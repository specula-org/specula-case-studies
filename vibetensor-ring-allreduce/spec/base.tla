--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for VibeTensor's Blackwell Ring AllReduce collective.
 *
 * Derived from:
 *   ring_allreduce_plugin/94_blackwell_ring_allreduce/cutlass/experimental/
 *     distributed/collective/{ring_allreduce_kernel_sm100.cuh,
 *     ring_allreduce_barrier_sm100.cuh, ring_allreduce_drain.hpp,
 *     ring_allreduce_smem.hpp, ring_allreduce_types.hpp}
 *   ring_allreduce_plugin/vbt_ring_allreduce/vbt_ring_allreduce_plugin.cu
 *
 * Category: A (Distributed / Message-Passing) — N per-rank kernels
 * communicating via system-scope atomic flag arrays over CUDA P2P/UVA.
 *
 * Bug Families covered:
 *   F1 — CAS-from-kOk defeats status precedence elevation
 *   F2 — AG step-0 publish under concurrent abort exposes partial data
 *   F3 — Asymmetric release-barrier timeouts (rank-0 trusted-sequencer hang)
 *   F5 — Host watchdog must poison self_abort before returning
 *   F6 — Epoch-equality flag freshness across runs
 *   F7 — Drain not abort-responsive
 *
 * Not modeled (per modeling brief):
 *   - CUTLASS warp-level intra-CTA concurrency / SMEM ping-pong (smem.hpp)
 *   - CUDA event/stream graph fence semantics (Family 4 = code review)
 *   - Numerical reduction (data abstracted as sets of contributors)
 *)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Rank          \* Set of rank IDs (e.g., {0, 1, 2, 3})
CONSTANT NumTiles      \* Number of independent tiles (== num_tiles_total in code)
CONSTANT EpochValue    \* The per-run epoch tag (must be > 0; code: types.hpp:135)
CONSTANT StaleEpoch    \* A stale (prior-run) epoch value, for Family 6
CONSTANT Nil           \* Sentinel "none"

\* Status / error codes.
\* Source: ring_allreduce_types.hpp:56-61
CONSTANTS
    kOk,             \* RingAllreduceError::kOk = 0
    kInvalidParams,  \* kInvalidParams (highest precedence)
    kTimeout,        \* kTimeout
    kAbortObserved   \* kAbortObserved (lowest non-OK precedence)

\* ============================================================================
\* DERIVED HELPERS / CONSTANTS
\* ============================================================================

\* world_size = |Rank|. Code restricts to {1, 2, 4, 8} (types.hpp:163).
N == Cardinality(Rank)

\* Ranks are 0..N-1 in code. The spec accepts any totally-ordered Rank set.
\* For convenience define a left-neighbor function on the ring.
\* Source: kernel_sm100.cuh:2473  left = (rank + N - 1) % N
\* For abstract Rank we model the ring through an arbitrary bijection RankIdx.
RankIdx == CHOOSE f \in [Rank -> 0..N-1] :
                /\ \A i, j \in Rank : i /= j => f[i] /= f[j]

IdxRank == [i \in 0..N-1 |-> CHOOSE r \in Rank : RankIdx[r] = i]

LeftOf(r) == IdxRank[(RankIdx[r] + N - 1) % N]

\* Chunk identifier set (one chunk per rank, modeling tiles_per_chunk=1
\* with num_chunks_total == world_size * num_channels and num_channels=1).
\* Source: types.hpp / kernel_sm100.cuh:2466-2467
Chunk == 0..N-1

\* Per-rank "owned" chunk after RS completes.
\* After s = N-2 RS steps, rank r holds chunk_rs(N-2) = (r - (N-2) - 1 + N) % N
\*                                                  = (r + 1) % N.
\* Source: kernel_sm100.cuh:488 chunk_rs(s) = (r + N - s - 1) % N
OwnedChunk(r) == ((RankIdx[r] + 1) % N)

\* Chunk that rank r reads/adds at RS step s (0-indexed).
\* Source: kernel_sm100.cuh:488
ChunkRS(r, s) == ((RankIdx[r] + N - s - 1) % N)

\* Chunk that rank r overwrites/copies at AG step s (0-indexed).
\* Source: kernel_sm100.cuh:626
ChunkAG(r, s) == ((RankIdx[r] + N - s) % N)

\* Number of RS / AG steps. Source: kernel_sm100.cuh:485, 623
\* RS loops s in [0, N-2], i.e. N-1 steps; same for AG.
NumSteps == N - 1

\* Status precedence merge_status (kInvalidParams > kTimeout > kAbortObserved > kOk).
\* Source: ring_allreduce_types.hpp:69-80
MergeStatus(a, b) ==
    IF a = kInvalidParams \/ b = kInvalidParams THEN kInvalidParams
    ELSE IF a = kTimeout \/ b = kTimeout THEN kTimeout
    ELSE IF a = kAbortObserved \/ b = kAbortObserved THEN kAbortObserved
    ELSE kOk

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- Per-rank kernel program counter. Source: kernel_sm100.cuh:2424-2547 ---
\* "rs"            — executing reduce-scatter loop (rs_step in 0..NumSteps-1)
\* "ag_pub0"       — about to publish ag_ready[r][0][t] (post-RS, pre-AG-loop)
\*                   Source: kernel_sm100.cuh:602-617
\* "ag"            — executing all-gather loop (ag_step in 0..NumSteps-1)
\* "drain_signal"  — about to call signal_tile_finished + drain (cta0 only)
\*                   Source: kernel_sm100.cuh:2513-2538
\* "barrier_gather" — Phase A of completion barrier
\*                   Source: ring_allreduce_barrier_sm100.cuh:257-305
\* "barrier_release" — Phase B of completion barrier
\*                   Source: ring_allreduce_barrier_sm100.cuh:309-404
\* "barrier_latch" — post-barrier publish_error_and_abort(broadcast) latch
\*                   Source: ring_allreduce_barrier_sm100.cuh:330-332, 400-402
\* "epilogue"      — write out_status[r]. Source: kernel_sm100.cuh:2543-2545
\* "done"          — kernel exited
VARIABLE pc

\* Per-rank intra-phase step counters.
VARIABLE rs_step           \* [Rank -> 0..NumSteps]
VARIABLE ag_step           \* [Rank -> 0..NumSteps]

\* Per-rank "rs broke out early" flag (so AG is skipped).
\* Source: kernel_sm100.cuh:506-509, 748-751
VARIABLE rs_ok

\* --- Symbolic data: data[r][c] = SUBSET Rank, the contributors so far.
\* Initial: data[r][c] = {r}. Final/correct: data[r][c] = Rank for every c.
\* This abstracts T self_data[idx] in code. Source: kernel_sm100.cuh:541-544
VARIABLE data

