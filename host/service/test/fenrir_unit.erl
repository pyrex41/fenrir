%% A3 unit tests of the host: framing against the specification's byte vectors, the
%% value codec, the storage contract on a real SQLite file, the connection settings,
%% the capability manifest check and its refusal, and the image identity refusals.
%%
%%   erl -noshell -pa EBIN -run fenrir_unit main CONFIG
%% Writes OUT/unit.json: {"tests": [...], "passed": N, "failed": M}.
-module(fenrir_unit).
-export([main/1]).

main([ConfigFile]) ->
    {ok, [C]} = file:consult(ConfigFile),
    Out = maps:get(out, C),
    ok = filelib:ensure_dir(filename:join(Out, "unit/x")),
    fenrir_faults:init(),
    Tests = lists:append([vectors(maps:get(root, C)), values(), store(C), settings(C), manifest(C), identity(C),
                          upgrade(C)]),
    Failed = [T || T = {_, false, _} <- Tests],
    Json = #{<<"tests">> => [#{<<"name">> => iolist_to_binary(io_lib:format("~p", [N])), <<"pass">> => P,
                               <<"detail">> => iolist_to_binary(io_lib:format("~0P", [D, 12]))} || {N, P, D} <- Tests],
             <<"passed">> => length(Tests) - length(Failed), <<"failed">> => length(Failed)},
    ok = file:write_file(filename:join(Out, "unit.json"), json:encode(Json)),
    [io:format("FAIL ~p: ~0P~n", [N, D, 20]) || {N, false, D} <- Failed],
    io:format("unit: ~p passed, ~p failed~n", [length(Tests) - length(Failed), length(Failed)]),
    halt(0).

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

