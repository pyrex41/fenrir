%% A3: the service node's control channel for the campaign driver (and for any client
%% that drives the service from outside the node). The node is a separate BEAM OS
%% process; the channel is fds 3 (in) and 4 (out), {packet,4} with external term
%% format, set up by host/service/priv/node-launch. Each command gets one answer, except
%% run_jobs, which streams the runner's delivery notices before its answer. The driver
%% can kill this OS process at any moment; nothing here is durable.
%%
%%   erl -noshell -noinput -pa EBIN -run fenrir_node main CONFIG
%% CONFIG is a file holding one Erlang map (consulted): db, tenants, image, launcher,
%% console_dir, workers, mutant, runner.
-module(fenrir_node).
-export([main/1]).

main([ConfigFile]) ->
    {ok, [Config]} = file:consult(ConfigFile),
    Chan = open_port({fd, 3, 4}, [{packet, 4}, binary, eof]),
    fenrir_faults:init(),
    process_flag(trap_exit, true),
    case catch fenrir_service_sup:start_link(Config) of
        {ok, Sup} ->
            send(Chan, {started, #{beam_os_pid => list_to_integer(os:getpid()),
                                   otp => erlang:system_info(otp_release),
                                   erts => erlang:system_info(version),
                                   sqlite_port_os_pid => fenrir_store:port_os_pid()}}),
            loop(Chan, Sup);
        Other ->
            send(Chan, {start_failed, Other}),
            timer:sleep(100),
            erlang:halt(3)
    end.

send(Chan, Term) -> port_command(Chan, term_to_binary(Term)).

loop(Chan, Sup) ->
    receive
        {Chan, {data, Bin}} ->
            Cmd = binary_to_term(Bin),
            Answer = try command(Cmd, Chan) catch C:E:Stack -> {error, {C, E, hd(Stack ++ [none])}} end,
            send(Chan, Answer),
            after_answer(Cmd),
            case Cmd of stop -> erlang:halt(0); _ -> loop(Chan, Sup) end;
        {Chan, eof} -> erlang:halt(0);
        {'EXIT', Sup, R} -> send(Chan, {supervisor_exit, R}), erlang:halt(4);
        _ -> loop(Chan, Sup)
    end.

%% The front's fault point after a response has been written to the client.
after_answer({submit, _, _, _, _}) -> fenrir_faults:hit(f1_after_response, #{});
after_answer({complete, _, _, _}) -> fenrir_faults:hit(f1_after_response, #{});
after_answer(_) -> ok.

command({submit, T, K, D, P}, _) -> fenrir_front:submit(T, K, D, P);
command({complete, T, J, Ok}, _) -> fenrir_front:complete(T, J, Ok);
command({respond, E}, _) -> fenrir_front:respond(E);
command(outbox, _) -> fenrir_front:outbox();
command(snapshot, _) -> fenrir_store:snapshot();
command(pending, _) -> fenrir_store:pending_jobs();
command({run_jobs, Opts}, Chan) ->
    N = fenrir_runner:run_once(fun(Note) -> send(Chan, {note, Note}) end, Opts),
    {jobs_done, N};
command({arm, Point, Action, Count}, _) -> fenrir_faults:arm(Point, Action, Count);
command(disarm, _) -> fenrir_faults:disarm(), catch fenrir_store:arm_port(disarm, 1), ok;
command({arm_port, Kind, N}, _) -> fenrir_store:arm_port(Kind, N);
command(fired, _) -> fenrir_faults:fired();
command(pids, _) -> #{beam => list_to_integer(os:getpid()), sqlite_port => fenrir_store:port_os_pid()};
command({concurrent, Requests}, _) -> concurrent(Requests);
%% A4: the upgrade orchestration API (fenrir_upgrade), and requests started now and
%% awaited later (a run held at a paused fault point across an upgrade step).
command({begin_upgrade, V2Image, MigImage}, _) -> fenrir_upgrade:begin_upgrade(V2Image, MigImage);
command(abort_upgrade, _) -> fenrir_upgrade:abort_upgrade();
command(migrate, _) -> fenrir_upgrade:migrate();
command(cut_over, _) -> fenrir_upgrade:cut_over();
command(upgrade_state, _) -> fenrir_upgrade:state();
command({async, Req}, _) ->
    async_table(),
    T = erlang:unique_integer([positive]),
    spawn(fun() -> R = try one(Req) catch C:E -> {error, {C, E}} end, ets:insert(fenrir_async, {T, R}) end),
    {ticket, T};
command({await, T}, _) -> await(T, 6000);
command({release, Point}, _) -> fenrir_faults:release(Point);
command({paused, Point}, _) -> wait_paused(Point, 500);
command(ping, _) -> pong;
command(diag, _) ->
    Sup = whereis(fenrir_worker_sup),
    #{children => catch supervisor:which_children(fenrir_worker_sup),
      worker_sup => catch erlang:process_info(Sup, [current_stacktrace, message_queue_len, status]),
      w1 => whereis(w1)};
command(stop, _) -> ok.

one({submit, T, K, D, P}) -> fenrir_front:submit(T, K, D, P);
one({complete, T, J, Ok}) -> fenrir_front:complete(T, J, Ok);
one(migrate) -> fenrir_upgrade:migrate();
%% A worker the supervisor does not know (a stale v1 worker left behind by an
%% upgrade): it keeps the image it was started with, so only the store can fence it.
one({detached, Req}) ->
    Name = list_to_atom("detached" ++ integer_to_list(erlang:unique_integer([positive]))),
    Opts = #{image => persistent_term:get(fenrir_v1_image), launcher => persistent_term:get(fenrir_launcher),
             console_dir => persistent_term:get(fenrir_console_dir), name => Name},
    {ok, W} = gen_server:start({local, Name}, fenrir_worker, Opts, []),
    try fenrir_front:request_on(Name, Req) after gen_server:stop(W) end.

async_table() ->
    case ets:info(fenrir_async) of
        undefined -> ets:new(fenrir_async, [named_table, public, set]), ok;
        _ -> ok
    end.

await(_, 0) -> {error, await_timeout};
await(T, N) ->
    case ets:lookup(fenrir_async, T) of
        [{T, R}] -> ets:delete(fenrir_async, T), {done, R};
        [] -> timer:sleep(20), await(T, N - 1)
    end.

%% true once a process is held at Point (at most N x 20 ms).
wait_paused(_, 0) -> false;
wait_paused(Point, N) ->
    case fenrir_faults:paused(Point) of
        true -> true;
        false -> timer:sleep(20), wait_paused(Point, N - 1)
    end.

%% Run requests at once, one caller process each (the workers are picked round-robin).
concurrent(Requests) ->
    Self = self(),
    T0 = erlang:monotonic_time(microsecond),
    Pids = [spawn_link(fun() ->
                               R = case Req of
                                       {submit, T, K, D, P} -> fenrir_front:submit(T, K, D, P);
                                       {complete, T, J, Ok} -> fenrir_front:complete(T, J, Ok)
                                   end,
                               Self ! {done, self(), R, erlang:monotonic_time(microsecond)}
                       end) || Req <- Requests],
    Results = [receive {done, P, R, T1} -> {R, T1 - T0} end || P <- Pids],
    {concurrent_done, Results, erlang:monotonic_time(microsecond) - T0}.
