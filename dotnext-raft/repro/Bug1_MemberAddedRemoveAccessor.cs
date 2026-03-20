using System.Net;
using System.Reflection;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using DotNext.Net.Cluster.Consensus.Raft.Http;

namespace DotNext.Net.Cluster.Consensus.Raft.BugRepro;

/// <summary>
/// Bug 1: MemberAdded event's remove accessor modifies memberRemovedHandlers instead of memberAddedHandlers.
/// Location: RaftCluster.Membership.cs:99
///
/// This is a copy-paste bug. The MemberAdded event's -= operator removes from the wrong handler list.
/// Effect: (1) handler is never actually removed (memory leak), (2) a MemberRemoved handler is removed instead.
/// </summary>
public sealed class Bug1_MemberAddedRemoveAccessor : Assert
{
    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(20);
    private static CancellationToken TestToken => new CancellationTokenSource(DefaultTimeout).Token;

    private static IHost CreateHost(int port, IDictionary<string, string> config)
    {
        return new HostBuilder()
            .ConfigureWebHost(webHost => webHost.UseKestrel(options => options.ListenLocalhost(port))
                .UseStartup<Startup>()
            )
            .ConfigureHostOptions(static options => options.ShutdownTimeout = TimeSpan.FromSeconds(20))
            .ConfigureAppConfiguration(builder => builder.AddInMemoryCollection(config!))
            .ConfigureLogging(builder => builder.SetMinimumLevel(LogLevel.Warning))
            .JoinCluster()
            .Build();
    }

    private static IRaftHttpCluster GetCluster(IHost host)
        => host.Services.GetRequiredService<IRaftHttpCluster>();

    /// <summary>
    /// Demonstrates Bug 1: After unsubscribing from MemberAdded, the handler is still registered
    /// because the remove accessor incorrectly removes from memberRemovedHandlers.
    ///
    /// We use reflection to inspect the internal InvocationList fields to prove the bug.
    /// </summary>
    [Fact]
    public async Task MemberAddedHandler_StillRegistered_AfterUnsubscribe()
    {
        var config1 = new Dictionary<string, string>
        {
            { "partitioning", "false" },
            { "publicEndPoint", "http://localhost:3362" },
            { "coldStart", "true" },
            { "requestTimeout", "00:01:00" }
        };

        using var host1 = CreateHost(3362, config1);
        await host1.StartAsync(TestToken);

        var cluster1 = GetCluster(host1);

        // Wait for leader
        var leader = await cluster1.WaitForLeaderAsync(DefaultTimeout, TestToken);
        NotNull(leader);

        var clusterObj = cluster1;
        var clusterType = clusterObj.GetType();

        // Find the generic base type RaftCluster<TMember>
        var baseType = clusterType;
        while (baseType != null && !(baseType.IsGenericType && baseType.GetGenericTypeDefinition() == typeof(RaftCluster<>)))
            baseType = baseType.BaseType;

        NotNull(baseType);

        // Get the private fields
        var addedField = baseType!.GetField("memberAddedHandlers",
            BindingFlags.NonPublic | BindingFlags.Instance);
        var removedField = baseType.GetField("memberRemovedHandlers",
            BindingFlags.NonPublic | BindingFlags.Instance);

        NotNull(addedField);
        NotNull(removedField);

        // Get the MemberAdded event
        var memberAddedEvent = baseType.GetEvent("MemberAdded");
        NotNull(memberAddedEvent);

        // Check initial state: both handler lists should be empty
        var addedBefore = addedField!.GetValue(clusterObj);
        var isEmptyProp = addedBefore!.GetType().GetProperty("IsEmpty");
        NotNull(isEmptyProp);
        True((bool)isEmptyProp!.GetValue(addedBefore)!, "memberAddedHandlers should start empty");

        var removedBefore = removedField!.GetValue(clusterObj);
        True((bool)isEmptyProp.GetValue(removedBefore)!, "memberRemovedHandlers should start empty");

        // Subscribe to MemberAdded via reflection
        var delegateType = memberAddedEvent!.EventHandlerType!;
        var dummyMethod = typeof(Bug1_MemberAddedRemoveAccessor)
            .GetMethod(nameof(DummyHandler), BindingFlags.Static | BindingFlags.NonPublic)!;
        var testHandler = Delegate.CreateDelegate(delegateType, dummyMethod);

        // Add handler (correct: adds to memberAddedHandlers)
        memberAddedEvent.AddMethod!.Invoke(clusterObj, [testHandler]);

        var addedAfterAdd = addedField.GetValue(clusterObj);
        False((bool)isEmptyProp.GetValue(addedAfterAdd)!, "memberAddedHandlers should have 1 handler after subscribe");

        // Remove handler (BUG: removes from memberRemovedHandlers instead of memberAddedHandlers)
        memberAddedEvent.RemoveMethod!.Invoke(clusterObj, [testHandler]);

        // Check state after unsubscribe
        var addedAfterRemove = addedField.GetValue(clusterObj);
        var removedAfterRemove = removedField.GetValue(clusterObj);

        var addedStillHasHandler = !(bool)isEmptyProp.GetValue(addedAfterRemove)!;

        // BUG PROOF: memberAddedHandlers should be empty now (handler removed),
        // but it's NOT — the handler is still there because remove went to memberRemovedHandlers.
        True(addedStillHasHandler,
            "BUG CONFIRMED: memberAddedHandlers is NOT empty after MemberAdded -= handler. " +
            "The remove accessor at RaftCluster.Membership.cs:99 modifies memberRemovedHandlers " +
            "instead of memberAddedHandlers. The handler was never actually unsubscribed.");

        await host1.StopAsync(TestToken);
    }

