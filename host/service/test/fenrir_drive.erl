%% A3 campaigns: the driver side. It plays the clients and the recorder, runs the
%% service node as a separate OS process (host/service/priv/node-launch), kills it, and
%% restarts it from the SQLite file. It is NOT part of the system under test: it runs in
%% its own BEAM, which no fault touches, so its record of what clients were told is
%% complete.
%%
%% The recorder writes histories in the format of spec/service/HISTORY_FORMAT.md
%% (fenrir.service.history/1): every externally visible event of a run, including
%% responses that never arrived (an indeterminate outcome), crashes, store observations
%% through the service's API, and deliveries.
-module(fenrir_drive).
-export([new/2, start/1, stop/1, kill/1, call/2, call/3, cmd/2, backoff/1,
         submit/4, submit_told/4, complete/4, respond/2, crash/2, observe/1, drain/2, fault/3,
         event/2, events/1, told/1, write_history/3, audit/2, retry_submit/5, concurrent/2,
         fresh_db/1, upgrade/3, async/2, await/2, upgrade_view/2]).
%% A4: a scenario with schema => 2 in its context writes fenrir.service.history/2
%% (HISTORY_FORMAT.md section 4): observations carry the upgrade state, operator
%% upgrade steps are recorded, and v2 receipts have six fields.

%% Ctx: #{erl, ebin, node_launch, out, config => NodeConfigMap, name}
new(Ctx, Name) ->
    Dir = filename:join(maps:get(out, Ctx), "runs/" ++ Name),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Db = filename:join(Dir, "store.db"),
    fresh_db(Db),
    Config = (maps:get(config, Ctx))#{db => Db, console_dir => Dir},
    #{ctx => Ctx, name => Name, dir => Dir, db => Db, config => Config, node => none,
      events => [], told => [], boots => 0, crashes => 0, coverage => [], latencies => [],
      schema => maps:get(schema, Ctx, 1), v2_sha => maps:get(v2_sha, Ctx, none)}.

fresh_db(Db) -> [file:delete(Db ++ S) || S <- ["", "-wal", "-shm", "-journal"]], ok.

%% ---------- the node ----------

start(S = #{node := none, config := Config, dir := Dir, ctx := Ctx}) ->
    Boot = maps:get(boots, S) + 1,
    ConfigFile = filename:join(Dir, "node-config.term"),
    ok = file:write_file(ConfigFile, io_lib:format("~p.~n", [Config])),
    Log = filename:join(Dir, "node.log"),
    Args = [Log, maps:get(erl, Ctx), "-noshell", "-noinput", "-pa", maps:get(ebin, Ctx),
            "-run", "fenrir_node", "main", ConfigFile],
    T0 = erlang:monotonic_time(microsecond),
    Port = open_port({spawn_executable, maps:get(node_launch, Ctx)},
                     [{args, Args}, {packet, 4}, binary, exit_status,
                      {env, [{"FENRIR_SQLITE_PORT", maps:get(sqlite_port, Ctx)}]}]),
    receive
        {Port, {data, B}} ->
            case binary_to_term(B) of
                {started, Info} ->
                    S#{node := #{port => Port, info => Info, pid => maps:get(beam_os_pid, Info)},
                       boots := Boot, node_start_us => erlang:monotonic_time(microsecond) - T0};
                {start_failed, Why} -> wait_exit(Port), {start_failed, Why}
            end;
        {Port, {exit_status, St}} -> {start_failed, {exit, St}}
    after 60000 -> {start_failed, timeout}
    end.

wait_exit(Port) -> receive {Port, {exit_status, _}} -> ok after 10000 -> catch port_close(Port), ok end.

