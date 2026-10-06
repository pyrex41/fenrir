"""Scripted replay/evidence admission tests; no independent oracle or live credit."""
import base64
import copy
import importlib.util
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('replay_units',ROOT/'tools/solo5/control_replay.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def fixture():
    guest,host = m.wire.records()
    return {'header':{'schema':'unit-only','profile':m.wire.PROFILE,'guest_sha256':'a'*64},
            'choices':[{'index':str(i),'sequence':str(i),'epoch':str(max(0,i-1)),
                        'kind':r['kind'],'site':r.get('site','Transport'+r['kind']),
                        'domain_hash':'b'*64,'selected':[r['kind']],
                        'bytes':base64.b64encode(m.wire.frame(r)).decode()} for i,r in enumerate(host)],
            'footer':{'execution':'Completed','conformance':'Admitted','first_error':None,'trace':guest,
                      'responses':[base64.b64encode(m.wire.frame(r)).decode() for r in host]}}


class ReplayTests(unittest.TestCase):
    def test_exact_closed_choices_headers_and_footer(self):
        good = fixture()
        m.validate_tape(copy.deepcopy(good),good)
        mutations = [lambda x:x['header'].update(guest_sha256='drift'),
                     lambda x:x['header'].update(extra='no'),lambda x:x.update(extra='no'),
                     lambda x:x['choices'].pop(),lambda x:x['choices'].append(x['choices'][-1]),
                     lambda x:x['choices'].reverse(),lambda x:x['footer'].update(execution='BudgetExhausted'),
                     lambda x:x['footer']['trace'][0].update(sequence='99')]
        for key in ['index','sequence','epoch','kind','site','domain_hash','selected','bytes']:
            mutations.append(lambda x,key=key:x['choices'][0].update({key:'drift'}))
        for mutate in mutations:
            bad = copy.deepcopy(good)
            mutate(bad)
            with self.assertRaises(ValueError):
                m.validate_tape(bad,good)

    def test_strict_json_duplicates_numbers_and_nonsemantic_endings(self):
        for raw in [b'{"a":"x","a":"y"}',b'{"a":"x","\\u0061":"y"}',
                    b'{"a":0}',b'{"a":1.2}',b'{"a":NaN}']:
            with self.assertRaises(ValueError):
                m.strict_json(raw)
        self.assertEqual(m.strict_json(b'{"a":"0"}'),{'a':'0'})
        for outcome in ['CandidateCrash','HarnessTimeout','OutputLimit','GuestRejected']:
            with self.assertRaises(ValueError):
                m.footer({'execution':outcome})

    def test_source_identity_missing_stale_inconsistent(self):
        path = 'tools/solo5/control_protocol.py'
        sources = {path:m.client.digest(ROOT/path)}
        m.identity_sources({'sources_before':sources,'sources_after':sources},[path])
        for report in [{}, {'sources_before':{},'sources_after':{}},
                       {'sources_before':sources,'sources_after':{}},
                       {'sources_before':{path:'0'*64},'sources_after':{path:'0'*64}}]:
            with self.assertRaises(ValueError):
                m.identity_sources(report,[path])

    def test_all_tapes_validate_before_any_guest_or_output(self):
        import hashlib
        import json
        import tempfile
        from unittest.mock import patch
        names = ['cold-0','guest-early-terminal','guest-wrong-boundary','guest-suffix']
        report = {'cases':[{'name':name} for name in names]}
        data = b'unit-only-not-independent-oracle'
        sources = {p:'i' for p in ['tools/solo5/control_replay.py','tools/solo5/interactive.py','tools/solo5/control_protocol.py']}
        tape = fixture()
        result = {'replay':'Exact','conformance':'Admitted','execution':'Completed','qualification':'UNKNOWN',
                  'scope':'Observed cooperative transport prefix/footer only','cleanup':'confirmed'}
        bundle = {'schema':'fenrir.solo5.control-replay-bundle/1','qualification':'UNKNOWN',
                  'oracle_report_sha256':hashlib.sha256(data).hexdigest(),'sources':sources,
                  'cases':{name:{'tape':copy.deepcopy(tape),'result':result} for name in names},
                  'scope':'Same guest/tender/options exposed transport completion or first discrepancy, not native machine replay'}
        bundle['cases'][names[-1]]['tape']['choices'].pop()
        parent = ROOT/'build/solo5'
        parent.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as directory:
            path = Path(directory)
            bad = path/'bad.json'
            bad.write_text(json.dumps(bundle))
            output = path/'output.json'
            with patch.object(m,'admit_report',return_value=(report,data)), patch.object(m,'environment',return_value={}), \
                 patch.object(m,'tape_for',return_value=tape),patch.object(m.client,'digest',return_value='i'), \
                 patch.object(m.peer,'session') as guest, patch.object(m.sys,'argv',['unit',str(path/'input.json'),str(output),'--tapes',str(bad)]):
                with self.assertRaises(ValueError):
                    m.main()
                guest.assert_not_called()
                self.assertFalse(output.exists())

    def test_bundle_closed_and_result_cannot_promote(self):
        tape = fixture()
        result = {'replay':'Exact','conformance':'Admitted','execution':'Completed','qualification':'UNKNOWN',
                  'scope':'Observed cooperative transport prefix/footer only','cleanup':'confirmed'}
        bundle = {'schema':'fenrir.solo5.control-replay-bundle/1','qualification':'UNKNOWN',
                  'oracle_report_sha256':'h','sources':{'unit-only':'i'},'cases':{'unit':{'tape':tape,'result':result}},
                  'scope':'Same guest/tender/options exposed transport completion or first discrepancy, not native machine replay'}
        m.validate_bundle(bundle,{'unit':tape},'h',{'unit-only':'i'})
        for mutate in [lambda x:x.update(extra='no'),lambda x:x.update(qualification='PASS'),
                       lambda x:x.update(oracle_report_sha256='drift'),lambda x:x['cases'].clear(),
                       lambda x:x['cases']['unit'].update(extra='no'),
                       lambda x:x['cases']['unit']['result'].update(qualification='PASS')]:
            bad = copy.deepcopy(bundle)
            mutate(bad)
            with self.assertRaises(ValueError):
                m.validate_bundle(bad,{'unit':tape},'h',{'unit-only':'i'})


if __name__ == '__main__':
    unittest.main()
