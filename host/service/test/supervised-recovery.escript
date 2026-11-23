#!/usr/bin/env escript
-include_lib("kernel/include/file.hrl").
%% Run with the service modules on the Erlang code path and a fresh output directory.
main([Image, Launcher, Out]) -> main([Image, Launcher, Out, "fenrir"]);
main([Image, Launcher, Out, Implementation]) -> main([Image, Launcher, Out, Implementation, "recovery"]);
main([Image, Launcher, Out, Implementation, Mode]) ->
    Db = filename:join(Out, "jobs.db"),
    false = filelib:is_file(Db),
    fenrir_faults:init(),
    {Tokens, Bindings} = fenrir_authority:campaign_credentials(2),
    {ok, Sup} = fenrir_service_sup:start_link(#{image => Image, launcher => Launcher,
        db => Db, tenants => 2, submit_credentials => Bindings, console_dir => Out}),
    unlink(Sup),
    try
        ok = select_worker(Implementation),
        case Mode of
            "recovery" -> recovery(Tokens, Implementation, Out);
            "timeout-after-commit" -> timeout_after_commit(Tokens, Implementation, Out);
            "rollback" -> rollback(Tokens, Implementation, Out);
            "backlog" -> backlog(Tokens, Implementation, Out, 0);
            "wide-backlog" -> backlog(Tokens, Implementation, Out, 4294967296);
            "fresh-commits" -> fresh_commits(Tokens, Implementation, Out, none, 128);
            "paced-commits" ->
                Rate = list_to_integer(os:getenv("FENRIR_COMMIT_RATE")),
                Seconds = list_to_integer(os:getenv("FENRIR_COMMIT_SECONDS")),
                true = Rate > 0 andalso Seconds > 0,
                fresh_commits(Tokens, Implementation, Out, Rate, Rate * Seconds)
        end
    after
        exit(Sup, shutdown)
    end.

