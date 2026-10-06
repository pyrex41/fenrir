#!/usr/bin/env python3
"""Cooperative virtual-clock DEVELOPMENT builds; never native/TC0 qualification."""
import argparse
import copy
import hashlib
import os
import selectors
import signal
import subprocess
import time
import uuid
import base64
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools/solo5'))
import control_protocol as wire


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT/path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


build = load('environment_build', 'tools/solo5/build-control-stdin.py')
overlay = load('environment_overlay', 'backends/solo5/overlays/virtual-environment/overlay.py')
client = build.client
PROFILE = 'fenrir.solo5.cooperative-environment/1'
RUN = 'environment-0'


def records():
    """Independent hand expectations, not candidate source or transitions."""
    common = {'profile': PROFILE, 'run_id': RUN}
    domains = [[['Init', '0', '1000']], [['Hold', 'Read0']], [['Advance', '10']],
               [['Hold', 'Read2']], [['Hold', 'Read3']], [['Ack', 'Terminal']]]
    sites = ['Init', 'Read0', 'Advance10', 'Read2', 'Read3', 'Terminal']
    host = []
    for i, kind in enumerate(['Init', 'Hold', 'Advance', 'Hold', 'Hold', 'Ack']):
        host.append({**common, 'domain_hash': wire.hash_value(domains[i]),
                     'epoch': str(i), 'sequence': str(i), 'site': sites[i], 'kind': kind})
    host[0].update(time='0', wall_origin='1000')
    host[2]['time'] = '10'
    guest = [{**common, 'domain_hash': wire.hash_value(domains[0]), 'epoch': '0',
              'kind': 'Hello', 'sequence': '0', 'site': 'Init'}]
    for i, (m, w) in enumerate([('0', '1000'), ('0', '1000'), ('10', '1010'), ('10', '1010')]):
        guest.append({**common, 'epoch': str(i+1), 'sequence': str(i+1), 'kind': 'Clock',
                      'monotonic': m, 'wall': w, 'site': 'Read'+str(i)})
    guest.append({**common, 'accepted': '5', 'domain_hash': wire.hash_value(domains[5]),
                  'epoch': '5', 'kind': 'Terminal', 'sequence': '5', 'site': 'Terminal'})
    return guest, host


def transfer(output, label):
    match = re.search(r'^FG_'+label+r'_BEGIN\n([A-Za-z0-9+/=\n]+)FG_'+label+r'_END\n', output, re.M)
    if not match or len(output) > 2097152:
        raise ValueError('Invalid bounded '+label+' artifact transfer')
    return base64.b64decode(match[1].replace('\n', ''), validate=True)


