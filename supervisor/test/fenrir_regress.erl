%% Regressions for remote perform (spec/tc1/EFFECTS.md §12). They describe the
%% behaviour the contract requires. On master a89bf40 they fail.
%%
%% The peer is supervisor/test/fenrir_member.erl, not a Solo5 guest.
%% fenrir_relay, fenrir_journal and fenrir_wire are the modules under test.
%% There is no xfail marker in this repository; the runner exits 1.
-module(fenrir_regress).
-export([vm_phase1/0, vm_phase2/0, upgrade/0]).

vm_phase1() ->
    Dir = run_dir(),
    start(Dir),
    step([<<"issue">>, <<"caller">>, <<"peer">>, <<"7">>]),
    step([<<"deliver-request">>]),
    Label = step([<<"act">>, <<"peer">>]),
    Store = dump(Dir),
    expect(lists:member(<<"applied">>, Label), {phase1_act, Label}),
    expect(cell0(Store) =:= 5, {phase1_cell, Store}),
    ok = file:write_file(filename:join(Dir, "READY"), <<"act committed\n">>),
    receive after infinity -> ok end.

vm_phase2() ->
    Dir = run_dir(),
    write_images(Dir),
    {ok, _} = application:ensure_all_started(fenrir_supervisor),
    Journal = fenrir_journal:take(),
    expect(Journal =:= none, {journal_not_empty, Journal}),
    ok = assemble(Dir),
    Before = dump(Dir),
    expect(cell0(Before) =:= 5, {store_not_kept, Before}),
    {ok, _} = fenrir_relay:enabled(),
    step([<<"issue">>, <<"caller">>, <<"peer">>, <<"7">>]),
    {ok, Enabled} = fenrir_relay:enabled(),
    Nd = offered(Enabled, <<"not-delivered">>),
    %% §12.4 / §12.7: key 7 was handed over and applied before the VM died, so
    %% not_delivered must not be offered for it.
    NdOk = not Nd,
    say(NdOk, "vm_loss_not_delivered: not_delivered offered for key 7, which is already applied (~p)~n", [Enabled]),
    case Nd of
        true ->
            step([<<"not-delivered">>]),
            {ok, _} = fenrir_relay:enabled(),
            step([<<"issue">>, <<"caller">>, <<"peer">>, <<"9">>]),
            step([<<"deliver-request">>]),
            step([<<"act">>, <<"peer">>]),
            step([<<"deliver-reply">>]);
        false -> ok
    end,
    After = dump(Dir),
    %% A fresh key for the same intent must not apply the effect again.
    CellOk = cell0(After) =:= 5,
    say(CellOk, "vm_loss_double_apply: cell 0 is ~p after a fresh-key retry (store ~p)~n", [cell0(After), After]),
    Outcomes = read(filename:join(Dir, "caller.outcomes")),
    io:format("vm_loss outcomes:~n~s~n", [Outcomes]),
    finish(NdOk andalso CellOk).

upgrade() ->
    Dir = run_dir(),
    Digest = list_to_binary(os:getenv("FENRIR_SIGNATURE_DIGEST")),
    expect(byte_size(Digest) =:= 64, {digest, Digest}),
    start(Dir),
    {ok, _} = fenrir_relay:enabled(),
    step([<<"issue">>, <<"caller">>, <<"peer">>, <<"1">>]),
    step([<<"deliver-request">>]),
    Act = step([<<"act">>, <<"peer">>]),
    Reply = step([<<"deliver-reply">>]),
    Outcomes = read(filename:join(Dir, "caller.outcomes")),
    %% Caller was assembled against version 1 of F(v, a) = 10*v+a. The peer
    %% runs version 2. Both images carry the same signature digest, which does
    %% not cover the function, so assembly accepted the peer.
    ValueOk = value_of(Outcomes) =:= 11,
    say(ValueOk, "upgrade_version_safe: reply ~p, expected 11 (F version 1). act ~p reply-label ~p digest ~s~n",
        [value_of(Outcomes), Act, Reply, Digest]),
    io:format("upgrade outcomes:~n~s~n", [Outcomes]),
    finish(ValueOk).

