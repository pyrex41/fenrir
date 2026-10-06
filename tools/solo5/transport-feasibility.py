#!/usr/bin/env python3
"""Stock SPT no-device stdin-denial/control probe; not interactive transport success."""
import argparse
import base64
import importlib.util
import json
from pathlib import Path
import re
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('baseline_client', ROOT/'tools/solo5/baseline.py')
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
READY = {'kind':'ProbeReady','sequence':'0'}
CONTROL = [READY, {'kind':'Terminal','outcome':'Ok','sequence':'1'}]
ATTEMPT = [READY, {'fd':'0','kind':'InputAttempt','sequence':'1'}]


def parse_frames(raw):
    lines = raw.splitlines()
    result, i = [], 0
    def pairs(items):
        d = {}
        for k,v in items:
            if k in d:
                raise ValueError('Duplicate decoded key')
            d[k] = v
        return d
    def number(_):
        raise ValueError('Numeric tokens unsupported')
    while i < len(lines):
        line = lines[i]
        i += 1
        if not line.startswith('FG'):
            continue  # Stock tender banner; retained verbatim in diagnostics.
        match = re.fullmatch(r'FGIO0/1 (0|[1-9][0-9]*)',line)
        if not match or int(match[1]) > 4096 or i >= len(lines):
            raise ValueError('Malformed or oversized capability-probe framing')
        payload = lines[i]
        i += 1
        if len(payload.encode()) != int(match[1]):
            raise ValueError('Probe payload length mismatch')
        result.append(json.loads(payload,object_pairs_hook=pairs,parse_int=number,parse_float=number,parse_constant=number))
    return result


def classify(mode, exit_code, stdout):
    observed = parse_frames(stdout)
    if mode == 'control' and exit_code == 0 and observed == CONTROL:
        return 'stock-console-control-completed'
    if mode == 'read-stdin' and exit_code == 159 and observed == ATTEMPT:
        return 'stock-read-fd0-denied-by-sigsys'
    if mode == 'invalid' and exit_code == 1 and observed == []:
        return 'startup-mode-rejected'
    raise ValueError('Unexpected capability/lifecycle classification; no success credit')


def check_policy(info, mounts, writable):
    h, c = info['HostConfig'], info['Config']
    if (h['NetworkMode'] != 'none' or h['Privileged'] or not h['ReadonlyRootfs']
            or h['CapDrop'] != ['ALL'] or c['User'] != '65534:65534'
            or 'no-new-privileges' not in h['SecurityOpt'] or h['Devices']
            or h['Memory'] != 134217728 or h['PidsLimit'] != 32
            or c.get('OpenStdin') or c.get('Tty')):
        raise ValueError('Required stock sandbox/container policy differs')
    binds = {(m['Source'],m['Destination']):m['RW'] for m in info['Mounts'] if m['Type'] == 'bind'}
    if binds != {(str(host),target):False for host,target in mounts}:
        raise ValueError('Unexpected or writable bind mount')
    if set(h.get('Tmpfs') or {}) != ({'/work'} if writable else set()):
        raise ValueError('Unexpected writable tmpfs')
    return {'network':'none','user':'65534:65534','readonly_root':True,'cap_drop':['ALL'],
            'no_new_privileges':True,'devices':[],'memory_mib':'128','pids_limit':'32',
            'stdin':'closed by Docker for stock denial preflight; no host responses supplied',
            'bind_inputs':[{'source':str(p),'destination':t,'readonly':True} for p,t in mounts]}


