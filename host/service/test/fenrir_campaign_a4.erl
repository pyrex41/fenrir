%% A4 campaigns (host/service/CONTRACT.md section 7 maps each named assumption to the
%% scenarios here): the versioned upgrade of spec/service/UPGRADE.md on the real stack.
%% Each scenario runs on a fresh SQLite file and a fresh node, as in A3, and writes a
%% history of schema fenrir.service.history/2 (HISTORY_FORMAT.md section 4), checked
%% afterwards against the A4 model by harness/service-history.shen, with the SQLite file
%% audited after every crash and at the end.
%%
%% Families:
%%   upgrade_load      v1 traffic, begin, more v1 traffic, migrate, requests refused in
%%                     the window, cut-over, every pre-upgrade request retried, v2 traffic,
%%                     drain; an early cut-over is refused
%%   upgrade_crash     a crash (tender, store process, SQLite port program, node) at every
%%                     named point of the upgrade, incl. inside the install transaction and
%%                     between migrate and cut-over; then the upgrade is resumed
%%   upgrade_stale     a v1 run held before its commit across migrate (and cut-over) on a
%%                     worker the supervisor does not know: its commit is fenced by the store
%%   upgrade_cas       a v1 commit between the migration's snapshot and its install: the
%%                     install is told Changed, the program reads again and installs
%%   upgrade_manifest  begin-upgrade with images the host cannot discharge is refused
-module(fenrir_campaign_a4).
-export([families/2, mutant_suite/2, crash_matrix/0]).

-define(D, fenrir_drive).
-define(C, fenrir_campaign).

families(C, Want) ->
    Ctx = ctx(C, normal, 1),
    R = repeats(C),
    [lists:append([load(Ctx, C, I) || I <- lists:seq(1, R)]) || Want(upgrade_load)]
    ++ [lists:append([crash(Ctx, C, P, A, Ph, I) || {P, A, Ph} <- crash_matrix(), I <- lists:seq(1, R)]) || Want(upgrade_crash)]
    ++ [lists:append([stale(ctx(C, normal, 2), C, V, I) || V <- stale_variants(), I <- lists:seq(1, R)]) || Want(upgrade_stale)]
    ++ [lists:append([cas(ctx(C, normal, 1), C, I) || I <- lists:seq(1, R)]) || Want(upgrade_cas)]
    ++ [manifest(Ctx, C) || Want(upgrade_manifest)].

repeats(C) -> maps:get(a4_repeats, C, maps:get(repeats, C)).

ctx(C, Mutant, Workers) ->
    (?C:ctx(C, Mutant, Workers))#{schema => 2, v2_sha => maps:get(v2_sha, C)}.

v2(C) -> maps:get(v2_image, C).
mig(C) -> maps:get(migration_image, C).

check(N, B, D) -> ?C:check(N, B, D).

%% The scenarios a host mutant is run against (and the A4 equivalent control).
mutant_suite(M, C) ->
    Ctx = ctx(C, M, 1),
    [hd(load(Ctx, C, 1)), hd(stale(ctx(C, M, 2), C, delivery_across_cut_over, 1)),
     hd(stale(ctx(C, M, 2), C, submit_across_migrate, 1)), hd(cas(Ctx, C, 1)), hd(manifest(Ctx, C)),
     hd(crash(Ctx, C, between_migrate_and_cut_over, kill_node, migrate, 1)),
     hd(crash(Ctx, C, i5_before_commit, kill_node, migrate, 1))]
    ++ [hd(crash(Ctx, C, i7_between_transactions, kill_node, migrate, 1)) || M =:= migration_two_transactions].

%% ---------- shared steps ----------

