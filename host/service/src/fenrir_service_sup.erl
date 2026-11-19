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
-export([start_link/1, init/1, worker_sup_init/1, prepare/2, cut_over/2]).

start_link(Config) ->
    case fenrir_authority:validate(Config) of
        {ok, Bindings} -> start_checked(Config#{submit_credentials => Bindings});
        {error, _} = E -> E
    end.

start_checked(Config = #{a4 := #{operator := Operator, handler := Handler, launch_dir := Dir}}) ->
    Count = maps:get(workers, Config, 1),
    Mutant = maps:get(mutant, Config, normal),
    case is_pid(Operator) andalso node(Operator) =:= node() andalso is_process_alive(Operator)
            andalso is_integer(Count) andalso Count >= 1 andalso Count =< 64
            andalso Mutant =:= normal andalso filelib:is_dir(Dir) of
        true ->
            case fenrir_a4_image:admit_handler(Handler, handler_v2, maps:get(tenants, Config)) of
                {ok, Pin, Domain} ->
                    supervisor:start_link({local, ?MODULE}, ?MODULE, {top, Config#{a4_v2 => {Pin, Domain}}});
                {error, _} = Error -> Error
            end;
        false -> {error, invalid_a4_supervisor_config}
    end;
start_checked(#{a4 := _}) -> {error, invalid_a4_supervisor_config};
start_checked(Config) ->
    case fenrir_worker:check_image(maps:get(image, Config)) of
        {ok, _} -> supervisor:start_link({local, ?MODULE}, ?MODULE, {top, Config});
        {error, E} -> {error, E}
    end.

init({top, Config}) ->
    Ns = lists:seq(1, maps:get(workers, Config, 1)),
    V1 = [list_to_atom("w" ++ integer_to_list(I)) || I <- Ns],
    Store0 = #{db => maps:get(db, Config), tenants => maps:get(tenants, Config),
               mutant => maps:get(mutant, Config, normal)},
    {Workers, Store} = case maps:find(a4, Config) of
        {ok, #{operator := Operator}} ->
            V2 = [list_to_atom("a4w" ++ integer_to_list(I)) || I <- Ns],
            {#{v1 => V1, v2 => V2}, Store0#{maintenance_operator => Operator}};
        error -> {V1, Store0}
    end,
    Children =
        [#{id => fenrir_holder, start => {fenrir_holder, start_link, []}},
         #{id => fenrir_store, start => {fenrir_store, start_link, [Store]}},
         #{id => fenrir_worker_sup, type => supervisor,
           start => {supervisor, start_link, [{local, fenrir_worker_sup}, ?MODULE, {workers, Workers, Config}]}},
         #{id => fenrir_front, start => {fenrir_front, start_link, [Workers, maps:get(submit_credentials, Config)]}},
         #{id => fenrir_runner, start => {fenrir_runner, start_link, [maps:get(runner, Config, #{})]}}],
    {ok, {#{strategy => one_for_one, intensity => 1000, period => 10}, Children}};
init({workers, Workers, Config}) -> worker_sup_init({Workers, Config}).

worker_sup_init({#{v1 := V1, v2 := V2},
                 Config = #{a4 := #{handler := Handler, launch_dir := Dir}, a4_v2 := {P2, Domain}}}) ->
    Base = #{launcher => maps:get(launcher, Config), a4_launch_dir => Dir,
             console_dir => maps:get(console_dir, Config, "/tmp")},
    V2Specs = bank(v2, V2, Base#{image => Handler, a4_pin => P2}),
    case fenrir_store:routing_phase() of
        {ok, {v2, P2}} -> {ok, {worker_strategy(), V2Specs}};
        {ok, Phase} when Phase =:= v1; Phase =:= {prepared, P2}; Phase =:= {migrated, P2} ->
            %% Read v1 only after SQLite tells us that recovery may still
            %% require it. Durable v2 must never depend on retired bytes.
            Path = maps:get(image, Config, undefined),
            case fenrir_a4_image:admit_handler(Path, handler_v1, maps:get(tenants, Config)) of
                {ok, P1, Domain} ->
                    {ok, {worker_strategy(), bank(v1, V1, Base#{image => Path, a4_v1_pin => P1}) ++ V2Specs}};
                {ok, _, _} -> error(upgrade_request_domain_mismatch);
                {error, Why} -> error({v1_image_required, Why})
            end;
        {ok, _} -> error(durable_image_pin_mismatch);
        _ -> error(durable_phase_unavailable)
    end;
worker_sup_init({Workers, Config}) ->
    Opts = #{image => maps:get(image, Config), launcher => maps:get(launcher, Config),
             console_dir => maps:get(console_dir, Config, "/tmp")},
    {ok, {#{strategy => one_for_one, intensity => 1000, period => 10},
          [#{id => W, start => {fenrir_worker, start_link, [W, Opts#{name => W}]}} || W <- Workers]}}.

worker_strategy() -> #{strategy => one_for_one, intensity => 1000, period => 10}.

bank(Version, Names, Opts) ->
    [#{id => {Version, W}, start => {fenrir_worker, start_link, [W, Opts#{name => W}]}} || W <- Names].

%% Do not prepare an image the configured standby bank cannot run.
prepare(Handler, Migration) ->
    case fenrir_store:maintenance(state) of
        {ok, v1} ->
            case {fenrir_a4_image:admit(Handler, handler_v2), fenrir_a4_image:admit(Migration, migration)} of
                {{ok, HP}, {ok, MP}} ->
                    case v2_ready(HP) of
                        true -> fenrir_store:maintenance({prepare, HP, MP});
                        false -> {refused, v2_bank_not_ready}
                    end;
                {{error, Why}, _} -> {refused, Why};
                {_, {error, Why}} -> {refused, Why}
            end;
        {ok, _} -> {refused, wrong_phase};
        Error -> Error
    end.

%% Only the store's operator can cut over or resume retirement. The live front
%% selects the active bank from durable state, never from this housekeeping.
cut_over(Id, Handler) ->
    case fenrir_store:maintenance(state) of
        {ok, {Phase, Id, Pin, _}} when Phase =:= migrated; Phase =:= v2 ->
            case fenrir_a4_image:load(Handler, handler_v2, Pin) of
                {ok, _} -> activate_bank(Phase, Id, Pin);
                {error, Why} -> {refused, Why}
            end;
        {ok, _} -> {refused, wrong_preparation};
        Error -> Error
    end.

activate_bank(Phase, Id, Pin) ->
    case v2_ready(Pin) of
        true ->
            Result = case Phase of
                migrated -> fenrir_store:maintenance({cut_over, Id, Pin});
                v2 -> ok
            end,
            case Result of
                ok ->
                    case retire_v1() of
                        ok -> ok;
                        Error -> {cut_over_committed, Error}
                    end;
                Other -> Other
            end;
        false -> {refused, v2_bank_not_ready}
    end.

v2_ready(Pin) ->
    try supervisor:which_children(fenrir_worker_sup) of
        Children ->
            V2 = [{Id, Pid} || {Id = {v2, _}, Pid, worker, _} <- Children],
            V2 =/= [] andalso lists:all(fun({Id, Pid}) ->
                is_pid(Pid) andalso
                case supervisor:get_childspec(fenrir_worker_sup, Id) of
                    {ok, #{start := {fenrir_worker, start_link, [_, #{a4_pin := Pin, image := Path}]}}} ->
                        case fenrir_a4_image:load(Path, handler_v2, Pin) of
                            {ok, _} -> true;
                            _ -> false
                        end;
                    _ -> false
                end
            end, V2)
    catch exit:_ -> false end.

retire_v1() ->
    try
        Ids = [Id || {Id = {v1, _}, _, worker, _} <- supervisor:which_children(fenrir_worker_sup)],
        lists:foreach(fun(Id) ->
            ok = supervisor:terminate_child(fenrir_worker_sup, Id),
            ok = supervisor:delete_child(fenrir_worker_sup, Id)
        end, Ids),
        ok
    catch _:_ -> worker_retirement_unconfirmed end.
