/************************************************************************
 * TLA+ Trace Validation Test
 *
 * Runs a basic 3-node Raft scenario with NURAFT_TRACE_FILE set,
 * producing an NDJSON trace for TLA+ validation.
 *
 * The trace starts AFTER make_group completes (3-node cluster with S1 as
 * leader). An initial snapshot line captures the starting state, then
 * client request events are traced.
 ************************************************************************/

#include "fake_network.hxx"
#include "raft_package_fake.hxx"
#include "fake_executer.hxx"

#include "raft_params.hxx"
#include "test_common.h"

#include <cstdio>
#include <cstdlib>

#ifdef NURAFT_TLA_TRACE
#include "tla_trace.hxx"
#endif

using namespace nuraft;
using namespace raft_functional_common;

using raft_result = cmd_result< ptr<buffer> >;

namespace trace_test {

#ifdef NURAFT_TLA_TRACE
// Emit a snapshot line capturing the state of all servers.
// This is used by Trace.tla's TraceInit to set the initial state.
static void emit_snapshot(const std::vector<RaftPkg*>& pkgs) {
    // Build a JSON snapshot with the state of all servers
    std::string buf = "{\"tag\":\"config\",\"ts\":";
    buf += std::to_string(nuraft::tla_trace::now_ns());
    buf += ",\"snapshot\":{";
    bool first = true;
    for (auto* pp : pkgs) {
        if (!first) buf += ",";
        first = false;
        auto rs = pp->raftServer;
        std::string nid = tla_trace::server_name(pp->myId);
        buf += "\"" + nid + "\":{";
        buf += "\"term\":" + std::to_string(rs->get_term()) + ",";
        buf += "\"role\":\"" + std::string(
            rs->is_leader() ? "leader" : "follower") + "\",";
        buf += "\"commitIndex\":" + std::to_string(
            rs->get_target_committed_log_idx()) + ",";
        buf += "\"smCommitIndex\":" + std::to_string(
            rs->get_committed_log_idx()) + ",";
        buf += "\"lastLogIndex\":" + std::to_string(
            rs->get_last_log_idx()) + ",";
        buf += "\"lastLogTerm\":" + std::to_string(
            rs->get_last_log_term());
        buf += "}";
    }
    buf += "}}";
    tla_trace::TraceWriter::instance().write(buf);
}
#endif

int basic_trace_test() {
    reset_log_files();
    ptr<FakeNetworkBase> f_base = cs_new<FakeNetworkBase>();

    std::string s1_addr = "S1";
    std::string s2_addr = "S2";
    std::string s3_addr = "S3";

    RaftPkg s1(f_base, 1, s1_addr);
    RaftPkg s2(f_base, 2, s2_addr);
    RaftPkg s3(f_base, 3, s3_addr);
    std::vector<RaftPkg*> pkgs = {&s1, &s2, &s3};

    // 1. Launch servers and form group (S1 becomes leader).
    //    Events during make_group involve single-node elections
    //    and membership changes that don't match the 3-node spec.
    CHK_Z( launch_servers( pkgs ) );
    CHK_Z( make_group( pkgs ) );

    // S1 should be leader now.
    CHK_TRUE( s1.raftServer->is_leader() );

#ifdef NURAFT_TLA_TRACE
    // Reset the trace file to start fresh after make_group.
    tla_trace::TraceWriter::instance().close();
    tla_trace::TraceWriter::instance().init();
    // Emit a snapshot of the current cluster state.
    emit_snapshot(pkgs);
#endif

    // 2. Append client entries using the executer thread pattern.
    ExecArgs exec_args(&s1);
    TestSuite::ThreadHolder hh(&exec_args, fake_executer, fake_executer_killer);

    for (int i = 0; i < 3; i++) {
        std::string test_msg = "msg" + std::to_string(i);
        ptr<buffer> msg = buffer::alloc(test_msg.size() + 1);
        msg->put(test_msg);

        {   std::lock_guard<std::mutex> l(exec_args.msgToWriteLock);
            exec_args.msgToWrite = msg;
        }
        exec_args.eaExecuter.invoke();
        TestSuite::sleep_ms(EXECUTOR_WAIT_MS, "wait for executor");

        // Replicate: pre-commit and commit packets.
        s1.fNet->execReqResp();
        s1.fNet->execReqResp();
        CHK_Z( wait_for_sm_exec(pkgs, COMMIT_TIMEOUT_SEC) );
    }

    // 3. Verify all state machines are in sync.
    CHK_TRUE( s1.getTestSm()->isSame(*s2.getTestSm()) );
    CHK_TRUE( s1.getTestSm()->isSame(*s3.getTestSm()) );

    return 0;
}

}  // namespace trace_test

int main(int argc, char** argv) {
    TestSuite ts(argc, argv);
    ts.options.printTestMessage = true;
    ts.doTest("basic trace test", trace_test::basic_trace_test);
    return 0;
}
