%% A3: the check's JSON report (house style: status development-pass / development-fail,
%% evidence, qualification UNKNOWN, counts, tool identities).
%%
%%   erl -noshell -pa EBIN -run fenrir_report main CONFIG HISTORY_EXIT
-module(fenrir_report).
-export([main/1, assess/5, status/5, negative_scope/1]).

main([ConfigFile, HistExit]) ->
    {ok, [C]} = file:consult(ConfigFile),
    Out = maps:get(out, C),
    {Scen, ScenErrors} = input(scenarios, fun() ->
        {ok, SB} = file:read_file(filename:join(Out, "scenarios.bin")),
        binary_to_term(SB)
    end),
    {Verdicts, VerdictErrors} = input(verdicts, fun() -> jsonl(filename:join(Out, "verdicts/verdicts.jsonl")) end),
    {Negatives, NegErrors} = input(negative_verdicts, fun() -> jsonl(filename:join(Out, "negative/verdicts.jsonl")) end),
    Unit = case file:read_file(filename:join(Out, "unit.json")) of {ok, U} -> json:decode(U); _ -> #{<<"passed">> => 0, <<"failed">> => 1, <<"tests">> => []} end,
    InputErrors = ScenErrors ++ VerdictErrors ++ NegErrors,
    {Scope, Rows, Mutants, Neg} = assess(C, Scen, Verdicts, Negatives, negative_scope(maps:get(root, C))),
    Normal = [R || R <- Rows, maps:get(mutant, R) =:= normal],
    Families = maps:get(families, fenrir_campaign:declared_scope(C)),
    FamilyJson = maps:from_list([{atom_to_binary(F), family(F, [R || R <- Normal, maps:get(family, R) =:= F])} || F <- Families]),
    UnitOk = maps:get(<<"failed">>, Unit) =:= 0 andalso maps:get(<<"passed">>, Unit) > 0,
    Complete = maps:get(<<"complete">>, Scope) andalso InputErrors =:= [] andalso HistExit =:= "0",
    Status = status(Scope, Rows, Mutants, UnitOk, {InputErrors, HistExit}),
    Lat = lists:sort(lists:append([maps:get(latencies_us, R, []) || R <- Normal, maps:get(family, R) =/= two_workers])),
    Boots = lists:sort([maps:get(node_start_us, R, 0) || R <- Normal, maps:get(node_start_us, R, 0) > 0]),
    TwoW = lists:append([us_batches(R) || R <- Normal, maps:get(family, R) =:= two_workers]),
    {ok, IB} = file:read_file(maps:get(image, C)),
    I = json:decode(IB),
    Report =
        #{<<"schema">> => <<"fenrir.host.service-check/1">>,
          <<"status">> => Status,
          <<"evidence">> => case Status of <<"development-pass">> -> <<"observed history accepted; bounded crash campaign">>;
                                           _ -> <<"UNKNOWN: development check did not pass">> end,
          <<"qualification">> => <<"UNKNOWN">>,
          <<"stage">> => <<"A3 (04_DIRECTION_AMENDMENT.md section 8)">>,
          <<"contract">> => [<<"spec/service/ACCEPTED_JOB.md">>, <<"spec/service/HANDLER.md">>, <<"host/service/CONTRACT.md">>],
          <<"mode">> => atom_to_binary(maps:get(mode, C)),
          <<"scope">> => Scope#{<<"complete">> := Complete, <<"input_errors">> => InputErrors,
                                 <<"history_checker_exit">> => list_to_binary(HistExit)},
          <<"artifact_source">> => list_to_binary(maps:get(artifact_source, C)),
          <<"identities">> => identities(C, I),
          <<"unit_tests">> => #{<<"passed">> => maps:get(<<"passed">>, Unit), <<"failed">> => maps:get(<<"failed">>, Unit),
                                <<"failures">> => [T || T <- maps:get(<<"tests">>, Unit), maps:get(<<"pass">>, T) =:= false]},
          <<"campaigns">> => FamilyJson,
          <<"normal_stack">> => #{<<"scenarios">> => length(Normal),
                                  <<"histories_accepted">> => count(fun(R) -> maps:get(verdict, R) =:= <<"accepted">> end, Normal),
                                  <<"flagged">> => [flag_json(R) || R <- Normal, maps:get(flagged, R)],
                                  <<"node_crashes_observed">> => lists:sum([maps:get(crashes, R, 0) || R <- Normal]),
                                  <<"requests">> => lists:sum([maps:get(requests, R, 0) || R <- Normal]),
                                  <<"a2_run_coverage">> => a2_coverage(C, Normal)},
          <<"host_mutants">> => Mutants,
          <<"history_checker_negative_tests">> => Neg,
          <<"latency">> => #{<<"request_boot_plus_run_us">> => dist(Lat),
                             <<"node_start_us">> => dist(Boots),
                             <<"two_worker_batch_of_2_us">> => dist(lists:sort(TwoW)),
                             <<"note">> => <<"one request per tender boot (protocol v2 runs one program per boot); request_boot_plus_run_us is the worker's wall time from spawning solo5-spt to Bye and exit, including the SQLite commit; development timings, not a performance claim">>},
          <<"not_covered">> => [<<"power loss and fsync honesty: kill -9 of a process cannot drop the OS page cache, so synchronous=OFF is NOT DETECTED by this campaign">>,
                                <<"disk corruption, torn sectors, a lying disk">>, <<"SQLite itself">>, <<"OTP itself">>,
                                <<"isolation between several workers on one store beyond the observed serialized runs (one adapter process serializes commits)">>,
                                <<"production client authentication and credential lifecycle (the campaign controller is privileged)">>,
                                <<"performance">>, <<"requests outside the image's request domain (protocol v2 lowers entry inputs into the image)">>]},
    ok = file:write_file(filename:join(Out, "report.json"), json:encode(Report)),
    halt(0).

