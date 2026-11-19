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
%%   (store: the port program kills itself after the next statement completes, before
%%   answering), kill_store (exit kill of the store process).
-module(fenrir_faults).
-export([init/0, arm/3, disarm/0, hit/2, fired/0]).

-define(T, fenrir_faults).

init() ->
    case ets:info(?T) of
        undefined -> ets:new(?T, [named_table, public, set]), ok;
        _ -> ok
    end.

%% Fire Action at the Count-th hit of Point from now.
arm(Point, Action, Count) when is_integer(Count), Count >= 1 ->
    ets:insert(?T, {Point, Action, Count}), ok.

disarm() -> ets:delete_all_objects(?T), ok.

fired() -> [{P, A} || {{fired, P}, A} <- ets:tab2list(?T)].

%% Ctx: #{tender => OsPid, worker => Pid, port => OsPid, store_port => Port}
hit(Point, Ctx) ->
    case ets:lookup(?T, Point) of
        [] -> ok;
        [{Point, Action, 1}] ->
            ets:delete(?T, Point),
            ets:insert(?T, {{fired, Point}, Action}),
            fire(Action, Ctx);
        [{Point, Action, N}] -> ets:insert(?T, {Point, Action, N - 1}), ok
    end.

fire(kill_node, _) -> os:cmd("kill -9 " ++ os:getpid()), timer:sleep(infinity);
fire(halt_node, _) -> erlang:halt(137, [{flush, false}]);
fire(kill_tender, #{tender := P}) -> kill9(P), ok;
fire(kill_worker, #{worker := Pid}) -> exit(Pid, kill), ok;
fire(kill_port, #{port := P}) -> kill9(P), ok;
fire(kill_store, #{store := Pid}) -> exit(Pid, kill), ok;
fire(lose_ack, #{store_port := Port}) -> fenrir_sqlite:arm(Port, after_statement, 1), ok;
fire(Action, Ctx) -> error({fault_not_applicable, Action, maps:keys(Ctx)}).

kill9(P) when is_integer(P) -> os:cmd("kill -9 " ++ integer_to_list(P)), timer:sleep(20), ok;
kill9(_) -> ok.
