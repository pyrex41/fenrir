#!/usr/bin/env python3
"""Development arithmetic probe, NOT a TC0-A qualification evaluator."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OPS = {'add': 2, 'sub': 2, 'mul': 2, 'div': 2, 'neg': 1}
MINIMUM, MAXIMUM = -(1 << 63), (1 << 63) - 1


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def independently_expected(op, args):
    a = args[0]
    if op == 'div' and args[1] == 0:
        return {'status': 'Trap', 'code': 'DivZero'}
    if op == 'add':
        result = a + args[1]
    elif op == 'sub':
        result = a - args[1]
    elif op == 'mul':
        result = a * args[1]
    elif op == 'neg':
        result = -a
    else:
        b = args[1]
        result = abs(a) // abs(b)
        if (a < 0) != (b < 0):
            result = -result
    if not MINIMUM <= result <= MAXIMUM:
        return {'status': 'Trap', 'code': 'Overflow'}
    return {'status': 'Ok', 'value': str(result)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shen-executable', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    executable = Path(args.shen_executable).resolve(strict=True)
    fixture_path = ROOT / 'fixtures/tc0/arithmetic-boundaries.json'
    model = ROOT / 'models/tc0/arithmetic.shen'
    candidate = ROOT / 'runtime/tc0/arithmetic-candidate.mjs'
    fixtures = json.loads(fixture_path.read_text())
    expressions = []
    for case in fixtures:
        op, values = case['op'], case['args']
        if op not in OPS or len(values) != OPS[op]:
            raise ValueError('Invalid operation or arity')
        if any(not re.fullmatch(r'(0|-[1-9][0-9]*|[1-9][0-9]*)', value) for value in values):
            raise ValueError('Invalid decimal input')
        numbers = list(map(int, values))
        if any(not MINIMUM <= value <= MAXIMUM for value in numbers):
            raise ValueError('Input outside I64')
        if independently_expected(op, numbers) != case['expected']:
            raise ValueError('Hand fixture disagrees with independent exact integer arithmetic')
        expressions += ['-e', '(tc0.arithmetic ' + op + ' [' + ' '.join(values) + '])']
    invocation = subprocess.run([str(executable), 'eval', '-l', str(model), *expressions],
                                capture_output=True, text=True, timeout=30)
    if invocation.returncode:
        raise RuntimeError('Shen launch/load failed: ' + invocation.stderr[-2000:])
    raw_results = re.findall(r'^\[(ok|trap) ([a-z0-9-]+)\]$', invocation.stdout, re.MULTILINE)
    if len(raw_results) != len(fixtures):
        raise RuntimeError('Invalid Shen result count/framing: ' + invocation.stdout[-2000:])
    rows, mutant_failures = [], []
    node = shutil.which('node')
    if not node:
        raise RuntimeError('Node candidate toolchain unavailable')
    for case, (tag, value) in zip(fixtures, raw_results):
        reference = {'status': 'Ok', 'value': value} if tag == 'ok' else {
            'status': 'Trap', 'code': {'overflow': 'Overflow', 'div-zero': 'DivZero'}[value]}
        command = [node, str(candidate), case['op'], *case['args']]
        normal = subprocess.run(command, capture_output=True, text=True, timeout=5)
        faulty = subprocess.run([*command, '--mutant=rounded-add'], capture_output=True, text=True, timeout=5)
        if normal.returncode or faulty.returncode:
            raise RuntimeError('Candidate crashed/invalid input; not a semantic mutant kill')
        actual, mutated = json.loads(normal.stdout), json.loads(faulty.stdout)
        matches = reference == actual == case['expected']
        rows.append({'id': case['id'], 'expected': case['expected'], 'reference': reference,
                     'candidate': actual, 'matches': matches})
        if mutated != reference:
            mutant_failures.append({'id': case['id'], 'args': case['args'], 'op': case['op'],
                                    'reference': reference, 'mutated': mutated})
    report = {
        'scope': 'Development I64 arithmetic component only; no TC0-A qualification',
        'qualification': 'UNKNOWN',
        'sources': {str(path.relative_to(ROOT)): digest(path) for path in [model, candidate, fixture_path, Path(__file__)]},
        'shen_executable': {'path': str(executable), 'sha256': digest(executable)},
        'shen_boot': {'path': str(executable.parent.parent / 'lib/shen-scheme/shen.boot'),
                      'sha256': digest(executable.parent.parent / 'lib/shen-scheme/shen.boot')},
        'cases': rows, 'rounded_add_mutant_discrepancies': mutant_failures,
        'gaps': ['G0 isolation/baseline not qualified', 'No full AST/frame machine, closures or hand-derived step trace',
                 'No reduction or exact semantic tape replay', 'No approved TC0-A evaluator'],
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'component_cases': str(len(rows)), 'all_match': all(row['matches'] for row in rows),
                      'mutant_discrepancies': str(len(mutant_failures)), 'qualification': 'UNKNOWN', 'report': str(output)}))
    return 0 if all(row['matches'] for row in rows) and mutant_failures else 1


if __name__ == '__main__':
    raise SystemExit(main())
