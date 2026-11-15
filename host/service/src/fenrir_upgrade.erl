%% A4: the upgrade orchestration API of the service node (spec/service/UPGRADE.md
%% sections 4 and 10). Every transition is one transaction of the store on the durable
%% upgrade state (fenrir_store:transition/2, fenrir_store:migration/2), so a crash at any
%% point leaves the state a completed step left; the API is resumable: after a node
%% restart in `prepared` the operator migrates (again), in `migrated` cuts over.
%%
%%   begin_upgrade(V2Image, MigrationImage)  v1 -> prepared, after the capability manifest
%%       check of both descriptors: the v2 handler image must be contract 2 and the
%%       migration image the migration contract (UPGRADE.md section 4.1); otherwise refused
%%   migrate()      prepared -> migrated: one boot of the migration image, its install a
%%                  compare-and-swap of the store (section 5)
%%   cut_over()     migrated -> v2, then every worker is restarted and takes the v2 image
%%   abort_upgrade()  prepared -> v1
%%   state()        the durable upgrade state
%%
%% Outcomes: ok | {refused, Why} | changed (the migration gave up after its retries:
%% nothing applied) | busy | aborted | indeterminate (the step may have happened).
%%
%% Host mutants here (CONTRACT.md section 7): no_manifest_check (begin_upgrade admits
%% any image), stale_workers (cut_over does not restart the workers; they keep the v1
%% image and every commit they make is fenced by the store).
-module(fenrir_upgrade).
-export([begin_upgrade/2, migrate/0, cut_over/0, abort_upgrade/0, state/0]).

mutant() -> maps:get(mutant, fenrir_store:info(), normal).

state() -> fenrir_store:upgrade_state().

begin_upgrade(V2Image, MigImage) ->
    Mutant = mutant(),
    Checked = [{V2Image, fenrir_worker:check_image(V2Image), 2},
               {MigImage, fenrir_worker:check_image(MigImage), migration}],
    Problems = [{Path, Why} || {Path, R, Want} <- Checked, (Why = problem(R, Want)) =/= none],
    case {Problems, Mutant} of
        {[], _} -> do_begin(V2Image, MigImage, Checked);
        {_, no_manifest_check} -> do_begin(V2Image, MigImage, Checked);
        _ -> {refused, Problems}
    end.

problem({ok, I}, Want) ->
    case fenrir_worker:image_version(I) of
        Want -> none;
        Other -> {contract_version, Other, wanted, Want}
    end;
problem({error, E}, _) -> E.

do_begin(V2Image, MigImage, Checked) ->
    Sha = case hd(Checked) of
              {_, {ok, I}, _} -> maps:get(<<"artifact_sha256">>, I);
              _ -> <<"unchecked">>
          end,
    outcome(fenrir_store:transition(begin_upgrade, #{image => Sha, v2_image => list_to_binary(V2Image),
                                               migration_image => list_to_binary(MigImage)})).

abort_upgrade() -> outcome(fenrir_store:transition(abort, #{})).

migrate() ->
    #{upgrade := U, migration_image := Mig} = fenrir_store:upgrade_state(),
    case U of
        prepared ->
            Opts = #{launcher => launcher(), console_dir => console_dir(), name => migration},
            R = fenrir_worker:run_migration(binary_to_list(Mig), Opts),
            fenrir_faults:hit(u_after_migrate, #{}),
            case R of
                {ok, {data, <<"Migrated">>, <<"Installed">>, []}, _} -> ok;
                {ok, {data, <<"Migrated">>, <<"Changed">>, []}, _} -> changed;
                {ok, {data, <<"Migrated">>, <<"Refused">>, []}, _} -> {refused, migration_refused};
                {ok, Other, _} -> {indeterminate, {unexpected_result, Other}};
                {refused, Why} -> {refused, Why};
                {busy, _, _} -> busy;
                {aborted, _, _} -> aborted;
                {failed, Why, _} -> {aborted, Why};
                {stale, _, _} -> aborted;
                {indeterminate, _, _} -> indeterminate
            end;
        Other -> {refused, {upgrade_state, Other}}
    end.

cut_over() ->
    case outcome(fenrir_store:transition(cut_over, #{})) of
        ok ->
            fenrir_faults:hit(u_after_cut_over_meta, #{}),
            case mutant() of
                stale_workers -> ok;
                _ -> restart_workers()
            end;
        R -> R
    end.

%% Each worker is restarted and takes the image of the version now in force.
restart_workers() ->
    [begin
         _ = supervisor:terminate_child(fenrir_worker_sup, Id),
         {ok, _} = supervisor:restart_child(fenrir_worker_sup, Id)
     end || {Id, _, worker, _} <- supervisor:which_children(fenrir_worker_sup)],
    ok.

outcome(ok) -> ok;
outcome({refused, Cur}) -> {refused, {upgrade_state, Cur}};
outcome(busy) -> busy;
outcome({aborted, _}) -> aborted;
outcome({indeterminate, _}) -> indeterminate.

launcher() -> persistent_term:get(fenrir_launcher).
console_dir() -> persistent_term:get(fenrir_console_dir, "/tmp").
