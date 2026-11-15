%% A3 campaigns (host/service/CONTRACT.md maps each named assumption to the scenarios
%% here). Deterministic and seeded: a scenario's workload is a function of its name and
%% its repeat index. Each scenario runs on a fresh SQLite file and a fresh service node,
%% writes a history (checked afterwards by harness/service-history.shen) and audits the
%% SQLite file directly after every crash and at the end.
%%
%%   erl -noshell -pa EBIN -run fenrir_campaign main CONFIG
%% CONFIG: one Erlang map (consulted), see host/service/check.sh.
-module(fenrir_campaign).
-export([main/1]).
%% Shared with the A4 campaigns (fenrir_campaign_a4).
-export([ctx/3, scenario/5, check/3, snapshot_of/1, no_pending/1, retry_complete/5]).

-define(D, fenrir_drive).

main([ConfigFile]) ->
    {ok, [C]} = file:consult(ConfigFile),
    Out = maps:get(out, C),
    T0 = erlang:monotonic_time(millisecond),
    Families = maps:get(families, C, all),
    Want = fun(F) -> Families =:= all orelse lists:member(F, Families) end,
    Ctx = ctx(C, normal, 1),
    R = lists:append(
          [run_family(F, Ctx, C) || F <- [hand_traces, a2_runs, random_schedules, retries, duplicates,
                                           crash_points, sqlite_kills, lost_ack, busy, two_workers], Want(F)]
          ++ [mutant_suite(M, C) || Want(mutants), M <- maps:get(mutants, C)]
          ++ fenrir_campaign_a4:families(C, Want)
          ++ [fenrir_campaign_a4:mutant_suite(M, C) || Want(a4_mutants), M <- maps:get(a4_mutants, C, [])]),
    ok = file:write_file(filename:join(Out, "scenarios.bin"), term_to_binary(R)),
    Hist = [maps:get(history, X) || X <- R, maps:is_key(history, X)],
    ok = file:write_file(filename:join(Out, "histories.txt"), [[H, $\n] || H <- Hist]),
    io:format("campaign: ~p scenarios, ~p ms~n", [length(R), erlang:monotonic_time(millisecond) - T0]),
    halt(0).

ctx(C, Mutant, Workers) ->
    #{erl => maps:get(erl, C), ebin => maps:get(ebin, C), node_launch => maps:get(node_launch, C),
      sqlite_port => maps:get(sqlite_port, C), out => maps:get(out, C),
      config => #{tenants => maps:get(tenants, C, 3), image => maps:get(image, C), launcher => maps:get(launcher, C),
                  workers => Workers, mutant => Mutant}}.

repeats(C) -> maps:get(repeats, C).

%% ---------- scenario frame ----------

%% Run Fun(S) on a fresh store and node; returns the scenario record.
scenario(Ctx, Family, Name, Fun) -> scenario(Ctx, Family, Name, #{}, Fun).
scenario(Ctx0, Family, Name, Over, Fun) ->
    Ctx = Ctx0#{config := maps:merge(maps:get(config, Ctx0), Over)},
    Mutant = maps:get(mutant, maps:get(config, Ctx)),
    Full = lists:flatten(io_lib:format("~s/~s/~s", [Mutant, Family, Name])),
    S0 = ?D:new(Ctx, Full),
    T0 = erlang:monotonic_time(microsecond),
    case ?D:start(S0) of
        {start_failed, Why} ->
            #{family => Family, name => Full, mutant => Mutant, status => start_failed, detail => Why};
        S1 ->
            {S2, Checks} = try Fun(S1) of
                               {SX, CX} -> {SX, CX}
                           catch Cl:Er:St -> {?D:kill(S1), [{exception, false, {Cl, Er, lists:sublist(St, 4)}}]}
                           end,
            S3 = case maps:get(node, S2) of none -> S2; _ -> ?D:observe(S2) end,
            S4 = ?D:stop(S3),
            Audit = ?D:audit(maps:get(db, S4), ?D:told(S4)),
            Tenants = maps:get(tenants, maps:get(config, Ctx)),
            File = ?D:write_history(S4, Tenants, #{<<"family">> => atom_to_binary(Family),
                                                   <<"mutant">> => atom_to_binary(Mutant)}),
            CrashAudits = [V || {_, V} <- maps:get(audits, S4, [])],
            #{family => Family, name => Full, mutant => Mutant, history => File,
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
    lists:append([sqlite_kills(Ctx, Kind, Op, R) || Kind <- [before_statement, write, sync], Op <- [submit, complete],
                                                    R <- lists:seq(1, maps:get(sqlite_kill_repeats, C, 1))]);
