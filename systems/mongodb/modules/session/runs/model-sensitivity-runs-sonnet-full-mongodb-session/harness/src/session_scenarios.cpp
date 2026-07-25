// MongoDB session lifecycle trace scenarios.
//
// Implements the TLA+ state machine from MongoDBSession.tla as a standalone
// C++ program that generates NDJSON traces for spec validation.
//
// State variables and transitions match the spec exactly.
// Each action function updates state then emits the corresponding trace event.
//
// Four scenarios are generated, one trace file per scenario:
//   normal_lifecycle.ndjson   — checkout/checkin + refresh cycles
//   kill_protocol.ndjson      — full kill-request → kill-release sequence
//   refresh_reap_race.ndjson  — Family 1: refresh and reap run concurrently
//   two_phase_reap.ndjson     — Family 4: two-step disk reap ordering
#include "tla_trace.h"

#include <iostream>
#include <map>
#include <string>
#include <stdexcept>
#include <thread>
#include <chrono>

using namespace mongo::tla_trace;

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------

struct SessionState {
    bool   sessionInCatalog      = true;
    std::string checkoutOpCtx    = "none";    // "none" | "normal" | "kill"
    int    waiters               = 0;
    int    killsRequested        = 0;
    bool   killTokenRegistered   = false;
    std::string killReleasePhase = "none";    // "none" | "cleared" | "notified"
    int    sessionLastRefreshed  = 1;
    bool   txnRecordOnDisk       = true;
    bool   imageRecordOnDisk     = true;
    std::string diskReapPhase    = "idle";    // "idle" | "image_reaped" | "done"
    std::string sessionSource    = "none";    // "none" | "active" | "runningOp"
    bool   refreshRetryQueued    = false;
    bool   refreshFailedRunningOp = false;
};

struct GlobalState {
    std::map<std::string, SessionState> sessions;
    std::string refreshWorkerPhase = "idle";
    std::string reapWorkerPhase    = "idle";
    int reapCutoff  = 0;
    int currentTime = 2;   // TLA+ Init: currentTime = 2

    GlobalState() {
        sessions["s1"] = SessionState{};
        sessions["s2"] = SessionState{};
    }
};

// ---------------------------------------------------------------------------
// Precondition helper
// ---------------------------------------------------------------------------

static void require(bool cond, const char* msg) {
    if (!cond) throw std::logic_error(msg);
}

// ---------------------------------------------------------------------------
// Action implementations
// Each function performs the state transition then emits the trace event.
// ---------------------------------------------------------------------------

// WaitForCheckout(s)
static void wait_for_checkout(GlobalState& gs, const std::string& s, TraceEmitter& te) {
    auto& ss = gs.sessions.at(s);
    require(ss.sessionInCatalog, "WaitForCheckout: sessionInCatalog must be TRUE");
    ss.waiters++;
    te.emit("wait_for_checkout", s,
        JsObj().n("waiters", ss.waiters)
               .b("sessionInCatalog", ss.sessionInCatalog)
               .n("killsRequested", ss.killsRequested));
}

// CheckoutSession(s) — non-kill checkout
static void checkout_session(GlobalState& gs, const std::string& s, TraceEmitter& te) {
    auto& ss = gs.sessions.at(s);
    require(ss.sessionInCatalog,          "CheckoutSession: must be in catalog");
    require(ss.waiters > 0,               "CheckoutSession: must have waiters");
    require(ss.checkoutOpCtx == "none",   "CheckoutSession: must not be checked out");
    require(ss.killsRequested == 0,       "CheckoutSession: kills must be zero (not forKill)");
    ss.checkoutOpCtx = "normal";
    ss.waiters--;
    te.emit("checkout_session", s,
        JsObj().s("checkoutOpCtx", "normal")
               .b("sessionInCatalog", ss.sessionInCatalog)
               .n("killsRequested", ss.killsRequested));
}

