#!/usr/bin/env python3
"""Independent integrated pure-call development observations, NOT qualification."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('expression_probe',ROOT/'tools/check-tc0-expression.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def atom(s):
    if not isinstance(s,str) or not re.fullmatch('[a-z][a-z0-9_-]*',s):
        raise ValueError('Name outside demonstrated Shen symbol transport scope')
    return 'fn-'+s


def translate(e,codes):
    tag,node,*x=e
    if tag=='lambda':
        body=translate(x[5],codes)
        codes.append('['+node+' ['+x[0]+' '+body+']]')
        rest=x[0]+' '+body
    elif tag=='call':
        rest=atom(x[0])+' '+translate(x[1],codes)
    elif tag=='apply':
        rest=' '.join(translate(c,codes) for c in x)
    elif tag=='let':
        rest=x[0]+' '+translate(x[1],codes)+' '+translate(x[2],codes)
    elif tag=='if':
        rest=' '.join(translate(c,codes) for c in x)
    elif tag=='prim':
        rest=x[0]+' '+' '.join(translate(c,codes) for c in x[1:])
    elif tag=='emit':
        if not re.fullmatch('[A-Za-z_][A-Za-z0-9_]*',x[0]):
            raise ValueError('Label outside demonstrated Shen string scope')
        rest=json.dumps(x[0])+' '+translate(x[1],codes)
    else:
        return probe.shen_expr(e)
    return '['+tag+' '+node+' '+rest+']'


def model_value(v):
    if isinstance(v,list) and len(v)==4 and v[0]=='closure' and v[3]==[]:
        return {'code_id':v[1],'captures':[[k,model_value(x)] for k,x in v[2]],'capture_support':[]}
    return probe.value(v)


def normalize(s,i):
    if s[1][2]=='return-return':
        s[1][2]='collect-return'
        row=probe.normalize(s,i)
        row['site']['rule']='ReturnReturn'
        return row
    return probe.normalize(s,i)


MODEL_FILES=[ROOT/'models/tc0/arithmetic.shen',ROOT/'models/tc0/pure-call-machine.shen',ROOT/'models/tc0/pure-call-oracle.shen']
REFERENCE_STEPS=200


class Oracle:
    """Runs models/tc0/pure-call-oracle.shen over a batch of initial states.

    Exactly one of: a host Shen launcher (runs the driver source), or a
    Yggdrasil-shaken artifact directory built by tools/tc0/build-shaken-oracle.mjs,
    admitted only while its stamp matches the current model sources."""
    def __init__(self,shen=None,artifact=None):
        if (shen is None)==(artifact is None):
            raise ValueError('Exactly one oracle: host Shen executable or shaken artifact')
        self.shen=Path(shen).resolve(strict=True) if shen else None
        self.artifact=Path(artifact).resolve(strict=True) if artifact else None
        if self.artifact:
            stamp=json.loads((self.artifact/'oracle-stamp.json').read_text())
            current={str(p.relative_to(ROOT)):probe.digest(p) for p in MODEL_FILES}
            if stamp.get('schema')!='fenrir.shaken-oracle.v1' or stamp.get('sources')!=current:
                raise RuntimeError('Shaken oracle is stale or foreign; rebuild with tools/tc0/build-shaken-oracle.mjs')
            if probe.digest(self.artifact/'app-lisp')!=stamp.get('artifact_sha256') or probe.digest(self.artifact/'yggdrasil.manifest.txt')!=stamp.get('manifest_sha256'):
                raise RuntimeError('Shaken oracle artifact does not match its stamp')

    def identity_paths(self):
        if self.shen:
            return [self.shen,self.shen.parent.parent/'lib/shen-scheme/shen.boot']
        return [self.artifact/'app-lisp',self.artifact/'yggdrasil.manifest.txt',self.artifact/'oracle-stamp.json']

    def describe(self):
        return {'kind':'host-shen','executable':str(self.shen)} if self.shen else {'kind':'yggdrasil-shaken','artifact':str(self.artifact)}

    def run(self,initials,timeout=30):
        argv=[str(self.shen),'script',str(ROOT/'models/tc0/pure-call-oracle.shen')] if self.shen else [str(self.artifact/'app-lisp')]
        stdin=''.join(f'{REFERENCE_STEPS} {i}\n' for i in initials)+'end\n'
        # Through probe.synchronous so callers that bound subprocesses also bound the oracle.
        out,err=probe.synchronous(argv,timeout=timeout*max(1,len(initials)),stdin=stdin,cwd=ROOT/'models/tc0')
        chunks=out.split('[case-end]\n')
        if len(chunks)!=len(initials)+1:
            raise RuntimeError('Oracle returned '+str(len(chunks)-1)+' cases for '+str(len(initials)))
        return chunks[:-1],err


def initial_state(a):
    codes=[]
    for f in a['functions']:
        body=translate(f['body'],codes)
        codes.append('['+f['id']+' ['+f['parameter_id']+' '+body+']]')
    names='['+' '.join('['+atom(f['name'])+' '+f['id']+']' for f in a['functions'])+']'
    entry=next(f for f in a['functions'] if f['name']==a['entry'])
    return '[pure-call-state [evaluate '+translate(entry['body'],[])+' true] [['+entry['parameter_id']+' [int 0]]] [] ['+' '.join(codes)+'] '+names+']'


def observe(case,oracle,node,scratch,model=None):
    a=case['program']
    filename=scratch/(case['name']+'.json')
    filename.write_text(json.dumps(a,separators=(',',':')))
    # Host validation occurs before translation or model execution.
    stdout,stderr=probe.synchronous([str(node),str(ROOT/'tools/tc0/run-pure-call.mjs'),str(filename)])
    candidate=json.loads(stdout)
    if model is None:
        outs,errs=oracle.run([initial_state(a)])
        model=(outs[0],errs)
    model_stdout,model_stderr=model
    lines=model_stdout.splitlines()
    if not lines or lines[-1].strip()!='terminal':
        raise RuntimeError('Independent model incomplete within '+str(REFERENCE_STEPS)+' steps: '+case['name'])
    steps=[normalize(probe.parse_list(line),i) for i,line in enumerate(x for x in lines if x.startswith('[sample '))]
    descriptors=[model_value(probe.parse_list(line)) for line in lines if line.startswith('[closure ')]
    # Hand fixtures supply an independent expectation; structural reduction trials
    # may instead use the freshly observed model terminal outcome (never candidate).
    expected=case.get('expected_outcome',steps[-1]['events'][0]['outcome'])
    if candidate['execution']!='Completed' or candidate['steps']!=steps or candidate['outcome']!=expected or steps[-1]['events'][0]['outcome']!=expected:
        raise RuntimeError('Independent model/candidate/hand disagreement: '+case['name'])
    if not all(d in descriptors for d in candidate['descriptors']):
        raise RuntimeError('Descriptor not independently observed')
    if 'expected_staging' in case and [[s['after'],s['depth']] for s in steps]!=case['expected_staging']:
        raise RuntimeError('Hand staging mismatch')
    if 'expected_return_frames' in case and sum(s['site']['rule']=='ReturnReturn' for s in steps)!=int(case['expected_return_frames']):
        raise RuntimeError('Return destination count mismatch')
    if 'maximum_depth' in case and max(int(s['depth']) for s in steps)>int(case['maximum_depth']):
        raise RuntimeError('Semantic continuation depth exceeds hand bound')
    if 'expected_descriptor_count' in case and len(candidate['descriptors'])!=int(case['expected_descriptor_count']):
        raise RuntimeError('Descriptor count mismatch')
    if 'expected_emissions' in case and [e['label'] for s in steps for e in s['events'] if e['kind']=='Emit']!=case['expected_emissions']:
        raise RuntimeError('Hand emission order mismatch')
    return {'name':case['name'],'program':a,'input':['int','0'],'hand_expectations':{k:v for k,v in case.items() if k not in ('name','program')},
            'hand_outcome':expected,'candidate':candidate,'model_steps':steps,'model_descriptors':descriptors,
            'shen_stdout':model_stdout,'shen_stderr':model_stderr,'candidate_stderr':stderr}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    which=parser.add_mutually_exclusive_group(required=True)
    which.add_argument('--shen-executable')
    which.add_argument('--oracle-artifact',help='Directory from tools/tc0/build-shaken-oracle.mjs')
    parser.add_argument('--output',required=True)
    args=parser.parse_args()
    dest=Path(args.output).resolve()
    if not dest.is_relative_to(ROOT/'build') or dest.suffix!='.json':
        raise ValueError('Output must be JSON below build')
    oracle=Oracle(shen=args.shen_executable,artifact=args.oracle_artifact)
    node=Path(shutil.which('node')).resolve(strict=True)
    fixture=ROOT/'fixtures/tc0/pure-call-forward.json'
    hand=ROOT/'fixtures/tc0/pure-call-hand-cases.mjs'
    paths=[Path(__file__),ROOT/'tools/check-tc0-expression.py',fixture,hand,
           ROOT/'tools/tc0/run-pure-call.mjs',ROOT/'tools/tc0/pure-call-artifact.mjs',
           ROOT/'tools/tc0/canonical.mjs',ROOT/'runtime/tc0/pure-call-machine.mjs',
           *MODEL_FILES,ROOT/'spec/tc0/pure-call-demo.json',
           ROOT/'tests/tc0/pure-call-machine.test.mjs',ROOT/'tests/tc0/pure-call-artifact.test.mjs',
           *oracle.identity_paths(),node]
    before={str(p):probe.digest(p) for p in paths}
    fixture_stdout,_=probe.synchronous([str(node),'--input-type=module','-e',
        'import {cases} from '+json.dumps(hand.as_uri())+'; console.log(JSON.stringify(cases));'])
    cases=json.loads(fixture_stdout)
    if len(cases)>8:
        raise ValueError('Hand case cap')
    forward={'name':'hand-forward','program':json.loads(fixture.read_text()),'expected_outcome':['Ok',['int','1']],
             'expected_staging':[['Eval','1'],['Value','1'],['Ready','0'],['Eval','0'],['Eval','1'],['Value','1'],['Eval','1'],['Value','1'],['Ready','0'],['Value','0'],['Join','0'],['Terminate','0'],['Terminal','0']]}
    cases=[forward]+cases
    if len({c['name'] for c in cases})!=len(cases) or any(not re.fullmatch('[a-z][a-z0-9-]*',c['name']) for c in cases):
        raise ValueError('Unique safe case IDs required')
    scratch=ROOT/'build/tc0/pure-call-inputs'
    scratch.mkdir(parents=True,exist_ok=True)
    outs,errs=oracle.run([initial_state(c['program']) for c in cases])
    results=[observe(c,oracle,node,scratch,(out,errs)) for c,out in zip(cases,outs)]
    if before!={str(p):probe.digest(p) for p in paths}:
        raise RuntimeError('Source/toolchain drift')
    report={'qualification':'UNKNOWN','scope':'tc0-a-pure-call-demo/1 hand cases; trusted-local development',
            'sources':before,'oracle':oracle.describe(),'bounds':{'reference_steps':str(REFERENCE_STEPS),'cases':str(len(cases)),'wall_seconds_per_process':'30'},
            'cases':results,'limitations':['No complete catalog or integrated strict replay yet','Hand cases are not generated discovery/exhaustive scope','Not full TC0-A or qualified evaluator/isolation']}
    dest.parent.mkdir(parents=True,exist_ok=True)
    dest.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'qualification':'UNKNOWN','independent_case_agreement':len(results),'report':str(dest)}))


if __name__=='__main__':
    main()