run_family(lost_ack, Ctx, C) -> [lost_ack(Ctx, Op, R) || Op <- [submit, complete], R <- lists:seq(1, repeats(C))];
run_family(busy, Ctx, C) -> [busy(Ctx, Op, R) || Op <- [submit, complete], R <- lists:seq(1, repeats(C))];
run_family(two_workers, Ctx, C) -> [two_workers(Ctx, R, maps:get(concurrent_batches, C, 10)) || R <- lists:seq(1, repeats(C))].

%% The scenarios a host mutant is run against (and the equivalent control).
mutant_suite(Mutant, C) ->
    Ctx = ctx(C, Mutant, 1),
    [retries(Ctx, 1), duplicates(Ctx, 1), busy(Ctx, submit, 1),
     crash_point(Ctx, f1_after_response, kill_node, submit, 1),
     crash_point(Ctx, w4_reply_before_response, kill_node, submit, 1),
     lost_ack(Ctx, submit, 1)]
    ++ sqlite_kills(Ctx, before_statement, submit, 1)
    ++ [random_schedule(Ctx, Seed, 10) || Seed <- lists:seq(1, maps:get(mutant_random_schedules, C, 3))].

%% ---------- hand traces (spec/service/hand-traces.json) ----------

hand_trace(Ctx, Tenants, T) ->
    Name = binary_to_list(maps:get(<<"name">>, T)),
    scenario(Ctx, hand_traces, Name, #{tenants => Tenants},
      fun(S0) ->
              {S, Resps, Disabled} = hand_steps(S0, maps:get(<<"schedule">>, T), [], 0),
              Outbox = case ?D:call(S, outbox) of {ok, O, _} -> O; _ -> [] end,
              Final = [snapshot_of(S), [ev(E) || E <- Outbox], [ev(E) || E <- lists:reverse(?D:told(S))]],
              case maps:get(<<"disabled_at">>, T, none) of
                  none -> {S, [check(responses_as_derived_by_hand, Resps =:= maps:get(<<"responses">>, T), Resps),
                               check(final_state_as_derived_by_hand, json:decode(iolist_to_binary(json:encode(Final))) =:= maps:get(<<"final">>, T), Final)]};
                  N -> {S, [check(disabled_at_as_derived_by_hand, Disabled =:= N, Disabled)]}
              end
      end).

snapshot_of(S) -> snapshot_of(S, 100).
snapshot_of(S, N) ->
    case ?D:call(S, snapshot) of
        {ok, St, _} when is_list(St) -> St;
        {ok, _, _} when N > 0 -> timer:sleep(20), snapshot_of(S, N - 1); %% the store is restarting
        _ -> unavailable
    end.

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
    Name = lists:flatten(io_lib:format("run-~2..0B", [I])),
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
    Name = lists:flatten(io_lib:format("seed-~3..0B", [Seed])),
    scenario(Ctx, random_schedules, Name,
      fun(S0) ->
              rand:seed(exsss, {Seed, 1009, 7}),
              S = lists:foldl(fun(_, Acc) -> random_step(Acc) end, S0, lists:seq(1, Len)),
              {S, []}
      end).

random_step(S) ->
    Outbox = case ?D:call(S, outbox) of {ok, O, _} -> O; _ -> [] end,
    Next = case ?D:call(S, snapshot) of {ok, St, _} -> [N || [_, _, _, N] <- St]; _ -> [0, 0, 0] end,
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
    scenario(Ctx, retries, "repeat-" ++ integer_to_list(R),
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
              Snap = snapshot_of(S),
              {S, [check(one_report_per_key, [length(Reps) || [Reps, _, _, _] <- Snap] =:= [3, 3, 3], Snap) | Checks]}
      end).

