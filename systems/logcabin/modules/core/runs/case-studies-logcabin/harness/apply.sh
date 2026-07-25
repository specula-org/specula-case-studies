#!/bin/bash
# Apply TLA+ trace instrumentation to LogCabin.
#
# Usage: cd case-studies/logcabin && bash harness/apply.sh
#
# This script:
# 1. Resets artifact to clean state
# 2. Copies trace module files into Server/
# 3. Patches SConscript to compile tla_trace.cc
# 4. Patches RaftConsensus.cc with instrumentation emit calls
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/logcabin"
HARNESS="$CASE_DIR/harness"

echo "=== Applying TLA+ trace instrumentation to LogCabin ==="
echo "Artifact: $ARTIFACT"

# ---- Step 1: Clean artifact ----
echo "[1/4] Resetting artifact to clean state..."
git -C "$ARTIFACT" checkout -- .

# ---- Step 1b: Fix Python 3 / modern C++ compatibility ----
echo "[1b/4] Fixing Python 3 and modern C++ compatibility..."
# Fix SConstruct for Python 3
sed -i "1s/from distutils.version import LooseVersion as Version/try:\n    from distutils.version import LooseVersion as Version\nexcept ImportError:\n    from packaging.version import Version/" "$ARTIFACT/SConstruct"
sed -i "s/print 'Detected compiler %s %s' % (env\['CXX_FAMILY'\],/print('Detected compiler %s %s' % (env['CXX_FAMILY'],/" "$ARTIFACT/SConstruct"
sed -i "s/                                           env\['CXX_VERSION'\])/                                           env['CXX_VERSION']))/" "$ARTIFACT/SConstruct"
sed -i "s/print 'Could not detect compiler: %s' % e/print('Could not detect compiler: %s' % e)/" "$ARTIFACT/SConstruct"
sed -i 's/print "Error BUILDTYPE must be RELEASE or DEBUG"/print("Error BUILDTYPE must be RELEASE or DEBUG")/' "$ARTIFACT/SConstruct"
sed -i "s/os.sysconf_names.has_key/\"SC_NPROCESSORS_ONLN\" in os.sysconf_names #/" "$ARTIFACT/SConstruct"
sed -i "s/return 2\*int(os.popen2/return 2*int(subprocess.check_output(/" "$ARTIFACT/SConstruct"
sed -i 's/CXX_STANDARD = .c++11./CXX_STANDARD = "c++17"/' "$ARTIFACT/SConstruct"
# Fix missing includes for modern GCC
sed -i '/#include <cstdarg>/a #include <cstdint>' "$ARTIFACT/Core/StringUtil.cc"
sed -i '/#include <mutex>/a #include <stdexcept>' "$ARTIFACT/include/LogCabin/Client.h"
# Symlink gtest
if [ ! -e "$ARTIFACT/gtest/src/gtest-all.cc" ]; then
    rm -rf "$ARTIFACT/gtest"
    ln -sf /usr/src/googletest/googletest "$ARTIFACT/gtest"
fi

# ---- Step 2: Copy trace module ----
echo "[2/4] Copying trace module files..."
cp "$HARNESS/src/tla_trace.h"  "$ARTIFACT/Server/tla_trace.h"
cp "$HARNESS/src/tla_trace.cc" "$ARTIFACT/Server/tla_trace.cc"
cp "$HARNESS/src/RaftTraceTest.cc" "$ARTIFACT/Server/RaftTraceTest.cc"

# ---- Step 3: Patch SConscript ----
echo "[3/4] Patching Server/SConscript..."
# Add tla_trace.cc to the source list
sed -i '/^src = \[/,/^\]/{ /^]$/i\    "tla_trace.cc",
}' "$ARTIFACT/Server/SConscript"

# ---- Step 4: Patch RaftConsensus.cc with instrumentation ----
echo "[4/4] Patching Server/RaftConsensus.cc with trace instrumentation..."

# 4a: Add #include at top of file (after the last existing #include)
sed -i '/#include "Storage\/LogFactory.h"/a\
#ifdef LOGCABIN_TLA_TRACE\
#include "Server/tla_trace.h"\
#endif' "$ARTIFACT/Server/RaftConsensus.cc"

