%% The member processes. A member process is not restarted by OTP: restarting an
%% image is a step of the contract (restart), taken and logged by the relay.
-module(fenrir_member_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => simple_one_for_one, intensity => 0, period => 1},
          [#{id => fenrir_member, start => {fenrir_member, start_link, []}, restart => temporary, shutdown => 5000}]}}.