def compile_environment(dest, dependency):
    """Build twice in isolated copies; installed bindings/vendor/tender untouched."""
    vendor = ROOT/'build/vendor/solo5'
    if client.checked(['git', '-C', str(vendor), 'rev-parse', 'HEAD']).strip() != client.COMMIT:
        raise RuntimeError('Pinned vendor prerequisite differs')
    if client.checked(['git', '-C', str(vendor), 'status', '--porcelain', '--untracked-files=all']):
        raise RuntimeError('Vendor prerequisite is not pristine')
    receipt = json.loads(dependency.read_text())
    if receipt.get('schema') != 'fenrir.solo5.control-build/1' or receipt.get('cleanup') != 'confirmed':
        raise ValueError('Unsupported transport dependency')
    for path, sha in receipt['sources_before'].items():
        if receipt['sources_after'].get(path) != sha or client.digest(ROOT/path) != sha:
            raise ValueError('Transport dependency source differs: '+path)
    stock = json.loads(client.checked(['docker', 'image', 'inspect', client.IMAGE]))[0]
    image = json.loads(client.checked(['docker', 'image', 'inspect', receipt['overlay_image']]))[0]
    if (stock['Id'] != receipt['stock_image'] or image['Id'] != receipt['overlay_image'] or
        image['RootFS']['Layers'][:-1] != stock['RootFS']['Layers']):
        raise ValueError('Immutable dependency image differs')
    project = ['backends/solo5/virtual-env.h', 'backends/solo5/virtual-env.c',
               'backends/solo5/environment-guest.c', 'backends/solo5/protocol.h',
               'backends/solo5/protocol.c', 'backends/solo5/overlays/virtual-environment/overlay.py',
               'spec/solo5/environment-demo.json', 'tools/solo5/environment.py']
    protected = [vendor/'bindings/spt/bindings.c', vendor/'bindings/spt/net.c',
                 vendor/'bindings/crt_init.h', vendor/'tenders/spt/spt_core.c']
    paths = [ROOT/p for p in project] + protected
    before = {str(p.relative_to(ROOT)): client.digest(p) for p in paths}
    dest.mkdir(parents=True, exist_ok=False)
    mounts = []
    for name in ['bindings.c', 'net.c']:
        adapted, patch = overlay.apply(name, (vendor/'bindings/spt'/name).read_bytes())
        (dest/name).write_bytes(adapted)
        (dest/(name+'.patch')).write_text(patch)
        mounts.append((dest/name, '/inputs/'+name))
    for path in project[:5]:
        mounts.append((ROOT/path, '/inputs/'+Path(path).name))
    box = build.Sandbox(image['Id'])
    command = '''set -eu
export TMPDIR=/work
mkdir /work/source
cp /opt/solo5/Makeconf /opt/solo5/Makefile.common /work/source/
cp -a /opt/solo5/include /opt/solo5/bindings /work/source/
chmod -R u+w /work/source
# TOPDIR-relative wrappers must remain in the immutable executable image, not
# copied into the intentionally noexec build tmpfs. Symlink does not alter policy.
ln -s /opt/solo5/toolchain /work/source/toolchain
cd /work/source/bindings
make TOPDIR=/work/source clean >&2
cp /inputs/bindings.c /inputs/net.c /inputs/virtual-env.c /inputs/virtual-env.h spt/
make TOPDIR=/work/source -j2 solo5_spt.o >&2
cd /work
export PATH=/opt/solo5-install/bin:$PATH
aarch64-solo5-none-static-cc -Wall -Wextra -Werror -I/inputs -c /inputs/environment-guest.c -o guest.o
aarch64-solo5-none-static-cc -Wall -Wextra -Werror -I/inputs -c /inputs/protocol.c -o protocol.o
printf '{"type":"solo5.manifest","version":1,"devices":[]}\\n' > manifest.json
solo5-elftool gen-manifest manifest.json manifest.c
aarch64-solo5-none-static-cc -c manifest.c -o manifest.o
ld -nostdlib -static -z max-page-size=0x1000 -T /work/source/bindings/solo5_spt.lds /work/source/bindings/solo5_spt.o manifest.o guest.o protocol.o -o guest.spt
printf 'FG_BINDINGS_BEGIN\\n'; base64 /work/source/bindings/solo5_spt.o; printf 'FG_BINDINGS_END\\n'
printf 'FG_GUEST_BEGIN\\n'; base64 guest.spt; printf 'FG_GUEST_END\\n'
cc --version | head -1
sha256sum /opt/fenrir/solo5-spt-control /opt/solo5-install/lib/aarch64-solo5-none-static/solo5_spt.o
cat /opt/solo5-install/bin/aarch64-solo5-none-static-ld
'''
    try:
        binaries = []
        for i in range(2):
            p = box.run('environment-build-'+str(i), ['sh', '-c', command], mounts, True)
            if p.returncode:
                raise RuntimeError('Isolated environment build failed: '+p.stderr[-4000:])
            if receipt['tender_sha256'] not in p.stdout:
                raise RuntimeError('Installed unchanged tender identity differs')
            binaries.append((transfer(p.stdout, 'BINDINGS'), transfer(p.stdout, 'GUEST')))
        if binaries[0] != binaries[1]:
            raise RuntimeError('Isolated environment builds differ')
        (dest/'solo5_spt.o').write_bytes(binaries[0][0])
        (dest/'guest.spt').write_bytes(binaries[0][1])
        after = {str(p.relative_to(ROOT)): client.digest(p) for p in paths}
        if before != after or client.checked(['git', '-C', str(vendor), 'status', '--porcelain', '--untracked-files=all']):
            raise RuntimeError('Protected source drift')
        box.verify_cleanup()
        report = {'schema': 'fenrir.solo5.environment-build/1', 'qualification': 'UNKNOWN',
                  'profile': PROFILE, 'transport_dependency_sha256': client.digest(dependency),
                  'transport_image': image['Id'], 'stock_image': stock['Id'],
                  'tender_sha256': receipt['tender_sha256'], 'solo5_commit': client.COMMIT,
                  'bindings_sha256': client.digest(dest/'solo5_spt.o'),
                  'guest_sha256': client.digest(dest/'guest.spt'), 'two_builds_equal': True,
                  'sources_before': before, 'sources_after': after,
                  'cleanup': 'confirmed', 'canary_policy': 'unchanged native ticks',
                  'security_policy': 'unchanged pipe-only tender; raw clock syscalls still permitted',
                  'command': sys.argv}
        (dest/'build.json').write_text(json.dumps(report, indent=2)+'\n')
        return report
    finally:
        (dest/'diagnostics.json').write_text(json.dumps(box.logs, indent=2)+'\n')