\* --- Per-rank per-step per-tile readiness flags (system-scope atomics).
\* Stored as the epoch they hold (0 = not set; > 0 = epoch tag).
\* Source: types.hpp:117-118 self_rs_ready, self_ag_ready
\* Note: rs_ready[r][s][t] for s in 1..NumSteps; ag_ready[r][s][t] for s in 0..NumSteps
VARIABLE rs_ready          \* [Rank -> [1..NumSteps -> [1..NumTiles -> Nat]]]
VARIABLE ag_ready          \* [Rank -> [0..NumSteps -> [1..NumTiles -> Nat]]]

\* --- Per-rank error/abort scalars (system-scope atomics).
\* Source: types.hpp:119-120
\* self_error: written via CAS-from-kOk. Source: drain.hpp:102-110
\* self_abort: written unconditionally as part of publish_error_and_abort,
\*             OR by hop propagation from peer_abort[left]. Source: smem.hpp:144-153
VARIABLE self_error        \* [Rank -> ErrorCode]
VARIABLE self_abort        \* [Rank -> 0..1]

\* --- Per-rank drain counter (device-scope atomic).
\* Source: types.hpp:123 self_tiles_finished; drain.hpp:80-110, 167-219
VARIABLE tiles_finished    \* [Rank -> Nat]

\* --- Two-phase ring-token barrier. Source: types.hpp:126-129, barrier_sm100.cuh
\* All four are system-scope atomics, epoch-tagged.
VARIABLE barrier_gather_token    \* [Rank -> Nat]   (epoch when published)
VARIABLE barrier_gather_status   \* [Rank -> ErrorCode]
VARIABLE barrier_release_token   \* [Rank -> Nat]
VARIABLE barrier_release_status  \* [Rank -> ErrorCode]

\* --- Final per-rank kernel return value. Source: kernel_sm100.cuh:2543-2545 ---
VARIABLE out_status        \* [Rank -> ErrorCode \cup {Nil}]

\* --- Host-side state (Family 5) ---
\* Source: vbt_ring_allreduce_plugin.cu:637-656, 1035-1071
VARIABLE host_watchdog_fired   \* BOOLEAN — host watchdog fired
VARIABLE host_freed            \* BOOLEAN — host has freed atomics

\* --- Family 1/2/3 fault-injection knobs (Source: types.hpp:142-150 debug_*) ---
\* Set at Init from CONSTANTS in MC.cfg. Modeled as constant inputs not changed
\* during execution (debug_* are launch-time params).
VARIABLE inject_release_delay    \* [Rank -> 0..1]  — emulates debug_release_delay_*
VARIABLE inject_release_hang     \* [Rank -> 0..1]  — environmental "stuck mid-release"

\* --- Wait-flag timeout enable for non-zero release wait.
\* Source: barrier_sm100.cuh:338-348
\* Becomes true once abort observed during the release wait.
VARIABLE release_timeouts_armed  \* [Rank -> 0..1]

\* --- Track which step of the release wait the rank has reached:
\* "wait" (still polling), "got_token" (acquire-confirmed), "forwarded" (republished).
\* Source: barrier_sm100.cuh:342-397
VARIABLE release_pc              \* [Rank -> {"wait", "got_token", "forwarded"}]

\* Phase A — track which step rank is in after publishing self gather token.
\* Source: barrier_sm100.cuh:261-305
VARIABLE gather_pc               \* [Rank -> {"start", "self_published",
                                  \*           "left_received", "merged_published"}]

\* Cached "incoming" status from left during gather wait (rank!=0).
\* Source: barrier_sm100.cuh:280-304
VARIABLE gather_incoming         \* [Rank -> ErrorCode \cup {Nil}]

\* The local aggregate computed during gather (becomes final_status).
\* Source: barrier_sm100.cuh:259, 277, 297, 301
VARIABLE barrier_agg             \* [Rank -> ErrorCode]

\* Cached release broadcast received from left (non-zero ranks).
\* Source: barrier_sm100.cuh:384-385
VARIABLE release_broadcast       \* [Rank -> ErrorCode \cup {Nil}]

\* ============================================================================
\* VARIABLE GROUPS (for UNCHANGED clauses)
\* ============================================================================

phaseVars      == <<pc, rs_step, ag_step, rs_ok>>
flagVars       == <<rs_ready, ag_ready>>
errVars        == <<self_error, self_abort>>
drainVars      == <<tiles_finished>>
barrierVars    == <<barrier_gather_token, barrier_gather_status,
                    barrier_release_token, barrier_release_status,
                    gather_pc, gather_incoming, barrier_agg,
                    release_pc, release_broadcast,
                    release_timeouts_armed>>
hostVars       == <<host_watchdog_fired, host_freed>>
injectVars     == <<inject_release_delay, inject_release_hang>>
dataVars       == <<data>>
outVars        == <<out_status>>

vars == <<phaseVars, flagVars, errVars, drainVars, barrierVars,
          hostVars, injectVars, dataVars, outVars>>

\* ============================================================================
\* HELPER PREDICATES
\* ============================================================================

ErrorCodes == {kOk, kInvalidParams, kTimeout, kAbortObserved}

\* "Local status" derivation. Source: drain.hpp:144-163
LocalStatus(r) ==
    IF self_error[r] /= kOk THEN self_error[r]
    ELSE IF self_abort[r] = 1 THEN kAbortObserved
    ELSE kOk

\* CAS-from-kOk publish_error_and_abort. Source: drain.hpp:92-110
\* If self_error[r] = kOk, self_error becomes desired. Otherwise unchanged.
\* self_abort always becomes 1.
PublishErrorAndAbort(r, desired) ==
    /\ self_error' = [self_error EXCEPT
                        ![r] = IF self_error[r] = kOk THEN desired ELSE @]
    /\ self_abort' = [self_abort EXCEPT ![r] = 1]

\* Has rank r observed an abort signal from itself or its left neighbor?
\* Source: barrier_sm100.cuh:103-108 (AbortObservation::observed)
\*         smem.hpp:144-153  (wait_flag_warp hop propagation)
AbortObservation(r) ==
    \/ self_abort[r] = 1
    \/ self_abort[LeftOf(r)] = 1   \* read of peer_abort[left]

\* ============================================================================
\* INITIAL STATE
\* ============================================================================

