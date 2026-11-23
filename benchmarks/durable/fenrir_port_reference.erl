%% Packet adapter for the native reference: forward the same guarded Tx to SQLite
%% and translate its typed reply to fixed-width fields for the worker.
-module(fenrir_port_reference).
-behaviour(gen_server).
-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link(Name) -> gen_server:start_link({local, Name}, ?MODULE, [], []).
init([]) ->
    Port = open_port({spawn_executable, os:getenv("FENRIR_REFERENCE_PORT")},
                     [binary, {packet, 2}, exit_status, use_stdio]),
    {ok, Port}.

handle_call({run, {tenant,T} = Scope, Req}, _, P) when T =:= 0; T =:= 1 ->
    Result = case Req of
        {submit,K,D,Payload} when is_integer(K), K >= 0, K =< 9223372036854775807, (D =:= 0 orelse D =:= 1),
                                 Payload =:= <<D>> -> run(P, Scope, command(0,T,K,D));
        {complete,J,Ok} when is_integer(J), J >= 0, J =< 9223372036854775807, is_boolean(Ok) ->
            Flag = case Ok of true -> 1; false -> 0 end,
            run(P, Scope, command(1,T,J,Flag));
        _ -> {refused,outside_domain}
    end,
    {reply, Result, P};
handle_call(_, _, P) -> {reply,{refused,outside_domain},P}.
handle_cast(_, P) -> {noreply,P}.
handle_info({P,{exit_status,Code}}, P) -> {stop,{worker_exit,Code},P};
handle_info(_, P) -> {noreply,P}.

command(Op,T,K,D) when K < 2 -> <<Op,T,K,D>>;
command(Op,T,K,D) -> <<(Op+3),T,K:64/signed-big,D>>.

exchange(P, Bytes) ->
    true = port_command(P,Bytes),
    receive
        {P,{data,Reply}} -> fenrir_value:decode(Reply);
        {P,{exit_status,Code}} -> exit({worker_exit,Code})
    after 5000 -> exit(reference_timeout)
    end.

run(P, Scope, Cmd) ->
    Tx = exchange(P, Cmd),
    Stats = #{requests => 1},
    case fenrir_store:commit(Scope, Tx) of
        busy -> {busy,store_busy,Stats};
        {State,Why} when State =:= aborted; State =:= indeterminate -> {State,Why,Stats};
        {reply,{data,<<"Reply">>,<<"Unauthorized">>,[]}} -> {aborted,unauthorized_scope,Stats};
        {reply, Value} -> {ok,exchange(P, <<2,Cmd/binary,(reply_packet(Value))/binary>>),Stats}
    end.

reply_packet({data,<<"Reply">>,<<"Committed">>,[Receipt]}) ->
    <<0,0,(receipt(Receipt))/binary>>;
reply_packet({data,<<"Reply">>,<<"Recorded">>,[{int,Old},Receipt]}) ->
    <<1,Old,(receipt(Receipt))/binary>>;
reply_packet({data,<<"Reply">>,<<"Applied">>,[]}) -> <<2>>;
reply_packet({data,<<"Reply">>,<<"Skipped">>,[]}) -> <<3>>.

receipt({data,<<"Receipt">>,<<"Receipt">>,Fields}) ->
    << <<N:64/signed-big>> || {int,N} <- Fields >>.
