%% A3 unit tests of the host: framing against the specification's byte vectors, the
%% value codec, the storage contract on a real SQLite file, the connection settings,
%% the capability manifest check and its refusal, and the image identity refusals.
%%
%%   erl -noshell -pa EBIN -run fenrir_unit main CONFIG [host-only]
%% Writes OUT/unit.json: {"tests": [...], "passed": N, "failed": M}.
-module(fenrir_unit).
-export([main/1]).

main([ConfigFile]) -> run(ConfigFile, full);
main([ConfigFile, "host-only"]) -> run(ConfigFile, host_only).

run(ConfigFile, Mode) ->
    {ok, [C]} = file:consult(ConfigFile),
    Out = maps:get(out, C),
    ok = filelib:ensure_dir(filename:join(Out, "unit/x")),
    fenrir_faults:init(),
    Root = maps:get(root, C),
    Common = [vectors(Root), values(), authority(C), store(C), settings(C), artifact_manifest(C),
              fenrir_report_test:tests(Root), [t(N, F) || {N, F} <- fenrir_a4_unit:tests(C)]],
    Extra = case Mode of
                full -> [image_manifest(C), identity(C), guest_authority(C)];
                host_only -> [[t(store_lost_commit_ack, fun() -> lost_commit_ack(C) end)]]
            end,
    Tests = lists:append(Common ++ Extra),
    Failed = [T || T = {_, false, _} <- Tests],
    Json = #{<<"tests">> => [#{<<"name">> => iolist_to_binary(io_lib:format("~p", [N])), <<"pass">> => P,
                               <<"detail">> => iolist_to_binary(io_lib:format("~0P", [D, 12]))} || {N, P, D} <- Tests],
             <<"passed">> => length(Tests) - length(Failed), <<"failed">> => length(Failed)},
    ok = file:write_file(filename:join(Out, "unit.json"), json:encode(Json)),
    [io:format("FAIL ~p: ~0P~n", [N, D, 20]) || {N, false, D} <- Failed],
    io:format("unit: ~p passed, ~p failed~n", [length(Tests) - length(Failed), length(Failed)]),
    halt(case Failed of [] -> 0; _ -> 1 end).

t(Name, Fun) ->
    try Fun() of
        {true, D} -> {Name, true, D};
        true -> {Name, true, ok};
        {false, D} -> {Name, false, D};
        Other -> {Name, false, Other}
    catch C:E:S -> {Name, false, {C, E, lists:sublist(S, 3)}}
    end.

%% ---------- byte vectors of control protocol v1 and v2 ----------

vectors(Root) ->
    Lines = lists:append([vector_lines(filename:join(Root, F)) || F <- ["spec/solo5/pure-call-control-v1.vectors",
                                                                         "spec/solo5/pure-call-control-v2.vectors"]]),
    [t({vector, N}, fun() -> vector(Role, Exp, binary:decode_hex(Hex)) end) || [N, Role, Exp, Hex] <- Lines].

