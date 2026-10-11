// Benign boundary probes for tools/tc0/sandbox.mjs, development tier, NOT qualification.
// Usage: node tools/tc0/check-sandbox.mjs OUTPUT.json
// Each probe is a candidate patch (a runtime/tc0/pure-call-machine.mjs that attempts one
// action on import, then behaves normally) run in a throwaway copy of the candidate tree.
// Every probe runs twice: unsandboxed, as a control showing the action really happens, and
// inside the sandbox. Effects are measured from outside wherever possible: file hashes,
// a TCP listener in the parent's network namespace, and canary strings that can only be
// printed by a probe that actually obtained them.
import {spawnSync,spawn} from 'node:child_process';
import {createHash,randomBytes} from 'node:crypto';
import {cpSync,existsSync,mkdirSync,mkdtempSync,readFileSync,rmSync,writeFileSync} from 'node:fs';
import {createServer} from 'node:net';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {sandboxArgv,SANDBOX_ENV} from './sandbox.mjs';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const output=resolve(process.argv[2]??'');
if(!output.endsWith('.json')||existsSync(output))throw new Error('Usage: check-sandbox.mjs FRESH_OUTPUT.json');
const sha=b=>createHash('sha256').update(b).digest('hex');
const pre=spawnSync('unshare',['-n','--','true']);if(pre.error||pre.status!==0){console.error('BLOCKED: cannot create a network namespace');process.exit(2);}
mkdirSync(resolve(root,'build/tc0'),{recursive:true});
const base=mkdtempSync(resolve(root,'build/tc0/sandbox-probe-'));
const canary='canary-'+randomBytes(12).toString('hex');
const server=createServer(socket=>{connections.push(Date.now());socket.end();}),connections=[];
await new Promise(r=>server.listen(0,'127.0.0.1',r));const port=server.address().port;
// Each probe body runs at candidate import and reports what it obtained on stderr.
const PROBES={
 'baseline':``,
 'write-protected-model':`fs.appendFileSync(T+'/models/tc0/pure-call-machine.shen','\\n\\\\\\\\ probe');`,
 'write-new-file':`fs.writeFileSync(T+'/written-by-probe.txt','x');`,
 'read-secret-file':`process.stderr.write('GOT '+fs.readFileSync(T+'/secret/credential.txt','utf8')+'\\n');`,
 'read-model-source':`process.stderr.write('GOT '+fs.readFileSync(T+'/models/tc0/pure-call-machine.shen','utf8').length+'\\n');`,
 'read-environment-credential':`process.stderr.write('GOT '+(process.env.FENRIR_PROBE_TOKEN??'none')+'\\n');`,
 'spawn-process':`process.stderr.write('GOT '+cp.execSync('echo ${canary}').toString());`,
 'worker-thread':`await new Promise((ok,no)=>{const w=new wt.Worker("require('worker_threads').parentPort.postMessage('${canary}')",{eval:true});w.on('message',m=>{process.stderr.write('GOT '+m+'\\n');ok();});w.on('error',no);});`,
 'network-connect':`await new Promise((ok,no)=>{const s=net.connect(${port},'127.0.0.1',()=>{s.destroy();ok();});s.on('error',no);});`
};
const machine=readFileSync(resolve(root,'runtime/tc0/pure-call-machine.mjs'),'utf8');
const program=resolve(root,'fixtures/tc0/pure-call-forward.json');
function tree(name){
 const t=join(base,name);for(const d of ['tools/tc0','runtime/tc0','models/tc0'])cpSync(resolve(root,d),join(t,d),{recursive:true});
 mkdirSync(join(t,'secret'));writeFileSync(join(t,'secret/credential.txt'),canary);cpSync(program,join(t,'program.json'));return t;
}
async function attempt(name,sandboxed){
 const t=tree(name+(sandboxed?'-sandboxed':'-control'));
 const body=PROBES[name];
 writeFileSync(join(t,'runtime/tc0/pure-call-machine.mjs'),`import fs from 'node:fs';import cp from 'node:child_process';import wt from 'node:worker_threads';import net from 'node:net';\nconst T=${JSON.stringify(t)};\ntry{${body}}catch(e){process.stderr.write('DENIED '+(e.code??e.message)+'\\n');}\n`+machine);
 const before={model:sha(readFileSync(join(t,'models/tc0/pure-call-machine.shen'))),written:existsSync(join(t,'written-by-probe.txt'))},seen=connections.length;
 const script=join(t,'tools/tc0/run-pure-call.mjs'),args=[join(t,'program.json')];
 const argv=sandboxed?sandboxArgv({read:[join(t,'tools/tc0'),join(t,'runtime/tc0'),join(t,'program.json')],script,args}):[process.execPath,script,...args];
 const r=spawnSync(argv[0],argv.slice(1),{encoding:'utf8',timeout:20000,env:sandboxed?SANDBOX_ENV:{...process.env,FENRIR_PROBE_TOKEN:canary}});
 // spawnSync blocks the loop; let the listener record any accepted connection first.
 await new Promise(r=>setTimeout(r,100));
 const after={model:sha(readFileSync(join(t,'models/tc0/pure-call-machine.shen'))),written:existsSync(join(t,'written-by-probe.txt'))};
 const obtained={
  'write-protected-model':before.model!==after.model,'write-new-file':!before.written&&after.written,
  'read-secret-file':r.stderr.includes('GOT '+canary),'read-model-source':/GOT \d+/.test(r.stderr),
  'read-environment-credential':r.stderr.includes('GOT '+canary),'spawn-process':r.stderr.includes('GOT '+canary),
  'worker-thread':r.stderr.includes('GOT '+canary),'network-connect':connections.length>seen,'baseline':null}[name];
 return {r,t,obtained};
}
const rows=[];
for(const name of Object.keys(PROBES)){
 const control=await attempt(name,false),sandboxed=await attempt(name,true);
 const row={probe:name,control:{exit:String(control.r.status),obtained:control.obtained},sandboxed:{exit:String(sandboxed.r.status),obtained:sandboxed.obtained,denial:(sandboxed.r.stderr.match(/DENIED (\S+)/)??[])[1]??null}};
 if(name==='baseline'){row.control.stdout_sha256=sha(control.r.stdout);row.sandboxed.stdout_sha256=sha(sandboxed.r.stdout);row.semantics_preserved=control.r.status===0&&sandboxed.r.status===0&&control.r.stdout===sandboxed.r.stdout;}
 else row.enforced=control.obtained===true&&sandboxed.obtained===false;
 rows.push(row);
}
server.close();rmSync(base,{recursive:true,force:true});
const ok=rows.every(r=>r.probe==='baseline'?r.semantics_preserved:r.enforced);
const report={schema:'tc0-sandbox-probes/1',qualification:'UNKNOWN',boundary:'tools/tc0/sandbox.mjs: unshare -n + Node --permission + scrubbed environment',
 node:process.version,sandbox_sha256:sha(readFileSync(resolve(root,'tools/tc0/sandbox.mjs'))),probes_sha256:sha(readFileSync(fileURLToPath(import.meta.url))),
 all_enforced:ok,rows,not_bounded:['CPU, memory and wall time (callers keep watchdogs)','Reads Node performs itself at startup','Timing and other side channels','Kernel or Node permission-model defects']};
writeFileSync(output,JSON.stringify(report,null,1)+'\n',{flag:'wx'});
console.log(JSON.stringify({qualification:'UNKNOWN',all_enforced:ok,rows:rows.map(r=>[r.probe,r.probe==='baseline'?r.semantics_preserved:r.enforced,r.sandboxed.denial])}));
process.exit(ok?0:1);
