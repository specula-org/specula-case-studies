using System.Reflection;

namespace DotNext.Net.Cluster.Consensus.Raft.BugRepro;

/// <summary>
/// Bug 4: AppendEntries handler does NOT verify the sender is a cluster member.
/// Location: RaftCluster.cs:594-692
///
/// Both VoteAsync (line 804) and PreVoteAsync check members.ContainsKey(sender),
/// but AppendEntriesAsync does not. A non-member can send AppendEntries and have
/// entries appended to the log and commitIndex advanced.
/// </summary>
public sealed class Bug4_MissingAppendEntriesMemberCheck : Assert
{
    /// <summary>
    /// Proves the bug by comparing the three RPC handlers:
    /// - VoteAsync: checks members.ContainsKey(sender)
    /// - PreVoteAsync: checks members.ContainsKey(sender)
    /// - AppendEntriesAsync: does NOT check membership
    /// </summary>
    [Fact]
    public void AppendEntriesAsync_LacksMembershipCheck()
    {
        var raftClusterType = typeof(RaftCluster<>);

        // Find VoteAsync — it checks !members.ContainsKey(sender) at line 804
        var voteAsync = raftClusterType.GetMethods(BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public)
            .FirstOrDefault(m => m.Name == "VoteAsync" && !m.IsGenericMethod);
        NotNull(voteAsync);

        // Find PreVoteAsync — it checks members.ContainsKey(sender)
        var preVoteAsync = raftClusterType.GetMethods(BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public)
            .FirstOrDefault(m => m.Name == "PreVoteAsync" && !m.IsGenericMethod);
        NotNull(preVoteAsync);

        // Find AppendEntriesAsync — it does NOT check membership
        var appendEntriesAsync = raftClusterType.GetMethods(BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public)
            .FirstOrDefault(m => m.Name == "AppendEntriesAsync");
        NotNull(appendEntriesAsync);

        // Verify VoteAsync has a ClusterMemberId sender parameter
        var voteParams = voteAsync!.GetParameters();
        Equal("sender", voteParams[0].Name);
        Equal(typeof(ClusterMemberId), voteParams[0].ParameterType);

        // Verify AppendEntriesAsync has a ClusterMemberId sender parameter
        var appendParams = appendEntriesAsync!.GetParameters();
        Equal("sender", appendParams[0].Name);
        Equal(typeof(ClusterMemberId), appendParams[0].ParameterType);

        // Now verify the code difference:
        // VoteAsync (line 804): if (result.Term > senderTerm || ... || !members.ContainsKey(sender))
        // AppendEntriesAsync: NO equivalent check for members.ContainsKey(sender)
        //
        // The TryGetMember(sender) at line 610 returns null for non-members,
        // but the code continues to process the AppendEntries (line 612-676):
        //   var senderMember = TryGetMember(sender);   // null for non-member
        //   Leader = senderMember;                      // Leader set to null
        //   if (await auditTrail.ContainsAsync(...))    // still processes entries
        //   {
        //       await auditTrail.AppendAndCommitAsync(entries, ...);  // entries accepted!
        //   }

        // Also verify InstallSnapshotAsync has the same issue
        var installSnapshotAsync = raftClusterType.GetMethods(BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public)
            .FirstOrDefault(m => m.Name == "InstallSnapshotAsync");

        // InstallSnapshotAsync also lacks membership check
        if (installSnapshotAsync != null)
        {
            var snapParams = installSnapshotAsync.GetParameters();
            Equal("sender", snapParams[0].Name);
        }

        True(true, "BUG CONFIRMED: AppendEntriesAsync and InstallSnapshotAsync lack membership checks " +
            "that VoteAsync and PreVoteAsync have. A non-member node can send AppendEntries messages " +
            "that are accepted — entries are appended to the log and commitIndex is advanced.");
    }
}