input(Name, Read) ->
    try Read() of L when is_list(L) -> {L, []}
    catch Cl:Why -> {[], [print_term({Name, Cl, Why})]}
    end.

jsonl(File) ->
    {ok, B} = file:read_file(File),
    [json:decode(L) || L <- binary:split(B, <<"\n">>, [global, trim_all])].

status(#{<<"complete">> := true}, Rows, Mutants, true, {[], "0"}) ->
    Normal = [R || R <- Rows, maps:get(mutant, R) =:= normal],
    case Normal =/= [] andalso lists:all(fun(R) -> not maps:get(flagged, R) end, Normal)
            andalso lists:all(fun(M) -> maps:get(<<"as_expected">>, M) end, Mutants) of
        true -> <<"development-pass">>;
        false -> <<"development-fail">>
    end;
status(_, _, _, _, _) -> <<"development-fail">>.

assess(C, Scen, Verdicts, Negatives, NegativeScope) ->
    #{cases := Cases, sweeps := Sweeps, limit := Limit, fixture_counts := FixtureCounts, families := Declared} =
        fenrir_campaign:declared_scope(C),
    Fixed = [case_id(S) || S <- Scen, maps:get(family, S) =/= sqlite_kills],
    CasesDiff = exact(Cases, Fixed),
    SweepDiff = exact(Sweeps, lists:usort([maps:get(sweep, S, missing) || S <- Scen, maps:get(family, S) =:= sqlite_kills])),
    SweepScope = [{K, sweep_scope(K, Limit, [S || S <- Scen, maps:get(sweep, S, none) =:= K])} || K <- Sweeps],
    Histories = [list_to_binary(maps:get(history, S)) || S <- Scen, maps:is_key(history, S)],
    HistDiff = exact(Histories, [maps:get(<<"history">>, V, missing) || V <- Verdicts]),
    HistUnique = length(Histories) =:= length(lists:usort(Histories)),
    ByPath = maps:from_list([{maps:get(<<"history">>, V, missing), V} || V <- Verdicts]),
    Rows = [row(S, ByPath) || S <- Scen],
    Mutants = [mutant(M, [R || R <- Rows, maps:get(mutant, R) =:= M],
                       exact_ok(exact([K || K = {M0, _, _} <- Cases, M0 =:= M],
                                      [K || K = {M0, _, _} <- Fixed, M0 =:= M]))
                       andalso lists:all(fun(K) -> maps:get(<<"complete">>, K) end,
                           [S || {{M0, _, _, _}, S} <- SweepScope, M0 =:= M])) ||
               M <- maps:get(mutants, fenrir_campaign:scope_config(maps:get(mode, C)))],
    NegDiff = exact(maps:keys(NegativeScope), [maps:get(<<"history">>, V, missing) || V <- Negatives]),
    Neg = [negative(N, maps:get(maps:get(<<"history">>, N, missing), NegativeScope, missing)) || N <- Negatives],
    NegOk = exact_ok(NegDiff) andalso lists:all(fun(N) -> maps:get(<<"as_expected">>, N) end, Neg),
    ExpectedConfig = maps:merge(fenrir_campaign:scope_config(maps:get(mode, C)),
                                fenrir_campaign:fixture_paths(maps:get(root, C))),
    ConfigDiff = [{K, V, maps:get(K, C, missing)} || {K, V} <- maps:to_list(ExpectedConfig), maps:get(K, C, missing) =/= V],
    Families = maps:get(families, C, all),
    Only = maps:get(only, C, ""),
    Errors = [flag_json(R) || R <- Rows, maps:get(evidence_error, R)],
    FullFamilies = Families =:= all orelse
        (is_list(Families) andalso lists:sort(Families) =:= lists:sort([mutants | Declared])),
    Complete = FullFamilies andalso Only =:= "" andalso ConfigDiff =:= []
        andalso lists:all(fun({_, E, A}) -> E =:= A end, FixtureCounts)
        andalso exact_ok(CasesDiff) andalso exact_ok(SweepDiff)
        andalso lists:all(fun({_, S}) -> maps:get(<<"complete">>, S) end, SweepScope)
        andalso HistUnique andalso exact_ok(HistDiff) andalso NegOk andalso Errors =:= [],
    {#{<<"complete">> => Complete, <<"selected_families">> => print_term(Families),
       <<"crash_point_filter">> => list_to_binary(Only),
       <<"configuration_mismatches">> => [print_term(D) || D <- ConfigDiff],
       <<"fixture_counts">> => [#{<<"family">> => atom_to_binary(F), <<"expected">> => E, <<"actual">> => A} ||
                               {F, E, A} <- FixtureCounts],
       <<"static_cases">> => CasesDiff, <<"sqlite_sweep_ids">> => SweepDiff,
       <<"sqlite_sweeps">> => [S || {_, S} <- SweepScope],
       <<"history_verdicts">> => HistDiff, <<"unique_history_paths">> => HistUnique,
       <<"negative_controls">> => NegDiff, <<"negative_controls_as_expected">> => NegOk,
       <<"scenario_errors">> => Errors},
     Rows, Mutants, Neg}.