Init ==
    /\ pc = [r \in Rank |-> "rs"]
    /\ rs_step = [r \in Rank |-> 0]
    /\ ag_step = [r \in Rank |-> 0]
    /\ rs_ok = [r \in Rank |-> TRUE]
    \* Initial data: each rank has its own contribution for every chunk.
    \* Source: caller-provided self_data buffer; abstracted as {r} per (r, c)
    /\ data = [r \in Rank |-> [c \in Chunk |->
                    IF c = OwnedChunk(r) THEN {r}
                    ELSE {r}]]
    \* Flags initialized to 0 (cleared by reset_rank_atomics_init_kernel).
    \* Source: vbt_ring_allreduce_plugin.cu:763, 770, 1010-1031
    /\ rs_ready = [r \in Rank |-> [s \in 1..NumSteps |-> [t \in 1..NumTiles |-> 0]]]
    /\ ag_ready = [r \in Rank |-> [s \in 0..NumSteps |-> [t \in 1..NumTiles |-> 0]]]
    /\ self_error = [r \in Rank |-> kOk]
    /\ self_abort = [r \in Rank |-> 0]
    /\ tiles_finished = [r \in Rank |-> 0]
    /\ barrier_gather_token = [r \in Rank |-> 0]
    /\ barrier_gather_status = [r \in Rank |-> kOk]
    /\ barrier_release_token = [r \in Rank |-> 0]
    /\ barrier_release_status = [r \in Rank |-> kOk]
    /\ gather_pc = [r \in Rank |-> "start"]
    /\ gather_incoming = [r \in Rank |-> Nil]
    /\ barrier_agg = [r \in Rank |-> kOk]
    /\ release_pc = [r \in Rank |-> "wait"]
    /\ release_broadcast = [r \in Rank |-> Nil]
    /\ release_timeouts_armed = [r \in Rank |-> 0]
    /\ out_status = [r \in Rank |-> Nil]
    /\ host_watchdog_fired = FALSE
    /\ host_freed = FALSE
    /\ inject_release_delay = [r \in Rank |-> 0]
    /\ inject_release_hang = [r \in Rank |-> 0]

\* ============================================================================
\* ACTIONS — REDUCE SCATTER PHASE
\* ============================================================================

\* Single RS-step action: combines wait (if s>0), peer-data add, and publish.
\* For s=0, no wait; the rank simply adds its left-neighbor's chunk
\*   chunk_rs(0) and publishes self_rs_ready[1].
\* For s in 1..NumSteps-1, the rank waits on peer_rs_ready[left][s] = epoch
\*   before performing the add and publishing self_rs_ready[s+1].
\* Source: kernel_sm100.cuh:485-583 ring_allreduce_sm100_tile_legacy_rs
RS_Step(r, s, t) ==
    /\ pc[r] = "rs"
    /\ rs_step[r] = s
    /\ s < NumSteps
    /\ rs_ok[r]
    \* If s>0: wait on peer_rs_ready[left][s][t] == epoch (acquire confirm).
    \* Source: kernel_sm100.cuh:491-509, smem.hpp:137-203
    /\ s > 0 => rs_ready[LeftOf(r)][s][t] = EpochValue
    \* Compute reduction: data[r][chunk_rs] := data[r][chunk_rs] U data[left][chunk_rs]
    \* Source: kernel_sm100.cuh:541-544 self_data[idx] = self_data[idx] + peer_left[idx]
    /\ LET c == ChunkRS(r, s) IN
        data' = [data EXCEPT ![r] =
                    [@ EXCEPT ![c] = data[r][c] \cup data[LeftOf(r)][c]]]
    \* Publish self_rs_ready[s+1][t] = epoch (release).
    \* Source: kernel_sm100.cuh:559-573
    /\ rs_ready' = [rs_ready EXCEPT ![r][s+1][t] = EpochValue]
    /\ rs_step' = [rs_step EXCEPT ![r] = s + 1]
    /\ pc' = [pc EXCEPT ![r] = IF s + 1 = NumSteps THEN "ag_pub0" ELSE "rs"]
    /\ UNCHANGED <<ag_step, rs_ok, ag_ready, errVars, drainVars,
                   barrierVars, hostVars, injectVars, outVars>>

\* RS bails out early because peer_left aborted (or self aborted).
\* In code, wait_flag returns false; rs_ok=false; AG is skipped.
\* Source: kernel_sm100.cuh:506-509 (rs_ok = false; break)
\*         smem.hpp:144-153 (hop-propagation: self_abort = 1 if l != 0)
RS_AbortBail(r, t) ==
    /\ pc[r] = "rs"
    /\ rs_step[r] > 0     \* only s>0 enters wait_flag (s=0 has no wait)
    /\ rs_step[r] < NumSteps
    /\ rs_ok[r]
    /\ AbortObservation(r)
    \* Hop propagation: if left aborted, set self_abort. Source: smem.hpp:148-151
    /\ self_abort' = [self_abort EXCEPT
                        ![r] = IF self_abort[LeftOf(r)] = 1 THEN 1 ELSE @]
    /\ rs_ok' = [rs_ok EXCEPT ![r] = FALSE]
    /\ pc' = [pc EXCEPT ![r] = "ag_pub0"]   \* still proceeds to epilogue
    /\ UNCHANGED <<rs_step, ag_step, dataVars, flagVars, self_error,
                   drainVars, barrierVars, hostVars, injectVars, outVars>>

\* RS times out waiting on peer_rs_ready[left][s][t]. Publishes kTimeout
\* via CAS-from-kOk and bails out (rs_ok=false).
\* Source: kernel_sm100.cuh:213-317 ring_allreduce_wait_flag (timeout branch),
\*         drain.hpp:92-110 publish_error_and_abort
RS_WaitTimeout(r, t) ==
    /\ pc[r] = "rs"
    /\ rs_step[r] > 0
    /\ rs_step[r] < NumSteps
    /\ rs_ok[r]
    /\ rs_ready[LeftOf(r)][rs_step[r]][t] /= EpochValue
    /\ PublishErrorAndAbort(r, kTimeout)
    /\ rs_ok' = [rs_ok EXCEPT ![r] = FALSE]
    /\ pc' = [pc EXCEPT ![r] = "ag_pub0"]
    /\ UNCHANGED <<rs_step, ag_step, dataVars, flagVars, drainVars,
                   barrierVars, hostVars, injectVars, outVars>>

\* ============================================================================
\* ACTIONS — ALL GATHER PHASE
\* ============================================================================

\* Publish self_ag_ready[0][t] = epoch UNCONDITIONALLY (regardless of self_abort).
\* This is the Family-2 bug surface: published even on aborted RS.
\* Source: kernel_sm100.cuh:602-617 (legacy AG step-0 publish)
\*         kernel_sm100.cuh:1619-1623, 2223-2225 (warp-specialized SMEM AG)
AG_PublishStep0(r, t) ==
    /\ pc[r] = "ag_pub0"
    \* Note: NO precondition that self_abort[r] = 0. This is intentional
    \* and matches the implementation; it is the mechanism behind Family 2.
    /\ ag_ready' = [ag_ready EXCEPT ![r][0][t] = EpochValue]
    /\ pc' = [pc EXCEPT ![r] =
                IF rs_ok[r] THEN "ag" ELSE "drain_signal"]
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, dataVars, rs_ready,
                   errVars, drainVars, barrierVars, hostVars,
                   injectVars, outVars>>

