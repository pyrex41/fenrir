%% A3: the capability manifest check (spec/tc1/DURABLE.md section 2). The image's
%% residual effect row, read from its artifact (the durable effects in the entry
%% function's effect set, with their full declarations and the datatypes their operation
%% types mention), must be discharged by a storage contract this host carries; otherwise
%% the worker is not started. A refusal is a deployment outcome: no tender is booted.
%%
%% The one contract this host carries: Store.commit : Tx --> Reply of
%% spec/service/HANDLER.md section 2, discharged by fenrir_store.
-module(fenrir_manifest).
-export([check/2, residual/1, provided/0, check_artifact/1]).

provided() ->
    #{<<"Store">> =>
          #{class => <<"durable">>,
            operations => #{<<"commit">> => {[<<"Data">>, <<"Tx">>], [<<"Data">>, <<"Reply">>]}}}}.

%% HANDLER.md section 2, in the artifact's datatype encoding.
datatypes() ->
    C = fun(N, Fs) -> #{<<"name">> => N, <<"fields">> => Fs} end,
    D = fun(N, Cs) -> {N, Cs} end,
    I = <<"I64">>,
    maps:from_list(
      [D(<<"Cap">>, [C(<<"Tenant">>, [I])]),
       D(<<"Receipt">>, [C(<<"Receipt">>, [I, I, I, I, I])]),
       D(<<"Guard">>, [C(<<"Always">>, []), C(<<"Once">>, [I]), C(<<"Pending">>, [I])]),
       D(<<"Write">>, [C(<<"PutReport">>, [I, <<"Bytes">>]), C(<<"StageJob">>, []), C(<<"StageJobOf">>, [I]),
                       C(<<"RecordKey">>, [I, I]), C(<<"Finish">>, [I, <<"Bool">>])]),
       D(<<"Writes">>, [C(<<"Done">>, []), C(<<"Then">>, [[<<"Data">>, <<"Write">>], [<<"Data">>, <<"Writes">>]])]),
       D(<<"Tx">>, [C(<<"Tx">>, [[<<"Data">>, <<"Cap">>], [<<"Data">>, <<"Guard">>], [<<"Data">>, <<"Writes">>]])]),
       D(<<"Reply">>, [C(<<"Committed">>, [[<<"Data">>, <<"Receipt">>]]), C(<<"Recorded">>, [I, [<<"Data">>, <<"Receipt">>]]),
                       C(<<"Applied">>, []), C(<<"Skipped">>, []), C(<<"Unauthorized">>, [])])]).

%% The residual row of an artifact (a decoded JSON map): mirrors residualEffects of
%% tools/tc0/pure-call-artifact.mjs.
residual(A) ->
    case maps:get(<<"schema_version">>, A) of
        <<"tc1-durable-demo/1">> ->
            Entry = maps:get(<<"entry">>, A),
            [F] = [F || F <- maps:get(<<"functions">>, A), maps:get(<<"name">>, F) =:= Entry],
            Row = maps:get(<<"effects">>, F),
            [E || E <- maps:get(<<"effects">>, A), maps:get(<<"class">>, E, none) =:= <<"durable">>,
                  lists:member(maps:get(<<"name">>, E), Row)];
        _ -> []
    end.

check_artifact(Path) ->
    {ok, B} = file:read_file(Path),
    A = json:decode(B),
    check_row(residual(A), maps:get(<<"datatypes">>, A)).

%% check(ArtifactPath, ImageDescriptor): also requires the row the image build computed
%% with the JavaScript validator to be the same row.
check(Path, Image) ->
    {ok, B} = file:read_file(Path),
    A = json:decode(B),
    Row = residual(A),
    case maps:get(<<"residual_effects">>, Image, Row) =:= Row of
        false -> {refused, residual_row_differs_from_image_build};
        true -> check_row(Row, maps:get(<<"datatypes">>, A))
    end.

check_row(Row, Datatypes) ->
    P = provided(),
    Problems = lists:flatmap(fun(E) -> effect(E, P, Datatypes) end, Row),
    case Problems of
        [] -> ok;
        _ -> {refused, Problems}
    end.

effect(E, P, Datatypes) ->
    Name = maps:get(<<"name">>, E),
    case maps:get(Name, P, none) of
        none -> [{no_contract_for_effect, Name}];
        #{class := Class, operations := Ops} ->
            [{class_differs, Name} || maps:get(<<"class">>, E) =/= Class] ++
            lists:flatmap(fun(Op) -> operation(Name, Op, Ops, Datatypes) end, maps:get(<<"operations">>, E))
    end.

operation(Effect, Op, Ops, Datatypes) ->
    N = maps:get(<<"name">>, Op),
    Arg = maps:get(<<"argument_type">>, Op),
    Res = maps:get(<<"result_type">>, Op),
    case maps:get(N, Ops, none) of
        none -> [{no_contract_for_operation, Effect, N}];
        {Arg, Res} -> types([Arg, Res], Datatypes, sets:new(), []);
        _ -> [{operation_type_differs, Effect, N}]
    end.

%% Every datatype an operation type mentions, transitively, must be declared in the
%% artifact exactly as the contract declares it.
types([], _, _, Acc) -> lists:reverse(Acc);
types([[<<"Data">>, Name] | Rest], Datatypes, Seen, Acc) ->
    case sets:is_element(Name, Seen) of
        true -> types(Rest, Datatypes, Seen, Acc);
        false ->
            Seen1 = sets:add_element(Name, Seen),
            Want = maps:get(Name, datatypes(), none),
            Have = [maps:get(<<"constructors">>, D) || D <- Datatypes, maps:get(<<"name">>, D) =:= Name],
            case {Want, Have} of
                {none, _} -> types(Rest, Datatypes, Seen1, [{no_contract_for_datatype, Name} | Acc]);
                {W, [W]} -> types(Rest ++ lists:append([maps:get(<<"fields">>, C) || C <- W]), Datatypes, Seen1, Acc);
                _ -> types(Rest, Datatypes, Seen1, [{datatype_differs, Name} | Acc])
            end
    end;
types([[<<"Tuple">> | Ts] | Rest], Datatypes, Seen, Acc) -> types(Ts ++ Rest, Datatypes, Seen, Acc);
types([T | Rest], Datatypes, Seen, Acc) when is_binary(T) -> types(Rest, Datatypes, Seen, Acc);
types([T | Rest], Datatypes, Seen, Acc) -> types(Rest, Datatypes, Seen, [{unsupported_type, T} | Acc]).
