#!/usr/bin/env python3
"""Diagnostic controls using real service nodes and isolated source mutations.

Run on the same host as check.sh: python3 host/service/test/fault-controls.py \
    build/host/service/RUN/config.term
To reproduce the false positives at 2cc8d0e, pass that checkout's config and
append --baseline /path/to/2cc8d0e.
To reproduce the recovery/format/tender failures at 43eea72, use that run's
config and append --gap-baseline /path/to/43eea72.
To reproduce observation substitution at 001db56, append --observe-baseline
/path/to/001db56 to that revision's run config.
The control files and histories go into a fresh sibling directory. Neither the
checkout nor the campaign's original outputs are modified.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def replace_once(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new)


def erl_string(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


config = Path(sys.argv[1]).resolve()
baseline = len(sys.argv) == 4 and sys.argv[2] == "--baseline"
gap_baseline = len(sys.argv) == 4 and sys.argv[2] == "--gap-baseline"
observe_baseline = len(sys.argv) == 4 and sys.argv[2] == "--observe-baseline"
any_baseline = baseline or gap_baseline or observe_baseline
assert len(sys.argv) == 2 or any_baseline, __doc__
root = Path(sys.argv[3]).resolve() if any_baseline else Path(__file__).resolve().parents[3]
out = Path(tempfile.mkdtemp(prefix="fault-controls-", dir=config.parent.parent))
print(out, flush=True)
service = root / "host/service"
original_ebin = config.parent / "ebin"
sqlite = config.parent / "bin/fenrir_sqlite_port"
env = dict(os.environ, FENRIR_SQLITE_PORT=str(sqlite))
env.setdefault("ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1")


def run(name, family, only, filename, old, new, proof_test, history_verdict=None,
        mutant=False, positive=False):
    directory = out / name
    ebin = directory / "ebin"
    shutil.copytree(original_ebin, ebin)
    source = directory / filename
    source.write_text(replace_once((service / "src" / filename).read_text(), old,
                                   new.replace("@MARKER@", erl_string(directory / "stalled"))))
    if mutant:
        source.write_text(replace_once(source.read_text(), "    {jobs_done, N};",
                                       "    case N of 0 -> put(snapshot_after_drain, 2); _ -> ok end,\n"
                                       "    {jobs_done, N};"))
    sources = [source]
    if mutant:
        campaign = directory / "fenrir_campaign.erl"
        campaign.write_text(replace_once((service / "test/fenrir_campaign.erl").read_text(),
                                         "Ctx = ctx(C, normal, 1),",
                                         "Ctx = ctx(C, equivalent_control, 1),"))
        sources.append(campaign)
    if baseline and family == "random_schedules":
        # The older driver has a fixed two-minute timeout. Change only its
        # duration, not how it handles the timeout.
        driver = directory / "fenrir_drive.erl"
        driver.write_text(replace_once((service / "test/fenrir_drive.erl").read_text(),
                                       "after 120000 ->", "after 1000 ->"))
        sources.append(driver)
    script = directory / "run.config"
    with (directory / "log.txt").open("w") as log:
        # Reuse the real run configuration, including its absolute paths, but
        # exercise only the fault being controlled in a fresh output tree.
        subprocess.run([
            "erl", "-noshell", "-eval",
            "{ok, [C]} = file:consult(" + erl_string(config) + "), "
            "C1 = C#{out => " + erl_string(directory) + ", ebin => " + erl_string(ebin)
            + ", families => [" + family + "], only => " + erl_string(only)
            + ", repeats => 1, random_schedules => 1, schedule_length => 1, call_timeout => 1000}, "
            "ok = file:write_file(" + erl_string(script) + ', io_lib:format("~p.~n", [C1])), halt().',
        ], env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run(["erlc", "-Wall", "-Werror", "-o", ebin, *sources],
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run(["erl", "-noshell", "-pa", ebin, "-run", "fenrir_campaign", "main", script],
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run([
            "erl", "-noshell", "-pa", ebin, "-eval",
            "{ok,B} = file:read_file(" + erl_string(directory / "scenarios.bin") + "), "
            "Rows = binary_to_term(B), "
            'io:format("~p~n", [Rows]), '
            "true = lists:all(fun(S = #{status := executed, history := Path}) -> "
            "{ok,H} = file:read_file(Path), Events = maps:get(<<\"events\">>, json:decode(H)), "
            + proof_test + " end, Rows), "
            "true = (length(Rows) =:= " + ("2" if family == "lost_ack" else "1") + "), halt().",
        ], env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        if history_verdict is not None:
            verdict_dir = directory / "verdicts"
            subprocess.run(["sh", root / "harness/run-service-history.sh",
                            directory / "histories.txt", verdict_dir],
                           env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            verdict = json.loads((verdict_dir / "verdicts.jsonl").read_text())
            assert verdict["verdict"] == history_verdict, verdict
    result = "reproduced false evidence" if any_baseline else ("accepted" if positive else "rejected")
    print(f"{name}: {result}", flush=True)


unverified = ('false = lists:any(fun(E) -> hd(E) =:= <<"fault">> end, Events), '
              '{fault_fired,false,_} = lists:keyfind(fault_fired,1,maps:get(checks,S)), '
              'not fenrir_campaign:fault_evidence(S)')
if not gap_baseline and not observe_baseline:
    submit_context = '_' if baseline else '{_, Tokens, _}'
    submit_call = 'fenrir_front:submit(T, K, D, P)' if baseline else 'fixture_submit(Tokens, T, K, D, P)'
    submit = f'command({{submit, T, K, D, P}}, {submit_context}) -> {submit_call};'
    run("unrelated-node-sigkill", "crash_points", "w2_request_before_commit-kill_node-submit",
        "fenrir_node.erl", submit,
        '''command({submit, T, 2, D, P}, @CONTEXT@) ->
    case file:read_file(@MARKER@) of
        {error, enoent} ->
            ok = file:write_file(@MARKER@, <<"once">>),
            os:cmd("kill -9 " ++ os:getpid()), timer:sleep(infinity);
        {ok, _} -> @CALL@
    end;
'''.replace('@CONTEXT@', submit_context).replace('@CALL@', submit_call.replace('K, D', '2, D'))
        + submit,
        'true = (maps:get(crashes,S) =:= 1), ' +
        ('{fault_fired,true,_} = lists:keyfind(fault_fired,1,maps:get(checks,S)), is_list(Events)'
         if baseline else unverified))

decoy = '''    Decoy = open_port({spawn_executable, os:find_executable("sleep")},
                      [{args, ["30"]}, exit_status]),
    DecoyPid = fenrir_sqlite:os_pid(Decoy),
    true = P =/= DecoyPid,
'''
if not gap_baseline and not observe_baseline:
    port_action = ('fire(kill_port, #{port := P}) -> kill9(P), ok;' if baseline else
                   '    kill_port(Point, kill_port, P, Port, W);')
    port_fault_event = 'lists:member([<<"fault">>,<<"kill_port">>,<<"s4_after_commit">>],Events) andalso maps:get(checks_ok,S)'
    run("suppressed-kill", "crash_points", "s4_after_commit-kill_port-submit",
        "fenrir_faults.erl", port_action,
        'fire(kill_port, #{port := _}) -> ok;' if baseline else '    _ = {Point, P, Port, W}, ok;',
        port_fault_event if baseline else unverified)
    run("wrong-process", "crash_points", "s4_after_commit-kill_port-submit",
        "fenrir_faults.erl", port_action,
        ('fire(kill_port, #{port := P}) ->\n' + decoy + '    kill9(DecoyPid);' if baseline else
         decoy + '    true = erlang:port_info(Port) =/= undefined,\n'
         '    kill_port(Point, kill_port, DecoyPid, Decoy, W);'),
        port_fault_event if baseline else unverified)

if not any_baseline:
    run("unverified-lost-ack", "lost_ack", "", "fenrir_faults.erl",
        'fenrir_sqlite:arm(Port, after_commit, 1)',
        'fenrir_sqlite:arm(Port, after_statement, 1)',
        'true = lists:member({caller_sees_indeterminate,true,indeterminate},maps:get(checks,S)), '
        + unverified)
if not gap_baseline and not observe_baseline:
    run("suppressed-lost-ack", "lost_ack", "", "fenrir_faults.erl",
        'fenrir_sqlite:arm(Port, after_statement, 1)' if baseline else 'fenrir_sqlite:arm(Port, after_commit, 1)',
        'fenrir_sqlite:arm(Port, disarm, 1)',
        ('lists:member([<<"fault">>,<<"sqlite_port">>,<<"lose_ack">>],Events) andalso not maps:get(checks_ok,S)'
         if baseline else unverified))

for command in (() if observe_baseline else ("outbox",) if gap_baseline else ("outbox", "snapshot")):
    handler = {"outbox": "fenrir_front:outbox()", "snapshot": "fenrir_store:snapshot()"}[command]
    # Stall the first instance only; the restarted node must answer observations.
    run(command + "-timeout", "random_schedules", "", "fenrir_node.erl",
        f"command({command}, _) -> {handler};",
        f'''command({command}, _) ->
    Marker = @MARKER@,
    case file:read_file(Marker) of
        {{error, enoent}} -> ok = file:write_file(Marker, <<"once">>), timer:sleep(infinity);
        {{ok, _}} -> {handler}
    end;''',
        ('[] = maps:get(gaps,S), '
         'false = lists:any(fun(E) -> hd(E) =:= <<"gap">> end, Events), maps:get(checks_ok,S)'
         if baseline else (f'Gap = [<<"gap">>,<<"driver timed out">>,<<"{command}">>], '
                           if gap_baseline else f'Gap = [<<"gap">>,<<"driver timed out: {command}">>], ')
         + 'true = lists:member(Gap,maps:get(gaps,S)), lists:member(Gap,Events)'),
         history_verdict=None if baseline else ("rejected" if gap_baseline else "indeterminate"))

if not baseline and not observe_baseline:
    run("wrong-tender", "crash_points", "w3_commit_before_reply-kill_tender-submit",
        "fenrir_faults.erl", "    kill_port(Point, kill_tender, P, Port, W);",
        decoy + '    true = port_close(Port),\n    kill_port(Point, kill_tender, DecoyPid, Decoy, W);',
        ('{fault_fired,true,_} = lists:keyfind(fault_fired,1,maps:get(checks,S)), maps:get(checks_ok,S) '
         'andalso lists:member([<<"fault">>,<<"kill_tender">>,<<"w3_commit_before_reply">>],Events)'
         if gap_baseline else unverified))
    run("recovery-snapshot-timeout", "crash_points", "w4_reply_before_response-kill_node-submit",
        "fenrir_node.erl",
        "command(snapshot, _) -> fenrir_store:snapshot();",
        '''command(snapshot, _) ->
    case get(snapshot_after_drain) of
        1 -> timer:sleep(infinity);
        2 -> put(snapshot_after_drain, 1), fenrir_store:snapshot();
        _ -> fenrir_store:snapshot()
    end;''',
        ('[] = maps:get(gaps,S), '
         '{fault_fired,true,_} = lists:keyfind(fault_fired,1,maps:get(checks,S)), '
         '{no_pending_job_after_drain,false,unavailable} = '
         'lists:keyfind(no_pending_job_after_drain,1,maps:get(checks,S)), '
         'true = (maps:get(mutant,S) =:= equivalent_control), is_list(Events)'
         if gap_baseline else
         'Gap = [<<"gap">>,<<"driver timed out: snapshot">>], '
         '{probe_available,false,snapshot} = lists:keyfind(probe_available,1,maps:get(checks,S)), '
         'true = fenrir_campaign:fault_evidence(S), '
         'true = lists:member(Gap,maps:get(gaps,S)), lists:member(Gap,Events)'),
        history_verdict="accepted" if gap_baseline else "indeterminate", mutant=True)

if not baseline and not gap_baseline:
    def lost_observation(prior_crashes):
        if observe_baseline:
            return (
                f"{prior_crashes + 1} = maps:get(crashes,S), "
                f"{prior_crashes + 2} = maps:get(boots,S), "
                '[] = maps:get(gaps,S), true = maps:get(checks_ok,S), '
                'true = lists:member([<<"crash">>,<<"node">>],Events), '
                'hd(lists:last(Events)) =:= <<"observe">>'
            )
        return (
            f"{prior_crashes + 1} = maps:get(crashes,S), "
            f"{prior_crashes + 1} = maps:get(boots,S), "
            'false = maps:get(checks_ok,S), '
            '{probe_available,false,observe} = lists:keyfind(probe_available,1,maps:get(checks,S)), '
            'Gap = [<<"gap">>,<<"probe lost node: {observe,47}">>], '
            '[Gap] = maps:get(gaps,S), '
            'lists:sublist(lists:reverse(Events),2) =:= [[<<"crash">>,<<"node">>],Gap]'
        )

    want = "accepted" if observe_baseline else "indeterminate"
    run("final-observation-node-exit", "retries", "",
        "fenrir_node.erl", "command(snapshot, _) -> fenrir_store:snapshot();",
        '''command(snapshot, _) ->
    case get(final_observe_control) of
        true -> erlang:halt(47);
        _ -> put(final_observe_control, true), fenrir_store:snapshot()
    end;''',
        lost_observation(0), history_verdict=want)

    after_drain = '''command(snapshot, _) ->
    case erase(snapshot_after_drain) of
        2 -> @ACTION@;
        _ -> fenrir_store:snapshot()
    end;'''
    case_name = "w4_reply_before_response-kill_node-submit"
    run("recovery-observation-node-exit", "crash_points", case_name,
        "fenrir_node.erl", "command(snapshot, _) -> fenrir_store:snapshot();",
        after_drain.replace("@ACTION@", "erlang:halt(47)"),
        'true = fenrir_campaign:fault_evidence(S), ' + lost_observation(1),
        history_verdict=want, mutant=True)

    if not observe_baseline:
        run("same-boot-observation-retry", "crash_points", case_name,
            "fenrir_node.erl", "command(snapshot, _) -> fenrir_store:snapshot();",
            after_drain.replace("@ACTION@", "store_restarting"),
            'true = fenrir_campaign:fault_evidence(S), '
            '1 = maps:get(crashes,S), 2 = maps:get(boots,S), [] = maps:get(gaps,S), '
            'true = maps:get(checks_ok,S), hd(lists:last(Events)) =:= <<"observe">>',
            history_verdict="accepted", mutant=True, positive=True)