case_id(S) -> {maps:get(mutant, S), maps:get(family, S), maps:get(name, S)}.
print_term(T) -> iolist_to_binary(io_lib:format("~0P", [T, 14])).

exact(Expected, Actual) ->
    E = lists:sort(Expected), A = lists:sort(Actual),
    #{<<"expected">> => length(E), <<"actual">> => length(A),
      <<"missing">> => [print_term(K) || K <- E -- A], <<"unexpected">> => [print_term(K) || K <- A -- E]}.

exact_ok(#{<<"missing">> := [], <<"unexpected">> := []}) -> true;
exact_ok(_) -> false.

sweep_scope(K, Limit, Rs) ->
    Rows = lists:keysort(1, [{maps:get(probe_index, S, 0), maps:get(sweep_end, S, unverified), S} || S <- Rs]),
    Good = case lists:reverse(Rows) of
               [{N, completed, Last} | PriorRev] when N >= 2, N =< Limit ->
                   valid_probe(K, N, beyond, Last) andalso
                       [{I, E, valid_probe(K, I, fired, R)} || {I, E, R} <- lists:reverse(PriorRev)]
                       =:= [{I, continue, true} || I <- lists:seq(1, N - 1)];
               _ -> false
           end,
    #{<<"id">> => print_term(K), <<"limit">> => Limit, <<"complete">> => Good,
      <<"indices">> => [I || {I, _, _} <- Rows],
      <<"fired">> => [I || {I, _, S} <- Rows, maps:get(fired, S, false)],
      <<"end">> => case lists:reverse(Rows) of [] -> <<"missing">>; [{_, End, _} | _] -> atom_to_binary(End) end}.

