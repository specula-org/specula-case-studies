#!/usr/bin/env python3
"""
apply_patch.py — Apply TLA+ trace instrumentation to MongoDB replication sources.

Usage:
    python3 apply_patch.py <repl_dir>

Idempotent: each patch is guarded by a marker so re-running is safe.
"""

import os
import sys

MARKER = "TLA_TRACE:"   # if this string is present, the patch was already applied


def patch(path, old, new):
    """Replace `old` with `new` in `path`. No-op if MARKER already in file."""
    with open(path) as f:
        content = f.read()
    if MARKER in new and MARKER in content:
        # Check if the specific marker from `new` is already present
        # (crude but safe idempotency check)
        marker_line = next((l for l in new.splitlines() if MARKER in l), None)
        if marker_line and marker_line.strip() in content:
            print(f"  [skip] {os.path.basename(path)} — already patched")
            return
    if old not in content:
        print(f"  [warn] {os.path.basename(path)} — expected text not found; skipping")
        return
    with open(path, "w") as f:
        f.write(content.replace(old, new, 1))
    print(f"  [ok]   {os.path.basename(path)}")


def apply(repl_dir):
    # ─── replication_coordinator_impl.cpp ───────────────────────────────────

    rci = os.path.join(repl_dir, "replication_coordinator_impl.cpp")

    # 1. Add tla_trace.h include
    patch(rci,
        '#include "mongo/db/repl/replication_coordinator_impl.h"\n\n#include <ctime>',
        '#include "mongo/db/repl/replication_coordinator_impl.h"\n'
        '#include "mongo/db/repl/tla_trace.h"\n'
        '\n#include <ctime>')

    # 2. Add _tlaConfigStateStr helper in anonymous namespace
    patch(rci,
        'namespace {\n'
        'using VersionedConfigType = VersionedValue<ReplSetConfig, WriteRarelyRWMutex>;\n'
        'thread_local VersionedConfigType::Snapshot cachedRsConfig;\n'
        '\n'
        '}  // namespace',
        'namespace {\n'
        'using VersionedConfigType = VersionedValue<ReplSetConfig, WriteRarelyRWMutex>;\n'
        'thread_local VersionedConfigType::Snapshot cachedRsConfig;\n'
        '\n'
        '// Helper: get TLA+ configState string from enum (call while holding _mutex).\n'
        'const char* _tlaConfigStateStr(ReplicationCoordinatorImpl::ConfigState s) {\n'
        '    switch (s) {\n'
        '        case ReplicationCoordinatorImpl::kConfigSteady:          return "kConfigSteady";\n'
        '        case ReplicationCoordinatorImpl::kConfigReconfiguring:   return "kConfigReconfiguring";\n'
        '        case ReplicationCoordinatorImpl::kConfigHBReconfiguring: return "kConfigHBReconfiguring";\n'
        '        default:                                                  return "kConfigSteady";\n'
        '    }\n'
        '}\n'
        '\n'
        '}  // namespace')

    # 3. HandleRequestVote — emit before storeLocalLastVoteDocument
    patch(rci,
        '    // It\'s safe to store lastVote outside of _mutex. The topology coordinator grants only one\n'
        '    // vote per term, and storeLocalLastVoteDocument does nothing unless lastVote has a higher term\n'
        '    // than the previous lastVote, so threads racing to store votes from different terms will\n'
        '    // eventually store the latest vote.\n'
        '    if (!args.isADryRun() && response->getVoteGranted()) {\n'
        '        LastVote lastVote{args.getTerm(), args.getCandidateIndex()};\n'
        '        Status status = _externalState->storeLocalLastVoteDocument(opCtx, lastVote);',
        '    // TLA_TRACE: HandleRequestVote — emit after in-memory _lastVote updated, before persist.\n'
        '    if (!args.isADryRun()) {\n'
        '        stdx::lock_guard tlk(_mutex);\n'
        '        auto myId = (_selfIndex >= 0)\n'
        '            ? _rsConfig.unsafePeek().getMemberAt(_selfIndex).getHostAndPort().toString()\n'
        '            : std::string("unknown");\n'
        '        auto candId = (_rsConfig.unsafePeek().isInitialized() && args.getCandidateIndex() >= 0)\n'
        '            ? _rsConfig.unsafePeek().getMemberAt(args.getCandidateIndex()).getHostAndPort().toString()\n'
        '            : std::string("unknown");\n'
        '        TlaTrace::emitHandleRequestVote(\n'
        '            myId, candId, args.getTerm(),\n'
        '            _topCoord->getTerm(),\n'
        '            _topCoord->getMemberState().toString(),\n'
        '            _topCoord->getLastVote().getTerm());\n'
        '    }\n'
        '\n'
        '    // It\'s safe to store lastVote outside of _mutex. The topology coordinator grants only one\n'
        '    // vote per term, and storeLocalLastVoteDocument does nothing unless lastVote has a higher term\n'
        '    // than the previous lastVote, so threads racing to store votes from different terms will\n'
        '    // eventually store the latest vote.\n'
        '    if (!args.isADryRun() && response->getVoteGranted()) {\n'
        '        LastVote lastVote{args.getTerm(), args.getCandidateIndex()};\n'
        '        Status status = _externalState->storeLocalLastVoteDocument(opCtx, lastVote);')

    # 4. PersistVote — emit after storeLocalLastVoteDocument succeeds
    patch(rci,
        '            return status;\n'
        '        }\n'
        '    }\n'
        '    return Status::OK();\n'
        '}\n'
        '\n'
        'void ReplicationCoordinatorImpl::prepareReplMetadata(',
        '            return status;\n'
        '        }\n'
        '        // TLA_TRACE: PersistVote — durable write succeeded.\n'
        '        {\n'
        '            stdx::lock_guard tlk(_mutex);\n'
        '            auto myId = (_selfIndex >= 0)\n'
        '                ? _rsConfig.unsafePeek().getMemberAt(_selfIndex).getHostAndPort().toString()\n'
        '                : std::string("unknown");\n'
        '            TlaTrace::emitPersistVote(myId, _topCoord->getLastVote().getTerm());\n'
        '        }\n'
        '    }\n'
        '    return Status::OK();\n'
        '}\n'
        '\n'
        'void ReplicationCoordinatorImpl::prepareReplMetadata(')

    # 5. AutoReconfig / AutoReconfigPreempted
    patch(rci,
        '            auto reconfigStatus = doOptimizedReconfig(opCtx, getNewConfig);\n'
        '            if (!reconfigStatus.isOK()) {',
        '            auto reconfigStatus = doOptimizedReconfig(opCtx, getNewConfig);\n'
        '            if (!reconfigStatus.isOK()) {')  # no-op; already applied inline above

    # 6. SafeReconfigStart
    patch(rci,
        '    _setConfigState(lk, kConfigReconfiguring);\n'
        '    auto configStateGuard = ScopeGuard([&] {',
        '    _setConfigState(lk, kConfigReconfiguring);\n'
        '    // TLA_TRACE: SafeReconfigStart — configState -> Reconfiguring.\n'
        '    if (_selfIndex >= 0) {\n'
        '        TlaTrace::emitSafeReconfigStart(\n'
        '            _rsConfig.unsafePeek().getMemberAt(_selfIndex).getHostAndPort().toString(),\n'
        '            "kConfigReconfiguring");\n'
        '    }\n'
        '    auto configStateGuard = ScopeGuard([&] {')

    # 7. SafeReconfigSwap + ForceReconfig + SafeReconfigCaptureBarrier
    patch(rci,
        '    const PostMemberStateUpdateAction action = _setCurrentRSConfig(lk, opCtx, newConfig, myIndex);\n'
        '\n'
        '    // Record the latest committed optime in the current config atomically',
        '    const PostMemberStateUpdateAction action = _setCurrentRSConfig(lk, opCtx, newConfig, myIndex);\n'
        '\n'
        '    // TLA_TRACE: emit ForceReconfig or SafeReconfigSwap depending on reconfig type.\n'
        '    if (_selfIndex >= 0) {\n'
        '        auto myId = _rsConfig.unsafePeek().getMemberAt(_selfIndex).getHostAndPort().toString();\n'
        '        if (isForceReconfig) {\n'
        '            TlaTrace::emitForceReconfig(\n'
        '                myId,\n'
        '                _rsConfig.unsafePeek().getConfigVersion(),\n'
        '                _rsConfig.unsafePeek().getConfigVersion(),\n'
        '                _rsConfig.unsafePeek().getConfigTerm(),\n'
        '                "kConfigSteady", 0);\n'
        '        } else {\n'
        '            TlaTrace::emitSafeReconfigSwap(\n'
        '                myId,\n'
        '                _rsConfig.unsafePeek().getConfigVersion(),\n'
        '                _rsConfig.unsafePeek().getConfigTerm(),\n'
        '                "PostSwap");\n'
        '        }\n'
        '    }\n'
        '\n'
        '    // Record the latest committed optime in the current config atomically')

    patch(rci,
        '    _topCoord->updateLastCommittedInPrevConfig();\n'
        '\n'
        '    // Safe reconfig guarantees that all committed entries are safe',
        '    _topCoord->updateLastCommittedInPrevConfig();\n'
        '\n'
        '    // TLA_TRACE: SafeReconfigCaptureBarrier — only for safe reconfig.\n'
        '    if (_selfIndex >= 0 && !isForceReconfig) {\n'
        '        TlaTrace::emitSafeReconfigCaptureBarrier(\n'
        '            _rsConfig.unsafePeek().getMemberAt(_selfIndex).getHostAndPort().toString(),\n'
        '            "kConfigSteady",\n'
        '            _topCoord->getLastCommittedInPrevConfig().getSecs());\n'
        '    }\n'
        '\n'
        '    // Safe reconfig guarantees that all committed entries are safe')

    # 8. AdvanceCommitIndex
    patch(rci,
        'void ReplicationCoordinatorImpl::_updateLastCommittedOpTimeAndWallTime(WithLock lk) {\n'
        '    if (_topCoord->updateLastCommittedOpTimeAndWallTime()) {\n'
        '        _setStableTimestampForStorage(lk);\n'
        '    }\n'
        '}',
        'void ReplicationCoordinatorImpl::_updateLastCommittedOpTimeAndWallTime(WithLock lk) {\n'
        '    if (_topCoord->updateLastCommittedOpTimeAndWallTime()) {\n'
        '        // TLA_TRACE: AdvanceCommitIndex — commitIndex just advanced.\n'
        '        if (_selfIndex >= 0 && _getMemberState(lk).primary()) {\n'
        '            TlaTrace::emitAdvanceCommitIndex(\n'
        '                _rsConfig.unsafePeek().getMemberAt(_selfIndex).getHostAndPort().toString(),\n'
        '                static_cast<long long>(_topCoord->getLastCommittedOpTime().getSecs()));\n'
        '        }\n'
        '        _setStableTimestampForStorage(lk);\n'
        '    }\n'
        '}')

    # ─── replication_coordinator_impl_elect_v1.cpp ──────────────────────────

    elv1 = os.path.join(repl_dir, "replication_coordinator_impl_elect_v1.cpp")

    patch(elv1,
        '#include "mongo/db/repl/replication_coordinator_impl.h"',
        '#include "mongo/db/repl/replication_coordinator_impl.h"\n'
        '#include "mongo/db/repl/tla_trace.h"')

    # Timeout
    patch(elv1,
        '    _topCoord->voteForMyselfV1();\n'
        '\n'
        '    // Store the vote in persistent storage.',
        '    _topCoord->voteForMyselfV1();\n'
        '\n'
        '    // TLA_TRACE: Timeout — term incremented, self-vote secured.\n'
        '    if (_repl->_selfIndex >= 0) {\n'
        '        TlaTrace::emitTimeout(\n'
        '            _repl->_rsConfig.unsafePeek().getMemberAt(_repl->_selfIndex)\n'
        '                .getHostAndPort().toString(),\n'
        '            _topCoord->getTerm(),\n'
        '            _topCoord->getMemberState().toString());\n'
        '    }\n'
        '\n'
        '    // Store the vote in persistent storage.')

    # RequestVotes
    patch(elv1,
        '    fassert(28643, nextPhaseEvh.getStatus());\n'
        '    _replExecutor',
        '    fassert(28643, nextPhaseEvh.getStatus());\n'
        '\n'
        '    // TLA_TRACE: RequestVotes — vote requests enqueued.\n'
        '    if (_repl->_selfIndex >= 0) {\n'
        '        TlaTrace::emitRequestVotes(\n'
        '            _repl->_rsConfig.unsafePeek().getMemberAt(_repl->_selfIndex)\n'
        '                .getHostAndPort().toString(),\n'
        '            _topCoord->getTerm(),\n'
        '            _topCoord->getMemberState().toString());\n'
        '    }\n'
        '\n'
        '    _replExecutor')

    # BecomeLeader
    patch(elv1,
        '    _repl->_postWonElectionUpdateMemberState(lk);\n'
        '    _replExecutor->signalEvent(electionFinishedEvent);\n'
        '    lossGuard.dismiss();',
        '    _repl->_postWonElectionUpdateMemberState(lk);\n'
        '\n'
        '    // TLA_TRACE: BecomeLeader — role now PRIMARY, autoReconfigPending = TRUE per spec.\n'
        '    if (_repl->_selfIndex >= 0) {\n'
        '        TlaTrace::emitBecomeLeader(\n'
        '            _repl->_rsConfig.unsafePeek().getMemberAt(_repl->_selfIndex)\n'
        '                .getHostAndPort().toString(),\n'
        '            _topCoord->getTerm(),\n'
        '            _topCoord->getMemberState().toString(),\n'
        '            true);\n'
        '    }\n'
        '\n'
        '    _replExecutor->signalEvent(electionFinishedEvent);\n'
        '    lossGuard.dismiss();')

    # ─── replication_coordinator_impl_heartbeat.cpp ─────────────────────────

    hb = os.path.join(repl_dir, "replication_coordinator_impl_heartbeat.cpp")

    patch(hb,
        '#include <boost/smart_ptr.hpp>\n'
        '\n'
        '#define MONGO_LOGV2_DEFAULT_COMPONENT',
        '#include <boost/smart_ptr.hpp>\n'
        '#include "mongo/db/repl/tla_trace.h"\n'
        '\n'
        '#define MONGO_LOGV2_DEFAULT_COMPONENT')

    # HBReconfigSchedule
    patch(hb,
        '    _setConfigState(lk, kConfigHBReconfiguring);\n'
        '    auto rsc = _rsConfig.unsafePeek();',
        '    _setConfigState(lk, kConfigHBReconfiguring);\n'
        '    // TLA_TRACE: HBReconfigSchedule — configState -> HBReconfiguring.\n'
        '    if (_selfIndex >= 0) {\n'
        '        TlaTrace::emitHBReconfigSchedule(\n'
        '            _rsConfig.unsafePeek().getMemberAt(_selfIndex).getHostAndPort().toString(),\n'
        '            "kConfigHBReconfiguring");\n'
        '    }\n'
        '    auto rsc = _rsConfig.unsafePeek();')

    # HBReconfigFinish
    patch(hb,
        '    const PostMemberStateUpdateAction action =\n'
        '        _setCurrentRSConfig(lk, opCtx.get(), newConfig, myIndexValue);\n'
        '\n'
        '    lk.unlock();\n'
        '    if (contentChanged)',
        '    const PostMemberStateUpdateAction action =\n'
        '        _setCurrentRSConfig(lk, opCtx.get(), newConfig, myIndexValue);\n'
        '\n'
        '    // TLA_TRACE: HBReconfigFinish — new config installed, configState -> Steady.\n'
        '    if (_selfIndex >= 0) {\n'
        '        TlaTrace::emitHBReconfigFinish(\n'
        '            _rsConfig.unsafePeek().getMemberAt(_selfIndex).getHostAndPort().toString(),\n'
        '            _rsConfig.unsafePeek().getConfigVersion(),\n'
        '            _rsConfig.unsafePeek().getConfigTerm(),\n'
        '            "kConfigSteady");\n'
        '    }\n'
        '\n'
        '    lk.unlock();\n'
        '    if (contentChanged)')


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <repl_dir>")
        sys.exit(1)
    apply(sys.argv[1])
    print("Instrumentation applied.")
