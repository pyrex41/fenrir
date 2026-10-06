#!/usr/bin/env python3
"""Source-bound retained transport tapes and cold replay, DEVELOPMENT only."""
import argparse
import base64
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import shutil
import sys
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/solo5'))
import control_protocol as wire
spec = importlib.util.spec_from_file_location('interactive_replay',ROOT/'tools/solo5/interactive.py')
peer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(peer)
client = peer.client
REQUIRED = ['tools/solo5/interactive.py','tools/solo5/control_protocol.py','tools/solo5/build-control-stdin.py',
            'tools/solo5/baseline.py','tools/solo5/transport-feasibility.py','backends/solo5/interactive-guest.c',
            'backends/solo5/protocol.c','backends/solo5/protocol.h','spec/solo5/protocol-demo.json']
BUILD_REQUIRED = ['tools/solo5/build-control-stdin.py','tools/solo5/baseline.py','tools/solo5/transport-feasibility.py',
                  'backends/solo5/overlays/control-stdin/overlay.py','build/vendor/solo5/tenders/spt/spt_core.c','backends/solo5/Dockerfile']


def strict_json(data):
    def pairs(items):
        row = {}
        for k,v in items:
            if k in row:
                raise ValueError('Duplicate decoded evidence key')
            row[k] = v
        return row
    def numeric(_):
        raise ValueError('Numeric token in closed evidence')
    return json.loads(data,object_pairs_hook=pairs,parse_int=numeric,parse_float=numeric,parse_constant=numeric)


def identity_sources(report, required):
    before,after = report.get('sources_before'),report.get('sources_after')
    if not isinstance(before,dict) or before != after:
        raise ValueError('Missing or inconsistent source identity')
    for path in required:
        if path not in before:
            raise ValueError('Missing required source identity: '+path)
    for p,h in before.items():
        if client.digest(ROOT/p) != h:
            raise ValueError('Retained source drift: '+p)
    return before


def admit_report(path):
    data = path.read_bytes()
    report = strict_json(data)
    if report.get('schema') != 'fenrir.solo5.interactive-development/1' or report.get('qualification') != 'UNKNOWN' or report.get('cleanup') != 'confirmed':
        raise ValueError('Expected interactive development report')
    identity_sources(report,REQUIRED)
    identity_sources(report['build_identity'],BUILD_REQUIRED)
    build_path = Path(report['build_report'])
    if hashlib.sha256(build_path.read_bytes()).hexdigest() != report['build_report_sha256'] or peer.admit_build(build_path) != report['build_identity']:
        raise ValueError('Build report identity drift')
    binary = Path(report['guest_path'])
    if client.digest(binary) != report['guest_sha256']:
        raise ValueError('Guest artifact drift')
    cases = report.get('cases')
    if not isinstance(cases,list) or not 1 <= len(cases) <= 100 or len({x['name'] for x in cases}) != len(cases):
        raise ValueError('Bounded unique cases required')
    for row in cases:
        if row['cleanup'] != 'confirmed' or row['execution'] != row['expected_execution']:
            raise ValueError('Unconfirmed retained outcome')
    return report,data


def environment():
    docker = Path(shutil.which('docker')).resolve(strict=True)
    python = Path(sys.executable).resolve(strict=True)
    server = json.loads(client.checked(['docker','info','--format',
        '{"os":{{json .OSType}},"arch":{{json .Architecture}},"kernel":{{json .KernelVersion}},"version":{{json .ServerVersion}}}']))
    return {'host':{'system':platform.system(),'machine':platform.machine(),'python':platform.python_version()},
            'docker_server':server,'executables':{str(docker):client.digest(docker),str(python):client.digest(python)}}


def footer(row):
    if row['execution'] not in ['Completed','StoppedAtDivergence']:
        raise ValueError('Crash/watchdog/rejection is not an exact completed/divergence tape')
    return {'execution':row['execution'],'conformance':'Admitted' if row['execution']=='Completed' else 'Diverged',
            'first_error':row['first_error'],'trace':row['trace'],'responses':row['responses']}


def header(report,report_hash,row,env):
    return {'schema':'fenrir.solo5.control-tape/1','profile':wire.PROFILE,'run_id':wire.RUN,
            'report_sha256':report_hash,'sources':report['sources_after'],'build_report_sha256':report['build_report_sha256'],
            'guest_sha256':report['guest_sha256'],'image_id':report['image_id'],
            'mode':row['mode'],'opt_in':row['opt_in'],'input_kind':row['input_kind'],
            'bounds':report['bounds'],'config_hash':wire.records()[0][0]['config_hash'],
            'catalog_sha256':client.digest(ROOT/'spec/solo5/protocol-demo.json'),
            'replay_adapter_sha256':client.digest(Path(__file__)),'environment':env,
            'initial_protocol_state':{'guest_sequence':'0','host_sequence':'0','epoch':'0','accepted':'0'}}


