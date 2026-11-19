%% Control protocol v2 framing for the OTP host (spec/solo5/pure-call-control-v1.md
%% sections 2-4, -v2.md sections 2 and 4). Host requests are written in the one canonical
%% spelling; guest frames are parsed strictly, in the v1 order, and anything else fails
%% closed with the v1 code. No semantic decision is made here.
-module(fenrir_proto).
-export([frame/3, init_payload/7, run_payload/1, reply_payload/2, terminate_payload/0,
         parse/2, decode_json/1]).

-define(GUEST_MAX, 61440).
-define(HOST_MAX, 512).

%% One host frame: "FGC1 H" Type " " Seq(8) " " Len(8) "\n" Payload "\n".
frame(Type, Seq, Payload) when byte_size(Payload) =< ?HOST_MAX, Seq =< 99999999 ->
    <<"FGC1 H", Type, " ", (fixed(Seq))/binary, " ", (fixed(byte_size(Payload)))/binary, "\n", Payload/binary, "\n">>.

fixed(N) -> list_to_binary(io_lib:format("~8..0B", [N])).

kv(K, V) -> [$", K, "\":\"", V, $"].

init_payload(Artifact, Batch, Fuel, Mode, Program, Protocol, Schema) ->
    iolist_to_binary(["{", kv("artifact_sha256", Artifact), ",", kv("batch_sha256", Batch), ",", kv("fuel", Fuel), ",",
                      kv("kind", "Init"), ",", kv("mode", Mode), ",", kv("program", integer_to_list(Program)), ",",
                      kv("protocol", Protocol), ",", kv("schema", Schema), "}"]).

run_payload(N) -> iolist_to_binary(["{\"kind\":\"Run\",\"steps\":\"", integer_to_list(N), "\"}"]).

reply_payload(Seq, Value) ->
    iolist_to_binary(["{\"kind\":\"Reply\",\"request\":\"", integer_to_list(Seq), "\",\"value\":", fenrir_value:encode(Value), "}"]).

terminate_payload() -> <<"{\"kind\":\"Terminate\"}">>.

%% parse(Buffer, ExpectedSeq) -> {frame, Type, Json, Rest} | more | {error, Code}
%% v1 section 4, host side, in order.
parse(B, _) when byte_size(B) < 26 ->
    case B of
        <<"FGC1 ", _/binary>> -> more;
        _ -> case prefix_ok(B, <<"FGC1 ">>) of true -> more; false -> {error, 'BadMagic'} end
    end;
parse(<<"FGC1 ", Dir, Type, Sp1, Seq:8/binary, Sp2, Len:8/binary, Lf, Rest/binary>>, Expected) ->
    if
        Dir =/= $G -> {error, 'BadDirection'};
        true ->
            case lists:member(Type, "HYSDBE") of
                false -> {error, 'UnknownType'};
                true when Sp1 =/= $\s; Sp2 =/= $\s; Lf =/= $\n -> {error, 'BadHeader'};
                true ->
                    case {digits(Seq), digits(Len)} of
                        {true, true} ->
                            S = binary_to_integer(Seq), L = binary_to_integer(Len),
                            if
                                S =/= Expected -> {error, 'BadSequence'};
                                L > ?GUEST_MAX -> {error, 'Oversize'};
                                byte_size(Rest) < L + 1 -> more;
                                true ->
                                    <<P:L/binary, T, After/binary>> = Rest,
                                    if
                                        T =/= $\n -> {error, 'BadTrailer'};
                                        true -> payload(Type, P, After)
                                    end
                            end;
                        _ -> {error, 'BadHeader'}
                    end
            end
    end;
parse(_, _) -> {error, 'BadMagic'}.

prefix_ok(B, M) -> binary:part(M, 0, min(byte_size(B), byte_size(M))) =:= binary:part(B, 0, min(byte_size(B), byte_size(M))).

digits(B) -> lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(B)).

payload(Type, P, After) ->
    case lists:all(fun(C) -> C >= 16#20 andalso C =< 16#7e end, binary_to_list(P)) of
        false -> {error, 'BadPayload'};
        true ->
            case decode_json(P) of
                {ok, J} when is_map(J) ->
                    Kind = maps:get(<<"kind">>, J, none),
                    case kind(Type) =:= Kind of
                        true -> {frame, Type, J, After};
                        false -> {error, 'BadPayload'}
                    end;
                _ -> {error, 'BadPayload'}
            end
    end.

kind($H) -> <<"Hello">>; kind($Y) -> <<"Ready">>; kind($S) -> <<"Steps">>;
kind($D) -> <<"Digest">>; kind($B) -> <<"Bye">>; kind($E) -> <<"Error">>.

%% JSON with duplicate keys refused.
decode_json(Bin) ->
    Push = fun(K, V, Acc) ->
                   case lists:keymember(K, 1, Acc) of
                       true -> throw(duplicate_key);
                       false -> [{K, V} | Acc]
                   end
           end,
    Finish = fun(Acc, Old) -> {maps:from_list(Acc), Old} end,
    try json:decode(Bin, ok, #{object_push => Push, object_finish => Finish}) of
        {V, ok, <<>>} -> {ok, V};
        _ -> error
    catch _:_ -> error
    end.
