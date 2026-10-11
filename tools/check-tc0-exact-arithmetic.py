#!/usr/bin/env python3
"""G0 exact-arithmetic ledger for the pure-call machine; development tier, NOT qualification.

Core section 17 asks for a demonstration that a Shen port carries exact I64 values,
intermediates and unsigned IDs, against independently established integer results,
before it is relied on. This runs, through the full pure-call machine:

  * every binary operation add/sub/mul/div/lt/le/gt/ge over the boundary product
    V x V and neg over V, where V covers the I64 extremes, values around 2^53, the
    square-root-of-2^63 boundary for multiplication, and small signed values;
  * ID cases whose function, node and binding IDs exceed 2^53 and 2^64, including a
    closure whose two captures must be ordered numerically, not by float value.

Expected outcomes come from Python's exact integers, never from a port or the
candidate. Each Shen port named on the command line (host shen-scheme and/or a
Yggdrasil-shaken artifact) is checked separately; the candidate's trace must equal
each port's trace. One ledger row per port.
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
MIN, MAX = -(1 << 63), (1 << 63)-1
V = [MIN, MIN+1, -(1 << 53)-1, -(1 << 53), -3037000500, -3, -2, -1, 0, 1, 2, 3,
     3037000499, 3037000500, 1 << 53, (1 << 53)+1, 1 << 62, MAX-1, MAX]
BINARY = ['add', 'sub', 'mul', 'div', 'lt', 'le', 'gt', 'ge']


def expected(op, a, b=None):
    """Independent exact result as a pure-call outcome."""
    if op in ('lt', 'le', 'gt', 'ge'):
        return ['Ok', ['bool', {'lt': a < b, 'le': a <= b, 'gt': a > b, 'ge': a >= b}[op]]]
    if op == 'div' and b == 0:
        return ['Trap', 'DivZero']
    if op == 'div':
        q = abs(a)//abs(b)
        n = q if (a < 0) == (b < 0) else -q
    else:
        n = {'add': lambda: a+b, 'sub': lambda: a-b, 'mul': lambda: a*b, 'neg': lambda: -a}[op]()
    return ['Ok', ['int', str(n)]] if MIN <= n <= MAX else ['Trap', 'Overflow']


def program(name, result, body, ids=('0', '1')):
    nodes = []
    def collect(e):
        if isinstance(e, list) and len(e) > 1 and isinstance(e[0], str) and e[0] in ('int', 'prim', 'let', 'var', 'lambda', 'apply'):
            nodes.append(e[1])
            for x in e[2:]:
                collect(x)
    collect(body)
    return {'contract_version': '0.2', 'schema_version': 'tc0-a-pure-call-demo/2', 'slice': 'TC0-A', 'module': name,
            'datatypes': [], 'effects': [], 'functions': [{'id': ids[0], 'name': 'main', 'parameter_id': ids[1], 'argument_type': 'I64',
            'result_type': result, 'effects': [], 'body': body}], 'entry': 'main', 'input_schema': {'type': 'I64'},
            'source_map': [{'id': i, 'file': 'ledger', 'line': '0', 'column': '0'} for i in [ids[0], *nodes]]}


def cases():
    rows = []
    for op in BINARY:
        for a in V:
            for b in V:
                rows.append({'name': f'{op}-{len(rows)}', 'program': program('ledger', 'Bool' if op in ('lt', 'le', 'gt', 'ge') else 'I64',
                             ['prim', '2', op, ['int', '3', str(a)], ['int', '4', str(b)]]), 'expected_outcome': expected(op, a, b), 'args': [str(a), str(b)]})
    for a in V:
        rows.append({'name': f'neg-{len(rows)}', 'program': program('ledger', 'I64', ['prim', '2', 'neg', ['int', '3', str(a)]]),
                     'expected_outcome': expected('neg', a), 'args': [str(a)]})
    # IDs beyond 2^53 and 2^64. Captures x=...992 and y=...993 must be ordered numerically.
    big = lambda k: str((1 << 53)+k)
    huge = lambda k: str((1 << 64)+k)
    x, y, f, q = big(0), big(1), huge(5), huge(7)
    body = ['let', huge(1), y, ['int', huge(2), '20'], ['let', huge(3), x, ['int', huge(4), '22'],
            ['let', big(9), f, ['lambda', big(8), q, 'I64', 'I64', [], [], ['prim', big(7), 'add', ['var', big(6), x], ['var', big(5), y]]],
             ['apply', big(4), ['var', big(3), f], ['int', big(2), '0']]]]]
    rows.append({'name': 'ids-beyond-2-53-and-2-64', 'program': program('ledger-ids', 'I64', body, ids=(str(10**30), str(10**30+1))),
                 'expected_outcome': ['Ok', ['int', '42']], 'args': [], 'expected_capture_order': [x, y]})
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shen-executable')
    parser.add_argument('--oracle-artifact')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    ports = [('host-shen', pc.Oracle(shen=args.shen_executable))] if args.shen_executable else []
    ports += [('yggdrasil-shaken', pc.Oracle(artifact=args.oracle_artifact))] if args.oracle_artifact else []
    if not ports:
        raise ValueError('Name at least one Shen port')
    dest = Path(args.output).resolve()
    if not dest.is_relative_to(ROOT/'build') or dest.suffix != '.json' or dest.exists():
        raise ValueError('Fresh output JSON below build required')
    node = Path(shutil.which('node')).resolve(strict=True)
    paths = [Path(__file__), ROOT/'tools/check-tc0-pure-call.py', ROOT/'tools/check-tc0-expression.py', ROOT/'tools/tc0/run-pure-call-batch.mjs',
             ROOT/'tools/tc0/pure-call-artifact.mjs', ROOT/'tools/tc0/canonical.mjs', *pc.MODEL_FILES, ROOT/'runtime/tc0/pure-call-machine.mjs',
             *[p for _, o in ports for p in o.identity_paths()], node]
    before = {str(p): probe.digest(p) for p in paths}
    rows = cases()
    batch_in, batch_out = dest.with_suffix('.programs.json'), dest.with_suffix('.candidate.jsonl')
    batch_in.write_text(json.dumps([r['program'] for r in rows]))
    probe.synchronous([str(node), str(ROOT/'tools/tc0/run-pure-call-batch.mjs'), str(batch_in), str(batch_out)], timeout=300)
    candidate = [json.loads(l) for l in batch_out.read_text().splitlines()]
    ledger = []
    for label, oracle in ports:
        started = time.monotonic()
        outs, _ = oracle.run([pc.initial_state(r['program']) for r in rows], timeout=1)
        failures = []
        for r, out, cand in zip(rows, outs, candidate):
            lines = out.splitlines()
            if not lines or lines[-1].strip() != 'terminal':
                failures.append({'name': r['name'], 'reason': 'model incomplete'})
                continue
            steps = [pc.normalize(probe.parse_list(l), i) for i, l in enumerate(x for x in lines if x.startswith('[sample '))]
            outcome = steps[-1]['events'][0]['outcome']
            descriptors = [pc.model_value(probe.parse_list(l)) for l in lines if l.startswith('[closure ')]
            ok = outcome == r['expected_outcome'] and cand['outcome'] == outcome and cand['steps'] == steps
            if 'expected_capture_order' in r:
                ok = ok and [k for k, _ in descriptors[0]['captures']] == r['expected_capture_order']
            if not ok:
                failures.append({'name': r['name'], 'args': r['args'], 'expected': r['expected_outcome'], 'model': outcome,
                                 'candidate': cand['outcome'], 'traces_equal': cand['steps'] == steps})
        ledger.append({'port': label, 'oracle': oracle.describe(), 'cases': str(len(rows)), 'exact': str(len(rows)-len(failures)),
                       'failures': failures[:20], 'failure_count': str(len(failures)), 'seconds': round(time.monotonic()-started, 2)})
    if before != {str(p): probe.digest(p) for p in paths}:
        raise RuntimeError('Source/toolchain drift')
    outcomes = {}
    for r in rows:
        k = r['expected_outcome'][0] if r['expected_outcome'][0] == 'Ok' else 'Trap '+r['expected_outcome'][1]
        outcomes[k] = outcomes.get(k, 0)+1
    report = {'schema': 'tc0-exact-arithmetic-ledger/1', 'qualification': 'UNKNOWN', 'sources': before,
              'scope': 'Boundary product V x V for add/sub/mul/div/lt/le/gt/ge, neg over V, and IDs beyond 2^53/2^64, through the full pure-call machine',
              'values': [str(v) for v in V], 'expected_outcomes': outcomes, 'ledger': ledger,
              'limitations': ['Finite boundary vectors, not all I64 pairs', 'Agreement between ports supports portability, not semantic truth']}
    with dest.open('x') as fh:
        fh.write(json.dumps(report, indent=1)+'\n')
    print(json.dumps({'qualification': 'UNKNOWN', 'cases': len(rows), 'expected_outcomes': outcomes,
                      'ledger': [{k: v for k, v in l.items() if k in ('port', 'exact', 'failure_count', 'seconds')} for l in ledger]}))
    sys.exit(1 if any(l['failures'] for l in ledger) else 0)


if __name__ == '__main__':
    main()