with_store(C, Name, Mutant, Fun) ->
    Db = filename:join([maps:get(out, C), "unit", Name ++ ".db"]),
    fenrir_drive:fresh_db(Db),
    case ets:info(fenrir_mailbox) of undefined -> ets:new(fenrir_mailbox, [named_table, public]); _ -> ok end,
    {ok, Pid} = fenrir_store:start_link(#{db => Db, tenants => 2, mutant => Mutant}),
    try Fun(Db) after unlink(Pid), exit(Pid, shutdown), timer:sleep(50) end.

store(C) ->
    Cases =
        [{fresh_key_commits, [sub(0, 1, 1)], committed(receipt(0, 1, 1, 0, 0))},
         {same_key_same_digest_recorded, [sub(0, 1, 1), sub(0, 1, 1)],
          {reply, d(<<"Reply">>, <<"Recorded">>, [i(1), receipt(0, 1, 1, 0, 0)])}},
         {same_key_other_digest_recorded_with_first_digest, [sub(0, 1, 1), sub(0, 1, 0)],
          {reply, d(<<"Reply">>, <<"Recorded">>, [i(1), receipt(0, 1, 1, 0, 0)])}},
         {second_key_next_id, [sub(0, 1, 1), sub(0, 2, 0)], committed(receipt(0, 2, 0, 1, 1))},
         {tenants_are_separate, [sub(0, 1, 1), sub(1, 1, 1)], committed(receipt(1, 1, 1, 0, 0))},
         {unknown_tenant_unauthorized, [sub(2, 0, 0)], reply(<<"Unauthorized">>)},
         {negative_tenant_unauthorized, [sub(-1, 0, 0)], reply(<<"Unauthorized">>)},
         {pending_job_finished_applied, [sub(0, 0, 0), tx(0, pending(0), [w(<<"Finish">>, [i(0), {bool, true}])])], reply(<<"Applied">>)},
         {finished_job_skipped, [sub(0, 0, 0), tx(0, pending(0), [w(<<"Finish">>, [i(0), {bool, true}])]),
                                 tx(0, pending(0), [w(<<"Finish">>, [i(0), {bool, false}])])], reply(<<"Skipped">>)},
         {unknown_job_skipped, [tx(0, pending(5), [w(<<"Finish">>, [i(5), {bool, true}])])], reply(<<"Skipped">>)},
         {always_finish_unconditional_applied, [tx(0, always(), [w(<<"Finish">>, [i(9), {bool, true}])])], reply(<<"Applied">>)},
         {stage_job_of_does_not_allocate, [tx(0, always(), [w(<<"StageJobOf">>, [i(3)])]), sub(0, 0, 0)], committed(receipt(0, 0, 0, 0, 0))},
         {malformed_tx_aborted, [d(<<"Tx">>, <<"Tx">>, [])], {aborted, malformed_tx}}],
    [t({store_contract, N}, fun() ->
            with_store(C, atom_to_list(N), normal,
                       fun(_) -> Rs = [fenrir_store:commit(X) || X <- Txs], {lists:last(Rs) =:= Want, Rs} end)
        end) || {N, Txs, Want} <- Cases]
    ++ [t({store_contract, snapshot_is_canonical}, fun() ->
            with_store(C, "snapshot", normal, fun(_) ->
                fenrir_store:commit(sub(0, 1, 1)), fenrir_store:commit(sub(0, 0, 0)),
                fenrir_store:commit(tx(0, pending(1), [w(<<"Finish">>, [i(1), {bool, false}])])),
                S = fenrir_store:snapshot(),
                {S =:= [[[[0, 1], [1, 0]], [[0, 0, <<"pending">>], [1, 1, <<"failed">>]], [[0, 0, [0, 0, 0, 1, 1]], [1, 1, [0, 1, 1, 0, 0]]], 2],
                        [[], [], [], 0]], S} end) end),
        t({store_contract, payload_stored}, fun() ->
            with_store(C, "payload", normal, fun(Db) ->
                fenrir_store:commit(tx(0, once(0), [w(<<"PutReport">>, [i(7), {bytes, <<"hello">>}]), w(<<"RecordKey">>, [i(0), i(7)])])),
                {ok, P} = fenrir_sqlite:open(Db),
                R = fenrir_sqlite:exec(P, "SELECT payload FROM reports"), fenrir_sqlite:close(P),
                {R =:= {rows, [[{blob, <<"hello">>}]]}, R} end) end)].

%% ---------- connection settings: WAL and synchronous=FULL, read back ----------

settings(C) ->
    [t(settings_wal_full, fun() ->
         with_store(C, "settings", normal, fun(Db) ->
             {ok, P} = fenrir_store:open_configured(Db, normal),
             R = [fenrir_sqlite:exec(P, Q) || Q <- ["PRAGMA journal_mode", "PRAGMA synchronous", "PRAGMA foreign_keys"]],
             fenrir_sqlite:close(P),
             {R =:= [{rows, [[<<"wal">>]]}, {rows, [[2]]}, {rows, [[1]]}], R} end) end),
     t(settings_busy_is_distinct_outcome, fun() ->
         with_store(C, "busy", normal, fun(Db) ->
             {ok, P} = fenrir_sqlite:open(Db),
             {rows, _} = fenrir_sqlite:exec(P, "BEGIN IMMEDIATE"),
             R = fenrir_store:commit(sub(0, 0, 0)),
             fenrir_sqlite:exec(P, "ROLLBACK"), fenrir_sqlite:close(P),
             R2 = fenrir_store:commit(sub(0, 0, 0)),
             {R =:= busy andalso R2 =:= committed(receipt(0, 0, 0, 0, 0)), {R, R2}} end) end)].

%% ---------- capability manifest ----------

manifest(C) ->
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
        end) || {N, V} <- Variants]
    ++ [t(supervisor_refuses_worker_on_manifest, fun() -> supervisor_refusal(C, add_effect(A)) end)].

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
             R = fenrir_worker:run(wid, {submit, 0, 0, 0, <<0>>}),
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
                     R = fenrir_worker:run(wid2, {submit, 0, 0, 0, <<0>>}),
                     unlink(W), exit(W, shutdown),
                     {element(1, R) =:= failed andalso element(2, R) =:= {'Identity', hello}, R} end)
         end end)].

%% ---------- A4: the durable upgrade state, fencing, the v2 contract, the migration ----------

tx2(T, G, Ws) -> d(<<"Tx">>, <<"Tx2">>, [d(<<"Cap">>, <<"Tenant">>, [i(T)]), G,
                                          lists:foldr(fun(W, Acc) -> d(<<"Writes">>, <<"Then">>, [W, Acc]) end,
                                                      d(<<"Writes">>, <<"Done">>, []), Ws)]).
