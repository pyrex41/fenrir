%% Adapter-only checks. Fixture SQL may set otherwise unreachable states to
%% challenge the fence; it is not a migration or cut-over implementation.
-module(fenrir_a4_unit).
-export([tests/1]).

tests(C) ->
    [{a4_phase_codec, fun codec/0},
     {a4_transactional_fence, fun() -> fixture(C, "a4-fence", fun fence/2) end},
     {a4_session_authority, fun() -> fixture(C, "a4-session", fun authority/2) end},
     {a4_session_owner_death, fun() -> fixture(C, "a4-owner", fun owner_death/2) end},
     {a4_maintenance_operator_death, fun() -> fixture(C, "a4-operator", fun operator_death/2) end},
     {a4_unauthorized_call_does_not_revoke, fun authorization_transition/0},
     {a4_durable_preparation, fun() -> fixture(C, "a4-restart", fun restart/2) end},
     {a4_exact_snapshot_and_projection, fun() -> fixture(C, "a4-snapshot", fun projection/2) end},
     {a4_maintenance_lost_ack, fun() -> fixture(C, "a4-lost-ack", fun lost_ack/2) end},
     {a4_legacy_adoption, fun() -> fixture(C, "a4-legacy", fun legacy/2) end}].

fixture(C, Name, F) ->
    Db = filename:join([maps:get(out, C), "unit", Name ++ ".db"]),
    fenrir_drive:fresh_db(Db),
    Opts = #{db => Db, tenants => 2, mutant => normal, maintenance_operator => self()},
    undefined = whereis(fenrir_store),
    try F(Db, Opts)
    after
        case erase(a4_fixture_store) of
            P when is_pid(P) -> case is_process_alive(P) of true -> stop(P); false -> ok end;
            undefined -> ok
        end
    end.

start(Opts) ->
    {ok, Pid} = gen_server:start({local, fenrir_store}, fenrir_store, Opts, []),
    put(a4_fixture_store, Pid),
    Pid.

stop(Pid) -> ok = gen_server:stop(Pid, normal, 10000).

m(Request) -> fenrir_store:maintenance(Request).

pin(Label) ->
    fenrir_upgrade_state:image_pin(<<"descriptor:", Label/binary>>, <<"artifact">>, <<"image">>, <<"tender">>).

prep() -> {ok, _} = m({prepare, pin(<<"handler">>), pin(<<"migration">>)}).

open({prepared, Id, _, Pin}, Owner) -> m({open, Id, Pin, Owner}).
phase({_, Id, H, M}, Phase) -> {Phase, Id, H, M}.

sql(P, Text, Args) -> {rows, Rows} = fenrir_sqlite:exec(P, Text, Args), Rows.

with_port(Db, F) ->
    {ok, P} = fenrir_store:open_configured(Db, normal),
    try F(P) after fenrir_sqlite:close(P) end.

set_phase(Db, Schema, State) ->
    with_port(Db, fun(P) ->
        [] = sql(P, "BEGIN IMMEDIATE", []),
        [] = sql(P, "UPDATE meta SET v=?1 WHERE k='upgrade'", [fenrir_upgrade_state:encode(State)]),
        [] = sql(P, "UPDATE meta SET v=?1 WHERE k='schema'", [fenrir_upgrade_state:schema(Schema)]),
        [] = sql(P, "COMMIT", [])
    end).

data(T, C, Fs) -> {data, T, C, Fs}.
i(N) -> {int, N}.

tx(T, K) ->
    Writes = [data(<<"Write">>, <<"PutReport">>, [i(1), {bytes, <<"body">>}]),
              data(<<"Write">>, <<"StageJob">>, []),
              data(<<"Write">>, <<"RecordKey">>, [i(K), i(1)])],
    Ws = lists:foldr(fun(W, Acc) -> data(<<"Writes">>, <<"Then">>, [W, Acc]) end,
                     data(<<"Writes">>, <<"Done">>, []), Writes),
    data(<<"Tx">>, <<"Tx">>, [data(<<"Cap">>, <<"Tenant">>, [i(T)]),
                             data(<<"Guard">>, <<"Once">>, [i(K)]), Ws]).