vector_lines(File) ->
    {ok, B} = file:read_file(File),
    [binary:split(L, <<" ">>, [global, trim_all]) || L <- binary:split(B, <<"\n">>, [global, trim_all]),
                                                      binary:first(L) =/= $#].

vector(<<"host">>, _, Bytes) ->
    <<"FGC1 H", Type, " ", Seq:8/binary, " ", _:8/binary, "\n", Rest/binary>> = Bytes,
    Payload = binary:part(Rest, 0, byte_size(Rest) - 1),
    {ok, J} = fenrir_proto:decode_json(Payload),
    Mine = case Type of
               $I -> fenrir_proto:init_payload(maps:get(<<"artifact_sha256">>, J), maps:get(<<"batch_sha256">>, J),
                                               maps:get(<<"fuel">>, J), maps:get(<<"mode">>, J),
                                               binary_to_integer(maps:get(<<"program">>, J)), maps:get(<<"protocol">>, J),
                                               maps:get(<<"schema">>, J));
               $R -> fenrir_proto:run_payload(binary_to_integer(maps:get(<<"steps">>, J)));
               $X -> fenrir_proto:terminate_payload();
               $D -> <<"{\"kind\":\"Digest\"}">>;
               $A -> fenrir_proto:reply_payload(binary_to_integer(maps:get(<<"request">>, J)),
                                                fenrir_value:from_json(maps:get(<<"value">>, J)))
           end,
    Frame = fenrir_proto:frame(Type, binary_to_integer(Seq), Mine),
    {Frame =:= Bytes, Frame};
vector(<<"guest">>, _, Bytes) ->
    <<"FGC1 G", _, " ", Seq:8/binary, _/binary>> = Bytes,
    case fenrir_proto:parse(Bytes, binary_to_integer(Seq)) of
        {frame, _, _, <<>>} -> true;
        Other -> {false, Other}
    end;
vector(<<"reject">>, Expected, Bytes) ->
    Code = case fenrir_proto:parse(Bytes, 3) of
               {error, C} -> atom_to_binary(C);
               more -> <<"Truncated">>;
               Other -> Other
           end,
    {Code =:= Expected, Code}.

%% ---------- value codec ----------

values() ->
    Good = [<<"[\"unit\"]">>, <<"[\"bool\",true]">>, <<"[\"int\",\"-9223372036854775808\"]">>, <<"[\"int\",\"0\"]">>,
            <<"[\"bytes\",\"00ff\"]">>, <<"[\"tuple\",[\"unit\"],[\"int\",\"7\"]]">>,
            <<"[\"data\",\"Reply\",\"Committed\",[\"data\",\"Receipt\",\"Receipt\",[\"int\",\"0\"],[\"int\",\"1\"],[\"int\",\"1\"],[\"int\",\"0\"],[\"int\",\"0\"]]]">>],
    Bad = [<<"[\"int\",\"01\"]">>, <<"[\"int\",\"9223372036854775808\"]">>, <<"[\"bytes\",\"0F\"]">>, <<"[\"bytes\",\"0\"]">>,
           <<"[\"int\",7]">>, <<"[\"data\",\"Re ply\",\"X\"]">>, <<"[\"float\",\"1\"]">>, <<"[\"int\",\"-0\"]">>],
    [t({value_roundtrip, V}, fun() -> {fenrir_value:encode(fenrir_value:decode(V)) =:= V, V} end) || V <- Good]
    ++ [t({value_refused, V}, fun() -> try fenrir_value:decode(V) of X -> {false, X} catch _:_ -> true end end) || V <- Bad].

%% ---------- the storage contract (HANDLER.md section 3) on a real file ----------

i(N) -> {int, N}.
d(T, C, F) -> {data, T, C, F}.
tx(T, G, Ws) -> d(<<"Tx">>, <<"Tx">>, [d(<<"Cap">>, <<"Tenant">>, [i(T)]), G,
                                        lists:foldr(fun(W, A) -> d(<<"Writes">>, <<"Then">>, [W, A]) end, d(<<"Writes">>, <<"Done">>, []), Ws)]).
once(K) -> d(<<"Guard">>, <<"Once">>, [i(K)]).
pending(J) -> d(<<"Guard">>, <<"Pending">>, [i(J)]).
always() -> d(<<"Guard">>, <<"Always">>, []).
w(C, F) -> d(<<"Write">>, C, F).
sub(T, K, D) -> tx(T, once(K), [w(<<"StageJob">>, []), w(<<"PutReport">>, [i(D), {bytes, <<D>>}]), w(<<"RecordKey">>, [i(K), i(D)])]).
receipt(T, K, D, R, J) -> d(<<"Receipt">>, <<"Receipt">>, [i(T), i(K), i(D), i(R), i(J)]).
committed(Rc) -> {reply, d(<<"Reply">>, <<"Committed">>, [Rc])}.
reply(N) -> {reply, d(<<"Reply">>, N, [])}.

%% These adapter contract fixtures run on the trusted host. Their expected
%% tenant is assigned independently by each test, never inferred by the store.
commit(T, Tx) -> fenrir_store:commit({tenant, T}, Tx).

with_store(C, Name, Mutant, Fun) ->
    Db = filename:join([maps:get(out, C), "unit", Name ++ ".db"]),
    fenrir_drive:fresh_db(Db),
    case ets:info(fenrir_mailbox) of undefined -> ets:new(fenrir_mailbox, [named_table, public]); _ -> ok end,
    {ok, Pid} = fenrir_store:start_link(#{db => Db, tenants => 2, mutant => Mutant}),
    %% Wait for this exact fixture to finish terminating, including SQLite port
    %% close. Never kill a process found by name or treat a failed stop as success.
    try Fun(Db) after ok = gen_server:stop(Pid, normal, 10000) end.

store_fixture_teardown(C) ->
    Name = "fixture-teardown",
    %% Test the exception path too. Capture the fixture's exact server and port
    %% from inside the callback and check both immediately, without a sleep.
    {Pid, Port} =
        try with_store(C, Name, normal, fun(_) ->
            Store = whereis(fenrir_store),
            #{port := OpenPort} = sys:get_state(Store),
            true = is_port(OpenPort),
            throw({fixture_exception, Store, OpenPort})
        end)
        catch throw:{fixture_exception, Store, OpenPort} -> {Store, OpenPort}
        end,
    false = is_process_alive(Pid),
    undefined = whereis(fenrir_store),
    undefined = erlang:port_info(Port),
    with_store(C, Name, normal, fun(_) ->
        true = whereis(fenrir_store) =/= Pid,
        [[[], [], [], 0], [[], [], [], 0]] = fenrir_store:snapshot(),
        true
    end).

%% No guest here: exercise real front dispatch with a worker mailbox probe.
authority(C) ->
    [t(invalid_authority_config_refuses_start, fun() ->
         Hash = crypto:hash(sha256, <<"test">>),
         {error, invalid_submit_credentials} = fenrir_service_sup:start_link(#{tenants => 2, submit_credentials => #{Hash => 2}}),
         {error, invalid_submit_credentials} = fenrir_authority:validate(#{tenants => 2, submit_credentials => #{<<"short">> => 0}}),
         {ok, Empty} = fenrir_authority:validate(#{tenants => 2}),
         denied = fenrir_authority:authenticate(crypto:strong_rand_bytes(32), Empty),
         true
     end),
     t(credential_scopes_front_dispatch, fun() ->
         {Tokens, Bindings} = fenrir_authority:campaign_credentials(2),
         Parent = self(),
         Worker = spawn(fun() ->
             authority_worker_probe(Parent, fun({submit, K, D, _}) ->
                 T = case K of 0 -> 1; 1 -> 0 end,
                 accepted_value(T, K, D)
             end)
         end),
         true = register(authority_probe, Worker),
         {ok, Front} = fenrir_front:start_link([authority_probe], Bindings),
         try
             T1 = maps:get(1, Tokens),
             Denied = {{refused, unauthorized}, #{}},
             Denied = fenrir_front:submit(1, 0, 0, <<0>>), %% raw tenant is not a credential
             Denied = fenrir_front:submit(crypto:hash(sha256, T1), 0, 0, <<0>>), %% verifier is not the token
             Denied = fenrir_front:submit(crypto:strong_rand_bytes(32), 0, 0, <<0>>),
             receive {Worker, _, _} -> error(unauthorized_dispatch) after 0 -> ok end,
             {{accepted, [1, 0, 0, 0, 0]}, _} = fenrir_front:submit(T1, 0, 0, <<0>>),
             receive {Worker, {tenant, 1}, {submit, 0, 0, <<0>>}} -> ok
             after 1000 -> error(no_scoped_dispatch)
             end,
             %% The probe returns a mismatched receipt for key 1.
             {indeterminate, _} = fenrir_front:submit(T1, 1, 0, <<0>>),
             receive {Worker, {tenant, 1}, {submit, 1, 0, <<0>>}} -> ok
             after 1000 -> error(no_scoped_dispatch)
             end,
             [{accepted, [1, 0, 0, 0, 0]}] = fenrir_front:outbox(),
             true
         after
             gen_server:stop(Front),
             exit(Worker, kill)
         end
     end),
     t(response_must_match_request, fun response_integrity/0),
     t(guest_scope_mismatch_cannot_read_or_write, fun() ->
         with_store(C, "scope", normal, fun(_) ->
             Rc = receipt(1, 0, 1, 0, 0),
             {reply, {data, <<"Reply">>, <<"Committed">>, [Rc]}} = commit(1, sub(1, 0, 1)),
             Before = fenrir_store:snapshot(),
             IoBefore = fenrir_store:io_counters(),
             Denied = {aborted, unauthorized_scope},
             Denied = commit(0, sub(1, 0, 1)), %% no recorded receipt leak
             Denied = commit(0, sub(1, 1, 0)), %% no cross-tenant allocation
             Denied = commit(0, tx(1, pending(0), [w(<<"Finish">>, [i(0), {bool, true}])])),
             Denied = fenrir_store:commit(none, sub(1, 1, 0)),
             Before = fenrir_store:snapshot(),
             IoBefore = fenrir_store:io_counters(),
             committed(receipt(0, 0, 0, 0, 0)) =:= commit(0, sub(0, 0, 0))
         end)
     end)].

response_integrity() ->
    {Tokens, Bindings} = fenrir_authority:campaign_credentials(2),
    Parent = self(),
    Worker = spawn(fun() -> authority_worker_probe(Parent, fun response_fixture/1) end),
    true = register(response_probe, Worker),
    {ok, Front} = fenrir_front:start_link([response_probe], Bindings),
    try
        Token = maps:get(1, Tokens),
        Submit = fun(K, D) -> fenrir_front:submit(Token, K, D, <<D>>) end,
        Deliver = fun(J) -> fenrir_front:deliver(1, J, true) end,
        Bad = [{wrong_submit_kind, fun() -> Submit(0, 0) end},
               {wrong_receipt_key, fun() -> Submit(1, 0) end},
               {wrong_receipt_digest, fun() -> Submit(2, 0) end},
               {wrong_conflict_key, fun() -> Submit(3, 0) end},
               {accepted_for_delivery, fun() -> Deliver(0) end},
               {conflict_for_delivery, fun() -> Deliver(1) end},
               {refused_for_delivery, fun() -> Deliver(2) end}],
        lists:foreach(fun({Test, Call}) ->
            {Test, {indeterminate, _}, []} = {Test, Call(), fenrir_front:outbox()}
        end, Bad),
        {delivered, _} = Deliver(3),
        {{accepted, [1, 4, 1, 0, 0]}, _} = Submit(4, 1),
        {{conflict, 1, 5}, _} = Submit(5, 1),
        [{accepted, [1, 4, 1, 0, 0]}, {conflict, 1, 5}] = fenrir_front:outbox(),
        true
    after
        gen_server:stop(Front),
        exit(Worker, kill),
        flush_worker_probes(Worker)
    end.

flush_worker_probes(Worker) ->
    receive {Worker, _, _} -> flush_worker_probes(Worker) after 0 -> ok end.

response_fixture({submit, 0, _, _}) -> d(<<"Response">>, <<"Delivered">>, []);
response_fixture({submit, 1, D, _}) -> accepted_value(1, 0, D);
response_fixture({submit, 2, D, _}) -> accepted_value(1, 2, D + 1);
response_fixture({submit, 3, _, _}) -> conflict_value(1, 2);
response_fixture({submit, 4, D, _}) -> accepted_value(1, 4, D);
response_fixture({submit, 5, _, _}) -> conflict_value(1, 5);
response_fixture({complete, 0, _}) -> accepted_value(1, 0, 0);
response_fixture({complete, 1, _}) -> conflict_value(1, 1);
response_fixture({complete, 2, _}) -> d(<<"Response">>, <<"Refused">>, []);
response_fixture({complete, 3, _}) -> d(<<"Response">>, <<"Delivered">>, []).

accepted_value(T, K, D) -> d(<<"Response">>, <<"Accepted">>, [receipt(T, K, D, 0, 0)]).
conflict_value(T, K) -> d(<<"Response">>, <<"Conflict">>, [i(T), i(K)]).

authority_worker_probe(Parent, Respond) ->
    receive
        {'$gen_call', From, {run, Scope, Req}} ->
            Parent ! {self(), Scope, Req},
            gen_server:reply(From, {ok, Respond(Req), #{}}),
            authority_worker_probe(Parent, Respond)
    end.

store(C) ->
    Cases =
        [{fresh_key_commits, [{0, sub(0, 1, 1)}], committed(receipt(0, 1, 1, 0, 0))},
         {same_key_same_digest_recorded, [{0, sub(0, 1, 1)}, {0, sub(0, 1, 1)}],
          {reply, d(<<"Reply">>, <<"Recorded">>, [i(1), receipt(0, 1, 1, 0, 0)])}},
         {same_key_other_digest_recorded_with_first_digest, [{0, sub(0, 1, 1)}, {0, sub(0, 1, 0)}],
          {reply, d(<<"Reply">>, <<"Recorded">>, [i(1), receipt(0, 1, 1, 0, 0)])}},
         {second_key_next_id, [{0, sub(0, 1, 1)}, {0, sub(0, 2, 0)}], committed(receipt(0, 2, 0, 1, 1))},
         {tenants_are_separate, [{0, sub(0, 1, 1)}, {1, sub(1, 1, 1)}], committed(receipt(1, 1, 1, 0, 0))},
         {unknown_tenant_unauthorized, [{2, sub(2, 0, 0)}], reply(<<"Unauthorized">>)},
         {negative_tenant_unauthorized, [{-1, sub(-1, 0, 0)}], reply(<<"Unauthorized">>)},
         {pending_job_finished_applied, [{0, sub(0, 0, 0)}, {0, tx(0, pending(0), [w(<<"Finish">>, [i(0), {bool, true}])])}], reply(<<"Applied">>)},
         {finished_job_skipped, [{0, sub(0, 0, 0)}, {0, tx(0, pending(0), [w(<<"Finish">>, [i(0), {bool, true}])])},
                                 {0, tx(0, pending(0), [w(<<"Finish">>, [i(0), {bool, false}])])}], reply(<<"Skipped">>)},
         {unknown_job_skipped, [{0, tx(0, pending(5), [w(<<"Finish">>, [i(5), {bool, true}])])}], reply(<<"Skipped">>)},
         {always_finish_unconditional_applied, [{0, tx(0, always(), [w(<<"Finish">>, [i(9), {bool, true}])])}], reply(<<"Applied">>)},
         {stage_job_of_does_not_allocate, [{0, tx(0, always(), [w(<<"StageJobOf">>, [i(3)])])}, {0, sub(0, 0, 0)}], committed(receipt(0, 0, 0, 0, 0))},
         {malformed_tx_aborted, [{0, d(<<"Tx">>, <<"Tx">>, [])}], {aborted, malformed_tx}}],
    [t(store_fixture_teardown, fun() -> store_fixture_teardown(C) end)]
    ++ [t({store_contract, N}, fun() ->
            with_store(C, atom_to_list(N), normal,
                       fun(_) -> Rs = [commit(T, X) || {T, X} <- Txs], {lists:last(Rs) =:= Want, Rs} end)
        end) || {N, Txs, Want} <- Cases]
    ++ [t({store_contract, snapshot_is_canonical}, fun() ->
            with_store(C, "snapshot", normal, fun(_) ->
                commit(0, sub(0, 1, 1)), commit(0, sub(0, 0, 0)),
                commit(0, tx(0, pending(1), [w(<<"Finish">>, [i(1), {bool, false}])])),
                S = fenrir_store:snapshot(),
                {S =:= [[[[0, 1], [1, 0]], [[0, 0, <<"pending">>], [1, 1, <<"failed">>]], [[0, 0, [0, 0, 0, 1, 1]], [1, 1, [0, 1, 1, 0, 0]]], 2],
                        [[], [], [], 0]], S} end) end),
        t({store_contract, payload_stored}, fun() ->
            with_store(C, "payload", normal, fun(Db) ->
                commit(0, tx(0, once(0), [w(<<"PutReport">>, [i(7), {bytes, <<"hello">>}]), w(<<"RecordKey">>, [i(0), i(7)])])),
                {ok, P} = fenrir_sqlite:open(Db),
                R = fenrir_sqlite:exec(P, "SELECT payload FROM reports"), fenrir_sqlite:close(P),
                {R =:= {rows, [[{blob, <<"hello">>}]]}, R} end) end)].

%% ---------- connection settings: WAL and synchronous=FULL, read back ----------

settings(C) ->
    [t(settings_wal_full, fun() ->
         with_store(C, "settings", normal, fun(Db) ->
             {ok, P} = fenrir_store:open_configured(Db, normal),
             R = [fenrir_sqlite:exec(P, Q) || Q <- ["PRAGMA journal_mode", "PRAGMA synchronous", "PRAGMA foreign_keys", "PRAGMA busy_timeout"]],
             {sqlite_error, constraint, _, _} = fenrir_sqlite:exec(P, "INSERT INTO reports VALUES (9,0,0,X'00')"),
             fenrir_sqlite:close(P),
             {R =:= [{rows, [[<<"wal">>]]}, {rows, [[2]]}, {rows, [[1]]}, {rows, [[50]]}], R} end) end),
     t(settings_refuse_non_wal_database, fun() ->
         {error, {connection_settings, Bad}} = fenrir_store:open_configured(":memory:", normal),
         lists:member({"PRAGMA journal_mode=WAL", {rows, [[<<"memory">>]]}}, Bad)
     end),
     t(settings_wal_commit_requests_sync, fun() ->
         Full = measured_commit_io(C, normal),
         Off = measured_commit_io(C, sync_off),
         {W, Sync} = Full,
         {WOff, SyncOff} = Off,
         {W > 0 andalso Sync > 0 andalso WOff > 0 andalso SyncOff =:= 0, #{full => Full, off => Off}}
     end),
     t(settings_busy_is_distinct_outcome, fun() ->
         with_store(C, "busy", normal, fun(Db) ->
             {ok, P} = fenrir_sqlite:open(Db),
             {rows, _} = fenrir_sqlite:exec(P, "BEGIN IMMEDIATE"),
             R = commit(0, sub(0, 0, 0)),
             fenrir_sqlite:exec(P, "ROLLBACK"), fenrir_sqlite:close(P),
             R2 = commit(0, sub(0, 0, 0)),
             {R =:= busy andalso R2 =:= committed(receipt(0, 0, 0, 0, 0)), {R, R2}} end) end)].

measured_commit_io(C, Mutant) ->
    with_store(C, "commit-io-" ++ atom_to_list(Mutant), Mutant, fun(_) ->
        {W0, S0} = fenrir_store:io_counters(),
        Rc = receipt(0, 0, 0, 0, 0),
        {reply, {data, <<"Reply">>, <<"Committed">>, [Rc]}} = commit(0, sub(0, 0, 0)),
        {W1, S1} = fenrir_store:io_counters(),
        {W1 - W0, S1 - S0}
    end).

%% Exercise the real SQLite port fault, without making a guest or history claim.
lost_commit_ack(C) ->
    Db = filename:join([maps:get(out, C), "unit", "lost-ack.db"]),
    fenrir_drive:fresh_db(Db),
    Start = fun() ->
                {ok, Pid} = fenrir_store:start_link(#{db => Db, tenants => 2, mutant => normal}),
                unlink(Pid),
                {Pid, monitor(process, Pid)}
            end,
    Wait = fun(Pid, Ref) ->
               receive {'DOWN', Ref, process, Pid, Reason} -> Reason
               after 5000 -> error({store_did_not_stop, Pid})
               end
           end,
    Tx = sub(0, 1, 1),
    {First, FirstRef} = Start(),
    try
        ok = fenrir_faults:arm(s3_before_commit, lose_ack, 1),
        {indeterminate, {port_died, commit, {lost_commit_ack, 137}}} = commit(0, Tx),
        sqlite_port_died = Wait(First, FirstRef),
        {Second, SecondRef} = Start(),
        try
            Snapshot = [[[[0, 1]], [[0, 0, <<"pending">>]], [[1, 1, [0, 1, 1, 0, 0]]], 1], [[], [], [], 0]],
            Snapshot = fenrir_store:snapshot(),
            {reply, {data, <<"Reply">>, <<"Recorded">>, [{int, 1}, Receipt]}} = commit(0, Tx),
            Receipt = receipt(0, 1, 1, 0, 0),
            Snapshot = fenrir_store:snapshot(),
            true
        after
            exit(Second, shutdown),
            shutdown = Wait(Second, SecondRef)
        end
    after
        exit(First, shutdown),
        ok = fenrir_faults:disarm()
    end.

%% ---------- capability manifest ----------

artifact_manifest(C) ->
    {ok, B} = file:read_file(maps:get(artifact, C)),
    A = json:decode(B),
    Variants =
        [{extra_durable_effect, add_effect(A)},
         {extra_operation, map_store(A, fun(E) -> E#{<<"operations">> := maps:get(<<"operations">>, E) ++
                                              [#{<<"name">> => <<"erase">>, <<"argument_type">> => <<"I64">>, <<"result_type">> => <<"Unit">>}]} end)},
         {operation_renamed, map_store(A, fun(E) -> E#{<<"operations">> := [(hd(maps:get(<<"operations">>, E)))#{<<"name">> => <<"commit2">>}]} end)},
         {result_type_changed, map_store(A, fun(E) -> E#{<<"operations">> := [(hd(maps:get(<<"operations">>, E)))#{<<"result_type">> => <<"I64">>}]} end)},
         {reply_constructor_added, map_datatype(A, <<"Reply">>, fun(Cs) -> Cs ++ [#{<<"name">> => <<"Busy">>, <<"fields">> => []}] end)},
         {write_field_changed, map_datatype(A, <<"Write">>, fun([P | Cs]) -> [P#{<<"fields">> => [<<"I64">>]} | Cs] end)},
         {class_ordinary_not_residual, map_store(A, fun(E) -> E#{<<"class">> := <<"ordinary">>} end)}],
    Dir = filename:join(maps:get(out, C), "unit"),
    [t(manifest_accepts_handler, fun() -> {fenrir_manifest:check_artifact(maps:get(artifact, C)) =:= ok, ok} end)]
    ++ [t({manifest_refuses, N}, fun() ->
            F = filename:join(Dir, atom_to_list(N) ++ ".json"),
            ok = file:write_file(F, json:encode(V)),
            R = fenrir_manifest:check_artifact(F),
            case N of
                class_ordinary_not_residual -> {R =:= ok, R}; %% not residual: no host contract needed
                _ -> {element(1, R) =:= refused, R}
            end
        end) || {N, V} <- Variants].

image_manifest(C) ->
    [t(supervisor_refuses_worker_on_manifest, fun() ->
        {ok, B} = file:read_file(maps:get(artifact, C)),
        supervisor_refusal(C, add_effect(json:decode(B)))
    end)].

add_effect(A) ->
    Mail = #{<<"name">> => <<"Mail">>, <<"class">> => <<"durable">>,
             <<"operations">> => [#{<<"name">> => <<"send">>, <<"argument_type">> => <<"Bytes">>, <<"result_type">> => <<"Unit">>}]},
    A#{<<"effects">> := maps:get(<<"effects">>, A) ++ [Mail],
       <<"functions">> := [case maps:get(<<"name">>, F) of
                                <<"main">> -> F#{<<"effects">> := maps:get(<<"effects">>, F) ++ [<<"Mail">>]};
                                _ -> F
                            end || F <- maps:get(<<"functions">>, A)]}.
map_store(A, Fun) -> A#{<<"effects">> := [case maps:get(<<"name">>, E) of <<"Store">> -> Fun(E); _ -> E end || E <- maps:get(<<"effects">>, A)]}.
map_datatype(A, N, Fun) ->
    A#{<<"datatypes">> := [case maps:get(<<"name">>, D) of N -> D#{<<"constructors">> := Fun(maps:get(<<"constructors">>, D))}; _ -> D end
                           || D <- maps:get(<<"datatypes">>, A)]}.

%% An image descriptor whose artifact (identity-consistent) declares an effect no
%% contract discharges: the supervisor must refuse to start, and no tender boots.
supervisor_refusal(C, Variant) ->
    Dir = filename:join(maps:get(out, C), "unit/refusal"),
    ok = filelib:ensure_dir(filename:join(Dir, "artifacts/x")),
    Bytes = json:encode(Variant),
    ok = file:write_file(filename:join(Dir, "artifacts/0.json"), Bytes),
    {ok, IB} = file:read_file(maps:get(image, C)),
    I = json:decode(IB),
    I2 = I#{<<"batch_dir">> := list_to_binary(Dir), <<"artifact_sha256">> := binary:encode_hex(crypto:hash(sha256, Bytes), lowercase),
            <<"residual_effects">> := fenrir_manifest:residual(Variant)},
    Desc = filename:join(Dir, "image.json"),
    ok = file:write_file(Desc, json:encode(I2)),
    R = fenrir_service_sup:start_link(#{image => Desc, db => filename:join(Dir, "x.db"), tenants => 2,
                                        launcher => maps:get(launcher, C)}),
    Refused = case R of {error, {capability_manifest_refused, [{no_contract_for_effect, <<"Mail">>}]}} -> true; _ -> false end,
    {Refused andalso whereis(fenrir_store) =:= undefined, R}.

%% ---------- real guest authority wiring (full runner only) ----------

guest_authority(C) ->
    [t(authenticated_guest_submit, fun() ->
         with_guest_service(C, "guest-tenant", maps:get(image, C), fun(Tokens) ->
             T1 = maps:get(1, Tokens),
             {{refused, unauthorized}, #{}} = fenrir_front:submit(1, 0, 0, <<0>>),
             {{accepted, [1, 0, 0, 0, 0]}, _} = fenrir_front:submit(T1, 0, 0, <<0>>),
             {{accepted, [1, 0, 0, 0, 0]}, _} = fenrir_front:submit(T1, 0, 0, <<0>>),
             {delivered, _} = fenrir_front:deliver(1, 0, true),
             [[[], [], [], 0], [[[0, 0]], [[0, 0, <<"done">>]], [[0, 0, [1, 0, 0, 0, 0]]], 1]]
                 = fenrir_store:snapshot(),
             true
         end)
     end),
     t(real_guest_wrong_tenant_is_rejected, fun() ->
         %% Inject bad dispatch metadata: select the real tenant-1 entry for
         %% an authenticated tenant-0 submit. Same image and protocol; the
         %% real guest emits a well-formed Store.commit for another tenant.
         Desc = misrouted_submit_image(C, "wrong-tenant", [<<"submit">>, 1, 0, 0]),
         with_guest_service(C, "wrong-tenant", Desc, fun(Tokens) ->
             {aborted, #{why := unauthorized_scope, replies := [], commit := none}} =
                 fenrir_front:submit(maps:get(0, Tokens), 0, 0, <<0>>),
             [[[], [], [], 0], [[], [], [], 0]] = fenrir_store:snapshot(),
             [] = fenrir_front:outbox(),
             true
         end)
     end),
     t(real_guest_wrong_key_is_not_published, fun() ->
         Desc = misrouted_submit_image(C, "wrong-key", [<<"submit">>, 0, 1, 0]),
         with_guest_service(C, "wrong-key", Desc, fun(Tokens) ->
             {indeterminate, #{commit := committed}} = fenrir_front:submit(maps:get(0, Tokens), 0, 0, <<0>>),
             %% The reply is suppressed, not rolled back. Within-tenant writes
             %% are still made by the handler, here deliberately misrouted.
             [[[[0, 0]], [[0, 0, <<"pending">>]], [[1, 0, [0, 1, 0, 0, 0]]], 1], [[], [], [], 0]]
                 = fenrir_store:snapshot(),
             [] = fenrir_front:outbox(),
             true
         end)
     end)].

misrouted_submit_image(C, Name, Target) ->
    {ok, Bin} = file:read_file(maps:get(image, C)),
    I = json:decode(Bin),
    Entries = maps:get(<<"entries">>, I),
    From = [<<"submit">>, 0, 0, 0],
    [Replacement] = [E || E = #{<<"request">> := Req} <- Entries, Req =:= Target],
    Bad = [case E of #{<<"request">> := From} -> Replacement#{<<"request">> := From}; _ -> E end || E <- Entries],
    Desc = filename:join([maps:get(out, C), "unit", Name ++ "-image.json"]),
    ok = file:write_file(Desc, json:encode(I#{<<"entries">> := Bad})),
    Desc.

with_guest_service(C, Name, Image, Fun) ->
    Dir = filename:join(maps:get(out, C), "unit"),
    {Tokens, Bindings} = fenrir_authority:campaign_credentials(2),
    {ok, Sup} = fenrir_service_sup:start_link(
                  #{image => Image, db => filename:join(Dir, Name ++ ".db"),
                    tenants => 2, launcher => maps:get(launcher, C), console_dir => Dir,
                    submit_credentials => Bindings}),
    try Fun(Tokens) after gen_server:stop(Sup) end.

%% ---------- identities: a mismatched image is refused ----------

identity(C) ->
    {ok, IB} = file:read_file(maps:get(image, C)),
    I = json:decode(IB),
    Dir = filename:join(maps:get(out, C), "unit"),
    Write = fun(Name, Map) -> F = filename:join(Dir, Name), ok = file:write_file(F, json:encode(Map)), F end,
    Bad = fun(H) -> <<(binary:part(H, 0, 63))/binary, (case binary:last(H) of $0 -> $1; _ -> $0 end)>> end,
    [t(image_sha_mismatch_refused, fun() ->
         R = fenrir_worker:check_image(Write("img-sha.json", I#{<<"image_sha256">> := Bad(maps:get(<<"image_sha256">>, I))})),
         {R =:= {error, {image_identity, image}}, R} end),
     t(tender_sha_mismatch_refused, fun() ->
         R = fenrir_worker:check_image(Write("tender-sha.json", I#{<<"tender_sha256">> := Bad(maps:get(<<"tender_sha256">>, I))})),
         {R =:= {error, {image_identity, tender}}, R} end),
     t(hello_batch_mismatch_refused, fun() ->
         %% The image file is the real one but the descriptor names another batch: the
         %% guest's Hello does not match, the session fails closed before Init.
         with_store(C, "identity", normal, fun(_) ->
             F = Write("batch.json", I#{<<"batch_sha256">> := Bad(maps:get(<<"batch_sha256">>, I))}),
             {ok, W} = fenrir_worker:start_link(wid, #{image => F, launcher => maps:get(launcher, C), console_dir => Dir, name => wid}),
             R = fenrir_worker:run(wid, {tenant, 0}, {submit, 0, 0, <<0>>}),
             S = fenrir_store:snapshot(),
             unlink(W), exit(W, shutdown),
             {element(1, R) =:= failed andalso element(2, R) =:= {'Identity', hello} andalso S =:= [[[], [], [], 0], [[], [], [], 0]], R} end) end),
     t(hello_wrong_image_refused, fun() ->
         %% Another guest image (a different batch) under this descriptor's identities.
         case maps:get(other_image, C, none) of
             none -> {false, no_other_image};
             Other ->
                 {ok, OB} = file:read_file(Other),
                 F = Write("other.json", I#{<<"image">> := list_to_binary(Other),
                                            <<"image_sha256">> := binary:encode_hex(crypto:hash(sha256, OB), lowercase)}),
                 with_store(C, "identity2", normal, fun(_) ->
                     {ok, W} = fenrir_worker:start_link(wid2, #{image => F, launcher => maps:get(launcher, C), console_dir => Dir, name => wid2}),
                     R = fenrir_worker:run(wid2, {tenant, 0}, {submit, 0, 0, <<0>>}),
                     unlink(W), exit(W, shutdown),
                     {element(1, R) =:= failed andalso element(2, R) =:= {'Identity', hello}, R} end)
         end end)].
