#!/usr/bin/env python3
"""Bounded generated Shen/candidate discovery and reduction; trusted LOCAL only."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import time

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('expression_probe', ROOT/'tools/check-tc0-expression.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shen-executable', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--max-cases', type=int, default=16)
    parser.add_argument('--max-attempts', type=int, default=40)
    args = parser.parse_args()
    if not 1 <= args.max_cases <= 100 or not 1 <= args.max_attempts <= 100:
        raise ValueError('Development caps must be 1..100')
    destination = Path(args.output).resolve()
    if not destination.is_relative_to(ROOT/'build') or destination.suffix != '.json':
        raise ValueError('Output must be JSON below build/')
    executable = Path(args.shen_executable).resolve(strict=True)
    boot = executable.parent.parent/'lib/shen-scheme/shen.boot'
    node = Path(shutil.which('node')).resolve(strict=True)
    paths = [Path(__file__), ROOT/'tools/check-tc0-expression.py',
             *[ROOT/'tools/tc0'/p for p in ['generate.mjs','reduce.mjs','reduction-bridge.mjs','artifact.mjs','canonical.mjs','replay.mjs']],
             ROOT/'models/tc0/arithmetic.shen',ROOT/'models/tc0/expression-machine.shen',
             ROOT/'runtime/tc0/expression-machine.mjs',ROOT/'spec/tc0/arithmetic-demo-frames.json',executable,boot,node]
    before = {str(p):probe.digest(p) for p in paths}
    start = time.monotonic()
    observations = []
    def budget():
        if time.monotonic()-start > 120:
            raise TimeoutError('Development campaign watchdog; not semantic timeout')
    def bridge(request):
        budget()
        # Input file is a private owned build output; no shell or background process.
        # Existing synchronous helper has no stdin support, so supply JSON via a tiny Node launcher.
        command = [str(node), '--input-type=module', '-e',
                   "import {spawnSync} from 'node:child_process'; const r=spawnSync(process.execPath,[process.argv[1]],{input:process.argv[2],encoding:'utf8',timeout:30000,maxBuffer:8388608}); if(r.error) throw r.error; if(r.status!==0) throw new Error(r.stderr);process.stdout.write(r.stdout);",
                   str(ROOT/'tools/tc0/reduction-bridge.mjs'),json.dumps(request,separators=(',',':'))]
        out, _ = probe.synchronous(command, timeout=35)
        return json.loads(out)
    def observe(artifact, input_value):
        budget()
        pair = bridge({'action':'run','artifact':artifact,'input':input_value})
        fn = artifact['functions'][0]
        if input_value != ['unit'] or fn['argument_type'] != 'Unit':
            raise ValueError('Undemonstrated input translation')
        initial = '[state [eval '+probe.shen_expr(fn['body'])+'] [['+fn['parameter_id']+' [unit]]] []]'
        # Fixed independent model bound, NOT a step count taken from candidate.
        state = '(value tc0.campaign.state)'
        terminal = '(= (hd (hd (tl '+state+'))) terminal)'
        argv = [str(executable),'eval','-l',str(ROOT/'models/tc0/arithmetic.shen'),
                '-l',str(ROOT/'models/tc0/expression-machine.shen'),'-e','(set tc0.campaign.state '+initial+')']
        for _ in range(200):
            argv += ['-e','(if '+terminal+' [] (tc0.demo.sample '+state+'))',
                     '-e','(if '+terminal+' [] (set tc0.campaign.state (hd (tl (tc0.demo.step '+state+')))))']
        argv += ['-e','(hd (hd (tl '+state+')))']
        stdout, stderr = probe.synchronous(argv, timeout=30)
        if stdout.splitlines()[-1].strip() != 'terminal':
            raise RuntimeError('Independent model budget exhausted; no completion credit')
        samples = [probe.parse_list(line) for line in stdout.splitlines() if line.startswith('[sample ')]
        reference = [probe.normalize(s,i) for i,s in enumerate(samples)]
        if pair['control']['execution'] != 'Completed' or pair['control']['steps'] != reference:
            raise RuntimeError('Unmodified candidate disagrees with independent model')
        events = [e for row in reference for e in row['events']]
        outcome = events[-1]['outcome']
        if pair['control']['outcome'] != outcome:
            raise RuntimeError('Candidate terminal outcome disagrees')
        mutant = pair['mutant']
        if mutant['execution'] != 'Completed':
            raise RuntimeError('Mutant did not complete within development bound')
        discrepancy = 'left-trap-right-emission' if (outcome[0]=='Trap' and not any(e['kind']=='Emit' for e in events)
            and any(e['kind']=='Emit' for e in mutant['events'])) else None
        result = {'artifact':artifact,'input':input_value,'reference':reference,'control':pair['control'],
                  'mutant':mutant,'metric':pair['metric'],'discrepancy':discrepancy,
                  'shen_stdout':stdout,'shen_stderr':stderr}
        observations.append(result)
        return result
    rows = bridge({'action':'generate','max_cases':str(args.max_cases)})
    original = None
    for row in rows:
        measured = observe(row['artifact'],row['input'])
        if measured['discrepancy']:
            original = measured
            discovered_index = row['index']
            break
    if original is None:
        raise RuntimeError('No discrepancy discovered in bounded generated prefix')
    current = original
    history = []
    cap_hit = False
    while True:
        changed = False
        proposals = bridge({'action':'proposals','artifact':current['artifact'],'input':current['input']})
        for proposal in proposals:
            if len(history) == args.max_attempts:
                cap_hit = True
                break
            trial = observe(proposal['artifact'],current['input'])
            accepted = trial['discrepancy'] == original['discrepancy']
            history.append({'observation_index':str(len(observations)-1),'metric':trial['metric'],'accepted':accepted})
            if accepted:
                current = trial
                changed = True
                break
        if cap_hit or not changed:
            break
    replays = {}
    for label, case in [('original',original),('minimized',current)]:
        replays[label] = bridge({'action':'replay','artifact':case['artifact'],'input':case['input'],
            'reference':case['reference'],'run_id':'generated-'+label,'shen_hash':before[str(executable)],
            'shen_boot_hash':before[str(boot)]})
        if replays[label]['replay']['replay'] != 'Exact' or replays[label]['replay']['conformance'] != 'Diverged':
            raise RuntimeError('Original/minimized failure replay did not retain Exact/Diverged')
    after = {str(p):probe.digest(p) for p in paths}
    if before != after:
        raise RuntimeError('Source/toolchain drift during campaign')
    report = {'qualification':'UNKNOWN','scope':'Trusted-local arithmetic-demo development, not full TC0-A',
              'sources':before,'discovered_index':discovered_index,'generation':rows[0]['enumeration'],
              'generation_stopped_at_first_failure':True,'original':original,'minimized':current,
              'history':history,'reduction_cap_hit':cap_hit,'reduction_scope':'Smallest-found deterministic proposals, not globally minimal',
              'observations':observations,'replays':replays,
              'limitations':['No qualified isolation or evaluator','No fresh agent repair evaluation','No calls/closures/full A',
                             'Development oracle/catalog unqualified','Semantic replay observes exposed state, not hidden native computation']}
    destination.parent.mkdir(parents=True,exist_ok=True)
    destination.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'qualification':'UNKNOWN','discovered_index':discovered_index,'attempts':len(history),
                      'original_metric':original['metric'],'minimized_metric':current['metric'],'reduction_cap_hit':cap_hit,
                      'original_failure_replay':replays['original']['replay'],'report':str(destination)}))


if __name__ == '__main__':
    main()