\* Single AG-step action: wait on peer_ag_ready[left][s][t], copy peer data
\* for ChunkAG(r,s), then publish self_ag_ready[s+1][t].
\* Source: kernel_sm100.cuh:623-727 ring_allreduce_sm100_tile_legacy_ag
AG_Step(r, s, t) ==
    /\ pc[r] = "ag"
    /\ ag_step[r] = s
    /\ s < NumSteps
    \* Wait on peer_ag_ready[left][s][t] == epoch.
    \* Source: kernel_sm100.cuh:629-645
    /\ ag_ready[LeftOf(r)][s][t] = EpochValue
    \* Copy: self_data[chunk_ag] := peer_left.data[chunk_ag]
    \* Source: kernel_sm100.cuh:675-678
    /\ LET c == ChunkAG(r, s) IN
        data' = [data EXCEPT ![r] = [@ EXCEPT ![c] = data[LeftOf(r)][c]]]
    \* Publish self_ag_ready[s+1][t] = epoch (modulo debug abort hooks).
    \* Source: kernel_sm100.cuh:704-722
    /\ ag_ready' = [ag_ready EXCEPT ![r][s+1][t] = EpochValue]
    /\ ag_step' = [ag_step EXCEPT ![r] = s + 1]
    /\ pc' = [pc EXCEPT ![r] = IF s + 1 = NumSteps THEN "drain_signal" ELSE "ag"]
    /\ UNCHANGED <<rs_step, rs_ok, rs_ready, errVars, drainVars,
                   barrierVars, hostVars, injectVars, outVars>>

\* Debug abort BEFORE publish. Source: kernel_sm100.cuh:711-714
\* Skips the ag_ready[s+1] publish; calls publish_error_and_abort(kAbortObserved).
\* Per Family 1/2: this can race with a later kTimeout from the barrier.
AG_DebugAbortBeforePublish(r, s, t) ==
    /\ pc[r] = "ag"
    /\ ag_step[r] = s
    /\ s < NumSteps
    /\ ag_ready[LeftOf(r)][s][t] = EpochValue
    /\ LET c == ChunkAG(r, s) IN
        data' = [data EXCEPT ![r] = [@ EXCEPT ![c] = data[LeftOf(r)][c]]]
    /\ PublishErrorAndAbort(r, kAbortObserved)
    /\ ag_step' = [ag_step EXCEPT ![r] = s + 1]
    /\ pc' = [pc EXCEPT ![r] = "drain_signal"]   \* break out of AG loop
    /\ UNCHANGED <<rs_step, rs_ok, rs_ready, ag_ready, drainVars,
                   barrierVars, hostVars, injectVars, outVars>>

\* Debug abort AFTER publish. Source: kernel_sm100.cuh:716-721
AG_DebugAbortAfterPublish(r, s, t) ==
    /\ pc[r] = "ag"
    /\ ag_step[r] = s
    /\ s < NumSteps
    /\ ag_ready[LeftOf(r)][s][t] = EpochValue
    /\ LET c == ChunkAG(r, s) IN
        data' = [data EXCEPT ![r] = [@ EXCEPT ![c] = data[LeftOf(r)][c]]]
    /\ ag_ready' = [ag_ready EXCEPT ![r][s+1][t] = EpochValue]
    /\ PublishErrorAndAbort(r, kAbortObserved)
    /\ ag_step' = [ag_step EXCEPT ![r] = s + 1]
    /\ pc' = [pc EXCEPT ![r] = "drain_signal"]
    /\ UNCHANGED <<rs_step, rs_ok, rs_ready, drainVars,
                   barrierVars, hostVars, injectVars, outVars>>

\* AG bails out early on observed abort (peer_ag_ready never sets).
\* Source: kernel_sm100.cuh:643-645 (got_peer = false; break)
\*         smem.hpp:144-153 hop-propagation
AG_AbortBail(r, t) ==
    /\ pc[r] = "ag"
    /\ ag_step[r] < NumSteps
    /\ AbortObservation(r)
    /\ self_abort' = [self_abort EXCEPT
                        ![r] = IF self_abort[LeftOf(r)] = 1 THEN 1 ELSE @]
    /\ pc' = [pc EXCEPT ![r] = "drain_signal"]
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, dataVars, flagVars, self_error,
                   drainVars, barrierVars, hostVars, injectVars, outVars>>

\* AG times out waiting on peer_ag_ready. Source: kernel_sm100.cuh:269-271 (wait_flag)
AG_WaitTimeout(r, t) ==
    /\ pc[r] = "ag"
    /\ ag_step[r] < NumSteps
    /\ ag_ready[LeftOf(r)][ag_step[r]][t] /= EpochValue
    /\ PublishErrorAndAbort(r, kTimeout)
    /\ pc' = [pc EXCEPT ![r] = "drain_signal"]
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, dataVars, flagVars, drainVars,
                   barrierVars, hostVars, injectVars, outVars>>

\* ============================================================================
\* ACTIONS — DRAIN PHASE
\* ============================================================================

\* signal_tile_finished: every CTA increments tiles_finished (CTA0 does it
\* via cta0_signal_and_drain). We model one tile per kernel; each rank
\* increments once before drain.
\* Source: drain.hpp:80-89 ring_allreduce_signal_tile_finished
\*         kernel_sm100.cuh:2513
SignalTileFinished(r) ==
    /\ pc[r] = "drain_signal"
    /\ tiles_finished' = [tiles_finished EXCEPT ![r] = @ + 1]
    /\ pc' = [pc EXCEPT ![r] = "drain"]
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, dataVars, flagVars, errVars,
                   barrierVars, hostVars, injectVars, outVars>>

\* Drain succeeds: tiles_finished[r] reached the expected count (NumTiles).
\* Source: drain.hpp:188-192 (done == expected_tiles, break)
\* In this spec each rank counts to NumTiles (one per CTA); we approximate
\* expected_tiles = NumTiles.
DrainComplete(r) ==
    /\ pc[r] = "drain"
    /\ tiles_finished[r] >= NumTiles
    /\ pc' = [pc EXCEPT ![r] = "barrier_gather"]
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, dataVars, flagVars, errVars,
                   drainVars, barrierVars, hostVars, injectVars, outVars>>

\* Drain timeout. The drain loop is NOT abort-responsive (Family 7):
\* it can spin out the full timeout_iters even if self_abort=1.
\* Source: drain.hpp:188-217 (no early-exit on self_abort)
DrainTimeout(r) ==
    /\ pc[r] = "drain"
    /\ tiles_finished[r] < NumTiles    \* still incomplete
    /\ PublishErrorAndAbort(r, kTimeout)
    /\ pc' = [pc EXCEPT ![r] = "barrier_gather"]   \* proceed (line 207)
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, dataVars, flagVars, drainVars,
                   barrierVars, hostVars, injectVars, outVars>>