duplicates(Ctx, R) ->
    scenario(Ctx, duplicates, "repeat-" ++ integer_to_list(R),
      fun(S0) ->
              S1 = lists:foldl(fun(K, A) -> element(2, ?D:submit_told(A, R rem 3, K, 0)) end, S0, [0, 1, 2]),
              S2 = ?D:drain(S1, #{duplicate => true}),
              {_, S3} = ?D:complete(S2, R rem 3, 0, true),
              {_, S4} = ?D:complete(S3, R rem 3, 0, false),
              {_, S5} = ?D:complete(S4, R rem 3, 7, true),
              S6 = ?D:drain(S5, #{duplicate => true}),
              Snap = snapshot_of(S6),
              [_, Jobs, _, _] = lists:nth(R rem 3 + 1, Snap),
              Expected = [[J, J, case fenrir_runner:outcome(R rem 3, J) of true -> <<"done">>; false -> <<"failed">> end] || J <- [0, 1, 2]],
              {S6, [check(first_delivery_decides_status, Jobs =:= Expected, Jobs)]}
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
    Name = lists:flatten(io_lib:format("~s-~s-~s-~B", [Point, Action, Op, R])),
    scenario(Ctx, crash_points, Name,
      fun(S0) ->
              {T, S1} = prefix(S0, R),
              Before = snapshot_of(S1),
              {ok, S2} = ?D:cmd(S1, {arm, Point, Action, 1}),
              {Out, Target, S3} = target(S2, Op, T, R),
              {FiredList, S3a} = ?D:cmd(S3, fired),
              NodeDied = maps:get(crashes, S3a) > maps:get(crashes, S2),
              Fired = NodeDied orelse (is_list(FiredList) andalso FiredList =/= []),
              {_, S3b} = ?D:cmd(S3a, disarm),
              S4 = note_fault(S3b, Fired andalso not NodeDied, Action, Point),
              Outcome = classify(Out, NodeDied),
              {S5, Retry} = recover(S4, Target),
              After = snapshot_of(S5),
              Diag = case Retry of gave_up -> {element(1, ?D:cmd(S5, diag)), lists:sublist(maps:get(whys, S5, []), 3)}; _ -> none end,
              {S5, [check(fault_fired, Fired, Point),
                    check(outcome_as_predicted, lists:member(Outcome, predicted(Point, Action, Op)), {Outcome, predicted(Point, Action, Op)}),
                    check(retry_definite, Retry =/= gave_up, {Retry, Diag}),
                    check(no_pending_job_after_drain, no_pending(After), After),
                    check(accepted_work_kept, kept(Before, After), {Before, After})]}
      end).

note_fault(S, true, Action, Point) -> ?D:fault(S, atom_to_binary(Action), atom_to_binary(Point));
note_fault(S, _, _, _) -> S.

classify({accepted, _}, _) -> answered;
classify({conflict, _, _}, _) -> answered;
classify(delivered, _) -> answered;
classify(Out, _) -> Out.

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
sqlite_kills(Ctx, Kind, Op, R, N, Acc) when N =< 40 ->
    Name = lists:flatten(io_lib:format("~s-~B-~s-~B", [Kind, N, Op, R])),
    Res = scenario(Ctx, sqlite_kills, Name,
            fun(S0) ->
                    {T, S1} = prefix(S0, R),
                    Before = snapshot_of(S1),
                    Pid0 = pids(S1),
                    {ok, S2} = ?D:cmd(S1, {arm_port, Kind, N}),
                    {Out, Target, S3} = target(S2, Op, T, R),
                    Pid1 = pids(S3), S4 = S3,
                    Died = maps:get(sqlite_port, Pid0) =/= maps:get(sqlite_port, Pid1),
                    S5 = case Died of true -> ?D:fault(S4, <<"sqlite_port">>, atom_to_binary(Kind)); false -> S4 end,
                    {_, S6} = ?D:cmd(S5, disarm),
                    {S7, Retry} = recover(S6, Target),
                    After = snapshot_of(S7),
                    put(fired, Died),
                    {S7, [check(port_killed_or_beyond, true, {Died, Out}),
                          check(retry_definite, Retry =/= gave_up, Retry),
                          check(no_pending_job_after_drain, no_pending(After), After),
                          check(accepted_work_kept, kept(Before, After), {Before, After})]}
            end),
    case erase(fired) of
        true -> sqlite_kills(Ctx, Kind, Op, R, N + 1, [Res#{fired => true} | Acc]);
        _ -> lists:reverse([Res#{fired => false, beyond_last_point => true} | Acc])
    end;
sqlite_kills(_, _, _, _, _, Acc) -> lists:reverse(Acc).

%% The node's process ids, once its store is up again (it restarts after a port death).
pids(S) -> pids(S, 50).
pids(S, 0) -> error({no_pids, maps:get(name, S)});
pids(S, N) ->
    case ?D:call(S, pids) of
        {ok, #{sqlite_port := P} = M, _} when is_integer(P) -> M;
        _ -> timer:sleep(20), pids(S, N - 1)
    end.

%% ---------- lost acknowledgment ----------

lost_ack(Ctx, Op, R) ->
    scenario(Ctx, lost_ack, lists:flatten(io_lib:format("~s-~B", [Op, R])),
      fun(S0) ->
              {T, S1} = prefix(S0, R),
              Before = snapshot_of(S1),
              {ok, S2} = ?D:cmd(S1, {arm, s3_before_commit, lose_ack, 1}),
              {Out, Target, S3} = target(S2, Op, T, R),
              S4 = ?D:fault(S3, <<"sqlite_port">>, <<"lose_ack">>),
              {_, S5} = ?D:cmd(S4, disarm),
              Mid = snapshot_of(S5),
              S6 = ?D:observe(S5),
              {Retry, S7} = case Target of
                                {submit, _, K, D} -> ?D:retry_submit(S6, T, K, D, 5);
                                {complete, _, J, Ok} -> retry_complete(S6, T, J, Ok, 5)
                            end,
              After = snapshot_of(S7),
              Committed = Mid =/= Before,
              Receipt = case Target of
                            {submit, _, K2, D2} -> [Rc || [_, _, Keys, _] <- [lists:nth(T + 1, After)], [K3, D3, Rc] <- Keys, {K3, D3} =:= {K2, D2}];
                            _ -> none
                        end,
              {S7, [check(caller_sees_indeterminate, Out =:= indeterminate, Out),
                    check(commit_survived_lost_ack, Committed, {Before, Mid}),
                    check(retry_returns_recorded_receipt,
                          case Target of {submit, _, _, _} -> [element(2, Retry)] =:= Receipt; _ -> Retry =:= delivered end, {Retry, Receipt}),
                    check(no_second_mutation, Mid =:= After, {Mid, After})]}
      end).

%% ---------- busy: a second connection holds the write lock ----------

busy(Ctx, Op, R) ->
    scenario(Ctx, busy, lists:flatten(io_lib:format("~s-~B", [Op, R])),
      fun(S0) ->
              {T, S1} = prefix(S0, R),
              Before = snapshot_of(S1),
              {ok, P} = fenrir_sqlite:open(maps:get(db, S1)),
              {rows, _} = fenrir_sqlite:exec(P, "PRAGMA busy_timeout=0"),
              {rows, _} = fenrir_sqlite:exec(P, "BEGIN IMMEDIATE"),
              {Out, Target, S2} = target(S1, Op, T, R),
              Mid = snapshot_of(S2),
              S3 = ?D:observe(S2),
              {rows, _} = fenrir_sqlite:exec(P, "ROLLBACK"),
              fenrir_sqlite:close(P),
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
    scenario(Ctx, two_workers, "repeat-" ++ integer_to_list(R), #{workers => 2},
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
