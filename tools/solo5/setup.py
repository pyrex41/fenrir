#!/usr/bin/env python3
"""Set up the pinned local SPT development image, then run the bounded spike."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[2]
COMMIT='38e0c348be231a2a3c59510a5caabf562792679f'
IMAGE='fenrir-solo5-dev:38e0c348be23'


def run(argv, **kwargs):
    return subprocess.run(argv,cwd=ROOT,check=True,timeout=kwargs.pop('timeout',60),**kwargs)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repeats',type=int,default=10)
    args=parser.parse_args()
    if not 1<=args.repeats<=20: parser.error('repeats must be 1..20')
    output=ROOT/'build/solo5';output.mkdir(parents=True,exist_ok=True)
    platform=run(['docker','info','--format','{{.OSType}}/{{.Architecture}}'],capture_output=True,text=True).stdout.strip()
    if platform not in ['linux/aarch64','linux/arm64']: raise RuntimeError('This measured probe requires a Linux/AArch64 Docker server; platform is '+platform)
    vendor=ROOT/'build/vendor/solo5'
    if not vendor.exists():
        vendor.parent.mkdir(parents=True,exist_ok=True)
        run(['git','clone','--depth','1','--branch','v0.9.3','https://github.com/Solo5/solo5.git',str(vendor)],timeout=120)
    actual=run(['git','-C',str(vendor),'rev-parse','HEAD'],capture_output=True,text=True).stdout.strip()
    dirty=run(['git','-C',str(vendor),'status','--porcelain','--untracked-files=all'],capture_output=True,text=True).stdout
    if actual!=COMMIT or dirty: raise RuntimeError('Vendor source differs from the pinned pristine commit; will not overwrite it')
    dockerfile=ROOT/'backends/solo5/Dockerfile'
    spec_hash=hashlib.sha256(dockerfile.read_bytes()).hexdigest()
    inspected=subprocess.run(['docker','image','inspect',IMAGE],cwd=ROOT,capture_output=True,text=True,timeout=15)
    labels=json.loads(inspected.stdout)[0]['Config'].get('Labels',{}) if inspected.returncode==0 else {}
    if labels.get('org.fenrir.solo5.commit')!=COMMIT or labels.get('org.fenrir.buildspec.sha256')!=spec_hash:
        with (output/'build.log').open('w') as log:
            run(['docker','build','--progress=plain','--build-arg','FENRIR_BUILD_SPEC_SHA256='+spec_hash,
                '-t',IMAGE,'-f',str(dockerfile),str(vendor)],timeout=300,stdout=log,stderr=subprocess.STDOUT)
    info=json.loads(run(['docker','image','inspect',IMAGE],capture_output=True,text=True).stdout)[0]
    (output/'setup.json').write_text(json.dumps({'schema':'fenrir.solo5.setup/1','solo5_commit':COMMIT,
        'image_id':info['Id'],'dockerfile_sha256':spec_hash,'qualification':'UNKNOWN',
        'limits':'Pinned base/source, APK versions inventoried by spike; no full reproducible-build claim'},indent=2)+'\n')
    run([sys.executable,str(ROOT/'tools/solo5/spike.py'),'--repeats',str(args.repeats),'--output',str(output/'spike.json')],timeout=240)


if __name__=='__main__': main()
