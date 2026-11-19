%% The supervisor's part of remote perform (spec/tc1/EFFECTS.md §12): it carries
%% every message between members, along declared connections only, tags every
%% attempt, remembers every hand-over, and reports outcomes.
%%
%% This server is a step machine. Its steps are those of the model
%% models/tc1/remote-system.shen, with the same labels: issue, refuse, finish,
%% deliver-request, deliver-reply, discard-reply, drop, duplicate, act, timeout,
%% not-delivered, crash, crash-after-commit, restart, supervisor-restart.
%% enabled/0 lists the steps that can be taken now;
%% step/1 takes one and returns its label. Who chooses the next step (a schedule,
%% a seeded choice, or the free-running policy with a clock) is fenrir_run's
%% business. Every step taken is appended to the event log.
%%
%% supervisor-restart (EFFECTS.md §12.7) is this process being killed and started
%% again by fenrir_sup while the member processes, and the guests, keep running.
%% What the new process knows is what fenrir_journal holds: everything in the
%% state below except `handed` (the record of hand-overs) and `net` (the
%% messages in flight), which exist only in this process and die with it. The
%% new process takes every request id in `issued` as handed over. Killed in any
%% other way, the new process answers every call with an error.
%%
%% Defect switches, for the harness only (each breaks the contract on purpose):
%%   not-delivered-after-handover   not-delivered offered although a copy was handed over
%%   late-reply-accepted        a reply for an attempt that timed out is given to the caller
%%   relay-undeclared           requests are carried whatever the manifest says
%%   forgetful-supervisor-restart   after its restart the relay takes nothing as handed over
%% Eight more are switches of the peer image's runtime, passed on its command line:
%%   non-idempotent-peer, reply-before-commit, replay-different-argument,
%%   read-only-writes, writes-without-record, record-without-writes, torn-commit,
%%   stale-reads (backends/solo5/remote/peer.c)
%%
%% A request names its operation, "Effect.operation" (wire format 4): what a
%% request carries is {Operation, Argument}, Argument an integer or the atom read.
%%
%% A kill inside a peer's commit. The model has no step of its own for it: a
%% peer killed before its store header counts the commit has committed nothing,
%% which is the model's step crash. So it is not among the enabled steps; it is
%% a way to take the step crash, asked for by the command
%% ["crash", Name, "in-commit"] where a crash-after-commit would be enabled. The
%% peer is let run on the oldest request in its inbox and told to stop inside
%% its commit; when its store file shows the request's reply record written and
%% not counted, it is killed. What is logged is what the store then says: crash
%% if the request has no counted record, crash-after-commit if it has. The
%% report lists each such kill with the uncounted records that were seen.
%%
%% A read-only operation (EFFECTS.md §12.3) has no request key. Each perform of
%% one is its own request: the relay names it read-N, N being the number of the
%% attempt it becomes, and keeps it in its records like a key. Its argument is
%% the atom read.
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
step(Command) ->
    case gen_server:call(?MODULE, {step, Command}, 120000) of
        {restart, Label} ->
            %% The step is logged and journalled. Now it happens: this relay
            %% process is killed, and its supervisor starts another.
            ok = restart_relay(),
            {ok, Label};
        Other -> Other
    end.

restart_relay() ->
    Old = whereis(?MODULE),
    Ref = erlang:monitor(process, Old),
    exit(Old, kill),
    receive {'DOWN', Ref, process, Old, _} -> ok after 5000 -> exit(relay_did_not_die) end,
    await_relay(Old, erlang:monotonic_time(millisecond) + 5000).

await_relay(Old, Deadline) ->
    case whereis(?MODULE) of
        Pid when is_pid(Pid), Pid =/= Old -> gen_server:call(?MODULE, ready, 120000);
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> exit(relay_not_restarted);
                false -> timer:sleep(1), await_relay(Old, Deadline)
            end
    end.
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

