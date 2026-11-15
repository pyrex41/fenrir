%% A3/A4: the capability manifest check (spec/tc1/DURABLE.md section 2). The image's
%% residual effect row, read from its artifact (the durable effects in the entry
%% function's effect set, with their full declarations and the datatypes their operation
%% types mention), must be discharged by a storage contract this host carries; otherwise
%% the worker is not started. A refusal is a deployment outcome: no tender is booted.
%%
%% The contracts this host carries, each named by its version (UPGRADE.md section 2):
%%   1          Store.commit : Tx --> Reply of spec/service/HANDLER.md section 2
%%   2          Store.commit : Tx --> Reply of spec/service/UPGRADE.md section 2.2
%%   migration  Migration.read/stage/install of UPGRADE.md section 5
%% An image's contract version is the contract its manifest matches exactly
%% (contract_version/1); an image descriptor that claims another is refused (check/2).
-module(fenrir_manifest).
-export([check/2, residual/1, provided/0, provided/1, check_artifact/1, contract_version/1, versions/0]).

versions() -> [1, 2, migration].

provided() -> provided(1).

provided(V) when V =:= 1; V =:= 2 ->
    #{<<"Store">> =>
          #{class => <<"durable">>,
            operations => #{<<"commit">> => {[<<"Data">>, <<"Tx">>], [<<"Data">>, <<"Reply">>]}}}};
provided(migration) ->
    #{<<"Migration">> =>
          #{class => <<"durable">>,
            operations => #{<<"read">> => {<<"I64">>, [<<"Data">>, <<"Next1">>]},
                            <<"stage">> => {[<<"Data">>, <<"Row2">>], [<<"Data">>, <<"Ack">>]},
                            <<"install">> => {<<"I64">>, [<<"Data">>, <<"Migrated">>]}}}}.

c(N, Fs) -> #{<<"name">> => N, <<"fields">> => Fs}.
dt(N) -> [<<"Data">>, N].
-define(I, <<"I64">>).

%% The datatypes of each contract, in the artifact's datatype encoding.
datatypes(1) ->
    maps:from_list(
      [{<<"Cap">>, [c(<<"Tenant">>, [?I])]},
       {<<"Receipt">>, [c(<<"Receipt">>, [?I, ?I, ?I, ?I, ?I])]},
       {<<"Guard">>, [c(<<"Always">>, []), c(<<"Once">>, [?I]), c(<<"Pending">>, [?I])]},
       {<<"Write">>, [c(<<"PutReport">>, [?I, <<"Bytes">>]), c(<<"StageJob">>, []), c(<<"StageJobOf">>, [?I]),
                      c(<<"RecordKey">>, [?I, ?I]), c(<<"Finish">>, [?I, <<"Bool">>])]},
       {<<"Writes">>, [c(<<"Done">>, []), c(<<"Then">>, [dt(<<"Write">>), dt(<<"Writes">>)])]},
       {<<"Tx">>, [c(<<"Tx">>, [dt(<<"Cap">>), dt(<<"Guard">>), dt(<<"Writes">>)])]},
       {<<"Reply">>, [c(<<"Committed">>, [dt(<<"Receipt">>)]), c(<<"Recorded">>, [?I, dt(<<"Receipt">>)]),
                      c(<<"Applied">>, []), c(<<"Skipped">>, []), c(<<"Unauthorized">>, [])]}]);
datatypes(2) ->
    maps:merge(datatypes(1), maps:from_list(
      [{<<"Receipt">>, [c(<<"Receipt">>, [?I, ?I, ?I, ?I, ?I]), c(<<"Receipt2">>, [?I, ?I, ?I, ?I, ?I])]},
       {<<"Write">>, [c(<<"PutReport">>, [?I, <<"Bytes">>]), c(<<"StageJob2">>, [?I]), c(<<"RecordKey">>, [?I, ?I]),
                      c(<<"Finish">>, [?I, <<"Bool">>]), c(<<"CountAttempt">>, [?I])]},
       {<<"Tx">>, [c(<<"Tx2">>, [dt(<<"Cap">>), dt(<<"Guard">>), dt(<<"Writes">>)])]}]));
datatypes(migration) ->
    S = dt(<<"Status">>),
    maps:from_list(
      [{<<"Status">>, [c(<<"Pending">>, []), c(<<"Done">>, []), c(<<"Failed">>, [])]},
       {<<"Receipt">>, [c(<<"Receipt">>, [?I, ?I, ?I, ?I, ?I]), c(<<"Receipt2">>, [?I, ?I, ?I, ?I, ?I])]},
       {<<"Row1">>, [c(<<"Job1">>, [?I, ?I, ?I, S]), c(<<"Key1">>, [?I, ?I, ?I, dt(<<"Receipt">>)])]},
       {<<"Next1">>, [c(<<"NoMore">>, []), c(<<"Next">>, [dt(<<"Row1">>)])]},
       {<<"Row2">>, [c(<<"Job2">>, [?I, ?I, ?I, S, ?I]), c(<<"Key2">>, [?I, ?I, ?I, dt(<<"Receipt">>)])]},
       {<<"Ack">>, [c(<<"Ack">>, [])]},
       {<<"Migrated">>, [c(<<"Installed">>, []), c(<<"Changed">>, []), c(<<"Refused">>, [])]}]).

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

