#!/usr/bin/env python3
"""Bounded LOCAL Solo5/SPT spike. No TC0 or whole-machine determinism qualification."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import uuid

ROOT=Path(__file__).resolve().parents[2]
IMAGE='fenrir-solo5-dev:38e0c348be23'
COMMIT='38e0c348be231a2a3c59510a5caabf562792679f'


def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def command(argv, timeout=60):
    return subprocess.run(argv,capture_output=True,text=True,timeout=timeout,check=False)


def docker(argv, timeout=60):
    p=command(['docker',*argv],timeout)
    if p.returncode: raise RuntimeError('Docker infrastructure error: '+p.stderr[-3000:])
    return p.stdout


def frames(output):
    # Tender/banner diagnostics remain separate; every FG-prefixed record is strict.
    lines=output.splitlines(); result=[];i=0
    while i<len(lines):
        line=lines[i];i+=1
        if not line.startswith('FG'): continue
        match=re.fullmatch(r'FG0/1 (0|[1-9][0-9]*)',line)
        if not match or int(match[1])>4096 or i>=len(lines): raise ValueError('Invalid frame header')
        payload=lines[i];i+=1
        if len(payload.encode())!=int(match[1]): raise ValueError('Wrong frame length')
        def pairs(items):
            decoded={}
            for key,val in items:
                if key in decoded: raise ValueError('Duplicate decoded frame key')
                decoded[key]=val
            return decoded
        def forbidden_number(_): raise ValueError('Numeric token in frame')
        result.append(json.loads(payload,object_pairs_hook=pairs,parse_int=forbidden_number,parse_float=forbidden_number,parse_constant=forbidden_number))
    expected=[{'kind':'Pong','sequence':'0','value':'pong'},{'kind':'Terminal','outcome':'Ok','sequence':'1'}]
    if result!=expected: raise ValueError('Wrong sequence/payload/termination framing')
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repeats',type=int,default=10)
    parser.add_argument('--output',default='build/solo5/spike.json')
    args=parser.parse_args()
    if not 1<=args.repeats<=20: parser.error('repeats must be 1..20')
    output=Path(args.output).resolve()
    if not output.is_relative_to(ROOT/'build') or output.suffix!='.json': parser.error('output must be build/*.json')
    output.parent.mkdir(parents=True,exist_ok=True)
    info=json.loads(docker(['image','inspect',IMAGE]))[0]
    if info['Config']['Labels'].get('org.fenrir.solo5.commit')!=COMMIT: raise RuntimeError('Image source label differs')
    if info['Config']['Labels'].get('org.fenrir.buildspec.sha256')!=sha(ROOT/'backends/solo5/Dockerfile'):
        raise RuntimeError('Image build specification differs; run tools/solo5/setup.py')
    image=info['Id'] # execute immutable ID, not mutable tag
    logs=[];cleanup=True
    sources=[ROOT/'backends/solo5/probe.c',ROOT/'backends/solo5/Dockerfile',ROOT/'backends/solo5/profile.json',ROOT/'tools/solo5/setup.py',Path(__file__)]
    before={str(p.relative_to(ROOT)):sha(p) for p in sources}
    with tempfile.TemporaryDirectory(prefix='fg-solo5-',dir=output.parent) as work:
        work=Path(work);(work/'sentinel').write_text('protected-benign-probe\n')
        original=sha(work/'sentinel')
        def run(label, argv, writable=False, mounts=()):
            nonlocal cleanup
            name='fenrir-solo5-'+uuid.uuid4().hex[:16]
            base=['run','--name',name,'--read-only','--network','none','--cap-drop','ALL',
                  '--security-opt','no-new-privileges','--user','65534:65534','--memory','128m','--pids-limit','32']
            if writable: base+=['--tmpfs','/work:rw,nosuid,size=32m,mode=1777']
            for host,target in mounts: base+=['--mount',f'type=bind,src={host},dst={target},readonly']
            try:
                p=command(['docker',*base,image,*argv],60)
                inspected=json.loads(docker(['inspect',name]))[0]
                config=inspected['HostConfig']
                if config['NetworkMode']!='none' or config['Privileged'] or not config['ReadonlyRootfs'] or config['CapDrop']!=['ALL']:
                    raise RuntimeError('Container boundary configuration differs')
                if inspected['Config']['User']!='65534:65534' or 'no-new-privileges' not in config['SecurityOpt'] or config['Devices']:
                    raise RuntimeError('Privilege/device configuration differs')
                if any(m['RW'] for m in inspected['Mounts'] if m['Type']=='bind'): raise RuntimeError('Writable bind input')
                logs.append({'id':label,'exit':str(p.returncode),'stdout':p.stdout,'stderr':p.stderr,
                             'network':'none','readonly_root':True,'privileged':False})
                return p
            finally:
                removed=command(['docker','rm','-f',name],30)
                if removed.returncode: cleanup=False
                left=command(['docker','inspect',name],15)
                if left.returncode==0: cleanup=False
        build_command='set -eu; cd /work; aarch64-solo5-none-static-cc -c /inputs/probe.c -o probe.o; printf \'{"type":"solo5.manifest","version":1,"devices":[]}\\n\' > manifest.json; /opt/solo5-install/bin/solo5-elftool gen-manifest manifest.json manifest.c; aarch64-solo5-none-static-cc -c manifest.c -o manifest.o; aarch64-solo5-none-static-ld -z solo5-abi=spt manifest.o probe.o -o probe.spt; printf "FG_BINARY_BEGIN\\n"; base64 probe.spt; printf "FG_BINARY_END\\n"'
        # One isolated tmpfs build; transfer the bounded binary over captured stdout.
        # Never expose the checkout, Docker socket or evaluator credentials.
        name='fenrir-solo5-build-'+uuid.uuid4().hex[:16]
        try:
            p=command(['docker','run','--name',name,'--read-only','--network','none','--cap-drop','ALL',
                '--security-opt','no-new-privileges','--user','65534:65534','--memory','128m','--pids-limit','32',
                '--tmpfs','/work:rw,nosuid,size=32m,mode=1777',
                '--mount',f'type=bind,src={ROOT/"backends/solo5/probe.c"},dst=/inputs/probe.c,readonly',
                '--env','PATH=/opt/solo5-install/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
                image,'sh','-c',build_command])
            if p.returncode: raise RuntimeError('Guest compilation failed: '+p.stdout+p.stderr)
            matched=re.fullmatch(r'FG_BINARY_BEGIN\n([A-Za-z0-9+/=\n]+)FG_BINARY_END\n',p.stdout)
            if not matched or len(p.stdout)>1024*1024: raise RuntimeError('Invalid binary transfer')
            binary=work/'probe.spt';binary.write_bytes(base64.b64decode(matched[1].replace('\n',''),validate=True))
        finally:
            removed=command(['docker','rm','-f',name],30)
            if removed.returncode: cleanup=False
        guest_hash=sha(binary)
        request='FG0/1 30\n{"kind":"Ping","sequence":"0"}\n'
        peer=['/opt/solo5-install/bin/solo5-spt','--mem=16','/guest/probe.spt']
        mount=[(binary,'/guest/probe.spt'),(work/'sentinel','/authority/sentinel')]
        semantic=[]
        for i in range(args.repeats):
            p=run('repeat-'+str(i),[*peer,request],mounts=mount)
            if p.returncode: raise RuntimeError('Guest execution failed: '+p.stderr)
            semantic.append(frames(p.stdout))
        invalid=run('malformed-startup',[*peer,'FG0/1 99\n{}\n'],mounts=mount)
        if invalid.returncode!=1: raise RuntimeError('Malformed startup was not rejected')
        negative={}
        for mode in ['open','socket']:
            p=run('forbidden-'+mode,[*peer,'probe-forbidden-'+mode],mounts=mount)
            negative[mode]={'exit':str(p.returncode),'expected':'159','denied_by_sigsys':p.returncode==159}
            if p.returncode!=159: raise RuntimeError('Unexpected forbidden syscall classification: '+str(p.returncode))
        clock_values=[]
        for i in range(2):
            p=run('stock-clock-'+str(i),[*peer,'probe-stock-clock'],mounts=mount)
            values=re.findall(r'^FGCLOCK ([0-9]+)$',p.stdout,re.MULTILINE)
            if p.returncode or len(values)!=1: raise RuntimeError('Clock audit failed')
            clock_values+=values
        if sha(work/'sentinel')!=original or sha(binary)!=guest_hash: raise RuntimeError('Protected input drift')
        (output.parent/'probe.spt').write_bytes(binary.read_bytes())
        inventory=run('inventory',['sh','-c','uname -sm; cc --version | head -1; apk info -v; sha256sum /opt/solo5-install/bin/solo5-spt'],mounts=())
        if inventory.returncode: raise RuntimeError('Toolchain inventory failed')
    after={str(p.relative_to(ROOT)):sha(p) for p in sources}
    if before!=after: raise RuntimeError('Source drift during spike')
    report={'schema':'fenrir.solo5.spike/1','scope':'Linux/AArch64 SPT feasibility; startup-only framed exchange',
        'solo5_commit':COMMIT,'image_id':image,'base_image':'alpine@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8',
        'sources':before,'guest_sha256':guest_hash,'repeat_count':str(args.repeats),
        'semantic_frames_identical':all(s==semantic[0] for s in semantic),'semantic_frames':semantic[0],
        'negative_syscall_probes':negative,'protected_sentinel_unchanged':True,
        'stock_wall_clock_samples':clock_values,'stock_wall_clock_varies':len(set(clock_values))>1,
        'determinism_qualification':'UNKNOWN','tc0_qualification':'UNKNOWN',
        'cleanup':'confirmed' if cleanup else 'unresolved',
        'limitations':['SPT is not hardware virtualization or instruction-counted execution',
          'Startup command-line input and console output; no interactive host Run protocol',
          'Stock clocks and direct CPU counter instructions are NOT mediated',
          'Repeated semantic payload agreement is not a whole-machine determinism proof',
          'Only tested access probes are covered; no blanket isolation/security certification',
          'Build APK versions retained in inventory, not a reproducible locked package repository']}
    output.write_text(json.dumps(report,indent=2)+'\n')
    output.with_suffix('.logs.json').write_text(json.dumps(logs,indent=2)+'\n')
    print(json.dumps({'boot':'completed','framed_exchange':'matched','repeats':str(args.repeats),
        'forbidden_syscalls':'SIGSYS','clock_control':'NOT IMPLEMENTED','qualification':'UNKNOWN',
        'cleanup':report['cleanup'],'report':str(output.relative_to(ROOT))}))
    return 0 if cleanup else 2


if __name__=='__main__': raise SystemExit(main())