recovery(Tokens, Implementation, Out) ->
        Token = maps:get(0, Tokens),
        Settings = fenrir_store:connection_settings(),
        #{journal_mode := <<"wal">>, synchronous := 2, foreign_keys := 1, busy_timeout_ms := 50} = Settings,
        Store = whereis(fenrir_store),
        StoreRef = monitor(process, Store),
        PortPid = fenrir_store:port_os_pid(),
        Witness = make_ref(),
        ok = fenrir_faults:arm(s3_before_commit, lose_ack, 1, Witness),
        {indeterminate, _} = fenrir_front:submit(Token, 1, 1, <<1>>),
        {s3_before_commit, lose_ack, PortPid, lost_commit_ack} = fenrir_faults:fired(Witness),
        await_restart(fenrir_store, Store, StoreRef),
        Settings = fenrir_store:connection_settings(),
        Recovered = fenrir_store:snapshot(),
        Worker = whereis(w1),
        WorkerRef = monitor(process, Worker),
        KillAt = erlang:monotonic_time(microsecond),
        exit(Worker, kill),
        await_restart(w1, Worker, WorkerRef),
        ReplacementObservedAt = erlang:monotonic_time(microsecond),
        {{accepted, Receipt}, #{worker := RetryWorker}} = fenrir_front:submit(Token, 1, 1, <<1>>),
        RetryAt = erlang:monotonic_time(microsecond),
        [0,1,1,0,0] = Receipt,
        Recovered = fenrir_store:snapshot(),
        Notify = fun({delivered, T, J, Ok, delivered}) ->
                         self() ! {event, [<<"complete">>, T, J, Ok, [<<"delivered">>]]};
                    ({deliver, _, _, _}) -> ok
                 end,
        DrainStart = erlang:monotonic_time(microsecond),
        1 = fenrir_runner:run_once(Notify, #{duplicate => true}),
        First = receive {event, E1} -> E1 after 1000 -> error(missing_delivery) end,
        Second = receive {event, E2} -> E2 after 1000 -> error(missing_duplicate) end,
        [] = fenrir_store:pending_jobs(),
        DrainEnd = erlang:monotonic_time(microsecond),
        Drained = fenrir_store:snapshot(),
        {{conflict,0,1}, _} = fenrir_front:submit(Token, 1, 0, <<0>>),
        ok = fenrir_front:respond({conflict,0,1}),
        Drained = fenrir_store:snapshot(),
        OtherToken = maps:get(1, Tokens),
        FreshBefore = fenrir_store:io_counters(),
        SubmitStart = erlang:monotonic_time(microsecond),
        {{accepted, OtherReceipt}, _} = fenrir_front:submit(OtherToken, 1, 0, <<0>>),
        SubmitEnd = erlang:monotonic_time(microsecond),
        [1,1,0,0,0] = OtherReceipt,
        ok = fenrir_front:respond({accepted, OtherReceipt}),
        RespondEnd = erlang:monotonic_time(microsecond),
        FreshIo = io_delta(FreshBefore, fenrir_store:io_counters()),
        [TenantZero, _] = Drained,
        OtherPending = [TenantZero, _] = fenrir_store:snapshot(),
        DuplicateBefore = fenrir_store:io_counters(),
        DuplicateStart = erlang:monotonic_time(microsecond),
        {{accepted, OtherReceipt}, _} = fenrir_front:submit(OtherToken, 1, 0, <<0>>),
        DuplicateElapsed = erlang:monotonic_time(microsecond) - DuplicateStart,
        DuplicateIo = io_delta(DuplicateBefore, fenrir_store:io_counters()),
        OtherPending = fenrir_store:snapshot(),
        1 = fenrir_runner:run_once(Notify, #{}),
        OtherDelivery = receive {event, E3} -> E3 after 1000 -> error(missing_tenant_delivery) end,
        [] = fenrir_store:pending_jobs(),
        Final = [TenantZero, _] = fenrir_store:snapshot(),
        Events = [[<<"submit">>,0,1,1,[<<"indeterminate">>]], [<<"observe">>,Recovered],
                  [<<"submit">>,0,1,1,[<<"accepted">>,Receipt]], First, Second,
                  [<<"drained">>], [<<"observe">>,Drained],
                  [<<"submit">>,0,1,0,[<<"conflict">>,0,1]], [<<"respond">>,[<<"conflict">>,0,1]],
                  [<<"observe">>,Drained], [<<"submit">>,1,1,0,[<<"accepted">>,OtherReceipt]],
                  [<<"respond">>,[<<"accepted">>,OtherReceipt]], [<<"observe">>,OtherPending],
                  [<<"submit">>,1,1,0,[<<"accepted">>,OtherReceipt]], [<<"observe">>,OtherPending],
                  OtherDelivery, [<<"drained">>], [<<"observe">>,Final]],
        History = #{worker_implementation => list_to_binary(Implementation), schema => <<"fenrir.service.history/1">>, tenants => 2,
                    scenario => <<"supervised-store-and-worker-recovery">>,
                    expect => <<"accepted">>, events => Events},
        ok = file:write_file(filename:join(Out,"history.json"), json:encode(History)),
        Fault = #{fault => <<"lost_commit_ack">>, sqlite_port_pid => PortPid, exit_status => 137,
                  sqlite_connection_before_and_after_restart => Settings},
        ok = file:write_file(filename:join(Out,"fault.json"), json:encode(Fault)),
        Timings = #{sqlite_connection_before_and_after_restart => Settings,
                    fresh_submit_vfs => FreshIo, duplicate_submit_vfs => DuplicateIo,
                    duplicate_submit_to_accepted_us => DuplicateElapsed,
                    fresh_submit_to_accepted_us => SubmitEnd - SubmitStart,
                    fresh_submit_to_respond_us => RespondEnd - SubmitStart,
                    killed_worker => w1, retry_worker => RetryWorker,
                    worker_kill_to_successful_retry_us => RetryAt - KillAt,
                    worker_kill_to_replacement_observed_us => ReplacementObservedAt - KillAt,
                    replacement_observed_to_successful_retry_us => RetryAt - ReplacementObservedAt,
                    runner_start_to_verified_empty_us => DrainEnd - DrainStart,
                    pending_jobs_at_start => 1, delivery_attempts => 2},
        ok = file:write_file(filename:join(Out,"timings.json"), json:encode(Timings)).

