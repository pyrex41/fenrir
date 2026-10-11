#!/usr/bin/env python3
"""Bounded pure-call generated discovery/reduction; trusted-local, NOT qualification."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import time
import os
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('pure_call_probe', ROOT/'tools/check-tc0-pure-call.py')
pc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pc)
probe = pc.probe


def emissions(run):
    return [e['label'] for s in run['steps'] for e in s['events'] if e['kind'] == 'Emit']


# Candidate-only mutants (run-pure-call.mjs flags) and the one discrepancy class each
# is expected to produce. A mutant trace matching the reference is a survivor.
MUTANTS = {'reverse-operands': ('--reverse-operands', 'reversed-emissions-same-outcome'),
           'arm-by-position': ('--arm-by-position', 'wrong-match-arm')}
FAMILIES = {'pure-call': 'tools/tc0/pure-call-generate.mjs', 'pure-data': 'tools/tc0/pure-data-generate.mjs'}


def classify(reference, mutant, kind='reverse-operands'):
    if mutant['execution'] != 'Completed':
        raise RuntimeError('Mutant incomplete; no semantic kill')
    model = reference['model_steps']
    if model == mutant['steps']:
        return None
    if kind == 'reverse-operands':
        if (emissions(reference['candidate']) == ['left', 'right']
                and emissions(mutant) == ['right', 'left']
                and mutant['outcome'] == reference['hand_outcome']):
            return 'reversed-emissions-same-outcome'
        return None
    # wrong-match-arm: the traces agree through a MatchReturn step, then dispatch
    # different nodes, i.e. the mutant entered a different arm body.
    steps = mutant['steps']
    k = next((i for i, (a, b) in enumerate(zip(model, steps)) if a != b), None)
    if (k is not None and k > 0
            and model[k-1]['site']['rule'] == 'MatchReturn'
            and model[k]['site']['rule'] == steps[k]['site']['rule'] == 'Dispatch'
            and model[k]['site']['node'] != steps[k]['site']['node']):
        return 'wrong-match-arm'
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shen-executable', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--max-cases', type=int, default=32)
    parser.add_argument('--max-attempts', type=int, default=100)
    parser.add_argument('--family', choices=sorted(FAMILIES), default='pure-call')
    parser.add_argument('--mutant', choices=sorted(MUTANTS), default='reverse-operands')
    parser.add_argument('--wall-seconds', type=int, default=120)
    args = parser.parse_args()
    if not 1 <= args.max_cases <= 32 or not 1 <= args.max_attempts <= 100 or not 1 <= args.wall_seconds <= 600:
        raise ValueError('Caps: cases1..32, attempts1..100, wall seconds1..600')
    wall = args.wall_seconds
    flag, expected_discrepancy = MUTANTS[args.mutant]
    dest = Path(args.output).resolve()
    if not dest.is_relative_to(ROOT/'build') or dest.suffix != '.json' or dest.exists():
        raise ValueError('Fresh output JSON below build required')
    executable = Path(args.shen_executable).resolve(strict=True)
    oracle = pc.Oracle(shen=executable)
    node = Path(shutil.which('node')).resolve(strict=True)
    paths = [Path(__file__), ROOT/'tools/check-tc0-pure-call.py', ROOT/'tools/check-tc0-expression.py',
             *[ROOT/'tools/tc0'/p for p in ['pure-call-generate.mjs', 'pure-data-generate.mjs', 'pure-call-reduce.mjs',
               'pure-call-campaign-bridge.mjs', 'run-pure-call.mjs', 'pure-call-artifact.mjs', 'canonical.mjs']],
             *pc.MODEL_FILES,
             ROOT/'runtime/tc0/pure-call-machine.mjs', ROOT/'spec/tc0/pure-call-demo.json',
             executable, node, executable.parent.parent/'lib/shen-scheme/shen.boot', Path(sys.executable).resolve()]
    before = {str(p): probe.digest(p) for p in paths}
    start = time.monotonic()
    def bounded_synchronous(argv, timeout=30, stdin=None, cwd=None):
        remaining = wall-(time.monotonic()-start)
        if remaining <= 0:
            raise TimeoutError('Campaign watchdog')
        deadline = time.monotonic()+min(timeout, remaining)
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr, tempfile.TemporaryFile() as given:
            if stdin is not None:
                given.write(stdin.encode())
                given.seek(0)
            process = subprocess.Popen(argv, stdout=stdout, stderr=stderr, start_new_session=True, cwd=cwd or ROOT,
                                       stdin=None if stdin is None else given)
            try:
                while True:
                    size = os.fstat(stdout.fileno()).st_size+os.fstat(stderr.fileno()).st_size
                    if size > 8388608:
                        raise RuntimeError('Transport output cap')
                    if time.monotonic() > deadline:
                        raise TimeoutError('Process/campaign watchdog, not semantic timeout')
                    if process.poll() is not None:
                        break
                    time.sleep(0.01)
                stdout.seek(0)
                stderr.seek(0)
                out, err = stdout.read().decode(), stderr.read().decode()
                if process.returncode:
                    raise RuntimeError(f'Process exit {process.returncode}: {err[-2000:]}')
                return out, err
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
    # Also bound pc.observe's candidate/model subprocesses; semantic logic stays independent.
    probe.synchronous = bounded_synchronous
    # A fresh campaign directory avoids replacing prior source-bound inputs.
    dest.parent.mkdir(parents=True, exist_ok=True)
    scratch = dest.with_suffix('.inputs')
    scratch.mkdir(exist_ok=False)
    def run(argv):
        if time.monotonic()-start > wall:
            raise TimeoutError('Campaign wall watchdog, not semantic outcome')
        out, err = probe.synchronous(argv, timeout=30)
        if len(out.encode())+len(err.encode()) > 8388608:
            raise RuntimeError('Transport output cap; no completion credit')
        return json.loads(out), err
    def bridge(action, arg):
        return run([str(node), str(ROOT/'tools/tc0/pure-call-campaign-bridge.mjs'), action, str(arg)])[0]
    observations = []
    def observe(case):
        if time.monotonic()-start > wall:
            raise TimeoutError('Campaign watchdog')
        measured = pc.observe(case, oracle, node, scratch)
        if len(measured['shen_stdout'].encode())+len(measured['shen_stderr'].encode()) > 8388608:
            raise RuntimeError('Model output cap')
        path = scratch/(case['name']+'.json')
        # Separate default invocation is an explicitly equivalent no-op control,
        # not a non-equivalent mutation and not independent semantic authority.
        control, control_err = run([str(node), str(ROOT/'tools/tc0/run-pure-call.mjs'), str(path)])
        if control != measured['candidate']:
            raise RuntimeError('Equivalent control disagrees with fresh baseline')
        mutant, mutant_err = run([str(node), str(ROOT/'tools/tc0/run-pure-call.mjs'), str(path), flag])
        metric = bridge('reduce', path)['metric']
        if metric['nodes'] > 200:
            raise RuntimeError('AST node bound exceeded')
        measured.update(metric=metric, equivalent_control=control, equivalent_control_stderr=control_err,
                        mutant=mutant, mutant_stderr=mutant_err, discrepancy=classify(measured, mutant, args.mutant))
        # Generated cases may carry an independently derived mutant outcome.
        predicted = case.get(args.mutant.replace('-', '_')+'_outcome')
        if predicted is not None and measured['discrepancy'] and mutant['outcome'] != predicted:
            raise RuntimeError('Mutant outcome differs from the generator-derived prediction')
        observations.append(measured)
        return measured
    family = run([str(node), str(ROOT/'tools/tc0/pure-call-campaign-bridge.mjs'), 'generate', str(args.max_cases), args.family])[0]
    original = None
    discovery_index = None
    for i, case in enumerate(family['cases']):
        measured = observe({k:v for k,v in case.items() if k != 'parameters'})
        if measured['discrepancy'] not in (None, expected_discrepancy):
            raise RuntimeError('Unexpected discrepancy class')
        if measured['discrepancy']:
            original, discovery_index = measured, i
            break
    if original is None:
        raise RuntimeError('No expected discrepancy discovered in generated prefix')
    current, history, cap_hit = original, [], False
    while True:
        proposals = bridge('reduce', scratch/(current['name']+'.json'))['proposals']
        changed = False
        for proposal in proposals:
            if len(history) >= args.max_attempts:
                cap_hit = True
                break
            case = {'name':'reduction-'+str(len(history)), 'program':proposal['program']}
            trial = observe(case)
            # Acceptance keeps the discrepancy class on fresh model/candidate
            # observations; the model outcome itself may change under reduction.
            accepted = trial['discrepancy'] == original['discrepancy']
            if trial['metric']['nodes'] >= current['metric']['nodes']:
                raise RuntimeError('Reduction did not decrease node metric')
            history.append({'observation_index':str(len(observations)-1), 'rule':proposal['rule'],
                            'path':proposal['path'], 'metric':trial['metric'], 'accepted':accepted})
            if accepted:
                current, changed = trial, True
                break
        if cap_hit or not changed:
            break
    if current['metric']['nodes'] >= original['metric']['nodes']:
        raise RuntimeError('No smaller valid failure obtained')
    after = {str(p):probe.digest(p) for p in paths}
    if before != after:
        raise RuntimeError('Source/toolchain drift')
    report = {'schema':'pure-call-reduction-development/2', 'qualification':'UNKNOWN',
              'scope':'Trusted-local finite '+args.family+' family, not full TC0-A', 'family':args.family,
              'mutant':args.mutant, 'expected_discrepancy':expected_discrepancy,
              'acceptance':'same discrepancy class on fresh Shen/candidate observations; outcome may change', 'sources':before,
              'sources_after':after, 'command':sys.argv, 'bounds':{'cases':str(args.max_cases),
              'ast_nodes':'200','reference_steps':'200','attempts':str(args.max_attempts),
              'wall_seconds':str(wall),'per_process_seconds':'30','output_bytes_per_process':'8388608'},
              'generation':{k:v for k,v in family.items() if k != 'cases'},
              'discovered_index':str(discovery_index), 'stopped_at_first_failure':True,
              'original':original,'minimized':current,'observations':observations,'history':history,
              'reduction_cap_hit':cap_hit,'cleanup':'confirmed',
              'limitations':['Smallest-found typed proposals, not global minimality or exhaustive exploration',
                             'No enforced evaluator isolation or independent agent repair',
                             'No exact replay claim until separately source-verified tapes are regenerated']}
    # Recheck immediately before publishing the retained bytes.
    if before != {str(p):probe.digest(p) for p in paths}:
        raise RuntimeError('Late source drift')
    with dest.open('x') as f:
        f.write(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'qualification':'UNKNOWN','family':args.family,'mutant':args.mutant,'discovered_index':str(discovery_index),
                      'attempts':len(history),'original_metric':original['metric'],
                      'minimized_metric':current['metric'],'reduction_cap_hit':cap_hit,'report':str(dest)}))


if __name__ == '__main__':
    main()
