%% Durable A4 phase/identity codec. No guest fields, paths or Erlang terms are
%% decoded from SQLite. The receiver checks this state inside its transaction.
-module(fenrir_upgrade_state).
-export([schema/1, decode/2, encode/1, image_pin/4, prepare/2, fence/2]).

schema(1) -> <<"fenrir.host.service-store/1">>;
schema(2) -> <<"fenrir.host.service-store/2">>.

%% A pin names descriptor, artifact, guest image and tender, in that order,
%% with raw SHA-256 bytes. The operator supplies already admitted pins; this
%% codec checks only their shape, not the binaries or the manifest.
image_pin(Descriptor, Artifact, Image, Tender) ->
    iolist_to_binary([crypto:hash(sha256, B) || B <- [Descriptor, Artifact, Image, Tender]]).

prepare(Handler, Migration) when is_binary(Handler), byte_size(Handler) =:= 128,
                                is_binary(Migration), byte_size(Migration) =:= 128 ->
    {ok, {prepared, crypto:strong_rand_bytes(16), Handler, Migration}};
prepare(_, _) -> {error, invalid_image_pin}.

encode(v1) -> <<"v1">>;
encode({Phase, Id, Handler, Migration}) ->
    <<(atom_to_binary(Phase))/binary, $:, (binary:encode_hex(<<Id/binary, Handler/binary, Migration/binary>>, lowercase))/binary>>.

decode(<<"fenrir.host.service-store/1">>, <<"v1">>) -> {ok, v1};
decode(Schema, Value) when is_binary(Value) ->
    case binary:split(Value, <<":">>) of
        [<<"prepared">>, Pins] when Schema =:= <<"fenrir.host.service-store/1">> -> decode_pins(prepared, Pins);
        [<<"migrated">>, Pins] when Schema =:= <<"fenrir.host.service-store/2">> -> decode_pins(migrated, Pins);
        [<<"v2">>, Pins] when Schema =:= <<"fenrir.host.service-store/2">> -> decode_pins(v2, Pins);
        _ -> {error, invalid_upgrade_metadata}
    end;
decode(_, _) -> {error, invalid_upgrade_metadata}.

decode_pins(Phase, Pins) when byte_size(Pins) =:= 544 ->
    try binary:decode_hex(Pins) of
        <<Id:16/binary, Handler:128/binary, Migration:128/binary>> ->
            State = {Phase, Id, Handler, Migration},
            case binary:encode_hex(<<Id/binary, Handler/binary, Migration/binary>>, lowercase) of
                Pins -> {ok, State};
                _ -> {error, invalid_upgrade_metadata}
            end
    catch error:badarg -> {error, invalid_upgrade_metadata}
    end;
decode_pins(_, _) -> {error, invalid_upgrade_metadata}.

fence(1, v1) -> ok;
fence(1, {prepared, _, _, _}) -> ok;
fence(2, {v2, _, _, _}) -> ok;
fence(_, _) -> {error, version_not_in_force}.