// CheckinSession(s) — normal release (no kill token)
static void checkin_session(GlobalState& gs, const std::string& s, TraceEmitter& te) {
    auto& ss = gs.sessions.at(s);
    require(ss.checkoutOpCtx == "normal", "CheckinSession: must be normally checked out");
    ss.checkoutOpCtx = "none";
    te.emit("checkin_session", s,
        JsObj().s("checkoutOpCtx", "none"));
}

// RequestKill(s)
static void request_kill(GlobalState& gs, const std::string& s, TraceEmitter& te) {
    auto& ss = gs.sessions.at(s);
    require(ss.sessionInCatalog,         "RequestKill: must be in catalog");
    require(!ss.killTokenRegistered,     "RequestKill: token must not be registered");
    ss.killsRequested++;
    te.emit("request_kill", s,
        JsObj().n("killsRequested", ss.killsRequested)
               .b("killTokenRegistered", false));
}

// RegisterKillChangeSucceed(s)
static void register_kill_change_succeed(GlobalState& gs, const std::string& s, TraceEmitter& te) {
    auto& ss = gs.sessions.at(s);
    require(ss.killsRequested > 0,   "RegisterKillChangeSucceed: must have pending kills");
    require(!ss.killTokenRegistered, "RegisterKillChangeSucceed: token must not be registered");
    ss.killTokenRegistered = true;
    te.emit("register_kill_change_succeed", s,
        JsObj().b("killTokenRegistered", true));
}

// CheckoutForKill(s) — no trace event; models session_catalog.cpp:168-178.
// Called internally before kill_release_clear_checkout.
static void checkout_for_kill_silent(GlobalState& gs, const std::string& s) {
    auto& ss = gs.sessions.at(s);
    require(ss.sessionInCatalog,        "CheckoutForKill: must be in catalog");
    require(ss.killTokenRegistered,     "CheckoutForKill: token must be registered");
    require(ss.killsRequested > 0,      "CheckoutForKill: must have pending kills");
    require(ss.checkoutOpCtx == "none", "CheckoutForKill: must not be checked out");
    ss.checkoutOpCtx = "kill";
    // No trace event — handled as SilentCheckoutForKill in Phase 3 Trace.tla
}

// KillReleaseClearCheckout(s) — step A of _releaseSession with killToken
static void kill_release_clear_checkout(GlobalState& gs, const std::string& s, TraceEmitter& te) {
    auto& ss = gs.sessions.at(s);
    require(ss.checkoutOpCtx == "kill",       "KillReleaseClearCheckout: must be kill checkout");
    require(ss.killReleasePhase == "none",    "KillReleaseClearCheckout: phase must be none");
    ss.checkoutOpCtx   = "none";
    ss.killReleasePhase = "cleared";
    te.emit("kill_release_clear_checkout", s,
        JsObj().s("checkoutOpCtx", "none")
               .n("killsRequested", ss.killsRequested));
}

// KillReleaseNotify(s) — step B: notify_all fires before --killsRequested
static void kill_release_notify(GlobalState& gs, const std::string& s, TraceEmitter& te) {
    auto& ss = gs.sessions.at(s);
    require(ss.killReleasePhase == "cleared", "KillReleaseNotify: phase must be cleared");
    ss.killReleasePhase = "notified";
    // killsRequested still > 0 here — this is the bug window
    te.emit("kill_release_notify", s,
        JsObj().n("killsRequested", ss.killsRequested));
}

// KillReleaseDecrement(s) — step C: --killsRequested, no second notify_all
static void kill_release_decrement(GlobalState& gs, const std::string& s, TraceEmitter& te) {
    auto& ss = gs.sessions.at(s);
    require(ss.killReleasePhase == "notified", "KillReleaseDecrement: phase must be notified");
    require(ss.killsRequested > 0,             "KillReleaseDecrement: kills must be > 0");
    ss.killsRequested--;
    ss.killTokenRegistered = false;
    ss.killReleasePhase    = "none";
    te.emit("kill_release_decrement", s,
        JsObj().n("killsRequested", ss.killsRequested)
               .b("killTokenRegistered", false));
}

