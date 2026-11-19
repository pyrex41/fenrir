%% Explicit local operator operations. The store verifies the operator PID;
%% this module does not create another source of authority.
-module(fenrir_a4_upgrade).
-export([prepare/2, migrate/3, cut_over/2]).

prepare(Handler, Migration) ->
    case {fenrir_a4_image:admit(Handler, handler_v2), fenrir_a4_image:admit(Migration, migration)} of
        {{ok, HP}, {ok, MP}} -> fenrir_store:maintenance({prepare, HP, MP});
        {{error, E}, _} -> {refused, E};
        {_, {error, E}} -> {refused, E}
    end.

cut_over(Id, Handler) ->
    case fenrir_a4_image:admit(Handler, handler_v2) of
        {ok, Pin} -> fenrir_store:maintenance({cut_over, Id, Pin});
        {error, E} -> {refused, E}
    end.

migrate(Id, Path, Opts) ->
    case fenrir_a4_image:admit(Path, migration) of
        {ok, Pin} -> migrate_admitted(Id, Path, Pin, Opts);
        {error, E} -> {refused, E}
    end.

migrate_admitted(Id, Path, Pin, Opts) ->
    Parent = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        receive
            {Parent, Token} ->
                %% If launch or protocol fails, the store's owner monitor
                %% invalidates this session. No token travels across a port.
                Parent ! {self(), fenrir_worker:run_migration(Path, Id, Pin, Opts#{migration_token => Token})}
        after 10000 -> exit(no_session)
        end
    end),
    case fenrir_store:maintenance({open, Id, Pin, Pid}) of
        {ok, Token} ->
            Pid ! {Parent, Token},
            receive
                {Pid, R} -> demonitor(Mon, [flush]), R;
                {'DOWN', Mon, process, Pid, Reason} -> {indeterminate, {migration_process_exit, Reason}}
            end;
        Other -> exit(Pid, kill), demonitor(Mon, [flush]), Other
    end.
