"""Closed hand-derived host transport expectations. UNQUALIFIED demo, no TC0 rules."""
import hashlib
import json
import re
PROFILE = 'fenrir.solo5.control-demo/1'
RUN = 'demo-0'
MAX_PAYLOAD = 65500


class ProtocolError(ValueError):
    pass


def canonical(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode('ascii')


def hash_value(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def records():
    common = {'profile':PROFILE,'run_id':RUN}
    config = hash_value({'boundaries':'2','profile':PROFILE})
    guest = [{**common,'config_hash':config,'kind':'Hello','sequence':'0'}]
    host = [{**common,'config_hash':config,'kind':'Init','sequence':'0'}]
    for i in range(2):
        boundary = {**common,'domain_hash':hash_value([['Proceed',str(i)]]),'epoch':str(i),
                    'kind':'Boundary','sequence':str(i+1),'site':'Probe'+str(i)}
        guest.append(boundary)
        host.append({**boundary,'kind':'Proceed','decision':['Proceed',str(i)]})
    guest.append({**common,'accepted':'2','epoch':'2','kind':'Terminal','sequence':'3'})
    host.append({**common,'kind':'Ack','sequence':'3'})
    return guest,host


def frame(record):
    body = canonical(record)
    if not 1 <= len(body) <= MAX_PAYLOAD:
        raise ProtocolError('PayloadLimit')
    return b'FGCTL/1 '+str(len(body)).encode()+b'\n'+body+b'\n'


def decode(body):
    def pairs(items):
        d = {}
        for k,v in items:
            if k in d:
                raise ProtocolError('DuplicateKey')
            d[k] = v
        return d
    def number(_):
        raise ProtocolError('NumericToken')
    try:
        value = json.loads(body.decode('ascii'),object_pairs_hook=pairs,parse_int=number,
                           parse_float=number,parse_constant=number)
        if canonical(value) != body:
            raise ProtocolError('NoncanonicalPayload')
        if not isinstance(value,dict):
            raise ProtocolError('RecordShape')
        return value
    except (UnicodeError,json.JSONDecodeError) as e:
        raise ProtocolError('PayloadEncoding') from e


class Decoder:
    def __init__(self):
        self.pending = bytearray()
        self.size = None

    def feed(self,data):
        return list(self.iter_feed(data))

    def iter_feed(self,data):
        # Commit each decoded prefix record before parsing later bytes. A bad
        # coalesced suffix must not erase a valid prefix or depend on chunking.
        self.pending.extend(data)
        while True:
            if self.size is None:
                at = self.pending.find(b'\n')
                if at < 0:
                    if len(self.pending) > 32:
                        raise ProtocolError('HeaderLimit')
                    break
                if at > 31:
                    raise ProtocolError('HeaderLimit')
                header = bytes(self.pending[:at])
                del self.pending[:at+1]
                match = re.fullmatch(rb'FGCTL/1 ([1-9][0-9]{0,4})',header)
                if not match:
                    raise ProtocolError('MalformedHeader')
                self.size = int(match[1])
                if self.size > MAX_PAYLOAD:
                    raise ProtocolError('PayloadLimit')
            if len(self.pending) < self.size+1:
                break
            body = bytes(self.pending[:self.size])
            if self.pending[self.size] != 10:
                raise ProtocolError('PayloadDelimiter')
            del self.pending[:self.size+1]
            self.size = None
            yield decode(body)

    def finish(self):
        if self.pending or self.size is not None:
            raise ProtocolError('TruncatedFrame')
