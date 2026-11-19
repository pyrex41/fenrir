%% A3: the job runner. It reads the pending jobs from the store (the durable job
%% records: SQLite, except in the volatile_mailbox mutant) and delivers each through a
%% worker as complete(T, J, Ok). Delivery is AT LEAST ONCE: a job stays pending until a
%% delivery commit has finished it, so a delivery lost to a crash is made again on a
%% later pass, and the handler's Pending guard absorbs a duplicate. The job's own work
%% is a deterministic function of (tenant, job): ok unless (7T + 3J) mod 5 = 0.
%%
%% run_once(Notify, Opts) makes one pass; Notify gets {deliver, T, J, Ok} before and
%% {delivered, T, J, Ok, Outcome} after each delivery (the campaign recorder). With
%% Opts #{duplicate => true} every job is delivered twice, the second time with the
%% other outcome. A periodic mode (#{interval => Ms}) runs passes on a timer.
-module(fenrir_runner).
-behaviour(gen_server).
-export([start_link/1, run_once/2, outcome/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Opts) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

outcome(T, J) -> (7 * T + 3 * J) rem 5 =/= 0.

run_once(Notify, Opts) ->
    Jobs = fenrir_store:pending_jobs(),
    lists:foreach(
      fun({T, J, _R}) ->
              Ok = outcome(T, J),
              deliver(Notify, T, J, Ok),
              maps:get(duplicate, Opts, false) andalso deliver(Notify, T, J, not Ok)
      end, Jobs),
    length(Jobs).

deliver(Notify, T, J, Ok) ->
    Notify({deliver, T, J, Ok}),
    {Out, _} = fenrir_front:deliver(T, J, Ok),
    Notify({delivered, T, J, Ok, Out}),
    true.

init(Opts) ->
    case maps:get(interval, Opts, none) of
        none -> ok;
        Ms -> erlang:send_after(Ms, self(), tick)
    end,
    {ok, Opts}.

handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(tick, S = #{interval := Ms}) ->
    catch run_once(fun(_) -> ok end, S),
    erlang:send_after(Ms, self(), tick),
    {noreply, S};
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
