"""Closed cooperative recording admission; no TC0/native qualification."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools/solo5'))
import environment as env


class AdmissionTests(unittest.TestCase):
    def tape(self):
        guest, host = env.records()
        return {'schema': 'fenrir.solo5.environment-recording/1', 'qualification': 'UNKNOWN',
                'header': {'test_identity': 'pinned'}, 'choices': host,
                'responses': [env.base64.b64encode(env.wire.frame(r)).decode() for r in host],
                'trace': guest, 'footer': env.completed_footer()}

    def test_control_and_all_singletons(self):
        value = self.tape()
        self.assertEqual(len(env.admit_recording(value, value['header'])), 6)
        for index in range(6):
            for field in ['epoch', 'site', 'domain_hash', 'profile', 'sequence', 'kind', 'run_id']:
                wrong = copy.deepcopy(value)
                wrong['choices'][index][field] = 'wrong'
                with self.assertRaises(ValueError):
                    env.admit_recording(wrong, value['header'])

    def test_closed_boundaries(self):
        value = self.tape()
        for field in value:
            wrong = copy.deepcopy(value)
            del wrong[field]
            with self.assertRaises(ValueError):
                env.admit_recording(wrong, value['header'])
        for field in ['choices', 'responses', 'trace']:
            for suffix in [False, True]:
                wrong = copy.deepcopy(value)
                if suffix:
                    wrong[field].append(wrong[field][-1])
                else:
                    wrong[field].pop()
                with self.assertRaises(ValueError):
                    env.admit_recording(wrong, value['header'])
        wrong = copy.deepcopy(value)
        wrong['footer']['final_state']['monotonic'] = '11'
        with self.assertRaises(ValueError):
            env.admit_recording(wrong, value['header'])

    def test_cli_invalid_tape_never_launches_or_writes(self):
        parent = ROOT/'build/solo5'
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as tmp:
            dest = Path(tmp)
            value = self.tape()
            value['choices'][0]['extra'] = 'forbidden'
            tape = dest/'bad.json'
            tape.write_bytes(env.wire.canonical(value))
            output = dest/'output.json'
            argv = ['environment.py', 'replay', '--build-report', str(dest/'build.json'),
                    '--recording', str(tape), '--output', str(output)]
            with patch.object(sys, 'argv', argv), patch.object(env, 'admit_build', return_value={}), \
                 patch.object(env, 'header', return_value=value['header']), patch.object(env, 'session') as session:
                with self.assertRaises(ValueError):
                    env.main()
                session.assert_not_called()
            self.assertFalse(output.exists())
            self.assertFalse(Path(str(output)+'.diagnostics.json').exists())

    def test_decoder_duplicate_and_numeric_rejection(self):
        for raw in [b'{"a":"x","a":"y"}', b'{"a":1}', b'{"a":1.0}', b'{}\n']:
            with self.assertRaises(ValueError):
                env.wire.decode(raw)


if __name__ == '__main__':
    unittest.main()