state(S) ->
    case ?D:cmd(S, upgrade_state) of
        {#{upgrade := U}, S1} -> {U, S1};
        {_, S1} -> timer:sleep(20), state(S1)
    end.

begin_good(S, C) -> ?D:upgrade(S, begin_upgrade, [v2(C), mig(C), good]).

%% Resume an interrupted upgrade until the state is v2 (at most N steps).
resume(S, _C, 0) -> {gave_up, S};
resume(S, C, N) ->
    {U, S1} = state(S),
    case U of
        v2 -> {v2, S1};
        v1 -> {_, S2} = begin_good(S1, C), ?D:backoff(N), resume(S2, C, N - 1);
        prepared -> {_, S2} = ?D:upgrade(S1, migrate, []), ?D:backoff(N), resume(S2, C, N - 1);
        migrated -> {_, S2} = ?D:upgrade(S1, cut_over, []), ?D:backoff(N), resume(S2, C, N - 1)
    end.

%% Seeded v1 or v2 traffic: submits on tenants 0..2, keys 0..1, digests 0..1, told when
%% answered; deliveries of jobs in use.
traffic(S, 0) -> S;
traffic(S, N) ->
    Next = case ?C:snapshot_of(S) of St when is_list(St) -> [X || [_, _, _, X] <- St]; _ -> [0, 0, 0] end,
    S1 = case rand:uniform(10) of
             X when X =< 7 -> element(2, ?D:submit_told(S, rand:uniform(3) - 1, rand:uniform(2) - 1, rand:uniform(2) - 1));
             _ ->
                 T = rand:uniform(3) - 1,
                 case lists:nth(T + 1, Next) of
                     0 -> S;
                     M -> element(2, ?D:complete(S, T, rand:uniform(M) - 1, rand:uniform(2) =:= 1))
                 end
         end,
    traffic(S1, N - 1).

%% Every key entry recorded under v1 (from a store snapshot): [{T, K, D, Receipt}].
recorded(Snap) when is_list(Snap) ->
    [{T, K, D, Rc} || {T, [_, _, Keys, _]} <- lists:zip(lists:seq(0, length(Snap) - 1), Snap), [K, D, Rc] <- Keys];
recorded(_) -> [].

%% Retry every recorded request with its digest (must answer its receipt, unchanged) and
%% with the other digest (must answer conflict).
retries(S, Recorded) ->
    lists:foldl(fun({T, K, D, Rc}, {SA, CA}) ->
                        {O1, S1} = ?D:retry_submit(SA, T, K, D, 5),
                        {O2, S2} = ?D:retry_submit(S1, T, K, 1 - D, 5),
                        {S2, [check({retry_returns_recorded_receipt, T, K}, O1 =:= {accepted, Rc}, {O1, Rc}),
                              check({retry_other_digest_conflict, T, K}, O2 =:= {conflict, T, K}, O2) | CA]}
                end, {S, []}, Recorded).

pending_ids(Snap) when is_list(Snap) ->
    [{T, J} || {T, [_, Jobs, _, _]} <- lists:zip(lists:seq(0, length(Snap) - 1), Snap), [J, _, <<"pending">> | _] <- Jobs];
pending_ids(_) -> unavailable.

job_ids(Snap) when is_list(Snap) ->
    [{T, J} || {T, [_, Jobs, _, _]} <- lists:zip(lists:seq(0, length(Snap) - 1), Snap), [J | _] <- Jobs];
job_ids(_) -> [].

%% ---------- upgrade under load ----------

load(Ctx, C, R) ->
    [?C:scenario(Ctx, upgrade_load, "repeat-" ++ integer_to_list(R), #{tenants => 3},
      fun(S0) ->
              rand:seed(exsss, {R, 4711, 13}),
              S1 = traffic(S0, 8),
              {B, S2} = begin_good(S1, C),
              %% an operator cutting over before migrating: refused in prepared
              {Early, S3} = ?D:upgrade(S2, cut_over, []),
              S4 = traffic(S3, 4),
              Before = ?C:snapshot_of(S4),
              {M, S5} = ?D:upgrade(S4, migrate, []),
              S6 = ?D:observe(S5),
              After = ?C:snapshot_of(S6),
              {W, S7} = ?D:submit(S6, 0, 2, 0),
              {Wd, S8} = ?D:complete(S7, 0, 0, true),
              {Cut, S9} = ?D:upgrade(S8, cut_over, []),
              S10 = ?D:observe(S9),
              {S11, RetryChecks} = retries(S10, recorded(Before)),
              S12 = traffic(S11, 4),
              S13 = ?D:drain(S12, #{}),
              Final = ?C:snapshot_of(S13),
              {S13, [check(early_cut_over_refused, element(1, Early) =:= refused, Early),
                     check(begin_ok, B =:= ok, B), check(migrate_ok, M =:= ok, M), check(cut_over_ok, Cut =:= ok, Cut),
                     %% nothing applied: unavailable, or aborted when the worker was being replaced
                     check(window_refuses_requests, lists:member(W, [unavailable, aborted]) andalso lists:member(Wd, [unavailable, aborted]), {W, Wd}),
                     check(pending_jobs_preserved_by_migrate, pending_ids(Before) =:= pending_ids(After), {Before, After}),
                     check(jobs_preserved, job_ids(Before) -- job_ids(Final) =:= [], {Before, Final}),
                     check(no_pending_job_after_drain, ?C:no_pending(Final), Final) | RetryChecks]}
      end)].

%% ---------- crashes at every named point of the upgrade ----------

%% {Point, Action, Phase}: Phase is the upgrade step the point is reached in.
crash_matrix() ->
    [{P, A, 'begin'} || P <- [begin_upgrade_before_commit, begin_upgrade_after_commit], A <- [kill_port, kill_store, kill_node]]
    ++ [{P, A, migrate} || P <- [i1_after_begin, i2_after_compare, i3_after_ddl, i4_mid_rows, i5_before_commit, i6_after_commit],
                           A <- [kill_port, kill_store, kill_node]]
    ++ [{m1_before_request, A, migrate} || A <- [kill_tender, kill_node]]
    ++ [{m2_before_install, A, migrate} || A <- [kill_tender, kill_node, halt_node]]
    ++ [{u_after_migrate, A, migrate} || A <- [kill_node, halt_node]]
    ++ [{between_migrate_and_cut_over, kill_node, migrate}]
    ++ [{P, A, cut_over} || P <- [cut_over_before_commit, cut_over_after_commit], A <- [kill_port, kill_store, kill_node]]
    ++ [{u_after_cut_over_meta, A, cut_over} || A <- [kill_node, halt_node]].

crash(Ctx, C, Point, Action, Phase, R) ->
    Name = lists:flatten(io_lib:format("~s-~s-~B", [Point, Action, R])),
    [?C:scenario(Ctx, upgrade_crash, Name, #{tenants => 3},
      fun(S0) ->
              rand:seed(exsss, {R, 99, erlang:phash2(Point)}),
              S1 = traffic(S0, 6),
              {_, S2} = case Phase of 'begin' -> {skip, S1}; _ -> begin_good(S1, C) end,
              Before = ?C:snapshot_of(S2),
              {_, S3} = case Phase of cut_over -> ?D:upgrade(S2, migrate, []); _ -> {skip, S2} end,
              {Fired, S4} = fault_step(S3, C, Point, Action, Phase),
              S5 = ?D:observe(S4),
              {Resumed, S6} = resume(S5, C, 6),
              S7 = ?D:observe(S6),
              {S8, RetryChecks} = retries(S7, recorded(Before)),
              {_, S9} = ?D:submit_told(S8, 2, 1, 1),
              S10 = ?D:drain(S9, #{}),
              After = ?C:snapshot_of(S10),
              {S10, [check(fault_fired, Fired, Point),
                     check(upgrade_resumed_to_v2, Resumed =:= v2, Resumed),
                     check(jobs_preserved, job_ids(Before) -- job_ids(After) =:= [], {Before, After}),
                     check(no_pending_job_after_drain, ?C:no_pending(After), After) | RetryChecks]}
      end)].

%% Arm the point and run the step that reaches it; true when the fault fired.
fault_step(S, _C, between_migrate_and_cut_over, kill_node, migrate) ->
    {M, S1} = ?D:upgrade(S, migrate, []),
    {M =:= ok, ?D:crash(S1, kill)};
fault_step(S, C, Point, Action, Phase) ->
    Count = case Point of m1_before_request -> 3; _ -> 1 end,
    {ok, S1} = ?D:cmd(S, {arm, Point, Action, Count}),
    Crashes = maps:get(crashes, S1),
    {_, S2} = case Phase of
                  'begin' -> begin_good(S1, C);
                  migrate -> ?D:upgrade(S1, migrate, []);
                  cut_over -> ?D:upgrade(S1, cut_over, [])
              end,
    {FiredList, S3} = ?D:cmd(S2, fired),
    NodeDied = maps:get(crashes, S3) > Crashes,
    {_, S4} = ?D:cmd(S3, disarm),
    Fired = NodeDied orelse (is_list(FiredList) andalso FiredList =/= []),
    S5 = case Fired andalso not NodeDied of
             true -> ?D:fault(S4, atom_to_binary(Action), atom_to_binary(Point));
             false -> S4
         end,
    {Fired, S5}.

%% ---------- stale runs: fencing by the store ----------

stale_variants() ->
    [submit_across_migrate, submit_across_cut_over, delivery_across_cut_over, submit_while_prepared,
     supervised_submit_across_migrate].

stale(Ctx, C, Variant, R) ->
    [?C:scenario(Ctx, upgrade_stale, lists:flatten(io_lib:format("~s-~B", [Variant, R])), #{tenants => 3},
      fun(S0) ->
              {_, S1} = ?D:submit_told(S0, 0, 0, 0),
              {ok, S2} = ?D:cmd(S1, {arm, w2_request_before_commit, pause, 1}),
              Req = case Variant of
                        delivery_across_cut_over -> {detached, {complete, 0, 0, true}};
                        supervised_submit_across_migrate -> {submit, 1, 1, 1, <<1>>};
                        _ -> {detached, {submit, 1, 0, 0, <<0>>}}
                    end,
              {Ticket, S3} = ?D:async(S2, Req),
              {Held, S4} = ?D:cmd(S3, {paused, w2_request_before_commit}),
              {_, S5} = begin_good(S4, C),
              {_, S6} = case Variant of submit_while_prepared -> {skip, S5}; _ -> ?D:upgrade(S5, migrate, []) end,
              {_, S7} = case Variant of
                            submit_across_cut_over -> ?D:upgrade(S6, cut_over, []);
                            delivery_across_cut_over -> ?D:upgrade(S6, cut_over, []);
                            _ -> {skip, S6}
                        end,
              {_, S8} = ?D:cmd(S7, {release, w2_request_before_commit}),
              {Out, S9} = ?D:await(S8, Ticket),
              {_, S9a} = ?D:cmd(S9, disarm),
              S10 = ?D:observe(S9a),
              {Resumed, S11} = resume(S10, C, 4),
              {Again, S12} = case Req of
                                 {detached, {complete, T, J, Ok}} -> ?C:retry_complete(S11, T, J, Ok, 5);
                                 {detached, {submit, T, K, D, _}} -> ?D:retry_submit(S11, T, K, D, 5);
                                 {submit, T, K, D, _} -> ?D:retry_submit(S11, T, K, D, 5)
                             end,
              S13 = ?D:drain(S12, #{}),
              Final = ?C:snapshot_of(S13),
              Want = case Variant of submit_while_prepared -> accepted; _ -> unavailable end,
              {S13, [check(run_held_before_commit, Held =:= true, Held),
                     check(stale_run_outcome, element(1, as_tuple(Out)) =:= Want, {Out, Want}),
                     check(upgrade_resumed_to_v2, Resumed =:= v2, Resumed),
                     check(request_succeeds_after_upgrade, Again =/= gave_up, Again),
                     check(no_pending_job_after_drain, ?C:no_pending(Final), Final)]}
      end)].

as_tuple(T) when is_tuple(T) -> T;
as_tuple(A) -> {A}.

%% ---------- a v1 commit between the migration's snapshot and its install ----------

cas(Ctx, C, R) ->
    [?C:scenario(Ctx, upgrade_cas, "repeat-" ++ integer_to_list(R), #{tenants => 3},
      fun(S0) ->
              {_, S1} = ?D:submit_told(S0, 0, 0, R rem 2),
              {_, S2} = begin_good(S1, C),
              {ok, S3} = ?D:cmd(S2, {arm, m2_before_install, pause, 1}),
              {Ticket, S4} = ?D:async(S3, migrate),
              {Held, S5} = ?D:cmd(S4, {paused, m2_before_install}),
              {Mid, S6} = ?D:submit_told(S5, 1, 1, 1),
              {_, S7} = ?D:cmd(S6, {release, m2_before_install}),
              {M, S8} = ?D:await(S7, Ticket),
              {_, S8a} = ?D:cmd(S8, disarm),
              S9 = ?D:observe(S8a),
              Snap = ?C:snapshot_of(S9),
              {Cut, S10} = ?D:upgrade(S9, cut_over, []),
              {Again, S11} = ?D:retry_submit(S10, 1, 1, 1, 5),
              S12 = ?D:drain(S11, #{}),
              {S12, [check(migration_held_before_install, Held =:= true, Held),
                     check(v1_commit_in_between_accepted, element(1, as_tuple(Mid)) =:= accepted, Mid),
                     check(migrate_ok_after_retry, M =:= ok, M),
                     check(in_between_job_migrated, lists:member({1, 0}, pending_ids(Snap)), Snap),
                     check(cut_over_ok, Cut =:= ok, Cut),
                     check(retry_returns_v1_receipt, Again =:= Mid, {Again, Mid})]}
      end)].

%% ---------- the capability manifest at begin-upgrade ----------

manifest(Ctx, C) ->
    [?C:scenario(Ctx, upgrade_manifest, "images", #{tenants => 3},
      fun(S0) ->
              Dir = maps:get(dir, S0),
              Bad = [{v1_image_as_v2, maps:get(image, C), mig(C)},
                     {v2_image_as_migration, v2(C), v2(C)},
                     {migration_image_as_v2, mig(C), mig(C)},
                     {v2_with_undischarged_effect, doctored(Dir, v2(C), mail), mig(C)},
                     {v2_with_store_contract_3, doctored(Dir, v2(C), reply_busy), mig(C)}],
              {S1, Checks} = lists:foldl(
                  fun({N, V2, Mig}, {SA, CA}) ->
                          {O, SB} = ?D:upgrade(SA, begin_upgrade, [V2, Mig, bad]),
                          {SB, [check({refused, N}, element(1, as_tuple(O)) =:= refused, O) | CA]}
                  end, {S0, []}, Bad),
              {U, S2} = state(S1),
              {B, S3} = begin_good(S2, C),
              S4 = ?D:observe(S3),
              {A, S5} = ?D:upgrade(S4, abort, []),
              S6 = ?D:observe(S5),
              {_, S7} = ?D:submit_told(S6, 0, 0, 0),
              {S7, [check(still_v1_after_refusals, U =:= v1, U), check(good_image_admitted, B =:= ok, B),
                    check(abort_ok, A =:= ok, A) | Checks]}
      end)].

%% A copy of an image descriptor whose artifact declares what no contract of the host
%% discharges (identity-consistent: the artifact hash is recomputed, as in the A3 unit
%% test supervisor_refuses_worker_on_manifest).
doctored(Dir, Image, What) ->
    {ok, IB} = file:read_file(Image),
    I = json:decode(IB),
    {ok, AB} = file:read_file(filename:join(maps:get(<<"batch_dir">>, I), "artifacts/0.json")),
    A = json:decode(AB),
    A2 = case What of
             mail ->
                 Mail = #{<<"name">> => <<"Mail">>, <<"class">> => <<"durable">>,
                          <<"operations">> => [#{<<"name">> => <<"send">>, <<"argument_type">> => <<"Bytes">>, <<"result_type">> => <<"Unit">>}]},
                 A#{<<"effects">> := maps:get(<<"effects">>, A) ++ [Mail],
                    <<"functions">> := [case maps:get(<<"name">>, F) of
                                            <<"main">> -> F#{<<"effects">> := maps:get(<<"effects">>, F) ++ [<<"Mail">>]};
                                            _ -> F
                                        end || F <- maps:get(<<"functions">>, A)]};
             reply_busy ->
                 A#{<<"datatypes">> := [case maps:get(<<"name">>, D) of
                                            <<"Reply">> -> D#{<<"constructors">> := maps:get(<<"constructors">>, D) ++
                                                                  [#{<<"name">> => <<"Busy">>, <<"fields">> => []}]};
                                            _ -> D
                                        end || D <- maps:get(<<"datatypes">>, A)]}
         end,
    Sub = filename:join(Dir, "doctored-" ++ atom_to_list(What)),
    ok = filelib:ensure_dir(filename:join(Sub, "artifacts/x")),
    Bytes = json:encode(A2),
    ok = file:write_file(filename:join(Sub, "artifacts/0.json"), Bytes),
    I2 = I#{<<"batch_dir">> := list_to_binary(Sub), <<"artifact_sha256">> := binary:encode_hex(crypto:hash(sha256, Bytes), lowercase),
            <<"residual_effects">> := fenrir_manifest:residual(A2)},
    Desc = filename:join(Sub, "image.json"),
    ok = file:write_file(Desc, json:encode(I2)),
    Desc.
