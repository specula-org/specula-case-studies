using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DotNext.Net.Cluster.Consensus.Raft.Tracing;

/// <summary>
/// Thread-safe NDJSON trace emitter for TLA+ trace validation.
/// Activated by DOTNEXT_TRACE_FILE environment variable.
/// </summary>
public static class TlaTrace
{
    private static StreamWriter? _writer;
    private static readonly object _lock = new();
    private static readonly ConcurrentDictionary<string, string> _serverMap = new();
    private static int _nextServerId;

    /// <summary>
    /// Initialize trace writer. Call once at startup.
    /// </summary>
    public static void Init(string? filePath = null)
    {
        filePath ??= Environment.GetEnvironmentVariable("DOTNEXT_TRACE_FILE");
        if (string.IsNullOrEmpty(filePath))
            return;

        var dir = Path.GetDirectoryName(filePath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);

        _writer = new StreamWriter(filePath, append: false) { AutoFlush = true };
    }

    /// <summary>
    /// Register a server mapping from implementation endpoint to TLA+ name.
    /// </summary>
    public static void RegisterServer(string implId, string tlaName)
    {
        _serverMap[Normalize(implId)] = tlaName;
    }

    /// <summary>
    /// Map an implementation node ID to a TLA+ server name (s1, s2, ...).
    /// Auto-assigns on first encounter.
    /// </summary>
    public static string MapServer(string? implId)
    {
        if (string.IsNullOrEmpty(implId)) return "";
        var key = Normalize(implId);
        return _serverMap.GetOrAdd(key, _ =>
        {
            var id = Interlocked.Increment(ref _nextServerId);
            return $"s{id}";
        });
    }

    /// <summary>
    /// Map a URI or EndPoint to TLA+ name.
    /// </summary>
    public static string MapServer(System.Net.EndPoint? endPoint)
    {
        if (endPoint is null) return "";
        return MapServer(endPoint.ToString());
    }

    public static bool IsEnabled => _writer is not null;

    /// <summary>
    /// Emit a trace event with full state.
    /// </summary>
    public static void EmitFull(string eventName, string nid, long term, string role,
        string votedFor, long commitIndex, long lastLogIndex, long lastLogTerm,
        Dictionary<string, object>? msg = null)
    {
        if (_writer is null) return;

        var state = new Dictionary<string, object>
        {
            ["term"] = term,
            ["role"] = role,
            ["votedFor"] = votedFor ?? "",
            ["commitIndex"] = commitIndex,
            ["lastLogIndex"] = lastLogIndex,
            ["lastLogTerm"] = lastLogTerm,
        };

        var ev = new Dictionary<string, object>
        {
            ["name"] = eventName,
            ["nid"] = nid,
            ["state"] = state,
        };
        if (msg is not null)
            ev["msg"] = msg;

        WriteEvent(ev);
    }

    /// <summary>
    /// Emit a trace event with weak state (term + role only).
    /// </summary>
    public static void EmitWeak(string eventName, string nid, long term, string role,
        Dictionary<string, object>? msg = null)
    {
        if (_writer is null) return;

        var state = new Dictionary<string, object>
        {
            ["term"] = term,
            ["role"] = role,
            ["votedFor"] = "",
            ["commitIndex"] = 0,
            ["lastLogIndex"] = 0,
            ["lastLogTerm"] = 0,
        };

        var ev = new Dictionary<string, object>
        {
            ["name"] = eventName,
            ["nid"] = nid,
            ["state"] = state,
        };
        if (msg is not null)
            ev["msg"] = msg;

        WriteEvent(ev);
    }

    /// <summary>
    /// Emit a trace event with commit-level state (term + role + commitIndex).
    /// </summary>
    public static void EmitCommit(string eventName, string nid, long term, string role,
        long commitIndex, Dictionary<string, object>? msg = null)
    {
        if (_writer is null) return;

        var state = new Dictionary<string, object>
        {
            ["term"] = term,
            ["role"] = role,
            ["votedFor"] = "",
            ["commitIndex"] = commitIndex,
            ["lastLogIndex"] = 0,
            ["lastLogTerm"] = 0,
        };

        var ev = new Dictionary<string, object>
        {
            ["name"] = eventName,
            ["nid"] = nid,
            ["state"] = state,
        };
        if (msg is not null)
            ev["msg"] = msg;

        WriteEvent(ev);
    }

    /// <summary>
    /// Emit a config line (first line of trace).
    /// </summary>
    public static void EmitConfig(string[] servers)
    {
        if (_writer is null) return;

        var line = new Dictionary<string, object>
        {
            ["tag"] = "config",
            ["ts"] = DateTimeOffset.UtcNow.ToString("o"),
            ["config"] = new Dictionary<string, object>
            {
                ["servers"] = servers,
            }
        };

        var json = JsonSerializer.Serialize(line);
        lock (_lock)
        {
            _writer.WriteLine(json);
        }
    }

    private static void WriteEvent(Dictionary<string, object> ev)
    {
        var line = new Dictionary<string, object>
        {
            ["tag"] = "trace",
            ["ts"] = DateTimeOffset.UtcNow.ToString("o"),
            ["event"] = ev,
        };

        var json = JsonSerializer.Serialize(line);
        lock (_lock)
        {
            _writer!.WriteLine(json);
        }
    }

    /// <summary>
    /// Flush and close the trace file.
    /// </summary>
    public static void Shutdown()
    {
        lock (_lock)
        {
            _writer?.Flush();
            _writer?.Dispose();
            _writer = null;
        }
    }

    /// <summary>
    /// Normalize endpoint string for consistent mapping.
    /// Trims trailing slashes and lowercases.
    /// </summary>
    private static string Normalize(string s)
        => s.TrimEnd('/').ToLowerInvariant();
}
