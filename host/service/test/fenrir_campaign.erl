%% A3 campaigns (host/service/CONTRACT.md maps each named assumption to the scenarios
%% here). Deterministic and seeded: a scenario's workload is a function of its name and
%% its repeat index. Each scenario runs on a fresh SQLite file and a fresh service node,
%% writes a history (checked afterwards by harness/service-history.shen) and audits the
%% SQLite file directly after every crash and at the end.
%%
%%   erl -noshell -pa EBIN -run fenrir_campaign main CONFIG
%% CONFIG: one Erlang map (consulted), see host/service/check.sh.
-module(fenrir_campaign).
-export([main/1, declared_scope/1, scope_config/1, fixture_paths/1, sweep_name/2, sweep_result/6,
         fault_evidence/1]).

-define(D, fenrir_drive).
-define(SQLITE_LIMIT, 40).

families() -> [hand_traces, a2_runs, random_schedules, retries, duplicates,
               crash_points, sqlite_kills, lost_ack, busy, two_workers].

mutants() -> [volatile_mailbox, respond_before_commit, two_transactions, busy_as_success,
              no_dedup, no_transaction, sync_off, equivalent_control].

%% The report checks the canonical mode, never a plan narrowed by diagnostic overrides.
scope_config(quick) -> scope_config(1, 12, 3, 1, 10);
scope_config(full) -> scope_config(5, 60, 6, 2, 20).

scope_config(Repeats, Random, MutantRandom, SQLiteRepeats, Batches) ->
    #{tenants => 3, repeats => Repeats, random_schedules => Random, schedule_length => 10,
      mutant_random_schedules => MutantRandom, sqlite_kill_repeats => SQLiteRepeats,
      concurrent_batches => Batches, mutants => mutants()}.

declared_scope(C) ->
    P = scope_config(maps:get(mode, C)),
    Rs = lists:seq(1, repeats(P)),
    Fixtures = fixture_paths(maps:get(root, C)),
    Hand = fixture(Fixtures, hand_traces, <<"traces">>),
    A2 = fixture(Fixtures, a2_runs, <<"runs">>),
    Static = [{normal, hand_traces, binary_to_list(maps:get(<<"name">>, T))} || T <- Hand]
        ++ [{normal, a2_runs, run_name(I)} || I <- lists:seq(0, length(A2) - 1)]
        ++ [{normal, random_schedules, seed_name(I)} || I <- lists:seq(1, maps:get(random_schedules, P))]
        ++ [{normal, F, repeat_name(R)} || F <- [retries, duplicates, two_workers], R <- Rs]
        ++ [{normal, crash_points, crash_name(Point, Action, Op, R)} || {Point, Action, Op} <- crash_matrix(), R <- Rs]
        ++ [{normal, F, op_name(Op, R)} || F <- [busy, lost_ack], Op <- [submit, complete], R <- Rs]
        ++ [{M, F, N} || M <- mutants(), {F, N} <- mutant_cases(M, P)],
    Sweeps = [{normal, K, Op, R} || {K, Op, R} <- normal_sweeps(P)]
        ++ [{M, before_statement, submit, 1} || M <- mutants()],
    #{cases => [{M, F, full_name(M, F, N)} || {M, F, N} <- Static],
      sweeps => Sweeps, limit => ?SQLITE_LIMIT, families => families(),
      fixture_counts => [{hand_traces, 11, length(Hand)}, {a2_runs, 68, length(A2)}]}.

fixture_paths(Root) ->
    #{hand_traces => filename:join(Root, "spec/service/hand-traces.json"),
      a2_runs => filename:join(Root, "tests/host/a2-runs.json")}.

fixture(C, Key, Field) ->
    {ok, B} = file:read_file(maps:get(Key, C)),
    maps:get(Field, json:decode(B)).

normal_sweeps(C) ->
    [{K, Op, R} || K <- [before_statement, write, sync], Op <- [submit, complete],
                   R <- lists:seq(1, maps:get(sqlite_kill_repeats, C, 1))].

mutant_cases(M, C) ->
    [{retries, repeat_name(1)}, {duplicates, repeat_name(1)}, {busy, op_name(submit, 1)},
     {crash_points, crash_name(f1_after_response, kill_node, submit, 1)},
     {crash_points, crash_name(w4_reply_before_response, kill_node, submit, 1)}]
    ++ [{lost_ack, op_name(submit, 1)} || lost_ack_applies(M)]
    ++ [{random_schedules, seed_name(I)} || I <- mutant_seeds(C)].

mutant_seeds(C) -> lists:seq(1, maps:get(mutant_random_schedules, C, 3)).
full_name(M, F, N) -> fmt("~s/~s/~s", [M, F, N]).
run_name(I) -> fmt("run-~2..0B", [I]).
seed_name(I) -> fmt("seed-~3..0B", [I]).
repeat_name(R) -> fmt("repeat-~B", [R]).
op_name(Op, R) -> fmt("~s-~B", [Op, R]).
crash_name(P, A, Op, R) -> fmt("~s-~s-~s-~B", [P, A, Op, R]).
sweep_name({M, K, Op, R}, N) -> full_name(M, sqlite_kills, probe_name(K, Op, R, N)).
probe_name(K, Op, R, N) -> fmt("~s-~B-~s-~B", [K, N, Op, R]).
fmt(F, Args) -> lists:flatten(io_lib:format(F, Args)).

