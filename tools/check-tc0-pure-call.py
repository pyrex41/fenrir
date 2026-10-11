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


def name(s):
    # Datatype/constructor names travel as Shen strings and print bare with ~A.
    if not isinstance(s,str) or not re.fullmatch('[A-Za-z_][A-Za-z0-9_]*',s):
        raise ValueError('Name outside demonstrated Shen string scope')
    return json.dumps(s)


def octets(h):
    if not re.fullmatch('(?:[0-9a-f]{2})*',h):
        raise ValueError('Bytes outside canonical hex')
    return '['+' '.join(str(b) for b in bytes.fromhex(h))+']'


def translate(e,codes):
    tag,node,*x=e
    if tag=='bytes':
        rest=octets(x[0])
    elif tag=='tuple':
        rest=' '.join(translate(c,codes) for c in x)
    elif tag=='project':
        rest=translate(x[0],codes)+' '+str(int(x[1]))
    elif tag=='construct':
        rest=' '.join([name(x[0]),name(x[1])]+[translate(c,codes) for c in x[2:]])
    elif tag=='match':
        rest=translate(x[0],codes)+' ['+' '.join('['+name(c)+' ['+' '.join(b)+'] '+translate(body,codes)+']' for c,b,body in x[1:])+']'
    elif tag=='lambda':
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
    if isinstance(v,list) and len(v)==2 and v[0]=='bytes' and isinstance(v[1],list):
        return ['bytes',bytes(int(o) for o in v[1]).hex()]
    if isinstance(v,list) and len(v)>=2 and v[0]=='tuple':
        return ['tuple',*map(model_value,v[1:])]
    if isinstance(v,list) and len(v)>=3 and v[0]=='data':
        return ['data',v[1],v[2],*map(model_value,v[3:])]
    return probe.value(v)


TRAPS={'div-zero':'DivZero','overflow':'Overflow','bounds':'Bounds'}


def outcome(o):
    return ['Ok',model_value(o[1])] if o[0]=='ok' else ['Trap',TRAPS[o[1]]]


def event(e):
    if e[0] in ('scope-exit','task-termination'):
        row={'kind':{'scope-exit':'ScopeExit','task-termination':'TaskTermination'}[e[0]],'task':'0','outcome':outcome(e[1])}
        if e[0]=='scope-exit': row['scope']='0'
        return row
    if e[0] in ('invoke','emit'):
        row={'kind':'Invoke' if e[0]=='invoke' else 'Emit','task':'0','node':e[1],'label':e[2],'value':model_value(e[3])}
        if e[0]=='invoke': row['operation']='emit'
        return row
    if e[0]=='commit':
        return {'kind':'Commit','task':'0','node':e[1],'operation':'emit','value':model_value(e[2])}
    raise ValueError('Unknown model event')


RULES={'return-return':'ReturnReturn','match-return':'MatchReturn'}


def normalize(s,i):
    # Shared site/phase spelling from the expression probe; values, outcomes and
    # pure-call-only frame rules are decoded here.
    events,s[4]=s[4],[]
    special=RULES.get(s[1][2]) if s[1][0]=='node' else None
    if special:
        s[1][2]='collect-return'
    row=probe.normalize(s,i)
    if special:
        row['site']['rule']=special
    row['events']=[event(e) for e in events]
    return row


# When true, every candidate run goes through tools/tc0/sandbox.mjs: no network, no
# environment, reads only the candidate tree and the program, no writes or processes.
SANDBOX=False


def candidate_argv(node,filename):
    script=ROOT/'tools/tc0/run-pure-call.mjs'
    if not SANDBOX:
        return [str(node),str(script),str(filename)]
    return [str(node),str(ROOT/'tools/tc0/sandbox.mjs'),'--read',str(ROOT/'tools/tc0'),str(ROOT/'runtime/tc0'),str(filename),'--',str(script),str(filename)]


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


def initial_value(v):
    tag,*x=v
    if tag=='int': return '[int '+x[0]+']'
    if tag=='bool': return '[bool '+('true' if x[0] else 'false')+']'
    if tag=='unit': return '[unit]'
    if tag=='bytes': return '[bytes '+octets(x[0])+']'
    if tag=='tuple': return '[tuple '+' '.join(map(initial_value,x))+']'
    if tag=='data': return '[data '+' '.join([name(x[0]),name(x[1])]+[initial_value(f) for f in x[2:]])+']'
    raise ValueError('Unsupported input value')


