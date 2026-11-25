%% STUB PEER. Not a Solo5 guest.
%%
%% Solo5 spt guests are not built for these regressions: the schedule kills the
%% whole Erlang VM, and the peer's store has to be a file that survives that
%% kill. This module is loaded in place of supervisor/src/fenrir_member.erl.
%% fenrir_relay, fenrir_journal and fenrir_wire are the real modules.
%%
%% The store file is wire format version 4, created on the first boot only and
%% left in place afterwards, which is what the real member does. Mailboxes are
%% memory and start empty on each boot.
%%
%% FENRIR_STUB_SCRIPT:
%%   vm1      Ledger.add key 7 argument 5
%%   vm2      key 7 again, then fresh key 9, same argument
%%   upgrade  Ledger.add key 1 argument 1
%% FENRIR_PEER_VERSION=2 selects F(version, arg) = 10*version+arg. Any other
%% value is the ledger add: cell 0 becomes cell 0 + argument.
-module(fenrir_member).
-behaviour(gen_server).
-export([start_link/1, boot/1, kill/1, put/5, grant/1, grant_hold/2, take/2,
         wait_exit/2, info/1, store/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(OP, <<"Ledger.add">>).

start_link(Spec) -> gen_server:start_link(?MODULE, Spec, []).
boot(Pid) -> gen_server:call(Pid, boot, 20000).
kill(Pid) -> gen_server:call(Pid, kill, 20000).
put(Pid, Type, Ref, Payload, Grant) -> gen_server:call(Pid, {put, Type, Ref, Payload, Grant}, 20000).
grant(Pid) -> gen_server:call(Pid, {grant, false}, 20000).
grant_hold(Pid, Where) -> gen_server:call(Pid, {grant, Where}, 20000).
take(Pid, TimeoutMs) -> gen_server:call(Pid, {take, TimeoutMs}, TimeoutMs + 20000).
wait_exit(Pid, _TimeoutMs) -> gen_server:call(Pid, wait_exit, 20000).
info(Pid) -> gen_server:call(Pid, info, 20000).
store(Pid) -> gen_server:call(Pid, store, 20000).

init(Spec) ->
    Script = case os:getenv("FENRIR_STUB_SCRIPT", "vm1") of
                 "vm2" -> [{req, 7, 5}, {req, 9, 5}];
                 "upgrade" -> [{req, 1, 1}];
                 _ -> [{req, 7, 5}]
             end,
    {ok, #{name => maps:get(name, Spec), kind => maps:get(kind, Spec),
           dir => maps:get(dir, Spec), has_store => maps:get(store, Spec),
           incarnation => 0, running => false, exit => none,
           script => Script, script_at => 1,
           inbox => [], grant => 0, outbox => [], out_seq => 1}}.

handle_call(boot, _From, S0) ->
    S = S0#{incarnation := maps:get(incarnation, S0) + 1, running := true, exit := none,
            script_at := 1, inbox := [], grant := 0, outbox := [], out_seq := 1},
    case maps:get(has_store, S) of
        true -> ensure_store(store_path(S));
        false -> ok
    end,
    {reply, ok, S};
