%% Trace emission module for TLA+ trace validation of Ra.
%% Emits NDJSON events that can be replayed against Trace.tla.
%%
%% Usage:
%%   tla_trace:init(#{file => "/tmp/trace.ndjson",
%%                    servers => #{ServerId => "s1", ...}}).
%%   tla_trace:ret(<<"event_name">>, #{from => FromId},
%%                 {NextState, State, Effects}).
%%   tla_trace:close().
-module(tla_trace).

-export([init/1, close/0,
         ret/2, ret/3,
         emit/4, emit/5,
         map_server_id/1]).

%% ============================================================
%% API
%% ============================================================

%% Initialize trace emission.
%%   Opts :: #{file := string(),
%%             servers := #{ra_server_id() => binary()}}
init(#{file := File, servers := ServerMap}) ->
    {ok, Fd} = file:open(File, [write, {encoding, utf8}]),
    persistent_term:put(tla_trace_fd, Fd),
    persistent_term:put(tla_trace_servers, ServerMap),
    ok.

%% Close the trace file.
close() ->
    case persistent_term:get(tla_trace_fd, undefined) of
        undefined -> ok;
        Fd ->
            file:close(Fd),
            persistent_term:erase(tla_trace_fd),
            persistent_term:erase(tla_trace_servers)
    end.

%% Wrap a handler return value and emit a trace event.
%% Used at return points in ra_server.erl.
ret(Event, {NextState, State, Effects}) ->
    emit(Event, NextState, State, #{}),
    {NextState, State, Effects}.

ret(Event, Extra, {NextState, State, Effects}) ->
    emit(Event, NextState, State, Extra),
    {NextState, State, Effects}.

%% Emit a trace event.
emit(Event, FsmState, State, Extra) ->
    case persistent_term:get(tla_trace_fd, undefined) of
        undefined -> ok;
        Fd ->
            do_emit(Fd, Event, FsmState, State, Extra)
    end.

emit(Event, FsmState, State, Extra, ExtraState) ->
    case persistent_term:get(tla_trace_fd, undefined) of
        undefined -> ok;
        Fd ->
            do_emit(Fd, Event, FsmState, State, maps:merge(Extra, ExtraState))
    end.

%% Map a server ID using the global server map.
map_server_id(ServerId) ->
    ServerMap = persistent_term:get(tla_trace_servers, #{}),
    maps:get(ServerId, ServerMap, format_server_id(ServerId)).

%% ============================================================
%% INTERNAL
%% ============================================================

do_emit(Fd, Event, FsmState, State, Extra) ->
    ServerMap = persistent_term:get(tla_trace_servers, #{}),
    #{cfg := Cfg} = State,
    Id = element(2, Cfg), %% #cfg.id is field 2 (after record tag)
    Nid = maps:get(Id, ServerMap, format_server_id(Id)),
    Ts = erlang:system_time(nanosecond),
    {LastLogIdx, _LastLogTerm} = ra_log:last_index_term(maps:get(log, State)),
    PostState = #{
        current_term => maps:get(current_term, State, 0),
        state => atom_to_binary(FsmState, utf8),
        commit_index => maps:get(commit_index, State, 0),
        last_log_index => LastLogIdx,
        last_applied => maps:get(last_applied, State, 0)
    },
    Line0 = #{
        event => Event,
        node => Nid,
        post_state => PostState,
        ts => Ts
    },
    %% Add optional fields from Extra
    Line1 = maybe_add_from(Line0, Extra, ServerMap),
    Line2 = maybe_add_to(Line1, Extra, ServerMap),
    Line3 = maybe_add_new_config(Line2, Extra, ServerMap),
    Json = encode_json(Line3),
    io:put_chars(Fd, [Json, $\n]).

maybe_add_from(Line, #{from := From}, ServerMap) ->
    Line#{from => maps:get(From, ServerMap, format_server_id(From))};
maybe_add_from(Line, _, _) ->
    Line.

maybe_add_to(Line, #{to := To}, ServerMap) ->
    Line#{to => maps:get(To, ServerMap, format_server_id(To))};
maybe_add_to(Line, _, _) ->
    Line.

maybe_add_new_config(Line, #{new_config := Cfg}, ServerMap) ->
    Mapped = [maps:get(S, ServerMap, format_server_id(S)) || S <- Cfg],
    Line#{new_config => Mapped};
maybe_add_new_config(Line, _, _) ->
    Line.

format_server_id({Name, _Node}) ->
    atom_to_binary(Name, utf8);
format_server_id(Name) when is_atom(Name) ->
    atom_to_binary(Name, utf8);
format_server_id(Other) ->
    list_to_binary(io_lib:format("~p", [Other])).

%% ============================================================
%% JSON ENCODER (for OTP 25 compatibility)
%% ============================================================

encode_json(Map) when is_map(Map) ->
    Pairs = maps:to_list(Map),
    Inner = lists:join($,,
        [encode_json_pair(K, V) || {K, V} <- Pairs]),
    [${ | [Inner, $}]];
encode_json(List) when is_list(List) ->
    Inner = lists:join($,, [encode_json(E) || E <- List]),
    [$[ | [Inner, $]]];
encode_json(true) -> <<"true">>;
encode_json(false) -> <<"false">>;
encode_json(null) -> <<"null">>;
encode_json(undefined) -> <<"null">>;
encode_json(Atom) when is_atom(Atom) ->
    encode_json_string(atom_to_binary(Atom, utf8));
encode_json(Int) when is_integer(Int) ->
    integer_to_binary(Int);
encode_json(Float) when is_float(Float) ->
    float_to_binary(Float, [{decimals, 10}, compact]);
encode_json(Bin) when is_binary(Bin) ->
    encode_json_string(Bin);
encode_json(Other) ->
    encode_json_string(list_to_binary(io_lib:format("~p", [Other]))).

encode_json_pair(Key, Value) ->
    [encode_json_string(to_binary(Key)), $:, encode_json(Value)].

encode_json_string(Bin) when is_binary(Bin) ->
    [$", escape_json_string(Bin), $"];
encode_json_string(Str) ->
    encode_json_string(unicode:characters_to_binary(Str)).

escape_json_string(<<>>) -> <<>>;
escape_json_string(Bin) ->
    escape_json_string(Bin, <<>>).

escape_json_string(<<>>, Acc) -> Acc;
escape_json_string(<<$", Rest/binary>>, Acc) ->
    escape_json_string(Rest, <<Acc/binary, $\\, $">>);
escape_json_string(<<$\\, Rest/binary>>, Acc) ->
    escape_json_string(Rest, <<Acc/binary, $\\, $\\>>);
escape_json_string(<<$\n, Rest/binary>>, Acc) ->
    escape_json_string(Rest, <<Acc/binary, $\\, $n>>);
escape_json_string(<<$\r, Rest/binary>>, Acc) ->
    escape_json_string(Rest, <<Acc/binary, $\\, $r>>);
escape_json_string(<<$\t, Rest/binary>>, Acc) ->
    escape_json_string(Rest, <<Acc/binary, $\\, $t>>);
escape_json_string(<<C, Rest/binary>>, Acc) when C < 32 ->
    Hex = list_to_binary(io_lib:format("\\u~4.16.0b", [C])),
    escape_json_string(Rest, <<Acc/binary, Hex/binary>>);
escape_json_string(<<C, Rest/binary>>, Acc) ->
    escape_json_string(Rest, <<Acc/binary, C>>).

to_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
to_binary(Bin) when is_binary(Bin) -> Bin;
to_binary(Int) when is_integer(Int) -> integer_to_binary(Int);
to_binary(List) when is_list(List) -> list_to_binary(List);
to_binary(Other) -> list_to_binary(io_lib:format("~p", [Other])).