finish(true) -> erlang:halt(0);
finish(false) -> erlang:halt(1).

say(true, _, _) -> ok;
say(false, Fmt, Args) -> io:format("FAIL " ++ Fmt, Args).

offered(Labels, Kind) ->
    lists:any(fun([K | _]) -> K =:= Kind; (_) -> false end, Labels).

value_of(Bin) ->
    case re:run(Bin, "reply status=0 value=(-?[0-9]+)", [{capture, all_but_first, list}]) of
        {match, [N]} -> list_to_integer(N);
        _ -> none
    end.

run_dir() ->
    case os:getenv("RUN_DIR") of
        false -> exit(no_run_dir);
        Dir -> Dir
    end.

start(Dir) ->
    write_images(Dir),
    {ok, _} = application:ensure_all_started(fenrir_supervisor),
    ok = assemble(Dir).

assemble(Dir) ->
    case fenrir_relay:assemble(system(Dir)) of
        ok -> ok;
        Other ->
            io:format("assemble failed ~p~n", [Other]),
            erlang:halt(2)
    end.

system(Dir) ->
    #{members => [#{name => <<"caller">>, kind => caller, image => filename:join(Dir, "caller.image")},
                  #{name => <<"peer">>, kind => peer, image => filename:join(Dir, "peer.image")}],
      connections => [[<<"caller">>, <<"peer">>]],
      bindings => [[<<"caller">>, <<"Ledger">>, <<"peer">>]],
      defects => [],
      start_check => true,
      tender => "/bin/true",
      dir => Dir,
      life_ms => 60000,
      crashes => 0, duplicates => 0, supervisor_restarts => 0}.

write_images(Dir) ->
    Digest = case os:getenv("FENRIR_SIGNATURE_DIGEST") of
                 false -> binary:copy(<<"ab">>, 32);
                 Hex -> list_to_binary(Hex)
             end,
    Caller = <<"\nFENRIR-REMOTE-DECL/3 connects=peer uses=peer/Ledger.add/keyed signatures=Ledger:", Digest/binary, "\n">>,
    Peer = <<"\nFENRIR-REMOTE-SERVES/2 store=yes writes=yes operations=Ledger.add/keyed signatures=Ledger:", Digest/binary, "\n">>,
    ok = file:write_file(filename:join(Dir, "caller.image"), Caller),
    ok = file:write_file(filename:join(Dir, "peer.image"), Peer).

step(Cmd) ->
    case fenrir_relay:step(Cmd) of
        {ok, Label} ->
            io:format("step ~p -> ~p~n", [Cmd, Label]),
            Label;
        Other ->
            io:format("step ~p failed ~p~n", [Cmd, Other]),
            erlang:halt(2)
    end.

expect(true, _) -> ok;
expect(false, Why) ->
    io:format("harness error ~p~n", [Why]),
    erlang:halt(2).

dump(Dir) ->
    Path = filename:join(Dir, "peer.store"),
    {ok, <<Header:512/binary, Rest/binary>>} = file:read_file(Path),
    {ok, H} = fenrir_wire:decode_header(Header),
    Count = maps:get(count, H),
    Rows = [row(binary:part(Rest, I * 512, 512)) || I <- seq0(Count)],
    io:format("store ~p~n", [Rows]),
    Rows.

row(Block) ->
    {ok, Rec} = fenrir_wire:decode_record(Block),
    case {fenrir_wire:decode_cell(Rec), fenrir_wire:decode_stored(Rec)} of
        {{ok, K, V}, _} -> {cell, K, V};
        {_, {ok, C, K, O, A, V}} -> {stored, C, K, O, A, V}
    end.

seq0(0) -> [];
seq0(N) -> lists:seq(0, N - 1).

cell0(Rows) ->
    lists:foldl(fun({cell, 0, V}, _) -> V; (_, Acc) -> Acc end, 0, Rows).

read(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        _ -> <<>>
    end.
