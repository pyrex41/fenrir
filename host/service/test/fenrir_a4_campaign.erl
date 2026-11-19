%% A finite campaign. Each scenario runs in a separate BEAM/SQLite store;
%% this recorder survives every injected death. Exceptions produce a gap and
%% a retained row, not a smaller denominator or an invented observation.
-module(fenrir_a4_campaign).
-export([main/1]).

main([Out, Erl, Ebin, NodeLaunch, Launcher, V1, V2, Migration]) ->
    {ok, HP} = fenrir_a4_image:admit(V2, handler_v2),
    {ok, MP} = fenrir_a4_image:admit(Migration, migration),
    C = #{erl => Erl, ebin => Ebin, out => Out, node_launch => NodeLaunch,
          sqlite_port => fenrir_sqlite:port_program(), call_timeout => 15000,
          config => #{tenants => 2, workers => 2, image => V1, launcher => Launcher,
                      a4 => #{handler => V2, migration => Migration,
                              launch_dir => filename:join(Out, "launch")}}},
    Plan = [{"node-v1", v1}, {"node-prepared", prepared}, {"node-migrated", migrated},
            {"node-v2", v2}, {"worker-v2-before-reply", worker}],
    Rows = [scenario(C, Name, Case, HP, MP) || {Name, Case} <- Plan],
    ok = file:write_file(filename:join(Out, "crash-rows.json"), json:encode(Rows)),
    halt(0).

scenario(C, Name, Case, HP, MP) ->
    put(recorder, fenrir_drive:new(C, Name)),
    put(fault, #{}),
    Status = try
        boot(),
        submit(0, 0, 1, [0,0,1,0,0]),
        submit(1, 0, 0, [1,0,0,0,0]),
        Target = go_to(Case, HP, MP),
        observe(Target),
        case Case of
            worker -> worker_recovery(Target);
            _ -> node_recovery(Case, Target, HP, MP)
        end,
        <<"observed">>
    catch Class:Reason ->
        keep(fenrir_drive:gap(get(recorder), <<"required evidence unavailable">>, {Class, Reason})),
        <<"unknown">>
    after
        keep(fenrir_drive:stop(get(recorder)))
    end,
    File = fenrir_drive:write_history(get(recorder), 2,
              #{<<"schema">> => <<"fenrir.service.history/2">>,
                <<"handler_pin">> => hex(HP), <<"migration_pin">> => hex(MP)}),
    #{name => list_to_binary(Name), status => Status, phase => atom_to_binary(Case),
      history => list_to_binary(File), proof => erase(fault)}.

keep(S) -> put(recorder, S), ok.
event(E) -> keep(fenrir_drive:event(get(recorder), E)).
next_index() -> length(fenrir_drive:events(get(recorder))).

boot() ->
    #{node := #{pid := Pid, port := Port}} = S = fenrir_drive:start(get(recorder)),
    keep(S),
    {os_pid, Pid} = erlang:port_info(Port, os_pid),
    Pid.

call(Cmd) ->
    R = fenrir_drive:call(get(recorder), Cmd),
    keep(element(3, R)),
    R.

cmd(Cmd) ->
    {ok, Out, _} = call(Cmd),
    Out.

submit(T, K, D, Rc) ->
    {{accepted, Rc}, _} = cmd({submit, T, K, D, <<D>>}),
    event([<<"submit">>, T, K, D, [<<"accepted">>, Rc]]).

observe(Target) ->
    #{db := Db} = get(recorder),
    Obs = fenrir_a4_workers:observed(Db, Target),
    event(Obs),
    Obs.

go_to(v1, _, _) -> v1;
go_to(Phase, HP, MP) ->
    {ok, Prep = {prepared, Id, HP, MP}} = cmd(a4_prepare),
    event([<<"upgrade">>, <<"begin">>, hex(HP), hex(MP), [<<"ok">>]]),
    observe(Prep),
    advance(Phase, Prep, {migrated, Id, HP, MP}).

advance(prepared, Prep, _) -> Prep;
advance(Phase, _, M = {migrated, Id, HP, MP}) ->
    migrate(Id, M),
    case Phase of
        migrated -> M;
        _ ->
            V2 = {v2, Id, HP, MP},
            cut_over(Id, V2),
            case Phase of v2 -> submit(0, 1, 0, [0,1,0,1,1,2]); _ -> ok end,
            V2
    end.