\* ============================================================================
\* ACTIONS — BARRIER PHASE A (GATHER)
\* ============================================================================

\* Rank 0: publish own gather token first, then wait on left.
\* Source: barrier_sm100.cuh:261-278
BarrierGather_Rank0_Publish(r) ==
    /\ pc[r] = "barrier_gather"
    /\ RankIdx[r] = 0
    /\ gather_pc[r] = "start"
    /\ LET local == LocalStatus(r) IN
        /\ barrier_gather_status' = [barrier_gather_status EXCEPT ![r] = local]
        /\ barrier_gather_token' = [barrier_gather_token EXCEPT ![r] = EpochValue]
        /\ barrier_agg' = [barrier_agg EXCEPT ![r] = local]
    /\ gather_pc' = [gather_pc EXCEPT ![r] = "self_published"]
    /\ UNCHANGED <<phaseVars, flagVars, errVars, drainVars,
                   barrier_release_token, barrier_release_status,
                   release_pc, release_broadcast, release_timeouts_armed,
                   gather_incoming, hostVars, injectVars, dataVars, outVars>>

\* Rank 0: wait on left's gather token. On success, agg = left.status.
\* Source: barrier_sm100.cuh:265-277
BarrierGather_Rank0_WaitSucceed(r) ==
    /\ pc[r] = "barrier_gather"
    /\ RankIdx[r] = 0
    /\ gather_pc[r] = "self_published"
    /\ barrier_gather_token[LeftOf(r)] = EpochValue
    /\ barrier_agg' = [barrier_agg EXCEPT ![r] = barrier_gather_status[LeftOf(r)]]
    /\ pc' = [pc EXCEPT ![r] = "barrier_release"]
    /\ gather_pc' = [gather_pc EXCEPT ![r] = "left_received"]
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, flagVars, errVars, drainVars,
                   barrier_gather_token, barrier_gather_status,
                   barrier_release_token, barrier_release_status,
                   release_pc, release_broadcast, release_timeouts_armed,
                   gather_incoming, hostVars, injectVars, dataVars, outVars>>

\* Rank 0: gather wait times out. Publish kTimeout via CAS, then agg = local.
\* Source: barrier_sm100.cuh:155-158, 277 (r.got_token ? r.status : local)
BarrierGather_Rank0_WaitTimeout(r) ==
    /\ pc[r] = "barrier_gather"
    /\ RankIdx[r] = 0
    /\ gather_pc[r] = "self_published"
    /\ barrier_gather_token[LeftOf(r)] /= EpochValue
    /\ PublishErrorAndAbort(r, kTimeout)
    /\ barrier_agg' = [barrier_agg EXCEPT ![r] = LocalStatus(r)']
    /\ pc' = [pc EXCEPT ![r] = "barrier_release"]
    /\ gather_pc' = [gather_pc EXCEPT ![r] = "left_received"]
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, flagVars, drainVars,
                   barrier_gather_token, barrier_gather_status,
                   barrier_release_token, barrier_release_status,
                   release_pc, release_broadcast, release_timeouts_armed,
                   gather_incoming, hostVars, injectVars, dataVars, outVars>>

\* Non-zero rank: wait on left's gather token. Source: barrier_sm100.cuh:280-304
BarrierGather_Nonzero_WaitSucceed(r) ==
    /\ pc[r] = "barrier_gather"
    /\ RankIdx[r] /= 0
    /\ gather_pc[r] = "start"
    /\ barrier_gather_token[LeftOf(r)] = EpochValue
    /\ gather_incoming' = [gather_incoming EXCEPT
                            ![r] = barrier_gather_status[LeftOf(r)]]
    /\ gather_pc' = [gather_pc EXCEPT ![r] = "left_received"]
    /\ UNCHANGED <<phaseVars, flagVars, errVars, drainVars,
                   barrier_gather_token, barrier_gather_status,
                   barrier_release_token, barrier_release_status,
                   release_pc, release_broadcast, release_timeouts_armed,
                   barrier_agg, hostVars, injectVars, dataVars, outVars>>

\* Non-zero rank: gather wait times out. Source: barrier_sm100.cuh:292-298
\* Publishes kTimeout; forwards local_status as own gather output.
BarrierGather_Nonzero_WaitTimeout(r) ==
    /\ pc[r] = "barrier_gather"
    /\ RankIdx[r] /= 0
    /\ gather_pc[r] = "start"
    /\ barrier_gather_token[LeftOf(r)] /= EpochValue
    /\ PublishErrorAndAbort(r, kTimeout)
    /\ LET now == LocalStatus(r)' IN
        /\ barrier_gather_status' = [barrier_gather_status EXCEPT ![r] = now]
        /\ barrier_gather_token' = [barrier_gather_token EXCEPT ![r] = EpochValue]
        /\ barrier_agg' = [barrier_agg EXCEPT ![r] = now]
    /\ pc' = [pc EXCEPT ![r] = "barrier_release"]
    /\ gather_pc' = [gather_pc EXCEPT ![r] = "merged_published"]
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, flagVars, drainVars,
                   barrier_release_token, barrier_release_status,
                   release_pc, release_broadcast, release_timeouts_armed,
                   gather_incoming, hostVars, injectVars, dataVars, outVars>>

\* Non-zero rank: after receiving left.token, publish merged status forward.
\* Source: barrier_sm100.cuh:300-304
\*   agg = merge_status(local, incoming);
\*   self.gather_status = agg; self.gather_token = epoch (release).
BarrierGather_Nonzero_PublishMerged(r) ==
    /\ pc[r] = "barrier_gather"
    /\ RankIdx[r] /= 0
    /\ gather_pc[r] = "left_received"
    /\ gather_incoming[r] /= Nil
    /\ LET local == LocalStatus(r)
           agg == MergeStatus(local, gather_incoming[r])
        IN
        /\ barrier_gather_status' = [barrier_gather_status EXCEPT ![r] = agg]
        /\ barrier_gather_token' = [barrier_gather_token EXCEPT ![r] = EpochValue]
        /\ barrier_agg' = [barrier_agg EXCEPT ![r] = agg]
    /\ pc' = [pc EXCEPT ![r] = "barrier_release"]
    /\ gather_pc' = [gather_pc EXCEPT ![r] = "merged_published"]
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, flagVars, errVars, drainVars,
                   barrier_release_token, barrier_release_status,
                   release_pc, release_broadcast, release_timeouts_armed,
                   gather_incoming, hostVars, injectVars, dataVars, outVars>>

\* ============================================================================
\* ACTIONS — BARRIER PHASE B (RELEASE)
\* ============================================================================

