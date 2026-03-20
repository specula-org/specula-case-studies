using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using DotNext.Net.Cluster.Consensus.Raft.Http;

namespace DotNext.Net.Cluster.Consensus.Raft.BugRepro;

internal sealed class Startup
{
    private readonly IConfiguration configuration;

    public Startup(IConfiguration configuration) => this.configuration = configuration;

    public void Configure(IApplicationBuilder app)
    {
        app.UseConsensusProtocolHandler();
    }

    public void ConfigureServices(IServiceCollection services)
    {
        services.AddOptions()
            .AddSingleton<IHttpMessageHandlerFactory, TestClientHandlerFactory>();
    }
}

internal sealed class TestClientHandlerFactory : IHttpMessageHandlerFactory
{
    public HttpMessageHandler CreateHandler(string name)
        => new SocketsHttpHandler { ConnectTimeout = TimeSpan.FromMilliseconds(100) };
}
