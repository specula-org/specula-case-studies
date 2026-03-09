---------------------------- MODULE MC_hunt ----------------------------
\* Bug hunting MC spec for Substrate GRANDPA
\* Tests MC-1 (root-only vote limit) and MC-2 (root-only forced change deps)
\* Uses correct base spec behavior + detection invariants to find where
\* the implementation diverges from correct behavior.

EXTENDS MC

\* ================================================================
\* Root change detection
\* In the implementation, pending standard changes are stored in a ForkTree.
\* The ForkTree mirrors the block tree: if change A's block is an ancestor
\* of change B's block, then A is B's parent in the ForkTree.
\* A "root" is a change with no parent in the ForkTree.
\* ================================================================

\* A pending standard change is a "root" in the ForkTree if no other
\* pending standard change's block is a proper ancestor of its block.
\* Since blocks are unique per change (AddStandardChange prevents duplicates),
\* other /= c implies other.block /= c.block.
IsRootStandardChange(c, ps) ==
    ~\E other \in ps :
        /\ other /= c
        /\ IsAncestor(other.block, c.block, blockTree)

\* ================================================================
\* MC-1: Vote limit computed from roots only (implementation bug)
\* authorities.rs:423-429 — current_limit only checks ForkTree roots
\*
\* The implementation's current_limit() iterates only the roots of the
\* ForkTree to find the minimum effective number. Non-root changes
\* (children in the ForkTree) with lower effective numbers are MISSED.
\*
\* The correct behavior (in the spec) checks ALL pending changes.
\* This invariant detects when the two computations diverge.
\* ================================================================

\* Implementation-faithful vote limit: only considers root changes
ImplComputeVoteLimitOf(ps, fb) ==
    LET roots == {c \in ps : IsRootStandardChange(c, ps)}
        effectiveNums == {EffectiveNumber(c) : c \in roots}
        validNums == {n \in effectiveNums : n >= fb}
    IN IF validNums = {} THEN MaxBlock + 1
       ELSE CHOOSE n \in validNums : \A m \in validNums : n <= m

\* Correct vote limit (from base spec): checks ALL changes
CorrectComputeVoteLimitOf(ps, fb) ==
    ComputeVoteLimitOf(ps, fb)

\* Detection invariant: implementation's root-only limit matches correct all-changes limit
\* VIOLATION means implementation allows a HIGHER vote limit than correct,
\* i.e., honest nodes could vote past a non-root pending change boundary.
\* This directly corresponds to authorities.rs:423-429 bug.
VoteLimitImplMatchesCorrect ==
    \A s \in Server :
        ~crashed[s] =>
        ImplComputeVoteLimitOf(pendingStandard[s], finalizedBlock[s]) =
        CorrectComputeVoteLimitOf(pendingStandard[s], finalizedBlock[s])

\* Stronger version: the implementation limit is never MORE permissive
\* (i.e., never higher) than the correct limit
VoteLimitImplNotTooPermissive ==
    \A s \in Server :
        ~crashed[s] =>
        ImplComputeVoteLimitOf(pendingStandard[s], finalizedBlock[s]) <=
        CorrectComputeVoteLimitOf(pendingStandard[s], finalizedBlock[s])

\* ================================================================
\* MC-2: Forced change dependency check on roots only (implementation bug)
\* authorities.rs:478-492 — dependency check only examines root standard changes
\*
\* The implementation's forced change dependency check only looks at
\* ROOT standard changes in the ForkTree. A non-root standard change
\* with effective_number <= median_last_finalized could be missed,
\* allowing a forced change to be applied prematurely.
\* ================================================================

\* Implementation-faithful dependency check: only examines root standard changes
ImplForcedChangeDepsOk(s, fc) ==
    LET roots == {sc \in pendingStandard[s] : IsRootStandardChange(sc, pendingStandard[s])}
    IN \A sc \in roots :
        ~(EffectiveNumber(sc) <= fc.medianFinalized
          /\ IsAncestor(sc.block, fc.block, blockTree))

\* Detection invariant: implementation's root-only dep check is safe
\* VIOLATION means the implementation would allow a forced change despite
\* an unsatisfied non-root standard change dependency.
\* ImplForcedChangeDepsOk says "OK" but ForcedChangeDepsOk (full check) says "NOT OK"
ForcedChangeDepsImplSafe ==
    \A s \in Server :
        ~crashed[s] =>
        \A fc \in pendingForced[s] :
            ImplForcedChangeDepsOk(s, fc) => ForcedChangeDepsOk(s, fc)

=============================================================================