%% Hold the first committed response at the delivery boundary. The client
%% deadline expires while the outbox already contains the accepted receipt.
timeout_after_commit(Tokens, Implementation, Out) ->
    Token = maps:get(0, Tokens),
    Client = self(),
    Ref = make_ref(),
    {Relay, Monitor} = spawn_monitor(fun() ->
        {Answer, _} = fenrir_front:submit(Token, 1, 1, <<1>>),
        Client ! {Ref, committed, Answer},
        receive {Ref, release} -> Client ! {Ref, response, Answer}
        after 5000 -> exit(delivery_gate_timeout)
        end
    end),
    Receipt = [0,1,1,0,0],
    Accepted = {accepted, Receipt},
    receive {Ref, committed, Accepted} -> ok after 5000 -> error(missing_commit) end,
    [Accepted] = fenrir_front:outbox(),
    Committed = fenrir_store:snapshot(),
    [{0,0,0}] = fenrir_store:pending_jobs(),
    receive {Ref, response, _} -> error(response_before_deadline)
    after 5 -> ok
    end,
    {Accepted, _} = fenrir_front:submit(Token, 1, 1, <<1>>),
    ok = fenrir_front:respond(Accepted),
    Relay ! {Ref, release},
    receive {Ref, response, Accepted} -> ok after 5000 -> error(missing_late_response) end,
    receive {'DOWN', Monitor, process, Relay, normal} -> ok after 5000 -> error(relay_failed) end,
    ok = fenrir_front:respond(Accepted),
    Committed = fenrir_store:snapshot(),
    [{0,0,0}] = fenrir_store:pending_jobs(),
    Submit = [<<"submit">>,0,1,1,[<<"accepted">>,Receipt]],
    Response = [<<"respond">>,[<<"accepted">>,Receipt]],
    Observation = [<<"observe">>,Committed],
    History = #{worker_implementation => list_to_binary(Implementation),
                schema => <<"fenrir.service.history/1">>, tenants => 2,
                scenario => <<"timeout-after-commit">>, expect => <<"accepted">>,
                events => [Submit,Observation,Submit,Response,Response,Observation]},
    Evidence = #{fault => <<"held_response_after_commit">>, client_wait_ms => 5,
                 pending_jobs_after_retry => 1, identical_responses => 2,
                 sqlite_connection => fenrir_store:connection_settings()},
    ok = file:write_file(filename:join(Out,"history.json"), json:encode(History)),
    ok = file:write_file(filename:join(Out,"fault.json"), json:encode(Evidence)).

rollback(Tokens, Implementation, Out) ->
    Empty = fenrir_store:snapshot(),
    Settings = fenrir_store:connection_settings(),
    Store = whereis(fenrir_store),
    Monitor = monitor(process, Store),
    PortPid = fenrir_store:port_os_pid(),
    Token = maps:get(1, Tokens),
    Witness = make_ref(),
    ok = fenrir_faults:arm(s2_mid_writes, kill_port, 1, Witness),
    {aborted, _} = fenrir_front:submit(Token, 1, 1, <<1>>),
    {s2_mid_writes, kill_port, PortPid, {sigkill, Caller}} = fenrir_faults:fired(Witness),
    Caller = pid_to_list(Store),
    await_restart(fenrir_store, Store, Monitor),
    Settings = fenrir_store:connection_settings(),
    Empty = fenrir_store:snapshot(),
    [] = fenrir_store:pending_jobs(),
    {{accepted, Receipt}, _} = fenrir_front:submit(Token, 1, 1, <<1>>),
    [1,1,1,0,0] = Receipt,
    [{1,0,0}] = fenrir_store:pending_jobs(),
    Events = [[<<"observe">>,Empty], [<<"submit">>,1,1,1,[<<"aborted">>]],
              [<<"observe">>,Empty], [<<"submit">>,1,1,1,[<<"accepted">>,Receipt]],
              [<<"observe">>,fenrir_store:snapshot()]],
    History = #{worker_implementation => list_to_binary(Implementation),
                schema => <<"fenrir.service.history/1">>, tenants => 2,
                scenario => <<"mid-write-rollback-retry">>, expect => <<"accepted">>, events => Events},
    Evidence = #{fault => <<"s2_mid_writes">>, sqlite_port_pid => PortPid,
                 exit_status => 137, store_pid => list_to_binary(Caller),
                 sqlite_connection_before_and_after_restart => Settings},
    ok = file:write_file(filename:join(Out,"history.json"), json:encode(History)),
    ok = file:write_file(filename:join(Out,"fault.json"), json:encode(Evidence)).

