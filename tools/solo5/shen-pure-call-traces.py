#!/usr/bin/env python3
"""Transport only: run the Shen pure-call model over a JSON array of programs
and write one normalized trace per line. Reuses the existing oracle wrapper and
normalization in tools/check-tc0-pure-call.py unchanged; no transition logic
and no comparison happens here. Development use; not a qualification tool."""
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pure_call_probe', ROOT/'tools/check-tc0-pure-call.py')
pc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pc)


def main():
    if len(sys.argv) != 4:
        raise SystemExit('Usage: shen-pure-call-traces.py SHEN_EXECUTABLE PROGRAMS.json OUTPUT.jsonl')
    shen, source, dest = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]).resolve()
    if not dest.is_relative_to(ROOT/'build') or dest.suffix != '.jsonl' or dest.exists():
        raise ValueError('Fresh output .jsonl below build required')
    programs = json.loads(source.read_text())
    outs, _ = pc.Oracle(shen=shen).run([pc.initial_state(p) for p in programs], timeout=1)
    with dest.open('x') as out:
        for text in outs:
            lines = text.splitlines()
            completed = bool(lines) and lines[-1].strip() == 'terminal'
            steps = [pc.normalize(pc.probe.parse_list(l), i)
                     for i, l in enumerate(x for x in lines if x.startswith('[sample '))]
            out.write(json.dumps({'execution': 'Completed' if completed else 'BudgetExhausted', 'steps': steps})+'\n')
    print(json.dumps({'programs': str(len(programs)), 'output': str(dest)}))


if __name__ == '__main__':
    main()