sub2(T, K, D) -> tx2(T, once(K), [w(<<"StageJob2">>, [i(0)]), w(<<"PutReport">>, [i(D), {bytes, <<D>>}]), w(<<"RecordKey">>, [i(K), i(D)])]).
receipt2(T, K, D, R, J) -> d(<<"Receipt">>, <<"Receipt2">>, [i(T), i(K), i(D), i(R), i(J)]).

%% The migration of a store as the program computes it (UPGRADE.md section 2.1), staged
%% row by row through the store's migration session.
migrate_store() ->
    {reply, First} = fenrir_store:migration(read, i(0)),
    Rows = read_rows(First, 1),
    [{reply, _} = fenrir_store:migration(stage, row2(R)) || R <- Rows],
    fenrir_store:migration(install, i(length(Rows))).

read_rows({data, <<"Next1">>, <<"NoMore">>, []}, _) -> [];
read_rows({data, <<"Next1">>, <<"Next">>, [R]}, I) ->
    {reply, N} = fenrir_store:migration(read, i(I)), [R | read_rows(N, I + 1)].

row2({data, <<"Row1">>, <<"Job1">>, [T, J, R, S]}) ->
    A = case S of {data, _, <<"Pending">>, _} -> 0; _ -> 1 end,
    d(<<"Row2">>, <<"Job2">>, [T, J, R, S, i(A)]);
row2({data, <<"Row1">>, <<"Key1">>, Fs}) -> d(<<"Row2">>, <<"Key2">>, Fs).

