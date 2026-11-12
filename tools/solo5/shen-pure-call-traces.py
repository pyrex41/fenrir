#!/usr/bin/env python3
"""Transport only: run a Shen pure-call model over a JSON array of programs and
write one normalized trace per line. No transition logic and no comparison
happens here. Development use; not a qualification tool.

Default: the registered model through the existing oracle wrapper in
tools/check-tc0-pure-call.py, unchanged.

--portable: the proposed width-independent model (models/tc0/portable), for
Shen ports whose integers are narrower than I64 such as Shen/JIT. I64 literals
and IDs are sent as Shen strings; the output has the same shape, so the
existing normalization is reused unchanged."""
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pure_call_probe', ROOT/'tools/check-tc0-pure-call.py')
pc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pc)


def ident(s):
    if not isinstance(s, str) or not re.fullmatch('0|[1-9][0-9]*', s):
        raise ValueError('Invalid ID')
    return '"'+s+'"'


def integer(s):
    if not isinstance(s, str) or not re.fullmatch('0|-?[1-9][0-9]*', s):
        raise ValueError('Invalid integer literal')
    return '"'+s+'"'


def label(s):
    if not isinstance(s, str) or not re.fullmatch('[A-Za-z_][A-Za-z0-9_]*', s):
        raise ValueError('Label outside demonstrated Shen string scope')
    return json.dumps(s)


def translate(e, codes):
    """Same shapes as pc.translate, with IDs and I64 literals as strings."""
    tag, node, *x = e
    sub = lambda c: translate(c, codes)
    if tag == 'unit':
        rest = ''
    elif tag == 'bool':
        rest = 'true' if x[0] else 'false'
    elif tag == 'int':
        rest = integer(x[0])
    elif tag == 'var':
        rest = ident(x[0])
    elif tag == 'bytes':
        rest = pc.octets(x[0])
    elif tag in ('tuple', 'apply', 'if'):
        rest = ' '.join(map(sub, x))
    elif tag == 'project':
        rest = sub(x[0])+' '+str(int(x[1]))
    elif tag == 'construct':
        rest = ' '.join([pc.name(x[0]), pc.name(x[1])]+[sub(c) for c in x[2:]])
    elif tag == 'match':
        rest = sub(x[0])+' ['+' '.join('['+pc.name(c)+' ['+' '.join(map(ident, b))+'] '+sub(body)+']' for c, b, body in x[1:])+']'
    elif tag == 'lambda':
        body = sub(x[5])
        codes.append('['+ident(node)+' ['+ident(x[0])+' '+body+']]')
        rest = ident(x[0])+' '+body
    elif tag == 'call':
        rest = pc.atom(x[0])+' '+sub(x[1])
    elif tag == 'let':
        rest = ident(x[0])+' '+sub(x[1])+' '+sub(x[2])
    elif tag == 'prim':
        if not re.fullmatch('[a-z_]+', x[0]):
            raise ValueError('Unsupported primitive')
        rest = x[0]+' '+' '.join(map(sub, x[1:]))
    elif tag == 'emit':
        rest = label(x[0])+' '+sub(x[1])
    else:
        raise ValueError('Unsupported expression')
    return '['+tag+' '+ident(node)+(' '+rest if rest else '')+']'


def initial_state(a, input_value=('int', '0')):
    codes = []
    for f in a['functions']:
        body = translate(f['body'], codes)
        codes.append('['+ident(f['id'])+' ['+ident(f['parameter_id'])+' '+body+']]')
    names = '['+' '.join('['+pc.atom(f['name'])+' '+ident(f['id'])+']' for f in a['functions'])+']'
    entry = next(f for f in a['functions'] if f['name'] == a['entry'])
    if input_value[0] != 'int':
        raise ValueError('Only int entry inputs are transported')
    return ('[pure-call-state [evaluate '+translate(entry['body'], [])+' true] [['+ident(entry['parameter_id'])
            + ' [int '+integer(input_value[1])+']]] [] ['+' '.join(codes)+'] '+names+']')


def run_portable(shen, programs):
    driver = ROOT/'models/tc0/portable/pure-call-oracle.shen'
    stdin = ''.join(f'{pc.REFERENCE_STEPS} {initial_state(p)}\n' for p in programs)+'end\n'
    out, _ = pc.probe.synchronous([str(Path(shen).resolve(strict=True)), 'script', str(driver)],
                                  timeout=max(60, len(programs)), stdin=stdin, cwd=ROOT/'models/tc0')
    chunks = out.split('[case-end]\n')
    if len(chunks) != len(programs)+1:
        raise RuntimeError('Oracle returned '+str(len(chunks)-1)+' cases for '+str(len(programs)))
    return chunks[:-1]


def main():
    args = sys.argv[1:]
    portable = '--portable' in args
    args = [a for a in args if a != '--portable']
    if len(args) != 3:
        raise SystemExit('Usage: shen-pure-call-traces.py [--portable] SHEN_EXECUTABLE PROGRAMS.json OUTPUT.jsonl')
    shen, source, dest = args[0], Path(args[1]), Path(args[2]).resolve()
    if not dest.is_relative_to(ROOT/'build') or dest.suffix != '.jsonl' or dest.exists():
        raise ValueError('Fresh output .jsonl below build required')
    programs = json.loads(source.read_text())
    if portable:
        outs = run_portable(shen, programs)
    else:
        outs, _ = pc.Oracle(shen=shen).run([pc.initial_state(p) for p in programs], timeout=1)
    with dest.open('x') as out:
        for text in outs:
            lines = text.splitlines()
            completed = bool(lines) and lines[-1].strip() == 'terminal'
            steps = [pc.normalize(pc.probe.parse_list(l), i)
                     for i, l in enumerate(x for x in lines if x.startswith('[sample '))]
            out.write(json.dumps({'execution': 'Completed' if completed else 'BudgetExhausted', 'steps': steps})+'\n')
    print(json.dumps({'programs': str(len(programs)), 'model': 'portable' if portable else 'registered', 'output': str(dest)}))


if __name__ == '__main__':
    main()
