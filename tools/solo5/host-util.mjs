// Shared host-side helpers for the Solo5 development tools. These reproduce the
// exact behaviours the former Python tools took from the Python standard
// library (strict JSON decoding hooks, json.dumps layouts, str.splitlines,
// strict base64, argparse exit codes, non-blocking pipe sessions), so that the
// Node ports keep the same accepted inputs, error kinds and output bytes.
// Transport only: no protocol expectations or verdicts live here.
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {accessSync, constants, existsSync, readFileSync, realpathSync} from 'node:fs';
import os from 'node:os';
import {basename, delimiter, dirname, isAbsolute, join, relative, resolve, sep} from 'node:path';

export const sha256=bytes=>createHash('sha256').update(bytes).digest('hex');
export const digest=path=>sha256(readFileSync(path));

// Python truthiness for decoded JSON values (empty list/dict/string are false).
export function truthy(v) {
  if(v===null||v===undefined||v===false||v===0||v==='')return false;
  if(Array.isArray(v))return v.length>0;
  if(typeof v==='object')return Object.keys(v).length>0;
  return true;
}

// str.splitlines(): Python's line boundaries, no trailing empty piece.
const BOUNDARY=/\r\n|[\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029]/g;
export function splitlines(text,keepends=false) {
  const out=[];let at=0;
  for(const m of text.matchAll(BOUNDARY)) {
    out.push(text.slice(at,keepends?m.index+m[0].length:m.index));
    at=m.index+m[0].length;
  }
  if(at<text.length)out.push(text.slice(at));
  return out;
}

// base64.b64decode(text, validate=True): alphabet and padding are strict.
export function b64decode(text) {
  if(!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(text))throw new Error('Invalid base64 input');
  return Buffer.from(text,'base64');
}

// bytes.decode() / decode('ascii'): strict, no replacement characters.
export function decodeUtf8(bytes) {
  return new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(bytes);
}

// json.loads with object_pairs_hook/parse_int/parse_float/parse_constant
// rejection hooks. Same grammar as Python's scanner, including NaN/Infinity
// tokens (handed to `numeric`) and whitespace handling; hooks fire in parse
// order, so the first defect in the text decides the error.
export function strictJson(input,{duplicate,numeric}) {
  // Python detects a UTF-8 signature on bytes input only.
  const text=typeof input==='string'?input:new TextDecoder('utf-8',{fatal:true}).decode(input);
  let at=0;
  const bad=what=>new SyntaxError(`${what}: char ${at}`);
  const space=()=>{while(at<text.length&&' \t\n\r'.includes(text[at]))at++;};
  const NUMBER=/(-?(?:0|[1-9][0-9]*))(\.[0-9]+)?([eE][-+]?[0-9]+)?/y;
  function string() {
    let out='';at++;
    for(;;) {
      if(at>=text.length)throw bad('Unterminated string');
      const c=text[at++];
      if(c==='"')return out;
      if(c<' ')throw bad('Invalid control character');
      if(c!=='\\'){out+=c;continue;}
      if(at>=text.length)throw bad('Unterminated string');
      const e=text[at++];
      if(e==='u') {
        const hex=text.slice(at,at+4);
        if(!/^[0-9a-fA-F]{4}$/.test(hex))throw bad('Invalid \\uXXXX escape');
        out+=String.fromCharCode(parseInt(hex,16));at+=4;
      } else {
        const simple={'"':'"','\\':'\\','/':'/',b:'\b',f:'\f',n:'\n',r:'\r',t:'\t'}[e];
        if(simple===undefined)throw bad('Invalid \\escape');
        out+=simple;
      }
    }
  }
  function value() {
    const c=text[at];
    if(c==='"')return string();
    if(c==='{') {
      const pairs=[];at++;space();
      if(text[at]==='}'){at++;return finish(pairs);}
      for(;;) {
        if(text[at]!=='"')throw bad('Expecting property name enclosed in double quotes');
        const key=string();space();
        if(text[at]!==':')throw bad("Expecting ':' delimiter");
        at++;space();
        pairs.push([key,value()]);space();
        if(text[at]==='}'){at++;return finish(pairs);}
        if(text[at]!==',')throw bad("Expecting ',' delimiter");
        at++;space();
      }
    }
    if(c==='[') {
      const items=[];at++;space();
      if(text[at]===']'){at++;return items;}
      for(;;) {
        items.push(value());space();
        if(text[at]===']'){at++;return items;}
        if(text[at]!==',')throw bad("Expecting ',' delimiter");
        at++;space();
      }
    }
    if(text.startsWith('null',at)){at+=4;return null;}
    if(text.startsWith('true',at)){at+=4;return true;}
    if(text.startsWith('false',at)){at+=5;return false;}
    NUMBER.lastIndex=at;
    if(NUMBER.test(text))throw numeric();
    for(const constant of ['NaN','Infinity','-Infinity'])if(text.startsWith(constant,at))throw numeric();
    throw bad('Expecting value');
  }
  function finish(pairs) {
    const seen=new Set();
    for(const [key] of pairs) {
      if(seen.has(key))throw duplicate();
      seen.add(key);
    }
    return Object.fromEntries(pairs);
  }
  space();
  const result=value();
  space();
  if(at!==text.length)throw bad('Extra data');
  return result;
}

