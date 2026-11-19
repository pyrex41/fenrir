%% What survives a restart of the relay (spec/tc1/EFFECTS.md §12.7,
%% supervisor-restart). After every call the relay leaves here its state less
%% its record of hand-overs and the messages in flight, and whether the call was
%% a supervisor-restart step. A relay that starts reads it back.
%% This is memory of another Erlang process, not durable storage: it survives
%% the relay process, not the Erlang VM.
-module(fenrir_journal).
-behaviour(gen_server).
-export([start_link/0, put/2, take/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Planned: the relay is about to be killed by its own supervisor-restart step.
put(State, Planned) -> gen_server:call(?MODULE, {put, State, Planned}, 20000).
%% none | {State, Planned}. A second take without a put in between says false.
take() -> gen_server:call(?MODULE, take, 20000).

init([]) -> {ok, none}.

handle_call({put, State, Planned}, _From, _) -> {reply, ok, {State, Planned}};
handle_call(take, _From, none) -> {reply, none, none};
handle_call(take, _From, {State, Planned}) -> {reply, {State, Planned}, {State, false}}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