backlog(Tokens, Implementation, Out, Base) ->
    %% Submit two distinct keys in each tenant, keeping job IDs store-assigned.
    Settings = fenrir_store:connection_settings(),
    #{journal_mode := <<"wal">>, synchronous := 2, foreign_keys := 1} = Settings,
    Start = erlang:monotonic_time(microsecond),
    Submits = [begin
        K = Base + D,
        {{accepted, Receipt}, _} = fenrir_front:submit(maps:get(T, Tokens), K, D, <<D>>),
        [T,K,D,D,D] = Receipt,
        [<<"submit">>,T,K,D,[<<"accepted">>,Receipt]]
    end || D <- [0,1], T <- [0,1]],
    Accepted = erlang:monotonic_time(microsecond),
    [{0,0,0},{0,1,1},{1,0,0},{1,1,1}] = fenrir_store:pending_jobs(),
    Before = fenrir_store:snapshot(),
    Worker = whereis(w1),
    Monitor = monitor(process, Worker),
    exit(Worker, kill),
    await_restart(w1, Worker, Monitor),
    Before = fenrir_store:snapshot(),
    Notify = fun({delivered,T,J,Ok,delivered}) ->
                     self() ! {completion,[<<"complete">>,T,J,Ok,[<<"delivered">>]]};
                ({deliver,_,_,_}) -> ok end,
    DrainStart = erlang:monotonic_time(microsecond),
    4 = fenrir_runner:run_once(Notify, #{duplicate => true}),
    [] = fenrir_store:pending_jobs(),
    DrainEnd = erlang:monotonic_time(microsecond),
    Delivered = [receive {completion,E} -> E after 1000 -> error(missing_completion) end
                 || _ <- lists:seq(1,8)],
    Events = Submits ++ [[<<"observe">>,Before]] ++ Delivered ++
             [[<<"drained">>],[<<"observe">>,fenrir_store:snapshot()]],
    History = #{worker_implementation => list_to_binary(Implementation),
                schema => <<"fenrir.service.history/1">>, tenants => 2,
                scenario => case Base of 0 -> <<"full-domain-backlog">>; _ -> <<"wide-key-backlog">> end, expect => <<"accepted">>, events => Events},
    Timings = #{pending_jobs_at_start => 4, delivery_attempts => 8,
                four_fresh_submits_us => Accepted - Start,
                runner_start_to_verified_empty_us => DrainEnd - DrainStart,
                sqlite_connection => Settings},
    ok = file:write_file(filename:join(Out,"history.json"), json:encode(History)),
    ok = file:write_file(filename:join(Out,"timings.json"), json:encode(Timings)).

%% Use absolute deadlines so a slow commit cannot shift the remaining schedule.
wait_until(Due) ->
    Left = Due - erlang:monotonic_time(microsecond),
    case Left > 0 of
        true -> timer:sleep((Left + 999) div 1000), wait_until(Due);
        false -> ok
    end.