    /// <summary>
    /// Demonstrates the second effect: unsubscribing from MemberAdded
    /// corrupts the MemberRemoved handler list by removing a non-existent handler.
    /// </summary>
    [Fact]
    public async Task MemberAddedUnsubscribe_CorruptsMemberRemovedHandlers()
    {
        var config1 = new Dictionary<string, string>
        {
            { "partitioning", "false" },
            { "publicEndPoint", "http://localhost:3364" },
            { "coldStart", "true" },
            { "requestTimeout", "00:01:00" }
        };

        using var host1 = CreateHost(3364, config1);
        await host1.StartAsync(TestToken);

        var cluster1 = GetCluster(host1);
        var leader = await cluster1.WaitForLeaderAsync(DefaultTimeout, TestToken);
        NotNull(leader);

        var clusterObj = cluster1;
        var clusterType = clusterObj.GetType();
        var baseType = clusterType;
        while (baseType != null && !(baseType.IsGenericType && baseType.GetGenericTypeDefinition() == typeof(RaftCluster<>)))
            baseType = baseType.BaseType;

        var removedField = baseType!.GetField("memberRemovedHandlers",
            BindingFlags.NonPublic | BindingFlags.Instance);
        var memberAddedEvent = baseType.GetEvent("MemberAdded");

        var delegateType = memberAddedEvent!.EventHandlerType!;
        var dummyMethod = typeof(Bug1_MemberAddedRemoveAccessor)
            .GetMethod(nameof(DummyHandler), BindingFlags.Static | BindingFlags.NonPublic)!;
        var testHandler = Delegate.CreateDelegate(delegateType, dummyMethod);

        // Subscribe to MemberAdded (goes to memberAddedHandlers — correct)
        memberAddedEvent.AddMethod!.Invoke(clusterObj, [testHandler]);

        // Unsubscribe from MemberAdded (BUG: goes to memberRemovedHandlers -= handler)
        // Since the handler was never in memberRemovedHandlers, InvocationList tries to remove
        // a non-existent delegate. This is benign when the list is empty, but would corrupt
        // the list if MemberRemoved had any subscribers.

        // First, add a handler to MemberRemoved to prove corruption
        var memberRemovedEvent = baseType.GetEvent("MemberRemoved");
        NotNull(memberRemovedEvent);

        var removedHandler = Delegate.CreateDelegate(delegateType, dummyMethod);
        memberRemovedEvent!.AddMethod!.Invoke(clusterObj, [removedHandler]);

        var removedBeforeBuggyUnsubscribe = removedField!.GetValue(clusterObj);
        var isEmptyProp = removedBeforeBuggyUnsubscribe!.GetType().GetProperty("IsEmpty");
        False((bool)isEmptyProp!.GetValue(removedBeforeBuggyUnsubscribe)!,
            "memberRemovedHandlers should have 1 handler (from MemberRemoved += handler)");

        // Now unsubscribe from MemberAdded — this incorrectly removes from memberRemovedHandlers
        memberAddedEvent.RemoveMethod!.Invoke(clusterObj, [testHandler]);

        var removedAfterBuggyUnsubscribe = removedField.GetValue(clusterObj);
        var removedIsEmpty = (bool)isEmptyProp.GetValue(removedAfterBuggyUnsubscribe)!;

        // BUG: The MemberRemoved handler was removed by unsubscribing from MemberAdded!
        True(removedIsEmpty,
            "BUG CONFIRMED: Unsubscribing from MemberAdded removed a handler from memberRemovedHandlers. " +
            "The MemberRemoved event handler was incorrectly removed as a side effect of " +
            "MemberAdded -= handler, because the remove accessor targets the wrong field.");

        await host1.StopAsync(TestToken);
    }

    private static void DummyHandler(object sender, object args) { }
}
