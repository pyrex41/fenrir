"""Independent hand-derived protocol units; not live guest/isolation evidence."""
import importlib.util
import sys
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/solo5'))
import control_protocol as p
spec = importlib.util.spec_from_file_location('interactive_test',ROOT/'tools/solo5/interactive.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class ProtocolTests(unittest.TestCase):
    def test_hand_hashes_and_sequence(self):
        guest,commands = p.records()
        self.assertEqual(guest[0]['config_hash'],'ba6400d1dc04d544d51e27fa3acc8b113a06a88de5c43c8c6d118c3dc586e3cf')
        self.assertEqual(guest[1]['domain_hash'],'b72fe6951f970bde6dac693e3ed5909449a0aa83fd09bbdcf4b1845fa4f57eaa')
        self.assertEqual(guest[2]['domain_hash'],'11080677314bfff6c924ceddd9d879a73d5aa78cf5257d971d97aaf86d1d7573')
        self.assertEqual([x['kind'] for x in guest],['Hello','Boundary','Boundary','Terminal'])
        self.assertEqual([x['kind'] for x in commands],['Init','Proceed','Proceed','Ack'])
        self.assertEqual([x['sequence'] for x in guest],['0','1','2','3'])
        self.assertEqual(guest[-1]['accepted'],'2')

    def test_every_byte_split_and_coalesced(self):
        rows,_ = p.records()
        stream = b''.join(p.frame(x) for x in rows)
        for at in range(len(stream)+1):
            decoder = p.Decoder()
            decoded = decoder.feed(stream[:at])+decoder.feed(stream[at:])
            decoder.finish()
            self.assertEqual(decoded,rows)
        decoder = p.Decoder()
        decoded = []
        for b in stream:
            decoded += decoder.feed(bytes([b]))
        decoder.finish()
        self.assertEqual(decoded,rows)

    def test_bad_coalesced_suffix_preserves_prefix_for_every_split(self):
        hello = p.records()[0][0]
        stream = p.frame(hello)+b'noise\n'
        for at in range(len(stream)+1):
            decoder = p.Decoder()
            prefix = []
            error = None
            for chunk in [stream[:at],stream[at:]]:
                try:
                    for row in decoder.iter_feed(chunk):
                        prefix.append(row)
                except p.ProtocolError as e:
                    error = str(e)
                    break
            self.assertEqual(prefix,[hello])
            self.assertEqual(error,'MalformedHeader')

    def test_noncanonical_or_bad_framing(self):
        for raw in [b'FGCTL/1 01\n{}\n',b'FGCTL/1 65501\n',b'FGCTL/1 2\n{}X',
                    b'noise before Hello\n',b'FGCTL/2 2\n{}\n',b'x'*33]:
            with self.subTest(raw=raw),self.assertRaises(p.ProtocolError):
                p.Decoder().feed(raw)
        for body in [b'{"x":"a","x":"a"}',b'{"x":"a","\\u0078":"a"}',
                     b'{"n":0}',b'{"n":1.2}',b'{"n":NaN}',b'{ "x":"a"}',
                     b'{"x":"\\u0061"}',b'{"z":"a","a":"b"}',b'[]',b'\xef\xbb\xbf{}']:
            with self.subTest(body=body),self.assertRaises(p.ProtocolError):
                p.decode(body)
        d = p.Decoder()
        d.feed(b'FGCTL/1 10\n{}')
        with self.assertRaises(p.ProtocolError):
            d.finish()

    def test_hostile_response_materialization(self):
        good = host.fault_responses(None)
        for index,kind in [(0,'run_id'),(0,'sequence'),(1,'epoch'),(1,'site'),(1,'domain_hash'),(0,'profile'),(1,'decision'),
                           (0,'unknown'),(0,'kind'),(0,'numeric'),(0,'duplicate'),(0,'length'),
                           (0,'oversize'),(1,'missing'),(0,'reorder'),(0,'truncated'),(3,'suffix')]:
            self.assertNotEqual(host.fault_responses((index,kind)),good)
        with self.assertRaises(ValueError):
            host.fault_responses((0,'invented-fault'))


if __name__ == '__main__':
    unittest.main()
