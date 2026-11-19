// Explore the JavaScript accepted-job implementation over the same bounded scope
// as harness/service-explore.shen, independently of the model, and write every
// distinct runtime edge (state, label) -> (next state, response) once, as one
// canonical JSON line (spec/service/ACCEPTED_JOB.md section 3):
//   [state, label, next, response]
// The harness compares these lines with the model's as sets.
//
//   node runtime/service/explore-graph.mjs T K D S C R X CAP EDGES.jsonl SUMMARY.json
//
// T tenants, K keys, D digests; budgets S submits, C deliveries, R responses,
// X crashes; CAP the most (state, remaining budget) pairs before truncation.
// Also counts schedules: every enabled label sequence within the budgets,
// including the empty one (BigInt, as a decimal string).
import {writeFileSync,openSync,writeSync,closeSync} from 'node:fs';
import {AcceptedJobService} from './accepted-job.mjs';

const KIND={submit:0,complete:1,respond:2,crash:3};

export function exploreGraph({tenants,keys,digests,budgets,cap,onEdge=()=>{}}){
  const start=process.hrtime.bigint();
  const root=new AcceptedJobService(tenants);
  const rootText=JSON.stringify(root.observe());
  const seen=new Map();            // stateText|budget -> paths reaching it (BigInt)
  const runtime=new Set([rootText]);
  const edgeKeys=new Set();
  const hits=[0,0,0,0];
  let layer=[{svc:root,text:rootText,budget:budgets.slice(),paths:1n}];
  seen.set(rootText+'|'+budgets.join(','),layer[0]);
  let productEdges=0,depth=0,truncated=false,schedules=1n;
  while(layer.length){
    const next=[];
    for(const node of layer){
      for(const label of node.svc.alphabet({keys,digests})){
        const kind=KIND[label[0]];
        if(node.budget[kind]===0){hits[kind]++;continue;}
        const svc=node.svc.clone(),response=svc.apply(label),text=JSON.stringify(svc.observe());
        const budget=node.budget.slice();budget[kind]--;
        productEdges++;
        schedules+=node.paths;
        const labelText=JSON.stringify(label),edgeKey=node.text+'|'+labelText;
        if(!edgeKeys.has(edgeKey)){
          edgeKeys.add(edgeKey);
          onEdge('['+node.text+','+labelText+','+text+','+JSON.stringify(response)+']');
        }
        runtime.add(text);
        const id=text+'|'+budget.join(','),found=seen.get(id);
        if(found){found.paths+=node.paths;continue;}
        if(seen.size>=cap){truncated=true;continue;}
        const child={svc,text,budget,paths:node.paths};
        seen.set(id,child);next.push(child);
      }
    }
    if(next.length)depth++;
    layer=next;
  }
  return {schema:'fenrir.service.js-explore/1',implementation:'runtime/service/accepted-job.mjs',
    params:{tenants,keys,digests},budgets:{submits:budgets[0],deliveries:budgets[1],responses:budgets[2],crashes:budgets[3]},
    states:seen.size,runtime_states:runtime.size,runtime_edges:edgeKeys.size,edges:productEdges,max_depth:depth,
    schedules:schedules.toString(),truncated,
    bound_hits:{submits:hits[0],deliveries:hits[1],responses:hits[2],crashes:hits[3]},
    seconds:Number(process.hrtime.bigint()-start)/1e9};
}

if(import.meta.url===`file://${process.argv[1]}`){
  const a=process.argv.slice(2);
  if(a.length!==10)throw new Error('Usage: explore-graph.mjs T K D S C R X CAP EDGES.jsonl SUMMARY.json');
  const n=a.slice(0,8).map(x=>{const v=Number(x);if(!Number.isInteger(v)||v<0)throw new Error('not a count: '+x);return v;});
  const fd=openSync(a[8],'w');
  let buffer=[];
  const flush=()=>{if(buffer.length){writeSync(fd,buffer.join('\n')+'\n');buffer=[];}};
  const summary=exploreGraph({tenants:n[0],keys:n[1],digests:n[2],budgets:n.slice(3,7),cap:n[7],
    onEdge:line=>{buffer.push(line);if(buffer.length>=4096)flush();}});
  flush();closeSync(fd);
  writeFileSync(a[9],JSON.stringify(summary)+'\n');
}
