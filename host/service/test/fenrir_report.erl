%% A3: the check's JSON report (house style: status development-pass / development-fail,
%% evidence, qualification UNKNOWN, counts, tool identities).
%%
%%   erl -noshell -pa EBIN -run fenrir_report main CONFIG HISTORY_EXIT
-module(fenrir_report).
-export([main/1]).

main([ConfigFile, HistExit]) ->
    {ok, [C]} = file:consult(ConfigFile),
    Out = maps:get(out, C),
    {ok, SB} = file:read_file(filename:join(Out, "scenarios.bin")),
    Scen = binary_to_term(SB),
    Verdicts = maps:from_list([{maps:get(<<"history">>, V), V} || V <- jsonl(filename:join(Out, "verdicts/verdicts.jsonl"))]),
    Negatives = jsonl(filename:join(Out, "negative/verdicts.jsonl")),
    Unit = case file:read_file(filename:join(Out, "unit.json")) of {ok, U} -> json:decode(U); _ -> #{<<"passed">> => 0, <<"failed">> => 1, <<"tests">> => []} end,
    Rows = [row(S, Verdicts) || S <- Scen],
    Normal = [R || R <- Rows, maps:get(mutant, R) =:= normal],
    Families = lists:usort([maps:get(family, R) || R <- Normal]),
    FamilyJson = maps:from_list([{atom_to_binary(F), family(F, [R || R <- Normal, maps:get(family, R) =:= F])} || F <- Families]),
    NormalOk = Normal =/= [] andalso lists:all(fun(R) -> not maps:get(flagged, R) end, Normal),
    Mutants = [mutant(M, [R || R <- Rows, maps:get(mutant, R) =:= M]) || M <- maps:get(mutants, C)],
    MutantsOk = lists:all(fun(M) -> maps:get(<<"as_expected">>, M) end, Mutants),
    Neg = [negative(N) || N <- Negatives],
    NegOk = Neg =/= [] andalso lists:all(fun(N) -> maps:get(<<"as_expected">>, N) end, Neg),
    UnitOk = maps:get(<<"failed">>, Unit) =:= 0 andalso maps:get(<<"passed">>, Unit) > 0,
    Pass = NormalOk andalso MutantsOk andalso NegOk andalso UnitOk andalso HistExit =:= "0",
    Lat = lists:sort(lists:append([maps:get(latencies_us, R, []) || R <- Normal, maps:get(family, R) =/= two_workers])),
    Boots = lists:sort([maps:get(node_start_us, R, 0) || R <- Normal, maps:get(node_start_us, R, 0) > 0]),
    TwoW = lists:append([us_batches(R) || R <- Normal, maps:get(family, R) =:= two_workers]),
    {ok, IB} = file:read_file(maps:get(image, C)),
    I = json:decode(IB),
    Report =
        #{<<"schema">> => <<"fenrir.host.service-check/1">>,
          <<"status">> => case Pass of true -> <<"development-pass">>; false -> <<"development-fail">> end,
          <<"evidence">> => <<"observed history accepted; bounded crash campaign">>,
          <<"qualification">> => <<"UNKNOWN">>,
          <<"stage">> => <<"A3 (04_DIRECTION_AMENDMENT.md section 8)">>,
          <<"contract">> => [<<"spec/service/ACCEPTED_JOB.md">>, <<"spec/service/HANDLER.md">>, <<"host/service/CONTRACT.md">>],
          <<"mode">> => atom_to_binary(maps:get(mode, C)),
          <<"artifact_source">> => list_to_binary(maps:get(artifact_source, C)),
          <<"identities">> => identities(C, I),
          <<"unit_tests">> => #{<<"passed">> => maps:get(<<"passed">>, Unit), <<"failed">> => maps:get(<<"failed">>, Unit),
                                <<"failures">> => [T || T <- maps:get(<<"tests">>, Unit), maps:get(<<"pass">>, T) =:= false]},
          <<"campaigns">> => FamilyJson,
          <<"normal_stack">> => #{<<"scenarios">> => length(Normal),
                                  <<"histories_accepted">> => count(fun(R) -> maps:get(verdict, R) =:= <<"accepted">> end, Normal),
                                  <<"flagged">> => [flag_json(R) || R <- Normal, maps:get(flagged, R)],
                                  <<"crashes_injected">> => lists:sum([maps:get(crashes, R, 0) || R <- Normal]),
                                  <<"requests">> => lists:sum([maps:get(requests, R, 0) || R <- Normal]),
                                  <<"a2_run_coverage">> => a2_coverage(C, Normal)},
          <<"host_mutants">> => Mutants,
          <<"history_checker_negative_tests">> => Neg,
          <<"latency">> => #{<<"request_boot_plus_run_us">> => dist(Lat),
                             <<"node_start_us">> => dist(Boots),
                             <<"two_worker_batch_of_2_us">> => dist(lists:sort(TwoW)),
                             <<"note">> => <<"one request per tender boot (protocol v2 runs one program per boot); request_boot_plus_run_us is the worker's wall time from spawning solo5-spt to Bye and exit, including the SQLite commit; development container, no KVM, not a performance claim">>},
          <<"not_covered">> => [<<"power loss and fsync honesty: kill -9 of a process cannot drop the OS page cache, so synchronous=OFF is NOT DETECTED by this campaign">>,
                                <<"disk corruption, torn sectors, a lying disk">>, <<"SQLite itself">>, <<"OTP itself">>,
                                <<"isolation between several workers on one store beyond the observed serialized runs (one adapter process serializes commits)">>,
                                <<"performance">>, <<"requests outside the image's request domain (protocol v2 lowers entry inputs into the image)">>]},
    ok = file:write_file(filename:join(Out, "report.json"), json:encode(Report)),
    halt(0).