// json.dumps. Defaults match Python's: ensure_ascii, ", " and ": " separators.
// indent uses "," line breaks and ": ", as Python does. undefined is a port
// defect (Python has no such value), never silently dropped.
export function dumps(value,{indent=null,sortKeys=false,compact=false,ascii=true}={}) {
  const quote=s=>'"'+s.replace(ascii?/["\\]|[^ -~]/g:/["\\\x00-\x1f]/g,c=>{
    const short={'"':'\\"','\\':'\\\\','\n':'\\n','\r':'\\r','\t':'\\t','\b':'\\b','\f':'\\f'}[c];
    return short??'\\u'+c.charCodeAt(0).toString(16).padStart(4,'0');
  })+'"';
  const item=indent===null?(compact?',':', '):',',colon=compact?':':': ';
  const walk=(v,depth)=>{
    if(v===null)return 'null';
    if(v===true)return 'true';
    if(v===false)return 'false';
    if(typeof v==='string')return quote(v);
    if(typeof v==='number') {
      if(!Number.isFinite(v))throw new Error('Non-finite number in JSON output');
      return String(v);
    }
    if(typeof v!=='object')throw new Error('Unserializable value in JSON output: '+typeof v);
    const open=indent===null?'':'\n'+' '.repeat(indent*(depth+1)),close=indent===null?'':'\n'+' '.repeat(indent*depth);
    if(Array.isArray(v)) {
      if(!v.length)return '[]';
      return '['+open+v.map(x=>walk(x,depth+1)).join(item+open)+close+']';
    }
    if(Buffer.isBuffer(v))throw new Error('Bytes in JSON output');
    // Python sorts keys by code point; UTF-16 order agrees for the ASCII keys used here.
    const keys=sortKeys?Object.keys(v).sort():Object.keys(v);
    if(!keys.length)return '{}';
    return '{'+open+keys.map(k=>quote(k)+colon+walk(v[k],depth+1)).join(item+open)+close+'}';
  };
  return walk(value,0);
}

// Path.resolve(): absolute, with symlinks followed for the part that exists.
export function pyResolve(path) {
  let head=resolve(String(path));const tail=[];
  while(!existsSync(head)) {
    const parent=dirname(head);
    if(parent===head)break;
    tail.unshift(basename(head));head=parent;
  }
  return join(realpathSync(head),...tail);
}
export function isRelativeTo(path,base) {
  const inside=relative(base,path);
  return inside===''||(!inside.startsWith('..'+sep)&&inside!=='..'&&!isAbsolute(inside));
}

// shutil.which for a plain command name.
export function which(name) {
  for(const dir of (process.env.PATH||'').split(delimiter)) {
    if(!dir)continue;
    const candidate=join(dir,name);
    try{accessSync(candidate,constants.X_OK);return candidate;}catch{}
  }
  return null;
}

// subprocess returncode: a signal death is the negated signal number.
export const returncode=(code,signal)=>signal?-os.constants.signals[signal]:code;

