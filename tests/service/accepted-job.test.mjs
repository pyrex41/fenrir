// The JavaScript accepted-job implementation against the hand-derived traces of
// spec/service/hand-traces.json and small hand-derived exploration counts.
// Development checks of the candidate, NOT evidence about the contract: the
// model-side checks and the differential comparison are in
// harness/service-explore.shen.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {AcceptedJobService,Disabled} from '../../runtime/service/accepted-job.mjs';
import {exploreGraph} from '../../runtime/service/explore-graph.mjs';

const hand=JSON.parse(readFileSync(new URL('../../spec/service/hand-traces.json',import.meta.url),'utf8'));
const params={keys:2,digests:2};
const enabled=(svc,label)=>svc.alphabet(params).some(l=>JSON.stringify(l)===JSON.stringify(label));

for(const trace of hand.traces){
  test(`hand trace ${trace.name}`,()=>{
    const svc=new AcceptedJobService(hand.tenants),responses=[];
    for(const [i,label] of trace.schedule.entries()){
      if(trace.disabled_at===i){
        assert.equal(enabled(svc,label),false,'label should not be in the alphabet');
        assert.throws(()=>svc.apply(label),Disabled);
        return;
      }
      assert.ok(enabled(svc,label),'label '+JSON.stringify(label)+' should be enabled at step '+i);
      responses.push(svc.apply(label));
    }
    assert.equal(trace.disabled_at,undefined,'the schedule should have stopped');
    assert.deepEqual(responses,trace.responses);
    assert.deepEqual(svc.observe(),trace.final);
  });
}

test('a retry or a refused reuse leaves the stores unchanged',()=>{
  const svc=new AcceptedJobService(2);
  svc.submit(1,1,0);
  const before=JSON.stringify(svc.observe()[0]);
  assert.deepEqual(svc.apply(['submit',1,1,0]),['accepted',[1,1,0,0,0]]);
  assert.deepEqual(svc.apply(['submit',1,1,1]),['conflict',1,1]);
  assert.equal(JSON.stringify(svc.observe()[0]),before);
});

test('a terminal job keeps its status under every later delivery',()=>{
  const svc=new AcceptedJobService(1);
  svc.submit(0,0,0);svc.complete(0,0,false);
  for(const ok of [true,false])svc.complete(0,0,ok);
  assert.deepEqual(svc.observe()[0][0][1],[[0,0,'failed']]);
});

test('clones are independent',()=>{
  const a=new AcceptedJobService(1);a.submit(0,0,0);
  const b=a.clone();b.complete(0,0,true);b.crash();b.submit(0,1,1);
  assert.deepEqual(a.observe(),[[[[[0,0]],[[0,0,'pending']],[[0,0,[0,0,0,0,0]]],1]],[['accepted',[0,0,0,0,0]]],[]]);
});

test('labels outside the alphabet are refused',()=>{
  const svc=new AcceptedJobService(1);
  assert.throws(()=>svc.apply(['submit',1,0,0]),Disabled);
  assert.throws(()=>svc.apply(['respond',['conflict',0,0]]),Disabled);
  assert.throws(()=>svc.apply(['stage',0,0]),Disabled);
  assert.throws(()=>svc.apply(['complete',0,0,1]),TypeError);
});

// Hand-derived: one tenant, key and digest; one submit and one response, no
// delivery or crash budget. Schedules: [], [submit], [submit, respond].
test('exploration counts on a hand-derived scope',()=>{
  const lines=[];
  const s=exploreGraph({tenants:1,keys:1,digests:1,budgets:[1,0,1,0],cap:100,onEdge:l=>lines.push(l)});
  assert.equal(s.states,3);assert.equal(s.runtime_states,3);assert.equal(s.runtime_edges,2);
  assert.equal(s.schedules,'3');assert.equal(s.max_depth,2);assert.equal(s.truncated,false);
  // Cut by budget: at the root, deliveries of id 0 (2 labels) and the crash; after the
  // submit, the submit, deliveries of ids 0 and 1 (4) and the crash; after the response,
  // the same plus the response.
  assert.deepEqual(s.bound_hits,{submits:2,deliveries:2+4+4,responses:1,crashes:3});
  assert.deepEqual(JSON.parse(lines[0]),[[[[[],[],[],0]],[],[]],['submit',0,0,0],
    [[[[[0,0]],[[0,0,'pending']],[[0,0,[0,0,0,0,0]]],1]],[['accepted',[0,0,0,0,0]]],[]],['accepted',[0,0,0,0,0]]]);
});

test('a truncated exploration says so',()=>{
  const s=exploreGraph({tenants:2,keys:2,digests:2,budgets:[2,1,1,1],cap:10});
  assert.equal(s.truncated,true);assert.ok(s.states<=10);
});

test('exploration is deterministic',()=>{
  const run=()=>{const lines=[];const s=exploreGraph({tenants:2,keys:2,digests:2,budgets:[2,1,1,1],cap:100000,onEdge:l=>lines.push(l)});return [s.states,s.runtime_edges,s.schedules,lines.join('\n')];};
  assert.deepEqual(run(),run());
});