def confirms_absent(exit_code, stdout, stderr, name):
    # Docker CLI capitalization varies. Require a successful absence-shaped
    # response naming this exact owned object, not an arbitrary daemon error.
    return (exit_code == 1 and stdout.strip() == '[]'
            and re.fullmatch(r'(?:error: )?no such object: '+re.escape(name),stderr.strip(),re.IGNORECASE) is not None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir',required=True)
    args = parser.parse_args()
    dest = Path(args.output_dir).resolve()
    if not dest.is_relative_to(ROOT/'build/solo5') or dest == ROOT/'build/solo5' or dest.exists():
        raise ValueError('Fresh output directory below build/solo5 required')
    vendor = ROOT/'build/vendor/solo5'
    if client.checked(['git','-C',str(vendor),'rev-parse','HEAD']).strip() != client.COMMIT or client.checked(['git','-C',str(vendor),'status','--porcelain','--untracked-files=all']):
        raise RuntimeError('Pinned pristine vendor prerequisite not met')
    image_info = json.loads(client.checked(['docker','image','inspect',client.IMAGE]))[0]
    labels = image_info['Config'].get('Labels',{})
    if labels.get('org.fenrir.solo5.commit') != client.COMMIT or labels.get('org.fenrir.buildspec.sha256') != client.digest(ROOT/'backends/solo5/Dockerfile'):
        raise RuntimeError('Installed image identity differs')
    image = image_info['Id']
    paths = [Path(__file__),ROOT/'tools/solo5/baseline.py',ROOT/'backends/solo5/interactive-probe.c',
             ROOT/'backends/solo5/Dockerfile',ROOT/'backends/solo5/profile.json',
             vendor/'tenders/spt/spt_core.c',vendor/'tenders/spt/spt_module_net.c']
    before = {str(p.relative_to(ROOT)):client.digest(p) for p in paths}
    dest.mkdir(parents=True,exist_ok=False)
    owner = uuid.uuid4().hex
    logs, names = [], []
    def run(label, argv, mounts=(), writable=False):
        name = 'fenrir-solo5-feas-'+uuid.uuid4().hex[:16]
        names.append(name)
        base = ['docker','run','--name',name,'--label','org.fenrir.probe.owner='+owner,
                '--read-only','--network','none','--cap-drop','ALL','--security-opt','no-new-privileges',
                '--user','65534:65534','--memory','128m','--pids-limit','32']
        if writable:
            base += ['--tmpfs','/work:rw,nosuid,size=32m,mode=1777',
                     '--env','PATH=/opt/solo5-install/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin']
        for host,target in mounts:
            base += ['--mount',f'type=bind,src={host},dst={target},readonly']
        command = [*base,image,*argv]
        try:
            p = client.command(command,timeout=30)
            info = json.loads(client.checked(['docker','inspect',name],timeout=15))[0]
            policy = check_policy(info,mounts,writable)
            if info['Config'].get('Labels',{}).get('org.fenrir.probe.owner') != owner or info['Image'] != image:
                raise RuntimeError('Owned container identity changed')
            logs.append({'case':label,'command':command,'container':name,'exit':str(p.returncode),
                         'stdout':p.stdout,'stderr':p.stderr,'policy':policy})
            return p
        finally:
            removed = client.command(['docker','rm','-f',name],timeout=15)
            remaining = client.command(['docker','inspect',name],timeout=15)
            logs.append({'case':label+'-cleanup','remove_exit':str(removed.returncode),
                         'inspect_exit':str(remaining.returncode),'inspect_stdout':remaining.stdout,
                         'inspect_stderr':remaining.stderr})
            if removed.returncode or not confirms_absent(remaining.returncode,remaining.stdout,remaining.stderr,name):
                raise RuntimeError('Unresolved owned container cleanup; stop')
    build = ('set -eu; cd /work; aarch64-solo5-none-static-cc -c /inputs/probe.c -o probe.o; '
             'printf \'{"type":"solo5.manifest","version":1,"devices":[]}\\n\' > manifest.json; '
             '/opt/solo5-install/bin/solo5-elftool gen-manifest manifest.json manifest.c; '
             'aarch64-solo5-none-static-cc -c manifest.c -o manifest.o; '
             'aarch64-solo5-none-static-ld -z solo5-abi=spt manifest.o probe.o -o probe.spt; '
             'printf "FG_BINARY_BEGIN\\n"; base64 probe.spt; printf "FG_BINARY_END\\n"')
    try:
        p = run('compile',['sh','-c',build],[(ROOT/'backends/solo5/interactive-probe.c','/inputs/probe.c')],True)
        if p.returncode:
            raise RuntimeError('Capability probe compilation failed: '+p.stderr[-2000:])
        matched = re.fullmatch(r'FG_BINARY_BEGIN\n([A-Za-z0-9+/=\n]+)FG_BINARY_END\n',p.stdout)
        if not matched or len(p.stdout) > 1048576:
            raise ValueError('Invalid bounded guest transfer')
        binary = dest/'probe.spt'
        binary.write_bytes(base64.b64decode(matched[1].replace('\n',''),validate=True))
        guest_hash = client.digest(binary)
        cases = []
        for label, mode in [('control','control'),('stdin-denial-one','read-stdin'),
                            ('stdin-denial-two','read-stdin'),('invalid-mode','invalid')]:
            p = run(label,['/opt/solo5-install/bin/solo5-spt','--mem=16','/guest/probe.spt',mode],[(binary,'/guest/probe.spt')])
            cases.append({'name':label,'mode':mode,'exit':str(p.returncode),
                          'classification':classify(mode,p.returncode,p.stdout),'frames':parse_frames(p.stdout)})
        if guest_hash != client.digest(binary):
            raise RuntimeError('Read-only guest drift')
        after = {str(p.relative_to(ROOT)):client.digest(p) for p in paths}
        if before != after:
            raise RuntimeError('Probe source drift')
        if client.checked(['docker','ps','-a','--filter','label=org.fenrir.probe.owner='+owner,'--format','{{.Names}}']).strip():
            raise RuntimeError('Owned probe resources remain')
        result = {'schema':'fenrir.solo5.transport-feasibility/1','qualification':'UNKNOWN',
                  'interactive_transport':'BLOCKED_PENDING_BOUNDARY_REVIEW',
                  'scope':'Stock no-device SPT capability/denial preflight, NOT an interactive exchange',
                  'command':sys.argv,'sources_before':before,'sources_after':after,'solo5_commit':client.COMMIT,
                  'image_id':image,'guest_sha256':guest_hash,'cases':cases,
                  'bounds':{'guest_memory_mib':'16','process_wall_seconds':'30','output_bytes':'8388608','cases':'4'},
                  'cleanup':'confirmed','limitations':[
                    'No host responses supplied; Docker stdin closed. Seccomp denial is observed before read could return EOF',
                    'No two-boundary handshake, framing-adversary or virtual-clock success claim',
                    'No tender/bindings/syscall expansion applied; no network/block transport workaround',
                    'Raw native CPU counters and stock clocks remain unmediated',
                    'Guest SIGSYS is an expected capability denial, not language conformance or a semantic mutant kill'],
                  'review_next':'Review explicit descriptor/channel policy and project-owned tender overlay before granting input reads'}
        with (dest/'feasibility.json').open('x') as f:
            f.write(json.dumps(result,indent=2)+'\n')
        print(json.dumps({'qualification':'UNKNOWN','stock_input_read':'SIGSYS159',
                          'interactive_transport':result['interactive_transport'],'cleanup':'confirmed','report':str(dest/'feasibility.json')}))
    finally:
        with (dest/'diagnostics.json').open('x') as f:
            f.write(json.dumps({'owner':owner,'containers':names,'logs':logs},indent=2)+'\n')


if __name__ == '__main__':
    main()