valid_probe(K = {M, _, Op, _}, I, Probe, S) ->
    case_id(S) =:= {M, sqlite_kills, fenrir_campaign:sweep_name(K, I)} andalso
        maps:get(status, S, missing) =:= executed andalso
        maps:get(fired, S, false) =:= (Probe =:= fired) andalso
        maps:get(beyond_last_point, S, false) =:= (Probe =:= beyond) andalso
        case lists:keyfind(sqlite_probe, 1, maps:get(checks, S, [])) of
            {_, true, {Probe, Out, Died, SameNode, Exit, Disarm, Applied}} ->
                fenrir_campaign:sweep_result(Op, Out, {Died, SameNode}, Exit, Disarm, Applied) =:= Probe;
            _ -> false
        end.

row(S = #{status := executed, history := Path}, Verdicts) ->
    H = list_to_binary(Path),
    V = maps:get(H, Verdicts, #{<<"verdict">> => <<"missing">>}),
    Verdict = maps:get(<<"verdict">>, V, <<"missing">>),
    Errors = [history_evidence || not valid_history(S, V)] ++
             [recorder_gap || maps:get(gaps, S, missing) =/= []] ++
             [probe_unavailable || lists:member(false, [Ok || {probe_available, Ok, _} <- maps:get(checks, S, [])])] ++
             [fault_not_verified || not fenrir_campaign:fault_evidence(S) orelse lists:any(fun({N, Ok, _}) ->
                 not Ok andalso lists:member(N, [sqlite_probe, exception])
             end, maps:get(checks, S, []))],
    Reasons = [history || Verdict =:= <<"rejected">>] ++ [audit || not maps:get(audit_clean, S)]
              ++ [checks || not maps:get(checks_ok, S)],
    S#{verdict => Verdict, verdict_detail => V, flagged => Reasons ++ Errors =/= [],
       evidence_error => Errors =/= [], reasons => Errors ++ Reasons};
row(S, _) ->
    S#{verdict => <<"not run">>, flagged => true, evidence_error => true,
       reasons => [maps:get(status, S, missing_execution_status)]}.

valid_history(S, V) ->
    Events = maps:get(events, S, 0),
    Events > 0 andalso maps:get(<<"events">>, V, 0) =:= Events andalso
        maps:get(<<"scenario">>, V, missing) =:= list_to_binary(maps:get(name, S)) andalso
        maps:get(<<"expect">>, V, missing) =:= <<"none">> andalso
        case V of
            #{<<"verdict">> := <<"accepted">>, <<"model_steps">> := N} -> is_integer(N) andalso N > 0;
            #{<<"verdict">> := <<"rejected">>, <<"first_inadmissible">> := #{<<"index">> := I}} ->
                is_integer(I) andalso I >= 0 andalso I < Events;
            _ -> false
        end.

count(F, L) -> length([X || X <- L, F(X)]).

