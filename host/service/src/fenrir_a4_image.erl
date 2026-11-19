%% A4 has two closed, source-bound roles. An admitted bundle is copied from the
%% bytes checked here, never executed later from its descriptor's original paths.
%% The local operator and the host-owned launch directory are in the TCB.
-module(fenrir_a4_image).
-export([admit/2, load/3, with_launch/3]).

admit(Path, Role) ->
    case bundle(Path, Role) of
        {ok, Pin, _} -> {ok, Pin};
        Error -> Error
    end.

load(Path, Role, Expected) ->
    case bundle(Path, Role) of
        {ok, Expected, Bundle} -> {ok, Bundle};
        {ok, _, _} -> {error, durable_image_pin_mismatch};
        Error -> Error
    end.

%% These exact canonical artifacts were emitted from the repository-relative
%% sources. Admission is deliberately narrower than compatible-manifest search.
artifact(handler_v2) -> <<"52b39c511c54e307e51ae3bb9fd46623d72dfafe86466bb6677276c79d6db138">>;
artifact(migration) -> <<"e75ed78253ee1e3b7b76c84590d2ff2d34d35330b6e8f6e0f3418448b7d9d415">>.

role_name(handler_v2) -> <<"handler-v2">>;
role_name(migration) -> <<"migration">>.

bundle(Path, Role) ->
    try
        Desc = read(Path, 2097152),
        I = json:decode(Desc),
        #{<<"schema">> := <<"fenrir.host.service-image/2">>,
          <<"protocol">> := <<"fenrir.solo5.pure-call-control/2">>,
          <<"machine_profile">> := <<"fenrir.solo5.pure-call-machine/2">>,
          <<"artifact_schema">> := <<"tc1-durable-demo/1">>,
          <<"fuel">> := <<"5000">>, <<"role">> := Label,
          <<"artifact_sha256">> := ArtifactSha, <<"batch_dir">> := BatchDir,
          <<"image">> := ImagePath, <<"tender">> := TenderPath,
          <<"image_sha256">> := ImageSha, <<"tender_sha256">> := TenderSha,
          <<"residual_effects">> := Row, <<"datatypes">> := DataTypes,
          <<"domain">> := Domain, <<"entries">> := Entries, <<"programs">> := Programs,
          <<"batch_sha256">> := Batch} = I,
        Label = role_name(Role),
        ArtifactSha = artifact(Role),
        Artifact = read(filename:join(BatchDir, <<"artifacts/0.json">>), 1048576),
        ArtifactSha = sha(Artifact),
        A = json:decode(Artifact),
        Row = fenrir_manifest:residual(A),
        true = Row =/= [],
        DataTypes = maps:get(<<"datatypes">>, A),
        Inputs = checked_entries(Role, Domain, Entries, Programs),
        Batch = sha(lists:join(<<"\n">>, [[ArtifactSha, $:, Input] || Input <- Inputs])),
        Image = read(ImagePath, 67108864),
        ImageSha = sha(Image),
        Tender = read(TenderPath, 8388608),
        TenderSha = sha(Tender),
        Pin = fenrir_upgrade_state:image_pin(Desc, Artifact, Image, Tender),
        {ok, Pin, {I, Image, Tender}}
    catch
        throw:Why -> {error, Why};
        error:_ -> {error, invalid_a4_image_descriptor}
    end.

read(Path, Limit) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, Fd} ->
            try
                case file:read(Fd, Limit + 1) of
                    {ok, B} when byte_size(B) =< Limit -> B;
                    _ -> throw(invalid_a4_file_size)
                end
            after file:close(Fd) end;
        {error, _} -> throw(a4_image_file_unavailable)
    end.

sha(B) -> binary:encode_hex(crypto:hash(sha256, B), lowercase).

checked_entries(Role, Domain, Entries, N) when is_integer(N), N > 0, N =< 4096 ->
    Requests = requests(Role, Domain, N),
    true = length(Entries) =:= N,
    lists:zipwith(fun({Request, Index}, Entry) ->
        Sha = sha(json:encode(input(Request))),
        #{<<"request">> := Request, <<"program">> := Index, <<"input_sha256">> := Sha} = Entry,
        Sha
    end, lists:zip(Requests, lists:seq(0, N - 1)), Entries).

requests(migration, D, 1) when map_size(D) =:= 0 -> [[<<"migrate">>]];
requests(handler_v2, #{<<"tenants">> := T, <<"keys">> := K, <<"digests">> := D, <<"jobs">> := J}, N) ->
    true = lists:all(fun(X) -> is_integer(X) andalso X >= 1 andalso X =< 64 end, [T, K, D, J]),
    N = T * (K * D + 2 * J),
    Seq = fun(X) -> lists:seq(0, X - 1) end,
    [[<<"submit">>, A, B, C] || A <- Seq(T), B <- Seq(K), C <- Seq(D)] ++
    [[<<"complete">>, A, B, Ok] || A <- Seq(T), B <- Seq(J), Ok <- [true, false]].

int(N) -> [<<"int">>, integer_to_binary(N)].
cap(T) -> [<<"data">>, <<"Cap">>, <<"Tenant">>, int(T)].
input([<<"migrate">>]) -> [<<"unit">>];
input([<<"submit">>, T, K, D]) ->
    [<<"data">>, <<"Command">>, <<"Submit">>, cap(T), int(K), int(D), [<<"bytes">>, binary:encode_hex(<<D>>, lowercase)]];
input([<<"complete">>, T, J, Ok]) ->
    [<<"data">>, <<"Command">>, <<"Complete">>, cap(T), int(J), [<<"bool">>, Ok]].

with_launch({I, Image, Tender}, Parent, Run) ->
    Dir = filename:join(Parent, <<"a4-", (binary:encode_hex(crypto:strong_rand_bytes(16), lowercase))/binary>>),
    case file:make_dir(Dir) of
        ok ->
            T = filename:join(Dir, <<"tender">>),
            G = filename:join(Dir, <<"guest.spt">>),
            try
                case copy_launch(Dir, [{T, Tender, 8#500}, {G, Image, 8#400}]) of
                    ok -> Run(I#{<<"image">> := G, <<"tender">> := T});
                    {error, _} -> {refused, a4_launch_copy_failed}
                end
            after
                file:delete(T),
                file:delete(G),
                file:del_dir(Dir)
            end;
        {error, _} -> {refused, a4_launch_directory_unavailable}
    end.

copy_launch(Dir, Files) ->
    try
        ok = file:change_mode(Dir, 8#700),
        [begin ok = file:write_file(Path, Bytes, [exclusive]), ok = file:change_mode(Path, Mode) end ||
            {Path, Bytes, Mode} <- Files],
        ok
    catch error:{badmatch, {error, _}} -> {error, file_setup} end.
