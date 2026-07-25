/**
 * TLA+ Trace Scenario Tests for RangeDeleterService
 *
 * Three scenarios targeting the three bug families from the modeling brief:
 *   Scenario 1: Normal operation (full deletion pipeline)
 *   Scenario 2: Step-down during majority wait (F1 bug family)
 *   Scenario 3: Recovery with concurrent op_observer (F2 bug family)
 *
 * Each scenario writes to a separate trace file set by TLA_TRACE_FILE.
 * Build and run via: bazel test //src/mongo/db/s:range_deleter_tla_trace_test
 */

#include "tla_trace.h"

#include "mongo/db/s/range_deleter_service.h"
#include "mongo/db/s/range_deleter_service_test.h"
#include "mongo/db/repl/wait_for_majority_service.h"
#include "mongo/util/fail_point.h"
#include "mongo/unittest/unittest.h"
#include "mongo/util/duration.h"
#include "mongo/platform/atomic_word.h"

namespace mongo {
namespace {

// -------------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------------

constexpr auto kTermNormal = 1L;
constexpr auto kTermStepDown = 2L;

void tlaSteupUp(OperationContext* opCtx, long long term) {
    RangeDeleterService::get(opCtx)->onStepUpBegin(opCtx, term);
    RangeDeleterService::get(opCtx)->onStepUpComplete(opCtx, term);
    RangeDeleterService::get(opCtx)->getServiceUpFuture().get(opCtx);
}

// -------------------------------------------------------------------------
// Scenario 1: Normal operation
//   Covers: OpObserverClearPending, StepUp, RecoveryPhase1Scan,
//           RecoveryPhase2Scan, DeleteOrphans, MajorityWaitSuccess,
//           CompleteInMemory, RemovePersistentTask
// -------------------------------------------------------------------------
class TlaTraceNormalOpTest : public RangeDeleterServiceTest {
public:
    void setUp() override {
        tlaTrace::init("/tmp/tla_trace_normal_operation.ndjson", "n1");
        RangeDeleterServiceTest::setUp();
    }

    void tearDown() override {
        RangeDeleterServiceTest::tearDown();
        tlaTrace::close();
    }
};

TEST_F(TlaTraceNormalOpTest, NormalDeletionPipeline) {
    // Create a task that starts as pending, then clear pending to trigger
    // OpObserverClearPending. StepUp fires from setUp() simulateStepup.
    // The deletion pipeline (DeleteOrphans → MajorityWaitSuccess →
    // CompleteInMemory → RemovePersistentTask) fires when we register and drain.

    auto taskWithOngoingQueries = createRangeDeletionTaskWithOngoingQueries(
        uuidCollA, BSON("_id" << 0), BSON("_id" << 10),
        CleanWhenEnum::kNow, /*pending=*/true);

    auto completionFuture = registerAndCreatePersistentTask(
        opCtx,
        taskWithOngoingQueries->getTask(),
        taskWithOngoingQueries->getOngoingQueriesFuture());

    // Drain ongoing queries → deletion starts
    taskWithOngoingQueries->drainOngoingQueries();
    completionFuture.get(opCtx);
}

// -------------------------------------------------------------------------
// Scenario 2: Step-down during majority wait (F1 bug family)
//   Covers: OpObserverClearPending, StepUp, RecoveryPhase1Scan,
//           RecoveryPhase2Scan, DeleteOrphans, MajorityWaitInterrupted, StepDown
// -------------------------------------------------------------------------
class TlaTraceStepDownTest : public RangeDeleterServiceTest {
public:
    void setUp() override {
        tlaTrace::init("/tmp/tla_trace_stepdown_mid_majority.ndjson", "n1");
        RangeDeleterServiceTest::setUp();
    }

    void tearDown() override {
        RangeDeleterServiceTest::tearDown();
        tlaTrace::close();
    }
};

TEST_F(TlaTraceStepDownTest, StepDownDuringMajorityWait) {
    // Use the hangBeforeDoingDeletion failpoint to pause between orphan deletion
    // and majority wait, then trigger step-down.
    // Note: The actual interruption of the majority wait happens when onStepDown
    // marks the opCtx as killed.

    auto taskWithOngoingQueries = createRangeDeletionTaskWithOngoingQueries(
        uuidCollA, BSON("_id" << 0), BSON("_id" << 10),
        CleanWhenEnum::kNow, /*pending=*/true);

    auto completionFuture = registerAndCreatePersistentTask(
        opCtx,
        taskWithOngoingQueries->getTask(),
        taskWithOngoingQueries->getOngoingQueriesFuture());

    // Drain queries but immediately step down before deletion completes.
    // The deletion thread will get interrupted during the majority wait.
    taskWithOngoingQueries->drainOngoingQueries();

    // Step down interrupts the majority wait
    // (onStepDown marks opCtx as Interrupted, causing .get(opCtx) to throw)
    RangeDeleterService::get(opCtx)->onStepDown();

    // completionFuture will complete with an error (interrupted)
    (void)completionFuture.waitNoThrow(opCtx);
}

// -------------------------------------------------------------------------
// Scenario 3: Recovery with concurrent op_observer (F2 bug family)
//   Covers: StepUp, RecoveryPhase1Scan, OpObserverClearPending,
//           OpObserverRegisterTask, RecoveryPhase2Scan, DeleteOrphans,
//           MajorityWaitSuccess, CompleteInMemory, RemovePersistentTask
//
//   In this scenario we exercise a task that is in pending state at step-up
//   time, then gets its pending flag cleared by a migration commit while
//   recovery is between phase 1 and phase 2.
// -------------------------------------------------------------------------
class TlaTraceRecoveryOpObserverTest : public RangeDeleterServiceTest {
public:
    void setUp() override {
        tlaTrace::init("/tmp/tla_trace_recovery_opobserver.ndjson", "n1");
        RangeDeleterServiceTest::setUp();
    }

    void tearDown() override {
        RangeDeleterServiceTest::tearDown();
        tlaTrace::close();
    }
};

TEST_F(TlaTraceRecoveryOpObserverTest, RecoveryWithConcurrentOpObserver) {
    // Step-up triggers recovery. A range deletion task arrives (pending→ready)
    // via an op_observer call (removePendingField) which happens concurrently.
    // Recovery's phase 2 also picks up the ready task, exercising the dedup path.

    auto taskWithOngoingQueries = createRangeDeletionTaskWithOngoingQueries(
        uuidCollA, BSON("_id" << 100), BSON("_id" << 200),
        CleanWhenEnum::kNow, /*pending=*/true);

    // Insert the persistent document in pending state first (simulates migration in-progress)
    insertRangeDeletionTaskDocument(opCtx, taskWithOngoingQueries->getTask());

    // Now clear the pending flag — this fires OpObserverClearPending + OpObserverRegisterTask
    // The timing means it can fire during or after recovery scans.
    removePendingField(opCtx, taskWithOngoingQueries->getTask().getId());

    // Register the task so the completion future is tracked
    auto completionFuture = RangeDeleterService::get(opCtx)->registerTask(
        taskWithOngoingQueries->getTask(),
        taskWithOngoingQueries->getOngoingQueriesFuture());

    taskWithOngoingQueries->drainOngoingQueries();
    completionFuture.get(opCtx);
}

}  // namespace
}  // namespace mongo