def admit_build(path):
    report = json.loads(path.read_bytes())
    if (report.get('schema') != 'fenrir.solo5.environment-build/1' or
        report.get('profile') != PROFILE or report.get('cleanup') != 'confirmed' or
        report.get('two_builds_equal') is not True):
        raise ValueError('Expected completed environment development build')
    # environment.py is host infrastructure, not linked guest source. Its later
    # session implementation is independently bound in the session header.
    for p, sha in report['sources_before'].items():
        if report['sources_after'].get(p) != sha:
            raise ValueError('Build source changed')
        if p != 'tools/solo5/environment.py' and client.digest(ROOT/p) != sha:
            raise ValueError('Guest/build source drift: '+p)
    for filename, field in [('guest.spt', 'guest_sha256'), ('solo5_spt.o', 'bindings_sha256')]:
        if client.digest(path.parent/filename) != report[field]:
            raise ValueError('Build artifact drift')
    image = json.loads(client.checked(['docker', 'image', 'inspect', report['transport_image']]))[0]
    stock = json.loads(client.checked(['docker', 'image', 'inspect', report['stock_image']]))[0]
    if image['RootFS']['Layers'][:-1] != stock['RootFS']['Layers']:
        raise ValueError('Image layer provenance differs')
    return report


def session(image, binary, responses=None, delay=0, fragment=False, mode='environment', timeout=20):
    """Foreground pipe exchange; host delays are diagnostics, never virtual time."""
    expected, host = records()
    planned = [wire.frame(r) for r in host] if responses is None else responses
    if len(planned) > 7 or sum(map(len, planned)) > 16384:
        raise ValueError('Input bound exceeded')
    name = 'fenrir-solo5-environment-'+uuid.uuid4().hex[:16]
    owner = uuid.uuid4().hex
    mounts = [(binary, '/guest/guest.spt')]
    argv = ['docker', 'run', '--name', name, '--label', 'org.fenrir.probe.owner='+owner,
            '--read-only', '--network', 'none', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
            '--user', '65534:65534', '--memory', '128m', '--pids-limit', '32', '-i',
            '--mount', f'type=bind,src={binary},dst=/guest/guest.spt,readonly', image,
            '/opt/fenrir/solo5-spt-control', '--mem=16', '--fenrir-control-stdin',
            '/guest/guest.spt', '--solo5:quiet', mode]
    decoder = wire.Decoder()
    trace, sent, holds = [], [], []
    output, err, pending = bytearray(), bytearray(), bytearray()
    error = stopped = None
    release = 0
    queued = None
    closing = not planned
    process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True, cwd=ROOT)
    selector = selectors.DefaultSelector()
    start = time.monotonic()
    for stream, label in [(process.stdout, 'stdout'), (process.stderr, 'stderr')]:
        os.set_blocking(stream.fileno(), False)
        selector.register(stream, selectors.EVENT_READ, label)
    os.set_blocking(process.stdin.fileno(), False)
    def close_input():
        if not process.stdin.closed:
            process.stdin.close()
    try:
        while True:
            now = time.monotonic()
            if now-start > timeout:
                stopped = 'HarnessTimeout'
                break
            if len(output)+len(err) > 1048576:
                stopped = 'OutputLimit'
                break
            if pending and now >= release and not process.stdin.closed:
                try:
                    count = os.write(process.stdin.fileno(), pending[:1] if fragment else pending)
                    del pending[:count]
                    if not pending:
                        sent.append(base64.b64encode(queued).decode())
                        queued = None
                except BlockingIOError:
                    pass
                except BrokenPipeError:
                    close_input()
                    pending.clear()
            if closing and not pending:
                close_input()
            for key, _ in selector.select(0.01):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                (output if key.data == 'stdout' else err).extend(chunk)
                if key.data == 'stdout':
                    try:
                        for record in decoder.iter_feed(chunk):
                            index = len(trace)
                            trace.append(record)
                            if index >= len(expected) or record != expected[index]:
                                error = {'kind': 'RecordMismatch', 'index': str(index)}
                                break
                            if index != len(sent):
                                error = {'kind': 'UnsolicitedProgress', 'index': str(index)}
                                break
                            if index >= len(planned):
                                closing = True
                            else:
                                queued = planned[index]
                                pending.extend(queued)
                                release = time.monotonic()+(delay if index in [1, 3] else 0)
                                if delay and index in [1, 3]:
                                    holds.append({'index': str(index), 'release_delay_seconds': str(delay)})
                                closing = index == len(planned)-1
                    except wire.ProtocolError as exc:
                        error = {'kind': str(exc), 'index': str(len(trace))}
            if error:
                stopped = 'StoppedAtDivergence'
                break
            if process.poll() is not None and not selector.get_map():
                break
        if stopped:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait(timeout=5)
        if not stopped:
            try:
                decoder.finish()
            except wire.ProtocolError as exc:
                error = {'kind': str(exc), 'index': str(len(trace))}
        info = json.loads(client.checked(['docker', 'inspect', name], 15))[0]
        if (info['Image'] != image or info['Config']['Labels'].get('org.fenrir.probe.owner') != owner or
            not info['Config']['OpenStdin'] or info['Config']['Tty']):
            raise RuntimeError('Owned session identity/wiring differs')
        check = copy.deepcopy(info)
        check['Config']['OpenStdin'] = False
        policy = build.feas.check_policy(check, mounts, False)
        code = process.returncode
        if stopped:
            execution = stopped
        elif code in [132, 133, 134, 139]:
            execution = 'CandidateCrash'
        elif code == 159:
            execution = 'SandboxDenied'
        elif code == 1:
            execution = 'GuestRejected'
        elif error or trace != expected or len(sent) != len(planned):
            execution = 'StoppedAtDivergence'
        elif code == 0:
            execution = 'Completed'
        else:
            execution = 'HarnessError'
        return {'execution': execution, 'exit': str(code), 'trace': trace, 'responses': sent,
                'first_error': error, 'stdout_sha256': hashlib.sha256(output).hexdigest(),
                'stderr': err.decode(errors='replace')[:8192], 'hold_diagnostics': holds,
                'fragmented_input': fragment, 'policy': policy, 'command': argv,
                'mode': mode, 'cleanup': 'confirmed'}
    finally:
        close_input()
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
        selector.close()
        process.stdout.close()
        process.stderr.close()
        removed = client.command(['docker', 'rm', '-f', name], 15)
        absent = client.command(['docker', 'inspect', name], 15)
        if removed.returncode or not build.feas.confirms_absent(absent.returncode, absent.stdout, absent.stderr, name):
            raise RuntimeError('Owned session container cleanup unresolved')
        groups = subprocess.run(['ps', '-axo', 'pid=,pgid=,stat='], capture_output=True, text=True, timeout=5, check=True)
        if any(len(x.split()) == 3 and x.split()[1] == str(process.pid) and
               not x.split()[2].startswith('Z') for x in groups.stdout.splitlines()):
            raise RuntimeError('Owned process-group cleanup unresolved')


