#include "tla_trace.h"
#include <iostream>
#include <map>
#include <string>
#include <thread>
#include <chrono>

using namespace tla_trace;

// Simulated migration protocol state machine
enum class DonorState { Init, ClonePrepared, CriticalSection, CommittingOnConfig, Done };
enum class RecipientState { Init, Cloned, CriticalSection, Ready, Done };
enum class Decision { Undecided, Commit, Abort };

struct MigrationState {
    DonorState donorState = DonorState::Init;
    RecipientState recipientState = RecipientState::Init;
    Decision decision = Decision::Undecided;
    bool criticalSectionActive = false;
    std::string taskState = "pending";
    std::string recipientTaskState = "pending";
    std::string releaseState = "not_released";
    std::string donorMetadata = "owned";
    std::string recipientMetadata = "not_owned";
};

std::string stateToString(DonorState s) {
    switch (s) {
        case DonorState::Init: return "Init";
        case DonorState::ClonePrepared: return "ClonePrepared";
        case DonorState::CriticalSection: return "CriticalSection";
        case DonorState::CommittingOnConfig: return "CommittingOnConfig";
        case DonorState::Done: return "Done";
    }
    return "Unknown";
}

std::string stateToString(RecipientState s) {
    switch (s) {
        case RecipientState::Init: return "Init";
        case RecipientState::Cloned: return "Cloned";
        case RecipientState::CriticalSection: return "CriticalSection";
        case RecipientState::Ready: return "Ready";
        case RecipientState::Done: return "Done";
    }
    return "Unknown";
}

std::string decisionToString(Decision d) {
    switch (d) {
        case Decision::Undecided: return "Undecided";
        case Decision::Commit: return "Commit";
        case Decision::Abort: return "Abort";
    }
    return "Unknown";
}

void emitStateFields(MigrationState& state, const std::string& event) {
    std::map<std::string, std::string> fields;
    fields["donorState"] = stateToString(state.donorState);
    fields["recipientState"] = stateToString(state.recipientState);
    fields["decision"] = decisionToString(state.decision);
    fields["criticalSectionActive"] = state.criticalSectionActive ? "true" : "false";
    fields["taskState"] = state.taskState;
    fields["recipientTaskState"] = state.recipientTaskState;
    fields["releaseState"] = state.releaseState;
    fields["donorMetadata"] = state.donorMetadata;
    fields["recipientMetadata"] = state.recipientMetadata;

    TraceEmitter::getInstance().emitEvent(event, "donor", fields);
}

// Test scenario 1: Normal commit flow
void testCommitFlow() {
    std::cout << "Running: testCommitFlow\n";
    MigrationState state;

    // RecipientStartClone
    state.recipientState = RecipientState::Init;
    emitStateFields(state, "RecipientStartClone");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // RecipientCloneComplete
    state.recipientState = RecipientState::Cloned;
    emitStateFields(state, "RecipientCloneComplete");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // DonorEnterCriticalSection
    state.donorState = DonorState::CriticalSection;
    state.criticalSectionActive = true;
    emitStateFields(state, "DonorEnterCriticalSection");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // DonorPersistCommitDecision
    state.decision = Decision::Commit;
    emitStateFields(state, "DonorPersistCommitDecision");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // LaunchReleaseRecipientCriticalSection
    state.releaseState = "in_flight";
    emitStateFields(state, "LaunchReleaseRecipientCriticalSection");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // CriticalSectionReleaseSucceeds
    state.criticalSectionActive = false;
    state.releaseState = "released";
    emitStateFields(state, "CriticalSectionReleaseSucceeds");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // DonorSendConfigServerCommit
    state.donorState = DonorState::CommittingOnConfig;
    emitStateFields(state, "DonorSendConfigServerCommit");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // ConfigServerPersistCommit
    state.donorState = DonorState::Done;
    emitStateFields(state, "ConfigServerPersistCommit");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // DonorDeleteRecipientRangeDeletionTask
    state.recipientTaskState = "deleted";
    emitStateFields(state, "DonorDeleteRecipientRangeDeletionTask");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // DonorDeleteRangeDeletionTaskLocally
    state.taskState = "deleted";
    emitStateFields(state, "DonorDeleteRangeDeletionTaskLocally");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // DonorRegisterRangeDeletionTask
    state.taskState = "ready";
    emitStateFields(state, "DonorRegisterRangeDeletionTask");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // ForgetMigration
    state.donorState = DonorState::Done;
    emitStateFields(state, "ForgetMigration");
}

// Test scenario 2: Abort flow
void testAbortFlow() {
    std::cout << "Running: testAbortFlow\n";
    MigrationState state;

    // RecipientStartClone
    state.recipientState = RecipientState::Init;
    emitStateFields(state, "RecipientStartClone");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // RecipientCloneComplete
    state.recipientState = RecipientState::Cloned;
    emitStateFields(state, "RecipientCloneComplete");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // DonorEnterCriticalSection
    state.donorState = DonorState::CriticalSection;
    state.criticalSectionActive = true;
    emitStateFields(state, "DonorEnterCriticalSection");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // DonorPersistAbortDecision
    state.decision = Decision::Abort;
    emitStateFields(state, "DonorPersistAbortDecision");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // LaunchReleaseRecipientCriticalSection
    state.releaseState = "in_flight";
    emitStateFields(state, "LaunchReleaseRecipientCriticalSection");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // CriticalSectionReleaseSucceeds
    state.criticalSectionActive = false;
    state.releaseState = "released";
    emitStateFields(state, "CriticalSectionReleaseSucceeds");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // AbortDeleteDonorRangeDeletionTask
    state.taskState = "deleted";
    emitStateFields(state, "AbortDeleteDonorRangeDeletionTask");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // AbortBumpRecipientTxnNumber
    emitStateFields(state, "AbortBumpRecipientTxnNumber");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // AbortMarkRecipientRangeDeletionReady
    state.recipientTaskState = "ready";
    emitStateFields(state, "AbortMarkRecipientRangeDeletionReady");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // AbortCleanup
    state.recipientState = RecipientState::Done;
    emitStateFields(state, "AbortCleanup");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // ForgetMigration
    state.donorState = DonorState::Done;
    emitStateFields(state, "ForgetMigration");
}

