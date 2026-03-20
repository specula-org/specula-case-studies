using Microsoft.AspNetCore.Connections;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using System.Net;
using static System.Threading.Timeout;

namespace DotNext.Net.Cluster.Consensus.Raft.Http;

using Diagnostics;
using Messaging;
using Tracing;
using static DotNext.Extensions.Logging.TestLoggers;

[Collection(TestCollections.Raft)]
public sealed class TlaTraceTests : RaftTest
{
    private sealed class LeaderTracker : LeaderChangedEvent, IClusterMemberLifetime
    {
        void IClusterMemberLifetime.OnStart(IRaftCluster cluster, IDictionary<string, string> metadata)
            => cluster.LeaderChanged += OnLeaderChanged;

        void IClusterMemberLifetime.OnStop(IRaftCluster cluster)
            => cluster.LeaderChanged -= OnLeaderChanged;
    }

    private static IHost CreateHost<TStartup>(int port, IDictionary<string, string> configuration, IClusterMemberLifetime? configurator = null)
        where TStartup : class
    {
        return new HostBuilder()
            .ConfigureWebHost(webHost => webHost.UseKestrel(options => options.ListenLocalhost(port))
                .ConfigureServices(services =>
                {
                    if (configurator is not null)
                        services.AddSingleton(configurator);
                })
                .UseStartup<TStartup>()
            )
            .ConfigureHostOptions(static options => options.ShutdownTimeout = DefaultTimeout)
            .ConfigureAppConfiguration(builder => builder.AddInMemoryCollection(configuration))
            .ConfigureLogging(builder => builder.AddDebugLogger(port.ToString()).SetMinimumLevel(LogLevel.Debug))
            .JoinCluster()
            .Build();
    }

    private static IRaftHttpCluster GetLocalClusterView(IHost host)
        => host.Services.GetRequiredService<IRaftHttpCluster>();

    /// <summary>
    /// Scenario 1: Basic consensus — election + heartbeats.
    /// Exercises: Timeout, RequestVote, HandleRequestVote, HandleRequestVoteResponse,
    ///            BecomeLeader, AppendEntries, HandleAppendEntries, HandleAppendEntriesResponse,
    ///            AdvanceCommitIndex.
    /// </summary>
    [Fact]
    public static async Task BasicConsensus()
    {
        var traceDir = Environment.GetEnvironmentVariable("TRACE_OUTPUT_DIR")
            ?? Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "traces");
        var traceFile = Path.Combine(traceDir, "basic_consensus.ndjson");
        Directory.CreateDirectory(traceDir);

        // Register server mappings BEFORE initializing trace
        // Use port-based naming for deterministic mapping
        TlaTrace.RegisterServer("http://localhost:9561", "s1");
        TlaTrace.RegisterServer("http://localhost:9562", "s2");
        TlaTrace.RegisterServer("http://localhost:9563", "s3");

        TlaTrace.Init(traceFile);
        TlaTrace.EmitConfig(["s1", "s2", "s3"]);

