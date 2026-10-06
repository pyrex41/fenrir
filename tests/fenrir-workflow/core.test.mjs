import test from 'node:test';
import assert from 'node:assert/strict';
import {
  CLAIMS, STATE_TYPE, addReceipt, advance, budgetReason, countTurn,
  newState, parseCommand, pause, qualification, restore, resume, settle,
} from '../../.pi/extensions/fenrir-workflow/core.mjs';
import { localPath, validateConfig } from '../../.pi/extensions/fenrir-workflow/storage.mjs';

const sourceHash = 's'.repeat(64);
const configuration = () => validateConfig({ version: 1, requiredChecks: ['qualify'], checks: {
  qualify: { kind: 'qualification', command: ['node', 'tools/qualify.mjs'], timeoutSeconds: 10, authorityPaths: ['tools/qualify.mjs'] },
  dev: { kind: 'development', command: ['node', '--test'], timeoutSeconds: 10, authorityPaths: [] },
} });
const initial = () => newState({ cwd: '/repo', sessionId: 'session', configHash: 'c'.repeat(64), protectedHash: 'p'.repeat(64), now: 1000 });
function receipt(state, patch = {}) {
  return { id: 'receipt', runId: state.id, configHash: state.configHash, protectedHash: state.protectedHash,
    sourceHash, sourceStable: true, evidenceStable: true, runnerCleanup: 'confirmed', cleanup: 'confirmed',
    checkId: 'qualify', kind: 'qualification', phase: state.phase, verdict: 'PASS', claims: CLAIMS, evidence: [], ...patch };
}
const report = (phase, outcome) => ({ phase, outcome, summary: 'Measured result', next: 'Next executable action', cleanup: 'confirmed', evidence: [] });
const step = (state, outcome, config = configuration()) => advance(state, report(state.phase, outcome), config, sourceHash, 2000);

test('command authorization has no model-start equivalent; strict budget parsing', () => {
  assert.equal(parseCommand('').action, 'status');
  assert.deepEqual(parseCommand('start --turns=12 --minutes=15 --repairs=2 build arithmetic').options, { turns: 12, minutes: 15, repairs: 2 });
  assert.equal(parseCommand('start').goal.includes('TC0-A'), true);
  for (const text of ['resume --turns=99', 'start --turns=3 --turns=4', 'start --unknown=2', 'go']) assert.throws(() => parseCommand(text));
  assert.throws(() => newState({ cwd: '/repo', sessionId: 'session', options: { turns: 0 } }));
});

test('phase reports cannot pass without external evidence', () => {
  let state = step(initial(), 'ready');
  assert.equal(state.phase, 'build');
  assert.throws(() => step(state, 'complete'));
  state = step(state, 'changed');
  assert.equal(state.phase, 'measure');
  assert.throws(() => step(state, 'pass'), /receipt/);
  const withDev = addReceipt(state, receipt(state, { checkId: 'dev', kind: 'development', claims: [] }));
  state = step(withDev, 'pass');
  assert.equal(state.phase, 'build');
  assert.throws(() => step({ ...state, phase: 'verify' }, 'pass'), /UNKNOWN/);
  assert.equal(qualification(state, configuration(), sourceHash).verdict, 'UNKNOWN');
});

test('missing evaluator does not stop the source-bound development loop', () => {
  const config=validateConfig({version:1,requiredChecks:['absent'],checks:{dev:{kind:'development',command:['node','--test'],timeoutSeconds:10,authorityPaths:[]}}});
  let state=step(step(initial(),'ready',config),'changed',config);
  state=addReceipt(state,receipt(state,{checkId:'dev',kind:'development',claims:[]}));
  state=step(state,'pass',config);
  assert.equal(state.phase,'build');assert.equal(state.status,'active');assert.equal(state.gateVerdict,'UNKNOWN');
  assert.equal(settle(state,{outcome:'completed',now:2000}).continue,true);
  assert.throws(()=>step({...state,phase:'verify'},'pass',config),/UNKNOWN/);
});

test('verification can return to build with real changed-source artifact references',()=>{
  const state={...initial(),phase:'verify',lastBuildSourceHash:sourceHash};
  assert.throws(()=>advance(state,{...report('verify','changed'),evidence:[{path:'candidate.mjs',sha256:'new'}]},configuration(),sourceHash,2000),/changed source/);
  assert.throws(()=>advance(state,report('verify','changed'),configuration(),'new-source',2000),/artifact evidence/);
  const next=advance(state,{...report('verify','changed'),evidence:[{path:'candidate.mjs',sha256:'new'}]},configuration(),'new-source',2000);
  assert.equal(next.phase,'build');assert.equal(next.gateVerdict,'UNKNOWN');assert.equal(next.status,'active');
  assert.equal(next.receipts.length,0);
});

test('full source-bound gate requires all six claims, not just command success', () => {
  let state = step(step(initial(), 'ready'), 'changed');
  state = addReceipt(state, receipt(state));
  state = step(state, 'pass');
  state = step(state, 'pass');
  assert.equal(state.phase, 'assess');
  state = step(state, 'complete');
  assert.equal(state.status, 'completed');
  assert.equal(state.gateVerdict, 'PASS');
  for (const patch of [
    { kind: 'development' }, { verdict: 'UNKNOWN' }, { sourceStable: false },
    { evidenceStable: false }, { cleanup: 'unresolved' }, { runnerCleanup: 'unresolved' },
    { claims: CLAIMS.slice(0, -1) },
  ]) {
    const altered = { ...state, receipts: [receipt(state, patch)] };
    assert.equal(qualification(altered, configuration(), sourceHash).verdict, 'UNKNOWN', JSON.stringify(patch));
  }
  assert.equal(qualification(state, configuration(), 'different-source').verdict, 'UNKNOWN');
});

