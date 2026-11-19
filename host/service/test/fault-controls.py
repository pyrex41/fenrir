#!/usr/bin/env python3
"""Diagnostic controls using real service nodes and one source mutation per run.

Run on the same host as check.sh: python3 host/service/test/fault-controls.py \
    build/host/service/RUN/config.term
To reproduce the false positives at 2cc8d0e, pass that checkout's config and
append --baseline /path/to/2cc8d0e.
The control files and histories go into a fresh sibling directory. Neither the
checkout nor the campaign's original outputs are modified.
"""
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
assert len(sys.argv) == 2 or baseline, __doc__
root = Path(sys.argv[3]).resolve() if baseline else Path(__file__).resolve().parents[3]
out = Path(tempfile.mkdtemp(prefix="fault-controls-", dir=config.parent.parent))
print(out, flush=True)
service = root / "host/service"
original_ebin = config.parent / "ebin"
sqlite = config.parent / "bin/fenrir_sqlite_port"
env = dict(os.environ, FENRIR_SQLITE_PORT=str(sqlite))
env.setdefault("ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1")


def run(name, family, only, filename, old, new, proof_test):
    directory = out / name
    ebin = directory / "ebin"
    shutil.copytree(original_ebin, ebin)
    source = directory / filename
    source.write_text(replace_once((service / "src" / filename).read_text(), old,
                                   new.replace("@MARKER@", erl_string(directory / "stalled"))))
    sources = [source]
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
    print(name + (": reproduced false evidence" if baseline else ": rejected"), flush=True)


unverified = ('false = lists:any(fun(E) -> hd(E) =:= <<"fault">> end, Events), '
              '{fault_fired,false,_} = lists:keyfind(fault_fired,1,maps:get(checks,S)), '
              'not fenrir_campaign:fault_evidence(S)')
submit = 'command({submit, T, K, D, P}, _) -> fenrir_front:submit(T, K, D, P);'
run("unrelated-node-sigkill", "crash_points", "w2_request_before_commit-kill_node-submit",
    "fenrir_node.erl", submit,
    '''command({submit, T, 2, D, P}, _) ->
    case file:read_file(@MARKER@) of
        {error, enoent} ->
            ok = file:write_file(@MARKER@, <<"once">>),
            os:cmd("kill -9 " ++ os:getpid()), timer:sleep(infinity);
        {ok, _} -> fenrir_front:submit(T, 2, D, P)
    end;
'''
    + submit,
    'true = (maps:get(crashes,S) =:= 1), ' +
    ('{fault_fired,true,_} = lists:keyfind(fault_fired,1,maps:get(checks,S)), is_list(Events)'
     if baseline else unverified))

port_action = ('fire(kill_port, #{port := P}) -> kill9(P), ok;' if baseline else
               '    kill_port(Point, kill_port, P, Port, W);')
port_fault_event = 'lists:member([<<"fault">>,<<"kill_port">>,<<"s4_after_commit">>],Events) andalso maps:get(checks_ok,S)'
run("suppressed-kill", "crash_points", "s4_after_commit-kill_port-submit",
    "fenrir_faults.erl", port_action,
    'fire(kill_port, #{port := _}) -> ok;' if baseline else '    _ = {Point, P, Port, W}, ok;',
    port_fault_event if baseline else unverified)
decoy = '''    Decoy = open_port({spawn_executable, os:find_executable("sleep")},
                      [{args, ["30"]}, exit_status]),
    DecoyPid = fenrir_sqlite:os_pid(Decoy),
    true = P =/= DecoyPid,
'''
run("wrong-process", "crash_points", "s4_after_commit-kill_port-submit",
    "fenrir_faults.erl", port_action,
    ('fire(kill_port, #{port := P}) ->\n' + decoy + '    kill9(DecoyPid);' if baseline else
     decoy + '    true = erlang:port_info(Port) =/= undefined,\n'
     '    kill_port(Point, kill_port, DecoyPid, Decoy, W);'),
    port_fault_event if baseline else unverified)

if not baseline:
    run("unverified-lost-ack", "lost_ack", "", "fenrir_faults.erl",
        'fenrir_sqlite:arm(Port, after_commit, 1)',
        'fenrir_sqlite:arm(Port, after_statement, 1)',
        'true = lists:member({caller_sees_indeterminate,true,indeterminate},maps:get(checks,S)), '
        + unverified)
run("suppressed-lost-ack", "lost_ack", "", "fenrir_faults.erl",
    'fenrir_sqlite:arm(Port, after_statement, 1)' if baseline else 'fenrir_sqlite:arm(Port, after_commit, 1)',
    'fenrir_sqlite:arm(Port, disarm, 1)',
    ('lists:member([<<"fault">>,<<"sqlite_port">>,<<"lose_ack">>],Events) andalso not maps:get(checks_ok,S)'
     if baseline else unverified))

for command in ("outbox", "snapshot"):
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
         if baseline else f'Gap = [<<"gap">>,<<"driver timed out">>,<<"{command}">>], '
         'true = lists:member(Gap,maps:get(gaps,S)), lists:member(Gap,Events)'))
