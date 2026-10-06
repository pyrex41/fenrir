#!/usr/bin/env python3
"""Offline isolated opt-in tender builds and COPY-only overlay image, DEVELOPMENT."""
import argparse
import base64
import importlib.util
import json
from pathlib import Path
import re
import sys
import uuid
ROOT = Path(__file__).resolve().parents[2]


def load(name,path):
    spec = importlib.util.spec_from_file_location(name,ROOT/path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


client = load('client','tools/solo5/baseline.py')
feas = load('feas','tools/solo5/transport-feasibility.py')
overlay = load('overlay','backends/solo5/overlays/control-stdin/overlay.py')


class Sandbox:
    def __init__(self,image):
        self.image = image
        self.owner = uuid.uuid4().hex
        self.logs = []

    def run(self,label,argv,mounts=(),writable=False):
        name = 'fenrir-solo5-build-'+uuid.uuid4().hex[:16]
        base = ['docker','run','--name',name,'--label','org.fenrir.probe.owner='+self.owner,
                '--read-only','--network','none','--cap-drop','ALL','--security-opt','no-new-privileges',
                '--user','65534:65534','--memory','128m','--pids-limit','32']
        if writable:
            base += ['--tmpfs','/work:rw,nosuid,size=32m,mode=1777']
        for host,target in mounts:
            base += ['--mount',f'type=bind,src={host},dst={target},readonly']
        command = [*base,self.image,*argv]
        try:
            p = client.command(command,timeout=60)
            info = json.loads(client.checked(['docker','inspect',name],15))[0]
            policy = feas.check_policy(info,mounts,writable)
            if info['Image'] != self.image or info['Config']['Labels'].get('org.fenrir.probe.owner') != self.owner:
                raise RuntimeError('Owned immutable container identity differs')
            self.logs.append({'case':label,'command':command,'exit':str(p.returncode),
                              'stdout':p.stdout,'stderr':p.stderr,'policy':policy})
            return p
        finally:
            removed = client.command(['docker','rm','-f',name],15)
            absent = client.command(['docker','inspect',name],15)
            self.logs.append({'case':label+'-cleanup','remove_exit':str(removed.returncode),
                              'inspect_exit':str(absent.returncode),'inspect_stdout':absent.stdout,'inspect_stderr':absent.stderr})
            if removed.returncode or not feas.confirms_absent(absent.returncode,absent.stdout,absent.stderr,name):
                raise RuntimeError('Unresolved owned build cleanup')

    def verify_cleanup(self):
        if client.checked(['docker','ps','-a','--filter','label=org.fenrir.probe.owner='+self.owner,'--format','{{.Names}}']).strip():
            raise RuntimeError('Owned build resources remain')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir',required=True)
    args = parser.parse_args()
    dest = Path(args.output_dir).resolve()
    if not dest.is_relative_to(ROOT/'build/solo5') or dest == ROOT/'build/solo5' or dest.exists():
        raise ValueError('Fresh output directory required')
    vendor = ROOT/'build/vendor/solo5'
    if client.checked(['git','-C',str(vendor),'rev-parse','HEAD']).strip() != client.COMMIT or client.checked(['git','-C',str(vendor),'status','--porcelain','--untracked-files=all']):
        raise RuntimeError('Pristine pinned vendor prerequisite')
    stock = json.loads(client.checked(['docker','image','inspect',client.IMAGE]))[0]
    labels = stock['Config'].get('Labels',{})
    if labels.get('org.fenrir.solo5.commit') != client.COMMIT or labels.get('org.fenrir.buildspec.sha256') != client.digest(ROOT/'backends/solo5/Dockerfile'):
        raise RuntimeError('Stock image identity differs')
    paths = [Path(__file__),ROOT/'tools/solo5/baseline.py',ROOT/'tools/solo5/transport-feasibility.py',
             ROOT/'backends/solo5/overlays/control-stdin/overlay.py',vendor/'tenders/spt/spt_core.c',ROOT/'backends/solo5/Dockerfile']
    before = {str(p.relative_to(ROOT)):client.digest(p) for p in paths}
    patched, patch = overlay.apply((vendor/'tenders/spt/spt_core.c').read_bytes())
    dest.mkdir(parents=True,exist_ok=False)
    (dest/'spt_core.c').write_bytes(patched)
    (dest/'control-stdin.patch').write_text(patch)
    box = Sandbox(stock['Id'])
    try:
        build = ('set -eu; test "$(sha256sum /opt/solo5/tenders/spt/spt_core.c | cut -d\" \" -f1)" = '+overlay.ORIGINAL_SHA256+'; '
                 'mkdir /work/source; cp /opt/solo5/Makeconf /opt/solo5/Makefile.common /work/source/; '
                 'cp -a /opt/solo5/include /opt/solo5/tenders /work/source/; '
                 'chmod -R u+w /work/source; cp /inputs/spt_core.c /work/source/tenders/spt/spt_core.c; '
                 'cd /work/source/tenders; make TOPDIR=/work/source clean >&2; '
                 'make TOPDIR=/work/source -j2 spt/solo5-spt >&2; '
                 'printf "FG_BINARY_BEGIN\\n"; base64 spt/solo5-spt; printf "FG_BINARY_END\\n"')
        binaries = []
        for i in range(2):
            p = box.run('tender-build-'+str(i),['sh','-c',build],[(dest/'spt_core.c','/inputs/spt_core.c')],True)
            if p.returncode:
                raise RuntimeError('Isolated tender compilation failed: '+p.stderr[-3000:])
            match = re.fullmatch(r'FG_BINARY_BEGIN\n([A-Za-z0-9+/=\n]+)FG_BINARY_END\n',p.stdout)
            if not match or len(p.stdout) > 1048576:
                raise ValueError('Invalid bounded tender transfer')
            binaries.append(base64.b64decode(match[1].replace('\n',''),validate=True))
        if binaries[0] != binaries[1]:
            raise RuntimeError('Two isolated patched tender builds differ')
        context = dest/'image-context'
        context.mkdir()
        tender = context/'solo5-spt-control'
        tender.write_bytes(binaries[0])
        tender.chmod(0o755)
        # Verified local base tag, no RUN/install/pull step. Verify both before
        # and after build plus exact inherited layer prefix; execute only image ID.
        recipe = ('FROM '+client.IMAGE+'\nCOPY --chmod=0555 solo5-spt-control /opt/fenrir/solo5-spt-control\n'
                  'LABEL org.fenrir.control-stdin="development-pipe-only"\n')
        (context/'Dockerfile').write_text(recipe)
        tag = 'fenrir-solo5-control:'+uuid.uuid4().hex[:16]
        p = client.command(['docker','build','--network=none','--pull=false','-t',tag,str(context)],120)
        box.logs.append({'case':'copy-only-image-build','exit':str(p.returncode),'stdout':p.stdout,'stderr':p.stderr})
        if p.returncode:
            raise RuntimeError('COPY-only local image build failed')
        image = json.loads(client.checked(['docker','image','inspect',tag]))[0]
        if json.loads(client.checked(['docker','image','inspect',client.IMAGE]))[0]['Id'] != stock['Id']:
            raise RuntimeError('Stock image tag drift')
        layers = stock['RootFS']['Layers']
        if image['RootFS']['Layers'][:-1] != layers or image['Config']['Labels'].get('org.fenrir.control-stdin') != 'development-pipe-only':
            raise RuntimeError('Overlay image does not extend exact stock layer identity')
        overlay_box = Sandbox(image['Id'])
        inventory = overlay_box.run('inventory',['sh','-c',
            'cc --version | head -1; pkgconf --modversion libseccomp; sha256sum /opt/fenrir/solo5-spt-control /opt/solo5-install/bin/solo5-spt; sha256sum /lib/ld-musl-aarch64.so.1 /usr/lib/libseccomp.so.*'])
        if inventory.returncode or client.digest(tender) not in inventory.stdout:
            raise RuntimeError('Installed tender/toolchain inventory mismatch')
        box.logs.extend(overlay_box.logs)
        overlay_box.verify_cleanup()
        box.verify_cleanup()
        after = {str(p.relative_to(ROOT)):client.digest(p) for p in paths}
        if before != after or client.checked(['git','-C',str(vendor),'status','--porcelain','--untracked-files=all']):
            raise RuntimeError('Protected stock/vendor source drift')
        report = {'schema':'fenrir.solo5.control-build/1','qualification':'UNKNOWN','sources_before':before,'sources_after':after,
                  'solo5_commit':client.COMMIT,'stock_image':stock['Id'],'overlay_image':image['Id'],'overlay_tag_advisory':tag,
                  'tender_sha256':client.digest(tender),'patched_source_sha256':client.digest(dest/'spt_core.c'),
                  'patch_sha256':client.digest(dest/'control-stdin.patch'),'recipe_sha256':client.digest(context/'Dockerfile'),
                  'two_tender_builds_equal':True,'toolchain_inventory':inventory.stdout,'command':sys.argv,
                  'cleanup':'confirmed','scope':'Opt-in pipe-only input policy; stock clocks/counters unmediated',
                  'limitations':['No interactive/semantic/native instruction-control qualification','Build repeatability under installed immutable dependencies only']}
        (dest/'build.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps({'qualification':'UNKNOWN','two_builds_equal':True,'overlay_image':image['Id'],'report':str(dest/'build.json'),'cleanup':'confirmed'}))
    finally:
        (dest/'diagnostics.json').write_text(json.dumps(box.logs,indent=2)+'\n')


if __name__ == '__main__':
    main()
