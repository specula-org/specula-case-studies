// Minimal test file to exercise trace instrumentation
// This would normally be integrated into MongoDB's test suite
// For now, it serves as a placeholder showing the test structure

#include <iostream>
#include <fstream>
#include <cassert>

#include "tla_trace.h"

int main() {
    // Initialize trace file
    tla_trace::Emitter::getInstance().init("../traces/test_basic.ndjson");

    // Emit test events following the instrumentation spec
    std::map<std::string, std::string> fields;

    // Test OnStepUpComplete
    fields.clear();
    fields["service_state"] = "READY_FOR_INIT";
    fields["recovery_started"] = "true";
    tla_trace::Emitter::getInstance().emit("OnStepUpComplete", "n1", 1, fields);

    // Test LaunchRangeDeletionRecoveryTask
    fields.clear();
    fields["service_state"] = "INITIALIZING";
    tla_trace::Emitter::getInstance().emit("LaunchRangeDeletionRecoveryTask", "n1", 1, fields);

    // Test RecoveryCompletesFirstScan
    fields.clear();
    fields["recovery_scan_state"] = "scanned_processing";
    tla_trace::Emitter::getInstance().emit("RecoveryCompletesFirstScan", "n1", 1, fields);

    // Test RecoveryCompletesSecondScan
    fields.clear();
    fields["recovery_scan_state"] = "scanned_all";
    tla_trace::Emitter::getInstance().emit("RecoveryCompletesSecondScan", "n1", 1, fields);

    // Test RecoveryCompletes
    fields.clear();
    fields["service_state"] = "UP";
    fields["recovery_outcome"] = "COMPLETE";
    tla_trace::Emitter::getInstance().emit("RecoveryCompletes", "n1", 1, fields);

    // Test RegisterTask
    fields.clear();
    fields["task"] = "task-1";
    fields["registration_time"] = "1";
    fields["overlapping_with"] = "[]";
    tla_trace::Emitter::getInstance().emit("RegisterTask", "n1", 1, fields);

    // Test CompleteTask
    fields.clear();
    fields["task"] = "task-1";
    fields["task_completed"] = "true";
    fields["service_state"] = "UP";
    tla_trace::Emitter::getInstance().emit("CompleteTask", "n1", 1, fields);

    // Test OnStepDown
    fields.clear();
    fields["service_state"] = "DOWN";
    tla_trace::Emitter::getInstance().emit("OnStepDown", "n1", 1, fields);

    tla_trace::Emitter::getInstance().close();

    // Verify trace file was created
    std::ifstream trace_file("../traces/test_basic.ndjson");
    if (!trace_file.is_open()) {
        std::cerr << "ERROR: Failed to create trace file" << std::endl;
        return 1;
    }

    // Count events in trace
    std::string line;
    int event_count = 0;
    while (std::getline(trace_file, line)) {
        if (!line.empty()) {
            event_count++;
        }
    }

    trace_file.close();

    if (event_count < 8) {
        std::cerr << "ERROR: Expected at least 8 events, got " << event_count << std::endl;
        return 1;
    }

    std::cout << "✓ Trace test passed - " << event_count << " events emitted" << std::endl;
    return 0;
}
