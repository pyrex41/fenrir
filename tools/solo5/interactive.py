#!/usr/bin/env python3
"""Synchronous stock-isolated cooperative transport sessions, DEVELOPMENT only."""
import argparse
import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
import uuid
sys.path.insert(0,str(Path(__file__).resolve().parent))
import control_protocol as wire
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('control_build',ROOT/'tools/solo5/build-control-stdin.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
client, feas = build.client, build.feas


def compile_guest(image,dest):
    box = build.Sandbox(image)
    mounts = [(ROOT/'backends/solo5'/p,'/inputs/'+p) for p in ['interactive-guest.c','protocol.c','protocol.h']]
    cmd = ('set -eu; cd /work; export PATH=/opt/solo5-install/bin:$PATH; '
           'aarch64-solo5-none-static-cc -Wall -Wextra -Werror -I/inputs -c /inputs/interactive-guest.c -o guest.o; '
           'aarch64-solo5-none-static-cc -Wall -Wextra -Werror -I/inputs -c /inputs/protocol.c -o protocol.o; '
           'printf \'{"type":"solo5.manifest","version":1,"devices":[]}\\n\' > manifest.json; '
           'solo5-elftool gen-manifest manifest.json manifest.c; '
           'aarch64-solo5-none-static-cc -c manifest.c -o manifest.o; '
           'aarch64-solo5-none-static-ld -z solo5-abi=spt manifest.o guest.o protocol.o -o guest.spt; '
           'printf "FG_BINARY_BEGIN\\n"; base64 guest.spt; printf "FG_BINARY_END\\n"')
    p = box.run('guest-build',['sh','-c',cmd],mounts,True)
    if p.returncode:
        raise RuntimeError('Guest build failed: '+p.stderr[-3000:])
    import re
    match = re.fullmatch(r'FG_BINARY_BEGIN\n([A-Za-z0-9+/=\n]+)FG_BINARY_END\n',p.stdout)
    if not match or len(p.stdout)>1048576:
        raise RuntimeError('Invalid guest transfer')
    binary = dest/'guest.spt'
    binary.write_bytes(base64.b64decode(match[1].replace('\n',''),validate=True))
    box.verify_cleanup()
    return binary,box.logs


def fault_responses(fault):
    _,host = wire.records()
    frames = [wire.frame(r) for r in host]
    if not fault:
        return frames
    index,kind = fault
    record = copy.deepcopy(host[index])
    if kind in ['run_id','sequence','epoch','site','domain_hash','profile']:
        record[kind] = 'wrong'
        frames[index] = wire.frame(record)
    elif kind == 'decision':
        record['decision'] = ['Proceed','wrong']
        frames[index] = wire.frame(record)
    elif kind == 'unknown':
        record['extra'] = 'no'
        frames[index] = wire.frame(record)
    elif kind == 'kind':
        record['kind'] = 'Invented'
        frames[index] = wire.frame(record)
    elif kind == 'numeric':
        record['sequence'] = 0
        frames[index] = wire.frame(record)
    elif kind == 'duplicate':
        body = wire.canonical(record)
        body = body[:-1]+b',"kind":"'+record['kind'].encode()+b'"}'
        frames[index] = b'FGCTL/1 '+str(len(body)).encode()+b'\n'+body+b'\n'
    elif kind == 'length':
        frames[index] = b'FGCTL/1 01\n{}\n'
    elif kind == 'oversize':
        frames[index] = b'FGCTL/1 65501\n'
    elif kind == 'missing':
        frames = frames[:index]
    elif kind == 'reorder':
        frames[index],frames[index+1] = frames[index+1],frames[index]
    elif kind == 'suffix':
        frames[-1] += wire.frame(host[0])
    elif kind == 'truncated':
        frames = frames[:index]+[frames[index][:-10]]
    else:
        raise ValueError('Unknown scripted fault')
    return frames


def session(image,binary,mode='protocol',opt_in=True,raw_input=None,fault=None,delay=0,
            fragment=False,timeout=30,input_kind='pipe',response_tape=None):
    """One foreground client session; no threads/background candidate processes."""
    name = 'fenrir-solo5-interactive-'+uuid.uuid4().hex[:16]
    owner = uuid.uuid4().hex
    protocol = mode in ['protocol','early-terminal','wrong-boundary','suffix','malformed-output']
    mounts = [(binary,'/guest/guest.spt')]
    argv = ['docker','run','--name',name,'--label','org.fenrir.probe.owner='+owner,
            '--read-only','--network','none','--cap-drop','ALL','--security-opt','no-new-privileges',
            '--user','65534:65534','--memory','128m','--pids-limit','32']
    # Docker -it refuses a piped client stdin before creating a container.
    # The negative TTY fixture allocates only -t (closed host input), which
    # still supplies a guest PTY and lets the tender reject its descriptor.
    interactive = input_kind == 'pipe'
    if interactive:
        argv += ['-i']
    if input_kind == 'tty':
        argv += ['-t']  # Negative startup rejection only, never a supported transport.
    executable = ['/opt/fenrir/solo5-spt-control','--mem=16']
    if opt_in:
        executable += ['--fenrir-control-stdin']
    executable += ['/guest/guest.spt','--solo5:quiet',mode]
    if input_kind == 'regular':
        input_file = binary.parent/'regular-input'
        if not input_file.exists():
            input_file.write_bytes(b'x')
        mounts.append((input_file,'/guest/input'))
        executable = ['sh','-c','exec "$@" < /guest/input','sh',*executable]
    elif input_kind == 'missing':
        executable = ['sh','-c','exec 0<&-; exec "$@"','sh',*executable]
    elif input_kind == 'write-only':
        executable = ['sh','-c','exec "$@" 0>&1','sh',*executable]
    for p,target in mounts:
        argv += ['--mount',f'type=bind,src={p},dst={target},readonly']
    argv += [image,*executable]
    planned = response_tape if response_tape is not None else fault_responses(fault)
    if sum(map(len,planned)) > 262144:
        raise ValueError('Materialized input cap')
    expected,_ = wire.records()
    decoder = wire.Decoder()
    trace,sent,hold_observations = [],[],[]
    output,err = bytearray(),bytearray()
    pending = bytearray()
    current = None
    release = 0
    error = None
    stopped = None
    total_input = 0
    closing = False
    process = subprocess.Popen(argv,stdin=subprocess.PIPE if interactive else subprocess.DEVNULL,
                               stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True,cwd=ROOT)
    selector = selectors.DefaultSelector()
    for stream,label in [(process.stdout,'stdout'),(process.stderr,'stderr')]:
        os.set_blocking(stream.fileno(),False)
        selector.register(stream,selectors.EVENT_READ,label)
    if interactive:
        os.set_blocking(process.stdin.fileno(),False)
    start = time.monotonic()
    if not protocol and interactive:
        pending.extend(raw_input or b'')
        closing = True
    def queue(index):
        nonlocal current,release,closing
        if index >= len(planned):
            closing = True
            return
        current = planned[index]
        pending.extend(current)
        release = time.monotonic()+(delay if index in [1,2] else 0)
        closing = index == len(planned)-1
    def close_input():
        if process.stdin and not process.stdin.closed:
            process.stdin.close()
    if protocol and interactive and not planned:
        close_input()
    policy = None
    try:
        while True:
            now = time.monotonic()
            if now-start > timeout:
                stopped = 'HarnessTimeout'
                break
            if len(output)+len(err) > 8388608:
                stopped = 'OutputLimit'
                break
            if pending and now >= release and process.stdin and not process.stdin.closed:
                try:
                    n = os.write(process.stdin.fileno(),pending[:1] if fragment else pending)
                    total_input += n
                    del pending[:n]
                    if not pending and current is not None:
                        sent.append(current)
                        if delay and len(sent) in [2,3]:
                            hold_observations.append({'response_index':str(len(sent)-1),'no_progress_observed_before_release':True})
                        current = None
                except BlockingIOError:
                    pass
                except BrokenPipeError:
                    close_input()
                    pending.clear()
            if closing and not pending:
                close_input()
            if total_input > 262144:
                stopped = 'InputLimit'
                break
            for key,_ in selector.select(0.01):
                chunk = os.read(key.fileobj.fileno(),65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                target = output if key.data == 'stdout' else err
                target.extend(chunk)
                if protocol and key.data == 'stdout':
                    try:
                        for record in decoder.iter_feed(chunk):
                            index = len(trace)
                            trace.append(record)
                            if index >= len(expected) or record != expected[index]:
                                error = {'kind':'RecordMismatch','index':str(index),'expected':expected[index] if index<len(expected) else None,'observed':record}
                                break
                            if index != len(sent):
                                error = {'kind':'UnsolicitedProgress','index':str(index)}
                                break
                            queue(index)
                    except wire.ProtocolError as e:
                        error = {'kind':str(e),'index':str(len(trace))}
                if error:
                    break
            if error:
                stopped = 'StoppedAtDivergence'
                break
            if process.poll() is not None and not selector.get_map():
                break
        if stopped:
            try:
                os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait(timeout=5)
        if protocol and not error and not stopped:
            try:
                decoder.finish()
            except wire.ProtocolError as e:
                error = {'kind':str(e),'index':str(len(trace))}
            if not error and trace != expected:
                error = {'kind':'PrematureExit','index':str(len(trace))}
        info = json.loads(client.checked(['docker','inspect',name],15))[0]
        if info['Image'] != image or info['Config'].get('Labels',{}).get('org.fenrir.probe.owner') != owner:
            raise RuntimeError('Owned session identity differs')
        if bool(info['Config'].get('OpenStdin')) != interactive or bool(info['Config'].get('Tty')) != (input_kind=='tty'):
            raise RuntimeError('Session descriptor wiring differs')
        # Inspect all unchanged isolation fields with the existing checker, then
        # separately bind the intentional stdin/TTY-negative settings above.
        check = copy.deepcopy(info)
        check['Config']['OpenStdin'] = False
        check['Config']['Tty'] = False
        policy = feas.check_policy(check,mounts,False)
        policy['stdin_kind'] = input_kind
        policy['tty_negative_only'] = input_kind=='tty'
        code = process.returncode
        if stopped in ['HarnessTimeout','OutputLimit','InputLimit']:
            execution = stopped
        elif error:
            execution = 'GuestRejected' if code==1 and error['kind']=='PrematureExit' else 'StoppedAtDivergence'
        elif code == 0 and (not protocol or trace==expected) and not pending:
            execution = 'Completed'
        elif code == 159:
            execution = 'SandboxDenied'
        elif code in [132,133,134,139]:
            execution = 'CandidateCrash'
        else:
            execution = 'GuestRejected' if code==1 else 'HarnessError'
        return {'execution':execution,'exit':str(code),'trace':trace,'responses':[base64.b64encode(x).decode() for x in sent],
                'first_error':error,'hold_observations':hold_observations,'input_bytes':str(total_input),
                'stdout_bytes':str(len(output)),'stdout_sha256':hashlib.sha256(output).hexdigest(),
                'stderr':err.decode(errors='replace')[:8192],'stdout_preview':bytes(output[:2048]).decode(errors='replace'),
                'delay_seconds':str(delay),'fragmented_input':fragment,
                'raw_input_sha256':hashlib.sha256(raw_input or b'').hexdigest(),
                'policy':policy,'command':argv,'mode':mode,'opt_in':opt_in,'input_kind':input_kind,'cleanup':'confirmed'}
    finally:
        close_input()
        try:
            try:
                os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError:
                pass
            except PermissionError:
                if process.poll() is None:
                    process.kill()
        finally:
            process.wait()
            selector.close()
            process.stdout.close()
            process.stderr.close()
        removed = client.command(['docker','rm','-f',name],15)
        absent = client.command(['docker','inspect',name],15)
        if removed.returncode or not feas.confirms_absent(absent.returncode,absent.stdout,absent.stderr,name):
            raise RuntimeError('Unresolved owned interactive container cleanup')
        groups = subprocess.run(['ps','-axo','pid=,pgid=,stat='],capture_output=True,text=True,timeout=5,check=True)
        if any(len(x.split())==3 and x.split()[1]==str(process.pid) and not x.split()[2].startswith('Z') for x in groups.stdout.splitlines()):
            raise RuntimeError('Unresolved client process group')


def admit_build(path):
    report = json.loads(path.read_bytes())
    if report.get('schema') != 'fenrir.solo5.control-build/1' or report.get('qualification') != 'UNKNOWN' or report.get('cleanup') != 'confirmed' or not report.get('two_tender_builds_equal'):
        raise ValueError('Expected retained development build')
    for p,h in report['sources_after'].items():
        if client.digest(ROOT/p) != h:
            raise RuntimeError('Build source drift: '+p)
    image = json.loads(client.checked(['docker','image','inspect',report['overlay_image']]))[0]
    stock = json.loads(client.checked(['docker','image','inspect',report['stock_image']]))[0]
    if image['RootFS']['Layers'][:-1] != stock['RootFS']['Layers']:
        raise RuntimeError('Image provenance differs')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-report',required=True)
    parser.add_argument('--output-dir',required=True)
    args = parser.parse_args()
    build_path = Path(args.build_report).resolve()
    report_bytes = build_path.read_bytes()
    build_report = admit_build(build_path)
    dest = Path(args.output_dir).resolve()
    if not dest.is_relative_to(ROOT/'build/solo5') or dest==ROOT/'build/solo5' or dest.exists():
        raise ValueError('Fresh output directory required')
    paths = [Path(__file__),ROOT/'tools/solo5/control_protocol.py',ROOT/'tools/solo5/build-control-stdin.py',
             ROOT/'tools/solo5/baseline.py',ROOT/'tools/solo5/transport-feasibility.py',
             *[ROOT/'backends/solo5'/p for p in ['interactive-guest.c','protocol.c','protocol.h']],ROOT/'spec/solo5/protocol-demo.json']
    before = {str(p.relative_to(ROOT)):client.digest(p) for p in paths}
    dest.mkdir(parents=True,exist_ok=False)
    binary,compile_logs = compile_guest(build_report['overlay_image'],dest)
    image = build_report['overlay_image']
    cases = []
    def observe(name,expected,**options):
        r = session(image,binary,**options)
        cases.append({'name':name,'expected_execution':expected,**r})
        if r['execution'] != expected:
            raise RuntimeError('Unexpected measured classification '+name+': '+r['execution'])
        if name.endswith('-startup-rejected') and (r['trace'] or 'Fenrir stdin requires an explicit readable pipe' not in r['stderr']+r['stdout_preview']):
            raise RuntimeError('Startup rejection was not independently observed before guest entry')
        return r
    try:
        observe('opt-in-read','Completed',mode='read-one',raw_input=b'x')
        observe('opt-in-max-read','Completed',mode='read-max',raw_input=b'x')
        observe('default-read-denied','SandboxDenied',mode='read-one',raw_input=b'x',opt_in=False)
        for mode in ['other-fd','oversize','open','socket']:
            observe(mode+'-denied','SandboxDenied',mode=mode,raw_input=b'x')
        for kind in ['regular','tty','closed','missing','write-only']:
            observe(kind+'-startup-rejected','GuestRejected',mode='read-one',input_kind=kind,raw_input=b'x')
        for i in range(10):
            observe('cold-'+str(i),'Completed')
        observe('delayed-responses','Completed',delay=0.2)
        observe('fragmented-input','Completed',fragment=True)
        for fault in [(0,'run_id'),(0,'sequence'),(1,'epoch'),(1,'site'),(1,'domain_hash'),(0,'profile'),(1,'decision'),
                      (0,'unknown'),(0,'kind'),(0,'numeric'),(0,'duplicate'),(0,'length'),
                      (0,'oversize'),(1,'missing'),(0,'reorder'),(0,'truncated'),(3,'suffix')]:
            observe('host-fault-'+str(fault),'GuestRejected',fault=fault)
        for mode in ['early-terminal','wrong-boundary','suffix','malformed-output']:
            observe('guest-'+mode,'StoppedAtDivergence',mode=mode)
        observe('guest-crash','CandidateCrash',mode='crash')
        observe('non-yielding-watchdog','HarnessTimeout',mode='loop',timeout=1)
        observe('output-flood','OutputLimit',mode='flood')
        after = {str(p.relative_to(ROOT)):client.digest(p) for p in paths}
        if before != after or build_path.read_bytes()!=report_bytes:
            raise RuntimeError('Source/build report drift')
        admit_build(build_path)
        guest_hash = client.digest(binary)
        result = {'schema':'fenrir.solo5.interactive-development/1','qualification':'UNKNOWN',
                  'scope':'Closed cooperative pipe transport; no TC0/native determinism qualification','command':sys.argv,
                  'sources_before':before,'sources_after':after,'build_report':str(build_path),
                  'build_report_sha256':hashlib.sha256(report_bytes).hexdigest(),'build_identity':build_report,
                  'image_id':image,'guest_path':str(binary),'guest_sha256':guest_hash,
                  'bounds':{'wall_seconds':'30','output_bytes':'8388608','input_bytes':'262144','guest_memory_mib':'16'},
                  'cases':cases,'cleanup':'confirmed','limitations':['No clock/counter mediation','No independent native instruction control','Protocol fixture not language conformance']}
        (dest/'interactive.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps({'qualification':'UNKNOWN','cases':len(cases),'cleanup':'confirmed','report':str(dest/'interactive.json')}))
    finally:
        (dest/'diagnostics.json').write_text(json.dumps({'compile':compile_logs,'cases':cases},indent=2)+'\n')


if __name__ == '__main__':
    main()
