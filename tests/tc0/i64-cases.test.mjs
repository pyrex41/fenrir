import test from 'node:test';
import assert from 'node:assert/strict';
import {VALUES, expected, cases} from '../../tools/tc0/check-i64.mjs';

// The Shen ports are external; these tests pin the expectation generator itself.
test('the boundary set brackets every width that matters', () => {
  const has=n=>VALUES.includes(n);
  for(const n of [-(1n<<63n),(1n<<63n)-1n,(1n<<53n)+1n,(1n<<61n)-1n,1n<<61n,1n<<62n,3037000499n,3037000500n,0n,-1n])assert.ok(has(n),String(n));
});
test('expected results follow TC0 checked arithmetic', () => {
  const max=(1n<<63n)-1n,min=-(1n<<63n);
  assert.equal(expected('add',max,1n),'[trap overflow]');
  assert.equal(expected('sub',min,1n),'[trap overflow]');
  assert.equal(expected('neg',min,null),'[trap overflow]');
  assert.equal(expected('div',min,-1n),'[trap overflow]');
  assert.equal(expected('div',-7n,2n),'[ok -3]');
  assert.equal(expected('div',7n,0n),'[trap div-zero]');
  assert.equal(expected('mul',3037000500n,3037000500n),'[trap overflow]');
  assert.equal(expected('mul',3037000499n,3037000499n),'[ok 9223372030926249001]');
  assert.equal(expected('compare',min,max),'-1');
});
test('the case list is the full product', () => {
  assert.equal(cases().length,VALUES.length*(1+5*VALUES.length));
});
