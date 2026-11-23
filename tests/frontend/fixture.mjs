#!/usr/bin/env node
// Test support for the frontend's round-trip check (frontend/test.sh).
//
//   node tests/frontend/fixture.mjs write NAME OUT.json
//     writes the program of the hand fixture NAME (fixtures/tc0, fixtures/tc1)
//   node tests/frontend/fixture.mjs same A.json B.json
//     exits 0 when the two artifacts are the same program up to a renaming of
//     IDs, ignoring what a frontend cannot share with a hand fixture: the
//     identity fields (contract, schema, slice), the module name and the source
//     map. Otherwise prints the first difference and exits 1.
import {readFileSync,writeFileSync} from 'node:fs';
import {encode} from '../../tools/tc0/canonical.mjs';
import {cases as callHand} from '../../fixtures/tc0/pure-call-hand-cases.mjs';
import {cases as dataHand} from '../../fixtures/tc0/pure-data-hand-cases.mjs';
import {cases as handlerCases,resumptionCases,closedAndCapturing} from '../../fixtures/tc1/handler-hand-cases.mjs';
import {cases as taskCases} from '../../fixtures/tc1/task-hand-cases.mjs';

const differ=(where,a,b)=>{console.log(`${where}: ${JSON.stringify(a)} against ${JSON.stringify(b)}`);process.exit(1);};
// Canonical encoding, so that the order of object keys does not matter.
const literal=(where,a,b)=>{if(!encode(a).equals(encode(b)))differ(where,a,b);};

// IDs correspond when one consistent renaming maps each ID of A to one of B.
function same(a,b) {
  const forward=new Map(),backward=new Map();
  const id=(where,x,y)=>{
    if(!forward.has(x)&&!backward.has(y)){forward.set(x,y);backward.set(y,x);}
    if(forward.get(x)!==y||backward.get(y)!==x)differ(where+' (IDs do not correspond)',x,y);
  };
  const ids=(where,xs,ys)=>{literal(where+' count',String(xs.length),String(ys.length));xs.forEach((x,i)=>id(where,x,ys[i]));};
  function expression(where,x,y) {
    literal(where+' tag',x[0],y[0]);literal(where+' arity',String(x.length),String(y.length));
    const [tag,node,...p]=x,[,other,...q]=y;where+='/'+tag;id(where,node,other);
    const each=(xs,ys)=>{literal(where+' operand count',String(xs.length),String(ys.length));xs.forEach((e,i)=>expression(where,e,ys[i]));};
    if(tag==='var'||tag==='discontinue')id(where,p[0],q[0]);
    else if(tag==='let'){id(where,p[0],q[0]);each(p.slice(1),q.slice(1));}
    else if(tag==='lambda'){id(where,p[0],q[0]);literal(where+' signature',p.slice(1,5),q.slice(1,5));expression(where,p[5],q[5]);}
    else if(tag==='resume'){id(where,p[0],q[0]);expression(where,p[1],q[1]);}
    else if(tag==='channel')literal(where+' element type and capacity',p,q);
    else if(tag==='project'){expression(where,p[0],q[0]);literal(where+' index',p[1],q[1]);}
    else if(tag==='match') {
      expression(where,p[0],q[0]);
      p.slice(1).forEach((arm,i)=>{const [c,binders,body]=arm,[d,others,rest]=q[i+1];literal(where+' constructor',c,d);ids(where+' binders',binders,others);expression(where,body,rest);});
    } else if(tag==='handle') {
      literal(where+' effect',p[0],q[0]);literal(where+' clause count',String(p[1].length),String(q[1].length));
      p[1].forEach((clause,i)=>{const other=q[1][i];literal(where+' operation',clause[0],other[0]);ids(where+' clause binders',clause.slice(1,-1),other.slice(1,-1));expression(where,clause.at(-1),other.at(-1));});
      expression(where,p[2],q[2]);
    } else {
      // Leading strings and booleans are literal data (labels, names, values); the rest are operands.
      const data=v=>!Array.isArray(v);
      literal(where+' data',p.filter(data),q.filter(data));
      each(p.filter(v=>!data(v)),q.filter(v=>!data(v)));
    }
  }
  for(const key of ['datatypes','effects','entry','input_schema'])literal(key,a[key],b[key]);
  literal('function count',String(a.functions.length),String(b.functions.length));
  a.functions.forEach((f,i)=>{
    const g=b.functions[i],where='function '+f.name;
    for(const key of ['name','argument_type','result_type','effects'])literal(`${where} ${key}`,f[key],g[key]);
    id(where,f.id,g.id);id(where,f.parameter_id,g.parameter_id);expression(where,f.body,g.body);
  });
}

const [command,first,second]=process.argv.slice(2);
if(command==='write'&&second) {
  const found=[...callHand,...dataHand,...handlerCases,...resumptionCases,...taskCases,closedAndCapturing].find(c=>c.name===first);
  if(!found){console.error(`no hand fixture is named ${first}`);process.exit(2);}
  writeFileSync(second,JSON.stringify(found.program));
} else if(command==='same'&&second) {
  same(JSON.parse(readFileSync(first,'utf8')),JSON.parse(readFileSync(second,'utf8')));
} else {
  console.error('usage: node tests/frontend/fixture.mjs write NAME OUT.json | same A.json B.json');process.exit(2);
}