main([ConfigFile]) ->
    {ok, [C]} = file:consult(ConfigFile),
    Out = maps:get(out, C),
    T0 = erlang:monotonic_time(millisecond),
    Families = maps:get(families, C, all),
    Want = fun(F) -> Families =:= all orelse lists:member(F, Families) end,
    Ctx = ctx(C, normal, 1),
    R = lists:append(
          [run_family(F, Ctx, C) || F <- families(), Want(F)]
          ++ [mutant_suite(M, C) || Want(mutants), M <- maps:get(mutants, C)]),
    ok = file:write_file(filename:join(Out, "scenarios.bin"), term_to_binary(R)),
    Hist = [maps:get(history, X) || X <- R, maps:is_key(history, X)],
    ok = file:write_file(filename:join(Out, "histories.txt"), [[H, $\n] || H <- Hist]),
    io:format("campaign: ~p scenarios, ~p ms~n", [length(R), erlang:monotonic_time(millisecond) - T0]),
    halt(0).

ctx(C, Mutant, Workers) ->
    (maps:with([call_timeout], C))#{
      erl => maps:get(erl, C), ebin => maps:get(ebin, C), node_launch => maps:get(node_launch, C),
      sqlite_port => maps:get(sqlite_port, C), out => maps:get(out, C),
      sqlite_observer => filename:join([maps:get(root, C), "host", "service", "test", "sqlite-exit-observer.sh"]),
      config => #{tenants => maps:get(tenants, C, 3), image => maps:get(image, C), launcher => maps:get(launcher, C),
                  workers => Workers, mutant => Mutant}}.

repeats(C) -> maps:get(repeats, C).

%% ---------- scenario frame ----------

%% Run Fun(S) on a fresh store and node; returns the scenario record.
scenario(Ctx, Family, Name, Fun) -> scenario(Ctx, Family, Name, #{}, Fun).
scenario(Ctx0, Family, Name, Over, Fun) ->
    Ctx = Ctx0#{config := maps:merge(maps:get(config, Ctx0), Over)},
    Mutant = maps:get(mutant, maps:get(config, Ctx)),
    Full = full_name(Mutant, Family, Name),
    try run_scenario(Ctx, Full, Family, Mutant, Fun) of
        Result -> Result#{family => Family, name => Full, mutant => Mutant}
    catch Cl:Er:St ->
        #{family => Family, name => Full, mutant => Mutant, status => execution_error,
          detail => {Cl, Er, lists:sublist(St, 4)}}
    end.

run_scenario(Ctx, Full, Family, Mutant, Fun) ->
    S0 = ?D:new(Ctx, Full),
    T0 = erlang:monotonic_time(microsecond),
    case ?D:start(S0) of
        {start_failed, Why} ->
            #{status => start_failed, detail => Why};
        S1 ->
            {S2, Checks} = try Fun(S1)
                           catch
                               throw:{probe_unavailable, Probe, State} ->
                                   {State, [check(probe_available, false, Probe) | maps:get(fault_checks, State, [])]};
                               Cl:Er:St -> ?D:kill(S1), erlang:raise(Cl, Er, St)
                           end,
            S3 = case {maps:get(node, S2), lists:keymember(probe_available, 1, Checks)} of
                     {none, _} -> S2;
                     {_, true} -> S2;
                     {_, false} -> ?D:observe(S2)
                 end,
            S4 = ?D:stop(S3),
            Audit = ?D:audit(maps:get(db, S4), ?D:told(S4)),
            Tenants = maps:get(tenants, maps:get(config, Ctx)),
            File = ?D:write_history(S4, Tenants, #{<<"family">> => atom_to_binary(Family),
                                                   <<"mutant">> => atom_to_binary(Mutant)}),
            CrashAudits = [V || {_, V} <- maps:get(audits, S4, [])],
            Events = ?D:events(S4),
            #{status => executed, history => File, events => length(Events),
              gaps => [E || [<<"gap">> | _] = E <- Events],
              audit_final => Audit, audit_after_crashes => CrashAudits,
              audit_clean => Audit =:= [] andalso lists:all(fun(V) -> V =:= [] end, CrashAudits),
              checks => Checks, checks_ok => lists:all(fun({_, Ok, _}) -> Ok end, Checks),
              crashes => maps:get(crashes, S4), boots => maps:get(boots, S4),
              requests => length(maps:get(latencies, S4)), latencies_us => maps:get(latencies, S4),
              node_start_us => maps:get(node_start_us, S4, 0),
              coverage => maps:get(coverage, S4), us => erlang:monotonic_time(microsecond) - T0}
    end.

check(Name, Bool, Detail) -> {Name, Bool =:= true, Detail}.

%% ---------- families ----------

run_family(hand_traces, Ctx, C) ->
    {ok, B} = file:read_file(maps:get(hand_traces, C)),
    H = json:decode(B),
    [hand_trace(Ctx, maps:get(<<"tenants">>, H), T) || T <- maps:get(<<"traces">>, H)];
run_family(a2_runs, Ctx, C) ->
    {ok, B} = file:read_file(maps:get(a2_runs, C)),
    Runs = maps:get(<<"runs">>, json:decode(B)),
    [a2_run(Ctx, I, R) || {I, R} <- lists:zip(lists:seq(0, length(Runs) - 1), Runs)];
run_family(random_schedules, Ctx, C) ->
    [random_schedule(Ctx, Seed, maps:get(schedule_length, C, 10)) || Seed <- lists:seq(1, maps:get(random_schedules, C))];
