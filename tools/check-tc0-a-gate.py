#!/usr/bin/env python3
"""Owner-reviewed, registered TC0-A gate evaluator (02 §14 TC0-GATE).

Runs trusted-local under the G1 scope and waivers recorded in
campaigns/tc0/G1_EVALUATOR_REVIEW.md; registration does not establish isolation.

Runs every row of spec/tc0/tc0-a-requirements.json freshly against the current
committed source, into a new run directory under build/tc0/gate/, and aggregates:
any required FAIL -> FAIL; else any BLOCKED -> BLOCKED; else any UNKNOWN -> UNKNOWN;
else PASS. All row reasons are reported whatever the aggregate.

The manifest also maps the workflow controller's six required claims to rows: a
claim is credited only when every row it names, and every claim prerequisite, PASS.

Authority: the verdict is a qualification verdict only when the manifest is
owner-reviewed AND .pi/fenrir-workflow.json registers this script as
`tc0-a-qualification`; otherwise `qualification` stays UNKNOWN. Waivers (such as
accepted instruction-only repairer isolation) are listed in every report.

Under the workflow controller (FENRIR_CHECK_NONCE set) stdout carries exactly one
fenrir.check.v1 report; logs go to stderr. Exit: PASS 0, FAIL 1, UNKNOWN/BLOCKED 2.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
PY = [sys.executable, '-I']


class Row:
    def __init__(self, status, reasons=(), **detail):
        self.status, self.reasons, self.detail = status, list(reasons), detail


def run(argv, timeout=900, cwd=ROOT):
    started = time.monotonic()
    try:
        r = subprocess.run([str(a) for a in argv], cwd=cwd, capture_output=True, text=True, timeout=timeout, start_new_session=True)
    except subprocess.TimeoutExpired:
        return None, '', 'evaluator watchdog', round(time.monotonic()-started, 2)
    return r.returncode, r.stdout, r.stderr, round(time.monotonic()-started, 2)


def last_json(text):
    for line in reversed(text.strip().splitlines()):
        try:
            return json.loads(line)
        except ValueError:
            continue
    return None


class Gate:
    def __init__(self, out, shen):
        self.out, self.shen, self.node = out, shen, shutil.which('node')
        self.memo, self.waivers = {}, []

    def need_shen(self):
        return None if self.shen and Path(self.shen).exists() else Row('BLOCKED', ['No Shen executable at build/toolchain/shen-scheme'])

    def source_identity(self):
        dirty = subprocess.run(['git', 'status', '--porcelain'], cwd=ROOT, capture_output=True, text=True).stdout.strip()
        head = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True, text=True).stdout.strip()
        self.head = head
        if dirty:
            return Row('UNKNOWN', ['Worktree has uncommitted changes; evidence would not be source-bound'], head=head)
        return Row('PASS', head=head)

    def toolchain_pinned(self):
        if not shutil.which('nix'):
            return Row('BLOCKED', ['nix unavailable; cannot resolve the pinned toolchain'])
        code, out, err, secs = run(['nix', 'build', '--no-link', '--print-out-paths', '.#shen-scheme'], timeout=1800)
        if code != 0:
            return Row('BLOCKED', ['nix build .#shen-scheme failed: '+err[-300:]])
        pinned = out.strip().splitlines()[-1]+'/bin/shen-scheme'
        actual = os.path.realpath(ROOT/'build/toolchain/shen-scheme')
        if actual != pinned:
            return Row('UNKNOWN', [f'build/toolchain/shen-scheme is {actual}, not the pinned {pinned}'])
        return Row('PASS', shen=pinned, seconds=secs)

    def unit_suite(self):
        tests = sorted(str(p.relative_to(ROOT)) for p in (ROOT/'tests/tc0').glob('*.test.mjs'))
        code, out, err, secs = run([self.node, '--test', *tests])
        fails = int((re.search(r'^# fail (\d+)', out, re.M) or [0, '1'])[1])
        skips = int((re.search(r'^# skipped (\d+)', out, re.M) or [0, '0'])[1])
        if fails or code not in (0, None) and not fails:
            return Row('FAIL', [f'{fails} failing tests' if fails else f'test runner exit {code}'], seconds=secs)
        if code is None:
            return Row('UNKNOWN', ['Test runner timed out'])
        if skips:
            return Row('UNKNOWN', [f'{skips} skipped tests are missing evidence'], seconds=secs)
        return Row('PASS', tests=str(len(tests)), passed=(re.search(r'^# pass (\d+)', out, re.M) or [0, '?'])[1], seconds=secs)

    def hand_agreement_and_replay(self):
        if (b := self.need_shen()):
            return b
        hand = self.out/'hand.json'
        code, out, err, secs = run([*PY, ROOT/'tools/check-tc0-pure-call.py', '--shen-executable', self.shen, '--sandbox', '--output', hand])
        if code != 0:
            disagreement = 'disagreement' in err or 'mismatch' in err
            return Row('FAIL' if disagreement else 'UNKNOWN', [err.strip().splitlines()[-1] if err.strip() else f'exit {code}'])
        self.memo['hand'] = hand
        code, out2, err2, secs2 = run([self.node, ROOT/'tools/tc0/check-pure-call-replay.mjs', hand, self.out/'hand-replay.json'])
        if code != 0:
            return Row('FAIL' if 'disagreement' in err2 else 'UNKNOWN', [err2.strip().splitlines()[-1] if err2.strip() else f'exit {code}'])
        return Row('PASS', cases=str((last_json(out) or {}).get('independent_case_agreement')), seconds=round(secs+secs2, 2))

    def exact_arithmetic(self, shaken=False):
        if (b := self.need_shen()):
            return b
        oracle = ['--oracle-artifact', ROOT/'build/toolchain/tc0-pure-call-oracle'] if shaken else ['--shen-executable', self.shen]
        code, out, err, secs = run([*PY, ROOT/'tools/check-tc0-exact-arithmetic.py', *oracle, '--output', self.out/('arith-shaken.json' if shaken else 'arith.json')])
        summary = last_json(out)
        if code == 0 and summary:
            return Row('PASS', cases=str(summary['cases']), seconds=secs)
        if code == 1 and summary:
            return Row('FAIL', [f"{l['port']}: {l['failure_count']} inexact" for l in summary['ledger'] if l['failure_count'] != '0'])
        return Row('UNKNOWN', [err.strip().splitlines()[-1] if err.strip() else f'exit {code}'])

    def exact_arithmetic_shaken(self):
        row = self.exact_arithmetic(shaken=True)
        return row if row.status != 'UNKNOWN' else Row('DEFERRED', ['Optional second port unavailable or stale: '+'; '.join(row.reasons)])

    def exhaustive_small(self):
        if (b := self.need_shen()):
            return b
        report = self.out/'exhaustive-5.json'
        code, out, err, secs = run([*PY, ROOT/'tools/check-tc0-pure-data-exhaustive.py', '--shen-executable', self.shen, '--sandbox', '--max-nodes', '5', '--output', report])
        if not report.exists():
            return Row('UNKNOWN', [err.strip().splitlines()[-1] if err.strip() else f'exit {code}'])
        r = json.loads(report.read_text())
        self.memo['exhaustive'] = r
        self.memo['exhaustive_path'] = report
        if r['disagreements']:
            return Row('FAIL', [f"{len(r['disagreements'])} programs disagree with Shen, first {r['disagreements'][0]['name']}"])
        return Row('PASS', programs=r['enumeration']['count'], seconds=secs)

    def mutant(self, name):
        r = self.memo.get('exhaustive')
        if not r:
            return Row('UNKNOWN', ['No exhaustive report in this run'])
        s = r['mutants'][name]
        if s['killed'] > 0:
            return Row('PASS', killed=str(s['killed']), survived=str(s['survived']), crashed=str(s['crashed']))
        return Row('FAIL', [f'Mutant {name} survived every program ({s["crashed"]} crashes are not kills)'])

    def catalog_coverage(self):
        if 'hand' not in self.memo or 'exhaustive_path' not in self.memo:
            return Row('UNKNOWN', ['Needs this run\'s hand and exhaustive reports'])
        code, out, err, secs = run([self.node, ROOT/'tools/tc0/check-pure-call-coverage.mjs', self.memo['hand'], self.memo['exhaustive_path'], self.out/'coverage.json'])
        s = last_json(out)
        if code != 0 or not s:
            return Row('UNKNOWN', [err.strip().splitlines()[-1] if err.strip() else f'exit {code}'])
        if s['unknown_observed']:
            return Row('FAIL', ['Steps outside the catalog: '+', '.join(s['unknown_observed'][:5])])
        if s['missing']:
            return Row('UNKNOWN', [f"{len(s['missing'])} catalog transitions uncovered: "+', '.join(s['missing'][:5])])
        return Row('PASS', covered=f"{s['covered']}/{s['catalog_keys']}")

    def discovery_reduction_replay(self):
        if (b := self.need_shen()):
            return b
        detail, reasons, status = {}, [], 'PASS'
        for mutant in ('arm-by-position', 'reverse-operands'):
            report = self.out/f's2-{mutant}.json'
            code, out, err, secs = run([*PY, ROOT/'tools/check-tc0-pure-call-reduction.py', '--shen-executable', self.shen, '--family', 'pure-data',
                                        '--mutant', mutant, '--max-cases', '24', '--wall-seconds', '300', '--output', report])
            if code != 0:
                reasons.append(f'{mutant}: '+(err.strip().splitlines()[-1] if err.strip() else f'exit {code}'))
                status = 'FAIL' if ('No expected discrepancy discovered' in err or 'disagreement' in err) else ('UNKNOWN' if status == 'PASS' else status)
                continue
            s = last_json(out)
            code, _, err2, _ = run([self.node, ROOT/'tools/tc0/check-pure-call-failure-replay.mjs', report, self.out/f's2-{mutant}-replay.json'])
            if code != 0:
                reasons.append(f'{mutant} replay: '+(err2.strip().splitlines()[-1] if err2.strip() else f'exit {code}'))
                status = 'FAIL'
                continue
            detail[mutant] = {'discovered_index': s['discovered_index'], 'nodes': f"{s['original_metric']['nodes']}->{s['minimized_metric']['nodes']}", 'seconds': secs}
            if mutant == 'arm-by-position':
                self.memo['s2_arm'] = report
        return Row(status, reasons, **detail)

    def candidate_boundary(self):
        code, out, err, secs = run([self.node, ROOT/'tools/tc0/check-sandbox.mjs', self.out/'sandbox.json'])
        if code == 2:
            return Row('BLOCKED', [err.strip()])
        if code == 0:
            return Row('PASS', seconds=secs)
        s = last_json(out)
        return Row('FAIL', [f"probes not enforced: {[r[0] for r in (s or {}).get('rows', []) if not r[1]]}" if s else f'exit {code}'])

    def requirement_ledger(self):
        code, out, err, _ = run([self.node, ROOT/'tools/tc0/check-requirement-ledger.mjs'])
        s = last_json(out)
        return Row('PASS', summary=s['summary']) if code == 0 else Row('FAIL', (s or {}).get('problems', [f'exit {code}']))

    def independent_repair_fresh(self):
        if (b := self.need_shen()):
            return b
        if 's2_arm' not in self.memo:
            return Row('UNKNOWN', ['Needs this run\'s arm-by-position reduction report'])
        s3 = self.out/'s3'
        code, out, err, _ = run([self.node, ROOT/'tools/tc0/s3-prepare.mjs', self.memo['s2_arm'], s3])
        if code != 0:
            return Row('UNKNOWN', ['Packet preparation failed: '+(err.strip().splitlines()[-1] if err.strip() else f'exit {code}')])
        repair = s3/'repair'
        shutil.copytree(s3/'workspace', repair)
        patch = ROOT/'campaigns/tc0/s3/independent-repair-1.patch'
        r = subprocess.run(['patch', '-p1', '--forward', '--batch', '-d', str(repair)], input=patch.read_text(), capture_output=True, text=True)
        if r.returncode != 0:
            return Row('UNKNOWN', ['Retained independent patch no longer applies to this source; repair evidence is stale'])
        for leftover in repair.rglob('*.orig'):
            leftover.unlink()
        code, out, err, secs = run([*PY, ROOT/'tools/check-tc0-s3-repair.py', '--packet', s3/'packet', '--workspace', repair,
                                    '--shen-executable', self.shen, '--output', self.out/'s3-evaluation.json'])
        s = last_json(out)
        if s and s.get('verdict') == 'DEVELOPMENT-PASS':
            return Row('PASS', steps=s['steps'], seconds=secs)
        if s:
            return Row('FAIL', ['S3 evaluator: '+', '.join(k for k, v in s['steps'].items() if v != 'PASS')])
        return Row('UNKNOWN', [err.strip().splitlines()[-1] if err.strip() else f'exit {code}'])

    def repair_isolation(self, path):
        p = ROOT/path
        if not p.exists():
            return Row('UNKNOWN', [f'No isolation record at {path}'])
        a = json.loads(p.read_text())
        patch = ROOT/a.get('patch', '')
        if not patch.is_file() or hashlib.sha256(patch.read_bytes()).hexdigest() != a.get('patch_sha256'):
            return Row('UNKNOWN', [f'{path} does not match the retained patch'])
        if not a.get('accepted_by'):
            return Row('UNKNOWN', [f'{path} names no reviewer'])
        if a.get('isolation') == 'enforced':
            return Row('PASS', isolation='enforced', accepted_by=a['accepted_by'])
        if a.get('isolation') == 'instruction-only' and a.get('decision') == 'owner-waiver':
            waiver = f"Repair isolation: instruction-only accepted by {a['accepted_by']} on {a.get('accepted_on')}; revisit: {a.get('revisit')}"
            self.waivers.append(waiver)
            return Row('PASS', isolation='instruction-only', waiver=waiver)
        return Row('UNKNOWN', [f'{path} records neither enforced isolation nor an owner waiver'])

    def check(self, name):
        if name.startswith('mutant:'):
            return self.mutant(name.split(':', 1)[1])
        if name.startswith('repair-isolation:'):
            return self.repair_isolation(name.split(':', 1)[1])
        return getattr(self, name.replace('-', '_'))()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', default=str(ROOT/'spec/tc0/tc0-a-requirements.json'))
    args = parser.parse_args()
    manifest_path = Path(args.manifest).resolve()
    manifest = json.loads(manifest_path.read_text())
    ledger = {r['id'] for r in json.loads((ROOT/manifest['ledger']).read_text())['rows']}
    unknown_refs = sorted({l for r in manifest['rows'] for l in r['ledger'] if l not in ledger})
    if manifest['schema'] != 'tc0-a-requirement-manifest/1' or unknown_refs:
        raise SystemExit('Manifest invalid; unknown ledger rows: '+', '.join(unknown_refs))
    stamp = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    head = subprocess.run(['git', 'rev-parse', '--short=12', 'HEAD'], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    out = ROOT/'build/tc0/gate'/f'{head}-{stamp}'
    out.mkdir(parents=True)
    shen = ROOT/'build/toolchain/shen-scheme'
    gate = Gate(out, str(shen) if shen.exists() else None)
    rows, started = [], time.monotonic()
    for spec_row in manifest['rows']:
        t = time.monotonic()
        try:
            row = gate.check(spec_row['check'])
        except Exception as e:  # evaluator fault: never a pass
            row = Row('UNKNOWN', [f'Evaluator error: {type(e).__name__}: {e}'])
        rows.append({'id': spec_row['id'], 'required': spec_row['required'], 'status': row.status, 'reasons': row.reasons,
                     'detail': row.detail, 'seconds': round(time.monotonic()-t, 2)})
        print(f"{spec_row['id']}: {row.status}{' - '+'; '.join(row.reasons) if row.reasons else ''}", file=sys.stderr, flush=True)
    required = [r for r in rows if r['required']]
    verdict = next((s for s in ('FAIL', 'BLOCKED', 'UNKNOWN') if any(r['status'] == s for r in required)), 'PASS')
    if gate.source_identity().detail.get('head') != getattr(gate, 'head', None) or subprocess.run(['git', 'status', '--porcelain'], cwd=ROOT, capture_output=True, text=True).stdout.strip():
        verdict = 'UNKNOWN' if verdict == 'PASS' else verdict
        rows.append({'id': 'source-drift', 'required': True, 'status': 'UNKNOWN', 'reasons': ['Source changed during evaluation'], 'detail': {}, 'seconds': 0})
    status = {r['id']: r['status'] for r in rows}
    claims = sorted(c for c, ids in manifest['claims'].items()
                    if all(status.get(i) == 'PASS' for i in [*ids, *manifest['claim_prerequisites']]))
    config = json.loads((ROOT/'.pi/fenrir-workflow.json').read_text())
    registered = (manifest.get('status') == 'owner-reviewed' and
                  'tools/check-tc0-a-gate.py' in config.get('checks', {}).get('tc0-a-qualification', {}).get('command', []))
    report = {'schema': 'tc0-a-gate-run/2', 'authority': 'owner-reviewed, registered' if registered else 'UNREGISTERED',
              'qualification': verdict if registered else 'UNKNOWN', 'verdict': verdict, 'claims': claims, 'waivers': gate.waivers,
              'head': getattr(gate, 'head', None), 'manifest': str(manifest_path.relative_to(ROOT)), 'evaluator': 'tools/check-tc0-a-gate.py',
              'aggregation': manifest['aggregation'], 'seconds': round(time.monotonic()-started, 2), 'rows': rows}
    (out/'gate.json').write_text(json.dumps(report, indent=1)+'\n')
    evidence = [str(p.relative_to(ROOT)) for p in [out/'gate.json', *[out/n for n in ('hand.json', 'hand-replay.json', 'arith.json', 'exhaustive-5.json', 'coverage.json',
                's2-arm-by-position.json', 's2-arm-by-position-replay.json', 's2-reverse-operands.json', 's2-reverse-operands-replay.json',
                'sandbox.json', 's3-evaluation.json')]] if p.is_file()]
    summary = (f"TC0-A gate at {report['head']}: {verdict}; {sum(r['status'] == 'PASS' for r in required)}/{len(required)} required rows PASS; "
               f"claims {', '.join(claims) or 'none'}" + (f"; waivers: {' | '.join(gate.waivers)}" if gate.waivers else '') +
               ''.join(f"; {r['id']}: {r['status']} ({'; '.join(r['reasons'])})" for r in rows if r['status'] not in ('PASS',) and r['required']))[:7900]
    if os.environ.get('FENRIR_CHECK_NONCE'):
        print(json.dumps({'schema': 'fenrir.check.v1', 'nonce': os.environ['FENRIR_CHECK_NONCE'], 'checkId': os.environ.get('FENRIR_CHECK_ID'),
                          'sourceHash': os.environ.get('FENRIR_SOURCE_SHA256'), 'configHash': os.environ.get('FENRIR_CONFIG_SHA256'),
                          'verdict': verdict if registered else 'UNKNOWN', 'cleanup': 'confirmed', 'claims': claims if registered else [],
                          'evidence': evidence, 'summary': summary}))
    else:
        print(json.dumps({'authority': report['authority'], 'qualification': report['qualification'], 'verdict': verdict, 'claims': claims,
                          'waivers': gate.waivers, 'rows': status, 'report': str(out/'gate.json')}))
    sys.exit({'PASS': 0, 'FAIL': 1}.get(verdict, 2))


if __name__ == '__main__':
    main()