migrate(Id, Phase) ->
    {ok, {data, <<"Migrated">>, <<"Installed">>, []}, #{commit := committed}} = cmd({a4_migrate, Id}),
    event([<<"upgrade">>, <<"migrate">>, [<<"ok">>]]),
    observe(Phase).

cut_over(Id, Phase) ->
    ok = cmd({a4_cut_over, Id}),
    event([<<"upgrade">>, <<"cut-over">>, [<<"ok">>]]),
    observe(Phase).

node_recovery(Case, Target, HP, MP) ->
    #{dir := Dir, node := #{pid := Before, port := Port}, boots := 1} = get(recorder),
    #{beam := Before} = cmd(a4_pids),
    {os_pid, Before} = erlang:port_info(Port, os_pid),
    Witness = filename:join(Dir, "node-sigkill"),
    {error, enoent} = file:read_file(Witness),
    ok = cmd({arm, a4_at_boundary, kill_node, 1, Witness}),
    {died, 137, #{last_node_exit := {1, Before, 137}}} = call(a4_boundary),
    %% The kill receipt is written only after the OS accepted the kill;
    %% also require the exact port wait status and a distinct restarted BEAM.
    Expected = iolist_to_binary(io_lib:format("a4_at_boundary kill_node ~B", [Before])),
    ok = node_receipt(Witness, Expected, 100),
    After = boot(),
    true = After =/= Before,
    #{beam := After} = cmd(a4_pids),
    #{boots := 2} = get(recorder),
    put(fault, #{index => next_index(), before => Before, after_pid => After, exit_status => 137,
                 witness => list_to_binary(Witness), phase => atom_to_binary(Case)}),
    event([<<"crash">>, <<"node">>, Before, After, 137]),
    {ok, Target} = cmd(a4_state),
    observe(Target),
    [] = cmd(outbox),
    Old = [<<"accepted">>, [0,0,1,0,0]],
    not_in_outbox = cmd({respond, {accepted, [0,0,1,0,0]}}),
    event([<<"respond-refused">>, Old]),
    case Case of
        migrated ->
            {unavailable, _} = cmd({submit, 0, 0, 1, <<1>>}),
            event([<<"submit">>,0,0,1,[<<"unavailable">>]]),
            {unavailable, _} = cmd({complete, 0, 0, true}),
            event([<<"complete">>,0,0,true,[<<"unavailable">>]]);
        _ -> submit(0, 0, 1, [0,0,1,0,0])
    end,
    V2 = case Target of
        v1 -> go_to(worker, HP, MP);
        {prepared, I, HP, MP} -> advance(worker, Target, {migrated, I, HP, MP});
        {migrated, I, HP, MP} -> cut_over(I, {v2, I, HP, MP}), {v2, I, HP, MP};
        {v2, _, HP, MP} -> Target
    end,
    submit(1, 0, 0, [1,0,0,0,0]),
    submit(0, 0, 1, [0,0,1,0,0]),
    submit(0, 1, 0, [0,1,0,1,1,2]),
    deliver(0, 0, true),
    deliver(0, 0, false),
    deliver(0, 1, true),
    deliver(1, 0, true),
    0 = length(cmd(pending)),
    event([<<"drained">>]),
    observe(V2).

node_receipt(_, _, 0) -> error(missing_node_kill_receipt);
node_receipt(Path, Expect, N) ->
    case file:read_file(Path) of
        {ok, Expect} -> ok;
        {ok, <<>>} -> timer:sleep(10), node_receipt(Path, Expect, N-1);
        {error, enoent} -> timer:sleep(10), node_receipt(Path, Expect, N-1);
        Other -> error({wrong_node_kill_receipt, Other})
    end.

worker_recovery(Target) ->
    #{beam := Beam, front := Front, v2 := A, v2_peer := B, v1 := undefined} = cmd(a4_pids),
    true = is_list(A) andalso is_list(B) andalso A =/= B,
    Event = {accepted, Rc = [0,1,0,1,1,2]},
    not_in_outbox = cmd({respond, Event}),
    W = make_ref(),
    ok = cmd({arm, w3_commit_before_reply, kill_worker, 1, W}),
    {indeterminate, Dead} = cmd({a4_fault_submit,0,1,0}),
    true = lists:member(Dead, [A,B]),
    {w3_commit_before_reply, kill_worker, Dead, killed} = cmd({fired, W}),
    Replacement = replacement(Beam, Front, Dead, A, B, 100),
    put(fault, #{index => next_index(), beam => Beam, front => list_to_binary(Front),
                 worker => list_to_binary(Dead), replacement => list_to_binary(Replacement),
                 point => <<"w3_commit_before_reply">>, reason => <<"killed">>}),
    event([<<"submit-committed-unpublished">>,0,1,0,list_to_binary(Dead),list_to_binary(Replacement)]),
    [<<"observe">>, [Tenant0 | _], _] = Obs = observe(Target),
    [_, _, Keys, 2] = Tenant0,
    true = lists:member([1,0,Rc], Keys),
    not_in_outbox = cmd({respond, Event}),
    event([<<"respond-refused">>, [<<"accepted">>, Rc]]),
    ok = cmd({respond, {accepted, [0,0,1,0,0]}}),
    event([<<"respond">>, [<<"accepted">>, [0,0,1,0,0]]]),
    [{S1,E1,{{accepted, Rc}, #{worker := P1}}},{S2,E2,{{accepted, Rc}, #{worker := P2}}}] =
        cmd({a4_retry_pair,0,1,0}),
    true = P1 =/= P2 andalso max(S1,S2) < min(E1,E2),
    Retry = [<<"submit">>,0,1,0,[<<"accepted">>,Rc]],
    event([<<"concurrent">>,[Retry,Retry]]),
    ok = cmd({respond, Event}),
    event([<<"respond">>, [<<"accepted">>,Rc]]),
    Obs = observe(Target).

replacement(_, _, _, _, _, 0) -> error(missing_worker_replacement);
replacement(Beam, Front, Dead, A, B, N) ->
    #{beam := Beam, front := Front, v2 := NowA, v2_peer := NowB} = cmd(a4_pids),
    {New, Peer, BeforePeer} = case Dead of A -> {NowA, NowB, B}; B -> {NowB, NowA, A} end,
    BeforePeer = Peer,
    case is_list(New) andalso New =/= Dead of
        true -> New;
        false -> timer:sleep(10), replacement(Beam, Front, Dead, A, B, N-1)
    end.

deliver(T,J,Ok) ->
    {delivered, _} = cmd({complete,T,J,Ok}),
    event([<<"complete">>,T,J,Ok,[<<"delivered">>]]).

hex(B) -> binary:encode_hex(B, lowercase).
