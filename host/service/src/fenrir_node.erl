%% A3: PRIVILEGED campaign control channel, not client ingress. Its peer chooses
%% which fixture principal to impersonate, can deliver jobs, read all tenants and
%% inject faults. Never expose these fds to an untrusted client. Separate BEAM OS
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
    {ok, [RawConfig]} = file:consult(ConfigFile),
    %% This process is the privileged, per-boot campaign controller. A
    %% serialized PID from the driver is never a maintenance credential.
    Config = case RawConfig of
        #{a4 := A4} -> RawConfig#{a4 := A4#{operator => self()}};
        _ -> RawConfig
    end,
    {Tokens, Bindings} = fenrir_authority:campaign_credentials(maps:get(tenants, Config)),
    Chan = open_port({fd, 3, 4}, [{packet, 4}, binary, eof]),
    fenrir_faults:init(),
    process_flag(trap_exit, true),
    case catch fenrir_service_sup:start_link(Config#{submit_credentials => Bindings}) of
        {ok, Sup} ->
            send(Chan, {started, #{beam_os_pid => list_to_integer(os:getpid()),
                                   otp => erlang:system_info(otp_release),
                                   erts => erlang:system_info(version),
                                   sqlite_port_os_pid => fenrir_store:port_os_pid()}}),
            loop(Chan, Sup, Tokens, Config);
        Other ->
            send(Chan, {start_failed, Other}),
            timer:sleep(100),
            erlang:halt(3)
    end.

send(Chan, Term) -> port_command(Chan, term_to_binary(Term)).

loop(Chan, Sup, Tokens, Config) ->
    receive
        {Chan, {data, Bin}} ->
            Cmd = binary_to_term(Bin),
            Answer = try command(Cmd, {Chan, Tokens, Config}) catch C:E:Stack -> {error, {C, E, hd(Stack ++ [none])}} end,
            send(Chan, Answer),
            after_answer(Cmd),
            case Cmd of stop -> erlang:halt(0); _ -> loop(Chan, Sup, Tokens, Config) end;
        {Chan, eof} -> erlang:halt(0);
        {'EXIT', Sup, R} -> send(Chan, {supervisor_exit, R}), erlang:halt(4);
        _ -> loop(Chan, Sup, Tokens, Config)
    end.

%% The front's fault point after a response has been written to the client.
after_answer({submit, _, _, _, _}) -> fenrir_faults:hit(f1_after_response, #{});
after_answer({complete, _, _, _}) -> fenrir_faults:hit(f1_after_response, #{});
after_answer(_) -> ok.

command({submit, T, K, D, P}, {_, Tokens, _}) -> fixture_submit(Tokens, T, K, D, P);
command({complete, T, J, Ok}, _) -> fenrir_front:deliver(T, J, Ok);
command({respond, E}, _) -> fenrir_front:respond(E);
command(outbox, _) -> fenrir_front:outbox();
command(snapshot, _) -> fenrir_store:snapshot();
command(pending, _) -> fenrir_store:pending_jobs();
command({run_jobs, Opts}, {Chan, _, _}) ->
    N = fenrir_runner:run_once(fun(Note) -> send(Chan, {note, Note}) end, Opts),
    {jobs_done, N};
command({arm, Point, Action, Count, Witness}, _) -> fenrir_faults:arm(Point, Action, Count, Witness);
command(disarm, _) -> fenrir_faults:disarm(), catch fenrir_store:arm_port(disarm, 1), ok;
command({arm_port, Kind, N}, _) -> fenrir_store:arm_port(Kind, N);
command({fired, Witness}, _) -> fenrir_faults:fired(Witness);
command(pids, _) -> #{beam => list_to_integer(os:getpid()), sqlite_port => fenrir_store:port_os_pid(),
                     worker => pid_string(whereis(w1)), store => pid_string(whereis(fenrir_store))};
command({concurrent, Requests}, {_, Tokens, _}) -> concurrent(Requests, Tokens);
command(a4_prepare, {_, _, #{a4 := #{handler := H, migration := M}}}) ->
    fenrir_service_sup:prepare(H, M);
command(a4_state, {_, _, #{a4 := _}}) -> fenrir_store:maintenance(state);
command({a4_migrate, Id}, {_, _, #{a4 := #{migration := M, launch_dir := Dir}} = C}) ->
    fenrir_a4_upgrade:migrate(Id, M, #{a4_launch_dir => Dir, launcher => maps:get(launcher, C),
                                       console_dir => maps:get(console_dir, C)});
command({a4_cut_over, Id}, {_, _, #{a4 := #{handler := H}}}) ->
    fenrir_service_sup:cut_over(Id, H);
command(a4_boundary, {_, _, #{a4 := _}}) -> fenrir_faults:hit(a4_at_boundary, #{});
command(a4_pids, {_, _, #{a4 := _}}) ->
    #{beam => list_to_integer(os:getpid()), front => pid_string(whereis(fenrir_front)),
      v1 => pid_string(whereis(w1)), v2 => pid_string(whereis(a4w1)),
      v2_peer => pid_string(whereis(a4w2))};
command({a4_fault_submit, T, K, D}, {_, Tokens, #{a4 := _}}) ->
    {R, Stats} = fixture_submit(Tokens, T, K, D, <<D>>),
    {R, pid_string(maps:get(worker, Stats, undefined))};
command({a4_retry_pair, T, K, D}, {_, Tokens, #{a4 := _}}) ->
    Parent = self(),
    Pids = [spawn_link(fun() ->
        receive go ->
            Start = erlang:monotonic_time(),
            R = fixture_submit(Tokens, T, K, D, <<D>>),
            Parent ! {retry_done, self(), Start, erlang:monotonic_time(), R}
        end
    end) || _ <- [1, 2]],
    [P ! go || P <- Pids],
    [receive {retry_done, P, Start, End, R} -> {Start, End, R} end || P <- Pids];
command(ping, _) -> pong;
command(diag, _) ->
    Sup = whereis(fenrir_worker_sup),
    #{children => catch supervisor:which_children(fenrir_worker_sup),
      worker_sup => catch erlang:process_info(Sup, [current_stacktrace, message_queue_len, status]),
      w1 => whereis(w1)};
command(stop, _) -> ok.

pid_string(P) when is_pid(P) -> pid_to_list(P);
pid_string(undefined) -> undefined.

fixture_submit(Tokens, T, K, D, P) -> fenrir_front:submit(maps:get(T, Tokens, none), K, D, P).

%% Run requests at once, one caller process each (the workers are picked round-robin).
concurrent(Requests, Tokens) ->
    Self = self(),
    T0 = erlang:monotonic_time(microsecond),
    Pids = [spawn_link(fun() ->
                               R = case Req of
                                       {submit, T, K, D, P} -> fixture_submit(Tokens, T, K, D, P);
                                       {complete, T, J, Ok} -> fenrir_front:deliver(T, J, Ok)
                                   end,
                               Self ! {done, self(), R, erlang:monotonic_time(microsecond)}
                       end) || Req <- Requests],
    Results = [receive {done, P, R, T1} -> {R, T1 - T0} end || P <- Pids],
    {concurrent_done, Results, erlang:monotonic_time(microsecond) - T0}.