# 4b: Instrument startNewElection (Timeout) — after updateLogMetadata() line 2898
# Insert after "updateLogMetadata();" in startNewElection
sed -i '/^    updateLogMetadata();$/,/^    interruptAll();$/{
/^    interruptAll();$/i\
#ifdef LOGCABIN_TLA_TRACE\
    if (TlaTrace::isEnabled()) {\
        TlaTrace::Event("Timeout", serverId)\
            .state(TLA_STATE())\
            .emit();\
    }\
#endif
}' "$ARTIFACT/Server/RaftConsensus.cc"

# 4c: Instrument becomeLeader (BecomeLeader) — after append({&entry}) line 2524
# Insert after "interruptAll();" at end of becomeLeader
sed -i '/^    \/\/ Outstanding RequestVote RPCs are no longer needed.$/,/^}$/{
/^    interruptAll();$/a\
#ifdef LOGCABIN_TLA_TRACE\
    if (TlaTrace::isEnabled()) {\
        TlaTrace::Event("BecomeLeader", serverId)\
            .state(TLA_STATE())\
            .emit();\
    }\
#endif
}' "$ARTIFACT/Server/RaftConsensus.cc"

# 4d: Instrument handleRequestVote (HandleRequestVote) — before closing brace
# We insert just before the closing "}" of handleRequestVote, after response fields are set
sed -i '/^    response.set_granted(request.term() == currentTerm &&$/,/^}$/{
/^    response.set_log_ok(logIsOk);$/a\
#ifdef LOGCABIN_TLA_TRACE\
    if (TlaTrace::isEnabled()) {\
        TlaTrace::Event("HandleRequestVote", serverId)\
            .state(TLA_STATE())\
            .field("from", TlaTrace::nid(request.server_id()))\
            .field("granted", response.granted())\
            .emit();\
    }\
#endif
}' "$ARTIFACT/Server/RaftConsensus.cc"

# 4e: Instrument handleAppendEntries (HandleAppendEntries) — after withholdVotesUntil at end
# Insert after the final "withholdVotesUntil = Clock::now() + ELECTION_TIMEOUT;" in handleAppendEntries
# We use the last occurrence within handleAppendEntries (line 1426)
# Use a marker: the last setElectionTimer before closing brace
python3 -c "
import re
with open('$ARTIFACT/Server/RaftConsensus.cc', 'r') as f:
    content = f.read()

# Find handleAppendEntries function and insert before its closing '}'
# The function ends with:
#   withholdVotesUntil = Clock::now() + ELECTION_TIMEOUT;
# }
marker = '    // reset election timer to avoid punishing the leader for our own\\n    // long disk writes\\n    setElectionTimer();\\n    withholdVotesUntil = Clock::now() + ELECTION_TIMEOUT;\\n}'
inject = '''    // reset election timer to avoid punishing the leader for our own
    // long disk writes
    setElectionTimer();
    withholdVotesUntil = Clock::now() + ELECTION_TIMEOUT;
#ifdef LOGCABIN_TLA_TRACE
    if (TlaTrace::isEnabled()) {
        TlaTrace::Event(\"HandleAppendEntries\", serverId)
            .state(TLA_STATE())
            .field(\"from\", TlaTrace::nid(request.server_id()))
            .field(\"success\", response.success())
            .field(\"lastLogIndex\", static_cast<uint64_t>(response.last_log_index()))
            .emit();
    }
#endif
}'''
content = content.replace(marker, inject, 1)
with open('$ARTIFACT/Server/RaftConsensus.cc', 'w') as f:
    f.write(content)
"

# 4f: Instrument advanceCommitIndex (AdvanceCommitIndex) — after commitIndex = newCommitIndex
python3 -c "
with open('$ARTIFACT/Server/RaftConsensus.cc', 'r') as f:
    content = f.read()

old = '''    commitIndex = newCommitIndex;
    VERBOSE(\"New commitIndex: %lu\", commitIndex);
    assert(commitIndex <= log->getLastLogIndex());
    stateChanged.notify_all();'''

new = '''    commitIndex = newCommitIndex;
    VERBOSE(\"New commitIndex: %lu\", commitIndex);
    assert(commitIndex <= log->getLastLogIndex());
    stateChanged.notify_all();
#ifdef LOGCABIN_TLA_TRACE
    if (TlaTrace::isEnabled()) {
        TlaTrace::Event(\"AdvanceCommitIndex\", serverId)
            .state(TLA_STATE())
            .field(\"newCommitIndex\", commitIndex)
            .emit();
    }
#endif'''
content = content.replace(old, new, 1)
with open('$ARTIFACT/Server/RaftConsensus.cc', 'w') as f:
    f.write(content)
