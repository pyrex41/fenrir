// Evidence checks are separate from semantic admissibility. Deleting a
// required milestone can leave a valid trace, but cannot certify this run.
import assert from 'node:assert/strict';

const pid=/^<\d+\.\d+\.\d+>$/;
export function overlap(history, proof, index, bank) {
  assert.equal(proof?.index,index,'missing or misplaced overlap evidence');
  assert.equal(proof.unit,'monotonic-microsecond');
  const e=history.events[index];
  assert.equal(e?.[0],'concurrent');
  assert.equal(e[1]?.length,2);
  assert.equal(proof.calls?.length,2);
  const [a,b]=proof.calls;
  for(const c of [a,b]){
    assert(Number.isSafeInteger(c.started)&&Number.isSafeInteger(c.ended));
    assert(c.started<c.ended,'invalid call interval');
    assert(typeof c.worker==='string');
    assert.match(c.worker,pid);
  }
  assert.notEqual(a.worker,b.worker,'calls used the same worker');
  assert(Math.max(a.started,b.started)<Math.min(a.ended,b.ended),'calls did not overlap');
  assert.deepEqual([a.worker,b.worker].sort(),[...bank].sort(),'call workers do not match the observed bank');
}

export function finalDrain(history, proof) {
  const i=history.events.length-2;
  assert.equal(proof?.index,i,'missing or misplaced drain evidence');
  assert.equal(proof.pending,0);
  assert.deepEqual(history.events[i],['drained']);
  const e=history.events[i+1];
  assert.equal(e[0],'observe');
  assert.equal(e[2][0],'v2');
  assert.equal(e[1].length,history.tenants);
  for(const tenant of e[1])for(const job of tenant[1]){
    assert(job[2]==='done'||job[2]==='failed','final observation contains unfinished work');
  }
}

// Run the same gate checks on explicit omission/substitution controls.
export function milestoneControls(h, overlapProof, index, bank, drain) {
  const controls=[];
  function unknown(name,f){
    assert.throws(f,assert.AssertionError);
    controls.push({name,status:'UNKNOWN'});
  }
  const copy=()=>structuredClone(h);
  const missing=copy();
  missing.events.splice(index,1);
  unknown('missing-overlap-event',()=>overlap(missing,overlapProof,index,bank));
  unknown('missing-overlap-record',()=>overlap(h,undefined,index,bank));
  const repeated=structuredClone(overlapProof);
  repeated.calls[1].worker=repeated.calls[0].worker;
  unknown('same-worker-twice',()=>overlap(h,repeated,index,bank));
  const serial=structuredClone(overlapProof);
  serial.calls[1].started=serial.calls[0].ended;
  serial.calls[1].ended=serial.calls[1].started+1;
  unknown('nonoverlapping-intervals',()=>overlap(h,serial,index,bank));
  const noDrain=copy();
  noDrain.events.splice(-2,1);
  unknown('missing-drained-event',()=>finalDrain(noDrain,drain));
  unknown('missing-drain-record',()=>finalDrain(h,undefined));
  return controls;
}
