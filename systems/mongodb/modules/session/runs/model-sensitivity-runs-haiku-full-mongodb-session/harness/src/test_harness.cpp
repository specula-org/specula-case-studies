#include "tla_trace.h"
#include <iostream>
#include <thread>
#include <vector>
#include <chrono>

using namespace mongo::tla_trace;

// Simulates MongoD session catalog behavior by emitting trace events
class SessionCatalogSimulator {
public:
    SessionCatalogSimulator(const std::string& trace_file)
        : emitter_(trace_file) {
        emitter_.initialize();
    }

    // Scenario 1: Basic checkout and release
    void testBasicCheckoutRelease() {
        std::string sid = "s1";
        std::string opctx = "opCtx_0";

        // CheckOutSession event
        emitter_.emitCheckOutSession(
            sid, false, "CHECKED_OUT", 0, false, "NONEXCLUSIVE", opctx, "ACTIVE");

        // Simulate some work
        std::this_thread::sleep_for(std::chrono::milliseconds(10));

        // ReleaseSession event
        emitter_.emitReleaseSession(
            sid, "AVAILABLE", 0, false, "NONEXCLUSIVE", "NULL", "ACTIVE");

        emitter_.flush();
    }

    // Scenario 2: Kill and checkout for kill
    void testKillWorkflow() {
        std::string sid = "s2";

        // Initial checkout
        emitter_.emitCheckOutSession(
            sid, false, "CHECKED_OUT", 0, false, "NONEXCLUSIVE", "opCtx_1", "ACTIVE");

        std::this_thread::sleep_for(std::chrono::milliseconds(5));

        // Kill the session
        emitter_.emitKill(
            sid, "KILLING", 1, false, "NONEXCLUSIVE", "opCtx_1", "ACTIVE");

        std::this_thread::sleep_for(std::chrono::milliseconds(5));

        // Release after kill
        emitter_.emitReleaseSession(
            sid, "KILLED", 1, false, "NONEXCLUSIVE", "NULL", "ACTIVE");

        std::this_thread::sleep_for(std::chrono::milliseconds(5));

        // Checkout for kill
        emitter_.emitCheckOutSession(
            sid, true, "CHECKED_OUT", 1, false, "NONEXCLUSIVE", "opCtx_2", "ACTIVE");

        std::this_thread::sleep_for(std::chrono::milliseconds(5));

        // Release for kill
        emitter_.emitReleaseSession(
            sid, "AVAILABLE", 0, false, "NONEXCLUSIVE", "NULL", "ACTIVE");

        emitter_.flush();
    }

    // Scenario 3: Parent-child session reaping
    void testParentChildReaping() {
        std::string parent_sid = "parent_1";
        std::string child_sid = "child_1";

        // Create child session
        emitter_.emitCreateChildSession(parent_sid, child_sid);

        std::this_thread::sleep_for(std::chrono::milliseconds(5));

        // Checkout parent
        emitter_.emitCheckOutSession(
            parent_sid, false, "CHECKED_OUT", 0, false, "NONEXCLUSIVE", "opCtx_3", "ACTIVE");

        std::this_thread::sleep_for(std::chrono::milliseconds(5));

        // Release parent
        emitter_.emitReleaseSession(
            parent_sid, "AVAILABLE", 0, false, "NONEXCLUSIVE", "NULL", "ACTIVE");

        std::this_thread::sleep_for(std::chrono::milliseconds(5));

        // Scan for reap
        emitter_.emitScanSessionsForReap(parent_sid, {parent_sid, child_sid});

        std::this_thread::sleep_for(std::chrono::milliseconds(5));

        // Finish reap
        emitter_.emitFinishReap(parent_sid);

        emitter_.flush();
    }

