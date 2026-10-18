#!/usr/bin/env python3
"""Independent Shen/candidate closure development probe; NOT qualification."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('expr_probe', ROOT/'tools/check-tc0-expression.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def translate(e, codes):
    tag, node, *a = e
    if tag in ('int','var'):
        operands = a[0]
    elif tag == 'lambda':
        body = translate(a[5],codes)
        codes.append('['+node+' ['+a[0]+' '+body+']]')
        operands = a[0]+' '+body
    elif tag == 'let':
        operands = a[0]+' '+translate(a[1],codes)+' '+translate(a[2],codes)
    elif tag in ('apply','add'):
        operands = ' '.join(translate(x,codes) for x in a)
    else:
        raise ValueError('Unsupported closure translation')
    return '['+tag+' '+node+' '+operands+']'


def value(v):
    if v[0] == 'int' and len(v) == 2:
        return v
    if v[0] == 'closure' and len(v) == 4 and v[3] == []:
        return {'code_id':v[1],'captures':[[k,value(x)] for k,x in v[2]],'capture_support':[]}
    raise ValueError('Unexpected closure model value')


def sample(s, epoch):
    tag, site, after, depth, events = s
    if tag != 'sample':
        raise ValueError('Invalid sample')
    rules = {'dispatch':'Dispatch','ready':'Ready','let-return':'LetReturn','collect-return':'CollectReturn',
             'return-return':'ReturnReturn','value':'Value','unwind':'Unwind','join':'Join','terminate':'Terminate'}
    kinds = {'eval':'Eval','value':'Value','ready':'Ready','unwind':'Unwind','join':'Join','terminate':'Terminate','terminal':'Terminal'}
    def event(e):
        if len(e) != 2 or e[0] not in ('scope-exit','task-termination'):
            raise ValueError('Unexpected event')
        o = e[1]
        outcome = ['Ok',value(o[1])] if o[0] == 'ok' else ['Trap',{'overflow':'Overflow'}[o[1]]]
        return {'kind':{'scope-exit':'ScopeExit','task-termination':'TaskTermination'}[e[0]],'outcome':outcome}
    return {'epoch':str(epoch),'site':{site[0]:site[1] if site[0]=='node' else kinds[site[1]],'rule':rules[site[2]]},
            'after':kinds[after],'depth':depth,'events':[event(e) for e in events]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shen-executable',required=True)
    parser.add_argument('--output',required=True)
    parser.add_argument('--additional-case',action='append',default=[])
    args = parser.parse_args()
    destination = Path(args.output).resolve()
    if not destination.is_relative_to(ROOT/'build') or destination.suffix != '.json':
        raise ValueError('Development output must be JSON below build')
    executable = Path(args.shen_executable).resolve(strict=True)
    node = Path(shutil.which('node')).resolve(strict=True)
    paths = [Path(__file__),ROOT/'tools/check-tc0-expression.py',ROOT/'tools/tc0/run-closure.mjs',
             ROOT/'tools/tc0/closure-artifact.mjs',ROOT/'tools/tc0/canonical.mjs',ROOT/'runtime/tc0/closure-machine.mjs',
             ROOT/'models/tc0/closure-machine.shen',ROOT/'models/tc0/arithmetic.shen',
             ROOT/'fixtures/tc0/closure-capture-program.json',ROOT/'spec/tc0/pure-closure-demo.json',
             ROOT/'tests/tc0/closure.test.mjs',executable,node,executable.parent.parent/'lib/shen-scheme/shen.boot']
    additional = []
    if len(args.additional_case) > 8:
        raise ValueError('Additional case cap')
    for filename in args.additional_case:
        path = Path(filename).resolve(strict=True)
        if not path.is_relative_to(ROOT/'fixtures/tc0'):
            raise ValueError('Additional cases must be retained TC0 fixtures')
        case = json.loads(path.read_text())
        if set(case) != {'case_id','program','expected_outcome','expected_descriptors'} or not isinstance(case['case_id'],str) or not case['case_id'].replace('-','').isalnum():
            raise ValueError('Closed additional fixture fields/name')
        additional.append(case)
        paths.append(path)
    before = {str(p):probe.digest(p) for p in paths}
    base = json.loads((ROOT/'fixtures/tc0/closure-capture-program.json').read_text())
    higher = json.loads(json.dumps(base))
    higher['body'][4][4] = ['apply','21',['lambda','15','16',['Arrow','I64','I64'],'I64',[],[],
        ['apply','17',['var','18','16'],['int','19','5']]],['var','20','5']]
    non_tail = json.loads(json.dumps(base))
    non_tail['body'][4][4] = ['add','22',non_tail['body'][4][4],['int','23','1']]
    overflow = json.loads(json.dumps(non_tail))
    overflow['body'][3][2] = '9223372036854775807'
    nested = json.loads(json.dumps(base))
    nested['body'][4][3] = ['lambda','7','8','I64',['Arrow','I64','I64'],[],[],
        ['lambda','15','16','I64','I64',[],[],['add','17',['add','9',['var','10','2'],['var','11','8']],['var','18','16']]]]
    nested['body'][4][4] = ['apply','12',['apply','19',['var','13','5'],['int','14','3']],['int','20','5']]
    cases = [('capture',base,['Ok',['int','12']]),('higher-order',higher,['Ok',['int','12']]),
             ('non-tail',non_tail,['Ok',['int','13']]),('overflow-unwind',overflow,['Trap','Overflow']),
             ('nested-returned-closure',nested,['Ok',['int','15']])]
    cases.extend((c['case_id'],c['program'],c['expected_outcome']) for c in additional)
    if len({name for name,_,_ in cases}) != len(cases):
        raise ValueError('Duplicate case ID')
    results = []
    scratch = ROOT/'build/tc0/closure-inputs'
    scratch.mkdir(parents=True,exist_ok=True)
    for name,p,expected in cases:
        # Host peer validates the closed graph before any candidate/model execution.
        program = scratch/(name+'.json')
        program.write_text(json.dumps(p,separators=(',',':')))
        stdout, _ = probe.synchronous([str(node),str(ROOT/'tools/tc0/run-closure.mjs'),str(program)])
        candidate = json.loads(stdout)
        if candidate['execution'] != 'Completed':
            raise RuntimeError('Candidate budget exhausted, not completing evidence')
        codes = []
        body = translate(p['body'],codes)
        initial = '[closure-state [eval '+body+' true] [['+p['input_binding']+' [int 0]]] [] ['+' '.join(codes)+']]'
        state = '(value tc0.cl.probe)'
        terminal = '(= (hd (hd (tl '+state+'))) terminal)'
        argv = [str(executable),'eval','-l',str(ROOT/'models/tc0/arithmetic.shen'),'-l',str(ROOT/'models/tc0/closure-machine.shen'),
                '-e','(set tc0.cl.probe '+initial+')']
        for _ in range(200):
            argv += ['-e','(if '+terminal+' [] (tc0.cl.sample '+state+'))',
                     '-e','(if '+terminal+' [] (set tc0.cl.probe (hd (tl (tc0.cl.step '+state+')))))',
                     '-e','(if (= (hd (hd (tl '+state+'))) value) (hd (tl (hd (tl '+state+')))) [])']
        argv += ['-e','(hd (hd (tl '+state+')))']
        model_stdout,model_stderr = probe.synchronous(argv,timeout=30)
        if model_stdout.splitlines()[-1].strip() != 'terminal':
            raise RuntimeError('Independent model did not complete within bound')
        steps = [sample(probe.parse_list(line),i) for i,line in enumerate(x for x in model_stdout.splitlines() if x.startswith('[sample '))]
        descriptors = [value(probe.parse_list(line)) for line in model_stdout.splitlines() if line.startswith('[closure ')]
        if candidate['steps'] != steps or candidate['outcome'] != expected or steps[-1]['events'][0]['outcome'] != expected:
            raise RuntimeError('Model/candidate/hand outcome or staging disagreement in '+name)
        # Compare freshly constructed descriptors, also observed repeatedly during propagation.
        if not all(d in descriptors for d in candidate['descriptors']):
            raise RuntimeError('Candidate descriptors not independently observed')
        for fixture in additional:
            if name == fixture['case_id']:
                if candidate['descriptors'] != fixture['expected_descriptors'] or not all(d in descriptors for d in fixture['expected_descriptors']):
                    raise RuntimeError('Hand-derived descriptor disagreement')
        if name == 'capture':
            hand = [('Eval','1'),('Value','1'),('Eval','0'),('Eval','1'),('Value','1'),('Eval','0'),
                    ('Eval','1'),('Value','1'),('Eval','1'),('Value','1'),('Ready','0'),('Eval','0'),
                    ('Eval','1'),('Value','1'),('Eval','1'),('Value','1'),('Ready','0'),('Value','0'),
                    ('Join','0'),('Terminate','0'),('Terminal','0')]
            if [(s['after'],s['depth']) for s in steps] != hand:
                raise RuntimeError('Hand-derived21-step capture staging disagreement')
        results.append({'name':name,'program':p,'program_sha256':probe.digest(program),'hand_outcome':expected,
                        'candidate':candidate,'model_steps':steps,'model_descriptors':descriptors,
                        'shen_stdout':model_stdout,'shen_stderr':model_stderr})
    if before != {str(p):probe.digest(p) for p in paths}:
        raise RuntimeError('Source/toolchain drift during probe')
    report = {'qualification':'UNKNOWN','scope':'Standalone pure-closure-demo/1 trusted-local development',
              'sources':before,'cases':results,'limitations':['Not full TC0-A artifact/catalog','No named/recursive calls',
              'No strict closure-profile replay/reduction yet','No independently reviewed evaluator/isolation']}
    destination.parent.mkdir(parents=True,exist_ok=True)
    destination.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'qualification':'UNKNOWN','independent_case_agreement':len(results),'report':str(destination)}))


if __name__ == '__main__':
    main()