begin_upgrade() -> fenrir_store:transition(begin_upgrade, #{image => <<"x">>, v2_image => <<"v2">>, migration_image => <<"m">>}).

upgrade(C) ->
    V2 = maps:get(v2_artifact, C, none),
    Mig = maps:get(migration_artifact, C, none),
    [t(upgrade_fresh_store_is_v1, fun() ->
         with_store(C, "u-fresh", normal, fun(_) ->
             U = fenrir_store:upgrade_state(), {maps:with([schema, upgrade], U) =:= #{schema => 1, upgrade => v1}, U} end) end),
     t(upgrade_v2_commit_fenced_while_v1, fun() ->
         with_store(C, "u-fence2", normal, fun(_) ->
             R = fenrir_store:commit(sub2(0, 0, 0)), S = fenrir_store:snapshot(),
             {element(1, R) =:= stale andalso S =:= [[[], [], [], 0], [[], [], [], 0]], {R, S}} end) end),
     t(upgrade_full_cycle_in_the_adapter, fun() ->
         with_store(C, "u-cycle", normal, fun(_) ->
             {reply, _} = fenrir_store:commit(sub(0, 0, 0)),
             {reply, _} = fenrir_store:commit(sub(1, 0, 1)),
             {reply, _} = fenrir_store:commit(tx(1, pending(0), [w(<<"Finish">>, [i(0), {bool, false}])])),
             E1 = fenrir_store:transition(cut_over, #{}),
             ok = begin_upgrade(),
             {reply, _} = fenrir_store:commit(sub(0, 1, 1)),
             I = migrate_store(),
             Stale = fenrir_store:commit(sub(0, 2, 0)),
             Window = fenrir_store:commit(sub2(0, 2, 0)),
             ok = fenrir_store:transition(cut_over, #{}),
             Old = fenrir_store:commit(sub(0, 2, 0)),
             Retry = fenrir_store:commit(sub2(0, 0, 0)),
             New = fenrir_store:commit(sub2(0, 2, 0)),
             Done = fenrir_store:commit(tx2(0, pending(0), [w(<<"Finish">>, [i(0), {bool, true}]), w(<<"CountAttempt">>, [i(0)])])),
             Snap = fenrir_store:snapshot(),
             Want = [[[[0, 0], [1, 1], [2, 0]], [[0, 0, <<"done">>, 1], [1, 1, <<"pending">>, 0], [2, 2, <<"pending">>, 0]],
                      [[0, 0, [0, 0, 0, 0, 0]], [1, 1, [0, 1, 1, 1, 1]], [2, 0, [0, 2, 0, 2, 2, 2]]], 3],
                     [[[0, 1]], [[0, 0, <<"failed">>, 1]], [[0, 1, [1, 0, 1, 0, 0]]], 1]],
             Ok = element(1, E1) =:= refused andalso I =:= {reply, d(<<"Migrated">>, <<"Installed">>, [])}
                  andalso element(1, Stale) =:= stale andalso element(1, Window) =:= stale andalso element(1, Old) =:= stale
                  andalso Retry =:= {reply, d(<<"Reply">>, <<"Recorded">>, [i(0), receipt(0, 0, 0, 0, 0)])}
                  andalso New =:= committed(receipt2(0, 2, 0, 2, 2)) andalso Done =:= reply(<<"Applied">>) andalso Snap =:= Want,
             {Ok, {E1, I, Stale, Window, Old, Retry, New, Done, Snap}} end) end),
     t(upgrade_install_changed_after_a_commit, fun() ->
         with_store(C, "u-cas", normal, fun(_) ->
             {reply, _} = fenrir_store:commit(sub(0, 0, 0)),
             ok = begin_upgrade(),
             {reply, First} = fenrir_store:migration(read, i(0)),
             Rows = read_rows(First, 1),
             [{reply, _} = fenrir_store:migration(stage, row2(R)) || R <- Rows],
             {reply, _} = fenrir_store:commit(sub(0, 1, 0)),
             R1 = fenrir_store:migration(install, i(length(Rows))),
             U = maps:get(upgrade, fenrir_store:upgrade_state()),
             R2 = migrate_store(),
             {R1 =:= {reply, d(<<"Migrated">>, <<"Changed">>, [])} andalso U =:= prepared
              andalso R2 =:= {reply, d(<<"Migrated">>, <<"Installed">>, [])}, {R1, U, R2}} end) end),
     t(upgrade_install_refused_unless_prepared, fun() ->
         with_store(C, "u-refused", normal, fun(_) ->
             {reply, _} = fenrir_store:commit(sub(0, 0, 0)),
             R = migrate_store(),
             {R =:= {reply, d(<<"Migrated">>, <<"Refused">>, [])} andalso maps:get(schema, fenrir_store:upgrade_state()) =:= 1, R} end) end),
     t(upgrade_unknown_schema_refused_at_open, fun() -> open_refused(C, "u-unknown",
         ["UPDATE meta SET v = 'fenrir.host.service-store/9' WHERE k = 'schema'"]) end),
     t(upgrade_inconsistent_state_refused_at_open, fun() -> open_refused(C, "u-inconsistent",
         ["UPDATE meta SET v = 'migrated' WHERE k = 'upgrade'"]) end),
     t(upgrade_v2_columns_under_schema_1_refused_at_open, fun() -> open_refused(C, "u-columns",
         ["ALTER TABLE jobs ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0"]) end),
     t(manifest_v2_handler_is_contract_2, fun() ->
         R = fenrir_manifest:contract_version(V2), {R =:= {ok, 2}, R} end),
     t(manifest_migration_program_is_migration_contract, fun() ->
         R = fenrir_manifest:contract_version(Mig), {R =:= {ok, migration}, R} end),
     t(manifest_v1_handler_is_contract_1, fun() ->
         R = fenrir_manifest:contract_version(maps:get(artifact, C)), {R =:= {ok, 1}, R} end),
     t(manifest_descriptor_claiming_another_contract_refused, fun() ->
         {ok, IB} = file:read_file(maps:get(image, C)),
         I = json:decode(IB),
         Art = filename:join(maps:get(<<"batch_dir">>, I), "artifacts/0.json"),
         R = fenrir_manifest:check(Art, I#{<<"contract_version">> => 2}),
         {element(1, R) =:= refused, R} end)].

%% A store file changed behind the adapter's back: reopening it must be refused.
open_refused(C, Name, Sqls) ->
    Db = filename:join([maps:get(out, C), "unit", Name ++ ".db"]),
    with_store(C, Name, normal, fun(_) -> ok end),
    {ok, P} = fenrir_sqlite:open(Db),
    [{rows, _} = fenrir_sqlite:exec(P, Q) || Q <- Sqls],
    fenrir_sqlite:close(P),
    Old = process_flag(trap_exit, true),
    R = fenrir_store:start_link(#{db => Db, tenants => 2, mutant => normal}),
    receive {'EXIT', _, _} -> ok after 100 -> ok end,
    process_flag(trap_exit, Old),
    {element(1, R) =:= error andalso element(1, element(2, R)) =:= store_refused, R}.