jsonl(File) ->
    case file:read_file(File) of
        {ok, B} -> [json:decode(L) || L <- binary:split(B, <<"\n">>, [global, trim_all])];
        _ -> []
    end.

row(S = #{status := start_failed}, _) ->
    S#{verdict => <<"not run">>, flagged => true, reasons => [start_failed]};
row(S, Verdicts) ->
    H = list_to_binary(maps:get(history, S)),
    V = maps:get(H, Verdicts, #{<<"verdict">> => <<"missing">>}),
    Verdict = maps:get(<<"verdict">>, V),
    Reasons = [history || Verdict =/= <<"accepted">>] ++ [audit || not maps:get(audit_clean, S)]
              ++ [checks || not maps:get(checks_ok, S)],
    S#{verdict => Verdict, verdict_detail => V, flagged => Reasons =/= [], reasons => Reasons}.

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
      <<"audit">> => iolist_to_binary(io_lib:format("~0P", [{maps:get(audit_final, R, []), maps:get(audit_after_crashes, R, [])}, 14])),
      <<"failed_checks">> => [iolist_to_binary(io_lib:format("~0P", [{N, D}, 14])) || {N, false, D} <- maps:get(checks, R, [])]}.

%% A mutant is caught when at least one of its scenarios is flagged: a history the
%% model rejects, an audit violation of the SQLite file, or a failed scenario check.
mutant(M, Rs) ->
    Flagged = [R || R <- Rs, maps:get(flagged, R)],
    By = fun(Reason) -> [list_to_binary(maps:get(name, R)) || R <- Flagged, lists:member(Reason, maps:get(reasons, R))] end,
    Expect = case M of equivalent_control -> not_flagged; sync_off -> not_detectable_here; _ -> caught end,
    Caught = Flagged =/= [],
    AsExpected = case Expect of caught -> Caught; not_flagged -> not Caught; not_detectable_here -> true end,
    #{<<"mutant">> => atom_to_binary(M), <<"expected">> => atom_to_binary(Expect),
      <<"result">> => case {M, Caught} of
                          {sync_off, false} -> <<"NOT DETECTED BY THIS CAMPAIGN (kill -9 keeps the OS page cache; power loss is not simulated)">>;
                          {_, true} -> <<"caught">>;
                          {_, false} -> <<"not flagged">>
                      end,
      <<"as_expected">> => AsExpected, <<"scenarios">> => length(Rs), <<"flagged_scenarios">> => length(Flagged),
      <<"caught_by_history_checker">> => By(history), <<"caught_by_sqlite_audit">> => By(audit),
      <<"caught_by_scenario_checks">> => By(checks),
      <<"first_inadmissible">> => [#{<<"scenario">> => list_to_binary(maps:get(name, R)),
                                     <<"at">> => maps:get(<<"first_inadmissible">>, maps:get(verdict_detail, R), null)}
                                   || R <- lists:sublist([R || R <- Flagged, lists:member(history, maps:get(reasons, R))], 3)]}.

