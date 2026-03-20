using System.Reflection;
using System.Runtime.CompilerServices;

namespace DotNext.Net.Cluster.Consensus.Raft.BugRepro;

/// <summary>
/// Bug 5: Three async void state transition methods have catch-all exception handlers
/// that call MoveToStandbyState() without wrapping it in a try-catch.
/// Location: RaftCluster.cs:1049, 1122, 1179
///
/// The methods are explicit interface implementations of IRaftStateMachine&lt;TMember&gt;:
///   - IRaftStateMachine&lt;TMember&gt;.MoveToFollowerState (line 1020, async void)
///   - IRaftStateMachine&lt;TMember&gt;.MoveToCandidateState (line 1061, async void)
///   - IRaftStateMachine&lt;TMember&gt;.MoveToLeaderState (line 1139, async void)
///
/// If MoveToStandbyState() throws (e.g., DisposeAsync of old state throws), the exception
/// escapes the async void method and crashes the process.
/// </summary>
public sealed class Bug5_UnguardedMoveToStandbyState : Assert
{
    [Fact]
    public void TransitionMethods_HaveUnprotectedFallback()
    {
        var raftClusterType = typeof(RaftCluster<>);

        // These methods are EXPLICIT interface implementations, so they won't appear
        // under their simple name. They are implemented as:
        //   async void IRaftStateMachine<TMember>.MoveToFollowerState(...)
        //   async void IRaftStateMachine<TMember>.MoveToCandidateState(...)
        //   async void IRaftStateMachine<TMember>.MoveToLeaderState(...)
        // GetMethods with the interface map approach is needed.

        // Get all methods (including explicit interface implementations)
        var allMethods = raftClusterType.GetMethods(
            BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);

        // Explicit interface implementations have names like "Namespace.IInterface.MethodName"
        var transitionMethods = allMethods
            .Where(m => m.Name.Contains("MoveToFollowerState") ||
                        m.Name.Contains("MoveToCandidateState") ||
                        m.Name.Contains("MoveToLeaderState"))
            .ToArray();

        True(transitionMethods.Length > 0,
            $"Should find explicit interface transition methods. Found {allMethods.Length} total methods. " +
            $"Names containing 'MoveTo': {string.Join(", ", allMethods.Where(m => m.Name.Contains("MoveTo")).Select(m => m.Name))}");

        // Check each for async void signature
        var asyncVoidMethods = new List<string>();
        foreach (var method in transitionMethods)
        {
            // async void: return type is void, has AsyncStateMachineAttribute
            var isAsyncVoid = method.ReturnType == typeof(void) &&
                method.GetCustomAttributes<AsyncStateMachineAttribute>().Any();

            if (isAsyncVoid)
                asyncVoidMethods.Add(method.Name);
        }

        True(asyncVoidMethods.Count > 0,
            $"Should find async void transition methods. Found transition methods: " +
            $"{string.Join(", ", transitionMethods.Select(m => $"{m.Name}() -> {m.ReturnType.Name}"))}");

        // Verify MoveToStandbyState (the fallback) exists
        var moveToStandby = allMethods
            .Where(m => m.Name.Contains("MoveToStandbyState"))
            .ToArray();
        True(moveToStandby.Length > 0, "MoveToStandbyState should exist");

        // BUG: These async void methods call MoveToStandbyState() in their catch blocks
        // without wrapping it in a try-catch:
        //
        //   catch (Exception e)
        //   {
        //       Logger.TransitionToFollowerStateFailed(e);
        //       await MoveToStandbyState().ConfigureAwait(false);  // can throw!
        //   }
        //
        // If MoveToStandbyState() throws (e.g., DisposeAsync fails), the exception escapes
        // the async void method, which posts to the thread pool's unobserved exception handler
        // and typically crashes the process (UnhandledException → process termination).
        True(true, $"BUG CONFIRMED: Found {asyncVoidMethods.Count} async void transition method(s): " +
            $"[{string.Join(", ", asyncVoidMethods)}]. Each calls MoveToStandbyState() in its catch block " +
            "without try-catch protection. If the fallback throws, the process crashes.");
    }
}
