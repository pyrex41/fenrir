%% Real stock Solo5 worker fixtures. These are not /2 campaign histories.
-module(fenrir_a4_workers).
-export([main/1]).

main([Out, Launcher, V1Path, V2Path, Migration]) ->
    try run(Out, Launcher, V1Path, V2Path, Migration) of
        ok -> halt(0)
    catch C:E:Trace ->
        io:format(standard_error, "A4 worker check failed: ~p:~p~n~p~n", [C, E, Trace]),
        halt(1)
    end.

run(Out, Launcher, V1Path, V2Path, Migration) ->
    fenrir_faults:init(),
    Opts = #{launcher => Launcher, console_dir => Out, a4_launch_dir => filename:join(Out, "launch")},
    Db = filename:join(Out, "service.db"),
    {Creds, Bindings} = fenrir_authority:campaign_credentials(2),
    C0 = maps:get(0, Creds),
    C1 = maps:get(1, Creds),
    Config = #{db => Db, tenants => 2, image => V1Path, workers => 2,
               launcher => Launcher, console_dir => Out, submit_credentials => Bindings,
               a4 => #{operator => self(), handler => V2Path, launch_dir => maps:get(a4_launch_dir, Opts)}},
    {error, upgrade_request_domain_mismatch} = fenrir_service_sup:start_link(Config#{tenants := 3}),
    {ok, Sup} = fenrir_service_sup:start_link(Config),
    Front = whereis(fenrir_front),
    V1 = whereis(w1),
    true = is_pid(Front) andalso is_pid(V1),
    {{accepted, Old=[0,0,1,0,0]}, _} = fenrir_front:submit(C0, 0, 1, <<1>>),
    {{accepted, [1,0,1,0,0]}, _} = fenrir_front:submit(C1, 0, 1, <<1>>),
    {delivered, _} = fenrir_front:deliver(1, 0, false),
    {refused, _} = fenrir_service_sup:prepare(Migration, V2Path),
    {ok, Descr} = file:read_file(V2Path),
    ok = file:write_file(V2Path, <<Descr/binary, "\n">>),
    {refused, v2_bank_not_ready} = fenrir_service_sup:prepare(V2Path, Migration),
    {ok, v1} = fenrir_store:maintenance(state),
    ok = file:write_file(V2Path, Descr),
    {ok, Prep = {prepared, Id, Pin, MP}} = fenrir_service_sup:prepare(V2Path, Migration),
    Prepared = observed(Db, Prep),
    %% A copied descriptor with a changed request table must not be admitted.
    Descriptor = json:decode(Descr),
    [First | Rest] = maps:get(<<"entries">>, Descriptor),
    BadPath = filename:join(Out, "bad-entry.json"),
    ok = file:write_file(BadPath, json:encode(Descriptor#{<<"entries">> := [First#{<<"program">> := 1} | Rest]})),
    {error, _} = fenrir_a4_image:admit(BadPath, handler_v2),
    {refused, unauthorized_maintenance} = foreign(fun() -> fenrir_a4_upgrade:migrate(Id, Migration, Opts) end),
    {refused, version_not_in_force} = fenrir_worker:run(a4w1, {tenant, 0}, {submit, 0, 1, <<1>>}),
    {refused, wrong_preparation} = fenrir_service_sup:cut_over(Id, V2Path),
    {ok, {data, <<"Migrated">>, <<"Installed">>, []}, #{requests := MigrationRequests, commit := committed}} =
        fenrir_a4_upgrade:migrate(Id, Migration, Opts),
    true = MigrationRequests =:= 10,
    {ok, {migrated, Id, Pin, MP}} = fenrir_store:maintenance(state),
    Migrated = observed(Db, {migrated, Id, Pin, MP}),
    {unavailable, _} = fenrir_front:submit(C0, 0, 1, <<1>>),
    {unavailable, _} = fenrir_front:deliver(0, 0, true),
    {{refused, unauthorized}, _} = fenrir_front:submit(<<0:256>>, 0, 1, <<1>>),
    {refused, unauthorized_maintenance} = foreign(fun() -> fenrir_service_sup:cut_over(Id, V2Path) end),
    {refused, version_not_in_force} = fenrir_worker:run(a4w1, {tenant, 0}, {submit, 0, 1, <<1>>}),
    ok = file:write_file(V2Path, <<Descr/binary, "\n">>),
    {refused, durable_image_pin_mismatch} = fenrir_service_sup:cut_over(Id, V2Path),
    {ok, {migrated, Id, Pin, MP}} = fenrir_store:maintenance(state),
    ok = file:write_file(V2Path, Descr),
    Mon = monitor(process, V1),
    ok = fenrir_service_sup:cut_over(Id, V2Path),
    ok = fenrir_service_sup:cut_over(Id, V2Path),
    receive {'DOWN', Mon, process, V1, shutdown} -> ok after 5000 -> error(v1_not_retired) end,
    undefined = whereis(w1),
    undefined = whereis(w2),
    CutOver = observed(Db, {v2, Id, Pin, MP}),
    Front = whereis(fenrir_front),
    ok = fenrir_front:respond({accepted, Old}),
    {{refused, unauthorized}, _} = fenrir_front:submit(<<0:256>>, 1, 0, <<0>>),
    {{accepted, Old}, #{contract_version := 2}} = fenrir_front:submit(C0, 0, 1, <<1>>),
    {{accepted, New=[0,1,0,1,1,2]}, #{contract_version := 2}} = fenrir_front:submit(C0, 1, 0, <<0>>),
    {{conflict, 0, 1}, _} = fenrir_front:submit(C0, 1, 1, <<1>>),
    {delivered, _} = fenrir_front:deliver(0, 0, true),
    {delivered, _} = fenrir_front:deliver(0, 0, false),
    true = lists:member({accepted, New}, fenrir_front:outbox()),
    Final = observed(Db, {v2, Id, Pin, MP}),
    {P0, P1} = overlap(C0, C1),
    true = P0 =/= P1,
    OverlapFinal = observed(Db, {v2, Id, Pin, MP}),
    Events = [[<<"submit">>,0,0,1,[<<"accepted">>,Old]],
              [<<"submit">>,1,0,1,[<<"accepted">>,[1,0,1,0,0]]],
              [<<"complete">>,1,0,false,[<<"delivered">>]],
              [<<"upgrade">>,<<"begin">>,hex(Pin),hex(MP),[<<"ok">>]], Prepared,
              [<<"upgrade">>,<<"migrate">>,[<<"ok">>]], Migrated,
              [<<"submit">>,0,0,1,[<<"unavailable">>]],
              [<<"upgrade">>,<<"cut-over">>,[<<"ok">>]], CutOver,
              [<<"respond">>,[<<"accepted">>,Old]],
              [<<"submit">>,0,0,1,[<<"accepted">>,Old]],
              [<<"submit">>,0,1,0,[<<"accepted">>,New]],
              [<<"submit">>,0,1,1,[<<"conflict">>,0,1]],
              [<<"complete">>,0,0,true,[<<"delivered">>]],
              [<<"complete">>,0,0,false,[<<"delivered">>]], Final,
              [<<"concurrent">>, [[<<"submit">>,0,2,1,[<<"accepted">>,[0,2,1,2,2,2]]],
                                  [<<"submit">>,1,2,0,[<<"accepted">>,[1,2,0,1,1,2]]]]],
              OverlapFinal],
    History = #{schema => <<"fenrir.service.history/2">>, scenario => <<"a4-worker-upgrade">>,
                handler_pin => hex(Pin), migration_pin => hex(MP), tenants => 2, events => Events},
    ok = file:write_file(filename:join(Out, "history.json"), json:encode(History)),
    %% An equivalent descriptor at the same path must still fail the durable pin.
    ok = file:write_file(V2Path, <<Descr/binary, "\n">>),
    {{refused, durable_image_pin_mismatch}, _} = fenrir_front:submit(C0, 2, 0, <<0>>),
    ok = file:write_file(V2Path, Descr),
    V2Pid = whereis(a4w1),
    V2Mon = monitor(process, V2Pid),
    exit(V2Pid, kill),
    receive {'DOWN', V2Mon, process, V2Pid, killed} -> ok after 5000 -> error(v2_kill_unobserved) end,
    true = is_pid(wait_worker(a4w1, V2Pid, 100)),
    Front = whereis(fenrir_front),
    ok = fenrir_front:respond({accepted, New}),
    ok = gen_server:stop(Sup),
    {ok, Sup2} = fenrir_service_sup:start_link(Config),
    {prepared, Id, Pin, MP} = Prep,
    {ok, {v2, Id, Pin, MP}} = fenrir_store:maintenance(state),
    undefined = whereis(w1),
    not_in_outbox = fenrir_front:respond({accepted, New}),
    {{accepted, New}, #{contract_version := 2}} = fenrir_front:submit(C0, 1, 0, <<0>>),
    ok = gen_server:stop(Sup2),
    cut_over_lost_ack(Out, Config, Opts, C0, V2Path, Migration, Pin, MP),
    {ok, []} = file:list_dir(maps:get(a4_launch_dir, Opts)),
    ok = file:write_file(filename:join(Out, "worker.json"), json:encode(
        #{status => <<"worker-fixture-pass">>, qualification => <<"UNKNOWN">>,
          scope => <<"A4 supervised cutover fixture; no node crash campaign">>,
          v1_worker_retired => true, front_outbox_preserved => true, v2_worker_kill_observed => true,
          overlapping_calls => 2, supervisor_restart_v2_only => true, cut_over_lost_ack_observed => true,
          migration_requests => MigrationRequests,
          handler_pin => binary:encode_hex(Pin, lowercase), migration_pin => binary:encode_hex(MP, lowercase)})),
    io:format("A4 worker fixture passed (~p migration requests)~n", [MigrationRequests]),
    ok.

hex(B) -> binary:encode_hex(B, lowercase).

cut_over_lost_ack(Out, Config, Opts, Credential, Handler, Migration, Pin, MP) ->
    Db = filename:join(Out, "cut-over-ack.db"),
    {ok, Sup} = fenrir_service_sup:start_link(Config#{db := Db}),
    Front = whereis(fenrir_front),
    OldWorker = whereis(w1),
    {{accepted, Old = [0,0,1,0,0]}, _} = fenrir_front:submit(Credential, 0, 1, <<1>>),
    {ok, Prep = {prepared, Id, Pin, MP}} = fenrir_service_sup:prepare(Handler, Migration),
    Prepared = observed(Db, Prep),
    {ok, {data, <<"Migrated">>, <<"Installed">>, []}, #{commit := committed}} =
        fenrir_a4_upgrade:migrate(Id, Migration, Opts),
    Migrated = observed(Db, {migrated, Id, Pin, MP}),
    Store = whereis(fenrir_store),
    M = monitor(process, Store),
    ok = fenrir_store:arm_port(after_commit, 1),
    {indeterminate, {port_died, maintenance_commit, {lost_commit_ack, 137}}} =
        fenrir_service_sup:cut_over(Id, Handler),
    receive {'DOWN', M, process, Store, sqlite_port_died} -> ok after 5000 -> error(cut_over_ack_store_survived) end,
    true = is_pid(wait_worker(fenrir_store, Store, 100)),
    {ok, {v2, Id, Pin, MP}} = fenrir_store:maintenance(state),
    %% The first call never reached retirement; routing and stale-worker
    %% fencing already follow the durable state, not in-memory progress.
    Front = whereis(fenrir_front),
    OldWorker = whereis(w1),
    {refused, version_not_in_force} = fenrir_worker:run(OldWorker, {tenant, 0}, {submit, 0, 1, <<1>>}),
    CutOver = observed(Db, {v2, Id, Pin, MP}),
    ok = fenrir_front:respond({accepted, Old}),
    {{accepted, Old}, #{contract_version := 2}} = fenrir_front:submit(Credential, 0, 1, <<1>>),
    ok = fenrir_service_sup:cut_over(Id, Handler),
    undefined = whereis(w1),
    undefined = whereis(w2),
    Front = whereis(fenrir_front),
    Final = observed(Db, {v2, Id, Pin, MP}),
    Events = [[<<"submit">>,0,0,1,[<<"accepted">>,Old]],
              [<<"upgrade">>,<<"begin">>,hex(Pin),hex(MP),[<<"ok">>]], Prepared,
              [<<"upgrade">>,<<"migrate">>,[<<"ok">>]], Migrated,
              [<<"upgrade">>,<<"cut-over">>,[<<"indeterminate">>]], CutOver,
              [<<"respond">>,[<<"accepted">>,Old]],
              [<<"submit">>,0,0,1,[<<"accepted">>,Old]], Final],
    ok = file:write_file(filename:join(Out, "cut-over-lost-ack.json"), json:encode(
        #{schema => <<"fenrir.service.history/2">>, scenario => <<"cut-over-lost-ack">>,
          handler_pin => hex(Pin), migration_pin => hex(MP), tenants => 2, events => Events})),
    ok = gen_server:stop(Sup).

overlap(C0, C1) ->
    Parent = self(),
    Job = fun(C, D) ->
        spawn(fun() ->
            receive go ->
                Started = erlang:monotonic_time(),
                Result = fenrir_front:submit(C, 2, D, <<D>>),
                Finished = erlang:monotonic_time(),
                Parent ! {self(), Started, Finished, Result}
            end
        end)
    end,
    W0 = Job(C0, 1),
    W1 = Job(C1, 0),
    W0 ! go,
    W1 ! go,
    {S0, E0, P0} = receive
        {W0, A0, B0, {{accepted,[0,2,1,2,2,2]}, #{worker := Pid0, contract_version := 2}}} -> {A0,B0,Pid0}
    after 10000 -> error(tenant_0_overlap_failed) end,
    {S1, E1, P1} = receive
        {W1, A1, B1, {{accepted,[1,2,0,1,1,2]}, #{worker := Pid1, contract_version := 2}}} -> {A1,B1,Pid1}
    after 10000 -> error(tenant_1_overlap_failed) end,
    true = erlang:max(S0, S1) < erlang:min(E0, E1),
    {P0, P1}.

wait_worker(_, _, 0) -> error(worker_not_replaced);
wait_worker(Name, Previous, N) ->
    case whereis(Name) of
        P when is_pid(P), P =/= Previous -> P;
        _ -> timer:sleep(10), wait_worker(Name, Previous, N - 1)
    end.

%% Independent SQLite observer, with rows and durable metadata in one snapshot.
observed(Db, Expected = {Phase, _, HP, MP}) ->
    {ok, P} = fenrir_store:open_configured(Db, normal),
    try
        [] = rows(P, "BEGIN"),
        [[Schema, Encoded]] = rows(P, "SELECT s.v,u.v FROM meta s,meta u WHERE s.k='schema' AND u.k='upgrade'"),
        {ok, Expected} = fenrir_upgrade_state:decode(Schema, Encoded),
        R = rows(P, "SELECT tenant,id,digest FROM reports ORDER BY tenant,id"),
        J = case Phase of
            prepared -> rows(P, "SELECT tenant,id,report,status FROM jobs ORDER BY tenant,id");
            _ -> rows(P, "SELECT tenant,id,report,status,attempts FROM jobs ORDER BY tenant,id")
        end,
        K0 = "SELECT tenant,key,digest,r_tenant,r_key,r_digest,r_report,r_job,",
        K = rows(P, K0 ++ (case Phase of prepared -> "1"; _ -> "receipt_version" end) ++
                    " FROM request_keys ORDER BY tenant,key"),
        Next = rows(P, "SELECT tenant,next FROM tenants ORDER BY tenant"),
        [] = rows(P, "COMMIT"),
        Stores = [[ [Rest || [T|Rest] <- R, T =:= Tenant],
                    [Rest || [T|Rest] <- J, T =:= Tenant],
                    [[Key,D,receipt([RT,RK,RD,RR,RJ],V)] || [T,Key,D,RT,RK,RD,RR,RJ,V] <- K, T =:= Tenant],
                    N] || [Tenant,N] <- Next],
        [<<"observe">>, Stores, [atom_to_binary(Phase), hex(HP), hex(MP)]]
    after fenrir_sqlite:close(P) end.

rows(P, Q) -> {rows, R} = fenrir_sqlite:exec(P, Q), R.
receipt(R, 1) -> R;
receipt(R, 2) -> R ++ [2].

foreign(Fun) ->
    Parent = self(),
    Pid = spawn(fun() -> Parent ! {self(), Fun()} end),
    receive {Pid, R} -> R after 10000 -> error(foreign_timeout) end.