submit(T, K) -> fenrir_store:commit({tenant, T}, tx(T, K)).

codec() ->
    Handler = pin(<<"handler">>),
    Migration = pin(<<"migration">>),
    {ok, {prepared, _, Handler, Migration} = S} = fenrir_upgrade_state:prepare(Handler, Migration),
    {ok, S} = fenrir_upgrade_state:decode(fenrir_upgrade_state:schema(1), fenrir_upgrade_state:encode(S)),
    {error, invalid_upgrade_metadata} = fenrir_upgrade_state:decode(fenrir_upgrade_state:schema(2), fenrir_upgrade_state:encode(S)),
    ok = fenrir_upgrade_state:fence(1, S),
    {error, version_not_in_force} = fenrir_upgrade_state:fence(2, S),
    {error, version_not_in_force} = fenrir_upgrade_state:fence(2, phase(S, migrated)),
    ok = fenrir_upgrade_state:fence(2, phase(S, v2)),
    {error, version_not_in_force} = fenrir_upgrade_state:fence(1, phase(S, v2)),
    true.

fence(Db, Opts) ->
    Pid = start(Opts),
    {reply, _} = submit(0, 1),
    {ok, Prep} = prep(),
    %% v1 remains in force during preparation; existing tenant checks still apply.
    {aborted, unauthorized_scope} = fenrir_store:commit({tenant, 1}, tx(0, 2)),
    {reply, _} = submit(0, 2),
    Before = fenrir_store:snapshot(),
    with_port(Db, fun(OtherPort) ->
        [] = sql(OtherPort, "BEGIN IMMEDIATE", []),
        busy = submit(0, 3),
        [] = sql(OtherPort, "ROLLBACK", [])
    end),
    [] = set_phase(Db, 2, phase(Prep, migrated)),
    {aborted, version_not_in_force} = submit(0, 3),
    %% A stale retry gets no receipt either; the fence precedes the tenant guard.
    {aborted, version_not_in_force} = submit(0, 1),
    [] = set_phase(Db, 2, phase(Prep, v2)),
    {aborted, version_not_in_force} = submit(0, 3),
    with_port(Db, fun(P) ->
        [] = sql(P, "DELETE FROM meta WHERE k='upgrade'", [])
    end),
    {aborted, {invalid_store_version, missing_upgrade_metadata}} = submit(0, 3),
    with_port(Db, fun(P) ->
        [] = sql(P, "INSERT INTO meta VALUES ('upgrade',?1)", [fenrir_upgrade_state:encode(phase(Prep, v2))])
    end),
    Before = fenrir_store:snapshot(),
    stop(Pid),
    {error, {store_schema, {unsupported_store_phase, v2}}} =
        gen_server:start({local, fenrir_store}, fenrir_store, Opts, []),
    true.

as_owner() ->
    spawn(fun Loop() ->
        receive {From, Request} -> From ! {self(), m(Request)}, Loop() end
    end).

ask(Pid, Request) ->
    Pid ! {self(), Request},
    receive {Pid, Out} -> Out after 5000 -> error(session_timeout) end.

