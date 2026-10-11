#!/usr/bin/env python3
"""Exhaustive-small schema /2 Shen-vs-candidate agreement and mutant kills; NOT qualification.

Every program of the bounded grammar in tools/tc0/pure-data-enumerate.mjs is run on
the Shen model (one batch process) and on the candidate (one batch process). All
programs must complete within the reference-step bound with identical normalized
traces and outcomes. Each candidate-only mutant is then classified per program as
killed (completed, trace differs from the fresh model trace), survived (identical
trace: an equivalent program for that mutant) or crashed (never credited as a kill).
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('pure_call_probe', ROOT/'tools/check-tc0-pure-call.py')
pc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pc)
probe = pc.probe
MUTANTS = ('reverse_operands', 'arm_by_position')


def trace_hash(steps):
    return hashlib.sha256(json.dumps(steps, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shen-executable', required=True)
    parser.add_argument('--max-nodes', type=int, default=5)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    if not 1 <= args.max_nodes <= 5:
        raise ValueError('Node bound 1..5')
    dest = Path(args.output).resolve()
    if not dest.is_relative_to(ROOT/'build') or dest.suffix != '.json' or dest.exists():
        raise ValueError('Fresh output JSON below build required')
    oracle = pc.Oracle(shen=args.shen_executable)
    node = Path(shutil.which('node')).resolve(strict=True)
    paths = [Path(__file__), ROOT/'tools/check-tc0-pure-call.py', ROOT/'tools/check-tc0-expression.py',
             *[ROOT/'tools/tc0'/p for p in ['pure-data-enumerate.mjs', 'run-pure-data-exhaustive.mjs',
               'pure-call-artifact.mjs', 'canonical.mjs']],
             *pc.MODEL_FILES, ROOT/'runtime/tc0/pure-call-machine.mjs', ROOT/'spec/tc0/pure-call-demo.json',
             *oracle.identity_paths(), node, Path(sys.executable).resolve()]
    before = {str(p): probe.digest(p) for p in paths}
    batch = dest.with_suffix('.candidate.jsonl')
    started = time.monotonic()
    probe.synchronous([str(node), str(ROOT/'tools/tc0/run-pure-data-exhaustive.mjs'), str(args.max_nodes), str(batch)], timeout=300)
    candidate_seconds = time.monotonic()-started
    header, *rows = [json.loads(line) for line in batch.read_text().splitlines()]
    if len(rows) != int(header['count']) or header['truncated']:
        raise RuntimeError('Candidate batch does not cover the enumerated scope')
    started = time.monotonic()
    outs, errs = oracle.run([pc.initial_state(r['program']) for r in rows], timeout=1)
    model_seconds = time.monotonic()-started
    disagreements, cases = [], []
    stats = {m: {'killed': 0, 'survived': 0, 'crashed': 0, 'first_killed': None} for m in MUTANTS}
    for row, out in zip(rows, outs):
        lines = out.splitlines()
        if not lines or lines[-1].strip() != 'terminal':
            disagreements.append({'name': row['name'], 'reason': 'model incomplete within reference steps'})
            continue
        model = [pc.normalize(probe.parse_list(l), i) for i, l in enumerate(x for x in lines if x.startswith('[sample '))]
        outcome = model[-1]['events'][0]['outcome']
        got = row['candidate']
        if got['execution'] != 'Completed' or got['steps'] != model or got['outcome'] != outcome:
            disagreements.append({'name': row['name'], 'program': row['program'], 'model_outcome': outcome,
                                  'candidate_outcome': got.get('outcome'), 'reason': 'trace or outcome disagreement'})
            continue
        verdicts = {}
        for m in MUTANTS:
            r = row[m]
            verdict = 'crashed' if r['execution'] == 'Crashed' else 'survived' if r['execution'] == 'Completed' and r['steps'] == model else 'killed' if r['execution'] == 'Completed' else 'crashed'
            stats[m][verdict] += 1
            verdicts[m] = verdict
            if verdict == 'killed' and stats[m]['first_killed'] is None:
                stats[m]['first_killed'] = {'name': row['name'], 'program': row['program'], 'model_outcome': outcome, 'mutant_outcome': r['outcome']}
        cases.append({'name': row['name'], 'nodes': row['nodes'], 'result': row['result'], 'outcome': outcome,
                      'steps': str(len(model)), 'trace_sha256': trace_hash(model), **verdicts})
    after = {str(p): probe.digest(p) for p in paths}
    if before != after:
        raise RuntimeError('Source/toolchain drift')
    outcomes = {}
    for c in cases:
        key = c['outcome'][0] if c['outcome'][0] == 'Ok' else 'Trap '+c['outcome'][1]
        outcomes[key] = outcomes.get(key, 0)+1
    report = {'schema': 'pure-data-exhaustive-small-development/1', 'qualification': 'UNKNOWN',
              'scope': 'Every program of grammar G (tools/tc0/pure-data-enumerate.mjs) with at most '+str(args.max_nodes)+' AST nodes; nothing wider',
              'sources': before, 'sources_after': after, 'oracle': oracle.describe(), 'command': sys.argv,
              'enumeration': header, 'bounds': {'max_nodes': str(args.max_nodes), 'reference_steps': str(pc.REFERENCE_STEPS)},
              'seconds': {'candidate_batch': round(candidate_seconds, 2), 'model_batch': round(model_seconds, 2)},
              'agreeing': str(len(cases)), 'disagreements': disagreements, 'outcomes': outcomes,
              'max_steps': str(max(int(c['steps']) for c in cases)) if cases else '0',
              'mutants': stats, 'candidate_batch_sha256': probe.digest(batch),
              'model_stdout_sha256': hashlib.sha256(''.join(outs).encode()).hexdigest(), 'cases': cases,
              'limitations': ['Bounded grammar and node count; not exhaustive TC0-A exploration',
                              'Mutant survivors are equivalent on those programs, not evidence of mutant equivalence in general',
                              'Crashed mutants are recorded, never credited as semantic kills']}
    with dest.open('x') as f:
        f.write(json.dumps(report, indent=1)+'\n')
    print(json.dumps({'qualification': 'UNKNOWN', 'programs': header['count'], 'agreeing': len(cases),
                      'disagreements': len(disagreements), 'outcomes': outcomes,
                      'mutants': {m: {k: v for k, v in s.items() if k != 'first_killed'} for m, s in stats.items()},
                      'seconds': report['seconds'], 'report': str(dest)}))
    if disagreements:
        sys.exit(1)


if __name__ == '__main__':
    main()
