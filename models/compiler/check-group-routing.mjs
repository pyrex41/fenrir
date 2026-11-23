// Evaluate the routing skeleton of the validated framed-log update. Distinct
// child tokens make duplicating or moving an untouched field observable.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {validatePureCallArtifact} from '../../tools/tc0/pure-call-artifact.mjs';

const {artifact} = validatePureCallArtifact(readFileSync(process.argv[2]), ['int', '0'], {maxNodes: 2000});
const group = artifact.functions.find(fn => fn.name === 'update-group');
const vacant = {tag: 'Vacant', fields: []};
const size = Symbol('size'), sum = Symbol('sum');

function route(tree, key, depth = 0) {
  assert.ok(depth <= 1, 'unexpected recursive promotion');
  const env = new Map([[group.parameter_id, [tree, BigInt(key), size, sum]]]);
  function evaluate(node) {
    switch (node[0]) {
      case 'var': assert.ok(env.has(node[2])); return env.get(node[2]);
      case 'int': return BigInt(node[2]);
      case 'project': return evaluate(node[2])[Number(node[3])];
      case 'let': env.set(node[2], evaluate(node[3])); return evaluate(node[4]);
      case 'tuple': return node.slice(2).map(evaluate);
      case 'construct': return {tag: node[3], fields: node.slice(4).map(evaluate)};
      case 'if': return evaluate(evaluate(node[2]) ? node[3] : node[4]);
      case 'match': {
        const subject = evaluate(node[2]);
        const arm = node.slice(3).find(([tag]) => tag === subject.tag);
        assert.equal(arm[1].length, subject.fields.length);
        arm[1].forEach((binder, i) => env.set(binder, subject.fields[i]));
        return evaluate(arm[2]);
      }
      case 'call': {
        const [cell, k, n, s] = evaluate(node[3]);
        assert.deepEqual([k, n, s], [BigInt(key), size, sum]);
        if (node[2] === 'update-group') return route(cell, key, depth + 1);
        assert.equal(node[2], 'update-pair');
        return {updated: cell};
      }
      case 'prim': {
        const a = evaluate(node[3]), b = evaluate(node[4]);
        switch (node[2]) {
          case 'lt': return a < b;
          case 'eq': return a === b;
          case 'div': return a / b;
          case 'mul': return a * b;
          case 'sub': return a - b;
        }
      }
    }
    throw Error('unsupported routing expression ' + node.slice(0, 3));
  }
  return evaluate(group.body);
}

const slot = key => Math.floor((key % 16) / 2);
for (let key = 0; key < 64; key++) {
  const fields = Array.from({length: 8}, (_, i) => Symbol(String(i)));
  const expected = [...fields];
  expected[slot(key)] = {updated: fields[slot(key)]};
  assert.deepEqual(route({tag: 'Branch', fields}, key), {tag: 'Branch', fields: expected});
  assert.deepEqual(route(vacant, key), {updated: vacant});
  const groupStart = key - key % 16;
  for (let even = groupStart; even < groupStart + 16; even += 2) {
    const pair = {tag: 'Pair', fields: [BigInt(even), 0n, 0n, 0n, 0n, 0n, 0n]};
    if (slot(key) === slot(even)) {
      assert.deepEqual(route(pair, key), {updated: pair});
    } else {
      const children = Array(8).fill(vacant);
      children[slot(even)] = pair;
      children[slot(key)] = {updated: vacant};
      assert.deepEqual(route(pair, key), {tag: 'Branch', fields: children});
    }
  }
}
console.log('Passed 64 branch routes, 64 vacant routes and 512 existing-pair routes.');