// Test scenario 3: Abort with recipient notification failure
void testAbortRecipientNotificationFails() {
    std::cout << "Running: testAbortRecipientNotificationFails\n";
    MigrationState state;

    state.recipientState = RecipientState::Init;
    emitStateFields(state, "RecipientStartClone");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.recipientState = RecipientState::Cloned;
    emitStateFields(state, "RecipientCloneComplete");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.donorState = DonorState::CriticalSection;
    state.criticalSectionActive = true;
    emitStateFields(state, "DonorEnterCriticalSection");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.decision = Decision::Abort;
    emitStateFields(state, "DonorPersistAbortDecision");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.releaseState = "in_flight";
    emitStateFields(state, "LaunchReleaseRecipientCriticalSection");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.criticalSectionActive = false;
    state.releaseState = "released";
    emitStateFields(state, "CriticalSectionReleaseSucceeds");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.taskState = "deleted";
    emitStateFields(state, "AbortDeleteDonorRangeDeletionTask");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // Recipient notification fails during abort
    std::map<std::string, std::string> failFields;
    failFields["donorState"] = stateToString(state.donorState);
    failFields["failureType"] = "ShardNotFound";
    failFields["recipientTaskState"] = "pending";
    failFields["decision"] = "Abort";
    TraceEmitter::getInstance().emitEvent("AbortRecipientNotificationFails", "donor", failFields);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.donorState = DonorState::Done;
    emitStateFields(state, "ForgetMigration");
}

// Test scenario 4: Critical section release fails
void testCriticalSectionReleaseFails() {
    std::cout << "Running: testCriticalSectionReleaseFails\n";
    MigrationState state;

    state.recipientState = RecipientState::Init;
    emitStateFields(state, "RecipientStartClone");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.recipientState = RecipientState::Cloned;
    emitStateFields(state, "RecipientCloneComplete");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.donorState = DonorState::CriticalSection;
    state.criticalSectionActive = true;
    emitStateFields(state, "DonorEnterCriticalSection");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.decision = Decision::Commit;
    emitStateFields(state, "DonorPersistCommitDecision");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.releaseState = "in_flight";
    emitStateFields(state, "LaunchReleaseRecipientCriticalSection");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // Release fails with ShardNotFound
    std::map<std::string, std::string> failFields;
    failFields["donorState"] = stateToString(state.donorState);
    failFields["releaseState"] = "released";  // From spec validation
    failFields["failureType"] = "ShardNotFound";
    failFields["criticalSectionActive"] = "false";
    TraceEmitter::getInstance().emitEvent("CriticalSectionReleaseFails", "donor", failFields);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
}

// Test scenario 5: Config server commit fails
void testConfigServerCommitFails() {
    std::cout << "Running: testConfigServerCommitFails\n";
    MigrationState state;

    state.recipientState = RecipientState::Init;
    emitStateFields(state, "RecipientStartClone");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.recipientState = RecipientState::Cloned;
    emitStateFields(state, "RecipientCloneComplete");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.donorState = DonorState::CriticalSection;
    state.criticalSectionActive = true;
    emitStateFields(state, "DonorEnterCriticalSection");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.decision = Decision::Commit;
    emitStateFields(state, "DonorPersistCommitDecision");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.releaseState = "in_flight";
    emitStateFields(state, "LaunchReleaseRecipientCriticalSection");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    state.criticalSectionActive = false;
    state.releaseState = "released";
    emitStateFields(state, "CriticalSectionReleaseSucceeds");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // Try to commit on config server but it fails
    state.donorState = DonorState::CommittingOnConfig;
    emitStateFields(state, "DonorSendConfigServerCommit");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // Config server commit fails and donor metadata is cleared
    std::map<std::string, std::string> failFields;
    failFields["donorMetadata"] = "not_owned";
    failFields["failureType"] = "CommitFailed";
    failFields["decision"] = "Commit";
    failFields["donorState"] = "CommittingOnConfig";
    failFields["recipientState"] = "Ready";
    failFields["criticalSectionActive"] = "false";
    TraceEmitter::getInstance().emitEvent("ConfigServerCommitFails", "donor", failFields);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // ForgetMigration after cleanup
    state.donorState = DonorState::Done;
    state.donorMetadata = "not_owned";
    emitStateFields(state, "ForgetMigration");
}

int main(int argc, char** argv) {
    // Initialize trace emitter
    std::string trace_file = "traces/migration.ndjson";
    if (argc > 1) {
        trace_file = argv[1];
    }

    TraceEmitter::getInstance().init(trace_file);

    // Run test scenarios
    testCommitFlow();
    std::cout << "\n";
    testAbortFlow();
    std::cout << "\n";
    testAbortRecipientNotificationFails();
    std::cout << "\n";
    testCriticalSectionReleaseFails();
    std::cout << "\n";
    testConfigServerCommitFails();

    TraceEmitter::getInstance().shutdown();

    std::cout << "Traces written to: " << trace_file << "\n";
    return 0;
}
