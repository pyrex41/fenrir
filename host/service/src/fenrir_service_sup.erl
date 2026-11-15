%% A3: the supervision tree. Workers (each owning at most one Solo5 tender at a time)
%% are restarted; every piece of state that must survive is in SQLite, so a restart of
%% any child loses only volatile state (the front's outbox, an in-flight request).
%%
%%   fenrir_service_sup (one_for_one)
%%     fenrir_holder        owns the volatile_mailbox mutant's ETS table (otherwise idle)
%%     fenrir_store         the SQLite adapter (one connection, one port program)
%%     fenrir_worker_sup    one_for_one over the workers w1..wN
%%     fenrir_front         front API and the volatile outbox
%%     fenrir_runner        the job runner
%%
%% start_link(Config) refuses to start (returns {error, _}) when the capability manifest
%% check fails: fenrir_manifest is run here first, before any child is started, and
%% again by each worker before it would boot a tender.
-module(fenrir_service_sup).
-behaviour(supervisor).
-export([start_link/1, init/1, worker_sup_init/1]).

start_link(Config) ->
    case fenrir_worker:check_image(maps:get(image, Config)) of
        {ok, _} -> supervisor:start_link({local, ?MODULE}, ?MODULE, {top, Config});
        {error, E} -> {error, E}
    end.

init({top, Config}) ->
    Workers = [list_to_atom("w" ++ integer_to_list(I)) || I <- lists:seq(1, maps:get(workers, Config, 1))],
    Store = #{db => maps:get(db, Config), tenants => maps:get(tenants, Config),
              mutant => maps:get(mutant, Config, normal)},
    Children =
        [#{id => fenrir_holder, start => {fenrir_holder, start_link, []}},
         #{id => fenrir_store, start => {fenrir_store, start_link, [Store]}},
         #{id => fenrir_worker_sup, type => supervisor,
           start => {supervisor, start_link, [{local, fenrir_worker_sup}, ?MODULE, {workers, Workers, Config}]}},
         #{id => fenrir_front, start => {fenrir_front, start_link, [Workers]}},
         #{id => fenrir_runner, start => {fenrir_runner, start_link, [maps:get(runner, Config, #{})]}}],
    {ok, {#{strategy => one_for_one, intensity => 1000, period => 10}, Children}};
init({workers, Workers, Config}) -> worker_sup_init({Workers, Config}).

%% A4: every worker resolves its image from the durable upgrade state when it starts
%% (fenrir_worker:init/1, resolve): the configured image is the v1 image, the v2 image is
%% the one begin-upgrade recorded. A restart after cut-over therefore boots v2 workers.
worker_sup_init({Workers, Config}) ->
    persistent_term:put(fenrir_launcher, maps:get(launcher, Config)),
    persistent_term:put(fenrir_v1_image, maps:get(image, Config)),
    persistent_term:put(fenrir_console_dir, maps:get(console_dir, Config, "/tmp")),
    Opts = #{image => maps:get(image, Config), launcher => maps:get(launcher, Config),
             console_dir => maps:get(console_dir, Config, "/tmp"), resolve => true,
             mutant => maps:get(mutant, Config, normal)},
    {ok, {#{strategy => one_for_one, intensity => 1000, period => 10},
          [#{id => W, start => {fenrir_worker, start_link, [W, Opts#{name => W}]}} || W <- Workers]}}.
