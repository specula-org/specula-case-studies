%% Common Test suite for TLA+ trace generation.
%% Exercises Ra's Raft protocol to produce NDJSON traces.
-module(tla_trace_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(SYS, default).

%%%===================================================================
%%% CT callbacks
%%%===================================================================

all() ->
    [{group, traces}].

all_tests() ->
    [basic_consensus,
     leader_step_down,
     consistent_query].

groups() ->
    [{traces, [], all_tests()}].

suite() -> [{timetrap, {seconds, 120}}].

init_per_suite(Config) ->
    ra_env:configure_logger(logger),
    ok = logger:set_primary_config(level, warning),
    {ok, _} = ra:start_in(?config(priv_dir, Config)),
    Config.

end_per_suite(_Config) ->
    application:stop(ra),
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    TraceDir = case os:getenv("TLA_TRACE_DIR") of
                   false -> filename:join(?config(priv_dir, Config), "traces");
                   Dir -> Dir
               end,
    ok = filelib:ensure_dir(filename:join(TraceDir, "dummy")),
    TraceFile = filename:join(TraceDir, atom_to_list(TestCase) ++ ".ndjson"),
    [{trace_file, TraceFile} | Config].

end_per_testcase(_TestCase, _Config) ->
    tla_trace:close(),
    ra_server_sup_sup:remove_all(?SYS),
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

%% Basic consensus: 3-node cluster, leader election, client writes, replication.
basic_consensus(Config) ->
    TraceFile = ?config(trace_file, Config),
    Members = [{s1, node()}, {s2, node()}, {s3, node()}],
    ServerMap = maps:from_list([{Id, atom_to_binary(Name, utf8)}
                                || {Name, _} = Id <- Members]),
    tla_trace:init(#{file => TraceFile, servers => ServerMap}),

    %% Start a 3-node cluster
    {ok, Started, _} = ra_kv:start_cluster(?SYS, basic_consensus,
                                           #{members => Members}),
    ct:pal("Started servers: ~p", [Started]),

    %% Wait for a leader to be elected
    Leader = wait_for_leader(Members, 10000),
    ct:pal("Leader elected: ~p", [Leader]),

    %% Write values (exercises client_request + replication + advance_commit_index)
    {ok, _} = ra_kv:put(Leader, <<"key1">>, <<"value1">>, 5000),
    ct:pal("Put key1=value1"),

    {ok, _} = ra_kv:put(Leader, <<"key2">>, <<"value2">>, 5000),
    ct:pal("Put key2=value2"),

    %% Read to verify replication
    timer:sleep(200),
    {ok, _, <<"value1">>} = ra_kv:get(Leader, <<"key1">>, 5000),
    ct:pal("Verified key1"),

    %% Allow time for followers to apply
    timer:sleep(500),

    %% Stop all servers
    [ra:stop_server(?SYS, S) || S <- Members],
    tla_trace:close(),

    %% Verify trace was generated
    verify_trace(TraceFile),
    ok.

%% Leader step-down scenario: trigger election, let a new leader emerge.
leader_step_down(Config) ->
    TraceFile = ?config(trace_file, Config),
    Members = [{s1, node()}, {s2, node()}, {s3, node()}],
    ServerMap = maps:from_list([{Id, atom_to_binary(Name, utf8)}
                                || {Name, _} = Id <- Members]),
    tla_trace:init(#{file => TraceFile, servers => ServerMap}),

    %% Start cluster
    {ok, _, _} = ra_kv:start_cluster(?SYS, leader_step_down,
                                     #{members => Members}),

    Leader = wait_for_leader(Members, 10000),
    ct:pal("Initial leader: ~p", [Leader]),

    %% Write a value to ensure stability
    {ok, _} = ra_kv:put(Leader, <<"k1">>, <<"v1">>, 5000),

    %% Trigger election on a follower
    Followers = [M || M <- Members, M /= Leader],
    NewCandidate = hd(Followers),
    ct:pal("Triggering election on ~p", [NewCandidate]),
    ra:trigger_election(NewCandidate),

    %% Wait for new leader
    timer:sleep(2000),
    NewLeader = wait_for_leader(Members, 10000),
    ct:pal("New leader: ~p", [NewLeader]),

    %% Write through new leader (exercises pre_vote + request_vote + become_leader)
    {ok, _} = ra_kv:put(NewLeader, <<"k2">>, <<"v2">>, 5000),

    timer:sleep(500),
    [ra:stop_server(?SYS, S) || S <- Members],
    tla_trace:close(),

    verify_trace(TraceFile),
    ok.

%% Consistent query: exercises heartbeat-based consistent reads.
consistent_query(Config) ->
    TraceFile = ?config(trace_file, Config),
    Members = [{s1, node()}, {s2, node()}, {s3, node()}],
    ServerMap = maps:from_list([{Id, atom_to_binary(Name, utf8)}
                                || {Name, _} = Id <- Members]),
    tla_trace:init(#{file => TraceFile, servers => ServerMap}),

    %% Start cluster
    {ok, _, _} = ra_kv:start_cluster(?SYS, consistent_query,
                                     #{members => Members}),

    Leader = wait_for_leader(Members, 10000),
    ct:pal("Leader: ~p", [Leader]),

    %% Write some data first
    {ok, _} = ra_kv:put(Leader, <<"cq1">>, <<"val1">>, 5000),
    {ok, _} = ra_kv:put(Leader, <<"cq2">>, <<"val2">>, 5000),

    %% Perform consistent queries (exercises heartbeat RPC path)
    {ok, _, <<"val1">>} = ra_kv:get(Leader, <<"cq1">>, 5000),
    {ok, _, <<"val2">>} = ra_kv:get(Leader, <<"cq2">>, 5000),

    %% Multiple consistent queries to generate heartbeat events
    {ok, _, <<"val1">>} = ra_kv:get(Leader, <<"cq1">>, 5000),

    timer:sleep(500),
    [ra:stop_server(?SYS, S) || S <- Members],
    tla_trace:close(),

    verify_trace(TraceFile),
    ok.

%%%===================================================================
%%% Helpers
%%%===================================================================

wait_for_leader(Members, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_leader_loop(Members, Deadline).

wait_for_leader_loop(Members, Deadline) ->
    case erlang:monotonic_time(millisecond) > Deadline of
        true ->
            ct:fail("No leader elected within timeout");
        false ->
            case find_leader(Members) of
                undefined ->
                    timer:sleep(200),
                    wait_for_leader_loop(Members, Deadline);
                Leader ->
                    Leader
            end
    end.

find_leader(Members) ->
    lists:foldl(
      fun(_, Found) when Found /= undefined -> Found;
         (M, _) ->
              try
                  case ra_server_proc:ping(M, 1000) of
                      {pong, leader} -> M;
                      _ -> undefined
                  end
              catch _:_ -> undefined
              end
      end, undefined, Members).

verify_trace(TraceFile) ->
    {ok, Data} = file:read_file(TraceFile),
    Lines = binary:split(Data, <<"\n">>, [global, trim_all]),
    NumLines = length(Lines),
    ct:pal("Trace generated: ~b lines in ~s", [NumLines, TraceFile]),
    ?assert(NumLines > 0),
    %% Verify each line is valid JSON with expected fields
    lists:foreach(
      fun(Line) ->
              %% Basic JSON structure check: starts with { and has "event"
              ?assertMatch(<<${, _/binary>>, Line),
              ?assert(binary:match(Line, <<"\"event\"">> ) /= nomatch)
      end, Lines),
    ok.