// StartRefresh
static void start_refresh(GlobalState& gs, TraceEmitter& te) {
    require(gs.refreshWorkerPhase == "idle", "StartRefresh: worker must be idle");
    gs.refreshWorkerPhase = "running";
    for (auto& [name, ss] : gs.sessions) {
        ss.sessionSource            = ss.sessionInCatalog ? "active" : "runningOp";
        ss.refreshRetryQueued       = false;
        ss.refreshFailedRunningOp   = false;
    }
    te.emit_global("start_refresh", JsObj());
}

// RefreshSucceed(s)
static void refresh_succeed(GlobalState& gs, const std::string& s, TraceEmitter& te) {
    auto& ss = gs.sessions.at(s);
    require(gs.refreshWorkerPhase == "running", "RefreshSucceed: worker must be running");
    require(ss.sessionSource == "active" || ss.sessionSource == "runningOp",
            "RefreshSucceed: session must be in refresh batch");
    ss.sessionLastRefreshed = gs.currentTime;
    ss.sessionSource        = "none";
    // ValidateRefreshSucceed reads TraceLog[l].state.lastRefreshed
    te.emit("refresh_succeed", s,
        JsObj().n("lastRefreshed", ss.sessionLastRefreshed));
}

// RefreshFail(s)
static void refresh_fail(GlobalState& gs, const std::string& s, TraceEmitter& te) {
    auto& ss = gs.sessions.at(s);
    require(gs.refreshWorkerPhase == "running", "RefreshFail: worker must be running");
    require(ss.sessionSource == "active" || ss.sessionSource == "runningOp",
            "RefreshFail: session must be in refresh batch");
    std::string src = ss.sessionSource;
    ss.sessionSource = "none";
    if (src == "active") {
        ss.refreshRetryQueued = true;
    } else {
        ss.refreshFailedRunningOp = true;
    }
    te.emit("refresh_fail", s,
        JsObj().s("sessionSource", src));
}

// EndRefresh
static void end_refresh(GlobalState& gs, TraceEmitter& te) {
    require(gs.refreshWorkerPhase == "running", "EndRefresh: worker must be running");
    for (auto& [name, ss] : gs.sessions)
        require(ss.sessionSource == "none", "EndRefresh: all sessions must be processed");
    gs.refreshWorkerPhase = "idle";
    te.emit_global("end_refresh", JsObj());
}

// StartReap
static void start_reap(GlobalState& gs, TraceEmitter& te) {
    require(gs.reapWorkerPhase == "idle", "StartReap: worker must be idle");
    gs.reapWorkerPhase = "running";
    gs.reapCutoff      = gs.currentTime;
    te.emit_global("start_reap",
        JsObj().n("reapCutoff", gs.reapCutoff));
}

// MemoryReap(s) — phase 1: remove from in-memory catalog
static void memory_reap(GlobalState& gs, const std::string& s, TraceEmitter& te) {
    auto& ss = gs.sessions.at(s);
    require(gs.reapWorkerPhase == "running", "MemoryReap: worker must be running");
    require(ss.sessionInCatalog,             "MemoryReap: must be in catalog");
    require(ss.sessionLastRefreshed < gs.reapCutoff,
            "MemoryReap: session must be stale (lastRefreshed < reapCutoff)");
    ss.sessionInCatalog = false;
    ss.diskReapPhase    = "idle";  // candidate for disk reap
    te.emit("memory_reap", s,
        JsObj().b("sessionInCatalog", false));
}

