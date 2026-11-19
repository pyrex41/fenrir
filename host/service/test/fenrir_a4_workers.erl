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
    StoreOpts = #{db => Db, tenants => 2, maintenance_operator => self()},
    {ok, Store} = fenrir_store:start_link(StoreOpts),
    {Creds, Bindings} = fenrir_authority:campaign_credentials(2),
    C0 = maps:get(0, Creds),
    C1 = maps:get(1, Creds),
    {ok, V1} = fenrir_worker:start_link(a4v1, Opts#{image => V1Path, name => a4v1}),
    {ok, Front} = fenrir_front:start_link([a4v1], Bindings),
    {{accepted, Old=[0,0,1,0,0]}, _} = fenrir_front:submit(C0, 0, 1, <<1>>),
    {{accepted, [1,0,1,0,0]}, _} = fenrir_front:submit(C1, 0, 1, <<1>>),
    {delivered, _} = fenrir_front:deliver(1, 0, false),
    {refused, _} = fenrir_a4_upgrade:prepare(Migration, V2Path),
    {ok, Prep = {prepared, Id, Pin, MP}} = fenrir_a4_upgrade:prepare(V2Path, Migration),
    %% A copied descriptor with a changed request table must not be admitted.
    {ok, Descr} = file:read_file(V2Path),
    Descriptor = json:decode(Descr),
    [First | Rest] = maps:get(<<"entries">>, Descriptor),
    BadPath = filename:join(Out, "bad-entry.json"),
    ok = file:write_file(BadPath, json:encode(Descriptor#{<<"entries">> := [First#{<<"program">> := 1} | Rest]})),
    {error, _} = fenrir_a4_image:admit(BadPath, handler_v2),
    {refused, unauthorized_maintenance} = foreign(fun() -> fenrir_a4_upgrade:migrate(Id, Migration, Opts) end),
    {ok, V2} = fenrir_worker:start_link(a4v2, Opts#{image => V2Path, name => a4v2, a4_pin => Pin}),
    {refused, version_not_in_force} = fenrir_worker:run(a4v2, {tenant, 0}, {submit, 0, 1, <<1>>}),
    {refused, wrong_preparation_or_image} = fenrir_a4_upgrade:cut_over(Id, V2Path),
    {ok, {data, <<"Migrated">>, <<"Installed">>, []}, #{requests := MigrationRequests, commit := committed}} =
        fenrir_a4_upgrade:migrate(Id, Migration, Opts),
    true = MigrationRequests =:= 10,
    {ok, {migrated, Id, Pin, MP}} = fenrir_store:maintenance(state),
    {unavailable, _} = fenrir_front:submit(C0, 0, 1, <<1>>),
    {refused, version_not_in_force} = fenrir_worker:run(a4v2, {tenant, 0}, {submit, 0, 1, <<1>>}),
    ok = fenrir_a4_upgrade:cut_over(Id, V2Path),
    ok = gen_server:stop(Front),
    {ok, Front2} = fenrir_front:start_link([a4v2], Bindings),
    {{refused, unauthorized}, _} = fenrir_front:submit(<<0:256>>, 1, 0, <<0>>),
    {{accepted, Old}, #{contract_version := 2}} = fenrir_front:submit(C0, 0, 1, <<1>>),
    {{accepted, New=[0,1,0,1,1,2]}, #{contract_version := 2}} = fenrir_front:submit(C0, 1, 0, <<0>>),
    {{conflict, 0, 1}, _} = fenrir_front:submit(C0, 1, 1, <<1>>),
    {delivered, _} = fenrir_front:deliver(0, 0, true),
    {delivered, _} = fenrir_front:deliver(0, 0, false),
    true = lists:member({accepted, New}, fenrir_front:outbox()),
    %% An equivalent descriptor at the same path must still fail the durable pin.
    ok = file:write_file(V2Path, <<Descr/binary, "\n">>),
    {{refused, durable_image_pin_mismatch}, _} = fenrir_front:submit(C0, 2, 0, <<0>>),
    ok = file:write_file(V2Path, Descr),
    ok = gen_server:stop(Front2),
    ok = gen_server:stop(V2),
    ok = gen_server:stop(V1),
    ok = gen_server:stop(Store),
    {ok, Store2} = fenrir_store:start_link(StoreOpts),
    {prepared, Id, Pin, MP} = Prep,
    {ok, {v2, Id, Pin, MP}} = fenrir_store:maintenance(state),
    {ok, V2Again} = fenrir_worker:start_link(a4v2, Opts#{image => V2Path, name => a4v2, a4_pin => Pin}),
    {ok, {data, <<"Response">>, <<"Accepted">>, [{data, <<"Receipt">>, <<"Receipt2">>, _}]}, _} =
        fenrir_worker:run(a4v2, {tenant, 0}, {submit, 1, 0, <<0>>}),
    ok = gen_server:stop(V2Again),
    ok = gen_server:stop(Store2),
    {ok, []} = file:list_dir(maps:get(a4_launch_dir, Opts)),
    ok = file:write_file(filename:join(Out, "report.json"), json:encode(
        #{status => <<"development-pass">>, qualification => <<"UNKNOWN">>,
          scope => <<"A4 bounded worker fixture; not a history campaign">>,
          migration_requests => MigrationRequests,
          handler_pin => binary:encode_hex(Pin, lowercase), migration_pin => binary:encode_hex(MP, lowercase)})),
    io:format("A4 worker fixture passed (~p migration requests)~n", [MigrationRequests]),
    ok.

foreign(Fun) ->
    Parent = self(),
    Pid = spawn(fun() -> Parent ! {self(), Fun()} end),
    receive {Pid, R} -> R after 10000 -> error(foreign_timeout) end.
