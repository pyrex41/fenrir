%% Who chooses the next step of the relay.
%%   list    a schedule: the steps to take, in order. A step that is not
%%           enabled ends the run with status step-not-enabled.
%%   seeded  the next step is chosen among the enabled ones by a fixed
%%           pseudo-random sequence, so one seed is one schedule.
%%   free    the free-running policy: deliver at once, never drop or duplicate,
%%           report timed-out (or peer-down, when the contract allows it) when a
%%           caller has waited timeout_ms on the wall clock, restart a member
%%           that is down, and record as a crash a member whose OS process is
%%           found dead. This is the only mode in which time matters. For tests,
%%           kill = [{Member, N}] kills that member's OS process from outside the
%%           relay once N steps have been taken, and kill_in_act = [{Member, N}]
%%           kills it inside its Nth act, after its durable commit and before
%%           its reply.
-module(fenrir_run).
-export([run/1]).

%% #{status, error} merged into the run report by fenrir_main.
run(#{mode := list, steps := Steps}) -> list(Steps, 0);
run(#{mode := seeded, seed := Seed, max_steps := Max}) -> seeded(Seed, Max);
run(#{mode := free, timeout_ms := Timeout, deadline_ms := Deadline, kill := Kill, kill_in_act := InAct}) ->
    [ok = fenrir_relay:arm_kill_in_act(Name, N) || {Name, N} <- InAct],
    free(#{timeout => Timeout, deadline => erlang:monotonic_time(millisecond) + Deadline}, Kill, 0, #{}).

failed(Reason) -> #{status => <<"error">>, error => unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}.

list([], _) -> #{status => <<"completed">>};
list([Command | Rest], Index) ->
    case fenrir_relay:step(Command) of
        {ok, _} -> list(Rest, Index + 1);
        {not_enabled, Enabled} ->
            #{status => <<"step-not-enabled">>,
              not_enabled => #{index => integer_to_binary(Index), step => Command, enabled => Enabled}};
        {error, Reason} -> failed(Reason)
    end.

%% A 64-bit linear congruential generator (Knuth's MMIX constants): the choice
%% depends on the seed and on nothing else, on any OTP release.
next(X) -> (X * 6364136223846793005 + 1442695040888963407) band 16#ffffffffffffffff.

%% Steps that carry a request forward are eight times as likely as the others,
%% so that runs get past the first timeout often enough to be interesting.
weight([Kind | _]) ->
    case lists:member(Kind, [<<"issue">>, <<"refuse">>, <<"finish">>, <<"deliver-request">>, <<"deliver-reply">>, <<"act">>]) of
        true -> 8;
        false -> 1
    end.

pick([Label | Labels], N) ->
    W = weight(Label),
    if N < W -> Label; true -> pick(Labels, N - W) end.

seeded(_, 0) -> #{status => <<"completed">>, stopped => <<"max-steps">>};
seeded(X, Left) ->
    case fenrir_relay:enabled() of
        {ok, []} -> #{status => <<"completed">>, stopped => <<"no-step-enabled">>};
        {ok, Enabled} ->
            X1 = next(X),
            Total = lists:sum([weight(L) || L <- Enabled]),
            case fenrir_relay:step(pick(Enabled, (X1 bsr 33) rem Total)) of
                {ok, _} -> seeded(X1, Left - 1);
                {not_enabled, _} -> failed(chosen_step_not_enabled);
                {error, Reason} -> failed(Reason)
            end;
        {error, Reason} -> failed(Reason)
    end.

%% Taken: steps taken so far. Since: when each waiting attempt (by its timeout
%% label) was first seen waiting.
free(Options = #{timeout := Timeout, deadline := Deadline}, Kill, Taken, Since) ->
    [fenrir_relay:inject_kill(Name) || {Name, N} <- Kill, N =:= Taken],
    Kill1 = [K || K = {_, N} <- Kill, N =/= Taken],
    {ok, Dead} = fenrir_relay:observe(),
    Now = erlang:monotonic_time(millisecond),
    case fenrir_relay:enabled() of
        _ when Now >= Deadline -> #{status => <<"completed">>, stopped => <<"deadline">>};
        {ok, Enabled} ->
            Kind = fun(K) -> [L || L = [K1 | _] <- Enabled, K1 =:= K] end,
            Forward = lists:append([Kind(K) || K <- [<<"restart">>, <<"issue">>, <<"refuse">>, <<"finish">>,
                                                     <<"deliver-request">>, <<"act">>, <<"deliver-reply">>]]),
            Waiting = Kind(<<"timeout">>),
            Since1 = maps:from_list([{W, maps:get(W, Since, Now)} || W <- Waiting]),
            Expired = [W || W <- Waiting, Now - maps:get(W, Since1) >= Timeout],
            Step = case {Forward, Expired} of
                       {[First | _], _} -> First;
                       {[], [[_, Tag] | _]} ->
                           %% peer-down when the contract allows it for this attempt, timed-out otherwise.
                           case lists:member([<<"peer-down">>, Tag], Enabled) of
                               true -> [<<"peer-down">>, Tag];
                               false -> [<<"timeout">>, Tag]
                           end;
                       {[], []} -> none
                   end,
            case {Step, Waiting, Kill1} of
                {none, [], []} -> #{status => <<"completed">>, stopped => <<"quiescent">>};
                {none, _, _} -> timer:sleep(1), free(Options, Kill1, Taken + length(Dead), Since1);
                _ ->
                    case fenrir_relay:step(Step) of
                        {ok, _} -> free(Options, Kill1, Taken + length(Dead) + 1, Since1);
                        {not_enabled, _} -> failed({free_step_not_enabled, Step});
                        {error, Reason} -> failed(Reason)
                    end
            end;
        {error, Reason} -> failed(Reason)
    end.