// DiskReapImage(s) — phase 2A: delete config.image_collection row
static void disk_reap_image(GlobalState& gs, const std::string& s, TraceEmitter& te) {
    auto& ss = gs.sessions.at(s);
    require(gs.reapWorkerPhase == "running",  "DiskReapImage: worker must be running");
    require(!ss.sessionInCatalog,             "DiskReapImage: must not be in catalog");
    require(ss.diskReapPhase == "idle",       "DiskReapImage: disk phase must be idle");
    require(ss.imageRecordOnDisk,             "DiskReapImage: image must be on disk");
    ss.imageRecordOnDisk = false;
    ss.diskReapPhase     = "image_reaped";
    te.emit("disk_reap_image", s,
        JsObj().b("imageRecordOnDisk", false));
}

// DiskReapTxn(s) — phase 2B: delete config.transactions row
static void disk_reap_txn(GlobalState& gs, const std::string& s, TraceEmitter& te) {
    auto& ss = gs.sessions.at(s);
    require(gs.reapWorkerPhase == "running",       "DiskReapTxn: worker must be running");
    require(!ss.sessionInCatalog,                  "DiskReapTxn: must not be in catalog");
    require(ss.diskReapPhase == "image_reaped",    "DiskReapTxn: image must be reaped first");
    require(ss.txnRecordOnDisk,                    "DiskReapTxn: txn must be on disk");
    ss.txnRecordOnDisk = false;
    ss.diskReapPhase   = "done";
    te.emit("disk_reap_txn", s,
        JsObj().b("txnRecordOnDisk", false));
}

// EndReap
static void end_reap(GlobalState& gs, TraceEmitter& te) {
    require(gs.reapWorkerPhase == "running", "EndReap: worker must be running");
    gs.reapWorkerPhase = "idle";
    te.emit_global("end_reap", JsObj());
}

