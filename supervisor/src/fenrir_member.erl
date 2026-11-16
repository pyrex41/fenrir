%% One member of a system: its image running as an OS process under the Solo5
%% tender (a port), its two mailbox files, and, for a peer, its durable store
%% file. This process is the only thing in the supervisor that touches them.
%% It decides nothing: fenrir_relay tells it what to do.
-module(fenrir_member).
-behaviour(gen_server).
-export([start_link/1, boot/1, kill/1, put/5, grant/1, grant_hold/1, take/2, wait_exit/2, info/1, store/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(BLOCKS, 64).
-define(POLL_MS, 1).

start_link(Spec) -> gen_server:start_link(?MODULE, Spec, []).

%% Start (or restart) the image: a new incarnation with empty mailboxes. The
%% durable store is created on the first boot only.
boot(Pid) -> gen_server:call(Pid, boot, 20000).
%% Kill the OS process. The durable store is left as it is.
kill(Pid) -> gen_server:call(Pid, kill, 20000).
%% Append a record to the inbox; granted at once or held (see grant/1).
put(Pid, Type, Ref, Payload, Grant) -> gen_server:call(Pid, {put, Type, Ref, Payload, Grant}, 20000).
%% Let the image consume one more inbox record.
grant(Pid) -> gen_server:call(Pid, {grant, false}, 20000).
%% The same, and the image is to stop just before it replies to that record,
%% without exiting (the inbox header's hold, wire.h): the place for a kill
%% between a peer's commit and its reply.
grant_hold(Pid) -> gen_server:call(Pid, {grant, true}, 20000).
%% The next outbox record: {ok, Record} | timeout | {exited, Status} | {malformed, Why}.
take(Pid, TimeoutMs) -> gen_server:call(Pid, {take, TimeoutMs}, TimeoutMs + 20000).
wait_exit(Pid, TimeoutMs) -> gen_server:call(Pid, {wait_exit, TimeoutMs}, TimeoutMs + 20000).
info(Pid) -> gen_server:call(Pid, info, 20000).
store(Pid) -> gen_server:call(Pid, store, 20000).

init(#{name := Name, kind := Kind, image := Image, tender := Tender, dir := Dir, life_ms := Life, options := Options}) ->
    process_flag(trap_exit, true),
    {ok, #{name => Name, kind => Kind, image => Image, tender => Tender, dir => Dir, life_ms => Life,
           options => Options, incarnation => 0, port => none, os_pid => none, exit => none,
           console => [], consoles => [], count => 0, grant => 0, hold => 0, taken => 0, inbox => none, outbox => none}}.

path(#{dir := Dir, name := Name}, What) -> filename:join(Dir, binary_to_list(Name) ++ "." ++ What).

handle_call(boot, _From, S0 = #{port := none}) ->
    S1 = close_files(S0),
    Inc = maps:get(incarnation, S1) + 1,
    Empty = binary:copy(<<0>>, ?BLOCKS * fenrir_wire:block()),
    ok = file:write_file(path(S1, "inbox"), Empty),
    ok = file:write_file(path(S1, "outbox"), Empty),
    {ok, In} = file:open(path(S1, "inbox"), [read, write, raw, binary]),
    {ok, Out} = file:open(path(S1, "outbox"), [read, raw, binary]),
    S2 = S1#{incarnation := Inc, count := 0, grant := 0, hold := 0, taken := 0, inbox := In, outbox := Out,
             console := [], exit := none},
    ok = write_header(S2),
    Devices = ["--block:inbox=" ++ path(S2, "inbox"), "--block:outbox=" ++ path(S2, "outbox")] ++
        case maps:get(kind, S2) of
            peer ->
                Store = path(S2, "store"),
                case filelib:is_regular(Store) of
                    true -> ok;
                    false ->
                        Header = fenrir_wire:header(#{magic => store, kind => store, incarnation => 0, count => 0, grant => 0}),
                        Rest = binary:copy(<<0>>, (?BLOCKS - 1) * fenrir_wire:block()),
                        ok = file:write_file(Store, <<Header/binary, Rest/binary>>)
                end,
                ["--block:store=" ++ Store];
            caller -> []
        end,
    Cmdline = "life=" ++ integer_to_list(maps:get(life_ms, S2)) ++ maps:get(options, S2),
    Port = open_port({spawn_executable, maps:get(tender, S2)},
                     [{args, ["--mem=32"] ++ Devices ++ [maps:get(image, S2), Cmdline]},
                      exit_status, binary, stderr_to_stdout, {cd, maps:get(dir, S2)}]),
    {os_pid, OsPid} = erlang:port_info(Port, os_pid),
    S3 = S2#{port := Port, os_pid := OsPid},
    %% The image announces itself by writing its (empty) outbox header.
    case announced(S3, deadline(10000)) of
        {ok, S4} -> {reply, ok, S4};
        {Error, S4} -> {reply, {error, Error}, S4}
    end;
handle_call(boot, _From, S) -> {reply, {error, running}, S};
handle_call(kill, _From, S = #{port := none}) -> {reply, ok, S};
handle_call(kill, _From, S = #{os_pid := OsPid}) ->
    os:cmd("kill -9 " ++ integer_to_list(OsPid)),
    S1 = await_exit(S, deadline(5000)),
    {reply, case maps:get(port, S1) of none -> ok; _ -> {error, did_not_die} end, S1};
handle_call({put, Type, Ref, Payload, Grant}, _From, S = #{inbox := In, count := Count, incarnation := Inc})
  when Count + 1 < ?BLOCKS ->
    Seq = Count + 1,
    Block = fenrir_wire:record(#{type => Type, seq => Seq, incarnation => Inc, ref => Ref, payload => Payload}),
    %% The record first, then the header that counts it.
    ok = file:pwrite(In, Seq * fenrir_wire:block(), Block),
    S1 = S#{count := Seq, grant := case Grant of grant -> maps:get(grant, S) + 1; hold -> maps:get(grant, S) end},
    ok = write_header(S1),
    {reply, {ok, Seq}, S1};
handle_call({put, _, _, _, _}, _From, S) -> {reply, {error, inbox_full}, S};
handle_call({grant, Hold}, _From, S = #{grant := Grant, count := Count}) when Grant < Count ->
    S1 = S#{grant := Grant + 1, hold := case Hold of true -> Grant + 1; false -> maps:get(hold, S) end},
    ok = write_header(S1),
    {reply, ok, S1};
handle_call({grant, _}, _From, S) -> {reply, {error, nothing_to_grant}, S};
handle_call({take, TimeoutMs}, _From, S) ->
    {Reply, S1} = take_record(S, deadline(TimeoutMs)),
    {reply, Reply, S1};
handle_call({wait_exit, TimeoutMs}, _From, S) ->
    S1 = await_exit(S, deadline(TimeoutMs)),
    {reply, case maps:get(port, S1) of none -> {ok, maps:get(exit, S1)}; _ -> timeout end, S1};
handle_call(info, _From, S) ->
    S1 = drain(S),
    Current = case {maps:get(incarnation, S1), maps:get(console, S1)} of
                  {0, _} -> [];
                  {_, finished} -> [];
                  _ -> [console_entry(S1)]
              end,
    {reply, #{running => maps:get(port, S1) =/= none, exit => maps:get(exit, S1), incarnation => maps:get(incarnation, S1),
              consoles => lists:reverse(Current ++ maps:get(consoles, S1))}, S1};
handle_call(store, _From, S) -> {reply, read_store(S), S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(Message, S) -> {noreply, port_message(Message, S)}.
terminate(_Reason, #{os_pid := OsPid, port := Port}) when Port =/= none ->
    os:cmd("kill -9 " ++ integer_to_list(OsPid)), ok;
terminate(_, _) -> ok.

%% ---- the port ----

port_message({Port, {data, Bytes}}, S = #{port := Port, console := Console}) -> S#{console := [Bytes | Console]};
port_message({Port, {exit_status, Status}}, S = #{port := Port}) ->
    S1 = S#{port := none, os_pid := none, exit := Status},
    S1#{consoles := [console_entry(S1) | maps:get(consoles, S1)], console := finished};
port_message(_, S) -> S.

%% Each incarnation's console is written to a file when it ends, or when asked for.
console_entry(S = #{console := finished}) -> hd(maps:get(consoles, S));
console_entry(S = #{console := Console, incarnation := Inc, exit := Exit}) ->
    File = path(S, "console." ++ integer_to_list(Inc)),
    ok = file:write_file(File, lists:reverse(Console)),
    #{incarnation => Inc, file => File, exit => Exit}.

drain(S) ->
    receive Message = {Port, _} when is_port(Port) -> drain(port_message(Message, S))
    after 0 -> S
    end.

deadline(Ms) -> erlang:monotonic_time(millisecond) + Ms.
expired(Deadline) -> erlang:monotonic_time(millisecond) >= Deadline.

await_exit(S = #{port := none}, _) -> S;
await_exit(S, Deadline) ->
    case expired(Deadline) of
        true -> S;
        false ->
            receive Message = {Port, _} when is_port(Port) -> await_exit(port_message(Message, S), Deadline)
            after ?POLL_MS -> await_exit(S, Deadline)
            end
    end.

%% ---- the mailboxes ----

close_files(S = #{inbox := In, outbox := Out}) ->
    [file:close(F) || F <- [In, Out], F =/= none],
    S#{inbox := none, outbox := none}.

write_header(#{inbox := In, incarnation := Inc, count := Count, grant := Grant, hold := Hold}) ->
    file:pwrite(In, 0, fenrir_wire:header(#{magic => mailbox, kind => inbox, incarnation => Inc, count => Count, grant => Grant,
                                            hold => Hold})).

%% The image may be writing its header while it is read here: a block that does
%% not decode is read again until the deadline before it counts as malformed.
%% An all-zero block is "not written yet".
outbox_header(#{outbox := Out, incarnation := Inc}) ->
    case file:pread(Out, 0, fenrir_wire:block()) of
        {ok, Block} when byte_size(Block) =:= 512 ->
            case fenrir_wire:decode_header(Block) of
                {ok, #{kind := outbox, incarnation := Inc, count := Count}} -> {ok, Count};
                {ok, _} -> wrong;
                malformed -> case Block =:= binary:copy(<<0>>, 512) of true -> empty; false -> torn end
            end;
        _ -> torn
    end.

announced(S, Deadline) ->
    S1 = drain(S),
    case {outbox_header(S1), maps:get(port, S1)} of
        {{ok, _}, _} -> {ok, S1};
        {wrong, _} -> {{malformed, outbox_header}, S1};
        {_, none} -> {{exited, maps:get(exit, S1)}, S1};
        _ ->
            case expired(Deadline) of
                true -> {timeout, S1};
                false -> timer:sleep(?POLL_MS), announced(S1, Deadline)
            end
    end.

take_record(S, Deadline) -> take_record(S, Deadline, 0).

take_record(S0, Deadline, Torn) ->
    S = drain(S0),
    Taken = maps:get(taken, S),
    case outbox_header(S) of
        {ok, Count} when Count > Taken, Count < ?BLOCKS ->
            Seq = Taken + 1,
            {ok, Block} = file:pread(maps:get(outbox, S), Seq * fenrir_wire:block(), fenrir_wire:block()),
            Inc = maps:get(incarnation, S),
            case fenrir_wire:decode_record(Block) of
                {ok, Record = #{seq := Seq, incarnation := Inc}} -> {{ok, Record}, S#{taken := Seq}};
                _ -> {{malformed, outbox_record}, S}
            end;
        {ok, Count} when Count =:= Taken -> waiting(S, Deadline, 0);
        {ok, _} -> {{malformed, outbox_count}, S};
        wrong -> {{malformed, outbox_header}, S};
        empty -> {{malformed, outbox_header}, S};
        torn when Torn >= 50 -> {{malformed, outbox_header}, S};
        torn -> timer:sleep(?POLL_MS), take_record(S, Deadline, Torn + 1)
    end.

waiting(S, Deadline, Torn) ->
    case {maps:get(port, S), expired(Deadline)} of
        {none, _} -> {{exited, maps:get(exit, S)}, S};
        {_, true} -> {timeout, S};
        _ -> timer:sleep(?POLL_MS), take_record(S, Deadline, Torn)
    end.

%% ---- the durable store, read for the run report ----

read_store(S = #{kind := peer}) ->
    case file:read_file(path(S, "store")) of
        {ok, <<Header:512/binary, Rest/binary>>} ->
            case fenrir_wire:decode_header(Header) of
                {ok, #{kind := store, count := Count, grant := Applications}} when Count * 512 =< byte_size(Rest) ->
                    Records = [decode_stored(binary:part(Rest, I * 512, 512), I + 1) || I <- lists:seq(0, Count - 1)],
                    case lists:member(malformed, Records) of
                        true -> malformed;
                        false -> #{applications => Applications, records => Records}
                    end;
                _ -> malformed
            end;
        _ -> absent
    end;
read_store(_) -> none.

decode_stored(Block, Seq) ->
    case fenrir_wire:decode_record(Block) of
        {ok, Record = #{type := stored, seq := Seq, incarnation := 0}} ->
            case fenrir_wire:decode_stored(Record) of
                {ok, Caller, Key, Argument, Value} -> {Caller, Key, Argument, Value};
                malformed -> malformed
            end;
        _ -> malformed
    end.
