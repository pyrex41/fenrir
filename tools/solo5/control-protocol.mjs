// Closed hand-derived host transport expectations. UNQUALIFIED demo, no TC0 rules.
import {createHash} from 'node:crypto';
import {dumps, strictJson} from './host-util.mjs';

export const PROFILE='fenrir.solo5.control-demo/1';
export const RUN='demo-0';
export const MAX_PAYLOAD=65500;

export class ProtocolError extends Error {}

// Canonical bytes: sorted keys, no spaces, ASCII only. A non-ASCII value is an
// encoding failure (UnicodeError in the former Python), not a ProtocolError.
class EncodingError extends Error {}
export function canonical(value) {
  const text=dumps(value,{sortKeys:true,compact:true,ascii:false});
  if(/[^\x00-\x7f]/.test(text))throw new EncodingError('Canonical value is not ASCII');
  return Buffer.from(text,'latin1');
}

export function hashValue(value) {
  return createHash('sha256').update(canonical(value)).digest('hex');
}

// Returns [guest records, host records].
export function records() {
  const common={profile:PROFILE,run_id:RUN};
  const config=hashValue({boundaries:'2',profile:PROFILE});
  const guest=[{...common,config_hash:config,kind:'Hello',sequence:'0'}];
  const host=[{...common,config_hash:config,kind:'Init',sequence:'0'}];
  for(let i=0;i<2;i++) {
    const boundary={...common,domain_hash:hashValue([['Proceed',String(i)]]),epoch:String(i),
      kind:'Boundary',sequence:String(i+1),site:'Probe'+i};
    guest.push(boundary);
    host.push({...boundary,kind:'Proceed',decision:['Proceed',String(i)]});
  }
  guest.push({...common,accepted:'2',epoch:'2',kind:'Terminal',sequence:'3'});
  host.push({...common,kind:'Ack',sequence:'3'});
  return [guest,host];
}

export function frame(record) {
  const body=canonical(record);
  if(body.length<1||body.length>MAX_PAYLOAD)throw new ProtocolError('PayloadLimit');
  return Buffer.concat([Buffer.from('FGCTL/1 '+body.length+'\n','latin1'),body,Buffer.from('\n','latin1')]);
}

// body: Buffer. Duplicate keys and numeric tokens are named; any other
// malformed or non-ASCII text is PayloadEncoding.
export function decode(body) {
  let value;
  try {
    if(body.some(byte=>byte>127))throw new EncodingError('Payload is not ASCII');
    value=strictJson(body.toString('latin1'),{duplicate:()=>new ProtocolError('DuplicateKey'),numeric:()=>new ProtocolError('NumericToken')});
    if(!canonical(value).equals(body))throw new ProtocolError('NoncanonicalPayload');
  } catch(e) {
    if(e instanceof EncodingError||e instanceof SyntaxError)throw new ProtocolError('PayloadEncoding',{cause:e});
    throw e;
  }
  if(value===null||typeof value!=='object'||Array.isArray(value))throw new ProtocolError('RecordShape');
  return value;
}

export class Decoder {
  constructor() {
    this.pending=Buffer.alloc(0);
    this.size=null;
  }

  feed(data) {
    return [...this.iterFeed(data)];
  }

  *iterFeed(data) {
    // Commit each decoded prefix record before parsing later bytes. A bad
    // coalesced suffix must not erase a valid prefix or depend on chunking.
    this.pending=Buffer.concat([this.pending,data]);
    for(;;) {
      if(this.size===null) {
        const at=this.pending.indexOf(10);
        if(at<0) {
          if(this.pending.length>32)throw new ProtocolError('HeaderLimit');
          break;
        }
        if(at>31)throw new ProtocolError('HeaderLimit');
        const header=this.pending.subarray(0,at).toString('latin1');
        this.pending=this.pending.subarray(at+1);
        const match=/^FGCTL\/1 ([1-9][0-9]{0,4})$/.exec(header);
        if(!match)throw new ProtocolError('MalformedHeader');
        this.size=Number(match[1]);
        if(this.size>MAX_PAYLOAD)throw new ProtocolError('PayloadLimit');
      }
      if(this.pending.length<this.size+1)break;
      const body=this.pending.subarray(0,this.size);
      if(this.pending[this.size]!==10)throw new ProtocolError('PayloadDelimiter');
      this.pending=this.pending.subarray(this.size+1);
      this.size=null;
      yield decode(body);
    }
  }

  finish() {
    if(this.pending.length||this.size!==null)throw new ProtocolError('TruncatedFrame');
  }
}
