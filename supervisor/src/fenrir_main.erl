%% Command-line entry of the supervisor.
%%   erl -noshell -pa EBIN -run fenrir_main main -extra SPEC
%% SPEC is a JSON file, or JSON text, describing one run: the manifest, the mode and its schedule, and where to
%% put the run's files. The run report is written to <dir>/result.json; nothing
%% is printed except a one-line summary. Exit status: 0 the run completed,
%% 2 refused at start, 3 a scheduled step was not enabled, 1 anything else.
%% See supervisor/README.md for the fields.
-module(fenrir_main).
-export([main/0, main/1]).

main() -> main(init:get_plain_arguments()).

main([SpecFile]) ->
    Killer = spawn(fun() -> receive after 300000 -> erlang:halt(1) end end),
    Code = try run(SpecFile)
           catch Class:Reason:Stack ->
                   io:format(standard_error, "fenrir supervisor: ~0p ~0p ~0p~n", [Class, Reason, Stack]),
                   1
           end,
    exit(Killer, kill),
    erlang:halt(Code);
main(_) ->
    io:format(standard_error, "usage: erl -noshell -pa EBIN -run fenrir_main main -extra SPEC.json~n", []),
    erlang:halt(1).

number(Value) when is_binary(Value) -> binary_to_integer(Value);
number(Value) when is_integer(Value) -> Value.

text(Value) when is_binary(Value) -> unicode:characters_to_list(Value).

schedule(#{<<"mode">> := <<"list">>, <<"steps">> := Steps}) when is_list(Steps) -> #{mode => list, steps => Steps};
schedule(#{<<"mode">> := <<"seeded">>, <<"seed">> := Seed} = S) ->
    #{mode => seeded, seed => number(Seed), max_steps => number(maps:get(<<"max_steps">>, S, 200))};
schedule(#{<<"mode">> := <<"free">>} = S) ->
    #{mode => free, timeout_ms => number(maps:get(<<"timeout_ms">>, S, 2000)),
      deadline_ms => number(maps:get(<<"deadline_ms">>, S, 20000)),
      kill => [{Name, number(N)} || [Name, N] <- maps:get(<<"kill">>, S, [])],
      lose => [[Name, integer_to_binary(number(N))] || [Name, N] <- maps:get(<<"lose">>, S, [])],
      kill_in_act => [{Name, number(N)} || [Name, N] <- maps:get(<<"kill_in_act">>, S, [])]}.

run(SpecFile) ->
    %% The argument is a file name, or the JSON text itself.
    Bytes = case SpecFile of
                [${ | _] -> unicode:characters_to_binary(SpecFile);
                _ -> {ok, Read} = file:read_file(SpecFile), Read
            end,
    Spec = json:decode(Bytes),
    Dir = text(maps:get(<<"dir">>, Spec)),
    ok = filelib:ensure_path(Dir),
    Manifest = case maps:get(<<"manifest">>, Spec) of
                   File when is_binary(File) -> {ok, M} = file:read_file(text(File)), json:decode(M);
                   Inline -> Inline
               end,
    Schedule = maps:get(<<"schedule">>, Spec),
    Defects = maps:get(<<"defects">>, Spec, []),
    Known = [<<"not-delivered-after-handover">>, <<"late-reply-accepted">>, <<"relay-undeclared">>, <<"non-idempotent-peer">>,
             <<"reply-before-commit">>, <<"forgetful-supervisor-restart">>, <<"replay-different-argument">>,
             <<"read-only-writes">>, <<"writes-without-record">>, <<"record-without-writes">>, <<"torn-commit">>, <<"stale-reads">>],
    [] = Defects -- Known,
    Members = [#{name => maps:get(<<"name">>, M),
                 kind => case maps:get(<<"kind">>, M) of <<"caller">> -> caller; <<"peer">> -> peer end,
                 image => text(maps:get(<<"image">>, M))}
               || M <- maps:get(<<"members">>, Manifest)],
    Connections = maps:get(<<"connections">>, Manifest),
    %% Which member serves each remote effect of each caller: [[Caller, Effect, Member]].
    %% A manifest that says nothing binds nothing, and a caller that uses a remote effect is then refused.
    Bindings = maps:get(<<"bindings">>, Manifest, []),
    StartCheck = maps:get(<<"start_check">>, Spec, true),
    Budget = fun(Key) -> number(maps:get(Key, Schedule, 0)) end,
    System = #{members => Members, connections => Connections, bindings => Bindings, defects => Defects, start_check => StartCheck,
               tender => text(maps:get(<<"tender">>, Spec)), dir => Dir,
               life_ms => number(maps:get(<<"life_ms">>, Spec, 60000)),
               crashes => Budget(<<"crashes">>), duplicates => Budget(<<"duplicates">>),
               supervisor_restarts => Budget(<<"supervisor_restarts">>)},
    {ok, _} = application:ensure_all_started(fenrir_supervisor),
    Outcome = case fenrir_relay:assemble(System) of
                  ok -> fenrir_run:run(schedule(Schedule));
                  {refused, _} -> #{status => <<"refused-at-start">>};
                  {error, Reason} ->
                      #{status => <<"error">>, error => unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}
              end,
    Report = fenrir_relay:report(),
    Shut = fenrir_relay:shutdown(),
    Result = maps:merge(maps:merge(maps:merge(Report, Shut), Outcome),
                        #{schema => <<"fenrir.supervisor.run/1">>,
                          schedule => Schedule, defects => Defects, start_check => StartCheck,
                          manifest => #{members => [#{name => maps:get(name, M), kind => atom_to_binary(maps:get(kind, M))} || M <- Members],
                                        connections => Connections, bindings => Bindings}}),
    ok = file:write_file(filename:join(Dir, "result.json"), [json:encode(Result), "\n"]),
    Status = maps:get(status, Outcome),
    io:format("~s ~s events=~b~n", [Status, filename:join(Dir, "result.json"), length(maps:get(events, Report))]),
    application:stop(fenrir_supervisor),
    case Status of
        <<"completed">> -> 0;
        <<"refused-at-start">> -> 2;
        <<"step-not-enabled">> -> 3;
        _ -> 1
    end.