handle_call(kill, _From, S) ->
    {reply, ok, S#{running := false, exit := killed}};
handle_call({put, outcome, _Ref, Payload, grant}, _From, S = #{kind := caller}) ->
    log_outcome(S, Payload),
    {reply, {ok, 1}, S};
handle_call({put, deliver, 0, Payload, hold}, _From, S = #{kind := peer, inbox := Inbox}) ->
    Seq = length(Inbox) + 1,
    {ok, <<"caller">>, ?OP, Key, Arg} = fenrir_wire:decode_call(#{type => deliver, ref => 0, payload => Payload}),
    {reply, {ok, Seq}, S#{inbox := Inbox ++ [{Seq, Key, Arg}]}};
handle_call({grant, false}, _From, S = #{kind := peer, grant := G, inbox := Inbox}) when G < length(Inbox) ->
    {Seq, Key, Arg} = lists:nth(G + 1, Inbox),
    Reply = act(S, Key, Arg),
    OutSeq = maps:get(out_seq, S),
    Block = fenrir_wire:record(#{type => reply, seq => OutSeq, incarnation => maps:get(incarnation, S),
                                 ref => Seq, payload => Reply}),
    {ok, Decoded} = fenrir_wire:decode_record(Block),
    {reply, ok, S#{grant := G + 1, out_seq := OutSeq + 1, outbox := maps:get(outbox, S) ++ [Decoded]}};
handle_call({grant, _}, _From, S) ->
    {reply, {error, nothing_to_grant}, S};
handle_call({take, _Timeout}, _From, S = #{kind := caller, script := Script, script_at := At}) ->
    case At > length(Script) of
        true ->
            Block = fenrir_wire:record(#{type => halt, seq => At, incarnation => maps:get(incarnation, S),
                                         ref => 0, payload => <<>>}),
            {ok, Decoded} = fenrir_wire:decode_record(Block),
            {reply, {ok, Decoded}, S#{script_at := At + 1}};
        false ->
            {req, Key, Arg} = lists:nth(At, Script),
            Payload = fenrir_wire:call_payload(<<"peer">>, ?OP, Key, Arg),
            Block = fenrir_wire:record(#{type => request, seq => At, incarnation => maps:get(incarnation, S),
                                         ref => 0, payload => Payload}),
            {ok, Decoded} = fenrir_wire:decode_record(Block),
            {reply, {ok, Decoded}, S#{script_at := At + 1}}
    end;
handle_call({take, Timeout}, _From, S = #{kind := peer, outbox := Out}) ->
    case Out of
        [Decoded | Rest] -> {reply, {ok, Decoded}, S#{outbox := Rest}};
        [] ->
            timer:sleep(min(Timeout, 50)),
            {reply, timeout, S}
    end;
handle_call(wait_exit, _From, S) ->
    {reply, {ok, 0}, S#{running := false, exit := 0}};
handle_call(info, _From, S) ->
    {reply, #{running => maps:get(running, S), exit => maps:get(exit, S),
              incarnation => maps:get(incarnation, S), consoles => []}, S};
handle_call(store, _From, S) ->
    {reply, read_store(S), S};
handle_call(Request, _From, S) ->
    {reply, {error, {stub_unexpected, Request}}, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.

store_path(#{dir := Dir, name := Name}) ->
    filename:join(Dir, binary_to_list(Name) ++ ".store").

ensure_store(Path) ->
    case filelib:is_regular(Path) of
        true -> ok;
        false ->
            Header = fenrir_wire:header(#{magic => store, kind => store, incarnation => 0, count => 0, grant => 0}),
            Rest = binary:copy(<<0>>, 63 * 512),
            ok = file:write_file(Path, <<Header/binary, Rest/binary>>),
            sync(Path)
    end.

sync(Path) ->
    {ok, Fd} = file:open(Path, [read, raw]),
    ok = file:sync(Fd),
    ok = file:close(Fd).

act(S, Key, Arg) ->
    Log = load_log(store_path(S)),
    case find_record(Log, <<"caller">>, Key) of
        {ok, ?OP, Arg, Value} ->
            note(S, io_lib:format("replay key=~b arg=~b value=~b~n", [Key, Arg, Value])),
            <<2:32/little, 0:32, Value:64/little-signed>>;
        none ->
            Value = case peer_mode() of
                        ledger -> cell_value(Log, 0) + Arg;
                        {versioned, Ver} -> 10 * Ver + Arg
                    end,
            append_commit(store_path(S), Log, Key, Arg, Value),
            note(S, io_lib:format("apply key=~b arg=~b value=~b~n", [Key, Arg, Value])),
            <<1:32/little, 0:32, Value:64/little-signed>>
    end.

peer_mode() ->
    case os:getenv("FENRIR_PEER_VERSION") of
        "2" -> {versioned, 2};
        _ -> ledger
    end.

note(#{dir := Dir, name := Name}, Text) ->
    ok = file:write_file(filename:join(Dir, binary_to_list(Name) ++ ".acts"), Text, [append]).

log_outcome(#{dir := Dir}, Payload) ->
    <<Kind:32/little, Status:32/little, Value:64/little-signed>> = Payload,
    Name = case Kind of 1 -> reply; 2 -> not_delivered; 3 -> timed_out; _ -> other end,
    Line = io_lib:format("~p status=~b value=~b~n", [Name, Status, Value]),
    ok = file:write_file(filename:join(Dir, "caller.outcomes"), Line, [append]).

load_log(Path) ->
    {ok, Bin} = file:read_file(Path),
    <<Header:512/binary, Rest/binary>> = Bin,
    {ok, #{kind := store, count := Count, grant := Stored}} = fenrir_wire:decode_header(Header),
    Recs = [begin
                Block = binary:part(Rest, I * 512, 512),
                {ok, Rec} = fenrir_wire:decode_record(Block),
                Rec
            end || I <- seq0(Count)],
    Stored = length([R || R <- Recs, fenrir_wire:decode_stored(R) =/= malformed]),
    Recs.

seq0(0) -> [];
seq0(N) when N > 0 -> lists:seq(0, N - 1).

find_record(Recs, Caller, Key) ->
    lists:foldl(fun(Rec, Acc) ->
                        case fenrir_wire:decode_stored(Rec) of
                            {ok, Caller, Key, Op, Arg, Value} -> {ok, Op, Arg, Value};
                            _ -> Acc
                        end
                end, none, Recs).

cell_value(Recs, Key) ->
    lists:foldl(fun(Rec, Acc) ->
                        case fenrir_wire:decode_cell(Rec) of
                            {ok, Key, Value} -> Value;
                            _ -> Acc
                        end
                end, 0, Recs).

append_commit(Path, Log, Key, Arg, Total) ->
    Count = length(Log),
    Stored = length([R || R <- Log, fenrir_wire:decode_stored(R) =/= malformed]),
    Cell = fenrir_wire:record(#{type => cell, seq => Count + 1, incarnation => 0, ref => 0,
                                payload => <<0:64/little-signed, Total:64/little-signed>>}),
    Name = <<"caller">>,
    Op = ?OP,
    StoredPayload = <<Name/binary, 0:((16 - byte_size(Name)) * 8),
                       Key:64/little-signed, Arg:64/little-signed, Total:64/little-signed,
                       Op/binary, 0:((64 - byte_size(Op)) * 8)>>,
    Rec = fenrir_wire:record(#{type => stored, seq => Count + 2, incarnation => 0, ref => 0,
                               payload => StoredPayload}),
    {ok, Bin} = file:read_file(Path),
    <<_Old:512/binary, Rest/binary>> = Bin,
    Rest1 = write_block(Rest, Count + 1, Cell),
    Rest2 = write_block(Rest1, Count + 2, Rec),
    NewHeader = fenrir_wire:header(#{magic => store, kind => store, incarnation => 0,
                                     count => Count + 2, grant => Stored + 1}),
    ok = file:write_file(Path, <<NewHeader/binary, Rest2/binary>>),
    sync(Path).

write_block(Rest, Seq, Block) ->
    At = (Seq - 1) * 512,
    Need = At + 512,
    Pad = case byte_size(Rest) < Need of
              true -> <<Rest/binary, (binary:copy(<<0>>, Need - byte_size(Rest)))/binary>>;
              false -> Rest
          end,
    <<Before:At/binary, _:512/binary, After/binary>> = Pad,
    <<Before/binary, Block/binary, After/binary>>.

read_store(S = #{has_store := true}) ->
    Path = store_path(S),
    case filelib:is_regular(Path) of
        false -> absent;
        true ->
            Log = load_log(Path),
            Cells = lists:foldl(fun(Rec, Acc) ->
                                         case fenrir_wire:decode_cell(Rec) of
                                             {ok, K, V} -> lists:keystore(K, 1, Acc, {K, V});
                                             _ -> Acc
                                         end
                                 end, [], Log),
            Records = lists:foldl(fun(Rec, Acc) ->
                                           case fenrir_wire:decode_stored(Rec) of
                                               {ok, C, K, O, A, V} ->
                                                   lists:keystore({C, K}, 1, Acc, {{C, K}, O, A, V});
                                               _ -> Acc
                                           end
                                   end, [], Log),
            #{cells => lists:keysort(1, Cells),
              records => [{C, K, O, A, V} || {{C, K}, O, A, V} <- Records],
              tail => []}
    end;
read_store(_) -> none.
