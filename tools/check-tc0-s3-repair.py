#!/usr/bin/env python3
"""Frozen S3 candidate-only repair evaluator; development tier, NOT qualification.

Evaluates a repairer's workspace (from tools/tc0/s3-prepare.mjs) against its packet:

 1. Only the allowed candidate path changed; every protected input is byte-identical.
 2. The candidate differs from the preserved defective original.
 3. Exact-original replay: the defective original still reproduces each retained
    failure, stopping at its recorded first divergence.
 4. The repaired candidate replays each retained failure Exact and Admitted.
 5. Fresh Shen agreement on the hand cases (workspace checker, repaired candidate).
 6. Workspace regression suite.
 7. Held-out (never in the workspace): the generated pure-call and pure-data families,
    and every exhaustive-small program up to 5 nodes, against fresh Shen observations.
 8. Mutation control: the same held-out exhaustive scope at 4 nodes must reject the
    preserved defective original.

The repaired candidate is untrusted code. Every step that executes it (4, 5, 7) runs it
inside tools/tc0/sandbox.mjs: no network, no inherited environment, reads limited to the
candidate tree and inputs, no writes beyond its one output, no processes. The workspace
regression suite (6) spawns processes and writes scratch files, so it runs with network
and environment isolation only; each step records its boundary.

Verdict DEVELOPMENT-PASS only if every step passes. The evaluator cannot establish
who authored the patch; the independence claim stays UNKNOWN unless recorded elsewhere.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()


def tree(start, candidate, dest):
    """Trusted export of the start revision with one candidate file substituted."""
    dest.mkdir(parents=True)
    archive = subprocess.run(['git', 'archive', '--format=tar', start], cwd=ROOT, check=True, capture_output=True).stdout
    subprocess.run(['tar', '-x', '-C', str(dest)], input=archive, check=True)
    shutil.copyfile(candidate, dest/'runtime/tc0/pure-call-machine.mjs')
    return dest


def run(argv, cwd, timeout=600, env=None):
    started = time.monotonic()
    r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout, start_new_session=True, env=env)
    return r, round(time.monotonic()-started, 2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packet', required=True)
    parser.add_argument('--workspace', required=True)
    parser.add_argument('--shen-executable', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    packet, workspace = Path(args.packet).resolve(strict=True), Path(args.workspace).resolve(strict=True)
    shen = str(Path(args.shen_executable).resolve(strict=True))
    dest = Path(args.output).resolve()
    if not dest.is_relative_to(ROOT/'build') or dest.suffix != '.json' or dest.exists():
        raise ValueError('Fresh output JSON below build required')
    scratch = dest.with_suffix('.eval')
    scratch.mkdir(parents=True)
    manifest = json.loads((packet/'workspace-manifest.json').read_text())
    bundle_path, defective = packet/'failure-bundle.json', packet/'defective-pure-call-machine.mjs'
    bundle = json.loads(bundle_path.read_text())
    allowed = set(manifest['allowed_paths'])
    candidate_rel = bundle['candidate_path']
    steps, node = [], shutil.which('node')

    def record(name, ok, **detail):
        steps.append({'step': name, 'status': 'PASS' if ok else 'FAIL', **detail})
        return ok

    # 1. Protected inputs and allowed paths.
    current = {}
    for p in sorted(workspace.rglob('*')):
        rel = str(p.relative_to(workspace))
        if p.is_file() and not any(rel.startswith(x) for x in manifest['ignored_prefixes']) and '__pycache__' not in p.parts:
            current[rel] = sha(p)
    expected = manifest['files']
    violations = sorted({k for k in set(current) | set(expected) if k not in allowed and current.get(k) != expected.get(k)})
    record('protected-inputs', not violations and sha(workspace/'s3/failure-bundle.json') == sha(bundle_path),
           violations=violations[:50], violation_count=str(len(violations)))
    candidate = workspace/candidate_rel
    # 2. The candidate must actually change.
    changed = candidate.is_file() and sha(candidate) != bundle['defective_candidate_sha256'] and sha(defective) == bundle['defective_candidate_sha256']
    record('candidate-changed', changed, candidate_sha256=sha(candidate) if candidate.is_file() else None)
    if all(s['status'] == 'PASS' for s in steps):
        evaluated = tree(manifest['start_revision'], candidate, scratch/'repaired-tree')
        control = tree(manifest['start_revision'], defective, scratch/'defective-tree')
        # 3-4. Exact-original replay and retained failures under the repair.
        for mode, cand in (('original', defective), ('repaired', candidate)):
            out = scratch/f'{mode}-replay.json'
            replay = [str(evaluated/'tools/tc0/s3-replay.mjs'), str(bundle_path), str(cand), mode, str(out)]
            if mode == 'repaired':
                replay = [str(evaluated/'tools/tc0/sandbox.mjs'), '--read', str(evaluated/'tools/tc0'), str(cand), str(bundle_path), '--write', str(out), '--', *replay]
            r, secs = run([node, *replay], evaluated)
            record(f'{mode}-replay', r.returncode == 0, seconds=secs, boundary='sandbox' if mode == 'repaired' else 'trusted defective original',
                   stdout=r.stdout[-2000:], stderr=r.stderr[-2000:])
        # 5. Fresh hand cases through the workspace's own checker (verified identical).
        r, secs = run([sys.executable, '-I', str(workspace/'tools/check-tc0-pure-call.py'), '--shen-executable', shen, '--sandbox',
                       '--output', str(workspace/'build/s3-eval/hand.json')], workspace)
        record('hand-case-agreement', r.returncode == 0, seconds=secs, boundary='sandbox', stdout=r.stdout[-2000:], stderr=r.stderr[-2000:])
        # 6. Workspace regression suite.
        tests = sorted(str(p.relative_to(workspace)) for p in (workspace/'tests/tc0').glob('*.test.mjs'))
        r, secs = run(['unshare', '-n', '--', node, '--test', *tests], workspace, env={'PATH': '/usr/bin:/bin'})
        record('regressions', r.returncode == 0, seconds=secs, boundary='network namespace and empty environment only', tests=tests, tail=r.stdout[-1500:])
        # 7. Held-out generated families.
        spec = importlib.util.spec_from_file_location('s3_pc', evaluated/'tools/check-tc0-pure-call.py')
        pc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(pc)
        pc.SANDBOX = True
        oracle = pc.Oracle(shen=shen)
        for family, count in (('pure-call', 32), ('pure-data', 24)):
            r, _ = run([node, str(evaluated/'tools/tc0/pure-call-campaign-bridge.mjs'), 'generate', str(count), family], evaluated)
            cases = [{k: v for k, v in c.items() if k in ('name', 'program', 'expected_outcome', 'expected_emissions')} for c in json.loads(r.stdout)['cases']]
            started, failures = time.monotonic(), []
            outs, errs = oracle.run([pc.initial_state(c['program']) for c in cases])
            work = scratch/f'{family}-inputs'
            work.mkdir()
            for c, out in zip(cases, outs):
                try:
                    pc.observe(c, oracle, Path(node), work, (out, errs))
                except Exception as e:  # each disagreement is retained by name
                    failures.append({'name': c['name'], 'error': str(e)[-300:]})
            record(f'held-out-generated-{family}', not failures, boundary='sandbox', cases=str(len(cases)), failures=failures[:10],
                   seconds=round(time.monotonic()-started, 2))
        # 7. Held-out exhaustive-small scope; 8. mutation control on the defective original.
        for name, where, bound, want_clean in (('held-out-exhaustive-5', evaluated, 5, True), ('mutation-control-defective-4', control, 4, False)):
            out = where/'build'/f'exhaustive-{bound}.json'
            r, secs = run([sys.executable, '-I', str(where/'tools/check-tc0-pure-data-exhaustive.py'), '--shen-executable', shen,
                           '--max-nodes', str(bound), '--output', str(out), *(['--sandbox'] if want_clean else [])], where)
            summary = json.loads(r.stdout.splitlines()[-1]) if r.stdout.strip() else {}
            disagreements = summary.get('disagreements')
            ok = (r.returncode == 0 and disagreements == 0) if want_clean else (r.returncode == 1 and isinstance(disagreements, int) and disagreements > 0)
            record(name, ok, seconds=secs, boundary='sandbox' if want_clean else 'trusted defective original', programs=summary.get('programs'), disagreements=disagreements, stderr=r.stderr[-1000:])
    required = ['protected-inputs', 'candidate-changed', 'original-replay', 'repaired-replay', 'hand-case-agreement', 'regressions',
                'held-out-generated-pure-call', 'held-out-generated-pure-data', 'held-out-exhaustive-5', 'mutation-control-defective-4']
    verdict = 'DEVELOPMENT-PASS' if [s['step'] for s in steps] == required and all(s['status'] == 'PASS' for s in steps) else 'FAIL'
    report = {'schema': 'tc0-s3-repair-evaluation/1', 'qualification': 'UNKNOWN', 'verdict': verdict,
              'independent_repair': 'UNKNOWN: the evaluator cannot establish who authored the patch',
              'start_revision': manifest['start_revision'], 'evaluator_sha256': sha(__file__),
              'packet': {'bundle_sha256': sha(bundle_path), 'defective_sha256': sha(defective), 'manifest_sha256': sha(packet/'workspace-manifest.json')},
              'oracle': shen, 'steps': steps}
    with dest.open('x') as f:
        f.write(json.dumps(report, indent=1)+'\n')
    print(json.dumps({'qualification': 'UNKNOWN', 'verdict': verdict, 'steps': {s['step']: s['status'] for s in steps}, 'report': str(dest)}))
    sys.exit(0 if verdict == 'DEVELOPMENT-PASS' else 1)


if __name__ == '__main__':
    main()