"

# 4g: Instrument leaderDiskThreadMain (LeaderDiskSync) — after lastSyncedIndex update
python3 -c "
with open('$ARTIFACT/Server/RaftConsensus.cc', 'r') as f:
    content = f.read()

old = '''            if (state == State::LEADER && currentTerm == term) {
                configuration->localServer->lastSyncedIndex = sync->lastIndex;
                advanceCommitIndex();
            }'''

new = '''            if (state == State::LEADER && currentTerm == term) {
                configuration->localServer->lastSyncedIndex = sync->lastIndex;
#ifdef LOGCABIN_TLA_TRACE
                if (TlaTrace::isEnabled()) {
                    TlaTrace::Event(\"LeaderDiskSync\", serverId)
                        .state(TLA_STATE())
                        .field(\"lastSyncedIndex\",
                               configuration->localServer->lastSyncedIndex)
                        .emit();
                }
#endif
                advanceCommitIndex();
            }'''
content = content.replace(old, new, 1)
with open('$ARTIFACT/Server/RaftConsensus.cc', 'w') as f:
    f.write(content)
"

# 4h: Instrument handleInstallSnapshot (HandleInstallSnapshot) — after readSnapshot() when done
python3 -c "
with open('$ARTIFACT/Server/RaftConsensus.cc', 'r') as f:
    content = f.read()

old = '''        NOTICE(\"Loading in new snapshot from leader\");
        snapshotWriter->save();
        snapshotWriter.reset();
        readSnapshot();
        stateChanged.notify_all();'''

new = '''        NOTICE(\"Loading in new snapshot from leader\");
        snapshotWriter->save();
        snapshotWriter.reset();
        readSnapshot();
        stateChanged.notify_all();
#ifdef LOGCABIN_TLA_TRACE
        if (TlaTrace::isEnabled()) {
            TlaTrace::Event(\"HandleInstallSnapshot\", serverId)
                .state(TLA_STATE())
                .field(\"from\", TlaTrace::nid(request.server_id()))
                .field(\"lastSnapshotIndex\", lastSnapshotIndex)
                .emit();
        }
#endif'''
content = content.replace(old, new, 1)
with open('$ARTIFACT/Server/RaftConsensus.cc', 'w') as f:
    f.write(content)
"

# 4i: Instrument snapshotDone (TakeSnapshot) — after lastSnapshotTerm assignment
python3 -c "
with open('$ARTIFACT/Server/RaftConsensus.cc', 'r') as f:
    content = f.read()

old = '''    lastSnapshotBytes = writer->save();
    lastSnapshotIndex = lastIncludedIndex;
    const Log::Entry& lastEntry = log->getEntry(lastIncludedIndex);
    lastSnapshotTerm = lastEntry.term();
    lastSnapshotClusterTime = lastEntry.cluster_time();'''

new = '''    lastSnapshotBytes = writer->save();
    lastSnapshotIndex = lastIncludedIndex;
    const Log::Entry& lastEntry = log->getEntry(lastIncludedIndex);
    lastSnapshotTerm = lastEntry.term();
    lastSnapshotClusterTime = lastEntry.cluster_time();
#ifdef LOGCABIN_TLA_TRACE
    if (TlaTrace::isEnabled()) {
        TlaTrace::Event(\"TakeSnapshot\", serverId)
            .state(TLA_STATE())
            .field(\"lastSnapshotIndex\", lastSnapshotIndex)
            .field(\"lastSnapshotTerm\", lastSnapshotTerm)
            .emit();
    }
#endif'''
content = content.replace(old, new, 1)
with open('$ARTIFACT/Server/RaftConsensus.cc', 'w') as f:
    f.write(content)
"

# 4j: Instrument appendEntries (AppendEntries send) — before callRPC
python3 -c "
with open('$ARTIFACT/Server/RaftConsensus.cc', 'r') as f:
    content = f.read()

old = '''    // Execute RPC
    Protocol::Raft::AppendEntries::Response response;
    TimePoint start = Clock::now();
    uint64_t epoch = currentEpoch;
    Peer::CallStatus status = peer.callRPC(
                Protocol::Raft::OpCode::APPEND_ENTRIES,
                request, response,
                lockGuard);'''