\* Rank 0: publish release_status = final_status (=agg), release_token = epoch.
\* Then begins waiting on left's release token. The wait timeouts are
\* DISABLED if final_status == kOk (rank-0 trusts the lap; Family 3 hazard).
\* Source: barrier_sm100.cuh:310-315
BarrierRelease_Rank0_Publish(r) ==
    /\ pc[r] = "barrier_release"
    /\ RankIdx[r] = 0
    /\ release_pc[r] = "wait"
    /\ barrier_release_status' = [barrier_release_status EXCEPT
                                    ![r] = barrier_agg[r]]
    /\ barrier_release_token' = [barrier_release_token EXCEPT
                                    ![r] = EpochValue]
    /\ release_pc' = [release_pc EXCEPT ![r] = "got_token"]   \* enter wait
    /\ UNCHANGED <<phaseVars, flagVars, errVars, drainVars,
                   barrier_gather_token, barrier_gather_status,
                   gather_pc, gather_incoming, barrier_agg,
                   release_broadcast, release_timeouts_armed,
                   hostVars, injectVars, dataVars, outVars>>

\* Rank 0: release wait succeeds (left published its release token).
\* Source: barrier_sm100.cuh:317-327
BarrierRelease_Rank0_WaitSucceed(r) ==
    /\ pc[r] = "barrier_release"
    /\ RankIdx[r] = 0
    /\ release_pc[r] = "got_token"
    /\ barrier_release_token[LeftOf(r)] = EpochValue
    /\ pc' = [pc EXCEPT ![r] = "barrier_latch"]
    /\ release_pc' = [release_pc EXCEPT ![r] = "forwarded"]
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, flagVars, errVars, drainVars,
                   barrier_gather_token, barrier_gather_status,
                   barrier_release_token, barrier_release_status,
                   gather_pc, gather_incoming, barrier_agg,
                   release_broadcast, release_timeouts_armed,
                   hostVars, injectVars, dataVars, outVars>>

\* Rank 0: release wait times out. Only possible if final_status (= agg) /= kOk.
\* Source: barrier_sm100.cuh:314-315 (timeouts_enabled = (final_status != kOk))
BarrierRelease_Rank0_WaitTimeout(r) ==
    /\ pc[r] = "barrier_release"
    /\ RankIdx[r] = 0
    /\ release_pc[r] = "got_token"
    /\ barrier_agg[r] /= kOk    \* Source: barrier_sm100.cuh:315
    /\ barrier_release_token[LeftOf(r)] /= EpochValue
    /\ PublishErrorAndAbort(r, kTimeout)
    /\ pc' = [pc EXCEPT ![r] = "barrier_latch"]
    /\ release_pc' = [release_pc EXCEPT ![r] = "forwarded"]
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, flagVars, drainVars,
                   barrier_gather_token, barrier_gather_status,
                   barrier_release_token, barrier_release_status,
                   gather_pc, gather_incoming, barrier_agg,
                   release_broadcast, release_timeouts_armed,
                   hostVars, injectVars, dataVars, outVars>>

\* Non-zero rank: arm release wait timeouts upon abort observation.
\* Source: barrier_sm100.cuh:343-349
BarrierRelease_Nonzero_ArmTimeouts(r) ==
    /\ pc[r] = "barrier_release"
    /\ RankIdx[r] /= 0
    /\ release_pc[r] = "wait"
    /\ release_timeouts_armed[r] = 0
    /\ AbortObservation(r)
    /\ release_timeouts_armed' = [release_timeouts_armed EXCEPT ![r] = 1]
    /\ UNCHANGED <<phaseVars, flagVars, errVars, drainVars, barrier_gather_token,
                   barrier_gather_status, barrier_release_token,
                   barrier_release_status, gather_pc, gather_incoming,
                   barrier_agg, release_pc, release_broadcast,
                   hostVars, injectVars, dataVars, outVars>>

\* Non-zero rank: release wait succeeds (left's release token observed).
\* Source: barrier_sm100.cuh:342-385
BarrierRelease_Nonzero_WaitSucceed(r) ==
    /\ pc[r] = "barrier_release"
    /\ RankIdx[r] /= 0
    /\ release_pc[r] = "wait"
    /\ barrier_release_token[LeftOf(r)] = EpochValue
    \* Acquire-confirm. Source: barrier_sm100.cuh:378-382
    /\ release_broadcast' = [release_broadcast EXCEPT
                              ![r] = barrier_release_status[LeftOf(r)]]
    /\ release_pc' = [release_pc EXCEPT ![r] = "got_token"]
    /\ UNCHANGED <<phaseVars, flagVars, errVars, drainVars,
                   barrier_gather_token, barrier_gather_status,
                   barrier_release_token, barrier_release_status,
                   gather_pc, gather_incoming, barrier_agg,
                   release_timeouts_armed, hostVars, injectVars,
                   dataVars, outVars>>

\* Non-zero rank: release wait times out (only after timeouts armed).
\* Source: barrier_sm100.cuh:351-366
\*   publish_error_and_abort(kTimeout); republish self.release_token best-effort.
BarrierRelease_Nonzero_WaitTimeout(r) ==
    /\ pc[r] = "barrier_release"
    /\ RankIdx[r] /= 0
    /\ release_pc[r] = "wait"
    /\ release_timeouts_armed[r] = 1
    /\ barrier_release_token[LeftOf(r)] /= EpochValue
    /\ PublishErrorAndAbort(r, kTimeout)
    \* Republish self release for liveness. Source: barrier_sm100.cuh:361-363
    /\ LET now == LocalStatus(r)' IN
        /\ barrier_release_status' = [barrier_release_status EXCEPT ![r] = now]
        /\ barrier_release_token' = [barrier_release_token EXCEPT ![r] = EpochValue]
    /\ pc' = [pc EXCEPT ![r] = "epilogue"]   \* skip latch — return directly
    /\ release_pc' = [release_pc EXCEPT ![r] = "forwarded"]
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, flagVars, drainVars,
                   barrier_gather_token, barrier_gather_status,
                   gather_pc, gather_incoming, barrier_agg,
                   release_broadcast, release_timeouts_armed,
                   hostVars, injectVars, dataVars, outVars>>

\* Non-zero rank: forward broadcast. Must-forward exactly once even on abort.
\* Source: barrier_sm100.cuh:395-397 (release_status=broadcast; release_token=epoch)
BarrierRelease_Nonzero_Forward(r) ==
    /\ pc[r] = "barrier_release"
    /\ RankIdx[r] /= 0
    /\ release_pc[r] = "got_token"
    /\ release_broadcast[r] /= Nil
    /\ barrier_release_status' = [barrier_release_status EXCEPT
                                    ![r] = release_broadcast[r]]
    /\ barrier_release_token' = [barrier_release_token EXCEPT ![r] = EpochValue]
    /\ pc' = [pc EXCEPT ![r] = "barrier_latch"]
    /\ release_pc' = [release_pc EXCEPT ![r] = "forwarded"]
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, flagVars, errVars, drainVars,
                   barrier_gather_token, barrier_gather_status,
                   gather_pc, gather_incoming, barrier_agg,
                   release_broadcast, release_timeouts_armed,
                   hostVars, injectVars, dataVars, outVars>>