test('latest failed check supersedes an older passing receipt', () => {
  let state = initial();
  state = addReceipt(state, receipt(state));
  state = addReceipt(state, receipt(state, { verdict: 'FAIL' }));
  assert.equal(qualification(state, configuration(), sourceHash).verdict, 'UNKNOWN');
  assert.throws(() => addReceipt(state, receipt(state, { runId: 'other-run' })), /another run/);
});

test('repair loop is bounded and verify failure can return to repair', () => {
  let state = step(step(initial(), 'ready'), 'changed');
  state = addReceipt(state, receipt(state, { verdict: 'FAIL' }));
  state = step(state, 'fail');
  assert.equal(state.phase, 'repair');
  assert.equal(state.repairs, 1);
  state = step(state, 'changed');
  state = addReceipt(state, receipt(state));
  state = step(state, 'pass');
  state = addReceipt(state, receipt(state, { verdict: 'FAIL' }));
  state = step(state, 'fail');
  assert.equal(state.phase, 'repair');
  state = step(state, 'changed');
  state.repairs = state.maxRepairs;
  state = addReceipt(state, receipt(state, { verdict: 'FAIL' }));
  assert.equal(step(state, 'fail').status, 'paused');
});

test('unknown and unresolved cleanup stop instead of pass', () => {
  const state = initial();
  assert.equal(step(state, 'unknown').status, 'blocked');
  const next = advance(state, { ...report('select', 'ready'), cleanup: 'unresolved' }, configuration(), sourceHash, 2000);
  assert.equal(next.cleanup, 'unresolved');
  assert.throws(() => resume(next, 2000), /cleanup/);
});

test('turn/time bounds include tool-driven turns; resume does not renew budgets', () => {
  let state = initial(); state.maxTurns = 2;
  state = countTurn(state, 2000);
  state = countTurn(state, 3000);
  assert.equal(state.turns, 2);
  assert.match(budgetReason(state, 4000), /turn/);
  assert.equal(countTurn(state, 4000).status, 'paused');
  assert.throws(() => resume(pause(state, 'human'), 4000), /exhausted/);
  const timed = initial(); timed.deadline = 2000;
  assert.equal(settle(timed, { outcome: 'completed', now: 2000 }).continue, false);
});

test('settlement preserves pending work, detects stalls and never revives stopped state', () => {
  let state = initial();
  assert.equal(settle(state, { outcome: 'completed', alreadyContinuing: true, now: 2000 }).deferred, true);
  assert.equal(settle(state, { outcome: 'completed', pending: true, now: 2000 }).deferred, true);
  assert.equal(settle(state, { outcome: 'aborted', now: 2000 }).state.status, 'paused');
  assert.equal(settle(state, { outcome: 'completed', running: true, now: 2000 }).state.status, 'blocked');
  state = settle(state, { outcome: 'completed', now: 2000 }).state;
  state = settle(state, { outcome: 'completed', now: 2000 }).state;
  assert.equal(settle(state, { outcome: 'completed', now: 2000 }).state.status, 'paused');
  assert.equal(settle(pause(state, 'stop', 'stopped'), { outcome: 'completed', now: 2000 }).continue, false);
});

test('state reconstruction follows only supplied active branch', () => {
  const a = initial(), b = { ...a, phase: 'repair' };
  const entry = data => ({ type: 'custom', customType: STATE_TYPE, data });
  assert.equal(restore([entry(a)], '/repo').phase, 'select');
  assert.equal(restore([entry(a), entry(b)], '/repo').phase, 'repair');
  assert.throws(() => restore([entry(a)], '/other'), /foreign/);
  assert.throws(() => restore([entry({ ...a, maxTurns: undefined })], '/repo'), /Malformed/);
  const restored = restore([entry(a)], '/repo'); restored.phase = 'assess';
  assert.equal(a.phase, 'select');
});

test('manifest closes schemas and forbids traversal or ignored evaluator authority', () => {
  for (const path of ['../outside', '/absolute', 'a/../../outside', '.', 'a\\b', 'a\0b']) assert.throws(() => localPath(path));
  assert.equal(localPath('./fixtures/a.json'), 'fixtures/a.json');
  const raw = { version: 1, requiredChecks: ['qualify'], checks: {} };
  assert.throws(() => validateConfig({ ...raw, surprise: true }), /Unknown/);
  assert.throws(() => validateConfig({ ...raw, requiredClaims: [] }), /six/);
  assert.throws(() => validateConfig({ ...raw, ignoredPaths: ['.pi'] }), /authority/);
  assert.throws(() => validateConfig({ ...raw, checks: { qualify: { kind: 'qualification', command: ['node'], timeoutSeconds: 10, authorityPaths: [] } } }), /authority/);
  const config = validateConfig(raw);
  assert.equal(config.requiredChecks[0], 'qualify'); // Missing future check remains UNKNOWN, not skipped.
  assert.equal(qualification(initial(), config, sourceHash).verdict, 'UNKNOWN');
});
