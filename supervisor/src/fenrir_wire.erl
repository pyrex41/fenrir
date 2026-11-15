%% Fenrir remote perform, wire format version 1: the supervisor's side.
%% The format is specified in backends/solo5/remote/wire.h. Decoding is strict:
%% anything that is not exactly a well-formed block is `malformed`.
-module(fenrir_wire).
-export([block/0, header/1, decode_header/1, record/1, decode_record/1,
         call_payload/3, decode_call/1, result_payload/2, decode_result/2, name_ok/1]).

-define(BLOCK, 512).
-define(RECORD, 16#31575246).
-define(MAILBOX, 16#424d5246).
-define(STORE, 16#54535246).

block() -> ?BLOCK.

seal(<<Head:24/binary, _:32, Tail/binary>>) ->
    Crc = erlang:crc32(<<Head/binary, 0:32, Tail/binary>>),
    <<Head/binary, Crc:32/little, Tail/binary>>.

sealed(<<Head:24/binary, Crc:32/little, Tail/binary>>) ->
    erlang:crc32(<<Head/binary, 0:32, Tail/binary>>) =:= Crc.

zero(Bin) -> Bin =:= binary:copy(<<0>>, byte_size(Bin)).

%% #{magic := mailbox | store, kind := inbox | outbox | store, incarnation, count, grant}
%% and, for an inbox only, hold: the granted record the image is to stop at
%% before it replies (0 or absent: none).
header(H = #{magic := Magic, kind := Kind, incarnation := Inc, count := Count, grant := Grant}) ->
    M = case Magic of mailbox -> ?MAILBOX; store -> ?STORE end,
    K = case Kind of inbox -> 1; outbox -> 2; store -> 3 end,
    Hold = maps:get(hold, H, 0),
    true = Hold =:= 0 orelse (Kind =:= inbox andalso Hold =< Grant),
    seal(<<M:32/little, 1:16/little, K:16/little, Inc:32/little, Count:32/little, Grant:32/little,
           Hold:32/little, 0:32, 0:((?BLOCK - 28) * 8)>>).

decode_header(<<M:32/little, 1:16/little, K:16/little, Inc:32/little, Count:32/little, Grant:32/little,
                Hold:32/little, _Crc:32, Rest/binary>> = Block) when byte_size(Block) =:= ?BLOCK ->
    case sealed(Block) andalso zero(Rest) of
        false -> malformed;
        true ->
            case {M, K} of
                {?MAILBOX, 1} when Inc > 0, Grant =< Count, Hold =< Grant ->
                    {ok, #{magic => mailbox, kind => inbox, incarnation => Inc, count => Count, grant => Grant, hold => Hold}};
                _ when Hold =/= 0 -> malformed;
                {?MAILBOX, 2} when Inc > 0, Grant =:= Count ->
                    {ok, #{magic => mailbox, kind => outbox, incarnation => Inc, count => Count, grant => Grant}};
                {?STORE, 3} when Inc =:= 0, Count =< Grant ->
                    {ok, #{magic => store, kind => store, incarnation => 0, count => Count, grant => Grant}};
                _ -> malformed
            end
    end;
decode_header(_) -> malformed.

type_code(request) -> 1; type_code(outcome) -> 2; type_code(deliver) -> 3;
type_code(reply) -> 4; type_code(halt) -> 5; type_code(stored) -> 6.
type_name(1) -> request; type_name(2) -> outcome; type_name(3) -> deliver;
type_name(4) -> reply; type_name(5) -> halt; type_name(6) -> stored; type_name(_) -> none.

%% #{type, seq, incarnation, ref, payload}
record(#{type := Type, seq := Seq, incarnation := Inc, ref := Ref, payload := Payload})
  when byte_size(Payload) =< 480, Seq > 0 ->
    Pad = ?BLOCK - 32 - byte_size(Payload),
    seal(<<?RECORD:32/little, 1:16/little, (type_code(Type)):16/little, Seq:32/little, Inc:32/little,
           Ref:32/little, (byte_size(Payload)):32/little, 0:32, 0:32, Payload/binary, 0:(Pad * 8)>>).

decode_record(<<?RECORD:32/little, 1:16/little, T:16/little, Seq:32/little, Inc:32/little, Ref:32/little,
                Length:32/little, _Crc:32, 0:32, Body/binary>> = Block)
  when byte_size(Block) =:= ?BLOCK, Seq > 0, Length =< 480 ->
    <<Payload:Length/binary, Rest/binary>> = Body,
    case sealed(Block) andalso zero(Rest) andalso type_name(T) of
        false -> malformed;
        none -> malformed;
        Type -> {ok, #{type => Type, seq => Seq, incarnation => Inc, ref => Ref, payload => Payload}}
    end;
decode_record(_) -> malformed.

name_ok(Name) when is_binary(Name), byte_size(Name) >= 1, byte_size(Name) =< 15 ->
    lists:all(fun(C) -> (C >= $a andalso C =< $z) orelse (C >= $0 andalso C =< $9) orelse C =:= $- end,
              binary_to_list(Name));
name_ok(_) -> false.

%% REQUEST, DELIVER and STORED payload: name[16], key i64, value i64.
call_payload(Name, Key, Value) ->
    true = name_ok(Name),
    <<Name/binary, 0:((16 - byte_size(Name)) * 8), Key:64/little-signed, Value:64/little-signed>>.

decode_call(#{ref := 0, payload := <<Field:16/binary, Key:64/little-signed, Value:64/little-signed>>}) ->
    [Name | Pad] = binary:split(Field, <<0>>),
    case name_ok(Name) andalso zero(iolist_to_binary(Pad)) of
        true -> {ok, Name, Key, Value};
        false -> malformed
    end;
decode_call(_) -> malformed.

%% OUTCOME: reply | peer_down | timed_out. REPLY: applied | replayed.
result_payload(Code, Value) ->
    N = case Code of reply -> 1; peer_down -> 2; timed_out -> 3; applied -> 1; replayed -> 2 end,
    <<N:32/little, 0:32, Value:64/little-signed>>.

decode_result(reply, #{ref := Ref, payload := <<N:32/little, 0:32, Value:64/little-signed>>}) when Ref > 0 ->
    case N of 1 -> {ok, applied, Value}; 2 -> {ok, replayed, Value}; _ -> malformed end;
decode_result(_, _) -> malformed.