new = '''    // Execute RPC
    Protocol::Raft::AppendEntries::Response response;
    TimePoint start = Clock::now();
    uint64_t epoch = currentEpoch;
#ifdef LOGCABIN_TLA_TRACE
    if (TlaTrace::isEnabled()) {
        TlaTrace::Event(\"AppendEntries\", serverId)
            .state(TLA_STATE())
            .field(\"from\", TlaTrace::nid(serverId))
            .field(\"to\", TlaTrace::nid(peer.serverId))
            .field(\"prevLogIndex\", prevLogIndex)
            .field(\"numEntries\", numEntries)
            .emit();
    }
#endif
    Peer::CallStatus status = peer.callRPC(
                Protocol::Raft::OpCode::APPEND_ENTRIES,
                request, response,
                lockGuard);'''
content = content.replace(old, new, 1)
with open('$ARTIFACT/Server/RaftConsensus.cc', 'w') as f:
    f.write(content)
"

# 4k: Instrument appendEntries response (HandleAppendEntriesResponse) — after matchIndex update
python3 -c "
with open('$ARTIFACT/Server/RaftConsensus.cc', 'r') as f:
    content = f.read()

old = '''            peer.nextIndex = peer.matchIndex + 1;
            peer.suppressBulkData = false;

            if (!peer.isCaughtUp_ &&'''

new = '''            peer.nextIndex = peer.matchIndex + 1;
            peer.suppressBulkData = false;
#ifdef LOGCABIN_TLA_TRACE
            if (TlaTrace::isEnabled()) {
                TlaTrace::Event(\"HandleAppendEntriesResponse\", serverId)
                    .state(TLA_STATE())
                    .field(\"from\", TlaTrace::nid(peer.serverId))
                    .field(\"success\", true)
                    .field(\"matchIndex\", peer.matchIndex)
                    .emit();
            }
#endif

            if (!peer.isCaughtUp_ &&'''
content = content.replace(old, new, 1)
with open('$ARTIFACT/Server/RaftConsensus.cc', 'w') as f:
    f.write(content)
"

# 4l: Instrument appendEntries failure response
python3 -c "
with open('$ARTIFACT/Server/RaftConsensus.cc', 'r') as f:
    content = f.read()

old = '''        } else {
            if (peer.nextIndex > 1)
                --peer.nextIndex;
            // A server that hasn\\'t been around for a while'''

new = '''        } else {
#ifdef LOGCABIN_TLA_TRACE
            if (TlaTrace::isEnabled()) {
                TlaTrace::Event(\"HandleAppendEntriesResponse\", serverId)
                    .state(TLA_STATE())
                    .field(\"from\", TlaTrace::nid(peer.serverId))
                    .field(\"success\", false)
                    .field(\"matchIndex\", peer.matchIndex)
                    .emit();
            }
#endif
            if (peer.nextIndex > 1)
                --peer.nextIndex;
            // A server that hasn\\'t been around for a while'''
content = content.replace(old, new, 1)
with open('$ARTIFACT/Server/RaftConsensus.cc', 'w') as f:
    f.write(content)
"

# 4m: Instrument requestVote response (HandleRequestVoteResponse) — after vote processing
python3 -c "
with open('$ARTIFACT/Server/RaftConsensus.cc', 'r') as f:
    content = f.read()

old = '''        if (response.granted()) {
            peer.haveVote_ = true;
            NOTICE(\"Got vote from server %lu for term %lu\",
                   peer.serverId, currentTerm);
            if (configuration->quorumAll(&Server::haveVote))
                becomeLeader();
        } else {
            NOTICE(\"Vote denied by server %lu for term %lu\",
                   peer.serverId, currentTerm);
        }'''

new = '''        if (response.granted()) {
            peer.haveVote_ = true;
            NOTICE(\"Got vote from server %lu for term %lu\",
                   peer.serverId, currentTerm);
#ifdef LOGCABIN_TLA_TRACE
            if (TlaTrace::isEnabled()) {
                TlaTrace::Event(\"HandleRequestVoteResponse\", serverId)
                    .state(TLA_STATE())
                    .field(\"from\", TlaTrace::nid(peer.serverId))
                    .field(\"granted\", true)
                    .emit();
            }
#endif
            if (configuration->quorumAll(&Server::haveVote))
                becomeLeader();
        } else {
            NOTICE(\"Vote denied by server %lu for term %lu\",
                   peer.serverId, currentTerm);
#ifdef LOGCABIN_TLA_TRACE
            if (TlaTrace::isEnabled()) {
                TlaTrace::Event(\"HandleRequestVoteResponse\", serverId)
                    .state(TLA_STATE())
                    .field(\"from\", TlaTrace::nid(peer.serverId))
                    .field(\"granted\", false)
                    .emit();
            }
#endif
        }'''
