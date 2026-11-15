%% Owns the ETS table of the volatile_mailbox mutant (jobs kept in memory, not in
%% SQLite). In the adapter the table exists and stays empty. It dies with the node.
-module(fenrir_holder).
-behaviour(gen_server).
-export([start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    case ets:info(fenrir_mailbox) of
        undefined -> ets:new(fenrir_mailbox, [named_table, public, set]);
        _ -> ok
    end,
    {ok, #{}}.

handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
