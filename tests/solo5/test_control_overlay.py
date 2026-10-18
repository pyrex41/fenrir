"""Exact-source overlay tests, not live sandbox or qualification evidence."""
import importlib.util
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('control_overlay',ROOT/'backends/solo5/overlays/control-stdin/overlay.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def pinned_spt_core(case):
    path = ROOT/'build/vendor/solo5/tenders/spt/spt_core.c'
    if not path.is_file():
        case.skipTest('Pinned vendor unavailable; live overlay build remains unverified')
    return path.read_bytes()


class OverlayTests(unittest.TestCase):
    def test_exact_patch_is_narrow_and_repeatable(self):
        original = pinned_spt_core(self)
        patched,diff = m.apply(original)
        self.assertEqual((patched,diff),m.apply(original))
        self.assertIn('static bool fenrir_control_stdin = false;',patched.decode())
        self.assertIn('!S_ISFIFO(input.st_mode)',patched.decode())
        self.assertIn('SCMP_A2(SCMP_CMP_LE, 65536)',patched.decode())
        additions = [s for s in diff.splitlines() if s.startswith('+') and not s.startswith('+++')]
        self.assertEqual(sum('SCMP_SYS(' in s for s in additions),1)
        self.assertTrue(any('SCMP_SYS(read)' in s for s in additions))
        self.assertTrue(diff.startswith('--- a/tenders/spt/spt_core.c\n+++ b/tenders/spt/spt_core.c\n'))
        self.assertIn('Copyright (c) 2015-2019',patched.decode())

    def test_moving_or_already_patched_source_rejected(self):
        original = pinned_spt_core(self)
        patched,_ = m.apply(original)
        for bad in [b'',original+b'\n',patched]:
            with self.assertRaises(ValueError):
                m.apply(bad)


if __name__ == '__main__':
    unittest.main()
