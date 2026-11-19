// One request served by a peer's program (spec/tc1/EFFECTS.md §12.12): the JavaScript
// handler machine, unchanged, with the peer's store carried out here. UNQUALIFIED.
// No model, oracle or validator imports.
//
// A peer's program (artifact schema tc1-handler-demo/4) has one function for each operation
// it serves. A request is one run of that function on the request's input: tuple(key, a)
// for an operation that is not read-only, a for a read-only one. The store is a finite map
// from I64 to I64; a cell that was never written reads 0. The program reaches it through
// two effects no frame handles, StoreRead.get and StoreWrite.put. When the machine is
// Ready at a perform of one of them, this file gives the perform its value and the machine
// takes no step for it: the frames stay where they are, as for a caller's remote perform.
//   get(k)      the value this request last put at k, else the store's, else 0
//   put((k,v))  kept aside in the request's write buffer; unit
// Nothing here commits: the result says what the request would write, and the peer's
// runtime commits that together with the request's record, or not at all.
//
// Result: {execution, outcome, trace, writes}
//   trace   in order, the machine's step records and, for each store perform,
//           {store:'get'|'put', key, value}
//   writes  [[key, value]] in ascending key order: the final value of each cell written.
//           Meaningful only when the outcome is Ok: a trap commits nothing.
//
// Injected defect, for the harness to detect (never enabled by default):
//   staleReads   get ignores what this request has written
import {HandlerMachine} from './handler-machine.mjs';

export const STORE_READ='StoreRead',STORE_WRITE='StoreWrite';

// The store perform the machine is Ready at, when no handler frame handles its effect.
function storePerform(machine) {
  const c=machine.control;
  if(c.kind!=='Ready'||c.operation!=='perform')return null;
  const [effect,operation]=c.metadata;
  if(!((effect===STORE_READ&&operation==='get')||(effect===STORE_WRITE&&operation==='put')))return null;
  if(machine.frames.some(f=>f.kind==='Handle'&&f.effect===effect))return null;
  return {effect,argument:c.values[0]};
}

// store: Map from decimal key to decimal value (canonical I64 text).
export function serveRequest(artifact,functionName,input,store,{staleReads=false,fuel=2000}={}) {
  if(!artifact.functions.some(f=>f.name===functionName))throw new Error('No such function');
  const machine=new HandlerMachine({...artifact,entry:functionName},input),buffer=new Map(),trace=[];
  let steps=0;
  while(!machine.terminal&&steps<fuel) {
    const perform=storePerform(machine);
    if(!perform){trace.push(machine.step());steps++;continue;}
    if(perform.effect===STORE_READ) {
      const key=perform.argument[1],value=(!staleReads&&buffer.has(key))?buffer.get(key):store.has(key)?store.get(key):'0';
      trace.push({store:'get',key,value});machine.control={kind:'Value',value:['int',value]};
    } else {
      const key=perform.argument[1][1],value=perform.argument[2][1];
      buffer.set(key,value);trace.push({store:'put',key,value});machine.control={kind:'Value',value:['unit']};
    }
  }
  const writes=[...buffer].sort((a,b)=>BigInt(a[0])<BigInt(b[0])?-1:1);
  return {execution:machine.terminal?'Completed':'BudgetExhausted',outcome:machine.terminal,trace,writes};
}
