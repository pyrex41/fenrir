%% A3/A4: the SQLite storage adapter. It discharges the handlers' one durable operation,
%% Store.commit : Tx --> Reply, under the storage contract of the version in force
%% (contract 1: spec/service/HANDLER.md section 3, models/service-a2/store-contract.shen;
%% contract 2: spec/service/UPGRADE.md section 2.2, models/service-a4/store-contract-v2.shen),
%% and the migration contract (UPGRADE.md section 5). Host infrastructure with a stated
%% contract (host/service/CONTRACT.md), not covered by Fenrir's proofs.
%%
%% One commit is ONE SQLite transaction: BEGIN IMMEDIATE (the write lock is taken first,
%% so the transaction never upgrades a read lock mid-flight), the fencing read of the
%% durable upgrade state, the guard read, the writes, COMMIT. WAL journal with
%% synchronous=FULL: the WAL is fsynced before COMMIT returns (CONTRACT.md A-DUR).
%% Outcomes of commit/1:
%%   {reply, ReplyValue}       committed (or a guard/authority answer with no write)
%%   busy                      SQLITE_BUSY: nothing applied, retryable; never a rollback
%%                             of committed work and never a success
%%   {stale, Why}              the commit's contract version is not the version in force
%%                             (UPGRADE.md section 4.3): nothing applied, no reply
%%   {aborted, Reason}         definitely not applied (failed before COMMIT was sent)
%%   {indeterminate, Reason}   COMMIT was sent and its answer was lost: may or may not
%%                             have committed; the caller must not report either
%%
%% The durable upgrade state lives in the meta table (UPGRADE.md section 3): `schema`
%% (fenrir.host.service-store/1 or /2), `upgrade` (v1 | prepared | migrated | v2) and,
%% from begin-upgrade on, `image` (the v2 handler's artifact SHA-256), `v2_image` and
%% `migration_image` (their descriptors). The adapter refuses to open a store whose
%% schema it does not know or whose schema and upgrade state disagree.
%%
%% Host mutants (CONTRACT.md sections 5 and 7), selected by the application environment
%% key `mutant`, each outside the normal code path. A3: volatile_mailbox,
%% respond_before_commit, two_transactions, busy_as_success, no_dedup, sync_off,
%% no_transaction, equivalent_control. A4: no_fencing, migration_drops_pending,
%% migration_two_transactions, keys_not_migrated, receipt_rewritten,
%% cutover_before_migration, volatile_upgrade_state, equivalent_control_a4 (and
%% no_manifest_check, stale_workers, which live in fenrir_upgrade). `normal` is the adapter.
-module(fenrir_store).
-behaviour(gen_server).
-export([start_link/1, commit/1, snapshot/0, pending_jobs/0, port_os_pid/0, arm_port/2, info/0,
         upgrade_state/0, transition/2, migration/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([parse_tx/1, schema/0, read_snapshot/2, open_configured/2, in_force/1, read_meta/1]).

-define(MAILBOX, fenrir_mailbox).
-define(SCHEMA1, <<"fenrir.host.service-store/1">>).
-define(SCHEMA2, <<"fenrir.host.service-store/2">>).

start_link(Opts) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

commit(Tx) ->
    try gen_server:call(?MODULE, {commit, Tx}, 60000)
    catch exit:Reason -> {indeterminate, {store_call, element(1, Reason)}}
    end.
snapshot() -> gen_server:call(?MODULE, snapshot, 60000).
pending_jobs() -> gen_server:call(?MODULE, pending_jobs, 60000).
port_os_pid() -> gen_server:call(?MODULE, port_os_pid).
arm_port(Kind, N) -> gen_server:call(?MODULE, {arm_port, Kind, N}).
info() -> gen_server:call(?MODULE, info).
%% #{schema => 1 | 2, upgrade => v1 | prepared | migrated | v2, image, v2_image, migration_image}
upgrade_state() -> gen_server:call(?MODULE, upgrade_state, 60000).
%% transition(Step, Extra): Step begin_upgrade | abort | cut_over; one transaction that checks the
%% current upgrade state and writes the next. ok | {refused, Current} | busy | {indeterminate, _}
transition(Step, Extra) ->
    try gen_server:call(?MODULE, {transition, Step, Extra}, 60000)
    catch exit:Reason -> {indeterminate, {store_call, element(1, Reason)}}
    end.
%% migration(Op, Value): the migration session (UPGRADE.md section 5). Op read | stage |
%% install. {reply, Value} | busy | {aborted, _} | {indeterminate, _}
migration(Op, Value) ->
    try gen_server:call(?MODULE, {migration, Op, Value}, 60000)
    catch exit:Reason -> {indeterminate, {store_call, element(1, Reason)}}
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
    case open_configured(Path, Mutant) of
        {ok, Port} ->
            ok = ensure_schema(Port, Tenants),
            case check_meta(Port, Mutant) of
                ok ->
                    {ok, #{port => Port, tenants => Tenants, mutant => Mutant, deferred => [], session => none,
                           busy_timeout => maps:get(busy_timeout, Opts, 50)}};
                {refused, Why} -> fenrir_sqlite:close(Port), {stop, {store_refused, Why}}
            end;
        {error, E} -> {stop, E}
    end.

%% Open and configure a connection: WAL, synchronous=FULL, foreign keys on, a short busy
%% timeout. Each setting is read back; a setting that did not take is a refusal to start.
open_configured(Path, Mutant) ->
    {ok, Port} = fenrir_sqlite:open(Path),
    Sync = case Mutant of sync_off -> "OFF"; _ -> "FULL" end,
    Checks = [{"PRAGMA journal_mode=WAL", [[<<"wal">>]]},
              {"PRAGMA synchronous=" ++ Sync, []},
              {"PRAGMA synchronous", [[case Mutant of sync_off -> 0; _ -> 2 end]]},
              {"PRAGMA foreign_keys=ON", []},
              {"PRAGMA busy_timeout=50", [[50]]}],
    Bad = [{Q, R} || {Q, Want} <- Checks, (R = fenrir_sqlite:exec(Port, Q)) =/= {rows, Want}],
    case Bad of
        [] -> {ok, Port};
        _ -> fenrir_sqlite:close(Port), {error, {connection_settings, Bad}}
    end.

ensure_schema(Port, Tenants) ->
    {rows, _} = fenrir_sqlite:exec(Port, "BEGIN IMMEDIATE"),
    [{rows, _} = fenrir_sqlite:exec(Port, S) || S <- schema()],
    {rows, _} = fenrir_sqlite:exec(Port, "INSERT OR IGNORE INTO meta VALUES ('schema','fenrir.host.service-store/1')"),
    {rows, _} = fenrir_sqlite:exec(Port, "INSERT OR IGNORE INTO meta VALUES ('upgrade','v1')"),
    [{rows, _} = fenrir_sqlite:exec(Port, "INSERT OR IGNORE INTO tenants VALUES (?1, 0)", [T]) || T <- lists:seq(0, Tenants - 1)],
    {rows, _} = fenrir_sqlite:exec(Port, "COMMIT"),
    ok.

%% The schema and the upgrade state must be known and agree (UPGRADE.md section 3), and
%% the tables must have the columns of that schema.
check_meta(Port, Mutant) ->
    M = read_meta(Port),
    Cols = fun(T) -> {rows, Rs} = fenrir_sqlite:exec(Port, "SELECT name FROM pragma_table_info('" ++ T ++ "')"),
                     [N || [N] <- Rs] end,
    V2Cols = lists:member(<<"attempts">>, Cols("jobs")) andalso lists:member(<<"r_version">>, Cols("request_keys")),
    V1Cols = not lists:member(<<"attempts">>, Cols("jobs")) andalso not lists:member(<<"r_version">>, Cols("request_keys")),
    Upgrade = case Mutant of volatile_upgrade_state -> upgrade_of(M); _ -> maps:get(<<"upgrade">>, M, none) end,
    case {maps:get(<<"schema">>, M, none), Upgrade} of
        {?SCHEMA1, U} when (U =:= <<"v1">> orelse U =:= <<"prepared">>), V1Cols -> ok;
        {?SCHEMA2, U} when (U =:= <<"migrated">> orelse U =:= <<"v2">>), V2Cols -> ok;
        {S, U} -> {refused, {unknown_or_inconsistent_store, S, U, {v1_columns, V1Cols}, {v2_columns, V2Cols}}}
    end.

%% volatile_upgrade_state mutant: the upgrade state is held in the holder's ETS table
%% (lost with the node), not in meta; meta keeps 'v1'.
upgrade_of(M) ->
    case ets:info(?MAILBOX) of
        undefined -> maps:get(<<"upgrade">>, M, none);
        _ -> case ets:lookup(?MAILBOX, upgrade) of [{upgrade, U}] -> U; [] -> maps:get(<<"upgrade">>, M, none) end
    end.

read_meta(Port) ->
    {rows, Rows} = fenrir_sqlite:exec(Port, "SELECT k, v FROM meta"),
    maps:from_list([{K, V} || [K, V] <- Rows]).

handle_call({commit, TxValue}, _From, S0) ->
    S = flush_deferred(S0),
    case parse_tx(TxValue) of
        {ok, Tx} -> {Out, S1} = do_commit(Tx, S), reply_or_stop(Out, S1);
        error -> {reply, {aborted, malformed_tx}, S}
    end;
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
handle_call(info, _From, S) -> {reply, maps:with([tenants, mutant], S), S};
handle_call(upgrade_state, _From, S) -> {reply, state_view(maps:get(port, S), maps:get(mutant, S)), S};
handle_call({transition, Step, Extra}, _From, S) -> reply_or_stop(do_transition(Step, Extra, S), S);
handle_call({migration, read, {int, I}}, _From, S) -> migration_read(I, S);
handle_call({migration, stage, Row}, _From, S) -> migration_stage(Row, S);
handle_call({migration, install, {int, N}}, _From, S) ->
    {Out, S1} = migration_install(N, S),
    reply_or_stop(Out, S1);
handle_call({migration, _, _}, _From, S) -> {reply, {aborted, malformed_migration_request}, S}.

handle_cast(_, S) -> {noreply, S}.

handle_info(flush, S) -> {noreply, flush_deferred(S)};
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

%% ---------- the durable upgrade state ----------

state_view(Port, Mutant) ->
    M = read_meta(Port),
    U = case Mutant of volatile_upgrade_state -> upgrade_of(M); _ -> maps:get(<<"upgrade">>, M) end,
    #{schema => case maps:get(<<"schema">>, M) of ?SCHEMA1 -> 1; ?SCHEMA2 -> 2 end,
      upgrade => binary_to_atom(U), image => maps:get(<<"image">>, M, none),
      v2_image => maps:get(<<"v2_image">>, M, none), migration_image => maps:get(<<"migration_image">>, M, none)}.

%% The version whose commits are accepted (UPGRADE.md section 3).
in_force(v1) -> 1;
in_force(prepared) -> 1;
in_force(migrated) -> none;
in_force(v2) -> 2.

current_upgrade(Port, Mutant) ->
    M = read_meta(Port),
    U = case Mutant of volatile_upgrade_state -> upgrade_of(M); _ -> maps:get(<<"upgrade">>, M) end,
    binary_to_atom(U).

set_upgrade(Port, volatile_upgrade_state, U) ->
    ets:insert(?MAILBOX, {upgrade, atom_to_binary(U)}),
    {rows, _} = fenrir_sqlite:exec(Port, "SELECT 1"), ok;
set_upgrade(Port, _, U) ->
    q(Port, "UPDATE meta SET v = ?1 WHERE k = 'upgrade'", [{text, atom_to_binary(U)}], upgrade_state), ok.

%% begin_upgrade: v1 -> prepared (Extra: image, v2_image, migration_image); abort: prepared -> v1;
%% cut_over: migrated -> v2 (cutover_before_migration mutant: also prepared -> v2).
allowed(begin_upgrade, v1, _) -> prepared;
allowed(abort, prepared, _) -> v1;
allowed(cut_over, migrated, _) -> v2;
allowed(cut_over, prepared, cutover_before_migration) -> v2;
allowed(_, _, _) -> refused.

do_transition(Step, Extra, S) ->
    Port = maps:get(port, S),
    Mutant = maps:get(mutant, S),
    case fenrir_sqlite:exec(Port, "BEGIN IMMEDIATE", []) of
        {rows, _} ->
            try
                Cur = current_upgrade(Port, Mutant),
                case allowed(Step, Cur, Mutant) of
                    refused -> rollback(Port), {refused, Cur};
                    Next ->
                        set_upgrade(Port, Mutant, Next),
                        [q(Port, "INSERT OR REPLACE INTO meta VALUES (?1, ?2)", [{text, atom_to_binary(K)}, {text, V}], meta)
                         || {K, V} <- maps:to_list(Extra)],
                        hit(list_to_atom(atom_to_list(Step) ++ "_before_commit"), S),
                        case fenrir_sqlite:exec(Port, "COMMIT", []) of
                            {rows, _} -> hit(list_to_atom(atom_to_list(Step) ++ "_after_commit"), S), ok;
                            {sqlite_error, B, _, _} when B =:= busy; B =:= locked -> rollback(Port), busy;
                            {port_died, R} -> {indeterminate, {port_died, commit, R}};
                            Other -> rollback(Port), {aborted, Other}
                        end
                end
            catch
                throw:{busy, _} -> rollback(Port), busy;
                throw:{port_died, Phase, R2} -> {aborted, {port_died, Phase, R2}};
                throw:{sql_error, Phase, C, E, M} -> rollback(Port), {aborted, {sql_error, Phase, C, E, M}}
            end;
        {sqlite_error, B, _, _} when B =:= busy; B =:= locked -> busy;
        {port_died, R} -> {aborted, {port_died, begin_immediate, R}};
        Other -> {aborted, Other}
    end.

%% ---------- the transaction ----------

%% {tx, Version, Tenant, Guard, Writes}: the constructor is the contract version in band
%% (UPGRADE.md section 2.2).
parse_tx({data, <<"Tx">>, C, [Cap, Guard, Writes]}) when C =:= <<"Tx">>; C =:= <<"Tx2">> ->
    V = case C of <<"Tx">> -> 1; <<"Tx2">> -> 2 end,
    try {ok, {tx, V, cap(Cap), guard(Guard), writes(V, Writes)}}
    catch _:_ -> error
    end;
parse_tx(_) -> error.

cap({data, <<"Cap">>, <<"Tenant">>, [{int, T}]}) -> T.
guard({data, <<"Guard">>, <<"Always">>, []}) -> always;
guard({data, <<"Guard">>, <<"Once">>, [{int, K}]}) -> {once, K};
guard({data, <<"Guard">>, <<"Pending">>, [{int, J}]}) -> {pending, J}.
writes(_, {data, <<"Writes">>, <<"Done">>, []}) -> [];
writes(V, {data, <<"Writes">>, <<"Then">>, [W, Ws]}) -> [write(V, W) | writes(V, Ws)].
write(_, {data, <<"Write">>, <<"PutReport">>, [{int, D}, {bytes, P}]}) -> {put_report, D, P};
write(1, {data, <<"Write">>, <<"StageJob">>, []}) -> stage_job;
write(1, {data, <<"Write">>, <<"StageJobOf">>, [{int, R}]}) -> {stage_job_of, R};
write(2, {data, <<"Write">>, <<"StageJob2">>, [{int, A}]}) -> {stage_job2, A};
write(_, {data, <<"Write">>, <<"RecordKey">>, [{int, K}, {int, D}]}) -> {record_key, K, D};
write(_, {data, <<"Write">>, <<"Finish">>, [{int, J}, {bool, Ok}]}) -> {finish, J, Ok};
write(2, {data, <<"Write">>, <<"CountAttempt">>, [{int, J}]}) -> {count_attempt, J}.

receipt(1, T, K, D, R, J) -> {data, <<"Receipt">>, <<"Receipt">>, [{int, T}, {int, K}, {int, D}, {int, R}, {int, J}]};
receipt(2, T, K, D, R, J) -> {data, <<"Receipt">>, <<"Receipt2">>, [{int, T}, {int, K}, {int, D}, {int, R}, {int, J}]}.
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

do_commit(Tx, S = #{mutant := respond_before_commit}) -> early_reply(Tx, S);
do_commit(Tx, S = #{mutant := no_transaction}) -> {run_tx(Tx, S, false), S};
do_commit(Tx, S) -> {run_tx(Tx, S, true), S}.

%% One transaction (Transactional = false only for the no_transaction mutant).
run_tx({tx, V, T, Guard, Writes}, S, Transactional) ->
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
        busy when Mutant =:= busy_as_success -> {reply, fabricate(V, T, Guard, Writes, Port)};
        busy -> busy;
        {aborted, _} = A -> A;
        ok ->
            hit(s1_after_begin, S),
            %% The fence and the body are both inside the protected expression: a
            %% statement that fails there is classified below, never escapes.
            try case fence(V, S) of
                    {stale, Why} -> close_read(Port, Transactional), {stale, Why};
                    Schema -> body(V, Schema, T, Guard, Writes, S, Transactional)
                end
            of
                {stale, Why2} -> {stale, Why2};
                {done, Reply} -> {reply, Reply};
                {commit, Reply} ->
                    hit(s3_before_commit, S),
                    finish(Port, Reply, S, Transactional)
            catch
                throw:{busy, _} -> rollback(Port), busy;
                throw:{port_died, Phase, R} -> {aborted, {port_died, Phase, R}};
                throw:{sql_error, Phase, C, E, M} -> rollback(Port), {aborted, {sql_error, Phase, C, E, M}}
            end
    end.

%% Fencing (UPGRADE.md section 4.3), inside the commit's transaction: the schema (1 or 2)
%% when version V is in force, else {stale, _}. The no_fencing mutant never refuses.
fence(V, S) ->
    Port = maps:get(port, S),
    Mutant = maps:get(mutant, S),
    M = read_meta_q(Port),
    U = binary_to_atom(case Mutant of volatile_upgrade_state -> upgrade_of(M); _ -> maps:get(<<"upgrade">>, M) end),
    Schema = case maps:get(<<"schema">>, M) of ?SCHEMA1 -> 1; ?SCHEMA2 -> 2 end,
    case {Mutant, in_force(U)} of
        {no_fencing, _} -> Schema;
        {_, V} -> Schema;
        {_, InForce} -> {stale, {version, V, in_force, InForce, upgrade, U}}
    end.

read_meta_q(Port) -> maps:from_list([{K, V} || [K, V] <- q(Port, "SELECT k, v FROM meta", [], fence)]).

finish(_Port, Reply, S, false) -> hit(s4_after_commit, S), {reply, Reply};
finish(Port, Reply, S, true) ->
    case fenrir_sqlite:exec(Port, "COMMIT", []) of
        {rows, _} -> hit(s4_after_commit, S), after_commit(Reply, S);
        {sqlite_error, B, _, _} when B =:= busy; B =:= locked -> rollback(Port), busy;
        {sqlite_error, C, E, M} -> rollback(Port), {aborted, {commit_failed, C, E, M}};
        {port_died, R} -> {indeterminate, {port_died, commit, R}}
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
body(V, Schema, T, Guard, Writes, S, Transactional) ->
    Port = maps:get(port, S),
    Mutant = maps:get(mutant, S),
    case ?Q("SELECT next FROM tenants WHERE tenant = ?1", [T], tenant) of
        [] -> close_read(Port, Transactional), {done, reply(<<"Unauthorized">>)};
        [[N]] ->
            case guard_check(Mutant, Schema, Guard, T, Port) of
                {stop, Reply} -> close_read(Port, Transactional), {done, Reply};
                apply ->
                    {Allocated, Receipt} = apply_writes(Mutant, V, T, N, Writes, S),
                    _ = Allocated,
                    {commit, case Receipt of none -> reply(<<"Applied">>); R -> {data, <<"Reply">>, <<"Committed">>, [R]} end}
            end
    end.

close_read(Port, true) -> rollback(Port);
close_read(_, false) -> ok.

key_columns(1) -> "digest, r_tenant, r_key, r_digest, r_report, r_job, 1";
key_columns(2) -> "digest, r_tenant, r_key, r_digest, r_report, r_job, r_version".

guard_check(_, _, always, _, _) -> apply;
guard_check(no_dedup, _, {once, _}, _, _) -> apply;
guard_check(Mutant, Schema, {once, K}, T, Port) ->
    Cols = key_columns(Schema),
    Rows = case Mutant of
               equivalent_control ->
                   case ?Q("SELECT count(*) FROM request_keys WHERE tenant = ?1 AND key = ?2", [T, K], guard) of
                       [[0]] -> [];
                       [[1]] -> ?Q("SELECT " ++ Cols ++ " FROM request_keys WHERE key = ?2 AND tenant = ?1", [T, K], guard)
                   end;
               _ -> ?Q("SELECT " ++ Cols ++ " FROM request_keys WHERE tenant = ?1 AND key = ?2", [T, K], guard)
           end,
    case Rows of
        [] -> apply;
        [[D, RT, RK, RD, RR, RJ, RV]] -> {stop, {data, <<"Reply">>, <<"Recorded">>, [{int, D}, receipt(RV, RT, RK, RD, RR, RJ)]}}
    end;
guard_check(volatile_mailbox, _, {pending, J}, T, _Port) ->
    case ets:lookup(?MAILBOX, {T, J}) of
        [{_, _, <<"pending">>}] -> apply;
        _ -> {stop, reply(<<"Skipped">>)}
    end;
guard_check(_, _, {pending, J}, T, Port) ->
    case ?Q("SELECT 1 FROM jobs WHERE tenant = ?1 AND id = ?2 AND status = 'pending'", [T, J], guard) of
        [] -> {stop, reply(<<"Skipped">>)};
        _ -> apply
    end.

%% The writes in order with N = Next (HANDLER.md section 3, step 3; UPGRADE.md section
%% 2.2). Returns {Allocated, Receipt}.
apply_writes(equivalent_control, V, T, N, Writes, S) ->
    %% Same meaning, other order: the counter first, then the writes last to first.
    Allocated = lists:any(fun(W) -> allocates(W) end, Writes),
    Port = maps:get(port, S),
    Allocated andalso ?Q("UPDATE tenants SET next = ?2 WHERE tenant = ?1", [T, N + 1], next),
    Receipt = lists:foldl(fun({record_key, K, D}, _) -> receipt(V, T, K, D, N, N); (_, R) -> R end, none, Writes),
    [one_write(equivalent_control, V, T, N, W, S) || W <- lists:reverse(Writes)],
    hit(s2_mid_writes, S),
    {Allocated, Receipt};
apply_writes(Mutant, V, T, N, Writes, S) ->
    Port = maps:get(port, S),
    {Allocated, Receipt, _} =
        lists:foldl(fun(W, {A, R, I}) ->
                            R2 = case one_write(Mutant, V, T, N, W, S) of none -> R; NewR -> NewR end,
                            I =:= 0 andalso hit(s2_mid_writes, S),
                            {A orelse allocates(W), R2, I + 1}
                    end, {false, none, 0}, Writes),
    Allocated andalso ?Q("UPDATE tenants SET next = ?2 WHERE tenant = ?1", [T, N + 1], next),
    {Allocated, Receipt}.

allocates({put_report, _, _}) -> true;
allocates(stage_job) -> true;
allocates({stage_job2, _}) -> true;
allocates({record_key, _, _}) -> true;
allocates(_) -> false.

%% Version 1's statements name no columns (as in A3): on a schema-2 table, whose rows
%% have more columns, an INSERT fails. Version 2's name their columns.
one_write(_, _, T, N, {put_report, D, P}, S) ->
    Port = maps:get(port, S),
    ?Q("INSERT INTO reports VALUES (?1, ?2, ?3, ?4)", [T, N, D, {blob, P}], put_report), none;
one_write(volatile_mailbox, _, T, N, stage_job, _S) -> ets:insert(?MAILBOX, {{T, N}, N, <<"pending">>}), none;
one_write(two_transactions, _, T, N, stage_job, _S) -> put(second, {T, N}), none;
one_write(_, _, T, N, stage_job, S) ->
    Port = maps:get(port, S),
    ?Q("INSERT INTO jobs VALUES (?1, ?2, ?2, 'pending')", [T, N], stage_job), none;
one_write(_, _, T, _N, {stage_job_of, R}, S) ->
    Port = maps:get(port, S),
    ?Q("INSERT INTO jobs VALUES (?1, ?2, ?2, 'pending')", [T, R], stage_job_of), none;
one_write(_, _, T, N, {stage_job2, A}, S) ->
    Port = maps:get(port, S),
    ?Q("INSERT INTO jobs (tenant, id, report, status, attempts) VALUES (?1, ?2, ?2, 'pending', ?3)", [T, N, A], stage_job2), none;
one_write(Mutant, 1, T, N, {record_key, K, D}, S) ->
    Port = maps:get(port, S),
    Verb = case Mutant of no_dedup -> "INSERT OR REPLACE"; _ -> "INSERT" end,
    ?Q(Verb ++ " INTO request_keys VALUES (?1, ?2, ?3, ?1, ?2, ?3, ?4, ?4)", [T, K, D, N], record_key),
    receipt(1, T, K, D, N, N);
one_write(Mutant, 2, T, N, {record_key, K, D}, S) ->
    Port = maps:get(port, S),
    Verb = case Mutant of no_dedup -> "INSERT OR REPLACE"; _ -> "INSERT" end,
    ?Q(Verb ++ " INTO request_keys (tenant, key, digest, r_tenant, r_key, r_digest, r_report, r_job, r_version)"
       " VALUES (?1, ?2, ?3, ?1, ?2, ?3, ?4, ?4, 2)", [T, K, D, N], record_key),
    receipt(2, T, K, D, N, N);
one_write(volatile_mailbox, _, T, _N, {finish, J, Ok}, _S) ->
    [ets:update_element(?MAILBOX, {T, J}, {3, status(Ok)}) || ets:member(?MAILBOX, {T, J})], none;
one_write(_, _, T, _N, {finish, J, Ok}, S) ->
    Port = maps:get(port, S),
    ?Q("UPDATE jobs SET status = ?3 WHERE tenant = ?1 AND id = ?2", [T, J, {text, status(Ok)}], finish), none;
one_write(_, _, T, _N, {count_attempt, J}, S) ->
    Port = maps:get(port, S),
    ?Q("UPDATE jobs SET attempts = attempts + 1 WHERE tenant = ?1 AND id = ?2", [T, J], count_attempt), none.

status(true) -> <<"done">>;
status(false) -> <<"failed">>.

%% busy_as_success mutant: the reply the commit would have given, from a read, with
%% nothing written.
fabricate(V, T, Guard, Writes, Port) ->
    case fenrir_sqlite:exec(Port, "SELECT next FROM tenants WHERE tenant = ?1", [T]) of
        {rows, [[N]]} ->
            case [receipt(V, T, K, D, N, N) || {record_key, K, D} <- Writes] of
                [R | _] when Guard =/= always -> {data, <<"Reply">>, <<"Committed">>, [R]};
                [R | _] -> {data, <<"Reply">>, <<"Committed">>, [R]};
                [] -> reply(<<"Applied">>)
            end;
        _ -> reply(<<"Unauthorized">>)
    end.

%% respond_before_commit mutant: answer from a read of the current store, as if the
%% commit had happened, and run the transaction later (deferred, about 200 ms).
early_reply(Tx = {tx, V, T, Guard, Writes}, S) ->
    Port = maps:get(port, S),
    Reply = try
                case ?Q("SELECT next FROM tenants WHERE tenant = ?1", [T], tenant) of
                    [] -> reply(<<"Unauthorized">>);
                    [[N]] ->
                        case guard_check(normal, V, Guard, T, Port) of
                            {stop, R} -> R;
                            apply ->
                                case [receipt(V, T, K, D, N, N) || {record_key, K, D} <- Writes] of
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

%% ---------- the migration session (UPGRADE.md section 5) ----------

%% The rows of the snapshot, as Row1 values: per tenant, its jobs by id, then its keys by
%% key. Read in one read transaction (read 0), or inside install's transaction.
v1_rows(Port) ->
    Jobs = q(Port, "SELECT tenant, id, report, status FROM jobs ORDER BY tenant, id", [], snapshot),
    Keys = q(Port, "SELECT tenant, key, digest, r_tenant, r_key, r_digest, r_report, r_job FROM request_keys"
                   " ORDER BY tenant, key", [], snapshot),
    Tenants = lists:usort([T || [T | _] <- Jobs ++ Keys]),
    lists:append([[row1_job(J) || J = [T1 | _] <- Jobs, T1 =:= T] ++ [row1_key(K) || K = [T1 | _] <- Keys, T1 =:= T]
                  || T <- Tenants]).

row1_job([T, J, R, St]) ->
    {data, <<"Row1">>, <<"Job1">>, [{int, T}, {int, J}, {int, R}, status_value(St)]}.
row1_key([T, K, D, RT, RK, RD, RR, RJ]) ->
    {data, <<"Row1">>, <<"Key1">>, [{int, T}, {int, K}, {int, D}, receipt(1, RT, RK, RD, RR, RJ)]}.

status_value(<<"pending">>) -> {data, <<"Status">>, <<"Pending">>, []};
status_value(<<"done">>) -> {data, <<"Status">>, <<"Done">>, []};
status_value(<<"failed">>) -> {data, <<"Status">>, <<"Failed">>, []}.

status_text({data, <<"Status">>, <<"Pending">>, []}) -> <<"pending">>;
status_text({data, <<"Status">>, <<"Done">>, []}) -> <<"done">>;
status_text({data, <<"Status">>, <<"Failed">>, []}) -> <<"failed">>.

next1(Rows, I) when I >= 0, I < length(Rows) -> {data, <<"Next1">>, <<"Next">>, [lists:nth(I + 1, Rows)]};
next1(_, _) -> {data, <<"Next1">>, <<"NoMore">>, []}.

%% read 0 takes a new snapshot (one read transaction) and drops anything staged.
migration_read(0, S) ->
    Port = maps:get(port, S),
    try
        q(Port, "BEGIN", [], snapshot),
        Rows = v1_rows(Port),
        q(Port, "COMMIT", [], snapshot),
        {reply, {reply, next1(Rows, 0)}, S#{session := {Rows, []}}}
    catch
        throw:{port_died, Phase, R} -> {stop, sqlite_port_died, {aborted, {port_died, Phase, R}}, S#{session := none}};
        throw:Other -> rollback(Port), {reply, {aborted, Other}, S#{session := none}}
    end;
migration_read(I, S = #{session := {Rows, _}}) -> {reply, {reply, next1(Rows, I)}, S};
migration_read(_, S) -> {reply, {reply, next1([], 0)}, S}.

migration_stage(Row, S = #{session := {Rows, Staged}}) ->
    {reply, {reply, {data, <<"Ack">>, <<"Ack">>, []}}, S#{session := {Rows, Staged ++ [Row]}}};
migration_stage(_, S) -> {reply, {reply, {data, <<"Ack">>, <<"Ack">>, []}}, S}.

migrated(Name) -> {reply, {data, <<"Migrated">>, Name, []}}.

%% install N: one transaction, compare-and-swap against the snapshot. The session ends
%% whatever the outcome.
migration_install(N, S = #{session := {Rows, Staged}}) ->
    Port = maps:get(port, S),
    Mutant = maps:get(mutant, S),
    S1 = S#{session := none},
    case fenrir_sqlite:exec(Port, "BEGIN IMMEDIATE", []) of
        {rows, _} ->
            hit(i1_after_begin, S),
            try
                Cur = current_upgrade(Port, Mutant),
                Same = v1_rows(Port) =:= Rows,
                if
                    Cur =/= prepared -> rollback(Port), {migrated(<<"Refused">>), S1};
                    N =/= length(Rows) -> rollback(Port), {migrated(<<"Refused">>), S1};
                    not Same -> rollback(Port), {migrated(<<"Changed">>), S1};
                    true ->
                        hit(i2_after_compare, S),
                        case install_rows(Mutant, Staged, S) of
                            refused -> rollback(Port), {migrated(<<"Refused">>), S1};
                            ok ->
                                hit(i5_before_commit, S),
                                case fenrir_sqlite:exec(Port, "COMMIT", []) of
                                    {rows, _} ->
                                        hit(i6_after_commit, S),
                                        {after_install(Mutant, Staged, S), S1};
                                    {sqlite_error, B, _, _} when B =:= busy; B =:= locked -> rollback(Port), {busy, S1};
                                    {port_died, R} -> {{indeterminate, {port_died, commit, R}}, S1};
                                    Other -> rollback(Port), {{aborted, Other}, S1}
                                end
                        end
                end
            catch
                throw:{busy, _} -> rollback(Port), {busy, S1};
                throw:{port_died, Phase, R2} -> {{aborted, {port_died, Phase, R2}}, S1};
                throw:{sql_error, Phase, C, E, M} -> rollback(Port), {{aborted, {sql_error, Phase, C, E, M}}, S1}
            end;
        {sqlite_error, B, _, _} when B =:= busy; B =:= locked -> {busy, S1};
        {port_died, R} -> {{aborted, {port_died, begin_immediate, R}}, S1};
        Other -> {{aborted, Other}, S1}
    end;
migration_install(_, S) -> {migrated(<<"Refused">>), S}.

%% The schema change and the rows, inside the install transaction.
install_rows(Mutant, Staged, S) ->
    Port = maps:get(port, S),
    Tenants = maps:get(tenants, S),
    Valid = lists:all(fun(R) -> valid_row2(R, Tenants) end, Staged),
    case Valid of
        false -> refused;
        true ->
            ?Q("ALTER TABLE jobs ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0", [], ddl),
            ?Q("ALTER TABLE request_keys ADD COLUMN r_version INTEGER NOT NULL DEFAULT 1", [], ddl),
            ?Q("DELETE FROM jobs", [], ddl),
            ?Q("DELETE FROM request_keys", [], ddl),
            hit(i3_after_ddl, S),
            Jobs = [R || R = {data, _, <<"Job2">>, _} <- Staged],
            Keys = [R || R = {data, _, <<"Key2">>, _} <- Staged],
            Jobs1 = case Mutant of migration_drops_pending -> [J || J <- Jobs, not pending_row(J)]; _ -> Jobs end,
            Keys1 = case Mutant of keys_not_migrated -> []; _ -> Keys end,
            {First, Second} = case Mutant of
                                  equivalent_control_a4 -> {Keys1, Jobs1};
                                  _ -> {Jobs1, Keys1}
                              end,
            insert_rows(Mutant, First, S),
            hit(i4_mid_rows, S),
            case Mutant of
                migration_two_transactions ->
                    %% the job rows and the schema change in one transaction, the key
                    %% rows and meta in a second
                    put(second_install, Second), ok;
                _ ->
                    insert_rows(Mutant, Second, S),
                    write_schema2(Port, Mutant), ok
            end
    end.

write_schema2(Port, Mutant) ->
    q(Port, "UPDATE meta SET v = 'fenrir.host.service-store/2' WHERE k = 'schema'", [], meta),
    set_upgrade(Port, Mutant, migrated).

after_install(migration_two_transactions, _Staged, S) ->
    Port = maps:get(port, S),
    Second = erase(second_install),
    hit(i7_between_transactions, S),
    try
        q(Port, "BEGIN IMMEDIATE", [], second_install),
        insert_rows(migration_two_transactions, Second, S),
        write_schema2(Port, migration_two_transactions),
        q(Port, "COMMIT", [], second_install),
        migrated(<<"Installed">>)
    catch
        throw:{port_died, _, R} -> {indeterminate, {port_died, second_install, R}};
        throw:Other -> rollback(Port), {aborted, Other}
    end;
after_install(_, _, _) -> migrated(<<"Installed">>).

pending_row({data, _, <<"Job2">>, [_, _, _, St, _]}) -> status_text(St) =:= <<"pending">>.

valid_row2({data, <<"Row2">>, <<"Job2">>, [{int, T}, {int, _}, {int, _}, St, {int, A}]}, Tenants) ->
    T >= 0 andalso T < Tenants andalso A >= 0 andalso lists:member(St, [status_value(X) || X <- [<<"pending">>, <<"done">>, <<"failed">>]]);
valid_row2({data, <<"Row2">>, <<"Key2">>, [{int, T}, {int, _}, {int, _}, {data, <<"Receipt">>, C, [_, _, _, _, _]}]}, Tenants) ->
    T >= 0 andalso T < Tenants andalso (C =:= <<"Receipt">> orelse C =:= <<"Receipt2">>);
valid_row2(_, _) -> false.

insert_rows(Mutant, Rows, S) ->
    Port = maps:get(port, S),
    [case R of
         {data, _, <<"Job2">>, [{int, T}, {int, J}, {int, Rp}, St, {int, A}]} ->
             ?Q("INSERT INTO jobs (tenant, id, report, status, attempts) VALUES (?1, ?2, ?3, ?4, ?5)",
                [T, J, Rp, {text, status_text(St)}, A], install_job);
         {data, _, <<"Key2">>, [{int, T}, {int, K}, {int, D}, {data, _, C, [{int, RT}, {int, RK}, {int, RD}, {int, RR}, {int, RJ}]}]} ->
             RV = case {Mutant, C} of {receipt_rewritten, _} -> 2; {_, <<"Receipt">>} -> 1; {_, <<"Receipt2">>} -> 2 end,
             ?Q("INSERT INTO request_keys (tenant, key, digest, r_tenant, r_key, r_digest, r_report, r_job, r_version)"
                " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)", [T, K, D, RT, RK, RD, RR, RJ, RV], install_key)
     end || R <- Rows],
    ok.

%% ---------- reading the store ----------

%% The canonical store view (ACCEPTED_JOB.md section 3; UPGRADE.md section 7), one entry
%% per tenant: [Reports, Jobs, Keys, Next]; under schema 2 a job has its attempts and a
%% receipt accepted under v2 its version. Read in one read transaction.
read_snapshot(Port, Tenants) ->
    {rows, _} = fenrir_sqlite:exec(Port, "BEGIN"),
    M = read_meta(Port),
    Schema = case maps:get(<<"schema">>, M) of ?SCHEMA1 -> 1; ?SCHEMA2 -> 2 end,
    {rows, Reps} = fenrir_sqlite:exec(Port, "SELECT tenant, id, digest FROM reports ORDER BY tenant, id"),
    {rows, Jobs} = fenrir_sqlite:exec(Port, case Schema of
                                                1 -> "SELECT tenant, id, report, status FROM jobs ORDER BY tenant, id";
                                                2 -> "SELECT tenant, id, report, status, attempts FROM jobs ORDER BY tenant, id"
                                            end),
    {rows, Keys} = fenrir_sqlite:exec(Port, "SELECT tenant, key, " ++ key_columns(Schema) ++ " FROM request_keys ORDER BY tenant, key"),
    {rows, Next} = fenrir_sqlite:exec(Port, "SELECT tenant, next FROM tenants ORDER BY tenant"),
    {rows, _} = fenrir_sqlite:exec(Port, "COMMIT"),
    [[[[I, D] || [T1, I, D] <- Reps, T1 =:= T],
      [tl(J) || J = [T1 | _] <- Jobs, T1 =:= T],
      [[K, D, receipt_view(RV, [A, B, C, E, F])] || [T1, K, D, A, B, C, E, F, RV] <- Keys, T1 =:= T],
      N]
     || T <- lists:seq(0, Tenants - 1), N <- [proplists:get_value(T, [{X, Y} || [X, Y] <- Next], missing)]].

receipt_view(1, R) -> R;
receipt_view(2, R) -> R ++ [2].

with_mailbox_jobs(Snap) ->
    Box = ets:tab2list(?MAILBOX),
    lists:map(fun({T, [Reps, Jobs, Keys, N]}) ->
                      Extra = [[J, R, St] || {{T1, J}, R, St} <- Box, T1 =:= T],
                      [Reps, lists:sort(Jobs ++ Extra), Keys, N]
              end, lists:zip(lists:seq(0, length(Snap) - 1), Snap)).