// Kill a process group this tool created, as os.killpg in the Python tools.
// A group whose leader already exited may report EPERM on Darwin; the caller
// always reaps and independently verifies that no live members remain.
export function killGroup(child) {
  try{process.kill(-child.pid,'SIGKILL');}
  catch(e) {
    if(e.code==='ESRCH')return;
    if(e.code==='EPERM'){if(child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');return;}
    throw e;
  }
}

// argparse behaviour that callers can observe: usage plus "error:" on stderr
// and exit status 2. Options may be given as "--name value" or "--name=value".
export class CliError extends Error {}
export function parseCli(argv,{prog,options={},positionals=[]}) {
  const usage='usage: '+[prog,...Object.entries(options).map(([flag,o])=>o.required?`${flag} ${o.metavar}`:`[${flag} ${o.metavar}]`),...positionals].join(' ');
  const fail=message=>{throw new CliError(`${usage}\n${prog}: error: ${message}`);};
  const out={},rest=[];
  for(const [flag,o] of Object.entries(options))out[flag.slice(2).replaceAll('-','_')]=o.default??null;
  for(let i=0;i<argv.length;i++) {
    const arg=argv[i];
    if(!arg.startsWith('--')||arg==='--'){rest.push(arg);continue;}
    const eq=arg.indexOf('='),flag=eq<0?arg:arg.slice(0,eq);
    const o=options[flag];
    if(!o)fail('unrecognized arguments: '+arg);
    let raw;
    if(eq>=0)raw=arg.slice(eq+1);
    else if(i+1<argv.length&&!(argv[i+1].startsWith('-')&&argv[i+1].length>1&&!/^-[0-9.]+$/.test(argv[i+1])))raw=argv[++i];
    else fail(`argument ${flag}: expected one argument`);
    if(o.type==='int') {
      if(!/^[+-]?[0-9]+$/.test(raw.trim()))fail(`argument ${flag}: invalid int value: '${raw}'`);
      raw=Number(raw.trim());
    }
    out[flag.slice(2).replaceAll('-','_')]=raw;
  }
  const missing=Object.entries(options).filter(([flag,o])=>o.required&&out[flag.slice(2).replaceAll('-','_')]===null).map(([flag])=>flag);
  if(rest.length<positionals.length)missing.push(...positionals.slice(rest.length));
  if(missing.length)fail('the following arguments are required: '+missing.join(', '));
  if(rest.length>positionals.length)fail('unrecognized arguments: '+rest.slice(positionals.length).join(' '));
  positionals.forEach((name,i)=>{out[name]=rest[i];});
  out.fail=fail;
  return out;
}
// Entry wrapper: argument errors exit 2, any other failure exits 1 with its
// stack (as an uncaught Python exception did), an integer result is the status.
export async function runMain(main) {
  try {
    const code=await main(process.argv.slice(2));
    if(Number.isInteger(code))process.exitCode=code;
  } catch(e) {
    if(e instanceof CliError){process.stderr.write(e.message+'\n');process.exit(2);}
    console.error(e?.stack||e);
    process.exit(1);
  }
}

// One foreground child in its own session with piped stdout/stderr and an
// optional piped stdin, exposing the primitives the Python sessions used:
// a bounded wait for readable output (selector.select), a non-blocking write
// that reports how many bytes the pipe took, and process-group cleanup.
export class PipeChild {
  constructor(argv,{cwd,input=true}) {
    this.child=spawn(argv[0],argv.slice(1),{cwd,detached:true,stdio:[input?'pipe':'ignore','pipe','pipe']});
    this.pid=this.child.pid;
    this.spawnError=null;this.exit=null;
    this.queues={stdout:[],stderr:[]};this.open=new Set(['stdout','stderr']);
    this.wake=null;this.writing=false;this.written=null;this.inputClosed=!input;
    const notify=()=>{if(this.wake){const w=this.wake;this.wake=null;w();}};
    this.exited=new Promise(done=>{
      // A launcher that cannot start never reports an exit; settle so cleanup still runs.
      this.child.on('error',e=>{this.spawnError=e;notify();done();});
      this.child.on('exit',(code,signal)=>{this.exit=returncode(code,signal);notify();done();});
    });
    for(const label of ['stdout','stderr']) {
      this.child[label].on('data',chunk=>{this.queues[label].push(chunk);notify();});
      this.child[label].on('end',()=>{this.queues[label].push(null);notify();});
      this.child[label].on('error',()=>{});
    }
    // A closed reader surfaces through the write callback, never as an unhandled event.
    if(input)this.child.stdin.on('error',()=>{});
  }
  get stdinOpen(){return !this.inputClosed;}
  // Start writing a prefix of the pending bytes. Returns false while an earlier
  // write has not been accepted by the pipe (BlockingIOError in the Python loop).
  startWrite(bytes) {
    if(this.writing||this.inputClosed)return false;
    const piece=Buffer.from(bytes);
    this.writing=true;
    this.child.stdin.write(piece,error=>{this.writing=false;this.written=error?{error}:{count:piece.length};if(this.wake){const w=this.wake;this.wake=null;w();}});
    return true;
  }
  // The outcome of the last write once the pipe has taken it: {count} or {error}.
  takeWritten(){const w=this.written;this.written=null;return w;}
  closeInput(){if(!this.inputClosed){this.inputClosed=true;this.child.stdin.end();}}
  // At most one chunk per stream, stdout first; a null chunk is end of stream.
  async select(ms) {
    if(this.spawnError)throw this.spawnError;
    const ready=()=>['stdout','stderr'].filter(l=>this.queues[l].length);
    if(!ready().length) {
      let timer;
      await new Promise(done=>{this.wake=done;timer=setTimeout(done,ms);});
      clearTimeout(timer);
    }
    this.wake=null;
    if(this.spawnError)throw this.spawnError;
    return ready().map(label=>{
      const chunk=this.queues[label].shift();
      if(chunk===null)this.open.delete(label);
      return {label,chunk};
    });
  }
  get streamsOpen(){return this.open.size>0;}
  async wait(ms) {
    if(this.exit!==null)return this.exit;
    let timer;
    await Promise.race([this.exited,new Promise(done=>{timer=setTimeout(done,ms);})]);
    clearTimeout(timer);
    if(this.spawnError)throw this.spawnError;
    if(this.exit===null)throw new Error('Child did not exit within '+ms+' ms');
    return this.exit;
  }
  kill(){killGroup(this.child);}
  async reap(){await this.exited;this.child.stdout.destroy();this.child.stderr.destroy();}
}
