"""Scripted baseline report checks; no independent execution/qualification credit."""
import copy
import importlib.util
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('baseline', ROOT/'tools/solo5/baseline.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def report(count=10):
    return {'solo5_commit':m.COMMIT,'repeat_count':str(count),'cleanup':'confirmed',
            'semantic_frames':[{'kind':'Pong','sequence':'0','value':'pong'},
                               {'kind':'Terminal','outcome':'Ok','sequence':'1'}],
            'semantic_frames_identical':True,'protected_sentinel_unchanged':True,
            'determinism_qualification':'UNKNOWN','tc0_qualification':'UNKNOWN',
            'negative_syscall_probes':{k:{'exit':'159','expected':'159','denied_by_sigsys':True} for k in ['open','socket']},
            'guest_sha256':'a'*64,'image_id':'sha256:fixed-unit-peer','sources':{'unit-only':'b'*64}}


class BaselineTests(unittest.TestCase):
    def test_hand_expectations_and_two_build_identity(self):
        m.validate_report(report(),10)
        m.validate_report(report(1),1)
        self.assertTrue(m.compare_builds(report(),report(1))['independent_guest_builds_equal'])

    def test_bad_classifications_rejected(self):
        for key,value in [('solo5_commit','moving'),('repeat_count','0'),('cleanup','unresolved'),
                          ('semantic_frames_identical',False),('protected_sentinel_unchanged',False),
                          ('determinism_qualification','PASS'),('tc0_qualification','PASS')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                bad = report()
                bad[key] = value
                m.validate_report(bad,10)
        bad = report()
        bad['negative_syscall_probes']['open']['exit'] = '1'
        with self.assertRaises(ValueError):
            m.validate_report(bad,10)
        bad = report()
        bad['semantic_frames'].reverse()
        with self.assertRaises(ValueError):
            m.validate_report(bad,10)

    def test_source_binary_image_payload_drift_rejected(self):
        for key in ['guest_sha256','image_id','sources','semantic_frames']:
            bad = copy.deepcopy(report(1))
            bad[key] = 'drift'
            with self.subTest(key=key), self.assertRaises(ValueError):
                m.compare_builds(report(),bad)

    def test_local_client_bounds(self):
        import sys
        result = m.command([sys.executable,'-c','print("unit-only")'],timeout=5)
        self.assertEqual(result.stdout,'unit-only\n')
        self.assertEqual(result.returncode,0)
        with self.assertRaises(TimeoutError):
            m.command([sys.executable,'-c','import time;time.sleep(5)'],timeout=0.05)
        with self.assertRaises(RuntimeError):
            m.command([sys.executable,'-c','import sys;sys.stdout.write("x"*9000000)'],timeout=5)


if __name__ == '__main__':
    unittest.main()