negative(N) ->
    Expect = maps:get(<<"expect">>, N),
    Verdict = maps:get(<<"verdict">>, N),
    {ok, H} = file:read_file(maps:get(<<"history">>, N)),
    Index = maps:get(<<"expect_index">>, json:decode(H), null),
    Got = case maps:get(<<"first_inadmissible">>, N, null) of null -> null; F -> maps:get(<<"index">>, F) end,
    #{<<"history">> => filename:basename(maps:get(<<"history">>, N)), <<"expect">> => Expect, <<"verdict">> => Verdict,
      <<"expect_index">> => Index, <<"index">> => Got,
      <<"reason">> => case maps:get(<<"first_inadmissible">>, N, null) of null -> null; F2 -> maps:get(<<"reason">>, F2) end,
      <<"as_expected">> => Verdict =:= Expect andalso (Index =:= null orelse Index =:= Got)}.

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
    {ok, B} = file:read_file(maps:get(a2_runs, C)),
    Runs = maps:get(<<"runs">>, json:decode(B)),
    Key = fun([<<"submit">>, T, K, D], Rs) -> {{submit, T, K, D}, Rs};
             ([<<"complete">>, T, J, Ok], Rs) -> {{complete, T, J, Ok}, Rs} end,
    Want = lists:usort([Key(maps:get(<<"request">>, R), [iolist_to_binary(json:encode(X)) || X <- maps:get(<<"replies">>, R)]) || R <- Runs]),
    Seen = lists:usort(lists:append([maps:get(coverage, R, []) || R <- Normal])),
    A2 = [R || R <- Normal, maps:get(family, R) =:= a2_runs],
    #{<<"a2_runs">> => length(Runs),
      <<"a2_runs_reproduced_by_scenario">> => count(fun(R) -> maps:get(checks_ok, R) end, A2),
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
    #{<<"otp_release">> => list_to_binary(erlang:system_info(otp_release)),
      <<"erts">> => list_to_binary(erlang:system_info(version)),
      <<"erl">> => list_to_binary(maps:get(erl, C)),
      <<"sqlite_version">> => V, <<"sqlite_source_id">> => SrcId,
      <<"sqlite_port_program_sha256">> => Sha(maps:get(sqlite_port, C)),
      <<"nixpkgs_rev">> => Lock,
      <<"solo5">> => maps:get(<<"solo5_identity">>, I),
      <<"tender">> => maps:get(<<"tender">>, I), <<"tender_sha256">> => maps:get(<<"tender_sha256">>, I),
      <<"guest_image_sha256">> => maps:get(<<"image_sha256">>, I), <<"batch_sha256">> => maps:get(<<"batch_sha256">>, I),
      <<"artifact_sha256">> => maps:get(<<"artifact_sha256">>, I), <<"protocol">> => maps:get(<<"protocol">>, I),
      <<"machine_profile">> => maps:get(<<"machine_profile">>, I), <<"image_entries">> => maps:get(<<"programs">>, I),
      <<"request_domain">> => maps:get(<<"domain">>, I),
      <<"shen">> => list_to_binary(os:getenv("FENRIR_SHEN_JIT", "unknown"))}.
