%% Top of the tree. The member processes hold the ports; the journal holds what
%% survives a restart of the relay; the relay holds the record of what was
%% handed over and the messages in flight. The relay comes last, so that it can
%% be killed and started again (the contract's supervisor-restart step,
%% spec/tc1/EFFECTS.md §12.7) without anything else being touched: the guests
%% keep running. If the member supervisor or the journal fails, the relay is
%% restarted with nothing to go on and the run ends in an error.
-module(fenrir_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => rest_for_one, intensity => 10, period => 1},
          [#{id => fenrir_member_sup, start => {fenrir_member_sup, start_link, []}, type => supervisor},
           #{id => fenrir_journal, start => {fenrir_journal, start_link, []}},
           #{id => fenrir_relay, start => {fenrir_relay, start_link, []}}]}}.