    // Scenario 4: Multiple concurrent sessions
    void testConcurrentSessions() {
        std::vector<std::string> session_ids = {"s3", "s4", "s5"};
        std::vector<std::string> op_ctxs = {"opCtx_4", "opCtx_5", "opCtx_6"};

        // Checkout all sessions
        for (size_t i = 0; i < session_ids.size(); ++i) {
            emitter_.emitCheckOutSession(
                session_ids[i], false, "CHECKED_OUT", 0, false, "NONEXCLUSIVE",
                op_ctxs[i], "ACTIVE");
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }

        // Kill a session in the middle
        emitter_.emitKill(
            session_ids[1], "KILLING", 1, false, "NONEXCLUSIVE", op_ctxs[1], "ACTIVE");

        std::this_thread::sleep_for(std::chrono::milliseconds(5));

        // Release sessions in order
        for (size_t i = 0; i < session_ids.size(); ++i) {
            if (i == 1) {
                emitter_.emitReleaseSession(
                    session_ids[i], "KILLED", 1, false, "NONEXCLUSIVE", "NULL", "ACTIVE");
            } else {
                emitter_.emitReleaseSession(
                    session_ids[i], "AVAILABLE", 0, false, "NONEXCLUSIVE", "NULL", "ACTIVE");
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }

        emitter_.flush();
    }

    // Scenario 5: Complex interleaving (Family 1 stress test)
    void testComplexInterleaving() {
        std::string s1 = "s6";
        std::string s2 = "s7";

        // Create two sessions
        emitter_.emitCheckOutSession(s1, false, "CHECKED_OUT", 0, false, "NONEXCLUSIVE", "opCtx_7", "ACTIVE");
        emitter_.emitCheckOutSession(s2, false, "CHECKED_OUT", 0, false, "NONEXCLUSIVE", "opCtx_8", "ACTIVE");

        std::this_thread::sleep_for(std::chrono::milliseconds(3));

        // Kill s1 while checked out
        emitter_.emitKill(s1, "KILLING", 1, false, "NONEXCLUSIVE", "opCtx_7", "ACTIVE");

        std::this_thread::sleep_for(std::chrono::milliseconds(3));

        // Release s2 while s1 is killed
        emitter_.emitReleaseSession(s2, "AVAILABLE", 0, false, "NONEXCLUSIVE", "NULL", "ACTIVE");

        std::this_thread::sleep_for(std::chrono::milliseconds(3));

        // Release s1 (was killed)
        emitter_.emitReleaseSession(s1, "KILLED", 1, false, "NONEXCLUSIVE", "NULL", "ACTIVE");

        std::this_thread::sleep_for(std::chrono::milliseconds(3));

        // Checkout s1 for kill (has kill token pending)
        emitter_.emitCheckOutSession(s1, true, "CHECKED_OUT", 1, false, "NONEXCLUSIVE", "opCtx_9", "ACTIVE");

        std::this_thread::sleep_for(std::chrono::milliseconds(3));

        // Release s1 after kill checkout
        emitter_.emitReleaseSession(s1, "AVAILABLE", 0, false, "NONEXCLUSIVE", "NULL", "ACTIVE");

        emitter_.flush();
    }

private:
    TraceEmitter emitter_;
};

int main(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <trace_file> [scenario]" << std::endl;
        std::cerr << "Scenarios:" << std::endl;
        std::cerr << "  1 - Basic checkout/release" << std::endl;
        std::cerr << "  2 - Kill workflow" << std::endl;
        std::cerr << "  3 - Parent-child reaping" << std::endl;
        std::cerr << "  4 - Concurrent sessions" << std::endl;
        std::cerr << "  5 - Complex interleaving" << std::endl;
        std::cerr << "  all - Run all scenarios" << std::endl;
        return 1;
    }

    std::string trace_file = argv[1];
    std::string scenario = (argc > 2) ? argv[2] : "all";

    SessionCatalogSimulator simulator(trace_file);

    try {
        if (scenario == "1" || scenario == "all") {
            std::cout << "Running Scenario 1: Basic checkout/release" << std::endl;
            simulator.testBasicCheckoutRelease();
        }
        if (scenario == "2" || scenario == "all") {
            std::cout << "Running Scenario 2: Kill workflow" << std::endl;
            simulator.testKillWorkflow();
        }
        if (scenario == "3" || scenario == "all") {
            std::cout << "Running Scenario 3: Parent-child reaping" << std::endl;
            simulator.testParentChildReaping();
        }
        if (scenario == "4" || scenario == "all") {
            std::cout << "Running Scenario 4: Concurrent sessions" << std::endl;
            simulator.testConcurrentSessions();
        }
        if (scenario == "5" || scenario == "all") {
            std::cout << "Running Scenario 5: Complex interleaving" << std::endl;
            simulator.testComplexInterleaving();
        }

        std::cout << "All scenarios completed successfully." << std::endl;
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return 1;
    }
}