stop(S = #{node := none}) -> S;
stop(S = #{node := #{port := Port}}) ->
    catch port_command(Port, term_to_binary(stop)),
    wait_exit(Port),
    S#{node := none}.

%% kill -9 of the node's BEAM from outside.
kill(S = #{node := none}) -> S;
kill(S = #{node := #{port := Port, pid := Pid}}) ->
    %% Only a node whose port is still open (its process id cannot have been reused).
    erlang:port_info(Port) =/= undefined andalso os:cmd("kill -9 " ++ integer_to_list(Pid)),
    wait_exit(Port),
    S#{node := none}.

%% {ok, Answer, S} | {died, Status, S} (the node is gone; S has node none)
call(S, Cmd) -> call(S, Cmd, fun(_, Acc) -> Acc end).
call(S = #{node := #{port := Port}}, Cmd, OnNote) ->
    try port_command(Port, term_to_binary(Cmd)) of
        true -> collect(S, Port, OnNote, S)
    catch error:badarg -> {died, port_closed, S#{node := none}}
    end;
call(S = #{node := none}, _Cmd, _OnNote) -> {died, no_node, S}.

collect(S, Port, OnNote, Acc) ->
    receive
        {Port, {data, B}} ->
            case binary_to_term(B) of
                {note, N} -> collect(S, Port, OnNote, OnNote(N, Acc));
                A -> {ok, A, Acc}
            end;
        {Port, {exit_status, St}} -> {died, St, Acc#{node := none}}
    after 120000 -> {died, driver_timeout, kill(Acc)}
    end.

%% ---------- the recorder ----------

event(S = #{events := Es}, E) -> S#{events := [E | Es]}.
events(#{events := Es}) -> lists:reverse(Es).
told(#{told := T}) -> T.

out_json({accepted, R}) -> [<<"accepted">>, R];
out_json({conflict, T, K}) -> [<<"conflict">>, T, K];
out_json(delivered) -> [<<"delivered">>];
out_json(busy) -> [<<"busy">>];
out_json(aborted) -> [<<"aborted">>];
out_json(indeterminate) -> [<<"indeterminate">>];
out_json(unavailable) -> [<<"unavailable">>];
out_json({refused, _}) -> [<<"refused">>];
out_json({response, _}) -> [<<"other">>];
out_json(_) -> [<<"other">>].

%% After the node died during a command: record the crash, audit the file as the crash
%% left it, restart from the SQLite file.
crashed(S0, What) ->
    S1 = event(S0#{crashes := maps:get(crashes, S0) + 1}, [<<"crash">>, What]),
    Audit = audit(maps:get(db, S1), told(S1)),
    S2 = S1#{audits => [{after_crash, Audit} | maps:get(audits, S1, [])]},
    case start(S2) of
        {start_failed, Why} -> error({restart_failed, Why});
        S3 -> observe(S3)
    end.

%% A submit. Returns {Outcome, S}. A node death during it is an indeterminate outcome
%% followed by a crash.
submit(S, T, K, D) ->
    case call(S, {submit, T, K, D, <<D>>}) of
        {ok, {Out, Stats}, S1} ->
            S2 = note_stats(S1, {submit, T, K, D}, Stats),
            {Out, event(S2, [<<"submit">>, T, K, D, out_json(Out)])};
        {died, _, S1} ->
            S2 = event(S1, [<<"submit">>, T, K, D, [<<"indeterminate">>]]),
            {indeterminate, crashed(S2, <<"node">>)}
    end.

note_stats(S, Req, Stats) ->
    Cov = case maps:get(replies, Stats, none) of
              none -> maps:get(coverage, S);
              Rs -> [{Req, Rs} | maps:get(coverage, S)]
          end,
    Lat = case maps:get(us, Stats, none) of none -> maps:get(latencies, S); Us -> [Us | maps:get(latencies, S)] end,
    Whys = case maps:get(why, Stats, none) of none -> maps:get(whys, S, []); W -> [W | maps:get(whys, S, [])] end,
    S#{coverage := Cov, latencies := Lat, whys => Whys}.

respond(S, E) ->
    EJ = out_json(E),
    case call(S, {respond, E}) of
        {ok, ok, S1} -> {ok, event(S1#{told := [E | maps:get(told, S1)]}, [<<"respond">>, EJ])};
        {ok, not_in_outbox, S1} -> {not_in_outbox, event(S1, [<<"respond-refused">>, EJ])};
        {died, _, S1} -> {died, crashed(S1, <<"node">>)}
    end.

%% Submit, and tell the client when there is a response.
submit_told(S, T, K, D) ->
    case submit(S, T, K, D) of
        {{accepted, _} = E, S1} -> {E, element(2, respond(S1, E))};
        {{conflict, _, _} = E, S1} -> {E, element(2, respond(S1, E))};
        Other -> Other
    end.

%% A client's backoff before its next attempt (a restarted worker may not be up yet).
backoff(N) -> timer:sleep(40 * (6 - min(N, 5))).

%% Retry a submit until it has a definite outcome (at most N attempts); A4: unavailable
%% (refused, nothing applied) is retried too.
retry_submit(S, _T, _K, _D, 0) -> {gave_up, S};
retry_submit(S, T, K, D, N) ->
    case submit_told(S, T, K, D) of
        {Out, S1} when Out =:= busy; Out =:= aborted; Out =:= indeterminate; Out =:= unavailable ->
            backoff(N), retry_submit(S1, T, K, D, N - 1);
        Other -> Other
    end.

complete(S, T, J, Ok) ->
    case call(S, {complete, T, J, Ok}) of
        {ok, {Out, Stats}, S1} ->
            S2 = note_stats(S1, {complete, T, J, Ok}, Stats),
            {Out, event(S2, [<<"complete">>, T, J, Ok, out_json(Out)])};
        {died, _, S1} ->
            S2 = event(S1, [<<"complete">>, T, J, Ok, [<<"indeterminate">>]]),
            {indeterminate, crashed(S2, <<"node">>)}
    end.

crash(S, _How) -> crashed(kill(S), <<"node">>).

%% An informational fault event (no A1 step): a tender, worker or port program died and
%% the node survived.
fault(S, What, Point) -> event(S, [<<"fault">>, What, Point]).

observe(S) -> observe(S, 100).
observe(S = #{schema := 2}, N) ->
    case call(S, snapshot) of
        {ok, Stores, S1} when is_list(Stores) ->
            case call(S1, upgrade_state) of
                {ok, #{upgrade := _} = U, S2} -> event(S2, [<<"observe">>, Stores, upgrade_view(S2, U)]);
                {ok, _, S2} when N > 0 -> timer:sleep(20), observe(S2, N - 1);
                {ok, Other, S2} -> error({no_upgrade_state, Other, maps:get(name, S2)});
                {died, _, S2} -> crashed(S2, <<"node">>)
            end;
        {ok, _NotYet, S1} when N > 0 -> timer:sleep(20), observe(S1, N - 1);
        {ok, Other, S1} -> error({no_snapshot, Other, maps:get(name, S1)});
        {died, _, S1} -> crashed(S1, <<"node">>)
    end;
observe(S, N) ->
    case call(S, snapshot) of
        {ok, Stores, S1} when is_list(Stores) -> event(S1, [<<"observe">>, Stores]);
        {ok, _NotYet, S1} when N > 0 -> timer:sleep(20), observe(S1, N - 1); %% the store is restarting
        {ok, Other, S1} -> error({no_snapshot, Other, maps:get(name, S1)});
        {died, _, S1} -> crashed(S1, <<"node">>)
    end.

%% A control command (arm, disarm, fired, pids): {Answer | died, S}; a node found dead
%% is recorded as a crash and restarted.
cmd(S, Cmd) ->
    case call(S, Cmd) of
        {ok, A, S1} -> {A, S1};
        {died, _, S1} -> {died, crashed(S1, <<"node">>)}
    end.

%% Run the job runner until a pass finds no pending job (at most Passes passes); record
%% every delivery and, at the end, that the runner found nothing pending.
drain(S, Opts) -> drain(S, Opts, maps:get(passes, Opts, 8)).
drain(S, _Opts, 0) -> event(S, [<<"gap">>, <<"runner did not drain">>]);
drain(S, Opts, N) ->
    OnNote = fun({deliver, T, J, Ok}, Acc) -> Acc#{inflight => {T, J, Ok}};
                ({delivered, T, J, Ok, Out}, Acc) ->
                     maps:remove(inflight, event(Acc, [<<"complete">>, T, J, Ok, out_json(Out)]))
             end,
    case call(S, {run_jobs, maps:with([duplicate], Opts)}, OnNote) of
        {ok, {jobs_done, 0}, S1} -> event(S1, [<<"drained">>]);
        {ok, {jobs_done, _}, S1} -> backoff(N), drain(S1, Opts, N - 1);
        {died, _, S1} ->
            S2 = case maps:get(inflight, S1, none) of
                     none -> S1;
                     {T, J, Ok} -> event(maps:remove(inflight, S1), [<<"complete">>, T, J, Ok, [<<"indeterminate">>]])
                 end,
            drain(crashed(S2, <<"node">>), Opts, N - 1)
    end.

%% Requests at once over the node's workers; recorded as one concurrent group whose
%% members the checker may order either way.
concurrent(S, Reqs) ->
    case call(S, {concurrent, Reqs}) of
        {ok, {concurrent_done, Results, Us}, S1} ->
            Evs = [case {Req, Out} of
                       {{submit, T, K, D, _}, _} -> [<<"submit">>, T, K, D, out_json(Out)];
                       {{complete, T, J, Ok}, _} -> [<<"complete">>, T, J, Ok, out_json(Out)]
                   end || {Req, {{Out, _St}, _}} <- lists:zip(Reqs, Results)],
            {[O || {{O, _}, _} <- Results], Us, event(S1, [<<"concurrent">>, Evs])};
        {died, _, S1} -> {died, 0, crashed(event(S1, [<<"gap">>, <<"node died in a concurrent group">>]), <<"node">>)}
    end.

%% ---------- A4: the upgrade, and requests held across it ----------

%% The upgrade state as the A4 model names it (UPGRADE.md section 7): the image is good
%% when it is the v2 image the campaign built, bad otherwise.
upgrade_view(S, #{upgrade := v1}) -> _ = S, [<<"v1">>];
upgrade_view(S, #{upgrade := U, image := Sha}) ->
    [atom_to_binary(U), case Sha =:= maps:get(v2_sha, S) of true -> <<"good">>; false -> <<"bad">> end].

up_json(ok) -> [<<"ok">>];
up_json(changed) -> [<<"changed">>];
up_json({refused, _}) -> [<<"refused">>];
up_json(busy) -> [<<"busy">>];
up_json(aborted) -> [<<"aborted">>];
up_json(_) -> [<<"indeterminate">>].

%% An operator's upgrade step: Step begin_upgrade (Args [V2Image, MigImage, good | bad]) | abort
%% | migrate | cut_over. Recorded as ["upgrade", Name, (Img,) OUT]; a node death during it
%% is an indeterminate outcome followed by a crash. {Outcome, S}.
upgrade(S, Step, Args) ->
    {Cmd, Name, Extra} = case {Step, Args} of
                             {begin_upgrade, [V2, Mig, Img]} -> {{begin_upgrade, V2, Mig}, <<"begin">>, [atom_to_binary(Img)]};
                             {abort, []} -> {abort_upgrade, <<"abort">>, []};
                             {migrate, []} -> {migrate, <<"migrate">>, []};
                             {cut_over, []} -> {cut_over, <<"cut-over">>, []}
                         end,
    case call(S, Cmd) of
        {ok, Out, S1} -> {Out, event(S1, [<<"upgrade">>, Name] ++ Extra ++ [up_json(Out)])};
        {died, _, S1} ->
            S2 = event(S1, [<<"upgrade">>, Name] ++ Extra ++ [[<<"indeterminate">>]]),
            {indeterminate, crashed(S2, <<"node">>)}
    end.

%% Start a request (or the migration) now, on the supervised workers (or, with
%% {detached, Req}, on a worker the supervisor does not know: a stale v1 worker), and
%% record it when it is awaited: {Ticket, S}.
async(S, Req) ->
    case call(S, {async, Req}) of
        {ok, {ticket, T}, S1} -> {{T, Req}, S1};
        {ok, Other, _} -> error({async_refused, Other});
        {died, _, S1} -> {none, crashed(S1, <<"node">>)}
    end.

await(S, none) -> {indeterminate, S};
await(S, {T, Req}) ->
    {Out, S1} = case call(S, {await, T}) of
                    {ok, {done, R}, SX} -> {R, SX};
                    {ok, Other, SX} -> {{error, Other}, SX};
                    {died, _, SX} -> {died, SX}
                end,
    Base = case Req of {detached, Q} -> Q; Q -> Q end,
    case {Base, Out} of
        {_, died} ->
            S2 = record_async(S1, Base, indeterminate),
            {indeterminate, crashed(S2, <<"node">>)};
        {migrate, _} -> {Out, event(S1, [<<"upgrade">>, <<"migrate">>, up_json(Out)])};
        {_, {O, Stats}} -> {O, record_async(note_stats(S1, request_of(Base), Stats), Base, O)};
        {_, _} -> {indeterminate, record_async(S1, Base, indeterminate)}
    end.

request_of({submit, T, K, D, _}) -> {submit, T, K, D};
request_of({complete, T, J, Ok}) -> {complete, T, J, Ok}.

record_async(S, {submit, T, K, D, _}, O) -> event(S, [<<"submit">>, T, K, D, out_json(O)]);
record_async(S, {complete, T, J, Ok}, O) -> event(S, [<<"complete">>, T, J, Ok, out_json(O)]);
record_async(S, migrate, O) -> event(S, [<<"upgrade">>, <<"migrate">>, up_json(O)]).

write_history(S, Tenants, Extra) ->
    H = maps:merge(#{<<"schema">> => case maps:get(schema, S, 1) of
                                         2 -> <<"fenrir.service.history/2">>;
                                         _ -> <<"fenrir.service.history/1">>
                                     end,
                     <<"tenants">> => Tenants,
                     <<"scenario">> => list_to_binary(maps:get(name, S)), <<"events">> => events(S)}, Extra),
    File = filename:join(maps:get(dir, S), "history.json"),
    ok = file:write_file(File, json:encode(H)),
    File.

%% ---------- the direct audit of the SQLite file ----------

%% Independent of the adapter's code: reads the file with its own connection and checks
%% the A1 store invariants on the raw rows, and that every acceptance a client was told
%% is in the file. Returns a list of violations ([] when clean).
audit(Db, Told) ->
    {ok, P} = fenrir_sqlite:open(Db),
    try
        Q = fun(Sql) -> {rows, R} = fenrir_sqlite:exec(P, Sql), R end,
        %% A killed node's port program may still be closing the file: wait for it.
        _ = Q("PRAGMA busy_timeout=10000"),
        Integrity = Q("PRAGMA integrity_check"),
        Journal = Q("PRAGMA journal_mode"),
        _ = Q("BEGIN"),
        Tenants = Q("SELECT tenant, next FROM tenants ORDER BY tenant"),
        Reports = Q("SELECT tenant, id, digest FROM reports"),
        Jobs = Q("SELECT tenant, id, report, status FROM jobs"),
        Keys = Q("SELECT tenant, key, digest, r_tenant, r_key, r_digest, r_report, r_job FROM request_keys"),
        %% A4 (UPGRADE.md sections 2.1, 3, 6 version.readable): the schema and upgrade state
        %% agree with the columns, and under schema 2 a job's attempts are 0 exactly while
        %% it is pending and 1 once finished.
        Meta = maps:from_list([{K, V0} || [K, V0] <- Q("SELECT k, v FROM meta")]),
        Cols = fun(T) -> [N || [N] <- Q("SELECT name FROM pragma_table_info('" ++ T ++ "')")] end,
        V2Cols = lists:member(<<"attempts">>, Cols("jobs")),
        Schema = maps:get(<<"schema">>, Meta, none),
        Upgrade = maps:get(<<"upgrade">>, Meta, none),
        Attempts = case V2Cols of true -> Q("SELECT tenant, id, status, attempts FROM jobs"); false -> [] end,
        Versions = case lists:member(<<"r_version">>, Cols("request_keys")) of
                       true -> Q("SELECT tenant, key, r_version FROM request_keys");
                       false -> [[T, K, 1] || [T, K | _] <- Keys]
                   end,
        _ = Q("COMMIT"),
        SchemaOk = case {Schema, Upgrade, V2Cols} of
                       {<<"fenrir.host.service-store/1">>, U, false} -> lists:member(U, [<<"v1">>, <<"prepared">>]);
                       {<<"fenrir.host.service-store/2">>, U, true} -> lists:member(U, [<<"migrated">>, <<"v2">>]);
                       _ -> false
                   end,
        V = [{integrity, Integrity} || Integrity =/= [[<<"ok">>]]]
            ++ [{journal_mode, Journal} || Journal =/= [[<<"wal">>]]]
            ++ [{schema_upgrade_columns_disagree, Schema, Upgrade, V2Cols} || not SchemaOk]
            ++ [{attempts_inconsistent, T, J, St, A} || [T, J, St, A] <- Attempts,
                                                        not ((St =:= <<"pending">> andalso A =:= 0) orelse (St =/= <<"pending">> andalso A =:= 1))]
            ++ lists:append([tenant_audit(T, N, Reports, Jobs, Keys) || [T, N] <- Tenants])
            ++ [{told_not_recorded, R} || {accepted, R} <- Told, not recorded(R, Reports, Jobs, Keys, Versions)],
        V
    after
        fenrir_sqlite:close(P)
    end.

tenant_audit(T, Next, Reports, Jobs, Keys) ->
    Rs = [{I, D} || [T1, I, D] <- Reports, T1 =:= T],
    Js = [{I, R, St} || [T1, I, R, St] <- Jobs, T1 =:= T],
    Ks = [{K, D, Rc} || [T1, K, D | Rc] <- Keys, T1 =:= T],
    [{key_receipt_wrong_tenant_or_key, T, K} || {K, D, [RT, RK, RD, _, _]} <- Ks, {RT, RK, RD} =/= {T, K, D}]
    ++ [{key_without_report, T, K} || {K, D, [_, _, _, RR, _]} <- Ks, not lists:member({RR, D}, Rs)]
    ++ [{key_without_job, T, K} || {K, _, [_, _, _, RR, RJ]} <- Ks, not lists:any(fun({J, R, _}) -> {J, R} =:= {RJ, RR} end, Js)]
    ++ [{report_id_not_below_next, T, I} || {I, _} <- Rs, I >= Next]
    ++ [{report_without_job, T, I} || {I, _} <- Rs, not lists:any(fun({J, R, _}) -> {J, R} =:= {I, I} end, Js)]
    ++ [{report_without_key, T, I} || {I, D} <- Rs, not lists:any(fun({_, KD, [_, _, _, RR, _]}) -> {KD, RR} =:= {D, I} end, Ks)]
    ++ [{job_id_not_below_next, T, J} || {J, _, _} <- Js, J >= Next]
    ++ [{job_without_report, T, J} || {J, R, _} <- Js, not lists:keymember(R, 1, Rs)].

%% A told receipt is recorded with its representation: five fields for a v1 receipt
%% (r_version 1), six ending in 2 for a v2 receipt (r_version 2).
recorded([T, K, D, R, J, 2], Reports, Jobs, Keys, Versions) ->
    lists:member([T, K, 2], Versions) andalso recorded([T, K, D, R, J], Reports, Jobs, Keys);
recorded([T, K, D, R, J], Reports, Jobs, Keys, Versions) ->
    lists:member([T, K, 1], Versions) andalso recorded([T, K, D, R, J], Reports, Jobs, Keys).

recorded([T, K, D, R, J], Reports, Jobs, Keys) ->
    lists:member([T, K, D, T, K, D, R, J], Keys)
        andalso lists:member([T, R, D], Reports)
        andalso lists:any(fun([T1, J1, R1, _]) -> {T1, J1, R1} =:= {T, J, R} end, Jobs).