        try
        {
            var config1 = new Dictionary<string, string?>
            {
                {"partitioning", "false"},
                {"publicEndPoint", "http://localhost:9561"},
                {"coldStart", "true"},
                {"requestTimeout", "00:01:00"},
                {"lowerElectionTimeout", "600"},
                {"upperElectionTimeout", "900"},
            };

            var config2 = new Dictionary<string, string?>
            {
                {"partitioning", "false"},
                {"publicEndPoint", "http://localhost:9562"},
                {"coldStart", "false"},
                {"requestTimeout", "00:01:00"},
                {"lowerElectionTimeout", "600"},
                {"upperElectionTimeout", "900"},
            };

            var config3 = new Dictionary<string, string?>
            {
                {"partitioning", "false"},
                {"publicEndPoint", "http://localhost:9563"},
                {"coldStart", "false"},
                {"requestTimeout", "00:01:00"},
                {"lowerElectionTimeout", "600"},
                {"upperElectionTimeout", "900"},
            };

            var listener = new LeaderTracker();
            using var host1 = CreateHost<Startup>(9561, config1, listener);
            await host1.StartAsync(TestToken);
            True(GetLocalClusterView(host1).Readiness.IsCompletedSuccessfully);

            using var host2 = CreateHost<Startup>(9562, config2);
            await host2.StartAsync(TestToken);

            using var host3 = CreateHost<Startup>(9563, config3);
            await host3.StartAsync(TestToken);

            // Wait for initial leader election (cold start node)
            await listener.Task.WaitAsync(TestToken);

            // Add members to form 3-node cluster
            True(await GetLocalClusterView(host1).AddMemberAsync(
                GetLocalClusterView(host2).LocalMemberAddress, TestToken));
            await GetLocalClusterView(host2).Readiness.WaitAsync(TestToken);

            True(await GetLocalClusterView(host1).AddMemberAsync(
                GetLocalClusterView(host3).LocalMemberAddress, TestToken));
            await GetLocalClusterView(host3).Readiness.WaitAsync(TestToken);

            // Verify leadership consensus across all nodes
            await AssertLeadershipAsync(
                EndPointFormatter.UriEndPointComparer,
                GetLocalClusterView(host1),
                GetLocalClusterView(host2),
                GetLocalClusterView(host3));

            // Wait for several heartbeat rounds to generate AppendEntries/Response events
            await Task.Delay(3000, TestToken);

            await host3.StopAsync(TestToken);
            await host2.StopAsync(TestToken);
            await host1.StopAsync(TestToken);
        }
        finally
        {
            TlaTrace.Shutdown();
        }
    }

    /// <summary>
    /// Scenario 2: Leader resignation — triggers new election.
    /// </summary>
    [Fact]
    public static async Task LeaderResignation()
    {
        var traceDir = Environment.GetEnvironmentVariable("TRACE_OUTPUT_DIR")
            ?? Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "traces");
        var traceFile = Path.Combine(traceDir, "leader_resignation.ndjson");
        Directory.CreateDirectory(traceDir);

        TlaTrace.RegisterServer("http://localhost:9571", "s1");
        TlaTrace.RegisterServer("http://localhost:9572", "s2");
        TlaTrace.RegisterServer("http://localhost:9573", "s3");

        TlaTrace.Init(traceFile);
        TlaTrace.EmitConfig(["s1", "s2", "s3"]);

        try
        {
            var config1 = new Dictionary<string, string?>
            {
                {"partitioning", "false"},
                {"publicEndPoint", "http://localhost:9571"},
                {"coldStart", "true"},
                {"requestTimeout", "00:01:00"},
                {"lowerElectionTimeout", "600"},
                {"upperElectionTimeout", "900"},
            };

            var config2 = new Dictionary<string, string?>
            {
                {"partitioning", "false"},
                {"publicEndPoint", "http://localhost:9572"},
                {"coldStart", "false"},
                {"requestTimeout", "00:01:00"},
                {"lowerElectionTimeout", "600"},
                {"upperElectionTimeout", "900"},
            };

            var config3 = new Dictionary<string, string?>
            {
                {"partitioning", "false"},
                {"publicEndPoint", "http://localhost:9573"},
                {"coldStart", "false"},
                {"requestTimeout", "00:01:00"},
                {"lowerElectionTimeout", "600"},
                {"upperElectionTimeout", "900"},
            };

            var listener = new LeaderTracker();
            using var host1 = CreateHost<Startup>(9571, config1, listener);
            await host1.StartAsync(TestToken);

            using var host2 = CreateHost<Startup>(9572, config2);
            await host2.StartAsync(TestToken);

            using var host3 = CreateHost<Startup>(9573, config3);
            await host3.StartAsync(TestToken);

            // Wait for initial leader
            await listener.Task.WaitAsync(TestToken);

            // Add members
            True(await GetLocalClusterView(host1).AddMemberAsync(
                GetLocalClusterView(host2).LocalMemberAddress, TestToken));
            await GetLocalClusterView(host2).Readiness.WaitAsync(TestToken);

            True(await GetLocalClusterView(host1).AddMemberAsync(
                GetLocalClusterView(host3).LocalMemberAddress, TestToken));
            await GetLocalClusterView(host3).Readiness.WaitAsync(TestToken);

            await AssertLeadershipAsync(
                EndPointFormatter.UriEndPointComparer,
                GetLocalClusterView(host1),
                GetLocalClusterView(host2),
                GetLocalClusterView(host3));

            // Wait for heartbeats to stabilize
            await Task.Delay(2000, TestToken);

            // Resign leadership — triggers new election
            True(await GetLocalClusterView(host1).ResignAsync(TestToken));

            // Wait for new leader election
            await Task.Delay(3000, TestToken);

            // Verify new leadership
            await AssertLeadershipAsync(
                EndPointFormatter.UriEndPointComparer,
                GetLocalClusterView(host1),
                GetLocalClusterView(host2),
                GetLocalClusterView(host3));

            await host3.StopAsync(TestToken);
            await host2.StopAsync(TestToken);
            await host1.StopAsync(TestToken);
        }
        finally
        {
            TlaTrace.Shutdown();
        }
    }
}