def initial_state(a,input_value=('int','0')):
    codes=[]
    for f in a['functions']:
        body=translate(f['body'],codes)
        codes.append('['+f['id']+' ['+f['parameter_id']+' '+body+']]')
    names='['+' '.join('['+atom(f['name'])+' '+f['id']+']' for f in a['functions'])+']'
    entry=next(f for f in a['functions'] if f['name']==a['entry'])
    return '[pure-call-state [evaluate '+translate(entry['body'],[])+' true] [['+entry['parameter_id']+' '+initial_value(list(input_value))+']] [] ['+' '.join(codes)+'] '+names+']'


def observe(case,oracle,node,scratch,model=None):
    a=case['program']
    filename=scratch/(case['name']+'.json')
    filename.write_text(json.dumps(a,separators=(',',':')))
    # Host validation occurs before translation or model execution.
    stdout,stderr=probe.synchronous(candidate_argv(node,filename))
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
    parser.add_argument('--sandbox',action='store_true',help='Run each candidate inside tools/tc0/sandbox.mjs')
    args=parser.parse_args()
    global SANDBOX
    SANDBOX=args.sandbox
    dest=Path(args.output).resolve()
    if not dest.is_relative_to(ROOT/'build') or dest.suffix!='.json':
        raise ValueError('Output must be JSON below build')
    oracle=Oracle(shen=args.shen_executable,artifact=args.oracle_artifact)
    node=Path(shutil.which('node')).resolve(strict=True)
    fixture=ROOT/'fixtures/tc0/pure-call-forward.json'
    hand=ROOT/'fixtures/tc0/pure-call-hand-cases.mjs'
    data_hand=ROOT/'fixtures/tc0/pure-data-hand-cases.mjs'
    paths=[Path(__file__),ROOT/'tools/check-tc0-expression.py',fixture,hand,data_hand,
           ROOT/'tools/tc0/run-pure-call.mjs',ROOT/'tools/tc0/pure-call-artifact.mjs',
           ROOT/'tools/tc0/canonical.mjs',ROOT/'runtime/tc0/pure-call-machine.mjs',
           *MODEL_FILES,ROOT/'spec/tc0/pure-call-demo.json',
           ROOT/'tests/tc0/pure-call-machine.test.mjs',ROOT/'tests/tc0/pure-call-artifact.test.mjs',ROOT/'tests/tc0/pure-data.test.mjs',
           *oracle.identity_paths(),node]
    before={str(p):probe.digest(p) for p in paths}
    def load(module,cap):
        out,_=probe.synchronous([str(node),'--input-type=module','-e',
            'import {cases} from '+json.dumps(module.as_uri())+'; console.log(JSON.stringify(cases));'])
        rows=json.loads(out)
        if len(rows)>cap:
            raise ValueError('Hand case cap')
        return rows
    cases=load(hand,8)
    data_cases=load(data_hand,16)
    forward={'name':'hand-forward','program':json.loads(fixture.read_text()),'expected_outcome':['Ok',['int','1']],
             'expected_staging':[['Eval','1'],['Value','1'],['Ready','0'],['Eval','0'],['Eval','1'],['Value','1'],['Eval','1'],['Value','1'],['Ready','0'],['Value','0'],['Join','0'],['Terminate','0'],['Terminal','0']]}
    cases=[forward]+cases+data_cases
    if len({c['name'] for c in cases})!=len(cases) or any(not re.fullmatch('[a-z][a-z0-9-]*',c['name']) for c in cases):
        raise ValueError('Unique safe case IDs required')
    scratch=ROOT/'build/tc0/pure-call-inputs'
    scratch.mkdir(parents=True,exist_ok=True)
    outs,errs=oracle.run([initial_state(c['program']) for c in cases])
    results=[observe(c,oracle,node,scratch,(out,errs)) for c,out in zip(cases,outs)]
    if before!={str(p):probe.digest(p) for p in paths}:
        raise RuntimeError('Source/toolchain drift')
    report={'qualification':'UNKNOWN','scope':'tc0-a-pure-call-demo/1 and /2 hand cases; trusted-local development',
            'sources':before,'oracle':oracle.describe(),'candidate_sandboxed':SANDBOX,'bounds':{'reference_steps':str(REFERENCE_STEPS),'cases':str(len(cases)),'wall_seconds_per_process':'30'},
            'cases':results,'limitations':['No complete catalog or integrated strict replay yet','Hand cases are not generated discovery/exhaustive scope','Not full TC0-A or qualified evaluator/isolation']}
    dest.parent.mkdir(parents=True,exist_ok=True)
    dest.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'qualification':'UNKNOWN','independent_case_agreement':len(results),'report':str(dest)}))


if __name__=='__main__':
    main()