authority(Db, Opts) ->
    P = start(maps:remove(maintenance_operator, Opts)),
    {refused, unauthorized_maintenance} = m({prepare, pin(<<"handler">>), pin(<<"migration">>)}),
    stop(P),
    _ = start(Opts),
    {refused, invalid_image_pin} = m({prepare, <<>>, <<>>}),
    {ok, {prepared, Id, _, Pin} = Prep} = prep(),
    Owner = as_owner(),
    Other = as_owner(),
    try
        {refused, unauthorized_maintenance} = ask(Other, {open, Id, Pin, Other}),
        {refused, wrong_preparation_or_image} = m({open, Id, pin(<<"wrong">>), Owner}),
        {ok, Token} = open(Prep, Owner),
        {refused, session_active} = open(Prep, Other),
        {refused, unauthorized_maintenance} = ask(Other, {read, Token}),
        {refused, unauthorized_maintenance} = ask(Other, {validate_install, Token, [], []}),
        {refused, unauthorized_maintenance} = ask(Other, {abort, Id}),
        {refused, unauthorized_maintenance} = ask(Other, {close, Token}),
        {refused, unauthorized_maintenance} = ask(Owner, {read, make_ref()}),
        {ok, [], []} = ask(Owner, {read, Token}),
        {refused, session_active} = open(Prep, Other),
        ok = m({abort, Id}),
        {ok, {prepared, NewId, _, Pin} = NewPrep} = prep(),
        true = NewId =/= Id,
        {refused, wrong_preparation} = m({abort, Id}),
        {ok, NewToken} = open(NewPrep, Owner),
        {refused, unauthorized_maintenance} = ask(Owner, {read, Token}),
        {ok, validated_only} = ask(Owner, {validate_install, NewToken, [], []}),
        {refused, unauthorized_maintenance} = ask(Owner, {validate_install, NewToken, [], []}),
        {ok, NewPrep} = m(state),
        {ok, DisplacedToken} = open(NewPrep, Owner),
        %% Even a changed pin with the same generation cannot reuse a session.
        {prepared, NewId, H, Pin} = NewPrep,
        [] = set_phase(Db, 1, {prepared, NewId, H, pin(<<"replacement">>)}),
        {refused, wrong_preparation} = ask(Owner, {read, DisplacedToken}),
        [] = set_phase(Db, 1, NewPrep),
        {refused, unauthorized_maintenance} = ask(Owner, {read, DisplacedToken}),
        true
    after exit(Owner, kill), exit(Other, kill) end.

owner_death(_Db, Opts) ->
    _ = start(Opts),
    {ok, Prep} = prep(),
    Owner = as_owner(),
    Ref = monitor(process, Owner),
    {ok, Token} = open(Prep, Owner),
    exit(Owner, kill),
    receive {'DOWN', Ref, process, Owner, killed} -> ok after 5000 -> error(owner_not_dead) end,
    {ok, NewToken} = open(Prep, self()),
    {refused, unauthorized_maintenance} = m({read, Token}),
    {ok, [], []} = m({read, NewToken}),
    ok = m({close, NewToken}),
    true.