content = content.replace(old, new, 1)
with open('$ARTIFACT/Server/RaftConsensus.cc', 'w') as f:
    f.write(content)
"

# 4n: Instrument installSnapshot send (InstallSnapshot) — before callRPC
python3 -c "
with open('$ARTIFACT/Server/RaftConsensus.cc', 'r') as f:
    content = f.read()

old = '''    // Execute RPC
    Protocol::Raft::InstallSnapshot::Response response;
    TimePoint start = Clock::now();
    uint64_t epoch = currentEpoch;
    Peer::CallStatus status = peer.callRPC(
                Protocol::Raft::OpCode::INSTALL_SNAPSHOT,
                request, response,
                lockGuard);'''

new = '''    // Execute RPC
    Protocol::Raft::InstallSnapshot::Response response;
    TimePoint start = Clock::now();
    uint64_t epoch = currentEpoch;
#ifdef LOGCABIN_TLA_TRACE
    if (TlaTrace::isEnabled() && request.byte_offset() == 0) {
        TlaTrace::Event(\"InstallSnapshot\", serverId)
            .state(TLA_STATE())
            .field(\"from\", TlaTrace::nid(serverId))
            .field(\"to\", TlaTrace::nid(peer.serverId))
            .field(\"lastSnapshotIndex\",
                   static_cast<uint64_t>(request.last_snapshot_index()))
            .emit();
    }
#endif
    Peer::CallStatus status = peer.callRPC(
                Protocol::Raft::OpCode::INSTALL_SNAPSHOT,
                request, response,
                lockGuard);'''
content = content.replace(old, new, 1)
with open('$ARTIFACT/Server/RaftConsensus.cc', 'w') as f:
    f.write(content)
"

# 4o: Instrument installSnapshot response (HandleInstallSnapshotResponse)
python3 -c "
with open('$ARTIFACT/Server/RaftConsensus.cc', 'r') as f:
    content = f.read()

old = '''            peer.snapshotFile.reset();
            peer.snapshotFileOffset = 0;
            peer.lastSnapshotIndex = 0;
        }
    }
}

void
RaftConsensus::becomeLeader()'''

new = '''            peer.snapshotFile.reset();
            peer.snapshotFileOffset = 0;
#ifdef LOGCABIN_TLA_TRACE
            if (TlaTrace::isEnabled()) {
                TlaTrace::Event(\"HandleInstallSnapshotResponse\", serverId)
                    .state(TLA_STATE())
                    .field(\"from\", TlaTrace::nid(peer.serverId))
                    .field(\"matchIndex\", peer.matchIndex)
                    .emit();
            }
#endif
            peer.lastSnapshotIndex = 0;
        }
    }
}

void
RaftConsensus::becomeLeader()'''
content = content.replace(old, new, 1)
with open('$ARTIFACT/Server/RaftConsensus.cc', 'w') as f:
    f.write(content)
"

# 4p: Instrument replicateEntry (ClientRequest) — after append
python3 -c "
with open('$ARTIFACT/Server/RaftConsensus.cc', 'r') as f:
    content = f.read()

# replicateEntry: after append({&entry}) and before the while loop
old = '''    if (state == State::LEADER) {
        entry.set_term(currentTerm);
        entry.set_cluster_time(clusterClock.leaderStamp());
        append({&entry});
        uint64_t index = log->getLastLogIndex();'''

new = '''    if (state == State::LEADER) {
        entry.set_term(currentTerm);
        entry.set_cluster_time(clusterClock.leaderStamp());
        append({&entry});
        uint64_t index = log->getLastLogIndex();
#ifdef LOGCABIN_TLA_TRACE
        if (TlaTrace::isEnabled() &&
            entry.type() == Protocol::Raft::EntryType::DATA) {
            TlaTrace::Event(\"ClientRequest\", serverId)
                .state(TLA_STATE())
                .emit();
        }
#endif'''
content = content.replace(old, new, 1)
with open('$ARTIFACT/Server/RaftConsensus.cc', 'w') as f:
    f.write(content)
"

echo ""
echo "=== Instrumentation applied successfully ==="
echo "Build with: cd $ARTIFACT && CXXFLAGS='-DLOGCABIN_TLA_TRACE' scons -j\$(nproc)"
