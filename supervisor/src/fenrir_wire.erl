%% Fenrir remote perform, wire format version 4: the supervisor's side.
%% The format is specified in backends/solo5/remote/wire.h. Decoding is strict:
%% anything that is not exactly a well-formed block is `malformed`.
-module(fenrir_wire).
-export([block/0, header/1, decode_header/1, record/1, decode_record/1,
         call_payload/3, call_payload/4, decode_call/1, decode_stored/1, decode_cell/1, outcome_payload/2, decode_result/2,
         name_ok/1, operation_ok/1]).

-define(VERSION, 4).

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
%% (0 or absent: none), and where: reply, just before it would reply, which is
%% after its commit; commit, inside the commit, with every record written and
%% the store header not.
%% A store header: count is the number of log records, grant the number of
%% STORED records among them.
header(H = #{magic := Magic, kind := Kind, incarnation := Inc, count := Count, grant := Grant}) ->
    M = case Magic of mailbox -> ?MAILBOX; store -> ?STORE end,
    K = case Kind of inbox -> 1; outbox -> 2; store -> 3 end,
    Hold = maps:get(hold, H, 0),
    Where = case maps:get(where, H, reply) of reply -> 0; commit -> 1 end,
    true = Hold =:= 0 orelse (Kind =:= inbox andalso Hold =< Grant),
    true = Where =:= 0 orelse Hold =/= 0,
    seal(<<M:32/little, ?VERSION:16/little, K:16/little, Inc:32/little, Count:32/little, Grant:32/little,
           Hold:32/little, 0:32, Where:32/little, 0:((?BLOCK - 32) * 8)>>).

decode_header(<<M:32/little, ?VERSION:16/little, K:16/little, Inc:32/little, Count:32/little, Grant:32/little,
                Hold:32/little, _Crc:32, Where:32/little, Rest/binary>> = Block) when byte_size(Block) =:= ?BLOCK ->
    case sealed(Block) andalso zero(Rest) andalso Where =< 1 andalso (Where =:= 0 orelse Hold =/= 0) of
        false -> malformed;
        true ->
            case {M, K} of
                {?MAILBOX, 1} when Inc > 0, Grant =< Count, Hold =< Grant ->
                    {ok, #{magic => mailbox, kind => inbox, incarnation => Inc, count => Count, grant => Grant, hold => Hold,
                           where => case Where of 0 -> reply; 1 -> commit end}};
                _ when Hold =/= 0 -> malformed;
                {?MAILBOX, 2} when Inc > 0, Grant =:= Count ->
                    {ok, #{magic => mailbox, kind => outbox, incarnation => Inc, count => Count, grant => Grant}};
                {?STORE, 3} when Inc =:= 0, Grant =< Count ->
                    {ok, #{magic => store, kind => store, incarnation => 0, count => Count, grant => Grant}};
                _ -> malformed
            end
    end;
decode_header(_) -> malformed.

type_code(request) -> 1; type_code(outcome) -> 2; type_code(deliver) -> 3;
type_code(reply) -> 4; type_code(halt) -> 5; type_code(stored) -> 6; type_code(cell) -> 7.
type_name(1) -> request; type_name(2) -> outcome; type_name(3) -> deliver;
type_name(4) -> reply; type_name(5) -> halt; type_name(6) -> stored; type_name(7) -> cell; type_name(_) -> none.

%% #{type, seq, incarnation, ref, payload}
record(#{type := Type, seq := Seq, incarnation := Inc, ref := Ref, payload := Payload})
  when byte_size(Payload) =< 480, Seq > 0 ->
    Pad = ?BLOCK - 32 - byte_size(Payload),
    seal(<<?RECORD:32/little, ?VERSION:16/little, (type_code(Type)):16/little, Seq:32/little, Inc:32/little,
           Ref:32/little, (byte_size(Payload)):32/little, 0:32, 0:32, Payload/binary, 0:(Pad * 8)>>).

decode_record(<<?RECORD:32/little, ?VERSION:16/little, T:16/little, Seq:32/little, Inc:32/little, Ref:32/little,
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

%% An operation's name on the wire: "Effect.operation", 3..63 bytes of [A-Za-z0-9_.] with one dot inside.
operation_ok(Operation) when is_binary(Operation), byte_size(Operation) >= 3, byte_size(Operation) =< 63 ->
    Word = fun(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse (C >= $0 andalso C =< $9) orelse C =:= $_ end,
    case binary:split(Operation, <<".">>, [global]) of
        [Effect, Name] when Effect =/= <<>>, Name =/= <<>> -> lists:all(Word, binary_to_list(Effect) ++ binary_to_list(Name));
        _ -> false
    end;
operation_ok(_) -> false.

padded(Field) ->
    [Text | Pad] = binary:split(Field, <<0>>),
    case zero(iolist_to_binary(Pad)) of true -> Text; false -> bad end.

%% REQUEST and DELIVER payload: name[16], mode u32 (1 keyed, 2 read-only), zero u32,
%% key i64, argument i64, operation[64]. A read-only call has no key and a unit
%% argument: both zero.
call_payload(Name, Operation, Key, Value) ->
    true = name_ok(Name) andalso operation_ok(Operation),
    <<Name/binary, 0:((16 - byte_size(Name)) * 8), 1:32/little, 0:32, Key:64/little-signed, Value:64/little-signed,
      Operation/binary, 0:((64 - byte_size(Operation)) * 8)>>.
call_payload(Name, Operation, read) ->
    true = name_ok(Name) andalso operation_ok(Operation),
    <<Name/binary, 0:((16 - byte_size(Name)) * 8), 2:32/little, 0:32, 0:64, 0:64, Operation/binary, 0:((64 - byte_size(Operation)) * 8)>>.

%% {ok, Name, Operation, Key, Argument} for a keyed call, {ok, Name, Operation, read} for a read-only one.
decode_call(#{ref := 0, payload := <<Field:16/binary, Mode:32/little, 0:32, Key:64/little-signed, Value:64/little-signed, Named:64/binary>>}) ->
    Name = padded(Field), Operation = padded(Named),
    case name_ok(Name) andalso operation_ok(Operation) of
        true when Mode =:= 1 -> {ok, Name, Operation, Key, Value};
        true when Mode =:= 2, Key =:= 0, Value =:= 0 -> {ok, Name, Operation, read};
        _ -> malformed
    end;
decode_call(_) -> malformed.

%% STORED payload: caller name[16], key i64, argument i64, value i64, operation[64].
decode_stored(#{type := stored, ref := 0, payload := <<Field:16/binary, Key:64/little-signed, Argument:64/little-signed, Value:64/little-signed, Named:64/binary>>}) ->
    Name = padded(Field), Operation = padded(Named),
    case name_ok(Name) andalso operation_ok(Operation) of
        true -> {ok, Name, Key, Operation, Argument, Value};
        false -> malformed
    end;
decode_stored(_) -> malformed.

%% CELL payload: key i64, value i64.
decode_cell(#{type := cell, ref := 0, payload := <<Key:64/little-signed, Value:64/little-signed>>}) -> {ok, Key, Value};
decode_cell(_) -> malformed.

%% OUTCOME: kind u32 (1 reply, 2 not_delivered, 3 timed_out), status u32, value i64.
%% A reply is {ok, Value} (status 0), conflict (status 1, value 0), or, from a
%% read-only operation, {read, Value} (status 0: there is no key to conflict on).
outcome_payload(reply, {ok, Value}) -> <<1:32/little, 0:32/little, Value:64/little-signed>>;
outcome_payload(reply, {read, Value}) -> <<1:32/little, 0:32/little, Value:64/little-signed>>;
outcome_payload(reply, conflict) -> <<1:32/little, 1:32/little, 0:64>>;
outcome_payload(not_delivered, none) -> <<2:32/little, 0:32, 0:64>>;
outcome_payload(timed_out, none) -> <<3:32/little, 0:32, 0:64>>.

%% REPLY: how u32 (1 applied, 2 replayed, 3 conflict, 4 read, 5 trapped), zero u32, value i64.
%% {ok, How, {ok, Value} | conflict | {read, Value} | trapped}. trapped: the peer's
%% program trapped; nothing was committed and there is no reply to carry.
decode_result(reply, #{ref := Ref, payload := <<N:32/little, 0:32, Value:64/little-signed>>}) when Ref > 0 ->
    case N of
        1 -> {ok, applied, {ok, Value}};
        2 -> {ok, replayed, {ok, Value}};
        3 when Value =:= 0 -> {ok, conflict, conflict};
        4 -> {ok, read, {read, Value}};
        5 when Value =:= 0 -> {ok, trapped, trapped};
        _ -> malformed
    end;
decode_result(_, _) -> malformed.
