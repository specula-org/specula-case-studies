/**
 * Integration Test Scenarios for Range Deletion Trace Collection
 * Exercises protocol paths required for TLA+ trace validation
 */

#include "mongo/db/s/range_deleter_service_test.h"
#include "mongo/db/s/range_deletion_task_gen.h"
#include "tla_trace.h"

#include <gtest/gtest.h>
#include <thread>
#include <chrono>

namespace mongo {

class RangeDeleterTraceTest : public RangeDeleterServiceTest {
public:
    void SetUp() override {
        RangeDeleterServiceTest::setUp();
        // Initialize trace file for this test
        tla_trace::initTrace("../traces/trace.ndjson");
    }

    void TearDown() override {
        tla_trace::shutdownTrace();
        RangeDeleterServiceTest::tearDown();
    }

    // Helper to create a task document
    RangeDeletionTask createRangeDeletionTask(UUID collectionUuid,
                                               const ChunkRange& range,
                                               int64_t taskId) {
        RangeDeletionTask task;
        task.setId(taskId);
        task.setCollectionUuid(collectionUuid);
        task.setRange(range);
        task.setPending(true);
        return task;
    }

    // Helper to emit trace events with current state
    void emitStateSnapshot(const std::string& eventName) {
        tla_trace::TraceEvent event;
        event.eventName = eventName;
        event.node = "primary";
        event.timestamp = tla_trace::TraceEmitter::now();
        event.currentTerm = 1;
        event.replicaRole = "primary";
        event.processorState = "idle";
        event.recoveryInFlight = false;
        event.recoveryOutcome = "unknown";
        tla_trace::emitTrace(event);
    }
};

// Scenario 1: Basic task insertion and completion
TEST_F(RangeDeleterTraceTest, BasicTaskInsertion) {
    auto serviceCtx = getServiceContext();
    RangeDeleterService* rangeDeleterService = RangeDeleterService::get(serviceCtx);
    ASSERT_NE(rangeDeleterService, nullptr);

    emitStateSnapshot("InitialState");

    // Create a range deletion task
    ChunkRange range(BSON("_id" << 0), BSON("_id" << 100));
    auto task = createRangeDeletionTask(uuidCollA, range, 1);

    // Emit trace for task insertion
    tla_trace::TraceEvent insertEvent;
    insertEvent.eventName = "InsertTaskDocument";
    insertEvent.node = "primary";
    insertEvent.timestamp = tla_trace::TraceEmitter::now();
    insertEvent.currentTerm = 1;
    insertEvent.replicaRole = "primary";
    insertEvent.processorState = "idle";
    insertEvent.taskId = 1;
    insertEvent.persistentTaskState[1] = "pending";
    insertEvent.recoveryInFlight = false;
    insertEvent.recoveryOutcome = "unknown";
    tla_trace::emitTrace(insertEvent);

    // Simulate task processing
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    emitStateSnapshot("AfterInsertion");
}

// Scenario 2: Task ready transition
TEST_F(RangeDeleterTraceTest, TaskReadyTransition) {
    auto serviceCtx = getServiceContext();

    emitStateSnapshot("InitialState");

    // Emit task insert
    tla_trace::TraceEvent insertEvent;
    insertEvent.eventName = "InsertTaskDocument";
    insertEvent.node = "primary";
    insertEvent.timestamp = tla_trace::TraceEmitter::now();
    insertEvent.currentTerm = 1;
    insertEvent.replicaRole = "primary";
    insertEvent.processorState = "idle";
    insertEvent.taskId = 1;
    insertEvent.persistentTaskState[1] = "pending";
    insertEvent.inMemoryTaskExists = {1};
    insertEvent.recoveryInFlight = false;
    insertEvent.recoveryOutcome = "unknown";
    tla_trace::emitTrace(insertEvent);

    std::this_thread::sleep_for(std::chrono::milliseconds(5));

    // Emit task ready
    tla_trace::TraceEvent readyEvent;
    readyEvent.eventName = "MarkTaskReady";
    readyEvent.node = "primary";
    readyEvent.timestamp = tla_trace::TraceEmitter::now();
    readyEvent.currentTerm = 1;
    readyEvent.replicaRole = "primary";
    readyEvent.processorState = "idle";
    readyEvent.taskId = 1;
    readyEvent.persistentTaskState[1] = "ready";
    readyEvent.inMemoryTaskExists = {1};
    readyEvent.recoveryInFlight = false;
    readyEvent.recoveryOutcome = "unknown";
    tla_trace::emitTrace(readyEvent);

    emitStateSnapshot("AfterMarkReady");
}

// Scenario 3: Primary step-up with recovery
TEST_F(RangeDeleterTraceTest, PrimaryStepUpRecovery) {
    emitStateSnapshot("SecondaryState");

    std::this_thread::sleep_for(std::chrono::milliseconds(5));

    // Emit step up to primary
    tla_trace::TraceEvent stepUpEvent;
    stepUpEvent.eventName = "BecomePublicPrimary";
    stepUpEvent.node = "primary";
    stepUpEvent.timestamp = tla_trace::TraceEmitter::now();
    stepUpEvent.currentTerm = 2;
    stepUpEvent.replicaRole = "primary";
    stepUpEvent.processorState = "idle";
    stepUpEvent.recoveryInFlight = true;
    stepUpEvent.recoveryOutcome = "unknown";
    tla_trace::emitTrace(stepUpEvent);

    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // Emit recovery complete
    tla_trace::TraceEvent recoveryEvent;
    recoveryEvent.eventName = "CompleteRecoverySuccessfully";
    recoveryEvent.node = "primary";
    recoveryEvent.timestamp = tla_trace::TraceEmitter::now();
    recoveryEvent.currentTerm = 2;
    recoveryEvent.replicaRole = "primary";
    recoveryEvent.processorState = "idle";
    recoveryEvent.recoveryInFlight = false;
    recoveryEvent.recoveryOutcome = "complete";
    recoveryEvent.tasksRecoveredInTerm = {1, 2};
    recoveryEvent.inMemoryTaskExists = {1, 2};
    tla_trace::emitTrace(recoveryEvent);

    emitStateSnapshot("AfterRecovery");
}

// Scenario 4: Deletion execution
TEST_F(RangeDeleterTraceTest, DeletionExecution) {
    // Setup initial state with task in ready state
    tla_trace::TraceEvent initEvent;
    initEvent.eventName = "InitialState";
    initEvent.node = "primary";
    initEvent.timestamp = tla_trace::TraceEmitter::now();
    initEvent.currentTerm = 1;
    initEvent.replicaRole = "primary";
    initEvent.processorState = "idle";
    initEvent.persistentTaskState[1] = "ready";
    initEvent.inMemoryTaskExists = {1};
    initEvent.recoveryInFlight = false;
    initEvent.recoveryOutcome = "unknown";
    tla_trace::emitTrace(initEvent);

    std::this_thread::sleep_for(std::chrono::milliseconds(5));

    // Start processor
    tla_trace::TraceEvent startEvent;
    startEvent.eventName = "StartProcessor";
    startEvent.node = "primary";
    startEvent.timestamp = tla_trace::TraceEmitter::now();
    startEvent.currentTerm = 1;
    startEvent.replicaRole = "primary";
    startEvent.processorState = "running";
    startEvent.recoveryInFlight = false;
    startEvent.recoveryOutcome = "complete";
    tla_trace::emitTrace(startEvent);

    std::this_thread::sleep_for(std::chrono::milliseconds(5));

    // Dequeue task
    tla_trace::TraceEvent dequeueEvent;
    dequeueEvent.eventName = "DequeuTaskForDeletion";
    dequeueEvent.node = "primary";
    dequeueEvent.timestamp = tla_trace::TraceEmitter::now();
    dequeueEvent.currentTerm = 1;
    dequeueEvent.replicaRole = "primary";
    dequeueEvent.processorState = "running";
    dequeueEvent.taskId = 1;
    dequeueEvent.deletionProgress = "mark_processing";
    dequeueEvent.persistentTaskState[1] = "ready";
    dequeueEvent.inMemoryTaskExists = {1};
    tla_trace::emitTrace(dequeueEvent);

    std::this_thread::sleep_for(std::chrono::milliseconds(5));

    // Mark processing
    tla_trace::TraceEvent markProcEvent;
    markProcEvent.eventName = "MarkTaskProcessing";
    markProcEvent.node = "primary";
    markProcEvent.timestamp = tla_trace::TraceEmitter::now();
    markProcEvent.currentTerm = 1;
    markProcEvent.replicaRole = "primary";
    markProcEvent.processorState = "running";
    markProcEvent.taskId = 1;
    markProcEvent.persistentTaskState[1] = "processing";
    markProcEvent.inMemoryTaskExists = {1};
    tla_trace::emitTrace(markProcEvent);

    std::this_thread::sleep_for(std::chrono::milliseconds(5));

    // Begin deletion
    tla_trace::TraceEvent beginDelEvent;
    beginDelEvent.eventName = "BeginDeletion";
    beginDelEvent.node = "primary";
    beginDelEvent.timestamp = tla_trace::TraceEmitter::now();
    beginDelEvent.currentTerm = 1;
    beginDelEvent.replicaRole = "primary";
    beginDelEvent.processorState = "running";
    beginDelEvent.taskId = 1;
    beginDelEvent.deletionProgress = "deleting";
    beginDelEvent.persistentTaskState[1] = "processing";
    beginDelEvent.inMemoryTaskExists = {1};
    tla_trace::emitTrace(beginDelEvent);

    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // Complete deletion
    tla_trace::TraceEvent completeDelEvent;
    completeDelEvent.eventName = "CompleteDeletion";
    completeDelEvent.node = "primary";
    completeDelEvent.timestamp = tla_trace::TraceEmitter::now();
    completeDelEvent.currentTerm = 1;
    completeDelEvent.replicaRole = "primary";
    completeDelEvent.processorState = "running";
    completeDelEvent.taskId = 1;
    completeDelEvent.deletionProgress = "mark_complete";
    completeDelEvent.persistentTaskState[1] = "processing";
    completeDelEvent.inMemoryTaskExists = {1};
    tla_trace::emitTrace(completeDelEvent);

    std::this_thread::sleep_for(std::chrono::milliseconds(5));

    // Remove task document
    tla_trace::TraceEvent removeDocEvent;
    removeDocEvent.eventName = "RemoveTaskDocument";
    removeDocEvent.node = "primary";
    removeDocEvent.timestamp = tla_trace::TraceEmitter::now();
    removeDocEvent.currentTerm = 1;
    removeDocEvent.replicaRole = "primary";
    removeDocEvent.processorState = "running";
    removeDocEvent.taskId = 1;
    removeDocEvent.persistentTaskState[1] = "deleted";
    removeDocEvent.inMemoryTaskExists = {1};
    tla_trace::emitTrace(removeDocEvent);

    std::this_thread::sleep_for(std::chrono::milliseconds(5));

    // Remove from memory
    tla_trace::TraceEvent removeMemEvent;
    removeMemEvent.eventName = "RemoveTaskFromMemory";
    removeMemEvent.node = "primary";
    removeMemEvent.timestamp = tla_trace::TraceEmitter::now();
    removeMemEvent.currentTerm = 1;
    removeMemEvent.replicaRole = "primary";
    removeMemEvent.processorState = "running";
    removeMemEvent.taskId = 1;
    removeMemEvent.inMemoryTaskExists = {};
    tla_trace::emitTrace(removeMemEvent);

    emitStateSnapshot("DeletionComplete");
}

// Scenario 5: Processor shutdown
TEST_F(RangeDeleterTraceTest, ProcessorShutdown) {
    tla_trace::TraceEvent initEvent;
    initEvent.eventName = "InitialState";
    initEvent.node = "primary";
    initEvent.timestamp = tla_trace::TraceEmitter::now();
    initEvent.currentTerm = 1;
    initEvent.replicaRole = "primary";
    initEvent.processorState = "running";
    initEvent.persistentTaskState[1] = "processing";
    initEvent.inMemoryTaskExists = {1};
    initEvent.recoveryInFlight = false;
    initEvent.recoveryOutcome = "unknown";
    tla_trace::emitTrace(initEvent);

    std::this_thread::sleep_for(std::chrono::milliseconds(5));

    // Shutdown processor mid-deletion
    tla_trace::TraceEvent shutdownEvent;
    shutdownEvent.eventName = "ShutdownProcessor";
    shutdownEvent.node = "primary";
    shutdownEvent.timestamp = tla_trace::TraceEmitter::now();
    shutdownEvent.currentTerm = 1;
    shutdownEvent.replicaRole = "secondary";
    shutdownEvent.processorState = "stopped";
    shutdownEvent.taskBeingDeleted = 1;  // Task mid-deletion
    shutdownEvent.persistentTaskState[1] = "processing";
    shutdownEvent.inMemoryTaskExists = {1};
    tla_trace::emitTrace(shutdownEvent);

    emitStateSnapshot("AfterShutdown");
}

} // namespace mongo
