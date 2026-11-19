%% A3 crash campaigns: named fault points in the host, armed by the campaign driver.
%% A point that is not armed costs one ETS lookup and does nothing. Faults are volatile
%% (they die with the node): the driver re-arms them after a restart.
%%
%% Points (where they sit is stated in host/service/CONTRACT.md):
%%   worker  w1_before_request  w2_request_before_commit  w3_commit_before_reply
%%           w4_reply_before_response
%%   front   f1_after_response
%%   store   s1_after_begin  s2_mid_writes  s3_before_commit  s4_after_commit
%%           s5_between_transactions (two_transactions mutant only)
%% Actions: kill_node (kill -9 of this BEAM's OS process), halt_node (erlang:halt/2,
%%   no flush), kill_tender (kill -9 of the solo5-spt process), kill_worker (exit kill of
%%   the worker process), kill_port (kill -9 of the SQLite port program), lose_ack
%%   (store: the port program kills itself after COMMIT completes, before
%%   answering), kill_store (exit kill of the store process).
-module(fenrir_faults).
-export([init/0, arm/3, arm/4, disarm/0, hit/2, fired/1, lost_ack/2]).

-define(T, fenrir_faults).

init() ->
    case ets:info(?T) of
        undefined -> ets:new(?T, [named_table, public, set]), ok;
        _ -> ok
    end.

%% Fire Action at the Count-th hit of Point from now.
arm(Point, Action, Count) -> arm(Point, Action, Count, none).
arm(Point, Action, Count, Witness) when is_integer(Count), Count >= 1 ->
    ets:insert(?T, {Point, Action, Count, Witness}), ok.

disarm() -> ets:delete_all_objects(?T), ok.

fired(Witness) -> fired(Witness, 25).
fired(Witness, N) ->
    case ets:lookup(?T, {fired, Witness}) of
        [{_, Proof}] -> Proof;
        [] when N > 0 -> timer:sleep(10), fired(Witness, N - 1);
        [] -> none
    end.

%% Ctx: #{tender => OsPid, worker => Pid, port => OsPid, store_port => Port}
hit(Point, Ctx) ->
    case ets:lookup(?T, Point) of
        [] -> ok;
        [{Point, Action, 1, Witness}] ->
            ets:delete(?T, Point),
            fire(Point, Action, Ctx, Witness);
        [{Point, Action, N, Witness}] -> ets:insert(?T, {Point, Action, N - 1, Witness}), ok
    end.

fire(Point, kill_node, _, Witness) ->
    Pid = os:getpid(),
    %% The shell survives the BEAM. Write the receipt only if it sent SIGKILL
    %% successfully; the driver separately requires the BEAM's matching wait status.
    os:cmd("kill -9 " ++ Pid ++ receipt_cmd(Witness, Point, kill_node, Pid)),
    ok;
fire(Point, halt_node, _, Witness) ->
    case Witness of
        none -> ok;
        _ -> ok = file:write_file(Witness, receipt(Point, halt_node, os:getpid()))
    end,
    %% Distinct from a signal death and from ordinary service exits.
    erlang:halt(86, [{flush, false}]);
fire(Point, kill_tender, #{tender := P, tender_port := Port}, W) ->
    kill_port(Point, kill_tender, P, Port, W);
fire(Point, kill_port, #{port := P, store_port := Port}, W) ->
    kill_port(Point, kill_port, P, Port, W);
fire(Point, kill_worker, #{worker := Pid}, W) when Pid =:= self() ->
    kill_process(Point, kill_worker, Pid, W);
fire(Point, kill_store, #{store := Pid}, W) when Pid =:= self() ->
    kill_process(Point, kill_store, Pid, W);
fire(s3_before_commit, lose_ack, #{port := P, store_port := Port}, W) ->
    case fenrir_sqlite:arm(Port, after_commit, 1) of
        ok -> {armed_lost_ack, W, P};
        _ -> ok
    end;
fire(_, Action, Ctx, _) -> error({fault_not_applicable, Action, maps:keys(Ctx)}).

receipt_cmd(none, _, _, _) -> "";
receipt_cmd(File, Point, Action, Pid) ->
    " && printf '%s' " ++ quote(receipt(Point, Action, Pid)) ++ " > " ++ quote(File).

receipt(Point, Action, Pid) -> atom_to_list(Point) ++ " " ++ atom_to_list(Action) ++ " " ++ Pid.
quote(S) -> "'" ++ lists:flatten(string:replace(S, "'", "'\\''", all)) ++ "'".

prove(none, _) -> ok;
prove(W, Proof) -> ets:insert(?T, {{fired, W}, Proof}), ok.

kill_port(Point, Action, Pid, Port, W) when is_integer(Pid), Pid > 0 ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, Pid} ->
            case os:cmd("kill -9 " ++ integer_to_list(Pid) ++ " && printf sent") of
                "sent" ->
                    receive
                        {Port, {exit_status, Status}} = Exit ->
                            %% The worker/store still classifies this as a real port
                            %% death; also leave its ordinary exit notice available.
                            self() ! Exit,
                            case Status of
                                137 -> prove(W, {Point, Action, Pid, {sigkill, pid_to_list(self())}});
                                _ -> ok
                            end
                    after 2000 -> ok
                    end;
                _ -> ok
            end;
        _ -> ok
    end;
kill_port(_, _, _, _, _) -> ok.

kill_process(Point, Action, Pid, W) ->
    Watcher = spawn(fun() ->
        M = monitor(process, Pid),
        Pid ! {monitoring_fault_target, self()},
        receive
            {'DOWN', M, process, Pid, killed} -> prove(W, {Point, Action, pid_to_list(Pid), killed});
            {'DOWN', M, process, Pid, _} -> ok
        end
    end),
    receive {monitoring_fault_target, Watcher} -> exit(self(), kill) end.

lost_ack({armed_lost_ack, W, Pid}, {lost_commit_ack, 137}) when is_integer(Pid), Pid > 0 ->
    prove(W, {s3_before_commit, lose_ack, Pid, lost_commit_ack});
lost_ack(_, _) -> ok.
