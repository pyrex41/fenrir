%% Host-only migration protocol. Neither a PID nor a session token is encoded
%% in the guest. Only an observed successful store install can mark committed.
-module(fenrir_a4_migration).
-export([answer/4]).

answer(<<"read">>, {int, 0}, Token, St) ->
    case maps:get(migration_result, St, none) of
        none when not is_map_key(copy, St) -> read_start(Token, St);
        {data, <<"Migrated">>, <<"Changed">>, []} -> read_start(Token, St);
        _ -> fail(unexpected_read, St)
    end;
answer(<<"read">>, {int, I}, _, St) when I > 0 -> read_row(I, St);
answer(<<"stage">>, Row, _, St = #{copy := C = #{stage := true, count := N}}) ->
    case staged(Row, C) of
        {ok, C1} -> send(d(<<"Ack">>, <<"Ack">>, []), St#{copy := C1#{stage := false, count := N+1}});
        error -> fail(invalid_stage, St)
    end;
answer(<<"install">>, {int, N}, Token, St = #{copy := #{ended := true, count := N, jobs := Js, keys := Ks}}) ->
    case fenrir_store:maintenance({install_retryable, Token, lists:sort(Js), lists:sort(Ks)}) of
        {ok, installed} -> result(<<"Installed">>, St#{commit := committed});
        {refused, snapshot_changed} -> result(<<"Changed">>, St);
        {refused, invalid_projection} -> result(<<"Refused">>, St);
        Other -> infrastructure(Other, St)
    end;
answer(_, _, _, St) -> fail(invalid_migration_operation, St).

read_start(Token, St) ->
    case fenrir_store:maintenance({refresh, Token}) of
        ok ->
            case fenrir_store:maintenance({read, Token}) of
                {ok, Jobs, Keys} ->
                    Rows = lists:sort([{T, 1, J, job1(T,J,R,S)} || [T,J,R,S] <- Jobs] ++
                                      [{T, 2, K, key1(T,K,D,RT,RK,RD,RR,RJ)} || [T,K,D,RT,RK,RD,RR,RJ] <- Keys]),
                    C = #{rows => Rows, count => 0, jobs => [], keys => [], stage => false, ended => false},
                    read_row(0, maps:remove(migration_result, St#{copy => C}));
                Other -> infrastructure(Other, St)
            end;
        Other -> infrastructure(Other, St)
    end.

read_row(N, St = #{copy := C = #{count := N, stage := false, ended := false, rows := Rows}}) ->
    case Rows of
        [] -> send(d(<<"Next1">>, <<"NoMore">>, []), St#{copy := C#{ended := true}});
        [{_, Kind, _, Row} | Rest] ->
            send(d(<<"Next1">>, <<"Next">>, [Row]), St#{copy := C#{rows := Rest, stage := true, kind => Kind}})
    end;
read_row(_, St) -> fail(unexpected_read, St).

staged({data, <<"Row2">>, <<"Job2">>, [{int,T},{int,J},{int,R},S,{int,A}]}, C = #{kind := 1, jobs := Js}) ->
    case status(S) of
        error -> error;
        S1 -> {ok, C#{jobs := [[T,J,R,S1,A]|Js]}}
    end;
staged({data, <<"Row2">>, <<"Key2">>, [{int,T},{int,K},{int,D},
        {data, <<"Receipt">>, <<"Receipt">>, [{int,RT},{int,RK},{int,RD},{int,RR},{int,RJ}]}]},
        C = #{kind := 2, keys := Ks}) ->
    {ok, C#{keys := [[T,K,D,RT,RK,RD,RR,RJ]|Ks]}};
staged(_, _) -> error.

job1(T,J,R,S) ->
    C = case S of <<"pending">> -> <<"Pending">>; <<"done">> -> <<"Done">>; <<"failed">> -> <<"Failed">> end,
    d(<<"Row1">>, <<"Job1">>, [i(T), i(J), i(R), d(<<"Status">>, C, [])]).
key1(T,K,D,RT,RK,RD,RR,RJ) ->
    d(<<"Row1">>, <<"Key1">>, [i(T), i(K), i(D),
                               d(<<"Receipt">>, <<"Receipt">>, lists:map(fun i/1, [RT,RK,RD,RR,RJ]))]).
status({data, <<"Status">>, <<"Pending">>, []}) -> <<"pending">>;
status({data, <<"Status">>, <<"Done">>, []}) -> <<"done">>;
status({data, <<"Status">>, <<"Failed">>, []}) -> <<"failed">>;
status(_) -> error.

result(Name, St) ->
    R = d(<<"Migrated">>, Name, []),
    send(R, (maps:remove(copy, St))#{migration_result => R}).
send(V, St) ->
    B = fenrir_value:encode(V),
    byte_size(B) =< 460 orelse fail(oversize_reply, St),
    {V, St#{replies := maps:get(replies, St) ++ [B]}}.

infrastructure(busy, St) -> throw({fail, busy, store_busy, St});
infrastructure({indeterminate, Why}, St) -> throw({fail, indeterminate, Why, St#{commit := sent}});
infrastructure({aborted, Why}, St) -> throw({fail, aborted, Why, St});
infrastructure(Other, St) -> fail(Other, St).
fail(Why, St) -> throw({fail, failed, {migration, Why}, St}).
d(T,C,F) -> {data,T,C,F}.
i(N) -> {int,N}.