def header(build_path, report):
    sources = ['tools/solo5/environment.py', 'tools/solo5/control_protocol.py',
               'tools/solo5/build-control-stdin.py', 'tools/solo5/baseline.py',
               'tools/solo5/transport-feasibility.py', 'spec/solo5/environment-demo.json']
    return {'schema': 'fenrir.solo5.environment-header/1', 'profile': PROFILE, 'run_id': RUN,
            'build_sha256': client.digest(build_path),
            'transport_dependency_sha256': report['transport_dependency_sha256'],
            'image': report['transport_image'], 'stock_image': report['stock_image'],
            'tender_sha256': report['tender_sha256'], 'bindings_sha256': report['bindings_sha256'],
            'guest_sha256': report['guest_sha256'], 'solo5_commit': report['solo5_commit'],
            'sources': {p: client.digest(ROOT/p) for p in sources},
            'python_sha256': client.digest(Path(sys.executable).resolve()),
            'docker_server': client.checked(['docker', 'version', '--format', '{{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}']).strip(),
            'initial_state': {'monotonic': '0', 'wall_origin': '1000'},
            'bounds': {'responses': '6', 'input_bytes': '16384', 'output_bytes': '1048576',
                       'watchdog_seconds': '20', 'guest_memory_mib': '16'},
            'security_scope': 'unchanged pipe-only tender; native startup ticks and raw clock syscalls unmediated'}


