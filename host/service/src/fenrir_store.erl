%% A3: the SQLite storage adapter. It discharges the handler's one durable operation,
%% Store.commit : Tx --> Reply, under the storage contract of spec/service/HANDLER.md
%% section 3 (executable statement: models/service-a2/store-contract.shen). Host
%% infrastructure with a stated contract (host/service/CONTRACT.md), not covered by
%% Fenrir's proofs.
%%
%% One commit is ONE SQLite transaction: BEGIN IMMEDIATE (the write lock is taken first,
%% so the transaction never upgrades a read lock mid-flight), the guard read, the writes,
%% COMMIT. WAL journal with synchronous=FULL: the WAL is fsynced before COMMIT returns
%% (CONTRACT.md A-DUR). Outcomes of commit/1:
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
-export([start_link/1, commit/1, snapshot/0, pending_jobs/0, port_os_pid/0, arm_port/2, info/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([parse_tx/1, schema/0, read_snapshot/2, open_configured/2]).

-define(MAILBOX, fenrir_mailbox).

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
            {ok, #{port => Port, tenants => Tenants, mutant => Mutant, deferred => [],
                   busy_timeout => maps:get(busy_timeout, Opts, 50)}};
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
    [{rows, _} = fenrir_sqlite:exec(Port, "INSERT OR IGNORE INTO tenants VALUES (?1, 0)", [T]) || T <- lists:seq(0, Tenants - 1)],
    {rows, _} = fenrir_sqlite:exec(Port, "COMMIT"),
    ok.

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
handle_call(info, _From, S) -> {reply, maps:with([tenants, mutant], S), S}.

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

%% ---------- the transaction ----------

parse_tx({data, <<"Tx">>, <<"Tx">>, [Cap, Guard, Writes]}) ->
    try {ok, {tx, cap(Cap), guard(Guard), writes(Writes)}}
    catch _:_ -> error
    end;
parse_tx(_) -> error.

cap({data, <<"Cap">>, <<"Tenant">>, [{int, T}]}) -> T.
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
            try body(T, Guard, Writes, S, Transactional) of
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
    {rows, Reps} = fenrir_sqlite:exec(Port, "SELECT tenant, id, digest FROM reports ORDER BY tenant, id"),
    {rows, Jobs} = fenrir_sqlite:exec(Port, "SELECT tenant, id, report, status FROM jobs ORDER BY tenant, id"),
    {rows, Keys} = fenrir_sqlite:exec(Port, "SELECT tenant, key, digest, r_tenant, r_key, r_digest, r_report, r_job"
                                             " FROM request_keys ORDER BY tenant, key"),
    {rows, Next} = fenrir_sqlite:exec(Port, "SELECT tenant, next FROM tenants ORDER BY tenant"),
    {rows, _} = fenrir_sqlite:exec(Port, "COMMIT"),
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
