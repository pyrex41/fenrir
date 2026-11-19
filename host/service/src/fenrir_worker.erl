%% A3: a supervised Fenrir worker. It owns at most ONE solo5-spt tender process at a time
%% (one request per boot: control protocol v1/v2 runs exactly one program per boot, v1
%% section 6) and speaks control protocol v2 (spec/solo5/pure-call-control-v2.md) with it:
%%
%%   boot   host/service/priv/spt-launch: solo5-spt --mem=32 --net:ctlin=@0 --net:ctlout=@2
%%          IMAGE with the port's stdin as ctlin (host -> guest) and the port's stdout as
%%          ctlout (guest -> host); the console goes to a file and is never parsed
%%   Hello  protocol, machine profile, batch identity and program count must be the
%%          image's (image.json); anything else is refused (Identity)
%%   Init   the request's entry (the request is lowered into the image: v2 section 3),
%%          its artifact identity and schema; Ready must repeat them
%%   Run    64 steps at a time until HostWait or a terminal execution
%%   HostRequest + host scope -> fenrir_store:commit/2 -> Reply -> the HostReply step
%%   Completed -> the program's result (TaskTermination outcome) -> Terminate -> Bye, exit 0
%%
%% The worker type-checks nothing the guest checks (the reply's type is checked by the
%% guest, the request's by the image's validation); it validates framing and the session
%% strictly (v1 section 4, host side) and fails closed: any deviation terminates the
%% tender and the request has no response. A commit the store could not finish (busy,
%% aborted, indeterminate) also ends the run without a reply (DURABLE.md section 4: the
%% host answers exactly once or never; D1 has no failure constructor in this handler's
%% Reply type, so a busy store cannot be told to the program).
-module(fenrir_worker).
-behaviour(gen_server).
-export([start_link/2, run/3, check_image/1, run_migration/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(FRAME_TIMEOUT, 10000).
-define(RUN_STEPS, 64).

start_link(Name, Opts) -> gen_server:start_link({local, Name}, ?MODULE, Opts, []).

%% Internal call. Scope comes from the OTP ingress or host job runner, not the guest.
%% run(Worker, Scope, Request) -> {ok, ResultValue, Stats} | {refused, Why} | {Outcome, Why, Stats}
%%   Outcome: busy | aborted (nothing committed) | indeterminate (a commit may have
%%   happened and no response exists) | failed (no commit was attempted)
run(Worker, Scope, Request) -> gen_server:call(Worker, {run, Scope, Request}, 120000).

init(Opts) ->
    process_flag(trap_exit, true),
    init_image(Opts).

init_image(Opts = #{a4_pin := Pin, image := Path}) ->
    case fenrir_a4_image:load(Path, handler_v2, Pin) of
        {ok, _} -> {ok, Opts#{boots => 0}};
        {error, E} -> {stop, E}
    end;
init_image(Opts) ->
    case check_image(maps:get(image, Opts)) of
        {ok, Image} -> {ok, Opts#{image_info => Image, boots => 0}};
        {error, E} -> {stop, E}
    end.

%% The image descriptor, the image and tender identities, and the capability manifest.
check_image(ImageJson) ->
    try
        I = json:decode(element(2, {ok, _} = file:read_file(ImageJson))),
        Image = maps:get(<<"image">>, I),
        Tender = maps:get(<<"tender">>, I),
        ok = same_sha(Image, maps:get(<<"image_sha256">>, I), image),
        ok = same_sha(Tender, maps:get(<<"tender_sha256">>, I), tender),
        Artifact = filename:join(maps:get(<<"batch_dir">>, I), "artifacts/0.json"),
        ok = same_sha(Artifact, maps:get(<<"artifact_sha256">>, I), artifact),
        case fenrir_manifest:check(Artifact, I) of
            ok -> {ok, I};
            {refused, Why} -> {error, {capability_manifest_refused, Why}}
        end
    catch
        throw:{identity, What} -> {error, {image_identity, What}};
        C:E -> {error, {bad_image_descriptor, C, E}}
    end.

same_sha(File, Want, What) ->
    case file:read_file(File) of
        {ok, B} ->
            case binary:encode_hex(crypto:hash(sha256, B), lowercase) of
                Want -> ok;
                _ -> throw({identity, What})
            end;
        _ -> throw({identity, {missing, What}})
    end.

handle_call({run, Scope, Request}, _From, S = #{a4_pin := Pin, image := Path, a4_launch_dir := Parent}) ->
    Result = case fenrir_store:handler_in_force(Pin) of
        ok ->
            case fenrir_a4_image:load(Path, handler_v2, Pin) of
                {ok, Bundle} ->
                    fenrir_a4_image:with_launch(Bundle, Parent, fun(I) ->
                        run_handler(Scope, Request, S#{image_info => I, request => Request})
                    end);
                {error, Why} -> {refused, Why}
            end;
        {refused, Why} -> {refused, Why};
        busy -> {refused, phase_check_busy};
        {aborted, Why} -> {refused, Why}
    end,
    {reply, Result, S#{boots := maps:get(boots, S) + 1}};
handle_call({run, Scope, Request}, _From, S) ->
    Result = run_handler(Scope, Request, S),
    {reply, Result, S#{boots := maps:get(boots, S) + 1}}.

run_handler(Scope, Request, S = #{image_info := I}) ->
    case entry(Scope, Request, I) of
        {ok, Program} ->
            T0 = erlang:monotonic_time(microsecond),
            Result = session(Program, Scope, S),
            T1 = erlang:monotonic_time(microsecond),
            stats(Result, T1 - T0);
        {refused, Why} -> {refused, Why}
    end.

%% Called by the already-bound migration session owner, not by the ingress.
run_migration(Path, Id, Pin, Opts = #{migration_token := Token, a4_launch_dir := Parent}) ->
    case {fenrir_store:maintenance({migration_in_force, Token, Id, Pin}), fenrir_a4_image:load(Path, migration, Pin)} of
        {ok, {ok, Bundle}} ->
            fenrir_a4_image:with_launch(Bundle, Parent, fun(I) ->
                session(0, maintenance, Opts#{image_info => I, name => migration})
            end);
        {ok, {error, Why}} -> {refused, Why};
        {Error, _} -> Error
    end.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.

stats({ok, V, St}, Us) -> {ok, V, St#{us => Us}};
stats({O, W, St}, Us) -> {O, W, St#{us => Us}}.

%% The image entry of a request; requests outside the image's domain are refused.
entry({tenant, T}, {submit, K, D, Payload}, I)
  when is_integer(T), T >= 0, is_integer(D), D >= 0, D =< 255, Payload =:= <<D>> ->
    find([<<"submit">>, T, K, D], I);
entry({tenant, _}, {submit, _, _, _}, _) -> {refused, payload_outside_image_domain};
entry({tenant, T}, {complete, J, Ok}, I) when is_integer(T), T >= 0 -> find([<<"complete">>, T, J, Ok], I);
entry(_, _, _) -> {refused, unknown_request}.

find(Req, I) ->
    case [maps:get(<<"program">>, E) || E <- maps:get(<<"entries">>, I), maps:get(<<"request">>, E) =:= Req] of
        [P] -> {ok, P};
        [] -> {refused, request_outside_image_domain}
    end.

%% ---------- one session: one boot, one request ----------

session(Program, Scope, S = #{image_info := I}) ->
    Console = filename:join(maps:get(console_dir, S, "/tmp"), "console-" ++ atom_to_list(maps:get(name, S, worker)) ++ ".txt"),
    Port = open_port({spawn_executable, maps:get(launcher, S)},
                     [binary, exit_status, use_stdio, {args, [maps:get(<<"tender">>, I), maps:get(<<"image">>, I), Console]}]),
    OsPid = case erlang:port_info(Port, os_pid) of {os_pid, P} -> P; _ -> undefined end,
    Ctx = #{tender => OsPid, tender_port => Port, worker => self()},
    St0 = #{port => Port, scope => Scope, buf => <<>>, seq => 0, epoch => 0, requests => 0, commit => none, ctx => Ctx,
            adapter => session_adapter(Scope, S),
            frames => 0, runs => 0, replies => [], tender_os_pid => OsPid},
    try
        {Hello, St1} = expect(St0, $H),
        ok = check_hello(Hello, I),
        T = boot_time(),
        {Ready, St2} = request(St1, $I, init_payload(Program, I), $Y),
        ok = check_ready(Ready, Program, I),
        drive(St2#{boot_us => T}, I)
    catch
        throw:{fail, Kind, Why, StF} -> kill(Port, OsPid), outcome(Kind, Why, StF);
        throw:{fail, Kind, Why} -> kill(Port, OsPid), outcome(Kind, Why, St0)
    end.

session_adapter(maintenance, #{migration_token := Token}) -> #{migration_token => Token};
session_adapter({tenant, _}, #{a4_pin := Pin, request := Request}) -> #{a4_pin => Pin, request => Request};
session_adapter({tenant, _}, _) -> #{}.

boot_time() -> erlang:monotonic_time(microsecond).

init_payload(Program, I) ->
    fenrir_proto:init_payload(maps:get(<<"artifact_sha256">>, I), maps:get(<<"batch_sha256">>, I),
                              maps:get(<<"fuel">>, I), "normal", Program, maps:get(<<"protocol">>, I),
                              maps:get(<<"artifact_schema">>, I)).

%% A failed session's outcome, from what the store did in it.
outcome(Kind, Why, St) ->
    O = case {Kind, maps:get(commit, St)} of
            {busy, none} -> busy;
            {aborted, none} -> aborted;
            {aborted, _} -> indeterminate;
            {indeterminate, _} -> indeterminate;
            {_, none} -> failed;
            {_, _} -> indeterminate
        end,
    {O, Why, summary(St)}.

summary(St = #{adapter := #{a4_pin := _}}) ->
    (maps:with([frames, runs, requests, commit, replies, tender_os_pid], St))#{contract_version => 2};
summary(St) -> maps:with([frames, runs, requests, commit, replies, tender_os_pid], St).

kill(Port, OsPid) ->
    catch port_close(Port),
    is_integer(OsPid) andalso os:cmd("kill -9 " ++ integer_to_list(OsPid)),
    ok.

drive(St, I) ->
    {J, St1} = request(St, $R, fenrir_proto:run_payload(?RUN_STEPS), $S),
    {Records, St2} = records(J, St1, ?RUN_STEPS),
    St3 = St2#{runs := maps:get(runs, St2) + 1},
    case maps:get(<<"execution">>, J) of
        <<"Running">> ->
            maps:get(requests, St3) =:= 0 andalso fenrir_faults:hit(w1_before_request, maps:get(ctx, St3)),
            drive(St3, I);
        <<"HostWait">> -> host_request(lists:last(Records), St3, I);
        <<"Completed">> -> completed(Records, St3);
        Other -> throw({fail, failed, {execution, Other}, St3})
    end.

host_request(Record, St, I) ->
    Seq = maps:get(requests, St),
    {Effect, Op, Value} = case [E || E <- maps:get(<<"events">>, Record), maps:get(<<"kind">>, E) =:= <<"HostRequest">>] of
                [#{<<"seq">> := SeqB, <<"effect">> := E, <<"operation">> := O, <<"value">> := V}] ->
                    SeqB =:= integer_to_binary(Seq) orelse throw({fail, failed, {'BadSteps', request_seq}, St}),
                    try {E, O, fenrir_value:from_json(V)} catch _:_ -> throw({fail, failed, {'BadSteps', request_value}, St}) end;
                _ -> throw({fail, failed, {'BadSteps', host_request}, St})
            end,
    valid_request(Effect, Op, St) orelse throw({fail, failed, {'BadSteps', host_request}, St}),
    fenrir_faults:hit(w2_request_before_commit, maps:get(ctx, St)),
    %% A guest that is already gone gets no commit made on its behalf.
    Port = maps:get(port, St),
    receive {Port, {exit_status, N}} -> throw({fail, failed, {tender_exit, N}, St})
    after 0 -> ok
    end,
    {Reply, St1} = answer(Effect, Op, Value, St),
    fenrir_faults:hit(w3_commit_before_reply, maps:get(ctx, St1)),
    {J, St2} = request(St1, $A, fenrir_proto:reply_payload(Seq, Reply), $S),
    {Records, St3} = records(J, St2, 1),
    Echo = [V || #{<<"events">> := Es} <- Records, #{<<"kind">> := <<"HostReply">>, <<"value">> := V} <- Es],
    Echo =:= [json:decode(fenrir_value:encode(Reply))] orelse throw({fail, failed, {'BadSteps', reply_echo}, St3}),
    fenrir_faults:hit(w4_reply_before_response, maps:get(ctx, St3)),
    St4 = St3#{requests := Seq + 1},
    case maps:get(<<"execution">>, J) of
        <<"Running">> -> drive(St4, I);
        <<"Completed">> -> completed(Records, St4);
        X -> throw({fail, failed, {execution, X}, St4})
    end.

valid_request(<<"Migration">>, Op, #{adapter := #{migration_token := _}}) ->
    lists:member(Op, [<<"read">>, <<"stage">>, <<"install">>]);
valid_request(<<"Store">>, <<"commit">>, #{adapter := #{a4_pin := _}, requests := 0}) -> true;
valid_request(<<"Store">>, <<"commit">>, #{adapter := A}) when map_size(A) =:= 0 -> true;
valid_request(_, _, _) -> false.

answer(<<"Migration">>, Op, V, St = #{adapter := #{migration_token := Token}}) ->
    fenrir_a4_migration:answer(Op, V, Token, St);
answer(<<"Store">>, <<"commit">>, V, St = #{adapter := #{a4_pin := Pin, request := Request}, requests := 0}) ->
    commit_reply(fenrir_store:commit_v2(maps:get(scope, St), Pin, Request, V), St);
answer(<<"Store">>, <<"commit">>, V, St = #{adapter := A}) when map_size(A) =:= 0 ->
    commit_reply(fenrir_store:commit(maps:get(scope, St), V), St);
answer(_, _, _, St) -> throw({fail, failed, {'BadSteps', host_request}, St}).

%% Busy or denied describes this operation only. It cannot undo evidence of a
%% prior reply in the same session, even though the pinned handler needs one call.
commit_reply({reply, {data, <<"Reply">>, <<"Unauthorized">>, []}}, St) ->
    throw({fail, aborted, unauthorized_scope, St});
commit_reply({reply, Reply}, St) ->
    {Reply, St#{commit := committed, replies := maps:get(replies, St) ++ [fenrir_value:encode(Reply)]}};
commit_reply(busy, St) -> throw({fail, busy, store_busy, St});
commit_reply({aborted, Why}, St) -> throw({fail, aborted, Why, St});
commit_reply({indeterminate, Why}, St = #{commit := none}) ->
    throw({fail, indeterminate, Why, St#{commit := sent}});
commit_reply({indeterminate, Why}, St) ->
    throw({fail, indeterminate, Why, St}).

completed(Records, St) ->
    Out = [O || #{<<"events">> := Es} <- Records, #{<<"kind">> := <<"TaskTermination">>, <<"outcome">> := O} <- Es],
    case Out of
        [[<<"Ok">>, V]] ->
            Value = try fenrir_value:from_json(V) catch _:_ -> throw({fail, failed, {'BadSteps', outcome}, St}) end,
            ok = check_outcome(Value, St),
            {Bye, St1} = request(St, $X, fenrir_proto:terminate_payload(), $B),
            <<"Completed">> = maps:get(<<"execution">>, Bye),
            ok = finish(St1),
            {ok, Value, summary(St1)};
        [[<<"Trap">>, C]] -> throw({fail, failed, {trap, C}, St});
        _ -> throw({fail, failed, {'BadSteps', no_outcome}, St})
    end.

check_outcome(Value, St = #{adapter := #{migration_token := _}}) ->
    case maps:get(migration_result, St, none) of
        Value -> ok;
        _ -> throw({fail, failed, migration_outcome_mismatch, St})
    end;
check_outcome(Value, St = #{adapter := #{a4_pin := _, request := Request}, replies := [Reply]}) ->
    case checked_response(Request, fenrir_value:decode(Reply)) of
        Value -> ok;
        _ -> throw({fail, failed, response_not_bound_to_store, St})
    end;
check_outcome(_, #{adapter := A}) when map_size(A) =:= 0 -> ok;
check_outcome(_, St) -> throw({fail, failed, missing_store_reply, St}).

checked_response({submit, _, _, _}, {data, <<"Reply">>, <<"Committed">>, [Rc]}) ->
    {data, <<"Response">>, <<"Accepted">>, [Rc]};
checked_response({submit, _, D, _}, {data, <<"Reply">>, <<"Recorded">>, [{int, D}, Rc]}) ->
    {data, <<"Response">>, <<"Accepted">>, [Rc]};
checked_response({submit, K, _, _}, {data, <<"Reply">>, <<"Recorded">>, [_, {data, <<"Receipt">>, _, [T | _]}]}) ->
    {data, <<"Response">>, <<"Conflict">>, [T, {int, K}]};
checked_response({complete, _, _}, {data, <<"Reply">>, C, []}) when C =:= <<"Applied">>; C =:= <<"Skipped">> ->
    {data, <<"Response">>, <<"Delivered">>, []};
checked_response(_, _) -> none.

%% After Bye: nothing more on ctlout, and the tender exits 0.
finish(St = #{buf := Buf}) when Buf =/= <<>> ->
    throw({fail, failed, 'TrailingOutput', St});
finish(St = #{port := Port, buf := <<>>}) ->
    receive
        {Port, {data, _}} -> throw({fail, failed, 'TrailingOutput', St});
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, N}} -> throw({fail, failed, {'TenderFailure', N}, St})
    after ?FRAME_TIMEOUT -> throw({fail, failed, 'HarnessTimeout', St})
    end.

%% ---------- frames ----------

request(St, Type, Payload, Want) ->
    Seq = maps:get(seq, St) + 1,
    Port = maps:get(port, St),
    try port_command(Port, fenrir_proto:frame(Type, Seq, Payload))
    catch error:badarg -> throw({fail, failed, tender_gone, St})
    end,
    expect(St#{seq := Seq}, Want).

expect(St = #{port := Port, buf := Buf, seq := Seq}, Want) ->
    case fenrir_proto:parse(Buf, Seq) of
        {frame, $E, J, _} -> throw({fail, failed, {'GuestError', maps:get(<<"code">>, J, unknown)}, St});
        {frame, Want, J, Rest} -> {J, St#{buf := Rest, frames := maps:get(frames, St) + 1}};
        {frame, _, _, _} -> throw({fail, failed, 'UnexpectedType', St});
        {error, Code} -> throw({fail, failed, Code, St});
        more ->
            receive
                {Port, {data, D}} -> expect(St#{buf := <<Buf/binary, D/binary>>}, Want);
                {Port, {exit_status, N}} -> throw({fail, failed, {tender_exit, N}, St})
            after ?FRAME_TIMEOUT -> throw({fail, failed, 'HarnessTimeout', St})
            end
    end.

check_hello(H, I) ->
    Want = #{<<"batch_sha256">> => maps:get(<<"batch_sha256">>, I),
             <<"machine_profile">> => maps:get(<<"machine_profile">>, I),
             <<"protocol">> => maps:get(<<"protocol">>, I),
             <<"programs">> => integer_to_binary(maps:get(<<"programs">>, I))},
    case maps:with(maps:keys(Want), H) =:= Want andalso is_map(maps:get(<<"limits">>, H, none)) of
        true -> ok;
        false -> throw({fail, failed, {'Identity', hello}})
    end.

check_ready(R, Program, I) ->
    Want = #{<<"artifact_sha256">> => maps:get(<<"artifact_sha256">>, I), <<"epoch">> => <<"0">>,
             <<"execution">> => <<"Running">>, <<"fuel">> => maps:get(<<"fuel">>, I), <<"mode">> => <<"normal">>,
             <<"program">> => integer_to_binary(Program), <<"schema">> => maps:get(<<"artifact_schema">>, I)},
    case maps:with(maps:keys(Want), R) =:= Want of
        true -> ok;
        false -> throw({fail, failed, {'Identity', ready}})
    end.

%% Steps records: 1..N records, epochs consecutive from the current epoch.
records(J, St, N) ->
    Steps = maps:get(<<"steps">>, J, none),
    E0 = maps:get(epoch, St),
    Ok = is_list(Steps) andalso length(Steps) >= 1 andalso length(Steps) =< N
        andalso [maps:get(<<"epoch">>, R, none) || R <- Steps] =:= [integer_to_binary(E) || E <- lists:seq(E0, E0 + length(Steps) - 1)]
        andalso maps:get(<<"epoch">>, J, none) =:= integer_to_binary(E0 + length(Steps))
        andalso lists:member(maps:get(<<"execution">>, J, none), [<<"Running">>, <<"Completed">>, <<"BudgetExhausted">>, <<"HostWait">>]),
    case Ok of
        true -> {Steps, St#{epoch := E0 + length(Steps)}};
        false -> throw({fail, failed, 'BadSteps', St})
    end.

-ifdef(TEST).

commit_outcome_test_() ->
    Before = #{commit => none, replies => [], requests => 0},
    Applied = {data, <<"Reply">>, <<"Applied">>, []},
    {Applied, After} = commit_reply({reply, Applied}, Before),
    ReplyBytes = [fenrir_value:encode(Applied)],
    Unauthorized = {reply, {data, <<"Reply">>, <<"Unauthorized">>, []}},
    ScopeMismatch = {aborted, unauthorized_scope},
    [
     {"first busy remains retryable", ?_assertEqual({busy, store_busy, Before}, store_failure(busy, Before))},
     {"commit then busy is indeterminate",
      ?_assertEqual({indeterminate, store_busy, #{commit => committed, requests => 1, replies => ReplyBytes}},
                    store_failure(busy, After#{requests := 1}))},
     {"first scope rejection is aborted", ?_assertEqual({aborted, unauthorized_scope, Before},
                                                       store_failure(ScopeMismatch, Before))},
     {"commit then scope rejection is indeterminate",
      ?_assertEqual({indeterminate, unauthorized_scope, #{commit => committed, requests => 1, replies => ReplyBytes}},
                    store_failure(ScopeMismatch, After#{requests := 1}))},
     {"Unauthorized reply also preserves prior commit",
      ?_assertEqual({indeterminate, unauthorized_scope, #{commit => committed, requests => 1, replies => ReplyBytes}},
                    store_failure(Unauthorized, After#{requests := 1}))},
     {"lost first commit reply marks sent",
      ?_assertEqual({indeterminate, lost, Before#{commit := sent}}, store_failure({indeterminate, lost}, Before))},
     {"lost later commit reply preserves prior commit",
      ?_assertEqual({indeterminate, lost, #{commit => committed, requests => 1, replies => ReplyBytes}},
                    store_failure({indeterminate, lost}, After#{requests := 1}))}
    ].

store_failure(Reply, St) ->
    try commit_reply(Reply, St)
    catch throw:{fail, Kind, Why, State} -> outcome(Kind, Why, State)
    end.

%% Model port messages directly to control the read boundaries independently of
%% the OS. The Bye bytes are the spec's bye-seq-86 vector.
bye_output_test_() ->
    Bye = <<"FGC1 GB 00000086 00000079\n"
            "{\"digest\":\"febaad5103a8d849\",\"epoch\":\"84\",\"execution\":\"Completed\",\"kind\":\"Bye\"}\n">>,
    <<Header:26/binary, Body/binary>> = Bye,
    <<Payload:79/binary, LF/binary>> = Body,
    ExtraFrame = <<"FGC1 GB 00000087 00000079\n", Body/binary>>,
    Digest = <<"FGC1 GD 00000085 00000079\n"
               "{\"digest\":\"463bdef321c45ce8\",\"epoch\":\"2\",\"execution\":\"Running\",\"kind\":\"Digest\"}\n">>,
    Exit = {exit_status, 0},
    [
     {"clean Bye", ?_assertEqual(ok, bye_output([], [{data, Bye}, Exit]))},
     {"fragmented Bye", ?_assertEqual(ok, bye_output([], [{data, Header}, {data, Payload}, {data, LF}, Exit]))},
     {"two frames consumed in order", ?_assertEqual(ok, bye_output([$D], [{data, <<Digest/binary, Bye/binary>>}, Exit]))},
     {"byte buffered after Bye", ?_assertThrow({fail, failed, 'TrailingOutput', _},
                                                bye_output([], [{data, <<Bye/binary, 0>>}, Exit]))},
     {"frame buffered after Bye", ?_assertThrow({fail, failed, 'TrailingOutput', _},
                                                 bye_output([], [{data, <<Bye/binary, ExtraFrame/binary>>}, Exit]))},
     {"byte buffered after fragmented Bye", ?_assertThrow({fail, failed, 'TrailingOutput', _},
                                                           bye_output([], [{data, Header}, {data, <<Body/binary, 0>>}, Exit]))},
     {"byte received separately after Bye", ?_assertThrow({fail, failed, 'TrailingOutput', _},
                                                           bye_output([], [{data, Bye}, {data, <<0>>}, Exit]))},
     {"nonzero exit after clean Bye", ?_assertThrow({fail, failed, {'TenderFailure', 1}, _},
                                                    bye_output([], [{data, Bye}, {exit_status, 1}]))}
    ].

bye_output(PreviousTypes, Messages) ->
    Port = make_ref(),
    [self() ! {Port, M} || M <- Messages],
    St0 = #{port => Port, buf => <<>>, seq => 86 - length(PreviousTypes), frames => 0},
    try
        St1 = lists:foldl(fun(Type, St) ->
                              {_, Parsed} = expect(St, Type),
                              Parsed#{seq := maps:get(seq, Parsed) + 1}
                          end, St0, PreviousTypes),
        {#{<<"execution">> := <<"Completed">>}, St2} = expect(St1, $B),
        finish(St2)
    after
        %% Trailing data can fail before the queued exit status is consumed.
        receive {Port, {exit_status, _}} -> ok after 0 -> ok end
    end.

-endif.
