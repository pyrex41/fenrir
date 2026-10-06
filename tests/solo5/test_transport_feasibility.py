"""Hand-derived stock-policy probe expectations; scripted unit peers, not live evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('feasibility', ROOT/'tools/solo5/transport-feasibility.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def frame(payload):
    if not isinstance(payload,str):
        payload = json.dumps(payload,separators=(',',':'))
    return f'FGIO0/1 {len(payload.encode())}\n{payload}\n'


class CapabilityProbeTests(unittest.TestCase):
    def test_hand_control_and_denial(self):
        control = ''.join(frame(x) for x in m.CONTROL)
        attempt = ''.join(frame(x) for x in m.ATTEMPT)
        self.assertEqual(m.classify('control',0,'Solo5 banner\n'+control),'stock-console-control-completed')
        self.assertEqual(m.classify('read-stdin',159,attempt),'stock-read-fd0-denied-by-sigsys')
        self.assertEqual(m.classify('invalid',1,''),'startup-mode-rejected')

    def test_wrong_lifecycle_no_credit(self):
        control = ''.join(frame(x) for x in m.CONTROL)
        attempt = ''.join(frame(x) for x in m.ATTEMPT)
        for mode,exit_code,stdout in [('control',159,control),('read-stdin',0,attempt),
                                     ('read-stdin',1,attempt),('read-stdin',159,''),
                                     ('read-stdin',159,control),('control',0,attempt),
                                     ('invalid',0,''),('invalid',1,attempt)]:
            with self.subTest(mode=mode,exit=exit_code), self.assertRaises(ValueError):
                m.classify(mode,exit_code,stdout)

    def test_framing_fail_closed(self):
        good = ''.join(frame(x) for x in m.CONTROL)
        for bad in ['FGIO0/1 99999\n{}\n','FGIO0/1 1\n{}\n','FGIO0/1 02\n{}\n',
                    'FGIO0/1 99\n','FGIO0/2 2\n{}\n',
                    frame('{"kind":"ProbeReady","kind":"ProbeReady","sequence":"0"}'),
                    frame('{"kind":"ProbeReady","\\u006bind":"ProbeReady","sequence":"0"}'),
                    frame('{"kind":"ProbeReady","sequence":0}'),
                    good+frame(m.CONTROL[-1]),good.replace('"sequence":"1"','"sequence":"3"')]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                m.classify('control',0,bad)

    def test_absence_confirmation_not_daemon_error(self):
        name = 'fenrir-solo5-unit-owned'
        for diagnostic in ['error: no such object: '+name,'Error: No such object: '+name]:
            self.assertTrue(m.confirms_absent(1,'[]\n',diagnostic,name))
        for code,stdout,stderr in [(0,'[]','error: no such object: '+name),
                                   (1,'[]','cannot connect to Docker daemon'),
                                   (1,'[]','error: no such object: unrelated'),
                                   (1,'[{}]','error: no such object: '+name),
                                   (1,'[]','error: no such object: '+name+'\nsecond error')]:
            self.assertFalse(m.confirms_absent(code,stdout,stderr,name))

    def test_hand_policy_and_denied_expansions(self):
        info = {'HostConfig':{'NetworkMode':'none','Privileged':False,'ReadonlyRootfs':True,
                             'CapDrop':['ALL'],'SecurityOpt':['no-new-privileges'],'Devices':[],
                             'Memory':134217728,'PidsLimit':32,'Tmpfs':{}},
                'Config':{'User':'65534:65534','OpenStdin':False,'Tty':False},
                'Mounts':[{'Type':'bind','Source':'/unit/input','Destination':'/guest/probe.spt','RW':False}]}
        mounts = [(Path('/unit/input'),'/guest/probe.spt')]
        self.assertEqual(m.check_policy(info,mounts,False)['network'],'none')
        for section,key,value in [('HostConfig','NetworkMode','bridge'),('HostConfig','Privileged',True),
                                 ('HostConfig','ReadonlyRootfs',False),('HostConfig','CapDrop',[]),
                                 ('HostConfig','SecurityOpt',[]),('HostConfig','Devices',[{}]),
                                 ('HostConfig','Memory',0),('HostConfig','PidsLimit',0),
                                 ('HostConfig','Tmpfs',{'/other':'rw'}),
                                 ('Config','User','0:0'),('Config','OpenStdin',True),('Config','Tty',True)]:
            bad = copy.deepcopy(info)
            bad[section][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                m.check_policy(bad,mounts,False)
        bad = copy.deepcopy(info)
        bad['Mounts'][0]['RW'] = True
        with self.assertRaises(ValueError):
            m.check_policy(bad,mounts,False)


if __name__ == '__main__':
    unittest.main()
