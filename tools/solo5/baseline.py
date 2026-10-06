#!/usr/bin/env python3
"""Fresh stock Solo5/SPT baseline evidence; DEVELOPMENT only, no authority changes."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
COMMIT = '38e0c348be231a2a3c59510a5caabf562792679f'
IMAGE = 'fenrir-solo5-dev:38e0c348be23'


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def command(argv, timeout=60):
    """Synchronous bounded local client, process-group join; no background jobs."""
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        process = subprocess.Popen(argv, cwd=ROOT, stdout=stdout, stderr=stderr, start_new_session=True)
        deadline = time.monotonic()+timeout
        try:
            while True:
                if os.fstat(stdout.fileno()).st_size+os.fstat(stderr.fileno()).st_size > 8388608:
                    raise RuntimeError('Client output cap; incomplete infrastructure outcome')
                if time.monotonic() > deadline:
                    raise TimeoutError('Client watchdog; not semantic time')
                if process.poll() is not None:
                    break
                time.sleep(0.01)
            stdout.seek(0)
            stderr.seek(0)
            return subprocess.CompletedProcess(argv, process.returncode, stdout.read().decode(), stderr.read().decode())
        finally:
            try:
                # Darwin may report EPERM for a group whose leader exited
                # between output-limit detection and killpg. Always reap first
                # and independently verify that no live group members remain.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    if process.poll() is None:
                        process.kill()
            finally:
                process.wait()
            inventory = subprocess.run(['ps','-axo','pid=,pgid=,stat='],capture_output=True,text=True,timeout=5,check=True)
            members = [line for line in inventory.stdout.splitlines()
                       if len(line.split()) == 3 and line.split()[1] == str(process.pid)
                       and not line.split()[2].startswith('Z')]
            if members:
                raise RuntimeError('Unresolved owned client process-group cleanup')


def checked(argv, timeout=60):
    p = command(argv, timeout)
    if p.returncode:
        raise RuntimeError('Prerequisite/command failure: '+p.stderr[-2000:])
    return p.stdout


def validate_report(r, count):
    expected = [{'kind':'Pong','sequence':'0','value':'pong'},
                {'kind':'Terminal','outcome':'Ok','sequence':'1'}]
    if (r.get('solo5_commit') != COMMIT or r.get('repeat_count') != str(count)
            or r.get('cleanup') != 'confirmed' or r.get('semantic_frames') != expected
            or r.get('semantic_frames_identical') is not True
            or r.get('protected_sentinel_unchanged') is not True
            or r.get('determinism_qualification') != 'UNKNOWN' or r.get('tc0_qualification') != 'UNKNOWN'):
        raise ValueError('Stock report does not meet bounded hand expectations')
    for mode in ['open','socket']:
        row = r.get('negative_syscall_probes', {}).get(mode, {})
        if row != {'exit':'159','expected':'159','denied_by_sigsys':True}:
            raise ValueError('Forbidden syscall classification differs')


def compare_builds(first, second):
    for k in ['guest_sha256','image_id','sources','semantic_frames']:
        if first[k] != second[k]:
            raise ValueError('Independent stock build identity/payload differs: '+k)
    return {'independent_guest_builds_equal':True,'guest_sha256':first['guest_sha256'],
            'semantic_payloads_equal':True,
            'reproducibility_scope':'Two clean guest builds under one content-addressed installed image; not rebuild of APK repositories or cross-host reproducibility'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', required=True)
    args = parser.parse_args()
    dest = Path(args.output_dir).resolve()
    if not dest.is_relative_to(ROOT/'build/solo5') or dest == ROOT/'build/solo5' or dest.exists():
        raise ValueError('Fresh directory below build/solo5 required')
    vendor = ROOT/'build/vendor/solo5'
    platform = checked(['docker','info','--format','{{.OSType}}/{{.Architecture}}']).strip()
    if platform not in ['linux/aarch64','linux/arm64']:
        raise RuntimeError('Required Docker Linux/AArch64 target unavailable')
    if checked(['git','-C',str(vendor),'rev-parse','HEAD']).strip() != COMMIT:
        raise RuntimeError('Pinned Solo5 checkout unavailable')
    if checked(['git','-C',str(vendor),'status','--porcelain','--untracked-files=all']):
        raise RuntimeError('Vendor dirty; no upstream edit is authorized')
    info = json.loads(checked(['docker','image','inspect',IMAGE]))[0]
    labels = info['Config'].get('Labels', {})
    if labels.get('org.fenrir.solo5.commit') != COMMIT or labels.get('org.fenrir.buildspec.sha256') != digest(ROOT/'backends/solo5/Dockerfile'):
        raise RuntimeError('Installed immutable image does not match pinned build specification')
    # Do not invoke setup.py: it may install moving dependencies or overwrite historical evidence.
    before_containers = checked(['docker','ps','-a','--filter','name=fenrir-solo5','--format','{{.Names}}']).splitlines()
    if before_containers:
        raise RuntimeError('Existing Solo5 probe containers require ownership/cleanup review')
    audit_files = ['bindings/spt/bindings.c','bindings/spt/net.c','bindings/crt_init.h',
                   'bindings/cpu_aarch64.h','tenders/spt/spt_core.c','tenders/spt/spt_module_net.c']
    paths = [Path(__file__),ROOT/'tools/solo5/spike.py',ROOT/'tools/solo5/setup.py',
             ROOT/'backends/solo5/probe.c',ROOT/'backends/solo5/Dockerfile',ROOT/'backends/solo5/profile.json',
             *[vendor/p for p in audit_files]]
    before = {str(p.relative_to(ROOT)):digest(p) for p in paths}
    dest.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('stock_spike', ROOT/'tools/solo5/spike.py')
    spike = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(spike)
    spike.command = command
    reports = []
    original_argv = sys.argv
    try:
        for label, count in [('build-one',10),('build-two',1)]:
            report_path = dest/label/'spike.json'
            sys.argv = ['tools/solo5/spike.py','--repeats',str(count),'--output',str(report_path)]
            if spike.main() != 0:
                raise RuntimeError('Stock spike cleanup unresolved; stop')
            r = json.loads(report_path.read_text())
            validate_report(r,count)
            reports.append(r)
    finally:
        sys.argv = original_argv
    remaining = checked(['docker','ps','-a','--filter','name=fenrir-solo5','--format','{{.Names}}']).splitlines()
    if remaining:
        raise RuntimeError('Probe containers remain; unresolved cleanup, do not continue')
    after = {str(p.relative_to(ROOT)):digest(p) for p in paths}
    if before != after:
        raise RuntimeError('Source drift')
    comparison = compare_builds(*reports)
    result = {'schema':'fenrir.solo5.baseline-development/1','qualification':'UNKNOWN',
              'scope':'Stock Linux/AArch64 SPT baseline; startup-only transport, NOT deterministic runtime',
              'sources_before':before,'sources_after':after,'command':original_argv,
              'platform':platform,'image_id':info['Id'],'solo5_commit':COMMIT,
              'bounds':{'cold_runs':'11','clean_guest_builds':'2','guest_memory_mib':'16',
                        'client_output_bytes':'8388608','container_memory_mib':'128','network':'none',
                        'compile_and_guest_client_wall_seconds':'60'},
              'comparison':comparison,'baseline_reports':['build-one/spike.json','build-two/spike.json'],
              'audit_inventory':[
                {'source':'bindings/spt/bindings.c','finding':'Clock APIs call Linux CLOCK_MONOTONIC/REALTIME; supported time not mediated'},
                {'source':'bindings/spt/net.c','finding':'Yield uses absolute host-monotonic timerfd/epoll readiness'},
                {'source':'bindings/crt_init.h','finding':'Stack canary uses native CPU ticks at startup; affects machine state'},
                {'source':'bindings/cpu_aarch64.h','finding':'cntvct_el0 direct register read; seccomp does not intercept it'},
                {'source':'tenders/spt/spt_core.c','finding':'Allows console write fd1 and stock clocks; no core read fd0 rule'},
                {'source':'tenders/spt/spt_module_net.c','finding':'Network module expands descriptor operations; no network device authorized here'}],
              'requirements':{'stock_boot':'demonstrated','startup_framing':'demonstrated',
                              'two_guest_build_repeatability':'demonstrated_in_installed_image',
                              'interactive_transport':'UNKNOWN','virtual_clocks':'not_implemented',
                              'native_instruction_control':'not_implemented','qualified_isolation':'UNKNOWN'},
              'cleanup':'confirmed','limitations':[
                'Source audit is a partial inventory, not exhaustive library/instruction closure',
                'No image/package-repository reproducibility or cross-host claim',
                'No arbitrary native-code determinism or semantic qualification',
                'Boundary expansion requires review before applying any tender/bindings overlay']}
    with (dest/'baseline.json').open('x') as f:
        f.write(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'qualification':'UNKNOWN','two_builds_equal':True,'cold_runs':11,
                      'cleanup':'confirmed','report':str(dest/'baseline.json')}))


if __name__ == '__main__':
    main()
