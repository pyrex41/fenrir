%% A3 host infrastructure: one SQLite connection held by the C port program
%% host/service/c_src/fenrir_sqlite_port.c. The caller owns the port (it is linked to
%% the process that opens it). No storage decision is made here.
-module(fenrir_sqlite).
-export([open/1, open/2, exec/2, exec/3, arm/3, counters/1, close/1, os_pid/1, port_program/0]).

-define(TIMEOUT, 30000).

port_program() ->
    case os:getenv("FENRIR_SQLITE_PORT") of
        false -> error(no_sqlite_port_program);
        P -> P
    end.

open(Path) -> open(Path, port_program()).

%% {ok, Port} | {error, Reason}
open(Path, Program) ->
    Port = open_port({spawn_executable, Program}, [{packet, 4}, binary, exit_status, use_stdio]),
    case call(Port, <<$O, (unicode:characters_to_binary(Path))/binary>>) of
        ok -> {ok, Port};
        Other -> catch port_close(Port), {error, Other}
    end.

os_pid(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, P} -> P;
        undefined -> undefined
    end.

%% exec(Port, Sql, Params) -> {rows, [[Value]]} | {sqlite_error, Primary, Extended, Msg}
%%                          | {port_died, Status}
exec(Port, Sql) -> exec(Port, Sql, []).
exec(Port, Sql, Params) ->
    S = unicode:characters_to_binary(Sql),
    call(Port, <<$E, (byte_size(S)):32, S/binary, (length(Params)):16, (<< <<(param(P))/binary>> || P <- Params >>)/binary>>).

%% Kind: write | sync | after_statement | before_statement; N >= 1 counted from now.
arm(Port, Kind, N) when is_integer(N), N >= 1 ->
    K = case Kind of disarm -> 0; write -> 1; sync -> 2; after_statement -> 3; before_statement -> 4 end,
    call(Port, <<$F, K, N:32>>).

counters(Port) ->
    case call(Port, <<$W>>) of
        {rows, [[W, S]]} -> {W, S};
        Other -> Other
    end.

close(Port) ->
    case erlang:port_info(Port) of
        undefined -> ok; %% the program is gone already
        _ -> close_open(Port)
    end.

close_open(Port) ->
    catch port_command(Port, <<$C>>),
    receive {Port, {exit_status, _}} -> ok after 5000 -> catch port_close(Port), ok end.

param(null) -> <<$n>>;
param(I) when is_integer(I) -> <<$i, I:64/signed>>;
param({text, B}) -> <<$t, (byte_size(B)):32, B/binary>>;
param({blob, B}) -> <<$b, (byte_size(B)):32, B/binary>>;
param(B) when is_binary(B) -> <<$t, (byte_size(B)):32, B/binary>>.

call(Port, Req) ->
    try port_command(Port, Req) of
        true -> wait(Port)
    catch error:badarg -> {port_died, closed}
    end.

wait(Port) ->
    receive
        {Port, {data, <<$K>>}} -> ok;
        {Port, {data, <<$R, N:32, C:16, Rest/binary>>}} -> {rows, rows(N, C, Rest)};
        {Port, {data, <<$X, P:32, E:32, L:32, M:L/binary>>}} -> {sqlite_error, code(P), E, M};
        {Port, {data, Other}} -> {port_died, {garbage, Other}};
        {Port, {exit_status, S}} -> {port_died, S}
    after ?TIMEOUT -> {port_died, timeout}
    end.

rows(0, _, <<>>) -> [];
rows(N, C, Bin) -> {Row, Rest} = row(C, Bin, []), [Row | rows(N - 1, C, Rest)].
row(0, Bin, Acc) -> {lists:reverse(Acc), Bin};
row(C, <<$n, R/binary>>, Acc) -> row(C - 1, R, [null | Acc]);
row(C, <<$i, I:64/signed, R/binary>>, Acc) -> row(C - 1, R, [I | Acc]);
row(C, <<$t, L:32, B:L/binary, R/binary>>, Acc) -> row(C - 1, R, [B | Acc]);
row(C, <<$b, L:32, B:L/binary, R/binary>>, Acc) -> row(C - 1, R, [{blob, B} | Acc]).

%% Primary result codes the adapter distinguishes.
code(5) -> busy;
code(6) -> locked;
code(19) -> constraint;
code(N) -> N.