def tape_for(report,report_hash,row,env):
    if row['mode'] not in ['protocol','early-terminal','wrong-boundary','suffix'] or not row['opt_in'] or row['input_kind'] != 'pipe':
        raise ValueError('Unsupported replay profile/options')
    choices = []
    _,commands = wire.records()
    for i,encoded in enumerate(row['responses']):
        if i >= len(commands):
            raise ValueError('Extra retained response')
        raw = base64.b64decode(encoded,validate=True)
        if raw != wire.frame(commands[i]):
            raise ValueError('Unsupported response bytes')
        domain = [['Proceed',str(i-1)]] if i in [1,2] else [[commands[i]['kind']]]
        choices.append({'index':str(i),'sequence':str(i),'epoch':str(max(0,i-1)),
                        'kind':commands[i]['kind'],'domain_hash':wire.hash_value(domain),
                        'site':commands[i].get('site','Transport'+commands[i]['kind']),
                        'bytes':encoded,'selected':domain[0]})
    return {'header':header(report,report_hash,row,env),'choices':choices,'footer':footer(row)}


def validate_tape(tape,expected):
    # Closed canonical data comparison covers header/options/environment, every
    # singleton choice/epoch/site/domain/response byte and the exact first footer.
    if not isinstance(tape,dict) or set(tape) != {'header','choices','footer'}:
        raise ValueError('Tape shape')
    if tape['header'] != expected['header']:
        raise ValueError('ReplayIncompatible')
    if tape['choices'] != expected['choices'] or tape['footer'] != expected['footer']:
        raise ValueError('ReplayDiverged')


def validate_bundle(bundle,expected,report_hash,sources):
    required = {'schema','qualification','oracle_report_sha256','sources','cases','scope'}
    if not isinstance(bundle,dict) or set(bundle)!=required or bundle['schema']!='fenrir.solo5.control-replay-bundle/1' or bundle['qualification']!='UNKNOWN' or bundle['oracle_report_sha256']!=report_hash or bundle['sources']!=sources:
        raise ValueError('Retained replay bundle incompatible')
    if bundle['scope']!='Same guest/tender/options exposed transport completion or first discrepancy, not native machine replay' or set(bundle['cases'])!=set(expected):
        raise ValueError('Missing/extra retained tapes or scope drift')
    for name,tape in expected.items():
        row = bundle['cases'][name]
        if set(row)!={'tape','result'}:
            raise ValueError('Retained case shape')
        validate_tape(row['tape'],tape)
        result = {'replay':'Exact','conformance':tape['footer']['conformance'],'execution':tape['footer']['execution'],
                  'qualification':'UNKNOWN','scope':'Observed cooperative transport prefix/footer only','cleanup':'confirmed'}
        if row['result'] != result:
            raise ValueError('Retained replay result drift')


def replay_one(report,row,tape,expected):
    validate_tape(tape,expected)  # Reject drift before candidate execution.
    raw = [base64.b64decode(c['bytes'],validate=True) for c in tape['choices']]
    observed = peer.session(report['image_id'],Path(report['guest_path']),mode=row['mode'],response_tape=raw)
    if footer(observed) != tape['footer']:
        raise ValueError('Cold first-boundary replay mismatch')
    return {'replay':'Exact','conformance':tape['footer']['conformance'],'execution':observed['execution'],
            'qualification':'UNKNOWN','scope':'Observed cooperative transport prefix/footer only','cleanup':observed['cleanup']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report')
    parser.add_argument('output')
    parser.add_argument('--tapes',help='Existing exact bundle to validate/replay; no record fallback')
    args = parser.parse_args()
    path,output = Path(args.report).resolve(),Path(args.output).resolve()
    if not output.is_relative_to(ROOT/'build/solo5') or output.suffix!='.json' or output==path or output.exists():
        raise ValueError('Fresh separate replay output required')
    report,data = admit_report(path)
    report_hash = hashlib.sha256(data).hexdigest()
    env = environment()
    own_sources = {p:client.digest(ROOT/p) for p in ['tools/solo5/control_replay.py','tools/solo5/interactive.py','tools/solo5/control_protocol.py']}
    selected_names = ['cold-0','guest-early-terminal','guest-wrong-boundary','guest-suffix']
    rows = {r['name']:r for r in report['cases']}
    expected = {name:tape_for(report,report_hash,rows[name],env) for name in selected_names}
    existing_data = None
    if args.tapes:
        existing_path = Path(args.tapes).resolve()
        existing_data = existing_path.read_bytes()
        existing = strict_json(existing_data)
        # Validate the entire closed bundle before launching even one guest.
        validate_bundle(existing,expected,report_hash,own_sources)
        supplied = {name:existing['cases'][name]['tape'] for name in expected}
    else:
        supplied = expected
    cases = {}
    for name in selected_names:
        result = replay_one(report,rows[name],supplied[name],expected[name])
        cases[name] = {'tape':supplied[name],'result':result}
    admit_report(path)
    if path.read_bytes()!=data or environment()!=env or any(client.digest(ROOT/p)!=h for p,h in own_sources.items()):
        raise ValueError('Replay report/source/environment drift')
    if existing_data is not None and existing_path.read_bytes()!=existing_data:
        raise ValueError('Parsed existing tape bytes drift')
    bundle = {'schema':'fenrir.solo5.control-replay-bundle/1','qualification':'UNKNOWN',
              'oracle_report_sha256':report_hash,'sources':own_sources,'cases':cases,
              'scope':'Same guest/tender/options exposed transport completion or first discrepancy, not native machine replay'}
    output.parent.mkdir(parents=True,exist_ok=True)
    with output.open('x') as f:
        f.write(json.dumps(bundle,sort_keys=True,separators=(',',':'))+'\n')
    print(json.dumps({'qualification':'UNKNOWN','exact_cases':len(cases),'output':str(output)}))


if __name__ == '__main__':
    main()
