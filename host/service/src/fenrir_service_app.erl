%% A3: the OTP application callback. The configuration map is the application
%% environment key `config` (db, tenants, image, launcher, console_dir, workers, mutant,
%% runner, optional submit_credentials); start refuses invalid credential bindings
%% or a failing capability manifest or image identity check.
%% The campaigns start the same tree through fenrir_node, which owns the control channel.
-module(fenrir_service_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, Config} = application:get_env(fenrir_service, config),
    fenrir_faults:init(),
    fenrir_service_sup:start_link(Config).

stop(_State) -> ok.