operator_death(_Db, Opts) ->
    Operator = as_owner(),
    Ref = monitor(process, Operator),
    try
        _ = start(Opts#{maintenance_operator := Operator}),
        {ok, {prepared, Id, _, Pin}} = ask(Operator, {prepare, pin(<<"handler">>), pin(<<"migration">>)}),
        {ok, Token} = ask(Operator, {open, Id, Pin, self()}),
        exit(Operator, kill),
        receive {'DOWN', Ref, process, Operator, killed} -> ok after 5000 -> error(operator_not_dead) end,
        {refused, unauthorized_maintenance} = m({read, Token}),
        wait_for_revocation(100),
        {reply, _} = submit(0, 1),
        true
    after exit(Operator, kill) end.

wait_for_revocation(0) -> error(operator_session_not_revoked);
wait_for_revocation(N) ->
    case sys:get_state(fenrir_store) of
        #{operator := none, maintenance := none} -> ok;
        _ -> receive after 10 -> wait_for_revocation(N - 1) end
    end.

authorization_transition() ->
    %% Force the order in which a call reaches the server before the DOWN.
    Dead = spawn(fun() -> ok end),
    Ref = monitor(process, Dead),
    receive {'DOWN', Ref, process, Dead, _} -> ok after 5000 -> error(operator_not_dead) end,
    Token = make_ref(),
    Session = #{token => Token, monitor => make_ref()},
    State = #{operator => Dead, operator_monitor => Ref, maintenance => Session},
    {reply, {refused, unauthorized_maintenance}, State} =
        fenrir_store:handle_call({maintenance, {close, Token}}, {self(), make_ref()}, State),
    {noreply, #{operator := none, maintenance := none}} =
        fenrir_store:handle_info({'DOWN', Ref, process, Dead, normal}, State),
    true.

restart(Db, Opts) ->
    First = start(Opts),
    {ok, Prep} = prep(),
    {ok, Token} = open(Prep, self()),
    stop(First),
    {error, {store_schema, prepared_tenant_domain_changed}} =
        gen_server:start({local, fenrir_store}, fenrir_store, Opts#{tenants := 3}, []),
    Second = start(Opts),
    {ok, Prep} = m(state),
    {refused, unauthorized_maintenance} = m({read, Token}),
    {ok, NewToken} = open(Prep, self()),
    ok = m({close, NewToken}),
    stop(Second),
    with_port(Db, fun(P) -> [] = sql(P, "DELETE FROM meta WHERE k='upgrade'", []) end),
    {error, {store_schema, {invalid_store_version, missing_upgrade_metadata}}} =
        gen_server:start({local, fenrir_store}, fenrir_store, Opts, []),
    true.

projection(Db, Opts) ->
    _ = start(Opts),
    {reply, _} = submit(0, 1),
    {reply, _} = submit(1, 1),
    %% Exercise the terminal attempt default without relying on a worker.
    with_port(Db, fun(P) ->
        [] = sql(P, "UPDATE jobs SET status='failed' WHERE tenant=1 AND id=0", [])
    end),
    {ok, Prep} = prep(),
    {ok, Token} = open(Prep, self()),
    {ok, Jobs, Keys} = m({read, Token}),
    NewJobs = jobs_v2(Jobs),
    {refused, invalid_projection} = m({validate_install, Token, tl(NewJobs), Keys}),
    {ok, Second} = open(Prep, self()),
    {refused, invalid_projection} = m({validate_install, Second, NewJobs, tl(Keys)}),
    {ok, WrongAttempts} = open(Prep, self()),
    {refused, invalid_projection} =
        m({validate_install, WrongAttempts, [J ++ [0] || J <- Jobs], Keys}),
    {ok, WrongReceipt} = open(Prep, self()),
    [[T, K, D, RT, RK, RD, RR, RJ] | Rest] = Keys,
    {refused, invalid_projection} =
        m({validate_install, WrongReceipt, NewJobs, [[T, K, D, RT, RK, RD, RR, RJ+1] | Rest]}),
    {ok, Third} = open(Prep, self()),
    %% Full snapshot comparison includes payload and Next, not just guest-facing rows.
    with_port(Db, fun(P) ->
        [] = sql(P, "UPDATE reports SET payload=?1 WHERE tenant=0 AND id=0", [{blob, <<"new">>}])
    end),
    {refused, snapshot_changed} = m({validate_install, Third, NewJobs, Keys}),
    {ok, Fourth} = open(Prep, self()),
    {reply, _} = submit(0, 2),
    {refused, snapshot_changed} = m({validate_install, Fourth, NewJobs, Keys}),
    {ok, Fifth} = open(Prep, self()),
    {ok, Jobs2, Keys2} = m({read, Fifth}),
    Snapshot = fenrir_store:snapshot(),
    {ok, validated_only} = m({validate_install, Fifth, jobs_v2(Jobs2), Keys2}),
    Snapshot = fenrir_store:snapshot(),
    {ok, Prep} = m(state),
    true.

jobs_v2(Jobs) ->
    [[T, J, R, St, case St of <<"pending">> -> 0; <<"failed">> -> 1 end] || [T, J, R, St] <- Jobs].

lost_ack(_Db, Opts) ->
    P = start(Opts),
    Mon = monitor(process, P),
    ok = fenrir_store:arm_port(after_commit, 1),
    {indeterminate, {port_died, maintenance_commit, {lost_commit_ack, 137}}} =
        m({prepare, pin(<<"handler">>), pin(<<"migration">>)}),
    receive {'DOWN', Mon, process, P, sqlite_port_died} -> ok after 5000 -> error(store_not_restarted) end,
    _ = start(Opts),
    Handler = pin(<<"handler">>),
    Migration = pin(<<"migration">>),
    {ok, {prepared, _, Handler, Migration}} = m(state),
    true.

legacy(Db, Opts) ->
    with_port(Db, fun(P) ->
        [[] = sql(P, Q, []) || Q <- fenrir_store:schema()],
        [] = sql(P, "INSERT INTO meta VALUES ('schema','fenrir.host.service-store/1')", []),
        [] = sql(P, "INSERT INTO tenants VALUES (0,7)", [])
    end),
    _ = start(Opts),
    {ok, v1} = m(state),
    [[[], [], [], 7], [[], [], [], 0]] = fenrir_store:snapshot(),
    true.