\* ============================================================================
\* ACTIONS — BARRIER LATCH (Family 1: CAS-from-kOk defeats elevation)
\* ============================================================================

\* Latch the post-barrier broadcast/final_status into self_error/abort via
\* publish_error_and_abort, which uses CAS expecting kOk.
\*
\* Source: barrier_sm100.cuh:330-332 (rank 0):
\*           if (final_status != kOk) publish_error_and_abort(self, ..., final_status);
\*         barrier_sm100.cuh:400-402 (non-zero rank):
\*           if (broadcast != kOk) publish_error_and_abort(self, ..., broadcast);
\*
\* Bug Family 1: if self_error[r] was already non-kOk (e.g., kAbortObserved
\* from hop-propagation in RS/AG), the CAS fails and the higher-precedence
\* broadcast does NOT elevate self_error[r]. The kernel epilogue then writes
\* out_status[r] = LocalStatus(r), which can disagree across ranks.
BarrierLatch(r) ==
    /\ pc[r] = "barrier_latch"
    /\ LET broadcast ==
            IF RankIdx[r] = 0 THEN barrier_agg[r]
            ELSE release_broadcast[r]
        IN
        IF broadcast /= kOk THEN
            \* CAS-from-kOk semantics. Source: drain.hpp:102-110
            /\ PublishErrorAndAbort(r, broadcast)
        ELSE
            \* No latch when broadcast = kOk. Source: barrier_sm100.cuh:330,400
            /\ UNCHANGED errVars
    /\ pc' = [pc EXCEPT ![r] = "epilogue"]
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, flagVars, drainVars,
                   barrierVars, hostVars, injectVars, dataVars, outVars>>

\* ============================================================================
\* ACTIONS — KERNEL EPILOGUE: WRITE OUT_STATUS
\* ============================================================================

\* Write out_status[r] = local_status(self_abort, self_error).
\* Source: kernel_sm100.cuh:2543-2545
\* Note: this reads LocalStatus(r) in the post-latch state. Ranks may disagree
\* due to Family 1.
KernelEpilogue(r) ==
    /\ pc[r] = "epilogue"
    /\ out_status' = [out_status EXCEPT ![r] = LocalStatus(r)]
    /\ pc' = [pc EXCEPT ![r] = "done"]
    /\ UNCHANGED <<rs_step, ag_step, rs_ok, flagVars, errVars, drainVars,
                   barrierVars, hostVars, injectVars, dataVars>>

\* ============================================================================
\* ACTIONS — HOST-SIDE WATCHDOG (Family 5)
\* ============================================================================

\* Host watchdog fires before all ranks have written out_status. The Family-5
\* PROPOSED STRENGTHENING is that the host MUST poison self_abort on every
\* rank before returning. This action models the strengthened, correct
\* behavior. The actual code skips this — see Family 5 in the brief.
\*
\* Source: vbt_ring_allreduce_plugin.cu:1067-1071 (current behavior: skip)
\*         Brief Family 5 §"Suggested modeling approach": signal abort on all ranks
HostWatchdogFire ==
    /\ ~host_watchdog_fired
    /\ \E r \in Rank : pc[r] /= "done"   \* still running
    /\ host_watchdog_fired' = TRUE
    /\ self_abort' = [r \in Rank |-> 1]
    /\ UNCHANGED <<phaseVars, flagVars, self_error, drainVars, barrierVars,
                   host_freed, injectVars, dataVars, outVars>>

\* Host frees per-call atomics. NoUseAfterFreeHost: only after every rank
\* has reached "done". Source: vbt_ring_allreduce_plugin.cu:1035 + comment
HostFreeResources ==
    /\ ~host_freed
    /\ \A r \in Rank : pc[r] = "done"
    /\ host_freed' = TRUE
    /\ UNCHANGED <<phaseVars, flagVars, errVars, drainVars, barrierVars,
                   host_watchdog_fired, injectVars, dataVars, outVars>>

\* ============================================================================
\* NEXT
\* ============================================================================

Next ==
    \/ \E r \in Rank, t \in 1..NumTiles, s \in 0..NumSteps - 1 : RS_Step(r, s, t)
    \/ \E r \in Rank, t \in 1..NumTiles : RS_AbortBail(r, t)
    \/ \E r \in Rank, t \in 1..NumTiles : RS_WaitTimeout(r, t)
    \/ \E r \in Rank, t \in 1..NumTiles : AG_PublishStep0(r, t)
    \/ \E r \in Rank, t \in 1..NumTiles, s \in 0..NumSteps - 1 : AG_Step(r, s, t)
    \/ \E r \in Rank, t \in 1..NumTiles, s \in 0..NumSteps - 1 :
            AG_DebugAbortBeforePublish(r, s, t)
    \/ \E r \in Rank, t \in 1..NumTiles, s \in 0..NumSteps - 1 :
            AG_DebugAbortAfterPublish(r, s, t)
    \/ \E r \in Rank, t \in 1..NumTiles : AG_AbortBail(r, t)
    \/ \E r \in Rank, t \in 1..NumTiles : AG_WaitTimeout(r, t)
    \/ \E r \in Rank : SignalTileFinished(r)
    \/ \E r \in Rank : DrainComplete(r)
    \/ \E r \in Rank : DrainTimeout(r)
    \/ \E r \in Rank : BarrierGather_Rank0_Publish(r)
    \/ \E r \in Rank : BarrierGather_Rank0_WaitSucceed(r)
    \/ \E r \in Rank : BarrierGather_Rank0_WaitTimeout(r)
    \/ \E r \in Rank : BarrierGather_Nonzero_WaitSucceed(r)
    \/ \E r \in Rank : BarrierGather_Nonzero_WaitTimeout(r)
    \/ \E r \in Rank : BarrierGather_Nonzero_PublishMerged(r)
    \/ \E r \in Rank : BarrierRelease_Rank0_Publish(r)
    \/ \E r \in Rank : BarrierRelease_Rank0_WaitSucceed(r)
    \/ \E r \in Rank : BarrierRelease_Rank0_WaitTimeout(r)
    \/ \E r \in Rank : BarrierRelease_Nonzero_ArmTimeouts(r)
    \/ \E r \in Rank : BarrierRelease_Nonzero_WaitSucceed(r)
    \/ \E r \in Rank : BarrierRelease_Nonzero_WaitTimeout(r)
    \/ \E r \in Rank : BarrierRelease_Nonzero_Forward(r)
    \/ \E r \in Rank : BarrierLatch(r)
    \/ \E r \in Rank : KernelEpilogue(r)
    \/ HostWatchdogFire
    \/ HostFreeResources

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* INVARIANTS — Standard / structural
\* ============================================================================