run_family(retries, Ctx, C) -> [retries(Ctx, R) || R <- lists:seq(1, repeats(C))];
run_family(duplicates, Ctx, C) -> [duplicates(Ctx, R) || R <- lists:seq(1, repeats(C))];
run_family(crash_points, Ctx, C) ->
    Only = maps:get(only, C, ""),
    [crash_point(Ctx, Point, Action, Op, R)
     || {Point, Action, Op} <- crash_matrix(), R <- lists:seq(1, repeats(C)),
        string:find(lists:flatten(io_lib:format("~s-~s-~s", [Point, Action, Op])), Only) =/= nomatch];
run_family(sqlite_kills, Ctx, C) ->
    lists:append([sqlite_kills(Ctx, Kind, Op, R) || {Kind, Op, R} <- normal_sweeps(C)]);
run_family(lost_ack, Ctx, C) -> [lost_ack(Ctx, Op, R) || Op <- [submit, complete], R <- lists:seq(1, repeats(C))];
run_family(busy, Ctx, C) -> [busy(Ctx, Op, R) || Op <- [submit, complete], R <- lists:seq(1, repeats(C))];
run_family(two_workers, Ctx, C) -> [two_workers(Ctx, R, maps:get(concurrent_batches, C, 10)) || R <- lists:seq(1, repeats(C))].

%% The scenarios a host mutant is run against (and the equivalent control).
mutant_suite(Mutant, C) ->
    Ctx = ctx(C, Mutant, 1),
    [retries(Ctx, 1), duplicates(Ctx, 1), busy(Ctx, submit, 1),
     crash_point(Ctx, f1_after_response, kill_node, submit, 1),
     crash_point(Ctx, w4_reply_before_response, kill_node, submit, 1)]
    ++ [lost_ack(Ctx, submit, 1) || lost_ack_applies(Mutant)]
    ++ sqlite_kills(Ctx, before_statement, submit, 1)
    ++ [random_schedule(Ctx, Seed, 10) || Seed <- mutant_seeds(C)].

%% No target COMMIT exists for no_transaction; respond_before_commit delivers
%% the answer before the deferred COMMIT. Neither can exercise a lost COMMIT
%% acknowledgment on the synchronous request path.
lost_ack_applies(M) -> M =/= no_transaction andalso M =/= respond_before_commit.

%% ---------- hand traces (spec/service/hand-traces.json) ----------

hand_trace(Ctx, Tenants, T) ->
    Name = binary_to_list(maps:get(<<"name">>, T)),
    scenario(Ctx, hand_traces, Name, #{tenants => Tenants},
      fun(S0) ->
              {S, Resps, Disabled} = hand_steps(S0, maps:get(<<"schedule">>, T), [], 0),
              {Outbox, S1} = require_probe(outbox, ?D:read_probe(S, outbox)),
              {Snap, S2} = snapshot_of(S1),
              Final = [Snap, [ev(E) || E <- Outbox], [ev(E) || E <- lists:reverse(?D:told(S2))]],
              case maps:get(<<"disabled_at">>, T, none) of
                  none -> {S2, [check(responses_as_derived_by_hand, Resps =:= maps:get(<<"responses">>, T), Resps),
                               check(final_state_as_derived_by_hand, json:decode(iolist_to_binary(json:encode(Final))) =:= maps:get(<<"final">>, T), Final)]};
                  N -> {S2, [check(disabled_at_as_derived_by_hand, Disabled =:= N, Disabled)]}
              end
      end).

snapshot_of(S) -> snapshot_of(S, 100).
snapshot_of(S, N) ->
    case ?D:call(S, snapshot) of
        {ok, St, S1} when is_list(St) -> {St, S1};
        {ok, _, S1} when N > 0 -> timer:sleep(20), snapshot_of(S1, N - 1); %% the store is restarting
        {ok, Why, S1} ->
            require_probe(snapshot, {unavailable, ?D:gap(S1, <<"snapshot unavailable">>, Why)});
        {died, Why, S1} -> require_probe(snapshot, ?D:abort_probe(S1, snapshot, Why))
    end.

require_probe(_, {ok, Answer, S}) -> {Answer, S};
require_probe(Probe, {unavailable, S}) -> throw({probe_unavailable, Probe, S}).

ev({accepted, R}) -> [<<"accepted">>, R];
ev({conflict, T, K}) -> [<<"conflict">>, T, K].

hand_steps(S, [], Acc, _) -> {S, lists:reverse(Acc), none};
hand_steps(S, [[<<"submit">>, T, K, D] | Rest], Acc, I) ->
    {Out, S1} = ?D:submit(S, T, K, D),
    hand_steps(S1, Rest, [resp(Out) | Acc], I + 1);
hand_steps(S, [[<<"complete">>, T, J, Ok] | Rest], Acc, I) ->
    {_Out, S1} = ?D:complete(S, T, J, Ok),
    hand_steps(S1, Rest, [null | Acc], I + 1);
hand_steps(S, [[<<"respond">>, E] | Rest], Acc, I) ->
    Ev = case E of [<<"accepted">>, R] -> {accepted, R}; [<<"conflict">>, T, K] -> {conflict, T, K} end,
    case ?D:respond(S, Ev) of
        {ok, S1} -> hand_steps(S1, Rest, [E | Acc], I + 1);
        {not_in_outbox, S1} -> {S1, lists:reverse(Acc), I}
    end;
hand_steps(S, [[<<"crash">>] | Rest], Acc, I) -> hand_steps(?D:crash(S, kill), Rest, [null | Acc], I + 1).