init([]) ->
    case fenrir_journal:take() of
        none -> {ok, #{assembled => false}};
        {S = #{assembled := true}, true} ->
            %% Restarted by a supervisor-restart step. The hand-over record and
            %% the messages in flight are gone. Every request id issued so far
            %% counts as handed over from here on.
            Handed = case defect(<<"forgetful-supervisor-restart">>, S) of
                         true -> [];
                         false -> maps:get(issued, S)
                     end,
            {ok, S#{handed => Handed, net => [], incarnations := maps:get(incarnations, S) + 1}};
        {S, _} -> {ok, S#{broken => true}}
    end.

%% Every call ends with the state, less what a restart loses, in the journal.
handle_call(ready, _From, S) -> {reply, ok, S};
handle_call(_, _From, S = #{broken := true}) -> {reply, {error, relay_died_outside_a_step}, S};
handle_call(Request, From, S0) ->
    {reply, Reply, S} = call(Request, From, S0),
    Planned = case Reply of {restart, _} -> true; _ -> false end,
    ok = fenrir_journal:put(maps:without([handed, net], S), Planned),
    {reply, Reply, S}.

call({assemble, Spec}, _From, #{assembled := false}) ->
    case assemble_system(Spec) of
        {ok, S} -> {reply, ok, S};
        {Other, S} -> {reply, Other, S}
    end;
call(enabled, _From, S0) ->
    case settle(S0) of
        {ok, S} -> {reply, {ok, [label(E) || E <- enabled_steps(S)]}, S};
        {Error, S} -> {reply, Error, S}
    end;
call({step, Command}, _From, S0) ->
    case settle(S0) of
        {ok, S1} ->
            Enabled = enabled_steps(S1),
            case in_commit(Command, Enabled) of
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
                        {restart, Label, S2} ->
                            Seen = #{label => Label, enabled => [label(E) || E <- Enabled]},
                            {reply, {restart, Label}, S2#{log := [Seen | maps:get(log, S2)]}};
                        {error, Reason, S2} -> {reply, {error, Reason}, S2}
                    end
            end;
        {Error, S1} -> {reply, Error, S1}
    end;
call(observe, _From, S = #{assembled := true, order := Order}) ->
    Dead = [Name || Name <- Order, died(Name, S)],
    S1 = lists:foldl(
           fun(Name, Acc) ->
                   {ok, Label, Acc1} = crashed(Name, Acc),
                   %% What else was enabled is not known here: the dead image may
                   %% not have reached a scheduling point.
                   Acc1#{log := [#{label => Label, enabled => <<"unobserved">>} | maps:get(log, Acc1)]}
           end, S, Dead),
    {reply, {ok, Dead}, S1};
call({inject_kill, Name}, _From, S) ->
    {reply, fenrir_member:kill(pid(Name, S)), S};
call({arm_kill_in_act, Name, N}, _From, S) ->
    {reply, ok, S#{kill_in_act := [{Name, N} | maps:get(kill_in_act, S)]}};
call(report, _From, S0) ->
    %% Let every image reach its next scheduling point, so that its console is complete.
    {Settled, S} = settle(S0),
    Enabled = case Settled of ok -> [label(E) || E <- enabled_steps(S)]; _ -> [] end,
    Log = lists:reverse(maps:get(log, S, [])),
    {reply, #{events => [maps:get(label, L) || L <- Log],
              enabled => [maps:get(enabled, L) || L <- Log],
              enabled_at_end => Enabled,
              settled => Settled =:= ok,
              refusals => maps:get(refusals, S, []),
              declared => maps:get(declared, S, []),
              %% Each kill placed inside a commit: the member, and the records its store
              %% file held beyond the header's count when it was killed.
              kills_in_commit => lists:reverse(maps:get(in_commit, S, [])),
              %% How many relay processes this run has had: one, and one more per supervisor-restart.
              supervisor_incarnations => integer_to_binary(maps:get(incarnations, S, 1))}, S};
call(shutdown, _From, S) ->
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
store_report(Name, #{cells := Cells, records := Records}) ->
    #{member => Name, cells => [[integer_to_binary(K), integer_to_binary(V)] || {K, V} <- Cells],
      records => [[Caller, integer_to_binary(Key), Operation, int(Argument), int(Value)] || {Caller, Key, Operation, Argument, Value} <- Records]};
store_report(Name, Other) -> #{member => Name, error => atom_to_binary(Other)}.

int(N) -> [<<"int">>, integer_to_binary(N)].

%% A reply value, as the caller's program sees it: (status, value) from a keyed
%% operation, the value itself from a read-only one.
value({read, N}) -> int(N);
value({ok, N}) -> [<<"tuple">>, int(0), int(N)];
value(conflict) -> [<<"tuple">>, int(1), int(0)].

%% ---------- assembling the system ----------

%% What an image says about itself: one line in the image file, which the build
%% derived from the image's own program and, for a caller, the manifest's binding
%% of each remote effect to a member (tools/solo5/remote-build.mjs).
%%   caller  FENRIR-REMOTE-DECL/3 connects=<peers> uses=<peer>/<Effect>.<op>/<mode>,... signatures=<Effect>:<digest>,...
%%   peer    FENRIR-REMOTE-SERVES/2 store=yes|no writes=yes|no operations=<Effect>.<op>/<mode>,... signatures=<Effect>:<digest>,...
%% writes: whether the peer's program mentions StoreWrite at all. A digest is the
%% SHA-256 of the canonical encoding of the effect's signature, as the build of
%% that image computed it from that image's program (EFFECTS.md §12.6).
%% {ok, {caller, Peers, [{Peer, Operation, Mode}], Signatures}} | {ok, {peer, HasStore, [{Operation, Mode}], Writes, Signatures}}
%% | {ok, none} | {error, Reason}; Signatures is [{Effect, Digest}].
declaration(Image) ->
    case file:read_file(Image) of
        {ok, Bytes} ->
            case {line(Bytes, <<"\nFENRIR-REMOTE-DECL/3 ">>), line(Bytes, <<"\nFENRIR-REMOTE-SERVES/2 ">>)} of
                {{ok, Line}, none} -> caller_declaration(fields(Line));
                {none, {ok, Line}} -> peer_declaration(fields(Line));
                {none, none} -> {ok, none};
                _ -> {error, ambiguous_declaration}
            end;
        _ -> {error, unreadable_image}
    end.

line(Bytes, Marker) ->
    case binary:matches(Bytes, Marker) of
        [{At, Size}] ->
            Rest = binary:part(Bytes, At + Size, min(8192, byte_size(Bytes) - At - Size)),
            case binary:split(Rest, <<"\n">>) of
                [Line, _] -> {ok, Line};
                _ -> ambiguous
            end;
        [] -> none;
        _ -> ambiguous
    end.

%% "key=a,b key=c" as [{Key, [Item]}].
fields(Line) ->
    [case binary:split(Field, <<"=">>) of
         [Key, List] -> {Key, [I || I <- binary:split(List, <<",">>, [global]), I =/= <<>>]};
         _ -> {Field, bad}
     end || Field <- binary:split(Line, <<" ">>, [global])].

mode_ok(Mode) -> Mode =:= <<"keyed">> orelse Mode =:= <<"read-only">>.

%% "Effect:digest" items, the digest 64 lowercase hexadecimal digits; bad if one is not.
signatures(Items) when is_list(Items) ->
    Parsed = [case binary:split(I, <<":">>, [global]) of
                  [Effect, Digest] when Effect =/= <<>>, byte_size(Digest) =:= 64 ->
                      case lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end, binary_to_list(Digest)) of
                          true -> {Effect, Digest};
                          false -> bad
                      end;
                  _ -> bad
              end || I <- Items],
    case lists:member(bad, Parsed) orelse length(lists:ukeysort(1, [P || P <- Parsed, P =/= bad])) =/= length(Parsed) of
        true -> bad;
        false -> Parsed
    end;
signatures(_) -> bad.

caller_declaration([{<<"connects">>, Peers}, {<<"uses">>, Items}, {<<"signatures">>, Signed}]) when is_list(Peers), is_list(Items) ->
    Uses = [case binary:split(I, <<"/">>, [global]) of
                [Peer, Operation, Mode] -> {Peer, Operation, Mode};
                _ -> bad
            end || I <- Items],
    Signatures = signatures(Signed),
    %% Every effect the image uses has its digest, and no other effect has one.
    Ok = lists:all(fun fenrir_wire:name_ok/1, Peers) andalso
         lists:all(fun({Peer, Operation, Mode}) -> lists:member(Peer, Peers) andalso mode_ok(Mode) andalso fenrir_wire:operation_ok(Operation);
                      (bad) -> false end, Uses) andalso
         lists:all(fun(Peer) -> lists:keymember(Peer, 1, Uses) end, Peers) andalso
         Signatures =/= bad andalso
         lists:usort([E || {E, _} <- Signatures]) =:= lists:usort([effect_of(Operation) || {_, Operation, _} <- Uses]),
    case Ok of
        true -> {ok, {caller, Peers, Uses, Signatures}};
        false -> {error, bad_declaration}
    end;
caller_declaration(_) -> {error, bad_declaration}.

peer_declaration([{<<"store">>, [Store]}, {<<"writes">>, [Writes]}, {<<"operations">>, Items}, {<<"signatures">>, Signed}]) when is_list(Items) ->
    Serves = [case binary:split(I, <<"/">>, [global]) of
                  [Operation, Mode] -> {Operation, Mode};
                  _ -> bad
              end || I <- Items],
    Signatures = signatures(Signed),
    Ok = lists:member(Store, [<<"yes">>, <<"no">>]) andalso lists:member(Writes, [<<"yes">>, <<"no">>]) andalso
         lists:all(fun({Operation, Mode}) -> mode_ok(Mode) andalso fenrir_wire:operation_ok(Operation); (bad) -> false end, Serves) andalso
         Signatures =/= bad andalso
         lists:usort([E || {E, _} <- Signatures]) =:= lists:usort([effect_of(Operation) || {Operation, _} <- Serves]),
    case Ok of
        true -> {ok, {peer, Store =:= <<"yes">>, Serves, Writes =:= <<"yes">>, Signatures}};
        false -> {error, bad_declaration}
    end;
peer_declaration(_) -> {error, bad_declaration}.

%% The effect of "Effect.operation".
effect_of(Operation) -> hd(binary:split(Operation, <<".">>)).

%% The assembly check. Nothing is started unless it passes. Which member serves a
%% remote effect of a caller is the manifest's binding, [Caller, Effect, Member]
%% (EFFECTS.md §12.6; owner ruling of 16 November 2026, §12.10 question 14): the
%% effects are the ones the caller's image says it uses. Seven refusals:
%%   [Caller, <<"unbound">>, Effect]        the caller uses a remote effect the manifest
%%                                          binds to no member
%%   [Caller, <<"unknown-member">>, Effect, Name]  the manifest binds the effect to a name
%%                                          that is no member of the system
%%   [Caller, Member]                       the effect is bound to a member the manifest
%%                                          declares no connection to from the caller (the
%%                                          start-time check, which start_check => false
%%                                          switches off for the harness)
%%   [Peer, <<"no-store">>, Operation]      a peer image without a durable store serves an
%%                                          operation that is not read-only (EFFECTS.md §12.3)
%%   [Peer, <<"no-store">>, <<"StoreWrite">>]  a peer image without a durable store whose
%%                                          program mentions the store's write effect
%%   [Caller, Member, <<"unserved">>, Operation]  the caller uses an operation the bound
%%                                          member's image does not serve in that mode
%%   [Caller, Member, <<"signature">>, Effect]  the bound member serves the effect, and its
%%                                          digest of the effect's signature is not the
%%                                          caller's: the two programs were built from
%%                                          different declarations (§12.10 question 15)
%% Only the third is ever switched off: nothing at run time stands behind the others.
%% A caller image was built with a binding of its own. Where the manifest binds an
%% effect to another member than the image was built for, the image is not an image of
%% this system: an error of the manifest, like an image without its line.
assemble_system(Spec = #{members := Members, connections := Edges, bindings := Bindings}) ->
    Names = [maps:get(name, M) || M <- Members],
    Declared = [{maps:get(name, M), maps:get(kind, M), declaration(maps:get(image, M))} || M <- Members],
    Callers = [N || {N, caller, _} <- Declared],
    BindingOk = fun([C, E, M]) -> is_binary(C) andalso is_binary(E) andalso is_binary(M) andalso lists:member(C, Callers);
                   (_) -> false
                end,
    Keys = [[C, E] || [C, E, _] <- Bindings],
    %% {Caller, Effect, Member the image was built for}, one per effect the image uses.
    Uses = lists:usort([{N, effect_of(Operation), P} || {N, caller, {ok, {caller, _, Us, _}}} <- Declared, {P, Operation, _} <- Us]),
    Bound = fun(N, Effect) -> [M || [C, E, M] <- Bindings, C =:= N, E =:= Effect] end,
    Bad = [{B, bad_binding} || B <- Bindings, not BindingOk(B)] ++
          [{K, duplicate_binding} || K <- lists:usort(Keys -- lists:usort(Keys))] ++
          [{[C, E, M], binding_of_unused_effect} || B = [C, E, M] <- Bindings, BindingOk(B), not lists:any(fun({N, Effect, _}) -> N =:= C andalso Effect =:= E end, Uses)] ++
          [{[N, Effect, M], image_built_for_another_member} || {N, Effect, P} <- Uses, [M] <- [Bound(N, Effect)], lists:member(M, Names), M =/= P] ++
          [{N, E} || {N, _, {error, E}} <- Declared] ++
          [{N, caller_image_without_declaration} || {N, caller, {ok, D}} <- Declared, D =:= none orelse element(1, D) =/= caller] ++
          [{N, peer_image_without_declaration} || {N, peer, {ok, D}} <- Declared, D =:= none orelse element(1, D) =/= peer] ++
          [{N, bad_name} || N <- Names, not fenrir_wire:name_ok(N)] ++
          [{N, duplicate_name} || N <- Names -- lists:usort(Names)] ++
          [{E, bad_connection} || E = [A, B] <- Edges, not (lists:member(A, Names) andalso lists:member(B, Names))],
    Unbound = [[N, <<"unbound">>, Effect] || {N, Effect, _} <- Uses, Bound(N, Effect) =:= []],
    Unknown = [[N, <<"unknown-member">>, Effect, M] || {N, Effect, _} <- Uses, [M] <- [Bound(N, Effect)], not lists:member(M, Names)],
    %% The connections the bindings need, in the order of the caller's uses, each once.
    Wanted = lists:foldl(fun(E, Acc) -> case lists:member(E, Acc) of true -> Acc; false -> Acc ++ [E] end end, [],
                         [[N, M] || {N, Effect, _} <- Uses, [M] <- [Bound(N, Effect)], lists:member(M, Names)]),
    Missing = [E || E <- Wanted, not lists:member(E, Edges)],
    Serves = maps:from_list([{N, S} || {N, peer, {ok, {peer, _, S, _, _}}} <- Declared]),
    Storeless = lists:append(
                  [[[N, <<"no-store">>, Operation] || {Operation, Mode} <- S, Mode =/= <<"read-only">>] ++
                   [[N, <<"no-store">>, <<"StoreWrite">>] || Writes]
                   || {N, peer, {ok, {peer, false, S, Writes, _}}} <- Declared]),
    %% The member an operation goes to is the bound one; a member that is not a peer serves nothing.
    Unserved = [[N, M, <<"unserved">>, Operation]
                || {N, caller, {ok, {caller, _, Us, _}}} <- Declared, {_, Operation, Mode} <- Us,
                   [M] <- [Bound(N, effect_of(Operation))], lists:member(M, Names),
                   not lists:member({Operation, Mode}, maps:get(M, Serves, []))],
    %% Both images carry a digest of the signature of each remote effect, each computed
    %% from its own program. Where the bound member serves the effect at all, they must be equal.
    PeerSigned = maps:from_list([{N, Sg} || {N, peer, {ok, {peer, _, _, _, Sg}}} <- Declared]),
    Unsigned = [[N, M, <<"signature">>, Effect]
                || {N, caller, {ok, {caller, _, _, Signed}}} <- Declared, {Effect, Digest} <- Signed,
                   [M] <- [Bound(N, Effect)], lists:member(M, Names),
                   lists:any(fun({Operation, _}) -> effect_of(Operation) =:= Effect end, maps:get(M, Serves, [])),
                   proplists:get_value(Effect, maps:get(M, PeerSigned, [])) =/= Digest],
    Stores = maps:from_list([{N, case D of {ok, {peer, HasStore, _, _, _}} -> HasStore; _ -> false end} || {N, _, D} <- Declared]),
    Always = Unbound ++ Unknown,
    Refusals = Always ++ case map_get(start_check, Spec) of true -> Missing; false -> [] end ++ Storeless ++ Unserved ++ Unsigned,
    Base = #{assembled => false, declared => Wanted, refusals => Always ++ Missing ++ Storeless ++ Unserved ++ Unsigned},
    if
        Bad =/= [] -> {{error, {manifest, Bad}}, Base};
        Refusals =/= [] -> {{refused, Refusals}, Base#{refusals := Refusals}};
        true -> start_members(Spec#{stores => Stores}, Base#{refusals := []})
    end.

start_members(Spec = #{members := Members, connections := Edges, defects := Defects, stores := Stores}, Base) ->
    Has = fun(Defect) -> lists:member(Defect, Defects) end,
    %% A defect of the peer image's runtime is a word on its command line.
    Words = [{<<"non-idempotent-peer">>, " non-idempotent"}, {<<"reply-before-commit">>, " reply-before-commit"},
             {<<"replay-different-argument">>, " replay-different-argument"}, {<<"read-only-writes">>, " read-only-writes"},
             {<<"writes-without-record">>, " writes-without-record"}, {<<"record-without-writes">>, " record-without-writes"},
             {<<"torn-commit">>, " torn-commit"}, {<<"stale-reads">>, " stale-reads"}],
    Options = fun(peer) ->
                      case [Word || {Defect, Word} <- Words, Has(Defect)] of
                          [Word | _] -> Word;
                          [] -> ""
                      end;
                 (caller) -> ""
              end,
    Pids = maps:from_list(
             [begin
                  {ok, Pid} = supervisor:start_child(fenrir_member_sup,
                                [M#{tender => maps:get(tender, Spec), dir => maps:get(dir, Spec),
                                    life_ms => maps:get(life_ms, Spec), options => Options(maps:get(kind, M)),
                                    store => maps:get(maps:get(name, M), Stores)}]),
                  {maps:get(name, M), Pid}
              end || M <- Members]),
    Order = [maps:get(name, M) || M <- Members],
    S = Base#{assembled := true, pids => Pids, order => Order, edges => Edges, defects => Defects,
              kinds => maps:from_list([{maps:get(name, M), maps:get(kind, M)} || M <- Members]),
              members => maps:from_list([{N, #{status => down, pending => none, inbox => [], next => idle}} || N <- Order]),
              net => [], handed => [], issued => [], tags => maps:from_list([{N, 1} || N <- Order]), attempts => #{},
              budget => {maps:get(crashes, Spec), maps:get(duplicates, Spec), maps:get(supervisor_restarts, Spec)}, log => [],
              acts => #{}, kill_in_act => [], incarnations => 1, in_commit => []},
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
                        {ok, Peer, Operation, Key, Argument} ->
                            Next = {request, Peer, integer_to_binary(Key), {Operation, Argument}, maps:get(seq, Record)},
                            settle(Names, S#{members := Members#{Name := M#{next := Next}}});
                        {ok, Peer, Operation, read} ->
                            %% No key: the request is this one attempt, named after the number it will get.
                            Rid = <<"read-", (integer_to_binary(maps:get(Name, maps:get(tags, S))))/binary>>,
                            Next = {request, Peer, Rid, {Operation, read}, maps:get(seq, Record)},
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

enabled_steps(S = #{order := Order, members := Members, net := Net, budget := {Crashes, Duplicates, Restarts}}) ->
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
               %% not-delivered: only for a request id that does not count as
               %% handed over. Whether the peer is up or down does not matter.
               [{timeout, Tag}] ++
               [{not_delivered, Tag} || defect(<<"not-delivered-after-handover">>, S)
                                            orelse not lists:member({Name, Peer, Rid}, maps:get(handed, S))];
           _ -> []
       end || Name <- Order]),
    Crash = [{crash, Name} || Name <- Order, Up(Name), Crashes > 0],
    %% A kill between a peer's commit and its reply: where acting would apply,
    %% which is read from the peer's durable store, not from the event log.
    %% A read-only request commits nothing, so there is no such place in acting on one.
    CommitCrash = [{crash_after_commit, Name, Tag}
                   || Crashes > 0, {act, Name, Tag} <- Act,
                      Entry <- [hd(maps:get(inbox, maps:get(Name, Members)))], element(2, element(4, Entry)) =/= read,
                      not recorded(Name, Entry, S)],
    Restart = [{restart, Name} || Name <- Order, Down(Name)],
    Program ++ Link ++ Act ++ Waiting ++ Crash ++ CommitCrash ++ Restart ++ [{supervisor_restart} || Restarts > 0].

%% Whether the peer's durable store has a reply record for the request id of an
%% inbox entry. The store is on the host side and is the only place that says so.
recorded(Name, {_, Caller, Rid, _, _}, S) ->
    case fenrir_member:store(pid(Name, S)) of
        #{records := Records} -> lists:any(fun({C, K, _, _, _}) -> C =:= Caller andalso integer_to_binary(K) =:= Rid end, Records);
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
label({not_delivered, Tag}) -> [<<"not-delivered">>, tag(Tag)];
label({crash, Name}) -> [<<"crash">>, Name];
label({crash_after_commit, Name, Tag}) -> [<<"crash-after-commit">>, Name, tag(Tag)];
label({restart, Name}) -> [<<"restart">>, Name];
label({supervisor_restart}) -> [<<"supervisor-restart">>].

%% A command names a step by its label or by a prefix of it; an act may carry
%% the expected applied/replayed, and discard-reply names the same step as
%% deliver-reply. What happened is what the returned label says.
matches([<<"discard-reply">> | Rest], Label) -> matches([<<"deliver-reply">> | Rest], Label);
matches(Command, Label) -> lists:prefix(Command, Label) orelse lists:prefix(Label, Command).

%% The steps a command names. ["crash", Name, "in-commit"] is the step crash of a
%% peer, taken by a kill placed inside its commit: possible where a
%% crash-after-commit of that peer is enabled, which is where acting would commit.
in_commit([<<"crash">>, Name, <<"in-commit">>], Enabled) ->
    [{crash_in_commit, Name, Tag} || {crash_after_commit, N, Tag} <- Enabled, N =:= Name];
in_commit(Command, Enabled) -> [E || E <- Enabled, matches(Command, label(E))].

%% ---------- taking a step ----------

member(Name, #{members := Members}) -> maps:get(Name, Members).
set_member(Name, M, S = #{members := Members}) -> S#{members := Members#{Name := M}}.
pid(Name, #{pids := Pids}) -> maps:get(Name, Pids).

%% Give the caller the one outcome of the perform it is suspended in.
outcome(Name, Seq, Code, Value, S) ->
    case fenrir_member:put(pid(Name, S), outcome, Seq, fenrir_wire:outcome_payload(Code, Value), grant) of
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
         issued := lists:usort([{Name, Peer, Rid} | maps:get(issued, S)]),
         attempts := Attempts#{Tag => {open, Seq}}}};
take_step({refuse, Name, Peer, Rid}, S = #{tags := Tags, attempts := Attempts}) ->
    %% The backstop behind the start-time check: nothing is put in flight.
    M = #{next := {request, Peer, Rid, _, Seq}} = member(Name, S),
    N = maps:get(Name, Tags),
    case outcome(Name, Seq, not_delivered, none, S) of
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
    Payload = case Argument of
                  {Operation, read} -> fenrir_wire:call_payload(Caller, Operation, read);
                  {Operation, Value} -> fenrir_wire:call_payload(Caller, Operation, binary_to_integer(Rid), Value)
              end,
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
take_step({duplicate, Message}, S = #{net := Net, budget := {Crashes, Duplicates, Restarts}}) ->
    {ok, label({duplicate, Message}), S#{net := lists:sort([Message | Net]), budget := {Crashes, Duplicates - 1, Restarts}}};
take_step({act, Name, Tag}, S0 = #{net := Net, acts := Acts, kill_in_act := Armed}) ->
    %% The peer image is let run on the oldest request in its inbox. Its reply
    %% record says whether it applied the request, replayed a recorded reply, or
    %% refused a key it has applied with another argument (conflict).
    M = #{inbox := [Entry = {Tag, Caller, Rid, _, Seq} | Inbox]} = member(Name, S0),
    Pid = pid(Name, S0),
    Nth = maps:get(Name, Acts, 0) + 1,
    S = S0#{acts := Acts#{Name => Nth}},
    Before = recorded(Name, Entry, S),
    case lists:member({Name, Nth}, Armed) of
        false -> ok = fenrir_member:grant(Pid);
        true ->
            %% Test only: an outside kill placed after the commit. Not recorded.
            ok = fenrir_member:grant_hold(Pid, reply),
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
                {ok, trapped, trapped} ->
                    %% The peer's program trapped: nothing was committed, and there is no reply to carry.
                    {ok, label({act, Name, Tag}) ++ [<<"trapped">>], set_member(Name, M#{inbox := Inbox}, S)};
                {ok, How, Value} ->
                    S1 = set_member(Name, M#{inbox := Inbox}, S),
                    {ok, label({act, Name, Tag}) ++ [atom_to_binary(How)],
                     S1#{net := lists:sort([{rep, Tag, Caller, Name, Rid, Value} | Net])}};
                malformed -> {error, {malformed_reply, Name}, S}
            end;
        {ok, _} -> {error, {malformed_reply, Name}, S};
        Other -> {error, {no_reply, Name, Other}, S}
    end;
take_step({crash_in_commit, Name, _Tag}, S = #{budget := {Crashes, Duplicates, Restarts}}) ->
    %% The peer is let run on the oldest request in its inbox, told to stop inside
    %% its commit. When its store file shows the request's reply record written
    %% beyond what the header counts, it is killed. What happened is then read
    %% from the store: nothing of the request is counted (crash), or its record is
    %% (crash-after-commit: a commit that was not atomic, or was already complete).
    #{inbox := [Entry = {Tag, _, _, _, _} | _]} = member(Name, S),
    Pid = pid(Name, S),
    Before = tail_of(Name, S),
    ok = fenrir_member:grant_hold(Pid, commit),
    Seen = await_tail(Name, Entry, Before, S, erlang:monotonic_time(millisecond) + ?SETTLE_MS, erlang:monotonic_time(millisecond) + 500),
    Killed = fenrir_member:kill(Pid),
    Spent = S#{budget := {Crashes - 1, Duplicates, Restarts}},
    case {Seen, Killed} of
        {{tail, Tail}, ok} ->
            {ok, Crash, S1} = crashed(Name, Spent),
            Note = #{member => Name, uncounted => [tail_item(T) || T <- Tail]},
            S2 = S1#{in_commit := [Note | maps:get(in_commit, S1)]},
            case recorded(Name, Entry, S2) of
                true -> {ok, label({crash_after_commit, Name, Tag}), S2};
                false -> {ok, Crash, S2}
            end;
        Other -> {error, {crash_in_commit, Name, Other}, S}
    end;
take_step({timeout, Tag = {Name, _}}, S) ->
    #{pending := {Tag, _, _, Seq}} = member(Name, S),
    case outcome(Name, Seq, timed_out, none, S) of
        ok -> {ok, label({timeout, Tag}), resolved(Name, Tag, {timed_out, Seq}, S)};
        {error, Reason} -> {error, Reason, S}
    end;
take_step({not_delivered, Tag = {Name, _}}, S = #{net := Net}) ->
    %% Enabled only for a request id that does not count as handed over. Every
    %% copy still held, of every attempt, is destroyed before the report.
    #{pending := {Tag, Peer, Rid, Seq}} = member(Name, S),
    Kept = [M || M <- Net, not is_request_for(M, Name, Peer, Rid)],
    case outcome(Name, Seq, not_delivered, none, S) of
        ok -> {ok, label({not_delivered, Tag}), resolved(Name, Tag, closed, S#{net := Kept})};
        {error, Reason} -> {error, Reason, S}
    end;
take_step({crash, Name}, S = #{budget := {Crashes, Duplicates, Restarts}}) ->
    case fenrir_member:kill(pid(Name, S)) of
        ok -> crashed(Name, S#{budget := {Crashes - 1, Duplicates, Restarts}});
        {error, Reason} -> {error, {crash, Name, Reason}, S}
    end;
take_step({crash_after_commit, Name, Tag}, S = #{net := Net, budget := {Crashes, Duplicates, Restarts}}) ->
    %% The peer is let run on the oldest request in its inbox, told to stop
    %% before it replies. When its store shows the commit, it is killed.
    M = #{inbox := [Entry = {Tag, Caller, Rid, _, Seq} | Inbox]} = member(Name, S),
    Pid = pid(Name, S),
    ok = fenrir_member:grant_hold(Pid, reply),
    Seen = await_commit(Name, Entry, S, erlang:monotonic_time(millisecond) + ?SETTLE_MS),
    Killed = fenrir_member:kill(Pid),
    Spent = S#{budget := {Crashes - 1, Duplicates, Restarts}},
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
    end;
take_step({supervisor_restart}, S = #{budget := {Crashes, Duplicates, Restarts}}) ->
    %% Nothing is done here but the bookkeeping: step/1 kills this process once
    %% the step is in the log and the journal, and init/1 of the next one does the rest.
    {restart, label({supervisor_restart}), S#{budget := {Crashes, Duplicates, Restarts - 1}}}.

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

%% The records the peer's store file holds beyond its header's count.
tail_of(Name, S) ->
    case fenrir_member:store(pid(Name, S)) of
        #{tail := Tail} -> Tail;
        _ -> []
    end.

tail_item({cell, K, V}) -> [<<"cell">>, integer_to_binary(K), integer_to_binary(V)];
tail_item({stored, Caller, K, Operation, A, V}) -> [<<"stored">>, Caller, integer_to_binary(K), Operation, int(A), int(V)].

%% Wait for the peer's store file to show, beyond its header's count, the reply
%% record of the inbox entry's request id: every record of the commit is then
%% written and none is counted. Before is the tail as it was when the request
%% was granted: records left there by an earlier commit that never happened do
%% not count as this one's, unless nothing else appears within Patience.
await_tail(Name, Entry = {_, Caller, Rid, _, _}, Before, S, Deadline, Patience) ->
    Tail = tail_of(Name, S),
    Written = lists:any(fun({stored, C, K, _, _, _}) -> C =:= Caller andalso integer_to_binary(K) =:= Rid; (_) -> false end, Tail),
    Now = erlang:monotonic_time(millisecond),
    case Written andalso (Tail =/= Before orelse Now >= Patience) of
        true -> {tail, Tail};
        false ->
            case fenrir_member:take(pid(Name, S), 1) of
                {ok, Record} -> {replied, Record};
                timeout when Now >= Deadline -> timeout;
                timeout -> await_tail(Name, Entry, Before, S, Deadline, Patience);
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