\* Type invariant.
TypeOK ==
    /\ pc \in [Rank -> {"rs", "ag_pub0", "ag", "drain_signal", "drain",
                        "barrier_gather", "barrier_release",
                        "barrier_latch", "epilogue", "done"}]
    /\ rs_step \in [Rank -> 0..NumSteps]
    /\ ag_step \in [Rank -> 0..NumSteps]
    /\ rs_ok \in [Rank -> BOOLEAN]
    /\ self_error \in [Rank -> ErrorCodes]
    /\ self_abort \in [Rank -> 0..1]
    /\ tiles_finished \in [Rank -> Nat]
    /\ barrier_gather_token \in [Rank -> Nat]
    /\ barrier_release_token \in [Rank -> Nat]
    /\ out_status \in [Rank -> ErrorCodes \cup {Nil}]

\* Per-tile flag monotonicity. Each rs_ready / ag_ready flag transitions at
\* most once per epoch (0 -> EpochValue). Once non-zero, stays equal to epoch.
\* (No clear-between-epochs semantics in this run, but checks the structural
\* invariant intra-run.)
\* Source: per Family 6 — equality check semantics.
PerTileMonotonicity ==
    \A r \in Rank, t \in 1..NumTiles :
        /\ \A s \in 1..NumSteps :
                rs_ready[r][s][t] \in {0, EpochValue}
        /\ \A s \in 0..NumSteps :
                ag_ready[r][s][t] \in {0, EpochValue}

\* Status precedence is well-formed: kInvalidParams > kTimeout > kAbortObserved > kOk.
\* MergeStatus(a,b) is at least as precedent as either a or b.
StatusMergeMonotonicity ==
    \A a, b \in ErrorCodes :
        LET m == MergeStatus(a, b) IN
        /\ MergeStatus(m, a) = m
        /\ MergeStatus(m, b) = m

\* ============================================================================
\* INVARIANTS — Bug-family targeting
\* ============================================================================

\* Helper: rank r has finished writing out_status.
Finished(r) == out_status[r] /= Nil

\* --- Family 1: Status coherence under abort/timeout interleavings ---
\*
\* AgreementOnKOk (Brief §5): If any rank wrote out_status[r]=kOk, every rank
\* that has finished must also have written kOk. (We must allow some ranks
\* to still be running — only check among finished ranks.)
AgreementOnKOk ==
    \A r1, r2 \in Rank :
        (Finished(r1) /\ Finished(r2) /\ out_status[r1] = kOk)
            => out_status[r2] = kOk

\* StatusCoherence (Brief §5): All finished ranks return identical out_status.
\* Family 1 expects this to be VIOLATED under fault injection.
StatusCoherence ==
    \A r1, r2 \in Rank :
        (Finished(r1) /\ Finished(r2)) => out_status[r1] = out_status[r2]

\* StatusElevation (Brief §5): If any rank's barrier_agg = E /= kOk, then
\* every rank that has finished latching must have self_error >=_precedence E.
\* Family 1 expects this to be VIOLATED.
PrecedenceLeq(a, b) == MergeStatus(a, b) = b

StatusElevation ==
    \A r1, r2 \in Rank :
        (RankIdx[r1] = 0 /\ pc[r2] \in {"epilogue", "done"})
            => PrecedenceLeq(barrier_agg[r1], MergeStatus(self_error[r2],
                  IF self_abort[r2] = 1 THEN kAbortObserved ELSE kOk))

\* --- Family 2: AG step-0 publish under concurrent abort ---
\*
\* AgReady0ImpliesFinalOrAbort (Brief §5):
\* ag_ready[r][0][t] = epoch  =>  data[r][OwnedChunk(r)] is fully reduced
\*                                   (= Rank), OR self_abort[r] = 1.
AgReady0ImpliesFinalOrAbort ==
    \A r \in Rank, t \in 1..NumTiles :
        ag_ready[r][0][t] = EpochValue =>
            \/ data[r][OwnedChunk(r)] = Rank
            \/ self_abort[r] = 1

\* --- Baseline correctness ---
\*
\* OwnedChunkFinalOnKOk: on the all-kOk terminal state, every rank's
\* owned chunk is fully reduced. (Pre-AG view; AG copies overwrite later.)
OwnedChunkFinalOnKOk ==
    (\A r \in Rank : Finished(r) /\ out_status[r] = kOk)
        => \A r \in Rank : data[r][OwnedChunk(r)] = Rank

\* On all-kOk terminal, every rank holds the fully reduced data for every
\* chunk (post-AG). Source: README — all-reduce semantics.
AllReduceCorrectness ==
    (\A r \in Rank : Finished(r) /\ out_status[r] = kOk)
        => \A r \in Rank, c \in Chunk : data[r][c] = Rank

\* --- Family 6: Epoch-equality flag freshness ---
\*
\* FreshnessInvariant: Any flag observed = EpochValue was published in this
\* epoch. We approximate by asserting flags only ever transition from 0 to
\* EpochValue (never to StaleEpoch) in this single-run model. The MC spec
\* additionally injects a stale flag value to test this invariant.
FreshnessInvariant ==
    \A r \in Rank, t \in 1..NumTiles :
        /\ \A s \in 1..NumSteps : rs_ready[r][s][t] /= StaleEpoch
        /\ \A s \in 0..NumSteps : ag_ready[r][s][t] /= StaleEpoch

\* --- Family 5: Host watchdog poisons all ranks before returning ---
WatchdogPoisons ==
    host_watchdog_fired => \A r \in Rank : self_abort[r] = 1

\* NoHostUAF: host_freed only after all ranks done.
NoHostUAF == host_freed => \A r \in Rank : pc[r] = "done"

\* --- Structural: RS publishes monotonically per step ---
RsPublishMonotonic ==
    \A r \in Rank, t \in 1..NumTiles, s \in 1..NumSteps :
        rs_ready[r][s][t] = EpochValue => rs_step[r] >= s

\* --- Structural: drain counter bounded by # CTAs (== NumTiles in this model) ---
DrainCounterBound ==
    \A r \in Rank : tiles_finished[r] <= NumTiles

\* ============================================================================
\* TEMPORAL PROPERTIES (liveness)
\* ============================================================================

\* Liveness: Every rank eventually writes out_status. Targets Family 3 + 7.
\* Requires fairness (added in MC).
EventuallyAllFinish == <>(\A r \in Rank : Finished(r))

\* AbortPropagation: once any rank aborts, eventually all ranks have abort=1.
\* Targets Family 3 hop-propagation guarantee.
AbortPropagation ==
    [](\E r \in Rank : self_abort[r] = 1
        => <>(\A r2 \in Rank : self_abort[r2] = 1))

==============================================================================
