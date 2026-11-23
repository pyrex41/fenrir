%% Accepted-job v1, with the same finite request domain as the recovery guest.
-module(fenrir_erlang_reference).
-behaviour(gen_server).
-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link(Name) -> gen_server:start_link({local, Name}, ?MODULE, [], []).
init([]) -> {ok, none}.

handle_call({run, {tenant, T} = Scope, Command}, _, State) when T =:= 0; T =:= 1 ->
    {reply, execute(Scope, T, Command), State};
handle_call(_, _, State) -> {reply, {refused, outside_domain}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.

execute(Scope, T, {submit, K, D, Payload}) when is_integer(K), K >= 0, K =< 9223372036854775807,
        (D =:= 0 orelse D =:= 1), Payload =:= <<D>> ->
    Writes = [write(<<"StageJob">>, []), write(<<"PutReport">>, [{int,D}, {bytes,Payload}]),
              write(<<"RecordKey">>, [{int,K}, {int,D}])],
    Reply = commit(Scope, T, <<"Once">>, K, Writes),
    case Reply of
        {reply, {data, <<"Reply">>, <<"Committed">>, [Receipt]}} -> response(<<"Accepted">>, [Receipt]);
        {reply, {data, <<"Reply">>, <<"Recorded">>, [{int,D}, Receipt]}} -> response(<<"Accepted">>, [Receipt]);
        {reply, {data, <<"Reply">>, <<"Recorded">>, _}} -> response(<<"Conflict">>, [{int,T}, {int,K}]);
        {reply, _} -> response(<<"Refused">>, []);
        Other -> failure(Other)
    end;
execute(Scope, T, {complete, J, Ok}) when is_integer(J), J >= 0, J =< 9223372036854775807, is_boolean(Ok) ->
    case commit(Scope, T, <<"Pending">>, J, [write(<<"Finish">>, [{int,J}, {bool,Ok}])]) of
        {reply, _} -> response(<<"Delivered">>, []);
        Other -> failure(Other)
    end;
execute(_, _, _) -> {refused, outside_domain}.

write(Name, Args) -> {data, <<"Write">>, Name, Args}.
commit(Scope, T, Guard, Key, Writes) ->
    Ops = lists:foldr(fun(W, Rest) -> {data, <<"Writes">>, <<"Then">>, [W, Rest]} end,
                      {data, <<"Writes">>, <<"Done">>, []}, Writes),
    Cap = {data, <<"Cap">>, <<"Tenant">>, [{int,T}]},
    Tx = {data, <<"Tx">>, <<"Tx">>, [Cap, {data, <<"Guard">>, Guard, [{int,Key}]}, Ops]},
    case fenrir_store:commit(Scope, Tx) of
        {reply, {data, <<"Reply">>, <<"Unauthorized">>, []}} -> {aborted, unauthorized_scope};
        Result -> Result
    end.

response(Name, Fields) -> {ok, {data, <<"Response">>, Name, Fields}, #{requests => 1}}.
failure(busy) -> {busy, store_busy, #{requests => 1}};
failure({Status, Why}) when Status =:= aborted; Status =:= indeterminate ->
    {Status, Why, #{requests => 1}}.