family(F, Rs) ->
    Base = #{<<"scenarios">> => length(Rs),
             <<"histories_accepted">> => count(fun(R) -> maps:get(verdict, R) =:= <<"accepted">> end, Rs),
             <<"histories_rejected">> => count(fun(R) -> maps:get(verdict, R) =:= <<"rejected">> end, Rs),
             <<"histories_indeterminate">> => count(fun(R) -> maps:get(verdict, R) =:= <<"indeterminate">> end, Rs),
             <<"audits_clean">> => count(fun(R) -> maps:get(audit_clean, R, false) end, Rs),
             <<"scenario_checks_ok">> => count(fun(R) -> maps:get(checks_ok, R, false) end, Rs),
             <<"crashes">> => lists:sum([maps:get(crashes, R, 0) || R <- Rs]),
             <<"requests">> => lists:sum([maps:get(requests, R, 0) || R <- Rs]),
             <<"history_events">> => lists:sum([maps:get(<<"events">>, maps:get(verdict_detail, R, #{}), 0) || R <- Rs]),
             <<"model_steps">> => lists:sum([maps:get(<<"model_steps">>, maps:get(verdict_detail, R, #{}), 0) || R <- Rs])},
    case F of
        sqlite_kills ->
            Base#{<<"kill_points_fired">> => count(fun(R) -> maps:get(fired, R, false) end, Rs),
                  <<"enumerations_ended_beyond_last_point">> => count(fun(R) -> maps:get(beyond_last_point, R, false) end, Rs)};
        _ -> Base
    end.

flag_json(R) ->
    #{<<"scenario">> => list_to_binary(maps:get(name, R)), <<"reasons">> => [atom_to_binary(X) || X <- maps:get(reasons, R)],
      <<"verdict">> => maps:get(verdict_detail, R, null),
      <<"execution_detail">> => print_term(maps:get(detail, R, none)),
      <<"audit">> => iolist_to_binary(io_lib:format("~0P", [{maps:get(audit_final, R, []), maps:get(audit_after_crashes, R, [])}, 14])),
      <<"failed_checks">> => [iolist_to_binary(io_lib:format("~0P", [{N, D}, 14])) || {N, false, D} <- maps:get(checks, R, [])]}.

%% A mutant is caught when at least one of its scenarios is flagged: a history the
%% model rejects, an audit violation of the SQLite file, or a failed scenario check.
mutant(M, Rs, Complete) ->
    Flagged = [R || R <- Rs, maps:get(flagged, R)],
    Errors = [R || R <- Rs, maps:get(evidence_error, R)],
    Catches = Flagged -- Errors,
    By = fun(Reason) -> [list_to_binary(maps:get(name, R)) || R <- Catches, lists:member(Reason, maps:get(reasons, R))] end,
    Expect = case M of equivalent_control -> not_flagged; sync_off -> not_detectable_here; _ -> caught end,
    Caught = Catches =/= [],
    Executed = length(Rs) - length(Errors),
    AsExpected = Complete andalso Executed > 0 andalso Errors =:= [] andalso Caught =:= (Expect =:= caught),
    #{<<"mutant">> => atom_to_binary(M), <<"expected">> => atom_to_binary(Expect),
      <<"result">> => case {M, Caught} of
                          _ when Executed =:= 0 -> <<"UNKNOWN: no valid executed scenarios">>;
                          _ when Errors =/= [] -> <<"UNKNOWN: scenario evidence errors">>;
                          _ when not Complete -> <<"UNKNOWN: incomplete mutant scope">>;
                          {sync_off, false} -> <<"NOT DETECTED BY THIS CAMPAIGN (kill -9 keeps the OS page cache; power loss is not simulated)">>;
                          {_, true} -> <<"caught">>;
                          {_, false} -> <<"not flagged">>
                      end,
      <<"as_expected">> => AsExpected, <<"scenarios">> => length(Rs), <<"flagged_scenarios">> => length(Flagged),
      <<"scope_complete">> => Complete,
      <<"executed_scenarios">> => Executed, <<"evidence_errors">> => [flag_json(R) || R <- Errors],
      <<"caught_by_history_checker">> => By(history), <<"caught_by_sqlite_audit">> => By(audit),
      <<"caught_by_scenario_checks">> => By(checks),
      <<"first_inadmissible">> => [#{<<"scenario">> => list_to_binary(maps:get(name, R)),
                                     <<"at">> => maps:get(<<"first_inadmissible">>, maps:get(verdict_detail, R), null)}
                                    || R <- lists:sublist([R || R <- Catches, lists:member(history, maps:get(reasons, R))], 3)]}.

%% Fixed fixture identities and oracle, independent of the paths/expectations echoed
%% by the checker. Include the positive and indeterminate controls in the same scope.
negative_scope(Root) ->
    A = <<"accepted">>, R = <<"rejected">>, I = <<"indeterminate">>,
    Specs = [{"acceptance-without-durable-commit", R, 2}, {"busy-but-applied", R, 1},
             {"concurrent-either-order", A, null}, {"cross-tenant-effect", R, 1},
             {"delivery-not-deduplicated", R, 3}, {"duplicated-mutation-on-retry", R, 2},
             {"duplicated-mutation-seen-in-store", R, 2}, {"full-cycle", A, null},
             {"impossible-first-submit", R, 0},
             {"indeterminate-committed-then-retry", A, null}, {"indeterminate-not-committed-then-retry", A, null},
             {"indeterminate-unresolved", A, null}, {"job-lost-after-acceptance", R, 3},
             {"job-lost-runner-drained", R, 3}, {"recorder-gap", I, 1}, {"repeated-concurrent-group", R, 0},
             {"response-after-crash", R, 2}, {"response-without-commit", R, 0},
             {"reused-key-accepted", R, 1}, {"submit-answered-refused", R, 0}],
    maps:from_list([begin
        Path = filename:join([Root, "tests", "host", "histories", Name ++ ".json"]),
        Scenario = list_to_binary(Name),
        {list_to_binary(Path), {Scenario, Expect, Index, fixture_events(Path, Scenario, Expect, Index)}}
    end || {Name, Expect, Index} <- Specs]).

fixture_events(Path, Scenario, Expect, Index) ->
    try
        {ok, B} = file:read_file(Path),
        #{<<"scenario">> := Scenario, <<"expect">> := Expect, <<"events">> := Es} = H = json:decode(B),
        Index = maps:get(<<"expect_index">>, H, null),
        length(Es)
    catch _:_ -> 0 end.

negative(N, missing) ->
    negative(N, {missing, null, null, 0});
negative(N, {Scenario, Expect, Index, Events}) ->
    Verdict = maps:get(<<"verdict">>, N, <<"missing">>),
    F = maps:get(<<"first_inadmissible">>, N, #{}),
    Got = maps:get(<<"index">>, F, null),
    #{<<"history">> => maps:get(<<"history">>, N, null), <<"expect">> => Expect, <<"verdict">> => Verdict,
      <<"expect_index">> => Index, <<"index">> => Got, <<"fixture_events">> => Events,
      <<"reason">> => maps:get(<<"reason">>, F, null),
      <<"as_expected">> => Verdict =:= Expect andalso Index =:= Got andalso Events > 0
          andalso maps:get(<<"events">>, N, 0) =:= Events
          andalso maps:get(<<"expect">>, N, missing) =:= Expect
          andalso maps:get(<<"scenario">>, N, missing) =:= Scenario}.

us_batches(R) -> lists:append([Us || {concurrent_batches_us, true, Us} <- maps:get(checks, R, [])]).

dist([]) -> #{<<"n">> => 0};
dist(L) ->
    N = length(L),
    P = fun(Q) -> lists:nth(max(1, min(N, round(Q * N))), L) end,
    #{<<"n">> => N, <<"min">> => hd(L), <<"median">> => P(0.5), <<"p90">> => P(0.9), <<"max">> => lists:last(L)}.

%% The 68 distinct (request, replies) runs of A2: how many the a2_runs family
%% reproduced exactly, and how many distinct (request, replies) the whole normal
%% campaign exercised.
a2_coverage(C, Normal) ->
    Canonical = fenrir_campaign:fixture_paths(maps:get(root, C)),
    {ok, B} = file:read_file(maps:get(a2_runs, Canonical)),
    Runs = maps:get(<<"runs">>, json:decode(B)),
    Key = fun([<<"submit">>, T, K, D], Rs) -> {{submit, T, K, D}, Rs};
             ([<<"complete">>, T, J, Ok], Rs) -> {{complete, T, J, Ok}, Rs} end,
    Want = lists:usort([Key(maps:get(<<"request">>, R), [iolist_to_binary(json:encode(X)) || X <- maps:get(<<"replies">>, R)]) || R <- Runs]),
    Seen = lists:usort(lists:append([maps:get(coverage, R, []) || R <- Normal])),
    A2 = [R || R <- Normal, maps:get(family, R) =:= a2_runs],
    #{<<"a2_runs">> => length(Runs),
      <<"a2_runs_reproduced_by_scenario">> => count(fun(R) -> not maps:get(flagged, R) end, A2),
      <<"a2_runs_seen_anywhere_in_campaign">> => length([W || W <- Want, lists:member(W, Seen)]),
      <<"distinct_request_replies_in_campaign">> => length(Seen)}.

identities(C, I) ->
    {ok, P} = fenrir_sqlite:open(filename:join(maps:get(out, C), "identity.db")),
    {rows, [[V]]} = fenrir_sqlite:exec(P, "SELECT sqlite_version()"),
    {rows, [[SrcId]]} = fenrir_sqlite:exec(P, "SELECT sqlite_source_id()"),
    fenrir_sqlite:close(P),
    Root = maps:get(root, C),
    Lock = case file:read_file(filename:join(Root, "flake.lock")) of
               {ok, L} -> maps:get(<<"rev">>, maps:get(<<"locked">>, maps:get(<<"nixpkgs">>, maps:get(<<"nodes">>, json:decode(L)))));
               _ -> null
           end,
    Sha = fun(F) -> {ok, B} = file:read_file(F), binary:encode_hex(crypto:hash(sha256, B), lowercase) end,
    ToolSource = maps:get(tool_source, C, unknown),
    {_, HostOS} = os:type(),
    #{<<"a3_tool_source">> => atom_to_binary(ToolSource),
      <<"host_os">> => atom_to_binary(HostOS),
      <<"host_arch">> => list_to_binary(string:trim(os:cmd("uname -m"))),
      <<"erts_target">> => list_to_binary(erlang:system_info(system_architecture)),
      <<"otp_release">> => list_to_binary(erlang:system_info(otp_release)),
      <<"erts">> => list_to_binary(erlang:system_info(version)),
      <<"erl">> => list_to_binary(maps:get(erl, C)),
      <<"sqlite_version">> => V, <<"sqlite_source_id">> => SrcId,
      <<"sqlite_port_program_sha256">> => Sha(maps:get(sqlite_port, C)),
      <<"sqlite_sweep_observer_sha256">> => Sha(filename:join([Root, "host", "service", "test", "sqlite-exit-observer.sh"])),
      <<"nixpkgs_rev">> => case ToolSource of nix_build -> Lock; _ -> null end,
      <<"solo5">> => maps:get(<<"solo5_identity">>, I),
      <<"tender">> => maps:get(<<"tender">>, I), <<"tender_sha256">> => maps:get(<<"tender_sha256">>, I),
      <<"guest_image_sha256">> => maps:get(<<"image_sha256">>, I), <<"batch_sha256">> => maps:get(<<"batch_sha256">>, I),
      <<"artifact_sha256">> => maps:get(<<"artifact_sha256">>, I), <<"protocol">> => maps:get(<<"protocol">>, I),
      <<"machine_profile">> => maps:get(<<"machine_profile">>, I), <<"image_entries">> => maps:get(<<"programs">>, I),
      <<"request_domain">> => maps:get(<<"domain">>, I),
      <<"shen">> => list_to_binary(os:getenv("FENRIR_SHEN_JIT", "unknown"))}.
