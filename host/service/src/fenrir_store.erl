%% A3: the SQLite storage adapter. It discharges the handler's one durable operation,
%% Store.commit : Tx --> Reply, under the storage contract of spec/service/HANDLER.md
%% section 3 (executable statement: models/service-a2/store-contract.shen). Host
%% infrastructure with a stated contract (host/service/CONTRACT.md), not covered by
%% Fenrir's proofs.
%%
%% One commit is ONE SQLite transaction: BEGIN IMMEDIATE (the write lock is taken first,
%% so the transaction never upgrades a read lock mid-flight), the guard read, the writes,
%% COMMIT. With WAL and synchronous=FULL SQLite requests WAL sync before COMMIT
%% returns (CONTRACT.md A-DUR). Scope was assigned by trusted OTP. Outcomes of commit/2:
%%   {reply, ReplyValue}       committed (or a guard/authority answer with no write)
%%   busy                      SQLITE_BUSY: nothing applied, retryable; never a rollback
%%                             of committed work and never a success
%%   {aborted, Reason}         definitely not applied (failed before COMMIT was sent)
%%   {indeterminate, Reason}   COMMIT was sent and its answer was lost: may or may not
%%                             have committed; the caller must not report either
%%
%% Host mutants (CONTRACT.md section 5), selected by the application environment key
%% `mutant`, each outside the normal code path: volatile_mailbox, respond_before_commit,
%% two_transactions, busy_as_success, no_dedup, sync_off, no_transaction, and the
%% equivalent control equivalent_control. `normal` is the adapter.
-module(fenrir_store).
-behaviour(gen_server).
-export([start_link/1, commit/2, snapshot/0, pending_jobs/0, port_os_pid/0, arm_port/2, info/0, io_counters/0]).
-export([maintenance/1, commit_v2/4, handler_in_force/1, routing_phase/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([parse_tx/1, schema/0, read_snapshot/2, open_configured/2]).

-define(MAILBOX, fenrir_mailbox).

start_link(Opts) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

commit(Scope, Tx) ->
    try gen_server:call(?MODULE, {commit, Scope, Tx}, 60000)
    catch exit:Reason -> {indeterminate, {store_call, element(1, Reason)}}
    end.
snapshot() -> gen_server:call(?MODULE, snapshot, 60000).
pending_jobs() -> gen_server:call(?MODULE, pending_jobs, 60000).
port_os_pid() -> gen_server:call(?MODULE, port_os_pid).
arm_port(Kind, N) -> gen_server:call(?MODULE, {arm_port, Kind, N}).
info() -> gen_server:call(?MODULE, info).
io_counters() -> gen_server:call(?MODULE, io_counters).
%% Adapter-only development interface, not exposed by the service node or worker.
maintenance(Request) ->
    try gen_server:call(?MODULE, {maintenance, Request}, 60000)
    catch exit:Reason -> {indeterminate, {store_call, Reason}}
    end.
%% Adapter-only v2 entry. Scope, pin and request come from trusted host code;
%% only Tx is decoded from a guest. No A3 worker calls this function.
commit_v2(Scope, Pin, Request, Tx) ->
    try gen_server:call(?MODULE, {commit_v2, Scope, Pin, Request, Tx}, 60000)
    catch exit:Reason -> {indeterminate, {store_call, Reason}}
    end.

handler_in_force(Pin) -> gen_server:call(?MODULE, {handler_in_force, Pin}, 60000).

%% Read-only routing advice. This is not a grant: the store fences every write
%% again after taking the write lock, including a request routed just before install.
routing_phase() ->
    try gen_server:call(?MODULE, routing_phase, 1000)
    catch exit:_ -> {error, store_unavailable}
    end.

schema() ->
    ["CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)",
     "CREATE TABLE IF NOT EXISTS tenants (tenant INTEGER PRIMARY KEY, next INTEGER NOT NULL CHECK (next >= 0))",
     "CREATE TABLE IF NOT EXISTS reports (tenant INTEGER NOT NULL REFERENCES tenants(tenant), id INTEGER NOT NULL,"
     " digest INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY (tenant, id))",
     "CREATE TABLE IF NOT EXISTS jobs (tenant INTEGER NOT NULL REFERENCES tenants(tenant), id INTEGER NOT NULL,"
     " report INTEGER NOT NULL, status TEXT NOT NULL CHECK (status IN ('pending','done','failed')), PRIMARY KEY (tenant, id))",
     "CREATE TABLE IF NOT EXISTS request_keys (tenant INTEGER NOT NULL REFERENCES tenants(tenant), key INTEGER NOT NULL,"
     " digest INTEGER NOT NULL, r_tenant INTEGER NOT NULL, r_key INTEGER NOT NULL, r_digest INTEGER NOT NULL,"
     " r_report INTEGER NOT NULL, r_job INTEGER NOT NULL, PRIMARY KEY (tenant, key))"].

%% ---------- gen_server ----------

init(Opts) ->
    process_flag(trap_exit, true),
    Path = maps:get(db, Opts),
    Tenants = maps:get(tenants, Opts),
    Mutant = maps:get(mutant, Opts, normal),
    Operator = maps:get(maintenance_operator, Opts, none),
    case Operator =:= none orelse (Mutant =:= normal andalso local_alive(Operator)) of
        true -> init_store(Path, Tenants, Mutant, Operator);
        false -> {stop, invalid_maintenance_operator}
    end.

init_store(Path, Tenants, Mutant, Operator) ->
    case open_configured(Path, Mutant) of
        {ok, Port} ->
            A4 = Operator =/= none,
            try ensure_schema(Port, Tenants, Mutant, A4) of
                ok -> {ok, #{port => Port, tenants => Tenants, mutant => Mutant, deferred => [],
                             a4 => A4, operator => Operator, operator_monitor => watch_operator(Operator),
                             maintenance => none}}
            catch throw:Why ->
                fenrir_sqlite:close(Port),
                {stop, {store_schema, Why}}
            end;
        {error, E} -> {stop, E}
    end.

%% Open and configure a connection: WAL, synchronous=FULL, foreign keys on, a short busy
%% timeout. Each setting is read back; a setting that did not take is a refusal to start.
open_configured(Path, Mutant) ->
    case fenrir_sqlite:open(Path) of
        {ok, Port} -> configure(Port, Mutant);
        {error, _} = E -> E
    end.

configure(Port, Mutant) ->
    Sync = case Mutant of sync_off -> "OFF"; _ -> "FULL" end,
    Checks = [{"PRAGMA journal_mode=WAL", [[<<"wal">>]]},
              {"PRAGMA synchronous=" ++ Sync, []},
              {"PRAGMA synchronous", [[case Mutant of sync_off -> 0; _ -> 2 end]]},
              {"PRAGMA foreign_keys=ON", []},
              {"PRAGMA foreign_keys", [[1]]},
              {"PRAGMA busy_timeout=50", [[50]]},
              {"PRAGMA busy_timeout", [[50]]}],
    Bad = [{Q, R} || {Q, Want} <- Checks, (R = fenrir_sqlite:exec(Port, Q)) =/= {rows, Want}],
    case Bad of
        [] -> {ok, Port};
        _ -> fenrir_sqlite:close(Port), {error, {connection_settings, Bad}}
    end.

handle_call({commit, Scope, TxValue}, _From, S0 = #{tenants := N}) ->
    case parse_tx(TxValue) of
        {ok, {tx, T, Guard, Writes}} when Scope =:= {tenant, T}, T >= 0, T < N ->
            %% Use the host tenant for all SQL, after checking the guest's claim.
            {tenant, HostTenant} = Scope,
            S = flush_deferred(S0),
            {Out, S1} = do_commit({tx, HostTenant, Guard, Writes}, S), reply_or_stop(Out, S1);
        {ok, {tx, T, _, _}} when Scope =:= {tenant, T} ->
            {reply, {reply, reply(<<"Unauthorized">>)}, S0};
        {ok, _} -> {reply, {aborted, unauthorized_scope}, S0};
        error -> {reply, {aborted, malformed_tx}, S0}
    end;
handle_call({maintenance, Request}, {Caller, _}, S) ->
    {Out, S1} = maintenance_call(Caller, Request, S),
    reply_or_stop(Out, S1);
handle_call({commit_v2, Scope, Pin, Request, Tx}, _From,
            S = #{a4 := true, tenants := N, port := Port}) ->
    case check_v2_request(Scope, Request, Tx, N) of
        {ok, T} ->
            Out = maintenance_tx(Port, fun() ->
                case upgrade_state(Port) of
                    {v2, _, Pin, _} -> do_v2(Port, T, Request);
                    {v2, _, _, _} -> {read, {aborted, wrong_handler_image}};
                    _ -> {read, {aborted, version_not_in_force}}
                end
            end),
            reply_or_stop(Out, S);
        {error, Why} -> {reply, {aborted, Why}, S}
    end;
handle_call({commit_v2, _, _, _, _}, _From, S) ->
    {reply, {aborted, v2_disabled}, S};
handle_call({handler_in_force, Pin}, _From, S = #{a4 := true, port := Port}) ->
    Out = maintenance_tx(Port, fun() ->
        case upgrade_state(Port) of
            {v2, _, Pin, _} -> {read, ok};
            {v2, _, _, _} -> {read, {refused, wrong_handler_image}};
            _ -> {read, {refused, version_not_in_force}}
        end
    end),
    reply_or_stop(Out, S);
handle_call({handler_in_force, _}, _From, S) ->
    {reply, {refused, v2_disabled}, S};
handle_call(routing_phase, _From, S = #{a4 := true, port := Port}) ->
    Out = maintenance_tx(Port, "BEGIN", fun() ->
        {read, case upgrade_state(Port) of
            v1 -> {ok, v1};
            {prepared, _, Pin, _} -> {ok, {prepared, Pin}};
            {migrated, _, Pin, _} -> {ok, {migrated, Pin}};
            {v2, _, Pin, _} -> {ok, {v2, Pin}}
        end}
    end),
    reply_or_stop(Out, S);
handle_call(routing_phase, _From, S) ->
    {reply, {error, a4_disabled}, S};
handle_call(snapshot, _From, S = #{a4 := true, port := Port, tenants := N}) ->
    Out = maintenance_tx(Port, fun() ->
        case fenrir_upgrade_state:fence(1, upgrade_state(Port)) of
            ok -> {read, snapshot_rows(Port, N)};
            {error, _} -> {read, {refused, v1_snapshot_unavailable}}
        end
    end),
    reply_or_stop(Out, S);
handle_call(snapshot, _From, S0) ->
    S = flush_deferred(S0),
    Snap = read_snapshot(maps:get(port, S), maps:get(tenants, S)),
    Snap2 = case maps:get(mutant, S) of
                volatile_mailbox -> with_mailbox_jobs(Snap);
                _ -> Snap
            end,
    {reply, Snap2, S};
handle_call(pending_jobs, _From, S0) ->
    S = flush_deferred(S0),
    Jobs = case maps:get(mutant, S) of
               volatile_mailbox -> lists:sort([{T, J, R} || {{T, J}, R, <<"pending">>} <- ets:tab2list(?MAILBOX)]);
               _ ->
                   {rows, Rows} = fenrir_sqlite:exec(maps:get(port, S),
                       "SELECT tenant, id, report FROM jobs WHERE status = 'pending' ORDER BY tenant, id"),
                   [{T, J, R} || [T, J, R] <- Rows]
           end,
    {reply, Jobs, S};
handle_call(port_os_pid, _From, S) -> {reply, fenrir_sqlite:os_pid(maps:get(port, S)), S};
handle_call({arm_port, Kind, N}, _From, S) -> {reply, fenrir_sqlite:arm(maps:get(port, S), Kind, N), S};
handle_call(io_counters, _From, S) -> {reply, fenrir_sqlite:counters(maps:get(port, S)), S};
handle_call(info, _From, S) -> {reply, maps:with([tenants, mutant], S), S}.

handle_cast(_, S) -> {noreply, S}.

handle_info(flush, S) -> {noreply, flush_deferred(S)};
handle_info({'DOWN', Ref, process, _, _}, S = #{operator_monitor := Ref}) ->
    {noreply, clear_session(S#{operator := none, operator_monitor := none})};
handle_info({'DOWN', Ref, process, _, _}, S = #{maintenance := #{monitor := Ref}}) ->
    {noreply, S#{maintenance := none}};
handle_info({Port, {exit_status, St}}, S = #{port := Port}) -> {stop, {sqlite_port_exit, St}, S};
handle_info({'EXIT', Port, R}, S = #{port := Port}) -> {stop, {sqlite_port_exit, R}, S};
handle_info(_, S) -> {noreply, S}.

terminate(_, #{port := Port}) -> catch fenrir_sqlite:close(Port), ok;
terminate(_, _) -> ok.

%% A dead port means the connection is gone: answer the caller, then stop so the
%% supervisor reopens the database (SQLite recovers the WAL on open).
reply_or_stop({Kind, {port_died, _, _}} = Out, S) when Kind =:= aborted; Kind =:= indeterminate ->
    {stop, sqlite_port_died, Out, S};
reply_or_stop(Out, S) -> {reply, Out, S}.

%% ---------- the transaction ----------

parse_tx({data, <<"Tx">>, <<"Tx">>, [Cap, Guard, Writes]}) ->
    try {ok, {tx, cap(Cap), guard(Guard), writes(Writes)}}
    catch _:_ -> error
    end;
parse_tx(_) -> error.

cap({data, <<"Cap">>, <<"Tenant">>, [{int, T}]}) when is_integer(T) -> T.
guard({data, <<"Guard">>, <<"Always">>, []}) -> always;
guard({data, <<"Guard">>, <<"Once">>, [{int, K}]}) -> {once, K};
guard({data, <<"Guard">>, <<"Pending">>, [{int, J}]}) -> {pending, J}.
writes({data, <<"Writes">>, <<"Done">>, []}) -> [];
writes({data, <<"Writes">>, <<"Then">>, [W, Ws]}) -> [write(W) | writes(Ws)].
write({data, <<"Write">>, <<"PutReport">>, [{int, D}, {bytes, P}]}) -> {put_report, D, P};
write({data, <<"Write">>, <<"StageJob">>, []}) -> stage_job;
write({data, <<"Write">>, <<"StageJobOf">>, [{int, R}]}) -> {stage_job_of, R};
write({data, <<"Write">>, <<"RecordKey">>, [{int, K}, {int, D}]}) -> {record_key, K, D};
write({data, <<"Write">>, <<"Finish">>, [{int, J}, {bool, Ok}]}) -> {finish, J, Ok}.

receipt(T, K, D, R, J) -> {data, <<"Receipt">>, <<"Receipt">>, [{int, T}, {int, K}, {int, D}, {int, R}, {int, J}]}.
reply(Name) -> {data, <<"Reply">>, Name, []}.

hit(Point, S) ->
    Port = maps:get(port, S),
    fenrir_faults:hit(Point, #{port => fenrir_sqlite:os_pid(Port), store_port => Port, store => self()}).

%% Statement helper: any port death or error ends the attempt with a classified outcome.
-define(Q(Sql, Params, Phase), q(Port, Sql, Params, Phase)).
q(Port, Sql, Params, Phase) ->
    case fenrir_sqlite:exec(Port, Sql, Params) of
        {rows, Rows} -> Rows;
        {sqlite_error, busy, _, _} -> throw({busy, Phase});
        {sqlite_error, locked, _, _} -> throw({busy, Phase});
        {sqlite_error, C, E, M} -> throw({sql_error, Phase, C, E, M});
        {port_died, R} -> throw({port_died, Phase, R})
    end.

%% One-time adoption of legacy A3 metadata in the same transaction as initialization.
%% For adopted stores an absent/invalid phase is not equivalent to v1.
ensure_schema(Port, Tenants, Mutant, A4) ->
    ?Q("BEGIN IMMEDIATE", [], init_begin),
    case ?Q("PRAGMA user_version", [], init_metadata) of
        [[0]] -> adopt_legacy(Port);
        [[1]] -> ok;
        _ -> throw(invalid_metadata_format)
    end,
    State = upgrade_state(Port),
    case State of
        v1 ->
            [?Q("INSERT OR IGNORE INTO tenants VALUES (?1, 0)", [T], init_tenant) ||
                T <- lists:seq(0, Tenants - 1)];
        {prepared, _, _, _} when Mutant =:= normal ->
            %% Do not expand the tenant domain of an in-progress preparation
            %% as a side effect of restarting with different configuration.
            ensure_upgrade_tenants(Port, Tenants);
        {Phase, _, _, _} when A4, (Phase =:= migrated orelse Phase =:= v2) ->
            ensure_upgrade_tenants(Port, Tenants),
            ?Q("SELECT attempts FROM jobs LIMIT 0", [], init_schema),
            ?Q("SELECT receipt_version FROM request_keys LIMIT 0", [], init_schema);
        _ -> throw({unsupported_store_phase, element(1, State)})
    end,
    ?Q("COMMIT", [], init_commit),
    ok.

ensure_upgrade_tenants(Port, Tenants) ->
    Expected = [[T] || T <- lists:seq(0, Tenants - 1)],
    case ?Q("SELECT tenant FROM tenants ORDER BY tenant", [], init_tenant) of
        Expected -> ok;
        _ -> throw(prepared_tenant_domain_changed)
    end.

adopt_legacy(Port) ->
    case ?Q("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
            [], init_metadata) of
        [] ->
            [?Q(Sql, [], init_schema) || Sql <- schema()],
            ?Q("INSERT INTO meta VALUES ('schema', ?1)", [fenrir_upgrade_state:schema(1)], init_schema);
        [[<<"jobs">>], [<<"meta">>], [<<"reports">>], [<<"request_keys">>], [<<"tenants">>]] ->
            case ?Q("SELECT k, v FROM meta ORDER BY k", [], init_metadata) of
                [[<<"schema">>, <<"fenrir.host.service-store/1">>]] -> ok;
                _ -> throw(invalid_legacy_metadata)
            end;
        _ -> throw(invalid_legacy_schema)
    end,
    ?Q("INSERT INTO meta VALUES ('upgrade','v1')", [], init_metadata),
    ?Q("PRAGMA user_version=1", [], init_metadata),
    ok.

upgrade_state(Port) ->
    case ?Q("SELECT k, v FROM meta WHERE k IN ('schema','upgrade') ORDER BY k", [], version_fence) of
        [[<<"schema">>, Schema], [<<"upgrade">>, Phase]] ->
            case fenrir_upgrade_state:decode(Schema, Phase) of
                {ok, State} -> State;
                {error, Why} -> throw({invalid_store_version, Why})
            end;
        _ -> throw({invalid_store_version, missing_upgrade_metadata})
    end.

%% ---------- isolated A4 maintenance (no installation or guest entrypoint) ----------

local_alive(Pid) when is_pid(Pid), node(Pid) =:= node() -> is_process_alive(Pid);
local_alive(_) -> false.

watch_operator(none) -> none;
watch_operator(Pid) -> monitor(process, Pid).

maintenance_call(Caller, Request, S = #{operator := Operator}) ->
    case local_alive(Operator) of
        true -> maintenance_live(Caller, Request, S);
        %% Authorization never changes session state. A monitored operator's
        %% DOWN notification owns the cleanup, even if a call arrives first.
        false -> {{refused, unauthorized_maintenance}, S}
    end.

maintenance_live(Caller, Request, S = #{operator := Caller, port := Port}) ->
    case Request of
        state -> {maintenance_tx(Port, fun() -> {read, {ok, upgrade_state(Port)}} end), S};
        {prepare, Handler, Migration} ->
            case fenrir_upgrade_state:prepare(Handler, Migration) of
                {ok, Prepared} ->
                    {maintenance_tx(Port, fun() ->
                        case upgrade_state(Port) of
                            v1 -> set_upgrade_state(Port, Prepared), {write, {ok, Prepared}};
                            _ -> {read, {refused, wrong_phase}}
                        end
                    end), S};
                {error, Why} -> {{refused, Why}, S}
            end;
        {abort, Id} ->
            Outcome = maintenance_tx(Port, fun() ->
                case upgrade_state(Port) of
                    {prepared, Id, _, _} -> set_upgrade_state(Port, v1), {write, ok};
                    _ -> {read, {refused, wrong_preparation}}
                end
            end),
            {Outcome, case Outcome of ok -> clear_session(S); _ -> S end};
        {cut_over, Id, HandlerPin} ->
            {maintenance_tx(Port, fun() ->
                case upgrade_state(Port) of
                    {migrated, Id, HandlerPin, MigrationPin} ->
                        set_upgrade_state(Port, {v2, Id, HandlerPin, MigrationPin}),
                        {write, ok};
                    _ -> {read, {refused, wrong_preparation_or_image}}
                end
            end), S};
        {open, Id, Pin, Owner} ->
            open_session(Port, Id, Pin, Owner, S);
        _ -> session_call(Caller, Request, S)
    end;
maintenance_live(Caller, Request, S) -> session_call(Caller, Request, S).

set_upgrade_state(Port, Prepared) ->
    ?Q("UPDATE meta SET v = ?1 WHERE k = 'upgrade'", [fenrir_upgrade_state:encode(Prepared)], maintenance_metadata),
    ok.

open_session(Port, Id, Pin, Owner, S0) ->
    S = case maps:get(maintenance, S0) of
            #{owner := Prior} -> case local_alive(Prior) of true -> S0; false -> clear_session(S0) end;
            none -> S0
        end,
    case {maps:get(maintenance, S), local_alive(Owner)} of
        {_, false} -> {{refused, invalid_session_owner}, S};
        {none, true} ->
            Outcome = maintenance_tx(Port, fun() ->
                case upgrade_state(Port) of
                    {prepared, Id, _, Pin} = Prepared ->
                        {read, {ok, Prepared, maintenance_snapshot(Port)}};
                    _ -> {read, {refused, wrong_preparation_or_image}}
                end
            end),
            case Outcome of
                {ok, Prep, Snapshot} ->
                    Token = make_ref(),
                    Ref = monitor(process, Owner),
                    {{ok, Token}, S#{maintenance := #{owner => Owner, monitor => Ref, token => Token,
                                                     prep => Prep, snapshot => Snapshot}}};
                Other -> {Other, S}
            end;
        _ -> {{refused, session_active}, S}
    end.

session_call(Owner, {read, Token}, S = #{port := Port, maintenance :=
        #{owner := Owner, token := Token, prep := Prep, snapshot := {_, Jobs, Keys, _}}}) ->
    Outcome = maintenance_tx(Port, fun() ->
        case upgrade_state(Port) of
            Prep -> {read, {ok, Jobs, Keys}};
            _ -> {read, {refused, wrong_preparation}}
        end
    end),
    {Outcome, case Outcome of {refused, wrong_preparation} -> clear_session(S); _ -> S end};
session_call(Owner, {migration_in_force, Token, Id, Pin}, S = #{port := Port, maintenance :=
        #{owner := Owner, token := Token, prep := Prep = {prepared, Id, _, Pin}}}) ->
    {maintenance_tx(Port, fun() ->
         case upgrade_state(Port) of Prep -> {read, ok}; _ -> {read, {refused, wrong_preparation}} end
     end), S};
session_call(Owner, {refresh, Token}, S = #{port := Port, maintenance :=
        Session = #{owner := Owner, token := Token, prep := Prep}}) ->
    Out = maintenance_tx(Port, fun() ->
        case upgrade_state(Port) of
            Prep -> {read, {ok, maintenance_snapshot(Port)}};
            _ -> {read, {refused, wrong_preparation}}
        end
    end),
    case Out of
        {ok, Snapshot} -> {ok, S#{maintenance := Session#{snapshot := Snapshot}}};
        _ -> {Out, S}
    end;
session_call(Owner, {Mode, Token, Jobs, Keys}, S = #{port := Port, maintenance :=
        #{owner := Owner, token := Token, prep := Prep, snapshot := Snapshot}})
  when Mode =:= validate_install; Mode =:= install; Mode =:= install_retryable ->
    Outcome = maintenance_tx(Port, fun() ->
        case upgrade_state(Port) of
            Prep ->
                case maintenance_snapshot(Port) of
                    Snapshot ->
                        case validate_projection(Snapshot, Jobs, Keys) of
                            {ok, validated_only} when Mode =/= validate_install -> install_v2(Port, Prep);
                            Result -> {read, Result}
                        end;
                    _ -> {read, {refused, snapshot_changed}}
                end;
            _ -> {read, {refused, wrong_preparation}}
        end
    end),
    %% The same admitted live execution may retry a changed snapshot, but
    %% must refresh it explicitly; every other install outcome closes it.
    {Outcome, case {Mode, Outcome} of
                  {install_retryable, {refused, snapshot_changed}} ->
                      S#{maintenance := (maps:get(maintenance, S))#{snapshot := stale}};
                  _ -> clear_session(S)
              end};
session_call(Owner, {close, Token}, S = #{maintenance := #{owner := Owner, token := Token}}) ->
    {ok, clear_session(S)};
session_call(_, _, S) -> {{refused, unauthorized_maintenance}, S}.

clear_session(S = #{maintenance := #{monitor := Ref}}) ->
    demonitor(Ref, [flush]),
    S#{maintenance := none};
clear_session(S) -> S.

maintenance_snapshot(Port) ->
    [[JobCount, KeyCount, Bytes]] = ?Q("SELECT (SELECT count(*) FROM jobs), (SELECT count(*) FROM request_keys),"
                                         " (SELECT coalesce(sum(length(payload)),0) FROM reports)",
                                         [], maintenance_snapshot_limit),
    (JobCount + KeyCount =< 128 andalso Bytes =< 4194304) orelse throw(migration_snapshot_limit),
    {?Q("SELECT tenant,id,digest,payload FROM reports ORDER BY tenant,id", [], maintenance_snapshot),
     ?Q("SELECT tenant,id,report,status FROM jobs ORDER BY tenant,id", [], maintenance_snapshot),
     ?Q("SELECT tenant,key,digest,r_tenant,r_key,r_digest,r_report,r_job FROM request_keys ORDER BY tenant,key",
        [], maintenance_snapshot),
     ?Q("SELECT tenant,next FROM tenants ORDER BY tenant", [], maintenance_snapshot)}.

validate_projection({_, OldJobs, OldKeys, _}, Jobs, Keys) ->
    Expected = [[T, I, R, Status, case Status of <<"pending">> -> 0; _ -> 1 end]
                || [T, I, R, Status] <- OldJobs],
    %% Key rows carry the original receipt fields, all of which must be equal.
    case Jobs =:= Expected andalso Keys =:= OldKeys of
        true -> {ok, validated_only};
        false -> {refused, invalid_projection}
    end.

%% Exact projection was compared under this write lock. Apply it in-place:
%% all old keys keep the v1 receipt form; reports and counters are untouched.
install_v2(Port, {prepared, Id, Handler, Migration}) ->
    ?Q("ALTER TABLE jobs ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts IN (0,1))",
       [], migration_jobs),
    ?Q("UPDATE jobs SET attempts=1 WHERE status IN ('done','failed')", [], migration_attempts),
    ?Q("ALTER TABLE request_keys ADD COLUMN receipt_version INTEGER NOT NULL DEFAULT 1 CHECK(receipt_version IN (1,2))",
       [], migration_keys),
    ?Q("UPDATE meta SET v=?1 WHERE k='schema'", [fenrir_upgrade_state:schema(2)], migration_schema),
    set_upgrade_state(Port, {migrated, Id, Handler, Migration}),
    {write, {ok, installed}}.

%% Bind the allowed v2 write set to the host's original request, not just the
%% tenant claimed by the guest. The isolated slice admits exactly the two
%% pinned handler shapes (not a general-purpose v2 Store implementation).
check_v2_request({tenant, T}, Request, {data, <<"Tx">>, <<"Tx2">>, [Cap, G, Ws]}, N)
  when is_integer(T), T >= 0, T < N ->
    case Cap of
        {data, <<"Cap">>, <<"Tenant">>, [{int, T}]} ->
            try {guard(G), writes_v2(Ws)} of
                Shape ->
                    case v2_matches(Request, Shape) of
                        true -> {ok, T};
                        false -> {error, request_mismatch}
                    end
            catch error:function_clause -> {error, malformed_tx}
            end;
        _ -> {error, unauthorized_scope}
    end;
check_v2_request(_, _, _, _) -> {error, malformed_tx_or_scope}.

writes_v2({data, <<"Writes">>, <<"Done">>, []}) -> [];
writes_v2({data, <<"Writes">>, <<"Then">>, [W, Ws]}) -> [write_v2(W) | writes_v2(Ws)].
write_v2({data, <<"Write">>, <<"StageJob2">>, [{int, 0}]}) -> stage_job;
write_v2({data, <<"Write">>, <<"CountAttempt">>, [{int, J}]}) -> {count_attempt, J};
write_v2(W = {data, <<"Write">>, Name, _})
  when Name =:= <<"Finish">>; Name =:= <<"PutReport">>; Name =:= <<"RecordKey">> -> write(W).

v2_matches({submit, K, D, P}, {{once, K}, [stage_job, {put_report, D, P}, {record_key, K, D}]}) ->
    i64(K) andalso i64(D) andalso is_binary(P);
v2_matches({complete, J, Ok}, {{pending, J}, [{finish, J, Ok}, {count_attempt, J}]}) ->
    i64(J) andalso is_boolean(Ok);
v2_matches(_, _) -> false.

i64(N) -> is_integer(N) andalso N >= -9223372036854775808 andalso N =< 9223372036854775807.

do_v2(Port, T, {submit, K, D, P}) ->
    case ?Q("SELECT digest, r_tenant, r_key, r_digest, r_report, r_job, receipt_version FROM request_keys"
            " WHERE tenant=?1 AND key=?2", [T, K], guard) of
        [] ->
            N = case ?Q("SELECT next FROM tenants WHERE tenant=?1", [T], tenant) of
                    [[Next]] when is_integer(Next) -> Next;
                    _ -> throw(invalid_tenant_counter)
                end,
            case i64(N + 1) of false -> throw(counter_exhausted); true -> ok end,
            ?Q("INSERT INTO reports (tenant,id,digest,payload) VALUES (?1,?2,?3,?4)", [T, N, D, {blob, P}], put_report),
            ?Q("INSERT INTO jobs (tenant,id,report,status,attempts) VALUES (?1,?2,?2,'pending',0)", [T, N], stage_job),
            ?Q("INSERT INTO request_keys VALUES (?1,?2,?3,?1,?2,?3,?4,?4,2)", [T, K, D, N], record_key),
            ?Q("UPDATE tenants SET next=?2 WHERE tenant=?1", [T, N + 1], next),
            {write, {reply, {data, <<"Reply">>, <<"Committed">>, [receipt_v(2, T, K, D, N, N)]}}};
        [[Recorded, T, K, Recorded, R, J, V]] when V =:= 1; V =:= 2 ->
            {read, {reply, {data, <<"Reply">>, <<"Recorded">>, [{int, Recorded}, receipt_v(V, T, K, Recorded, R, J)]}}};
        _ -> throw(invalid_receipt)
    end;
do_v2(Port, T, {complete, J, Ok}) ->
    case ?Q("SELECT attempts FROM jobs WHERE tenant=?1 AND id=?2 AND status='pending'", [T, J], guard) of
        [] -> {read, {reply, reply(<<"Skipped">>)}};
        [[0]] ->
            ?Q("UPDATE jobs SET status=?3, attempts=1 WHERE tenant=?1 AND id=?2", [T, J, status(Ok)], finish),
            {write, {reply, reply(<<"Applied">>)}};
        _ -> throw(invalid_pending_attempts)
    end.

receipt_v(1, T, K, D, R, J) -> receipt(T, K, D, R, J);
receipt_v(2, T, K, D, R, J) ->
    {data, <<"Receipt">>, <<"Receipt2">>, [{int, T}, {int, K}, {int, D}, {int, R}, {int, J}]}.

maintenance_tx(Port, Body) ->
    maintenance_tx(Port, "BEGIN IMMEDIATE", Body).

maintenance_tx(Port, Begin, Body) ->
    try ?Q(Begin, [], maintenance_begin) of
        [] -> maintenance_body(Port, Body)
    catch
        throw:{busy, _} -> busy;
        throw:Why -> {aborted, Why}
    end.

maintenance_body(Port, Body) ->
    try
        case Body() of
            {read, Result} -> ?Q("ROLLBACK", [], maintenance_read_end), Result;
            {write, Result} -> maintenance_commit(Port, Result)
        end
    catch
        throw:{busy, _} -> rollback(Port), busy;
        throw:{port_died, _, _} = Why -> {aborted, Why};
        throw:Why -> rollback(Port), {aborted, Why}
    end.

maintenance_commit(Port, Result) ->
    try ?Q("COMMIT", [], maintenance_commit) of [] -> Result
    catch
        throw:{port_died, _, _} = Why -> {indeterminate, Why};
        throw:{busy, _} -> rollback(Port), busy;
        throw:Why -> rollback(Port), {aborted, Why}
    end.

do_commit(Tx, S = #{mutant := respond_before_commit}) -> early_reply(Tx, S);
do_commit(Tx, S = #{mutant := no_transaction}) -> {run_tx(Tx, S, false), S};
do_commit(Tx, S) -> {run_tx(Tx, S, true), S}.

%% One transaction (Transactional = false only for the no_transaction mutant).
run_tx({tx, T, Guard, Writes}, S, Transactional) ->
    erase(second),
    Port = maps:get(port, S),
    Mutant = maps:get(mutant, S),
    Begun = case Transactional of
                true ->
                    case fenrir_sqlite:exec(Port, "BEGIN IMMEDIATE", []) of
                        {rows, _} -> ok;
                        {sqlite_error, B, _, _} when B =:= busy; B =:= locked -> busy;
                        {sqlite_error, C0, E0, M0} -> {aborted, {begin_failed, C0, E0, M0}};
                        {port_died, R0} -> {aborted, {port_died, begin_immediate, R0}}
                    end;
                false -> ok
            end,
    case Begun of
        busy when Mutant =:= busy_as_success -> {reply, fabricate(T, Guard, Writes, Port)};
        busy -> busy;
        {aborted, _} = A -> A;
        ok ->
            hit(s1_after_begin, S),
            try
                %% This path is A3/v1 only. Neither the guest constructor nor
                %% its claimed tenant can select the contract that is in force.
                case fenrir_upgrade_state:fence(1, upgrade_state(Port)) of
                    ok -> body(T, Guard, Writes, S, Transactional);
                    {error, FenceWhy} -> throw({version_fence, FenceWhy})
                end
            of
                {done, Reply} -> {reply, Reply};
                {commit, Reply} ->
                    Fault = hit(s3_before_commit, S),
                    finish(Port, Reply, S, Transactional, Fault)
            catch
                throw:{version_fence, Why} -> rollback(Port), {aborted, Why};
                throw:{invalid_store_version, Why} -> rollback(Port), {aborted, {invalid_store_version, Why}};
                throw:{busy, _} -> rollback(Port), busy;
                throw:{port_died, Phase, R} -> {aborted, {port_died, Phase, R}};
                throw:{sql_error, Phase, C, E, M} -> rollback(Port), {aborted, {sql_error, Phase, C, E, M}}
            end
    end.

finish(_Port, Reply, S, false, _) -> hit(s4_after_commit, S), {reply, Reply};
finish(Port, Reply, S, true, Fault) ->
    case fenrir_sqlite:exec(Port, "COMMIT", []) of
        {rows, _} -> hit(s4_after_commit, S), after_commit(Reply, S);
        {sqlite_error, B, _, _} when B =:= busy; B =:= locked -> rollback(Port), busy;
        {sqlite_error, C, E, M} -> rollback(Port), {aborted, {commit_failed, C, E, M}};
        {port_died, R} -> fenrir_faults:lost_ack(Fault, R), {indeterminate, {port_died, commit, R}}
    end.

%% two_transactions mutant: the job record is written by a second transaction.
after_commit(Reply, S = #{mutant := two_transactions}) ->
    case erase(second) of
        undefined -> {reply, Reply};
        {T, N} -> second_tx(Reply, T, N, S)
    end;
after_commit(Reply, _S) -> {reply, Reply}.

second_tx(Reply, T, N, S) ->
    Port = maps:get(port, S),
    hit(s5_between_transactions, S),
    try
        ?Q("BEGIN IMMEDIATE", [], second_begin),
        ?Q("INSERT INTO jobs VALUES (?1, ?2, ?2, 'pending')", [T, N], second_job),
        ?Q("COMMIT", [], second_commit),
        {reply, Reply}
    catch
        throw:{port_died, _, R} -> {indeterminate, {port_died, second_transaction, R}};
        throw:_ -> rollback(Port), {reply, Reply}
    end.

rollback(Port) -> fenrir_sqlite:exec(Port, "ROLLBACK", []), ok.

%% The guard and the writes, inside the open transaction. {done, Reply}: nothing to write
%% (the transaction is rolled back, it made no change); {commit, Reply}: commit it.
body(T, Guard, Writes, S, Transactional) ->
    Port = maps:get(port, S),
    Mutant = maps:get(mutant, S),
    case ?Q("SELECT next FROM tenants WHERE tenant = ?1", [T], tenant) of
        [] -> close_read(Port, Transactional), {done, reply(<<"Unauthorized">>)};
        [[N]] ->
            case guard_check(Mutant, Guard, T, Port) of
                {stop, Reply} -> close_read(Port, Transactional), {done, Reply};
                apply ->
                    {Allocated, Receipt} = apply_writes(Mutant, T, N, Writes, S),
                    _ = Allocated,
                    {commit, case Receipt of none -> reply(<<"Applied">>); R -> {data, <<"Reply">>, <<"Committed">>, [R]} end}
            end
    end.

close_read(Port, true) -> rollback(Port);
close_read(_, false) -> ok.

guard_check(_, always, _, _) -> apply;
guard_check(no_dedup, {once, _}, _, _) -> apply;
guard_check(Mutant, {once, K}, T, Port) ->
    Rows = case Mutant of
               equivalent_control ->
                   case ?Q("SELECT count(*) FROM request_keys WHERE tenant = ?1 AND key = ?2", [T, K], guard) of
                       [[0]] -> [];
                       [[1]] -> ?Q("SELECT digest, r_tenant, r_key, r_digest, r_report, r_job FROM request_keys"
                                    " WHERE key = ?2 AND tenant = ?1", [T, K], guard)
                   end;
               _ -> ?Q("SELECT digest, r_tenant, r_key, r_digest, r_report, r_job FROM request_keys"
                        " WHERE tenant = ?1 AND key = ?2", [T, K], guard)
           end,
    case Rows of
        [] -> apply;
        [[D, RT, RK, RD, RR, RJ]] -> {stop, {data, <<"Reply">>, <<"Recorded">>, [{int, D}, receipt(RT, RK, RD, RR, RJ)]}}
    end;
guard_check(volatile_mailbox, {pending, J}, T, _Port) ->
    case ets:lookup(?MAILBOX, {T, J}) of
        [{_, _, <<"pending">>}] -> apply;
        _ -> {stop, reply(<<"Skipped">>)}
    end;
guard_check(_, {pending, J}, T, Port) ->
    case ?Q("SELECT 1 FROM jobs WHERE tenant = ?1 AND id = ?2 AND status = 'pending'", [T, J], guard) of
        [] -> {stop, reply(<<"Skipped">>)};
        _ -> apply
    end.

%% The writes in order with N = Next (HANDLER.md section 3, step 3). Returns
%% {Allocated, Receipt}.
apply_writes(equivalent_control, T, N, Writes, S) ->
    %% Same meaning, other order: the counter first, then the writes last to first.
    Allocated = lists:any(fun(W) -> allocates(W) end, Writes),
    Port = maps:get(port, S),
    Allocated andalso ?Q("UPDATE tenants SET next = ?2 WHERE tenant = ?1", [T, N + 1], next),
    Receipt = lists:foldl(fun({record_key, K, D}, _) -> receipt(T, K, D, N, N); (_, R) -> R end, none, Writes),
    [one_write(equivalent_control, T, N, W, S) || W <- lists:reverse(Writes)],
    hit(s2_mid_writes, S),
    {Allocated, Receipt};
apply_writes(Mutant, T, N, Writes, S) ->
    Port = maps:get(port, S),
    {Allocated, Receipt, _} =
        lists:foldl(fun(W, {A, R, I}) ->
                            R2 = case one_write(Mutant, T, N, W, S) of none -> R; NewR -> NewR end,
                            I =:= 0 andalso hit(s2_mid_writes, S),
                            {A orelse allocates(W), R2, I + 1}
                    end, {false, none, 0}, Writes),
    Allocated andalso ?Q("UPDATE tenants SET next = ?2 WHERE tenant = ?1", [T, N + 1], next),
    {Allocated, Receipt}.

allocates({put_report, _, _}) -> true;
allocates(stage_job) -> true;
allocates({record_key, _, _}) -> true;
allocates(_) -> false.

one_write(_, T, N, {put_report, D, P}, S) ->
    Port = maps:get(port, S),
    ?Q("INSERT INTO reports VALUES (?1, ?2, ?3, ?4)", [T, N, D, {blob, P}], put_report), none;
one_write(volatile_mailbox, T, N, stage_job, _S) -> ets:insert(?MAILBOX, {{T, N}, N, <<"pending">>}), none;
one_write(two_transactions, T, N, stage_job, _S) -> put(second, {T, N}), none;
one_write(_, T, N, stage_job, S) ->
    Port = maps:get(port, S),
    ?Q("INSERT INTO jobs VALUES (?1, ?2, ?2, 'pending')", [T, N], stage_job), none;
one_write(_, T, _N, {stage_job_of, R}, S) ->
    Port = maps:get(port, S),
    ?Q("INSERT INTO jobs VALUES (?1, ?2, ?2, 'pending')", [T, R], stage_job_of), none;
one_write(Mutant, T, N, {record_key, K, D}, S) ->
    Port = maps:get(port, S),
    Verb = case Mutant of no_dedup -> "INSERT OR REPLACE"; _ -> "INSERT" end,
    ?Q(Verb ++ " INTO request_keys VALUES (?1, ?2, ?3, ?1, ?2, ?3, ?4, ?4)", [T, K, D, N], record_key),
    receipt(T, K, D, N, N);
one_write(volatile_mailbox, T, _N, {finish, J, Ok}, _S) ->
    [ets:update_element(?MAILBOX, {T, J}, {3, status(Ok)}) || ets:member(?MAILBOX, {T, J})], none;
one_write(_, T, _N, {finish, J, Ok}, S) ->
    Port = maps:get(port, S),
    ?Q("UPDATE jobs SET status = ?3 WHERE tenant = ?1 AND id = ?2", [T, J, {text, status(Ok)}], finish), none.

status(true) -> <<"done">>;
status(false) -> <<"failed">>.

%% busy_as_success mutant: the reply the commit would have given, from a read, with
%% nothing written.
fabricate(T, Guard, Writes, Port) ->
    case fenrir_sqlite:exec(Port, "SELECT next FROM tenants WHERE tenant = ?1", [T]) of
        {rows, [[N]]} ->
            case [receipt(T, K, D, N, N) || {record_key, K, D} <- Writes] of
                [R | _] when Guard =/= always -> {data, <<"Reply">>, <<"Committed">>, [R]};
                [R | _] -> {data, <<"Reply">>, <<"Committed">>, [R]};
                [] -> reply(<<"Applied">>)
            end;
        _ -> reply(<<"Unauthorized">>)
    end.

%% respond_before_commit mutant: answer from a read of the current store, as if the
%% commit had happened, and run the transaction later (deferred, about 200 ms).
early_reply(Tx = {tx, T, Guard, Writes}, S) ->
    Port = maps:get(port, S),
    Reply = try
                case ?Q("SELECT next FROM tenants WHERE tenant = ?1", [T], tenant) of
                    [] -> reply(<<"Unauthorized">>);
                    [[N]] ->
                        case guard_check(normal, Guard, T, Port) of
                            {stop, R} -> R;
                            apply ->
                                case [receipt(T, K, D, N, N) || {record_key, K, D} <- Writes] of
                                    [R | _] -> {data, <<"Reply">>, <<"Committed">>, [R]};
                                    [] -> reply(<<"Applied">>)
                                end
                        end
                end
            catch throw:_ -> reply(<<"Unauthorized">>)
            end,
    erlang:send_after(200, self(), flush),
    {{reply, Reply}, S#{deferred := maps:get(deferred, S) ++ [Tx]}}.

flush_deferred(S = #{deferred := []}) -> S;
flush_deferred(S = #{deferred := Txs}) ->
    [run_tx(Tx, S#{mutant := normal}, true) || Tx <- Txs],
    S#{deferred := []}.

%% ---------- reading the store ----------

%% The canonical store view (ACCEPTED_JOB.md section 3), one entry per tenant:
%% [Reports, Jobs, Keys, Next]. Read in one read transaction.
read_snapshot(Port, Tenants) ->
    {rows, _} = fenrir_sqlite:exec(Port, "BEGIN"),
    Snapshot = snapshot_rows(Port, Tenants),
    {rows, _} = fenrir_sqlite:exec(Port, "COMMIT"),
    Snapshot.

snapshot_rows(Port, Tenants) ->
    {rows, Reps} = fenrir_sqlite:exec(Port, "SELECT tenant, id, digest FROM reports ORDER BY tenant, id"),
    {rows, Jobs} = fenrir_sqlite:exec(Port, "SELECT tenant, id, report, status FROM jobs ORDER BY tenant, id"),
    {rows, Keys} = fenrir_sqlite:exec(Port, "SELECT tenant, key, digest, r_tenant, r_key, r_digest, r_report, r_job"
                                             " FROM request_keys ORDER BY tenant, key"),
    {rows, Next} = fenrir_sqlite:exec(Port, "SELECT tenant, next FROM tenants ORDER BY tenant"),
    [[[[I, D] || [T1, I, D] <- Reps, T1 =:= T],
      [[I, R, St] || [T1, I, R, St] <- Jobs, T1 =:= T],
      [[K, D, [A, B, C, E, F]] || [T1, K, D, A, B, C, E, F] <- Keys, T1 =:= T],
      N]
     || T <- lists:seq(0, Tenants - 1), N <- [proplists:get_value(T, [{X, Y} || [X, Y] <- Next], missing)]].

with_mailbox_jobs(Snap) ->
    Box = ets:tab2list(?MAILBOX),
    lists:map(fun({T, [Reps, Jobs, Keys, N]}) ->
                      Extra = [[J, R, St] || {{T1, J}, R, St} <- Box, T1 =:= T],
                      [Reps, lists:sort(Jobs ++ Extra), Keys, N]
              end, lists:zip(lists:seq(0, length(Snap) - 1), Snap)).