fresh_commits(Tokens, Implementation, Out, Rate, Count) ->
    Settings = fenrir_store:connection_settings(),
    #{journal_mode := <<"wal">>, synchronous := 2, foreign_keys := 1} = Settings,
    MemoryBefore = resource_snapshot(Out, Implementation),
    ProfileStart = case os:getenv("FENRIR_PROFILE_VFS") of
        "1" -> fenrir_store:storage_profile();
        _ -> none
    end,
    Before = fenrir_store:io_counters(),
    Start = erlang:monotonic_time(microsecond),
    {SubmitsRev, ServiceRev, LatenciesRev} =
        record_commits(0, Count, Tokens, Rate, Start, [], [], []),
    Elapsed = erlang:monotonic_time(microsecond) - Start,
    Io = io_delta(Before, fenrir_store:io_counters()),
    Profile = case ProfileStart of
        none -> #{};
        {Tx0, {Write0, Sync0}} ->
            {Tx1, {Write1, Sync1}} = fenrir_store:storage_profile(),
            #{store_transaction_ns => Tx1 - Tx0,
              vfs_time_ns => #{write => Write1 - Write0, sync => Sync1 - Sync0}}
    end,
    MemoryAfter = resource_snapshot(Out, Implementation),
    ServiceTimes = lists:reverse(ServiceRev),
    Latencies = lists:reverse(LatenciesRev),
    Events = lists:reverse(SubmitsRev, [[<<"observe">>,fenrir_store:snapshot()]]),
    History = #{worker_implementation => list_to_binary(Implementation),
                schema => <<"fenrir.service.history/1">>, tenants => 2,
                scenario => case Rate of none -> <<"fresh-commits">>; _ -> <<"paced-commits">> end, expect => <<"accepted">>, events => Events},
    Count = length(Latencies),
    Timings = Profile#{fresh_commits => Count, fresh_commits_elapsed_us => Elapsed,
                commits_per_second => Count * 1000000 / Elapsed,
                offered_rate => Rate, service_samples_us => ServiceTimes,
                acknowledgement_samples_us => Latencies,
                acknowledgement_p99_us => lists:nth((99 * Count + 99) div 100, lists:sort(Latencies)),
                vfs => Io, sqlite_connection => Settings},
    ok = file:write_file(filename:join(Out, "resources.json"),
                         json:encode(#{before_load => MemoryBefore, after_load => MemoryAfter})),
    Path = filename:join(Out, "history.json"),
    case Rate of
        none -> ok = file:write_file(Path, json:encode(History));
        _ -> write_commit_chunks(Path, maps:remove(events, History), Events, Count + 1, 0, 0)
    end,
    ok = file:write_file(filename:join(Out,"timings.json"), json:encode(Timings)).

%% Capture service resources outside the measured interval while SQLite is open.
resource_snapshot(Out, Implementation) ->
    Beam = list_to_integer(os:getpid()),
    Port = fenrir_store:port_os_pid(),
    Db = filename:join(Out, "jobs.db"),
    Worker = worker_resources(Implementation),
    Worker#{beam_pid => Beam, beam_rss_bytes => resident_bytes(Beam),
      sqlite_pid => Port, sqlite_rss_bytes => resident_bytes(Port),
      db_file_bytes => file_bytes(Db), wal_file_bytes => file_bytes(Db ++ "-wal"),
      shm_file_bytes => file_bytes(Db ++ "-shm")}.

%% The native adapter owns one persistent port. Its launcher execs the SPT
%% tender in place, so the port PID identifies the guest's host process.
worker_resources("fenrir") -> #{worker_location => <<"per_request_guest">>};
worker_resources(Impl) when Impl =:= "erlang"; Impl =:= "elixir" ->
    #{worker_location => <<"beam">>};
worker_resources(_) ->
    Worker = whereis(w1),
    {links, Links} = process_info(Worker, links),
    [Port] = [P || P <- Links, is_port(P), erlang:port_info(P, connected) =:= {connected, Worker}],
    {os_pid, Pid} = erlang:port_info(Port, os_pid),
    #{worker_location => <<"external_process">>, worker_pid => Pid,
      worker_rss_bytes => resident_bytes(Pid)}.

resident_bytes(Pid) when is_integer(Pid), Pid > 0 ->
    case os:type() of
        {unix, linux} ->
            {ok, Status} = file:read_file("/proc/" ++ integer_to_list(Pid) ++ "/status"),
            {match, [KiB]} = re:run(Status, <<"^VmRSS:[ \\t]+([0-9]+) kB$">>,
                                    [multiline, {capture, [1], binary}]),
            binary_to_integer(KiB) * 1024;
        {unix, darwin} ->
            list_to_integer(string:trim(os:cmd("/bin/ps -o rss= -p " ++ integer_to_list(Pid)))) * 1024
    end.

