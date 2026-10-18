// Evaluator-side mutant tests; withheld from S3 repair workspaces with the mutants.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { encode } from '../../tools/tc0/canonical.mjs';
import { validatePureCallArtifact } from '../../tools/tc0/pure-call-artifact.mjs';
import { PureCallMachine } from '../../runtime/tc0/pure-call-machine.mjs';
import { MUTANTS, mutantSource, createMachine } from '../../tools/tc0/pure-call-mutants.mjs';
import { cases as callCases } from '../../fixtures/tc0/pure-call-hand-cases.mjs';
import { cases as dataCases } from '../../fixtures/tc0/pure-data-hand-cases.mjs';
import { pureCallHeader } from '../../tools/tc0/pure-call-replay-header.mjs';
import { recordPureCall, replayPureCall, stateHash } from '../../tools/tc0/pure-call-replay.mjs';

const source = readFileSync(
  new URL('../../runtime/tc0/pure-call-machine.mjs', import.meta.url),
  'utf8'
);
const check = a => validatePureCallArtifact(encode(a), ['int', '0']);
const data = name => check(structuredClone(dataCases.find(c => c.name === name).program));
const setup = (program, options) => {
  const machine = () => createMachine(program, ['int', '0'], options);
  const reference = new PureCallMachine(program, ['int', '0']).run().steps;
  const m = machine();
  const header = pureCallHeader(m, program, ['int', '0'], reference, { unit_mock: true });
  return { machine, reference, header, bundle: recordPureCall(m, reference, header) };
};

test('the candidate carries no mutant options; every mutant applies exactly', () => {
  assert.doesNotMatch(
    source,
    /reverseOperands|wrapOverflow|armByPosition|constructorIndex|[Mm]utant/
  );
  for (const option of Object.keys(MUTANTS))
    assert.notEqual(mutantSource(source, option), source, option);
  assert.throws(
    () => mutantSource(source.replace('const operands =', 'let operands ='), 'reverseOperands'),
    /changed shape/
  );
  assert.throws(
    () => createMachine(check(callCases[0].program).artifact, ['int', '0'], { bogus: true }),
    /Unknown/
  );
  assert.throws(
    () =>
      createMachine(check(callCases[0].program).artifact, ['int', '0'], {
        reverseOperands: true,
        wrapOverflow: true
      }),
    /At most one/
  );
});

test('a mutant instance is a distinct replay identity from the reference', () => {
  const { artifact } = check(callCases[0].program);
  const reference = new PureCallMachine(artifact, ['int', '0']);
  for (const option of Object.keys(MUTANTS)) {
    const m = createMachine(artifact, ['int', '0'], { [option]: true });
    assert.equal(m.variant, option);
    assert.notEqual(stateHash(m), stateHash(reference), option);
  }
});

test('reversed-order mutant exact divergence is not conformance PASS', () => {
  const s = setup(callCases.find(c => c.name === 'named-emit-order').program, {
    reverseOperands: true
  });
  assert.equal(s.bundle.footer.kind, 'Divergence');
  const r = replayPureCall(s.machine(), s.reference, s.header, s.bundle);
  assert.equal(r.replay, 'Exact');
  assert.equal(r.conformance, 'Diverged');
  assert.equal(r.execution, 'StoppedAtDivergence');
});

test('reverse-operands mutant is distinguished on tuple and constructor collection', () => {
  const v = data('tuple-left-to-right-project');
  const r = createMachine(v.artifact, v.input, { reverseOperands: true }).run();
  assert.deepEqual(r.outcome, ['Ok', ['int', '1']]);
  assert.deepEqual(
    r.events.filter(e => e.kind === 'Emit').map(e => e.label),
    ['right', 'left']
  );
  const s = setup(v.artifact, { reverseOperands: true });
  assert.equal(s.bundle.footer.kind, 'Divergence');
  assert.equal(
    replayPureCall(s.machine(), s.reference, s.header, s.bundle).conformance,
    'Diverged'
  );
});

test("wrap-overflow mutant replaces each Overflow trap with the two's-complement result", () => {
  const wrapped = name => {
    const v = data(name);
    return createMachine(v.artifact, v.input, { wrapOverflow: true }).run().outcome;
  };
  assert.deepEqual(wrapped('div-min-by-minus-one'), ['Ok', ['int', '-9223372036854775808']]);
  assert.deepEqual(wrapped('mul-exact-square-then-overflow'), [
    'Ok',
    ['int', String(BigInt.asIntN(64, 3037000499n * 3037000499n * 2n))]
  ]);
  assert.deepEqual(wrapped('gt-ge-mul-around-2-53'), ['Ok', ['int', '43']]);
});
