%% The supervisor's part of remote perform (spec/tc1/EFFECTS.md §12): it carries
%% every message between members, along declared connections only, tags every
%% attempt, remembers every hand-over, and reports outcomes.
%%
%% This server is a step machine. Its steps are those of the model
%% models/tc1/remote-system.shen, with the same labels: issue, refuse, finish,
%% deliver-request, deliver-reply, discard-reply, drop, duplicate, act, timeout,
%% peer-down, crash, crash-after-commit, restart. enabled/0 lists the steps that can be taken now;
%% step/1 takes one and returns its label. Who chooses the next step (a schedule,
%% a seeded choice, or the free-running policy with a clock) is fenrir_run's
%% business. Every step taken is appended to the event log.
%%
%% Defect switches, for the harness only (each breaks the contract on purpose):
%%   peer-down-after-handover   peer-down offered although a copy was handed over
%%   late-reply-accepted        a reply for an attempt that timed out is given to the caller
%%   relay-undeclared           requests are carried whatever the manifest says
%% Two more are switches of the peer image, passed on its command line:
%%   non-idempotent-peer, reply-before-commit (backends/solo5/remote/peer.c)
-module(fenrir_relay).
-behaviour(gen_server).
-export([start_link/0, assemble/1, enabled/0, step/1, observe/0, inject_kill/1, arm_kill_in_act/2, report/0, shutdown/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SETTLE_MS, 5000).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Check the manifest against what the images declare, then start every member.
%% ok | {refused, [[Caller, Peer]]} | {error, Reason}
assemble(Spec) -> gen_server:call(?MODULE, {assemble, Spec}, 120000).
%% {ok, [Label]} | {error, Reason}. Labels are in the model's order of step kinds.
enabled() -> gen_server:call(?MODULE, enabled, 120000).
%% {ok, Label} | {not_enabled, [Label]} | {error, Reason}
step(Command) -> gen_server:call(?MODULE, {step, Command}, 120000).
%% Free-running mode only: notice members whose OS process has died without the
%% supervisor killing it, and record each as a crash. {ok, [Name]}.
observe() -> gen_server:call(?MODULE, observe, 120000).
%% For tests of the free-running mode: kill a member's OS process behind the
%% relay's back, as an outside failure would. Nothing is recorded.
inject_kill(Name) -> gen_server:call(?MODULE, {inject_kill, Name}, 120000).
%% For tests of the free-running mode: in the member's Nth act, kill its OS
%% process behind the relay's back after its durable commit and before its
%% reply. Nothing is recorded: the relay has to find out what happened.
arm_kill_in_act(Name, N) -> gen_server:call(?MODULE, {arm_kill_in_act, Name, N}, 120000).
report() -> gen_server:call(?MODULE, report, 120000).
shutdown() -> gen_server:call(?MODULE, shutdown, 120000).

init([]) -> {ok, #{assembled => false}}.

handle_call({assemble, Spec}, _From, #{assembled := false}) ->
    case assemble_system(Spec) of
        {ok, S} -> {reply, ok, S};
        {Other, S} -> {reply, Other, S}
    end;
handle_call(enabled, _From, S0) ->
    case settle(S0) of
        {ok, S} -> {reply, {ok, [label(E) || E <- enabled_steps(S)]}, S};
        {Error, S} -> {reply, Error, S}
    end;
handle_call({step, Command}, _From, S0) ->
    case settle(S0) of
        {ok, S1} ->
            Enabled = enabled_steps(S1),
            case [E || E <- Enabled, matches(Command, label(E))] of
                [] -> {reply, {not_enabled, [label(E) || E <- Enabled]}, S1};
                [Step | _] ->
                    case take_step(Step, S1) of
                        {ok, Label, S2} ->
                            Seen = #{label => Label, enabled => [label(E) || E <- Enabled]},
                            {reply, {ok, Label}, S2#{log := [Seen | maps:get(log, S2)]}};
                        {ok, Label, S2, Then} ->
                            %% One command, two steps: what else was enabled between them was not looked at.
                            Seen = #{label => Label, enabled => [label(E) || E <- Enabled]},
                            After = #{label => Then, enabled => <<"unobserved">>},
                            {reply, {ok, Label}, S2#{log := [After, Seen | maps:get(log, S2)]}};
                        {error, Reason, S2} -> {reply, {error, Reason}, S2}
                    end
            end;
        {Error, S1} -> {reply, Error, S1}
    end;
handle_call(observe, _From, S = #{assembled := true, order := Order}) ->
    Dead = [Name || Name <- Order, died(Name, S)],
    S1 = lists:foldl(
           fun(Name, Acc) ->
                   {ok, Label, Acc1} = crashed(Name, Acc),
                   %% What else was enabled is not known here: the dead image may
                   %% not have reached a scheduling point.
                   Acc1#{log := [#{label => Label, enabled => <<"unobserved">>} | maps:get(log, Acc1)]}
           end, S, Dead),
    {reply, {ok, Dead}, S1};
handle_call({inject_kill, Name}, _From, S) ->
    {reply, fenrir_member:kill(pid(Name, S)), S};
handle_call({arm_kill_in_act, Name, N}, _From, S) ->
    {reply, ok, S#{kill_in_act := [{Name, N} | maps:get(kill_in_act, S)]}};
handle_call(report, _From, S0) ->
    %% Let every image reach its next scheduling point, so that its console is complete.
    {Settled, S} = settle(S0),
    Enabled = case Settled of ok -> [label(E) || E <- enabled_steps(S)]; _ -> [] end,
    Log = lists:reverse(maps:get(log, S, [])),
    {reply, #{events => [maps:get(label, L) || L <- Log],
              enabled => [maps:get(enabled, L) || L <- Log],
              enabled_at_end => Enabled,
              settled => Settled =:= ok,
              refusals => maps:get(refusals, S, []),
              declared => maps:get(declared, S, [])}, S};
handle_call(shutdown, _From, S) ->
    Members = maps:get(pids, S, #{}),
    [fenrir_member:kill(Pid) || Pid <- maps:values(Members)],
    Order = maps:get(order, S, []),
    Consoles = [#{member => Name, incarnation => integer_to_binary(maps:get(incarnation, C)),
                  file => unicode:characters_to_binary(maps:get(file, C)),
                  exit => exit_text(maps:get(exit, C))}
                || Name <- Order, C <- maps:get(consoles, fenrir_member:info(maps:get(Name, Members)))],
    Stores = [store_report(Name, fenrir_member:store(maps:get(Name, Members))) || Name <- Order],
    {reply, #{consoles => Consoles, stores => [X || X <- Stores, X =/= none]}, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.

exit_text(none) -> <<"running">>;
exit_text(N) -> integer_to_binary(N).

store_report(_, none) -> none;
store_report(Name, #{applications := A, records := Records}) ->
    #{member => Name, applications => integer_to_binary(A),
      records => [[Caller, integer_to_binary(Key), value(Value)] || {Caller, Key, Value} <- Records]};
store_report(Name, Other) -> #{member => Name, error => atom_to_binary(Other)}.

value(N) -> [<<"int">>, integer_to_binary(N)].

%% ---------- assembling the system ----------

%% What an image declares about itself: the members it is built to call.
declaration(Image) ->
    case file:read_file(Image) of
        {ok, Bytes} ->
            Marker = <<"\nFENRIR-REMOTE-DECL/1 connects=">>,
            case binary:matches(Bytes, Marker) of
                [{At, Size}] ->
                    Rest = binary:part(Bytes, At + Size, min(256, byte_size(Bytes) - At - Size)),
                    case binary:split(Rest, <<"\n">>) of
                        [List, _] ->
                            Names = [N || N <- binary:split(List, <<",">>, [global]), N =/= <<>>],
                            case lists:all(fun fenrir_wire:name_ok/1, Names) of
                                true -> {ok, Names};
                                false -> {error, bad_declaration}
                            end;
                        _ -> {error, bad_declaration}
                    end;
                [] -> {ok, none};
                _ -> {error, ambiguous_declaration}
            end;
        _ -> {error, unreadable_image}
    end.

assemble_system(Spec = #{members := Members, connections := Edges}) ->
    Names = [maps:get(name, M) || M <- Members],
    Declared = [{maps:get(name, M), maps:get(kind, M), declaration(maps:get(image, M))} || M <- Members],
    Bad = [{N, E} || {N, _, {error, E}} <- Declared] ++
          [{N, caller_image_without_declaration} || {N, caller, {ok, none}} <- Declared] ++
          [{N, bad_name} || N <- Names, not fenrir_wire:name_ok(N)] ++
          [{N, duplicate_name} || N <- Names -- lists:usort(Names)] ++
          [{E, bad_connection} || E = [A, B] <- Edges, not (lists:member(A, Names) andalso lists:member(B, Names))],
    Wanted = [[N, P] || {N, _, {ok, Peers}} <- Declared, is_list(Peers), P <- Peers],
    Refusals = [E || E <- Wanted, not lists:member(E, Edges)],
    Base = #{assembled => false, declared => Wanted, refusals => Refusals},
    if
        Bad =/= [] -> {{error, {manifest, Bad}}, Base};
        %% The start-time check: a member whose program declares a connection the
        %% manifest lacks is not started, and neither is anything else.
        Refusals =/= [] andalso map_get(start_check, Spec) -> {{refused, Refusals}, Base};
        true -> start_members(Spec, Base#{refusals := []})
    end.

start_members(Spec = #{members := Members, connections := Edges, defects := Defects}, Base) ->
    Has = fun(Defect) -> lists:member(Defect, Defects) end,
    Options = fun(peer) ->
                      case {Has(<<"non-idempotent-peer">>), Has(<<"reply-before-commit">>)} of
                          {true, _} -> " non-idempotent";
                          {_, true} -> " reply-before-commit";
                          _ -> ""
                      end;
                 (caller) -> ""
              end,
    Pids = maps:from_list(
             [begin
                  {ok, Pid} = supervisor:start_child(fenrir_member_sup,
                                [M#{tender => maps:get(tender, Spec), dir => maps:get(dir, Spec),
                                    life_ms => maps:get(life_ms, Spec), options => Options(maps:get(kind, M))}]),
                  {maps:get(name, M), Pid}
              end || M <- Members]),
    Order = [maps:get(name, M) || M <- Members],
    S = Base#{assembled := true, pids => Pids, order => Order, edges => Edges, defects => Defects,
              kinds => maps:from_list([{maps:get(name, M), maps:get(kind, M)} || M <- Members]),
              members => maps:from_list([{N, #{status => down, pending => none, inbox => [], next => idle}} || N <- Order]),
              net => [], handed => [], tags => maps:from_list([{N, 1} || N <- Order]), attempts => #{},
              budget => {maps:get(crashes, Spec), maps:get(duplicates, Spec)}, log => [],
              acts => #{}, kill_in_act => []},
    boot_all(Order, S).

boot_all([], S) -> {ok, S};
boot_all([Name | Names], S) ->
    case boot(Name, S) of
        {ok, S1} -> boot_all(Names, S1);
        {error, Reason} -> {{error, Reason}, S}
    end.

boot(Name, S = #{pids := Pids, members := Members, kinds := Kinds}) ->
    case fenrir_member:boot(maps:get(Name, Pids)) of
        ok ->
            Next = case maps:get(Name, Kinds) of caller -> unknown; peer -> idle end,
            {ok, S#{members := Members#{Name := #{status => up, pending => none, inbox => [], next => Next}}}};
        {error, Reason} -> {error, {boot, Name, Reason}}
    end.

%% ---------- scheduling points ----------

%% A caller image that is up and has no outcome to wait for is running: wait for
%% it to reach its next scheduling point, a request or the end of its program.
%% Until then the supervisor does not know what that image's next step is.
settle(S = #{assembled := true, order := Order}) -> settle(Order, S);
settle(S) -> {{error, not_assembled}, S}.

settle([], S) -> {ok, S};
settle([Name | Names], S = #{members := Members, pids := Pids}) ->
    case maps:get(Name, Members) of
        M = #{status := up, pending := none, next := unknown} ->
            case fenrir_member:take(maps:get(Name, Pids), ?SETTLE_MS) of
                {ok, Record = #{type := request}} ->
                    case fenrir_wire:decode_call(Record) of
                        {ok, Peer, Key, Argument} ->
                            Next = {request, Peer, integer_to_binary(Key), Argument, maps:get(seq, Record)},
                            settle(Names, S#{members := Members#{Name := M#{next := Next}}});
                        malformed -> {{error, {malformed_request, Name}}, S}
                    end;
                {ok, #{type := halt, ref := 0, payload := <<>>}} ->
                    settle(Names, S#{members := Members#{Name := M#{next := halt}}});
                {ok, _} -> {{error, {malformed_record, Name}}, S};
                Other -> {{error, {no_scheduling_point, Name, Other}}, S}
            end;
        _ -> settle(Names, S)
    end.

%% ---------- the enabled steps, in the order of remote.successors ----------

defect(Name, #{defects := Defects}) -> lists:member(Name, Defects).

enabled_steps(S = #{order := Order, members := Members, net := Net, budget := {Crashes, Duplicates}}) ->
    Up = fun(Name) -> case Members of #{Name := #{status := up}} -> true; _ -> false end end,
    Down = fun(Name) -> case Members of #{Name := #{status := down}} -> true; _ -> false end end,
    Program = lists:append(
      [case maps:get(Name, Members) of
           #{status := up, pending := none, next := {request, Peer, Rid, _, _}} ->
               case declared(Name, Peer, S) of
                   true -> [{issue, Name, Peer, Rid}];
                   false -> [{refuse, Name, Peer, Rid}]
               end;
           #{status := up, pending := none, next := halt} -> [{finish, Name}];
           _ -> []
       end || Name <- Order]),
    Link = lists:append(
      [begin
           Deliver = case Message of
                         {req, _, _, Peer, _, _} -> Up(Peer);
                         {rep, _, Caller, _, _, _} -> Up(Caller)
                     end,
           [{deliver, Message} || Deliver] ++ [{drop, Message}] ++ [{duplicate, Message} || Duplicates > 0]
       end || Message <- lists:usort(Net)]),
    Act = lists:append(
      [case maps:get(Name, Members) of
           #{status := up, inbox := [{Tag, _, _, _, _} | _]} -> [{act, Name, Tag}];
           _ -> []
       end || Name <- Order]),
    Waiting = lists:append(
      [case maps:get(Name, Members) of
           #{status := up, pending := {Tag, Peer, Rid, _}} ->
               [{timeout, Tag}] ++
               [{peer_down, Tag} || Down(Peer),
                                    defect(<<"peer-down-after-handover">>, S)
                                        orelse not lists:member({Name, Peer, Rid}, maps:get(handed, S))];
           _ -> []
       end || Name <- Order]),
    Crash = [{crash, Name} || Name <- Order, Up(Name), Crashes > 0],
    %% A kill between a peer's commit and its reply: where acting would apply,
    %% which is read from the peer's durable store, not from the event log.
    CommitCrash = [{crash_after_commit, Name, Tag}
                   || Crashes > 0, {act, Name, Tag} <- Act, not recorded(Name, hd(maps:get(inbox, maps:get(Name, Members))), S)],
    Restart = [{restart, Name} || Name <- Order, Down(Name)],
    Program ++ Link ++ Act ++ Waiting ++ Crash ++ CommitCrash ++ Restart.

%% Whether the peer's durable store has a reply record for the request id of an
%% inbox entry. The store is on the host side and is the only place that says so.
recorded(Name, {_, Caller, Rid, _, _}, S) ->
    case fenrir_member:store(pid(Name, S)) of
        #{records := Records} -> lists:any(fun({C, K, _}) -> C =:= Caller andalso integer_to_binary(K) =:= Rid end, Records);
        _ -> false
    end.

declared(Caller, Peer, S = #{edges := Edges}) ->
    defect(<<"relay-undeclared">>, S) orelse lists:member([Caller, Peer], Edges).

tag({Caller, N}) -> [Caller, integer_to_binary(N)].

message_label({req, Tag, _, _, _, _}) -> [<<"request">>, tag(Tag)];
message_label({rep, Tag, _, _, _, Value}) -> [<<"reply">>, tag(Tag), value(Value)].

%% The label of an enabled step, as far as it is known before the step is taken:
%% an act does not say yet whether it applies or replays, and a reply handed to
%% the caller may turn out to be stale (discard-reply).
label({issue, Name, Peer, Rid}) -> [<<"issue">>, Name, Peer, Rid];
label({refuse, Name, Peer, Rid}) -> [<<"refuse">>, Name, Peer, Rid];
label({finish, Name}) -> [<<"finish">>, Name];
label({deliver, {req, Tag, _, _, _, _}}) -> [<<"deliver-request">>, tag(Tag)];
label({deliver, {rep, Tag, _, _, _, Value}}) -> [<<"deliver-reply">>, tag(Tag), value(Value)];
label({drop, Message}) -> [<<"drop">> | message_label(Message)];
label({duplicate, Message}) -> [<<"duplicate">> | message_label(Message)];
label({act, Name, Tag}) -> [<<"act">>, Name, tag(Tag)];
label({timeout, Tag}) -> [<<"timeout">>, tag(Tag)];
label({peer_down, Tag}) -> [<<"peer-down">>, tag(Tag)];
label({crash, Name}) -> [<<"crash">>, Name];
label({crash_after_commit, Name, Tag}) -> [<<"crash-after-commit">>, Name, tag(Tag)];
label({restart, Name}) -> [<<"restart">>, Name].

%% A command names a step by its label or by a prefix of it; an act may carry
%% the expected applied/replayed, and discard-reply names the same step as
%% deliver-reply. What happened is what the returned label says.
matches([<<"discard-reply">> | Rest], Label) -> matches([<<"deliver-reply">> | Rest], Label);
matches(Command, Label) -> lists:prefix(Command, Label) orelse lists:prefix(Label, Command).

%% ---------- taking a step ----------

member(Name, #{members := Members}) -> maps:get(Name, Members).
set_member(Name, M, S = #{members := Members}) -> S#{members := Members#{Name := M}}.
pid(Name, #{pids := Pids}) -> maps:get(Name, Pids).

%% Give the caller the one outcome of the perform it is suspended in.
outcome(Name, Seq, Code, Value, S) ->
    case fenrir_member:put(pid(Name, S), outcome, Seq, fenrir_wire:result_payload(Code, Value), grant) of
        {ok, _} -> ok;
        {error, Reason} -> {error, {outcome, Name, Reason}}
    end.

resolved(Name, Tag, Fate, S = #{attempts := Attempts}) ->
    M = member(Name, S),
    set_member(Name, M#{pending := none, next := unknown}, S#{attempts := Attempts#{Tag := Fate}}).

take_step({issue, Name, Peer, Rid}, S = #{tags := Tags, net := Net, attempts := Attempts}) ->
    M = #{next := {request, Peer, Rid, Argument, Seq}} = member(Name, S),
    N = maps:get(Name, Tags),
    Tag = {Name, N},
    S1 = set_member(Name, M#{pending := {Tag, Peer, Rid, Seq}, next := waiting}, S),
    {ok, label({issue, Name, Peer, Rid}),
     S1#{tags := Tags#{Name := N + 1}, net := lists:sort([{req, Tag, Name, Peer, Rid, Argument} | Net]),
         attempts := Attempts#{Tag => {open, Seq}}}};
take_step({refuse, Name, Peer, Rid}, S = #{tags := Tags, attempts := Attempts}) ->
    %% The backstop behind the start-time check: nothing is put in flight.
    M = #{next := {request, Peer, Rid, _, Seq}} = member(Name, S),
    N = maps:get(Name, Tags),
    case outcome(Name, Seq, peer_down, 0, S) of
        ok ->
            S1 = set_member(Name, M#{pending := none, next := unknown}, S),
            {ok, label({refuse, Name, Peer, Rid}), S1#{tags := Tags#{Name := N + 1}, attempts := Attempts#{{Name, N} => closed}}};
        {error, Reason} -> {error, Reason, S}
    end;
take_step({finish, Name}, S) ->
    case fenrir_member:wait_exit(pid(Name, S), ?SETTLE_MS) of
        {ok, 0} -> {ok, label({finish, Name}), set_member(Name, (member(Name, S))#{next := halted}, S)};
        Other -> {error, {finish, Name, Other}, S}
    end;
take_step({deliver, Message = {req, Tag, Caller, Peer, Rid, Argument}}, S = #{net := Net, handed := Handed}) ->
    %% The hand-over is recorded before the request is written to the peer's
    %% inbox: from here on the supervisor cannot know whether the peer acted.
    S1 = S#{net := Net -- [Message], handed := lists:usort([{Caller, Peer, Rid} | Handed])},
    Payload = fenrir_wire:call_payload(Caller, binary_to_integer(Rid), Argument),
    case fenrir_member:put(pid(Peer, S), deliver, 0, Payload, hold) of
        {ok, Seq} ->
            M = #{inbox := Inbox} = member(Peer, S1),
            {ok, label({deliver, Message}), set_member(Peer, M#{inbox := Inbox ++ [{Tag, Caller, Rid, Argument, Seq}]}, S1)};
        {error, Reason} -> {error, {deliver, Peer, Reason}, S1}
    end;
take_step({deliver, Message = {rep, Tag = {Caller, _}, Caller, _, _, Value}}, S = #{net := Net, attempts := Attempts}) ->
    S1 = S#{net := Net -- [Message]},
    Late = defect(<<"late-reply-accepted">>, S),
    case {member(Caller, S1), maps:get(Tag, Attempts)} of
        {#{pending := {Tag, _, _, Seq}}, _} ->
            case outcome(Caller, Seq, reply, Value, S1) of
                ok -> {ok, label({deliver, Message}), resolved(Caller, Tag, closed, S1)};
                {error, Reason} -> {error, Reason, S1}
            end;
        {_, {timed_out, Seq}} when Late ->
            %% Defect: the reply of an attempt that already timed out is handed to the caller.
            case outcome(Caller, Seq, reply, Value, S1) of
                ok -> {ok, label({deliver, Message}), S1};
                {error, Reason} -> {error, Reason, S1}
            end;
        _ ->
            %% The caller is no longer suspended in that attempt: the reply is stale.
            {ok, [<<"discard-reply">>, tag(Tag), value(Value)], S1}
    end;
take_step({drop, Message}, S = #{net := Net}) ->
    {ok, label({drop, Message}), S#{net := Net -- [Message]}};
take_step({duplicate, Message}, S = #{net := Net, budget := {Crashes, Duplicates}}) ->
    {ok, label({duplicate, Message}), S#{net := lists:sort([Message | Net]), budget := {Crashes, Duplicates - 1}}};
take_step({act, Name, Tag}, S0 = #{net := Net, acts := Acts, kill_in_act := Armed}) ->
    %% The peer image is let run on the oldest request in its inbox. Its reply
    %% record says whether it applied the request or replayed a recorded reply.
    M = #{inbox := [Entry = {Tag, Caller, Rid, _, Seq} | Inbox]} = member(Name, S0),
    Pid = pid(Name, S0),
    Nth = maps:get(Name, Acts, 0) + 1,
    S = S0#{acts := Acts#{Name => Nth}},
    Before = recorded(Name, Entry, S),
    case lists:member({Name, Nth}, Armed) of
        false -> ok = fenrir_member:grant(Pid);
        true ->
            %% Test only: an outside kill placed after the commit. Not recorded.
            ok = fenrir_member:grant_hold(Pid),
            _ = await_commit(Name, Entry, S, erlang:monotonic_time(millisecond) + ?SETTLE_MS),
            ok = fenrir_member:kill(Pid)
    end,
    case fenrir_member:take(Pid, ?SETTLE_MS) of
        {exited, _} ->
            %% The image died inside the act, without the supervisor killing it,
            %% and no reply will come. Whether it acted is read from its store.
            {ok, Crash, S1} = crashed(Name, S),
            case (not Before) andalso recorded(Name, Entry, S) of
                true -> {ok, label({crash_after_commit, Name, Tag}), S1};
                false -> {ok, Crash, S1}
            end;
        {ok, Record = #{type := reply, ref := Seq}} ->
            case fenrir_wire:decode_result(reply, Record) of
                {ok, How, Value} ->
                    S1 = set_member(Name, M#{inbox := Inbox}, S),
                    {ok, label({act, Name, Tag}) ++ [atom_to_binary(How)],
                     S1#{net := lists:sort([{rep, Tag, Caller, Name, Rid, Value} | Net])}};
                malformed -> {error, {malformed_reply, Name}, S}
            end;
        {ok, _} -> {error, {malformed_reply, Name}, S};
        Other -> {error, {no_reply, Name, Other}, S}
    end;
take_step({timeout, Tag = {Name, _}}, S) ->
    #{pending := {Tag, _, _, Seq}} = member(Name, S),
    case outcome(Name, Seq, timed_out, 0, S) of
        ok -> {ok, label({timeout, Tag}), resolved(Name, Tag, {timed_out, Seq}, S)};
        {error, Reason} -> {error, Reason, S}
    end;
take_step({peer_down, Tag = {Name, _}}, S = #{net := Net}) ->
    %% Enabled only while the peer is down and no copy of this request id was
    %% ever handed to it. Every copy still held, of every attempt, is destroyed.
    #{pending := {Tag, Peer, Rid, Seq}} = member(Name, S),
    Kept = [M || M <- Net, not is_request_for(M, Name, Peer, Rid)],
    case outcome(Name, Seq, peer_down, 0, S) of
        ok -> {ok, label({peer_down, Tag}), resolved(Name, Tag, closed, S#{net := Kept})};
        {error, Reason} -> {error, Reason, S}
    end;
take_step({crash, Name}, S = #{budget := {Crashes, Duplicates}}) ->
    case fenrir_member:kill(pid(Name, S)) of
        ok -> crashed(Name, S#{budget := {Crashes - 1, Duplicates}});
        {error, Reason} -> {error, {crash, Name, Reason}, S}
    end;
take_step({crash_after_commit, Name, Tag}, S = #{net := Net, budget := {Crashes, Duplicates}}) ->
    %% The peer is let run on the oldest request in its inbox, told to stop
    %% before it replies. When its store shows the commit, it is killed.
    M = #{inbox := [Entry = {Tag, Caller, Rid, _, Seq} | Inbox]} = member(Name, S),
    Pid = pid(Name, S),
    ok = fenrir_member:grant_hold(Pid),
    Seen = await_commit(Name, Entry, S, erlang:monotonic_time(millisecond) + ?SETTLE_MS),
    Killed = fenrir_member:kill(Pid),
    Spent = S#{budget := {Crashes - 1, Duplicates}},
    case {Seen, Killed} of
        {committed, ok} ->
            {ok, _, S1} = crashed(Name, Spent),
            {ok, label({crash_after_commit, Name, Tag}), S1};
        {{replied, Record = #{ref := Seq}}, ok} ->
            %% Not the step that was asked for: the image replied with nothing
            %% committed. What happened is recorded as it was seen: an act, by
            %% the reply, and then the crash.
            case fenrir_wire:decode_result(reply, Record) of
                {ok, How, Value} ->
                    S1 = set_member(Name, M#{inbox := Inbox}, Spent),
                    {ok, Crash, S2} = crashed(Name, S1#{net := lists:sort([{rep, Tag, Caller, Name, Rid, Value} | Net])}),
                    {ok, label({act, Name, Tag}) ++ [atom_to_binary(How)], S2, Crash};
                malformed -> {error, {malformed_reply, Name}, S}
            end;
        Other -> {error, {crash_after_commit, Name, Other}, S}
    end;
take_step({restart, Name}, S) ->
    case boot(Name, S) of
        {ok, S1} -> {ok, label({restart, Name}), S1};
        {error, Reason} -> {error, Reason, S}
    end.

%% Wait for the peer's store to show a reply record for the request id of the
%% inbox entry: committed. A peer that sends a record first has not committed:
%% {replied, Record}. Otherwise what stopped the wait.
await_commit(Name, Entry, S, Deadline) ->
    case recorded(Name, Entry, S) of
        true -> committed;
        false ->
            case fenrir_member:take(pid(Name, S), 1) of
                {ok, Record} -> {replied, Record};
                timeout ->
                    case erlang:monotonic_time(millisecond) >= Deadline of
                        true -> timeout;
                        false -> await_commit(Name, Entry, S, Deadline)
                    end;
                Other -> Other
            end
    end.

%% The image is gone, killed by a crash step or found dead. Its volatile state
%% is lost: its position, the perform it was suspended in, the requests handed
%% to it and not acted on. Nothing else changes: not its durable store, not
%% another member, nothing in flight.
crashed(Name, S = #{attempts := Attempts}) ->
    M = member(Name, S),
    Attempts1 = case M of
                    #{pending := {Tag, _, _, _}} -> Attempts#{Tag := orphaned};
                    _ -> Attempts
                end,
    {ok, label({crash, Name}),
     set_member(Name, M#{status := down, pending := none, inbox := [], next := idle}, S#{attempts := Attempts1})}.

%% Up as far as the relay knows, but its OS process has exited, and not as a
%% caller whose program ran to its end.
died(Name, S = #{kinds := Kinds}) ->
    case member(Name, S) of
        #{status := up} ->
            case fenrir_member:info(pid(Name, S)) of
                #{running := true} -> false;
                #{exit := 0} -> maps:get(Name, Kinds) =/= caller;
                _ -> true
            end;
        _ -> false
    end.

is_request_for({req, _, Caller, Peer, Rid, _}, Caller, Peer, Rid) -> true;
is_request_for(_, _, _, _) -> false.
