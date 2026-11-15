%% Top of the tree. The relay holds the record of what was handed over, and the
%% member processes hold the ports: if either side fails, nothing it knew can be
%% trusted any more (spec/tc1/EFFECTS.md §12.9, "a supervisor that fails"), so
%% the whole tree stops and is not restarted.
-module(fenrir_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_all, intensity => 0, period => 1},
          [#{id => fenrir_member_sup, start => {fenrir_member_sup, start_link, []}, type => supervisor},
           #{id => fenrir_relay, start => {fenrir_relay, start_link, []}}]}}.