def completed_footer():
    guest, _ = records()
    return {'schema': 'fenrir.solo5.environment-footer/1', 'execution': 'Completed', 'exit': '0',
            'accepted': '6', 'epoch': '5', 'final_state': {'monotonic': '10', 'wall': '1010'},
            'trace_sha256': wire.hash_value(guest),
            'stdout_sha256': hashlib.sha256(b''.join(wire.frame(r) for r in guest)).hexdigest()}


def recording(identity, result):
    guest, host = records()
    frames = [base64.b64encode(wire.frame(r)).decode() for r in host]
    if (result['execution'] != 'Completed' or result['exit'] != '0' or result['cleanup'] != 'confirmed' or
        result['trace'] != guest or result['responses'] != frames or
        result['stdout_sha256'] != completed_footer()['stdout_sha256'] or result['first_error'] is not None):
        raise ValueError('Only independently observed completed demo can be recorded')
    return {'schema': 'fenrir.solo5.environment-recording/1', 'qualification': 'UNKNOWN',
            'header': identity, 'choices': host, 'responses': frames, 'trace': guest,
            'footer': completed_footer()}


def admit_recording(value, identity):
    # Full equality against closed hand expectations intentionally restricts
    # this first profile to its one declared scenario. No seed/fresh-input fallback.
    guest, host = records()
    expected = {'schema': 'fenrir.solo5.environment-recording/1', 'qualification': 'UNKNOWN',
                'header': identity, 'choices': host,
                'responses': [base64.b64encode(wire.frame(r)).decode() for r in host],
                'trace': guest, 'footer': completed_footer()}
    if value != expected:
        raise ValueError('Replay incompatible or diverged: identity/choice/trace/footer mismatch')
    return [wire.frame(r) for r in host]


def fresh_output(path):
    dest = Path(path).resolve()
    if not dest.is_relative_to(ROOT/'build/solo5') or dest == ROOT/'build/solo5' or dest.exists():
        raise ValueError('Fresh build/solo5 output required')
    return dest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest='action', required=True)
    compile_args = modes.add_parser('build')
    compile_args.add_argument('--build-dir', required=True)
    compile_args.add_argument('--transport-build', required=True)
    for action in ['record', 'replay']:
        args = modes.add_parser(action)
        args.add_argument('--build-report', required=True)
        args.add_argument('--output', required=True)
        if action == 'replay':
            args.add_argument('--recording', required=True)
    args = parser.parse_args()
    if args.action == 'build':
        dest = fresh_output(args.build_dir)
        dependency = Path(args.transport_build).resolve()
        if not dependency.is_relative_to(ROOT/'build/solo5'):
            raise ValueError('Local transport build report required')
        report = compile_environment(dest, dependency)
        print(json.dumps({'qualification': 'UNKNOWN', 'report': str(dest/'build.json'),
                          'two_builds_equal': report['two_builds_equal'], 'cleanup': report['cleanup']}))
        return
    dest = fresh_output(args.output)
    diagnostics = fresh_output(str(dest)+'.diagnostics.json')
    path = Path(args.build_report).resolve()
    if not path.is_relative_to(ROOT/'build/solo5'):
        raise ValueError('Local build report required')
    report = admit_build(path)
    identity = header(path, report)
    responses = None
    if args.action == 'replay':
        tape = Path(args.recording).resolve()
        if not tape.is_relative_to(ROOT/'build/solo5') or tape.stat().st_size > 65536:
            raise ValueError('Bounded local recording required')
        # canonical decoder rejects duplicate keys/numeric tokens/invalid ASCII.
        responses = admit_recording(wire.decode(tape.read_bytes()), identity)
    result = session(report['transport_image'], path.parent/'guest.spt', responses=responses)
    if identity != header(path, admit_build(path)):
        raise RuntimeError('Source/environment identity changed during execution')
    value = recording(identity, result)
    # Never create or overwrite an output on failed replay admission/execution.
    dest.parent.mkdir(parents=True, exist_ok=True)
    with dest.open('xb') as stream:
        stream.write(wire.canonical(value))
    with diagnostics.open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps({'qualification': 'UNKNOWN', 'execution': result['execution'],
                      'replay': 'Exact' if args.action == 'replay' else 'NotRequested',
                      'recording': str(dest), 'cleanup': 'confirmed'}))


if __name__ == '__main__':
    main()