%% ok when some contract of this host discharges the artifact's row.
check_artifact(Path) ->
    case contract_version(Path) of
        {ok, _} -> ok;
        R -> R
    end.

%% {ok, Version} for the contract the artifact's residual row matches, else
%% {refused, Problems} with the problems against contract 1 (the A3 diagnostics), or
%% {ok, none} for an artifact with no residual effect (nothing to discharge).
contract_version(Path) ->
    {ok, B} = file:read_file(Path),
    A = json:decode(B),
    version_of(residual(A), maps:get(<<"datatypes">>, A)).

version_of([], _) -> {ok, none};
version_of(Row, Datatypes) ->
    case [V || V <- versions(), check_row(V, Row, Datatypes) =:= ok] of
        [V | _] -> {ok, V};
        [] -> check_row(1, Row, Datatypes)
    end.

%% check(ArtifactPath, ImageDescriptor): the row must be the one the image build computed
%% with the JavaScript validator, a contract of this host must discharge it, and the
%% descriptor's contract_version (1 when absent, as in A3 descriptors) must be that
%% contract's. {ok, Version} | {refused, Why}.
check(Path, Image) ->
    {ok, B} = file:read_file(Path),
    A = json:decode(B),
    Row = residual(A),
    Claimed = claimed(maps:get(<<"contract_version">>, Image, 1)),
    case maps:get(<<"residual_effects">>, Image, Row) =:= Row of
        false -> {refused, residual_row_differs_from_image_build};
        true ->
            case version_of(Row, maps:get(<<"datatypes">>, A)) of
                {ok, Claimed} -> {ok, Claimed};
                {ok, Other} -> {refused, {contract_version_claimed, Claimed, manifest_matches, Other}};
                {refused, Why} -> {refused, Why}
            end
    end.

claimed(<<"migration">>) -> migration;
claimed(V) when is_integer(V) -> V;
claimed(V) when is_binary(V) -> binary_to_integer(V).

check_row(V, Row, Datatypes) ->
    P = provided(V),
    Problems = lists:flatmap(fun(E) -> effect(V, E, P, Datatypes) end, Row),
    case Problems of
        [] -> ok;
        _ -> {refused, Problems}
    end.

effect(V, E, P, Datatypes) ->
    Name = maps:get(<<"name">>, E),
    case maps:get(Name, P, none) of
        none -> [{no_contract_for_effect, Name}];
        #{class := Class, operations := Ops} ->
            [{class_differs, Name} || maps:get(<<"class">>, E) =/= Class] ++
            lists:flatmap(fun(Op) -> operation(V, Name, Op, Ops, Datatypes) end, maps:get(<<"operations">>, E))
            ++ [{operation_missing, Name, O} || O <- maps:keys(Ops),
                                                not lists:member(O, [maps:get(<<"name">>, X) || X <- maps:get(<<"operations">>, E)])]
    end.

operation(V, Effect, Op, Ops, Datatypes) ->
    N = maps:get(<<"name">>, Op),
    Arg = maps:get(<<"argument_type">>, Op),
    Res = maps:get(<<"result_type">>, Op),
    case maps:get(N, Ops, none) of
        none -> [{no_contract_for_operation, Effect, N}];
        {Arg, Res} -> types(V, [Arg, Res], Datatypes, sets:new(), []);
        _ -> [{operation_type_differs, Effect, N}]
    end.

%% Every datatype an operation type mentions, transitively, must be declared in the
%% artifact exactly as the contract declares it.
types(_, [], _, _, Acc) -> lists:reverse(Acc);
types(V, [[<<"Data">>, Name] | Rest], Datatypes, Seen, Acc) ->
    case sets:is_element(Name, Seen) of
        true -> types(V, Rest, Datatypes, Seen, Acc);
        false ->
            Seen1 = sets:add_element(Name, Seen),
            Want = maps:get(Name, datatypes(V), none),
            Have = [maps:get(<<"constructors">>, D) || D <- Datatypes, maps:get(<<"name">>, D) =:= Name],
            case {Want, Have} of
                {none, _} -> types(V, Rest, Datatypes, Seen1, [{no_contract_for_datatype, Name} | Acc]);
                {W, [W]} -> types(V, Rest ++ lists:append([maps:get(<<"fields">>, C) || C <- W]), Datatypes, Seen1, Acc);
                _ -> types(V, Rest, Datatypes, Seen1, [{datatype_differs, Name} | Acc])
            end
    end;
types(V, [[<<"Tuple">> | Ts] | Rest], Datatypes, Seen, Acc) -> types(V, Ts ++ Rest, Datatypes, Seen, Acc);
types(V, [T | Rest], Datatypes, Seen, Acc) when is_binary(T) -> types(V, Rest, Datatypes, Seen, Acc);
types(V, [T | Rest], Datatypes, Seen, Acc) -> types(V, Rest, Datatypes, Seen, [{unsupported_type, T} | Acc]).