file_bytes(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{size = Size}} -> Size;
        {error, enoent} -> null
    end.

record_commits(Count, Count, _Tokens, _Rate, _Start, Events, Service, Latencies) ->
    {Events, Service, Latencies};
record_commits(I, Count, Tokens, Rate, Start, Events, Service, Latencies) ->
    T = I rem 2,
    J = I div 2,
    K = 4294967296 + J,
    D = J rem 2,
    Token = maps:get(T, Tokens),
    Due = case Rate of
        none -> erlang:monotonic_time(microsecond);
        _ -> Scheduled = Start + I * 1000000 div Rate, wait_until(Scheduled), Scheduled
    end,
    Begin = erlang:monotonic_time(microsecond),
    {{accepted, Receipt}, _} = fenrir_front:submit(Token, K, D, <<D>>),
    End = erlang:monotonic_time(microsecond),
    [T,K,D,J,J] = Receipt,
    Active = End - Begin,
    Latency = case Rate of none -> Active; _ -> End - Due end,
    Event = [<<"submit">>,T,K,D,[<<"accepted">>,Receipt]],
    record_commits(I + 1, Count, Tokens, Rate, Start, [Event | Events],
                   [Active | Service], [Latency | Latencies]).

write_commit_chunks(Path, Header, [], Total, Total, N) ->
    Manifest = Header#{schema => <<"fenrir.service.history/1-chunked">>, chunks => N, event_count => Total},
    ok = file:write_file(Path, json:encode(Manifest));
write_commit_chunks(Path, Header, Events, Total, First, N) ->
    Size = min(1024, Total - First),
    {Chunk, Rest} = lists:split(Size, Events),
    ok = file:write_file(Path ++ ".events." ++ integer_to_list(N),
                         json:encode(#{first => First, events => Chunk})),
    write_commit_chunks(Path, Header, Rest, Total, First + Size, N + 1).

io_delta({W0, S0}, {W1, S1}) when W1 >= W0, S1 >= S0 ->
    #{writes => W1 - W0, syncs => S1 - S0}.

select_worker("fenrir") -> ok;
select_worker("fenrir-native-mac") -> replace_worker(fenrir_port_reference);
select_worker("c-native-spt") -> replace_worker(fenrir_port_reference);
select_worker("fenrir-native-spt") -> replace_worker(fenrir_port_reference);
select_worker("nim") -> replace_worker(fenrir_port_reference);
select_worker("rust") -> replace_worker(fenrir_port_reference);
select_worker("erlang") -> replace_worker(fenrir_erlang_reference);
select_worker("elixir") ->
    {ok, _} = application:ensure_all_started(elixir),
    replace_worker('Elixir.Fenrir.DurableReference').

replace_worker(Module) ->
    ok = supervisor:terminate_child(fenrir_worker_sup, w1),
    ok = supervisor:delete_child(fenrir_worker_sup, w1),
    {ok, _} = supervisor:start_child(fenrir_worker_sup, #{id => w1,
        start => {Module, start_link, [w1]}}),
    ok.

await_restart(Name, Old, Ref) ->
    receive {'DOWN', Ref, process, Old, _} -> ok after 5000 -> error({still_running,Name}) end,
    await_replacement(Name, Old, erlang:monotonic_time(millisecond) + 5000).

%% Querying the supervisor serializes the observation with child restart.
%% DOWN can reach us before the supervisor handles EXIT, so retry a stale
%% answer within the original deadline. No fixed sleep enters the worker metric.
await_replacement(w1, Old, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining > 0 of
        false -> error({restart_timeout,w1});
        true ->
            Children = gen_server:call(fenrir_worker_sup, which_children, Remaining),
            case lists:keyfind(w1, 1, Children) of
                {w1, New, _, _} when is_pid(New), New =/= Old -> ok;
                _ -> await_replacement(w1, Old, Deadline)
            end
    end;
await_replacement(Name, Old, Deadline) ->
    case whereis(Name) of
        New when is_pid(New), New =/= Old -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(10), await_replacement(Name, Old, Deadline);
                false -> error({restart_timeout,Name})
            end
    end.
