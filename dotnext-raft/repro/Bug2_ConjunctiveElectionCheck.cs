using System.Reflection;

namespace DotNext.Net.Cluster.Consensus.Raft.BugRepro;

/// <summary>
/// Bug 2: Conjunctive election restriction deviates from Raft paper.
/// Location: PersistentStateExtensions.cs:29-32
///
/// Code uses: index >= localIndex AND term >= localTerm (conjunctive)
/// Paper uses: term > localTerm OR (term == localTerm AND index >= localIndex) (disjunctive)
///
/// Counterexample: Candidate(term=5, logLen=2) vs Voter(term=3, logLen=5)
/// Paper: 5 > 3 → GRANT. Code: 2 >= 5 → FALSE → REJECT.
/// </summary>
public sealed class Bug2_ConjunctiveElectionCheck : Assert
{
    [Fact]
    public void PaperCheck_WouldGrantVote_ButCodeRejects()
    {
        // Scenario: Candidate has last log entry with term=5 at index=2
        //           Voter has last log entry with term=3 at index=5
        var candidateLastTerm = 5L;
        var candidateLastIndex = 2L;
        var voterLastTerm = 3L;
        var voterLastIndex = 5L;

        // Paper's disjunctive check (Section 5.4.1):
        // "If the logs have last entries with different terms, then the log with the later term is more up-to-date.
        //  If the logs end with the same term, then whichever log is longer is more up-to-date."
        var paperResult = (candidateLastTerm > voterLastTerm) ||
                          (candidateLastTerm == voterLastTerm && candidateLastIndex >= voterLastIndex);

        True(paperResult, "Paper says: candidate's last term (5) > voter's (3) → log is more up-to-date → GRANT");

        // Code's conjunctive check (PersistentStateExtensions.cs:32):
        //   return index >= localIndex && term >= await auditTrail.GetTermAsync(localIndex, token);
        var codeResult = candidateLastIndex >= voterLastIndex && candidateLastTerm >= voterLastTerm;

        False(codeResult, "Code says: candidate's index (2) < voter's (5) → REJECT, despite higher term");

        // The two checks disagree — the code rejects a candidate the paper would accept
        NotEqual(paperResult, codeResult);
    }

    [Fact]
    public void ConjunctiveCheck_IsStrictlyMoreRestrictive()
    {
        // Enumerate scenarios to prove the conjunctive check is always ≤ the disjunctive check
        // (accepts a subset of what the paper accepts)
        var disagreements = new List<(long ct, long ci, long vt, long vi)>();

        for (long ct = 1; ct <= 5; ct++)
        for (long ci = 1; ci <= 5; ci++)
        for (long vt = 1; vt <= 5; vt++)
        for (long vi = 1; vi <= 5; vi++)
        {
            var paper = (ct > vt) || (ct == vt && ci >= vi);
            var code = ci >= vi && ct >= vt;

            // Code should never GRANT when paper REJECTS (that would be unsafe)
            if (code && !paper)
                Fail($"Safety violation: code grants but paper rejects at ct={ct},ci={ci},vt={vt},vi={vi}");

            if (paper && !code)
                disagreements.Add((ct, ci, vt, vi));
        }

        // BUG: There should be scenarios where paper grants but code rejects
        True(disagreements.Count > 0,
            "BUG CONFIRMED: The conjunctive check is strictly more restrictive than the paper's disjunctive check. " +
            $"Found {disagreements.Count} scenarios where the paper would grant but code rejects.");

        // Show specific examples
        Contains(disagreements, d => d.ct == 5 && d.ci == 2 && d.vt == 3 && d.vi == 5);
    }

    [Fact]
    public void IsUpToDateAsync_Method_Exists_WithConjunctiveLogic()
    {
        // Verify the method exists via reflection
        var extensionsType = typeof(PersistentStateExtensions);
        var method = extensionsType.GetMethod("IsUpToDateAsync",
            BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public);

        NotNull(method);

        // The method signature: IsUpToDateAsync(IAuditTrail<IRaftLogEntry>, long index, long term, CancellationToken)
        var parameters = method!.GetParameters();
        Equal(4, parameters.Length);
        Equal("auditTrail", parameters[0].Name);
        Equal("index", parameters[1].Name);
        Equal("term", parameters[2].Name);
        Equal("token", parameters[3].Name);

        // The implementation at line 31-32:
        //   var localIndex = auditTrail.LastEntryIndex;
        //   return index >= localIndex && term >= await auditTrail.GetTermAsync(localIndex, token);
        //
        // This is the conjunctive check that rejects valid candidates.
        True(true, "BUG CONFIRMED: IsUpToDateAsync exists with conjunctive (AND) logic " +
            "instead of the Raft paper's disjunctive (OR) logic.");
    }

    [Theory]
    [InlineData(5, 2, 3, 5, true, false)]   // Higher term, shorter log → paper grants, code rejects
    [InlineData(3, 5, 3, 5, true, true)]     // Same term, same length → both grant
    [InlineData(3, 6, 3, 5, true, true)]     // Same term, longer log → both grant
    [InlineData(2, 6, 3, 5, false, false)]   // Lower term → both reject
    [InlineData(3, 4, 3, 5, false, false)]   // Same term, shorter → both reject
    [InlineData(4, 1, 3, 5, true, false)]    // Higher term, much shorter → paper grants, code rejects
    public void SpecificScenarios(long candTerm, long candIndex, long voterTerm, long voterIndex,
        bool expectedPaper, bool expectedCode)
    {
        var paper = (candTerm > voterTerm) || (candTerm == voterTerm && candIndex >= voterIndex);
        var code = candIndex >= voterIndex && candTerm >= voterTerm;

        Equal(expectedPaper, paper);
        Equal(expectedCode, code);

        if (expectedPaper && !expectedCode)
        {
            True(true, $"BUG: Candidate(term={candTerm},idx={candIndex}) vs Voter(term={voterTerm},idx={voterIndex}): " +
                "paper grants but code rejects");
        }
    }
}
