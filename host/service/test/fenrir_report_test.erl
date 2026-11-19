%% Regression checks for A3's evidence gate, with no node or guest required.
-module(fenrir_report_test).
-export([tests/1]).

tests(Root) ->
    lists:append([checks(Root, Mode) || Mode <- [quick, full]]).

checks(Root, Mode) ->
    C = (fenrir_campaign:scope_config(Mode))#{mode => Mode, families => all, root => Root,
        hand_traces => filename:join(Root, "spec/service/hand-traces.json"),
        a2_runs => filename:join(Root, "tests/host/a2-runs.json")},
    #{cases := Cases, sweeps := Sweeps, limit := Limit} = fenrir_campaign:declared_scope(C),
    Rows = [row(M, F, Name) || {M, F, Name} <- Cases] ++ lists:append([sweep(K) || K <- Sweeps]),
    V = [verdict(R) || R <- Rows],
    NegScope = fenrir_report:negative_scope(Root),
    Neg = [control(P, Def) || {P, Def} <- maps:to_list(NegScope)],
    Assess = fun(Config, Rs, Vs, Ns) -> fenrir_report:assess(Config, Rs, Vs, Ns, NegScope) end,
    Complete = fun(Config, Rs, Vs, Ns) ->
        {Scope, Assessed, Mutants, _} = Assess(Config, Rs, Vs, Ns),
        fenrir_report:status(Scope, Assessed, Mutants, true, {[], "0"}) =:= <<"development-pass">>
    end,
    Partial = [R || R <- Rows, maps:get(family, R) =/= two_workers],
    NoEq = [R || R <- Rows, maps:get(mutant, R) =/= equivalent_control],
    OneRetry = [R || R <- Rows, maps:get(mutant, R) =:= normal, maps:get(family, R) =:= retries],
    [K | _] = Sweeps,
    Rest = [R || R <- Rows, maps:get(sweep, R, none) =/= K],
    NoFault = [probe(K, 1, false, no_fault_fired) | Rest],
    Boundary = [probe(K, N, true, continue) || N <- lists:seq(1, Limit - 1)]
        ++ [probe(K, Limit, true, limit_reached) | Rest],
    Hole = [probe(K, 1, true, continue), probe(K, 3, false, completed) | Rest],
    FailedMutant = [failed_mutant(R) || R <- Rows],
    MutantReport = fun(M, Rs, Vs) ->
        {_, _, Ms, _} = Assess(C, Rs, Vs, Neg),
        hd([R || R <- Ms, maps:get(<<"mutant">>, R) =:= atom_to_binary(M)])
    end,
    WithFreshVerdicts = fun(Rs) -> [verdict(R) || R <- Rs, maps:is_key(history, R)] end,
    ErrorIsNotKill = fun(Rs) ->
        M = MutantReport(volatile_mailbox, Rs, WithFreshVerdicts(Rs)),
        not maps:get(<<"as_expected">>, M) andalso maps:get(<<"caught_by_sqlite_audit">>, M) =:= []
    end,
    OnlyBadHistory = [R#{audit_clean => true} || R <- Rows],
    TestCases = [
        {exact_scope, Complete(C, Rows, V, Neg)},
        {missing_family, not Complete(C, Partial, WithFreshVerdicts(Partial), Neg)},
        {only_one_family, not Complete(C#{families => [retries]}, OneRetry, WithFreshVerdicts(OneRetry), Neg)},
        {shorter_schedule, not Complete(C#{schedule_length => 1}, Rows, V, Neg)},
        {substitute_fixture, not Complete(C#{hand_traces => "/not-the-canonical-fixture"}, Rows, V, Neg)},
        {duplicate_scenario, not Complete(C, [hd(Rows) | Rows], V, Neg)},
        {duplicate_verdict, not Complete(C, Rows, [hd(V) | V], Neg)},
        {missing_verdict, not Complete(C, Rows, tl(V), Neg)},
        {negative_subset, not Complete(C, Rows, V, tl(Neg))},
        {negative_duplicate, not Complete(C, Rows, V, [hd(Neg) | Neg])},
        {negative_wrong_expectation, not Complete(C, Rows, V, [(hd(Neg))#{<<"expect">> => <<"unreadable">>} | tl(Neg)])},
        {negative_wrong_index, not Complete(C, Rows, V, [(hd(Neg))#{<<"first_inadmissible">> => #{<<"index">> => -1}} | tl(Neg)])},
        {history_checker_exit, begin
            {Scope, Assessed, Ms, _} = Assess(C, Rows, V, Neg),
            fenrir_report:status(Scope, Assessed, Ms, true, {[], "2"}) =:= <<"development-fail">>
        end},
        {empty_equivalent_control, not maps:get(<<"as_expected">>, MutantReport(equivalent_control, NoEq, WithFreshVerdicts(NoEq)))},
        {startup_failure_not_kill, ErrorIsNotKill(FailedMutant)},
        {execution_error_not_kill, ErrorIsNotKill([case maps:get(status, R) of
            start_failed -> R#{status := execution_error}; _ -> R end || R <- FailedMutant])},
        {indeterminate_history_not_kill, not maps:get(<<"as_expected">>,
            MutantReport(volatile_mailbox, OnlyBadHistory,
                         [indeterminate(R, verdict(R)) || R <- OnlyBadHistory]))},
        {no_faults_fired, not Complete(C, NoFault, WithFreshVerdicts(NoFault), Neg)},
        {sweep_limit, not Complete(C, Boundary, WithFreshVerdicts(Boundary), Neg)},
        {sweep_hole, not Complete(C, Hole, WithFreshVerdicts(Hole), Neg)},
        {pid_change_without_sigkill, fenrir_campaign:sweep_result(submit, aborted, {true, true}, 1, ok, false) =:= unverified},
        {request_did_not_apply, fenrir_campaign:sweep_result(complete, delivered, {false, true}, none, ok, false) =:= unverified}
    ],
    [{{a3_report, Mode, Name}, Pass, regression} || {Name, Pass} <- TestCases].

row(M, F, Name) ->
    #{mutant => M, family => F, name => Name, status => executed, events => 1, gaps => [],
      history => "/synthetic/" ++ Name, checks_ok => true, checks => [],
      audit_clean => lists:member(M, [normal, equivalent_control, sync_off])}.

failed_mutant(R = #{mutant := volatile_mailbox}) -> maps:remove(history, R#{status := start_failed, detail => test});
failed_mutant(R) -> R.

indeterminate(#{mutant := volatile_mailbox}, V) -> V#{<<"verdict">> := <<"indeterminate">>};
indeterminate(_, V) -> V.

verdict(#{name := Name, history := Path}) ->
    #{<<"scenario">> => list_to_binary(Name), <<"history">> => list_to_binary(Path), <<"events">> => 1,
      <<"verdict">> => <<"accepted">>, <<"expect">> => <<"none">>, <<"model_steps">> => 1}.

control(Path, {Scenario, Expect, Index, Events}) ->
    V = #{<<"history">> => Path, <<"scenario">> => Scenario, <<"events">> => Events,
          <<"expect">> => Expect, <<"verdict">> => Expect},
    case Index of null -> V; _ -> V#{<<"first_inadmissible">> => #{<<"index">> => Index}} end.

sweep(K) -> [probe(K, 1, true, continue), probe(K, 2, false, completed)].

probe(K = {M, _, Op, _}, N, Fired, End) ->
    Base = row(M, sqlite_kills, fenrir_campaign:sweep_name(K, N)),
    Out = case Op of submit -> {accepted, receipt}; complete -> delivered end,
    Probe = case Fired of true -> {fired, aborted, true, true, 137, ok, false};
                          false -> {beyond, Out, false, true, none, ok, true} end,
    Base#{sweep => K, probe_index => N, sweep_end => End, fired => Fired,
          beyond_last_point => End =:= completed, checks := [{sqlite_probe, true, Probe}]}.