// ---------------------------------------------------------------------------
// Scenario 1: Normal lifecycle
// Covers: wait_for_checkout, checkout_session, checkin_session,
//         start_refresh, refresh_succeed, refresh_fail, end_refresh,
//         start_reap, end_reap
// ---------------------------------------------------------------------------
static void scenario_normal_lifecycle(const std::string& out_path) {
    TraceEmitter te(out_path);
    GlobalState  gs;

    // Four checkout/checkin cycles for s1
    for (int i = 0; i < 4; ++i) {
        wait_for_checkout(gs, "s1", te);
        checkout_session (gs, "s1", te);
        checkin_session  (gs, "s1", te);
        // Small sleep to space out real timestamps
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
    // Two checkout/checkin cycles for s2
    for (int i = 0; i < 2; ++i) {
        wait_for_checkout(gs, "s2", te);
        checkout_session (gs, "s2", te);
        checkin_session  (gs, "s2", te);
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
    // Refresh both sessions (sets sessionLastRefreshed = currentTime = 2)
    start_refresh   (gs, te);
    refresh_succeed (gs, "s1", te);
    refresh_succeed (gs, "s2", te);
    end_refresh     (gs, te);

    // More checkouts post-refresh
    for (int i = 0; i < 2; ++i) {
        wait_for_checkout(gs, "s1", te);
        checkout_session (gs, "s1", te);
        checkin_session  (gs, "s1", te);
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
    wait_for_checkout(gs, "s2", te);
    checkout_session (gs, "s2", te);
    checkin_session  (gs, "s2", te);

    // Second refresh: succeed s1, fail s2 (Family 3 coverage)
    start_refresh (gs, te);
    refresh_succeed(gs, "s1", te);
    refresh_fail   (gs, "s2", te);  // s2 stays in retry queue
    end_refresh    (gs, te);

    // Reap with nothing stale (s1.lastRefreshed = 2 = reapCutoff; 2 < 2 = false)
    start_reap(gs, te);
    end_reap  (gs, te);

    std::cout << "  scenario_normal_lifecycle -> " << out_path << "\n";
}

// ---------------------------------------------------------------------------
// Scenario 2: Kill protocol
// Covers: request_kill, register_kill_change_succeed,
//         kill_release_clear_checkout, kill_release_notify,
//         kill_release_decrement
// Note: checkout_for_kill has no trace event (silent action in spec).
//       Phase 3 must add SilentCheckoutForKill to Trace.tla.
// ---------------------------------------------------------------------------
static void scenario_kill_protocol(const std::string& out_path) {
    TraceEmitter te(out_path);
    GlobalState  gs;

    // s1: checkout, kill requested, kill token registered, checkin
    wait_for_checkout         (gs, "s1", te);
    checkout_session          (gs, "s1", te);
    request_kill              (gs, "s1", te);   // kills[s1]=1, token=false
    register_kill_change_succeed(gs, "s1", te); // token=true
    // Another thread checks out s2 (independent session, unaffected by s1 kill)
    wait_for_checkout         (gs, "s2", te);
    checkout_session          (gs, "s2", te);
    checkin_session           (gs, "s2", te);
    // Original owner of s1 checks in
    checkin_session           (gs, "s1", te);   // checkoutOpCtx="none", kills=1, token=true

    // KillSessionTokenOnCommit fires (on transaction commit):
    // checkout_for_kill completes (no trace event — silent in spec)
    checkout_for_kill_silent  (gs, "s1");        // checkoutOpCtx="kill"

    // Three-step kill release (_releaseSession with killToken present)
    kill_release_clear_checkout(gs, "s1", te);  // checkoutOpCtx="none", phase="cleared"
    kill_release_notify        (gs, "s1", te);  // phase="notified", kills still > 0 (bug window)
    kill_release_decrement     (gs, "s1", te);  // kills=0, token=false, phase="none"

    // Post-kill: s1 is available again; do more checkouts to pad to 25+ events
    for (int i = 0; i < 3; ++i) {
        wait_for_checkout(gs, "s1", te);
        checkout_session (gs, "s1", te);
        checkin_session  (gs, "s1", te);
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
    for (int i = 0; i < 2; ++i) {
        wait_for_checkout(gs, "s2", te);
        checkout_session (gs, "s2", te);
        checkin_session  (gs, "s2", te);
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
    // Refresh to record updated state
    start_refresh  (gs, te);
    refresh_succeed(gs, "s1", te);
    refresh_succeed(gs, "s2", te);
    end_refresh    (gs, te);

    std::cout << "  scenario_kill_protocol -> " << out_path << "\n";
}

// ---------------------------------------------------------------------------
// Scenario 3: Refresh-Reap race (Family 1)
// Demonstrates TxnRecordSafeWhileLive violation window:
//   refresh worker picks up s1 as "active" BEFORE reap removes it from memory;
//   reap then deletes the txn record even though refresh updated lastRefreshed.
// ---------------------------------------------------------------------------
static void scenario_refresh_reap_race(const std::string& out_path) {
    TraceEmitter te(out_path);
    GlobalState  gs;
    // Initial: s1/s2.lastRefreshed = 1, currentTime = 2

    // Setup: three checkout/checkin cycles without refreshes
    // (keeps lastRefreshed = 1 so sessions remain stale for reap)
    for (int i = 0; i < 3; ++i) {
        wait_for_checkout(gs, "s1", te);
        checkout_session (gs, "s1", te);
        checkin_session  (gs, "s1", te);
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
    for (int i = 0; i < 2; ++i) {
        wait_for_checkout(gs, "s2", te);
        checkout_session (gs, "s2", te);
        checkin_session  (gs, "s2", te);
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
    // 15 events so far

    // Concurrent refresh + reap workers (both start before either finishes)
    start_reap   (gs, te);   // reapCutoff = 2; s1.lastRefreshed=1 < 2 → stale
    start_refresh(gs, te);   // sessionSource: s1="active", s2="active"

    // Reap removes s1 from memory WHILE refresh has already snapshotted it as "active"
    memory_reap  (gs, "s1", te);  // s1 gone from catalog, diskReapPhase="idle"
    // Race: refresh still processes s1 (source="active"), updates lastRefreshed to 2
    refresh_succeed(gs, "s1", te);  // s1.lastRefreshed = 2 (= currentTime)
    // s2: reap then refresh
    memory_reap    (gs, "s2", te);  // s2 gone from catalog
    refresh_succeed(gs, "s2", te);  // s2.lastRefreshed = 2
    end_refresh    (gs, te);        // refresh done

    // Disk reap proceeds — deletes records even though lastRefreshed ≥ reapCutoff
    disk_reap_image(gs, "s1", te);  // image deleted
    disk_reap_image(gs, "s2", te);
    disk_reap_txn  (gs, "s1", te);  // BUG: s1.lastRefreshed=2 >= reapCutoff=2 but txn deleted
    disk_reap_txn  (gs, "s2", te);  // BUG: same for s2
    end_reap       (gs, te);

    std::cout << "  scenario_refresh_reap_race -> " << out_path << "\n";
}

// ---------------------------------------------------------------------------
// Scenario 4: Two-phase disk reap (Family 4)
// Demonstrates the NoDanglingImageWithoutTxnRecord violation window:
//   between disk_reap_image and disk_reap_txn, image is absent but txn exists.
// ---------------------------------------------------------------------------
static void scenario_two_phase_reap(const std::string& out_path) {
    TraceEmitter te(out_path);
    GlobalState  gs;
    // Initial: s1/s2.lastRefreshed = 1, currentTime = 2

    // Setup: checkout/checkin cycles (no refreshes — keep sessions stale)
    for (int i = 0; i < 3; ++i) {
        wait_for_checkout(gs, "s1", te);
        checkout_session (gs, "s1", te);
        checkin_session  (gs, "s1", te);
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
    for (int i = 0; i < 2; ++i) {
        wait_for_checkout(gs, "s2", te);
        checkout_session (gs, "s2", te);
        checkin_session  (gs, "s2", te);
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
    // 15 events

    // Two-phase reap for both sessions
    start_reap(gs, te);         // reapCutoff = 2

    memory_reap   (gs, "s1", te);  // s1 removed from in-memory catalog
    // Window: s1 absent from catalog but disk records (image + txn) still exist
    disk_reap_image(gs, "s1", te); // config.image_collection deleted
    // NoDanglingImageWithoutTxnRecord VIOLATED: image gone, txn still referenced
    disk_reap_txn  (gs, "s1", te); // config.transactions deleted — window closed

    memory_reap   (gs, "s2", te);  // s2 removed
    disk_reap_image(gs, "s2", te);
    disk_reap_txn  (gs, "s2", te);
    end_reap      (gs, te);
    // 23 events total

    // Post-reap: both sessions are fully reaped (diskReapPhase="done").
    // Refresh cycle with runningOp sessions (sessions may still have ops in flight).
    // start_refresh sets sessionSource="runningOp" for reaped sessions.
    start_refresh  (gs, te);         // s1/s2 source="runningOp" (not in catalog)
    refresh_succeed(gs, "s1", te);   // running-op session still refreshed
    refresh_succeed(gs, "s2", te);
    end_refresh    (gs, te);
    // 27 events total

    std::cout << "  scenario_two_phase_reap -> " << out_path << "\n";
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <traces_dir>\n";
        return 1;
    }
    std::string dir = argv[1];
    // Ensure trailing slash
    if (!dir.empty() && dir.back() != '/') dir += '/';

    std::cout << "Running MongoDB session lifecycle scenarios...\n";
    try {
        scenario_normal_lifecycle (dir + "normal_lifecycle.ndjson");
        scenario_kill_protocol    (dir + "kill_protocol.ndjson");
        scenario_refresh_reap_race(dir + "refresh_reap_race.ndjson");
        scenario_two_phase_reap   (dir + "two_phase_reap.ndjson");
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << "\n";
        return 1;
    }

    std::cout << "Done. Traces written to " << dir << "\n";
    return 0;
}