resp({accepted, R}) -> [<<"accepted">>, R];
resp({conflict, T, K}) -> [<<"conflict">>, T, K];
resp(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

%% ---------- the 68 distinct (request, replies) runs of the A2 refinement ----------

%% A short prefix on a fresh store makes the store give exactly the run's replies; then
%% the request runs and the worker's replies must be the A2 run's replies. Padding uses
%% key 2, which is outside A2's keys and inside the image's domain.
a2_run(Ctx, I, Run) ->
    [Kind, T, X, Y] = maps:get(<<"request">>, Run),
    [Reply] = maps:get(<<"replies">>, Run),
    Name = run_name(I),
    scenario(Ctx, a2_runs, Name,
      fun(S0) ->
              S1 = a2_prefix(S0, Kind, T, X, Y, Reply),
              Req = case Kind of <<"submit">> -> {submit, T, X, Y}; <<"complete">> -> {complete, T, X, Y} end,
              {Out, S2} = case Req of
                              {submit, _, _, _} -> ?D:submit_told(S1, T, X, Y);
                              {complete, _, _, _} -> ?D:complete(S1, T, X, Y)
                          end,
              Got = [json:decode(R) || {Q, Rs} <- lists:sublist(maps:get(coverage, S2), 1), Q =:= Req, R <- Rs],
              {S2, [check(replies_equal_a2_run, Got =:= [Reply], {Got, Reply, Out})]}
      end).

a2_prefix(S, <<"complete">>, T, J, _Ok, [_, _, <<"Applied">>]) -> pad_jobs(S, T, J);
a2_prefix(S, <<"complete">>, _T, _J, _Ok, [_, _, <<"Skipped">>]) -> S;
a2_prefix(S, <<"submit">>, T, _K, _D, [_, _, <<"Committed">>, [_, _, _, _, _, _, [_, N], _]]) ->
    pad(S, T, binary_to_integer(N));
a2_prefix(S, <<"submit">>, T, K, _D, [_, _, <<"Recorded">>, [_, D0], [_, _, _, _, _, _, [_, N], _]]) ->
    S1 = pad(S, T, binary_to_integer(N)),
    element(2, ?D:submit_told(S1, T, K, binary_to_integer(D0))).

%% Jobs 0..J exist and job J is pending: J+1 fresh submits (padding key 2, then keys 0, 1).
pad_jobs(S, T, J) ->
    Keys = [2, 0, 1],
    lists:foldl(fun(N, Acc) -> element(2, ?D:submit_told(Acc, T, lists:nth(N + 1, Keys), 0)) end, S, lists:seq(0, J)).

%% N fresh submits on the padding key's neighbours, so the next id is N.
pad(S, _T, 0) -> S;
pad(S, T, 1) -> element(2, ?D:submit_told(S, T, 2, 0)).

%% ---------- random schedules over the A1 alphabet ----------

random_schedule(Ctx, Seed, Len) ->
    Name = seed_name(Seed),
    scenario(Ctx, random_schedules, Name,
      fun(S0) ->
              rand:seed(exsss, {Seed, 1009, 7}),
              S = lists:foldl(fun(_, Acc) -> random_step(Acc) end, S0, lists:seq(1, Len)),
              {S, []}
      end).

random_step(S) ->
    case ?D:read_probe(S, outbox) of
        {unavailable, S1} -> S1;
        {ok, Outbox, S1} ->
            case ?D:read_probe(S1, snapshot) of
                {unavailable, S2} -> S2;
                {ok, Snap, S2} -> random_step(S2, Outbox, [N || [_, _, _, N] <- Snap])
            end
    end.

random_step(S, Outbox, Next) ->
    case rand:uniform(12) of
        X when X =< 5 -> element(2, ?D:submit(S, rand:uniform(2) - 1, rand:uniform(2) - 1, rand:uniform(2) - 1));
        X when X =< 7 ->
            T = rand:uniform(2) - 1,
            element(2, ?D:complete(S, T, rand:uniform(lists:nth(T + 1, Next) + 1) - 1, rand:uniform(2) =:= 1));
        X when X =< 10, Outbox =/= [] -> element(2, ?D:respond(S, lists:nth(rand:uniform(length(Outbox)), Outbox)));
        11 -> ?D:drain(S, #{});
        12 -> ?D:crash(S, kill);
        _ -> element(2, ?D:submit(S, rand:uniform(2) - 1, rand:uniform(2) - 1, rand:uniform(2) - 1))
    end.

%% ---------- retries and duplicates ----------

retries(Ctx, R) ->
    scenario(Ctx, retries, repeat_name(R),
      fun(S0) ->
              Pairs = [{T, K} || T <- [0, 1, 2], K <- [0, 1, 2]],
              {S, Checks} = lists:foldl(
                  fun({T, K}, {SA, CA}) ->
                          D = (T + K + R) rem 2,
                          {O1, S1} = ?D:submit_told(SA, T, K, D),
                          {O2, S2} = ?D:submit_told(S1, T, K, D),
                          {O3, S3} = ?D:submit_told(S2, T, K, D),
                          {O4, S4} = ?D:submit_told(S3, T, K, 1 - D),
                          {O5, S5} = ?D:submit_told(S4, T, K, D),
                          {S5, [check({same_receipt_on_retry, T, K}, O1 =:= O2 andalso O2 =:= O3 andalso O3 =:= O5, [O1, O2, O3, O5]),
                                check({conflict_on_other_payload, T, K}, O4 =:= {conflict, T, K}, O4) | CA]}
                  end, {S0, []}, Pairs),
               {Snap, SF} = snapshot_of(S),
               {SF, [check(one_report_per_key, [length(Reps) || [Reps, _, _, _] <- Snap] =:= [3, 3, 3], Snap) | Checks]}
      end).

duplicates(Ctx, R) ->
    scenario(Ctx, duplicates, repeat_name(R),
      fun(S0) ->
              S1 = lists:foldl(fun(K, A) -> element(2, ?D:submit_told(A, R rem 3, K, 0)) end, S0, [0, 1, 2]),
              S2 = ?D:drain(S1, #{duplicate => true}),
              {_, S3} = ?D:complete(S2, R rem 3, 0, true),
              {_, S4} = ?D:complete(S3, R rem 3, 0, false),
              {_, S5} = ?D:complete(S4, R rem 3, 7, true),
              S6 = ?D:drain(S5, #{duplicate => true}),
               {Snap, S7} = snapshot_of(S6),
              [_, Jobs, _, _] = lists:nth(R rem 3 + 1, Snap),
              Expected = [[J, J, case fenrir_runner:outcome(R rem 3, J) of true -> <<"done">>; false -> <<"failed">> end] || J <- [0, 1, 2]],
               {S7, [check(first_delivery_decides_status, Jobs =:= Expected, Jobs)]}
      end).

%% ---------- crash injection at named points ----------

%% {Point, Action, Op} and the outcome predicted for the faulted request.
crash_matrix() ->
    [{P, A, Op} || P <- [w1_before_request, w2_request_before_commit, w3_commit_before_reply, w4_reply_before_response],
                   A <- [kill_tender, kill_worker, kill_node, halt_node], Op <- [submit, complete]]
    ++ [{f1_after_response, A, Op} || A <- [kill_node, halt_node], Op <- [submit, complete]]
    ++ [{P, A, Op} || P <- [s1_after_begin, s2_mid_writes, s3_before_commit, s4_after_commit],
                      A <- [kill_port, kill_store, kill_node], Op <- [submit, complete]].

%% kill_tender before the commit: the worker sees the guest gone and commits nothing.
%% kill_port: the next statement finds the port dead; if that statement is COMMIT the
%% adapter cannot know whether it ran (indeterminate), otherwise nothing was applied.
%% After COMMIT returned (s4) the reply is already known. Anything that kills the
%% worker, the store process or the node while a request is in flight: indeterminate.
%% f1 with erlang:halt(_, [{flush, false}]): the answer already handed to the channel
%% may or may not have been written before the VM stopped.
predicted(P, kill_tender, _) when P =:= w1_before_request; P =:= w2_request_before_commit -> [aborted];
predicted(_, kill_tender, _) -> [indeterminate];
predicted(f1_after_response, kill_node, _) -> [answered];
predicted(f1_after_response, halt_node, _) -> [answered, indeterminate];
predicted(s4_after_commit, kill_port, _) -> [answered];
predicted(s1_after_begin, kill_port, _) -> [aborted];
predicted(s2_mid_writes, kill_port, submit) -> [aborted];   %% more writes follow the first
predicted(s2_mid_writes, kill_port, complete) -> [indeterminate]; %% Finish is the only write: COMMIT is next
predicted(s3_before_commit, kill_port, _) -> [indeterminate];
predicted(_, _, _) -> [indeterminate].

crash_point(Ctx, Point, Action, Op, R) ->
    Name = crash_name(Point, Action, Op, R),
    scenario(Ctx, crash_points, Name,
      fun(S0) ->
              {T, S1} = prefix(S0, R),
              {Before, SB} = snapshot_of(S1),
              {W, Pids, S2} = arm_fault(SB, Point, Action),
              {Out, Target, S3} = target(S2, Op, T, R),
              {S4, FaultCheck} = verify_fault(S2, S3, W, Point, Action, Pids),
              Outcome = classify(Out),
              {S5, Retry} = recover(S4, Target),
              {After, S6} = snapshot_of(S5),
              {Diag, SF} = case Retry of
                               gave_up ->
                                   {D, State} = ?D:cmd(S6, diag),
                                   {{D, lists:sublist(maps:get(whys, State, []), 3)}, State};
                               _ -> {none, S6}
                           end,
              {SF, [FaultCheck,
                    check(outcome_as_predicted, lists:member(Outcome, predicted(Point, Action, Op)), {Outcome, predicted(Point, Action, Op)}),
                    check(retry_definite, Retry =/= gave_up, {Retry, Diag}),
                    check(no_pending_job_after_drain, no_pending(After), After),
                    check(accepted_work_kept, kept(Before, After), {Before, After})]}
      end).

arm_fault(S, Point, Action) ->
    W = filename:join(maps:get(dir, S), "fault-receipt"),
    case file:delete(W) of ok -> ok; {error, enoent} -> ok end,
    {Pids, S1} = pids(S),
    {ok, S2} = ?D:cmd(S1, {arm, Point, Action, 1, W}),
    {W, Pids, S2}.

verify_fault(Before, S, W, Point, Action, Pids) ->
    NodeAction = Action =:= kill_node orelse Action =:= halt_node,
    S1 = case Point =:= f1_after_response andalso NodeAction andalso same_boot(Before, S) of
             true -> ?D:await_node_exit(S);
             false -> S
         end,
    {Proof, S2} = case NodeAction of
        true ->
            Beam = maps:get(beam, Pids),
            Boot = maps:get(boots, Before),
            Expected = iolist_to_binary(io_lib:format("~s ~s ~B", [Point, Action, Beam])),
            Exit = case maps:get(last_node_exit, S1, none) of {Boot, Beam, Status} -> Status; _ -> none end,
            Witness = case file:read_file(W) of {ok, Expected} -> matched; Other -> Other end,
            {{Point, Action, Beam, {Witness, Exit}}, S1};
        false ->
            case same_boot(Before, S1) of
                true -> ?D:cmd(S1, {fired, W});
                false -> {node_died, S1}
            end
    end,
    {Disarm, S3} = ?D:cmd(S2, disarm),
    SameBoot = same_boot(Before, S3),
    %% The worker's outcome independently carries the tender PID captured
    %% when the active request's session opened, not the hook's PID claim.
    Targets = Pids#{tender => maps:get(last_tender, S, none)},
    Detail = {Point, Action, Targets, SameBoot, Disarm, Proof},
    Fired = valid_fault(Detail),
    S4 = case Fired of
             true -> ?D:fault(S3, atom_to_binary(Action), atom_to_binary(Point));
             false -> S3
         end,
    FaultCheck = check(fault_fired, Fired, Detail),
    {S4#{fault_checks => [FaultCheck]}, FaultCheck}.

same_boot(S1, S2) -> maps:get(boots, S1) =:= maps:get(boots, S2).

valid_fault({P, kill_node, #{beam := B}, false, ok, {P, kill_node, B, {matched, 137}}}) -> is_os_pid(B);
valid_fault({P, halt_node, #{beam := B}, false, ok, {P, halt_node, B, {matched, 86}}}) -> is_os_pid(B);
valid_fault({P, kill_tender, #{worker := W, tender := T}, true, ok, {P, kill_tender, T, {sigkill, W}}}) ->
    is_os_pid(T) andalso is_list(W);
valid_fault({P, kill_port, #{sqlite_port := T, store := W}, true, ok, {P, kill_port, T, {sigkill, W}}}) ->
    is_os_pid(T) andalso is_list(W);
valid_fault({P, kill_worker, #{worker := T}, true, ok, {P, kill_worker, T, killed}}) -> is_list(T);
valid_fault({P, kill_store, #{store := T}, true, ok, {P, kill_store, T, killed}}) -> is_list(T);
valid_fault({s3_before_commit, lose_ack, #{sqlite_port := T}, true, ok,
             {s3_before_commit, lose_ack, T, lost_commit_ack}}) -> is_os_pid(T);
valid_fault(_) -> false.

is_os_pid(P) -> is_integer(P) andalso P > 0.

%% Report validation must also reject old or absent fault checks, not merely
%% explicitly false checks. Match the proof's exact point/action to the case.
fault_evidence(#{family := crash_points, mutant := M, name := Name, checks := Checks}) ->
    case lists:keyfind(fault_fired, 1, Checks) of
        {_, true, {P, A, _, _, _, _} = Detail} ->
            lists:any(fun({P0, A0, Op}) ->
                P =:= P0 andalso A =:= A0 andalso
                lists:any(fun(R) -> Name =:= full_name(M, crash_points, crash_name(P, A, Op, R)) end,
                          lists:seq(1, repeats(scope_config(full))))
            end, crash_matrix()) andalso valid_fault(Detail);
        _ -> false
    end;
fault_evidence(#{family := lost_ack, checks := Checks}) ->
    case lists:keyfind(fault_fired, 1, Checks) of
        {_, true, {s3_before_commit, lose_ack, _, _, _, _} = Detail} -> valid_fault(Detail);
        _ -> false
    end;
fault_evidence(#{family := F}) -> F =/= crash_points andalso F =/= lost_ack.

classify({accepted, _}) -> answered;
classify({conflict, _, _}) -> answered;
classify(delivered) -> answered;
classify(Out) -> Out.

%% A seeded prefix: 1 + R mod 2 accepted submits on tenant T = R mod 3 (keys 0 and 1
%% only, so the faulted submit's key 2 is always fresh and reaches the writes), told.
prefix(S, R) ->
    T = R rem 3,
    S1 = lists:foldl(fun(K, A) -> element(2, ?D:submit_told(A, T, K, (K + R) rem 2)) end, S, lists:seq(0, R rem 2)),
    {T, S1}.

%% The faulted request: a fresh submit (key 2 of tenant T, so it commits), or the
%% delivery of job 0 of tenant T (pending after the prefix).
target(S, submit, T, R) -> {Out, S1} = ?D:submit_told(S, T, 2, R rem 2), {Out, {submit, T, 2, R rem 2}, S1};
target(S, complete, T, _R) -> {Out, S1} = ?D:complete(S, T, 0, true), {Out, {complete, T, 0, true}, S1}.

%% After the fault: observe, retry the faulted request until definite, drain the jobs.
recover(S, Target) ->
    S1 = ?D:observe(S),
    {Retry, S2} = case Target of
                      {submit, T, K, D} -> ?D:retry_submit(S1, T, K, D, 5);
                      {complete, T, J, Ok} -> retry_complete(S1, T, J, Ok, 5)
                  end,
    S3 = ?D:drain(S2, #{}),
    {?D:observe(S3), Retry}.

retry_complete(S, _, _, _, 0) -> {gave_up, S};
retry_complete(S, T, J, Ok, N) ->
    case ?D:complete(S, T, J, Ok) of
        {delivered, S1} -> {delivered, S1};
        {_, S1} -> ?D:backoff(N), retry_complete(S1, T, J, Ok, N - 1)
    end.

no_pending(Snap) when is_list(Snap) -> [] =:= [J || [_, Jobs, _, _] <- Snap, [_, _, <<"pending">>] = J <- Jobs];
no_pending(_) -> false.

%% Every report and key entry before the fault is still there afterwards.
kept(Before, After) when is_list(Before), is_list(After) ->
    lists:all(fun({[R0, _, K0, _], [R1, _, K1, _]}) -> R0 -- R1 =:= [] andalso K0 -- K1 =:= [] end, lists:zip(Before, After));
kept(_, _) -> false.

%% ---------- kill -9 of the SQLite port program inside a transaction ----------

%% For Kind (before the n-th statement, before the n-th file write, before the n-th
%% fsync, counted from the faulted request), n = 1, 2, ... until the request finishes
%% without the fault firing. Each n is its own scenario.
sqlite_kills(Ctx, Kind, Op, R) -> sqlite_kills(Ctx, Kind, Op, R, 1, []).
sqlite_kills(Ctx, Kind, Op, R, N, Acc) ->
    Name = probe_name(Kind, Op, R, N),
    Res = scenario(Ctx#{observe_sqlite_exit => true}, sqlite_kills, Name,
            fun(S0) ->
                    {T, S1} = prefix(S0, R),
                    {Before, SB} = await_prefix(S1, T, 1 + R rem 2, 100),
                    {Pid0, SP} = pids(SB),
                    {ok, S2} = ?D:cmd(SP, {arm_port, Kind, N}),
                    {Out, Target, S3} = target(S2, Op, T, R),
                    {Pid1, SN} = pids(S3),
                    %% Disarm the port explicitly: the generic disarm command ignores port errors.
                    {Disarm, S4} = ?D:cmd(SN, {arm_port, disarm, 1}),
                    Died = maps:get(sqlite_port, Pid0) =/= maps:get(sqlite_port, Pid1),
                    SameNode = maps:get(crashes, S4) =:= maps:get(crashes, S2),
                    Exit = ?D:sqlite_exit(S3, maps:get(sqlite_port, Pid0)),
                    Applied = target_applied(Op, Target, S2, S3),
                    Probe = sweep_result(Op, Out, {Died, SameNode}, Exit, Disarm, Applied),
                    S6 = case Probe of fired -> ?D:fault(S4, <<"sqlite_port">>, atom_to_binary(Kind)); _ -> S4 end,
                    {S7, Retry} = recover(S6, Target),
                    {After, SF} = snapshot_of(S7),
                    {SF, [check(sqlite_probe, Probe =/= unverified, {Probe, Out, Died, SameNode, Exit, Disarm, Applied}),
                          check(retry_definite, Retry =/= gave_up, Retry),
                          check(no_pending_job_after_drain, no_pending(After), After),
                          check(accepted_work_kept, kept(Before, After), {Before, After})]}
            end),
    Probe = case lists:keyfind(sqlite_probe, 1, maps:get(checks, Res, [])) of
                {_, _, {P, _, _, _, _, _, _}} -> P;
                false -> unverified
            end,
    End = case {Probe, N} of
              {fired, ?SQLITE_LIMIT} -> limit_reached;
              {fired, _} -> continue;
              {beyond, 1} -> no_fault_fired;
              {beyond, _} -> completed;
              {unverified, _} -> unverified
          end,
    M = maps:get(mutant, Res),
    Row = Res#{sweep => {M, Kind, Op, R}, probe_index => N, sweep_end => End,
               fired => Probe =:= fired, beyond_last_point => End =:= completed},
    case End of
        continue -> sqlite_kills(Ctx, Kind, Op, R, N + 1, [Row | Acc]);
        _ -> lists:reverse([Row | Acc])
    end.

target_applied(Op, Target, Before, After) ->
    case {maps:get(coverage, After), maps:get(coverage, Before)} of
        {[{Target, [Reply]} | Old], Old} ->
            case {Op, json:decode(Reply)} of
                {submit, [_, _, <<"Committed">>, _]} -> true;
                {complete, [_, _, <<"Applied">>]} -> true;
                _ -> false
            end;
        _ -> false
    end.

%% For a firing, the observer must have reaped the armed child with SIGKILL,
%% not merely observed a new port PID (which can happen after a crash or timeout).
sweep_result(_, _, {true, true}, 137, ok, _) -> fired;
sweep_result(submit, {accepted, _}, {false, true}, none, ok, true) -> beyond;
sweep_result(complete, delivered, {false, true}, none, ok, true) -> beyond;
sweep_result(_, _, _, _, _, _) -> unverified.

%% The early-reply mutant can still be flushing the setup requests. Do not
%% arm while they are pending; count statements only in the targeted request.
await_prefix(S, T, Count, 0) ->
    require_probe(sqlite_prefix, {unavailable, ?D:gap(S, <<"sqlite prefix unavailable">>, {T, Count})});
await_prefix(S, T, Count, N) ->
    {Snap, S1} = snapshot_of(S),
    case lists:nth(T + 1, Snap) of
        [Reports, _, Keys, Count] when length(Reports) =:= Count, length(Keys) =:= Count -> {Snap, S1};
        _ -> timer:sleep(20), await_prefix(S1, T, Count, N - 1)
    end.

%% The node's process ids, once its store is up again (it restarts after a port death).
pids(S) -> pids(S, 50).
pids(S, N) ->
    case ?D:call(S, pids) of
        {ok, #{sqlite_port := P} = M, S1} when is_integer(P) -> {M, S1};
        {ok, _, S1} when N > 0 -> timer:sleep(20), pids(S1, N - 1);
        {ok, Why, S1} -> require_probe(pids, {unavailable, ?D:gap(S1, <<"process IDs unavailable">>, Why)});
        {died, Why, S1} -> require_probe(pids, ?D:abort_probe(S1, pids, Why))
    end.

%% ---------- lost acknowledgment ----------

lost_ack(Ctx, Op, R) ->
    scenario(Ctx, lost_ack, op_name(Op, R),
      fun(S0) ->
              {T, S1} = prefix(S0, R),
               {Before, SB} = snapshot_of(S1),
               {W, Pids, S2} = arm_fault(SB, s3_before_commit, lose_ack),
               {Out, Target, S3} = target(S2, Op, T, R),
               {S5, FaultCheck} = verify_fault(S2, S3, W, s3_before_commit, lose_ack, Pids),
               {Mid, SM} = snapshot_of(S5),
               S6 = ?D:observe(SM),
              {Retry, S7} = case Target of
                                {submit, _, K, D} -> ?D:retry_submit(S6, T, K, D, 5);
                                {complete, _, J, Ok} -> retry_complete(S6, T, J, Ok, 5)
                            end,
               {After, SF} = snapshot_of(S7),
               {Expected, ExpectedRetry} = lost_ack_expected(Target, Before),
               Committed = is_list(Mid) andalso Mid =:= Expected,
               {SF, [FaultCheck, check(caller_sees_indeterminate, Out =:= indeterminate, Out),
                     check(commit_survived_lost_ack, Committed, {Expected, Mid}),
                     check(retry_returns_recorded_receipt, Retry =:= ExpectedRetry, {Retry, ExpectedRetry}),
                     check(no_second_mutation, is_list(Mid) andalso Mid =:= After, {Mid, After})]}
       end).

lost_ack_expected({submit, T, K, D}, Before) when is_list(Before) ->
    {Prefix, [[R, J, Keys, N] | Tail]} = lists:split(T, Before),
    Receipt = [T, K, D, N, N],
    Row = [R ++ [[N, D]], J ++ [[N, N, <<"pending">>]], Keys ++ [[K, D, Receipt]], N + 1],
    {Prefix ++ [Row | Tail], {accepted, Receipt}};
lost_ack_expected({complete, T, J, Ok}, Before) when is_list(Before) ->
    {Prefix, [[R, Jobs, Keys, N] | Tail]} = lists:split(T, Before),
    Status = case Ok of true -> <<"done">>; false -> <<"failed">> end,
    Row = [R, [case Row of [J, Report, _] -> [J, Report, Status]; _ -> Row end || Row <- Jobs], Keys, N],
    {Prefix ++ [Row | Tail], delivered};
lost_ack_expected(_, _) -> {unavailable, unavailable}.

%% ---------- busy: a second connection holds the write lock ----------

busy(Ctx, Op, R) ->
    scenario(Ctx, busy, op_name(Op, R),
      fun(S0) ->
              {T, S1} = prefix(S0, R),
               {Before, SB} = snapshot_of(S1),
              {ok, P} = fenrir_sqlite:open(maps:get(db, S1)),
              {rows, _} = fenrir_sqlite:exec(P, "PRAGMA busy_timeout=0"),
              {rows, _} = fenrir_sqlite:exec(P, "BEGIN IMMEDIATE"),
               {Out, Target, S2} = target(SB, Op, T, R),
               %% Release the lock even when the post-request snapshot is unavailable.
               {Mid, SM} = try snapshot_of(S2)
                           after
                               fenrir_sqlite:exec(P, "ROLLBACK"),
                               fenrir_sqlite:close(P)
                           end,
               S3 = ?D:observe(SM),
              {Retry, S4} = case Target of
                                {submit, _, K, D} -> ?D:retry_submit(S3, T, K, D, 5);
                                {complete, _, J, Ok} -> retry_complete(S3, T, J, Ok, 5)
                            end,
              {S4, [check(adapter_reports_busy, Out =:= busy, Out),
                    check(nothing_half_applied, Mid =:= Before, {Before, Mid}),
                    check(later_retry_succeeds, Retry =/= gave_up andalso Retry =/= busy, Retry)]}
      end).

%% ---------- two workers on one store ----------

two_workers(Ctx, R, Batches) ->
    scenario(Ctx, two_workers, repeat_name(R), #{workers => 2},
      fun(S0) ->
              rand:seed(exsss, {R, 4242, 1}),
              {S, Us} = lists:foldl(
                  fun(_, {SA, UA}) ->
                          Reqs = [{submit, rand:uniform(2) - 1, rand:uniform(3) - 1, rand:uniform(2) - 1, none} || _ <- [1, 2]],
                          Reqs2 = [{submit, T, K, D, <<D>>} || {submit, T, K, D, _} <- Reqs],
                          {_, U, SB} = ?D:concurrent(SA, Reqs2),
                          {SB, [U | UA]}
                  end, {S0, []}, lists:seq(1, Batches)),
              S1 = ?D:drain(S, #{}),
              {S1#{latencies := maps:get(latencies, S1)}, [check(concurrent_batches_us, true, lists:reverse(Us))]}
      end).
