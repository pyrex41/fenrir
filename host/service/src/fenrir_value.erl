%% Canonical values of the artifact value encoding (spec/tc1/DURABLE.md section 5):
%%   ["unit"] ["bool",b] ["int","n"] ["bytes","hex"] ["tuple",v...] ["data",T,C,v...]
%% Erlang form: unit | {bool,B} | {int,N} | {bytes,Bin} | {tuple,[V]} | {data,T,C,[V]}
%% with T and C binaries. encode/1 writes the one canonical spelling (no white space,
%% decimal I64, lowercase hex). from_json/1 takes a term decoded by json:decode/1 and
%% fails closed on anything that is not a canonical value.
-module(fenrir_value).
-export([encode/1, from_json/1, decode/1]).

-define(MIN, -9223372036854775808).
-define(MAX, 9223372036854775807).

encode(unit) -> <<"[\"unit\"]">>;
encode({bool, true}) -> <<"[\"bool\",true]">>;
encode({bool, false}) -> <<"[\"bool\",false]">>;
encode({int, N}) when is_integer(N), N >= ?MIN, N =< ?MAX -> <<"[\"int\",\"", (integer_to_binary(N))/binary, "\"]">>;
encode({bytes, B}) -> <<"[\"bytes\",\"", (binary:encode_hex(B, lowercase))/binary, "\"]">>;
encode({tuple, Vs}) -> iolist_to_binary(["[\"tuple\"", [[$,, encode(V)] || V <- Vs], "]"]);
encode({data, T, C, Vs}) ->
    name(T), name(C),
    iolist_to_binary(["[\"data\",\"", T, "\",\"", C, "\"", [[$,, encode(V)] || V <- Vs], "]"]).

decode(Bin) -> from_json(json:decode(Bin)).

from_json([<<"unit">>]) -> unit;
from_json([<<"bool">>, B]) when is_boolean(B) -> {bool, B};
from_json([<<"int">>, S]) when is_binary(S) -> {int, int(S)};
from_json([<<"bytes">>, H]) when is_binary(H) -> {bytes, hex(H)};
from_json([<<"tuple">> | Vs]) -> {tuple, [from_json(V) || V <- Vs]};
from_json([<<"data">>, T, C | Vs]) when is_binary(T), is_binary(C) -> name(T), name(C), {data, T, C, [from_json(V) || V <- Vs]};
from_json(X) -> error({not_a_canonical_value, X}).

int(<<"0">>) -> 0;
int(<<"-", D/binary>>) -> N = pos(D), true = -N >= ?MIN, -N;
int(D) -> N = pos(D), true = N =< ?MAX, N.
pos(<<C, _/binary>> = D) when C >= $1, C =< $9 ->
    true = lists:all(fun(X) -> X >= $0 andalso X =< $9 end, binary_to_list(D)),
    binary_to_integer(D);
pos(D) -> error({not_a_canonical_decimal, D}).

hex(H) ->
    true = byte_size(H) rem 2 =:= 0,
    true = lists:all(fun(X) -> (X >= $0 andalso X =< $9) orelse (X >= $a andalso X =< $f) end, binary_to_list(H)),
    binary:decode_hex(H).

name(N) ->
    case re:run(N, "^[A-Za-z_][A-Za-z0-9_-]{0,63}$") of
        {match, _} -> ok;
        nomatch -> error({not_a_name, N})
    end.
