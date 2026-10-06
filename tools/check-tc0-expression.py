#!/usr/bin/env python3
"""Source-bound trusted LOCAL development probe; NOT TC0-A qualification/isolation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def synchronous(argv, timeout=30):
    # Join owned process group even on timeout; never run background candidate work.
    process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True, cwd=ROOT)
    try:
        out, err = process.communicate(timeout=timeout)
        if process.returncode:
            raise RuntimeError(f'Process exit {process.returncode}: {err[-2000:]}')
        return out, err
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def shen_expr(e):
    tag, node, *args = e
    if tag in ('int', 'var'):
        rest = args[0]
    elif tag == 'bool':
        rest = 'true' if args[0] else 'false'
    elif tag == 'unit':
        rest = ''
    elif tag == 'let':
        rest = args[0] + ' ' + shen_expr(args[1]) + ' ' + shen_expr(args[2])
    elif tag == 'if':
        rest = ' '.join(map(shen_expr, args))
    elif tag == 'emit':
        # This probe is only for the hand fixture's simple literal ASCII label.
        if not re.fullmatch('[A-Za-z_][A-Za-z0-9_]*', args[0]):
            raise ValueError('Label outside demonstrated Shen transport scope')
        rest = json.dumps(args[0]) + ' ' + shen_expr(args[1])
    elif tag == 'prim':
        if args[0] not in {'add','sub','mul','div','neg','lt','le','gt','ge','not'}:
            raise ValueError('Unsupported primitive')
        rest = args[0] + ' ' + ' '.join(map(shen_expr, args[1:]))
    else:
        raise ValueError('Unsupported expression')
    if not re.fullmatch('0|[1-9][0-9]*', node):
        raise ValueError('Invalid ID')
    return '[' + tag + ' ' + node + (' ' + rest if rest else '') + ']'


def parse_list(line):
    tokens = re.findall(r'"(?:[^"\\]|\\.)*"|\[|\]|[^\s\[\]]+', line)
    index = 0
    def parse(depth=0):
        nonlocal index
        if depth > 128 or index >= len(tokens):
            raise ValueError('Invalid Shen list framing')
        token = tokens[index]; index += 1
        if token == '[':
            values = []
            while index < len(tokens) and tokens[index] != ']':
                values.append(parse(depth+1))
            if index >= len(tokens):
                raise ValueError('Unclosed Shen list')
            index += 1
            return values
        if token == ']':
            raise ValueError('Unexpected closing bracket')
        return json.loads(token) if token.startswith('"') else token
    value = parse()
    if index != len(tokens):
        raise ValueError('Extra Shen output')
    return value


def value(v):
    if v == ['unit']:
        return v
    if v[0] == 'int' and len(v) == 2:
        return v
    if v[0] == 'bool' and len(v) == 2 and v[1] in ('true','false'):
        return ['bool', v[1] == 'true']
    raise ValueError('Unexpected model value')


def outcome(o):
    if o[0] == 'ok':
        return ['Ok', value(o[1])]
    return ['Trap', {'div-zero':'DivZero', 'overflow':'Overflow'}[o[1]]]


def event(e):
    if e[0] in ('scope-exit', 'task-termination'):
        row = {'kind': {'scope-exit':'ScopeExit','task-termination':'TaskTermination'}[e[0]],
               'task':'0', 'outcome':outcome(e[1])}
        if e[0] == 'scope-exit': row['scope'] = '0'
        return row
    if e[0] in ('invoke','emit'):
        row = {'kind': 'Invoke' if e[0] == 'invoke' else 'Emit', 'task':'0',
               'node':e[1], 'label':e[2], 'value':value(e[3])}
        if e[0] == 'invoke': row['operation'] = 'emit'
        return row
    if e[0] == 'commit':
        return {'kind':'Commit','task':'0','node':e[1],'operation':'emit','value':value(e[2])}
    raise ValueError('Unknown model event')


def normalize(sample, epoch):
    tag, site, after, depth, events = sample
    if tag != 'sample': raise ValueError('Expected sample')
    rules = {'dispatch':'Dispatch','ready':'Ready','collect-return':'CollectReturn',
             'let-return':'LetReturn','if-return':'IfReturn','unwind-frame':'UnwindFrame',
             'value':'Value','unwind':'Unwind','join':'Join','terminate':'Terminate'}
    normalized_site = {site[0]: site[1] if site[0] == 'node' else {
        'root-join-entry':'RootJoinEntry','join':'Join','terminate':'Terminate'}[site[1]],
        'rule':rules[site[2]]}
    return {'epoch':str(epoch),'site':normalized_site,'after':{
        'eval':'Eval','value':'Value','ready':'Ready','unwind':'Unwind','join':'Join',
        'terminate':'Terminate','terminal':'Terminal'}[after], 'depth':depth,
        'events':list(map(event, events))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shen-executable', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    executable = Path(args.shen_executable).resolve(strict=True)
    node_path = shutil.which('node')
    if not node_path:
        raise RuntimeError('Node toolchain unavailable')
    node = Path(node_path).resolve(strict=True)
    program = ROOT/'fixtures/tc0/left-trap-program.json'
    golden = ROOT/'fixtures/tc0/left-trap-trace.json'
    model = ROOT/'models/tc0/expression-machine.shen'
    arithmetic = ROOT/'models/tc0/arithmetic.shen'
    peer = ROOT/'tools/tc0/run-expression.mjs'
    sources = [program,golden,model,arithmetic,peer,Path(__file__),ROOT/'tools/tc0/artifact.mjs',
               ROOT/'tools/tc0/canonical.mjs',ROOT/'runtime/tc0/expression-machine.mjs']
    before = {str(p.relative_to(ROOT)):digest(p) for p in sources}
    # Validate the artifact through the host adapter BEFORE model translation/execution.
    stdout, _ = synchronous([str(node),str(peer),str(program)])
    candidate = json.loads(stdout)
    artifact = json.loads(program.read_text())
    hand = json.loads(golden.read_text())
    fn = artifact['functions'][0]
    initial = '[state [eval ' + shen_expr(fn['body']) + '] [[' + fn['parameter_id'] + ' [unit]]] []]'
    count = len(hand['steps'])
    command = [str(executable),'eval','-l',str(arithmetic),'-l',str(model),'-e',
               '(set tc0.demo.state ' + initial + ')']
    for _ in range(count):
        command += ['-e','(tc0.demo.sample (value tc0.demo.state))', '-e',
                    '(set tc0.demo.state (hd (tl (tc0.demo.step (value tc0.demo.state)))))']
    model_out, model_err = synchronous(command)
    samples = [parse_list(line) for line in model_out.splitlines() if line.startswith('[sample ')]
    if len(samples) != count: raise ValueError('Wrong model sample count')
    model_steps = [normalize(s,i) for i,s in enumerate(samples)]
    mutant_out, _ = synchronous([str(node),str(peer),str(program),'--reverse-operands'])
    mutant = json.loads(mutant_out)
    first = next((str(i) for i,(a,b) in enumerate(zip(model_steps,mutant['steps'])) if a != b), None)
    after = {str(p.relative_to(ROOT)):digest(p) for p in sources}
    if before != after: raise RuntimeError('Source drift during development check')
    report = {'scope':'Unqualified arithmetic-demo hand fixture only; trusted local development',
              'qualification':'UNKNOWN','sources':before,
              'shen_executable_sha256':digest(executable),
              'shen_boot_sha256':digest(executable.parent.parent/'lib/shen-scheme/shen.boot'),
              'node_executable_sha256':digest(node), 'model_steps':model_steps,
              'model_matches_hand':model_steps == hand['steps'],
              'candidate_matches_hand':candidate['steps'] == hand['steps'],
              'candidate_outcome_matches_hand':candidate['outcome'] == hand['expected_outcome'],
              'mutant_first_step_divergence':first,
              'mutant_emissions':[e for e in mutant['events'] if e['kind'] == 'Emit'],
              'limitations':['Not full TC0-A; no calls/closures or other constructors',
                             'Catalog/event/field shapes unreviewed', 'No strict tape replay or reduction',
                             'No qualified OS isolation or evaluator registration']}
    destination = Path(args.output)
    if not destination.resolve().is_relative_to(ROOT/'build') or destination.suffix != '.json':
        raise ValueError('Development output must be a .json file below build/')
    if destination.resolve() in [p.resolve() for p in sources]: raise ValueError('Output overwrites source')
    destination.parent.mkdir(parents=True,exist_ok=True)
    destination.write_text(json.dumps(report,indent=2)+'\n')
    destination.with_suffix('.shen.stdout').write_text(model_out)
    destination.with_suffix('.shen.stderr').write_text(model_err)
    matched = report['model_matches_hand'] and report['candidate_matches_hand'] and report['candidate_outcome_matches_hand']
    print(json.dumps({'development_agreement':matched,'mutant_first_divergence':first,
                      'qualification':'UNKNOWN','report':str(destination)}))
    return 0 if matched and first == '1' and len(report['mutant_emissions']) == 1 else 1


if __name__ == '__main__':
    raise SystemExit(main())
