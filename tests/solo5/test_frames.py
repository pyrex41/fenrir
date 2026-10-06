"""Independent hand-derived framing expectations; no Docker or model requests."""
import importlib.util
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('solo5_spike',ROOT/'tools/solo5/spike.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
PONG='{"kind":"Pong","sequence":"0","value":"pong"}'
TERMINAL='{"kind":"Terminal","outcome":"Ok","sequence":"1"}'
def frame(payload): return 'FG0/1 '+str(len(payload.encode()))+'\n'+payload+'\n'
GOOD=frame(PONG)+frame(TERMINAL)


class FramingTests(unittest.TestCase):
    def test_hand_framed_exchange(self):
        self.assertEqual(len(PONG.encode()),45)
        self.assertEqual(len(TERMINAL.encode()),49)
        self.assertEqual(module.frames('Solo5: diagnostic\n'+GOOD),[
            {'kind':'Pong','sequence':'0','value':'pong'},
            {'kind':'Terminal','outcome':'Ok','sequence':'1'}])

    def test_fail_closed(self):
        bad=[frame(PONG),frame(TERMINAL)+frame(PONG),GOOD+frame(TERMINAL),
             GOOD.replace('FG0/1 45','FG0/1 045'),GOOD.replace('FG0/1 45','FG0/1 44'),
             'FG0/1 5000\n{}\n',GOOD.replace('"sequence":"1"','"sequence":"2"'),
             frame('{"kind":"Pong","kind":"Pong","sequence":"0","value":"pong"}')+frame(TERMINAL),
             frame('{"kind":"Pong","\\u006bind":"Pong","sequence":"0","value":"pong"}')+frame(TERMINAL),
             frame('{"kind":"Pong","sequence":0,"value":"pong"}')+frame(TERMINAL),
             frame('{"kind":"Pong","sequence":"0","value":"pong","extra":null}')+frame(TERMINAL),
             'FG0/1 45\n', 'FG0/2 45\n'+PONG+'\n', 'FGCLOCK 1\n'+GOOD]
        for raw in bad:
            with self.subTest(raw=raw),self.assertRaises(ValueError): module.frames(raw)


if __name__=='__main__': unittest.main()
