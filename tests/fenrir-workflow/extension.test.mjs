import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import register from '../../.pi/extensions/fenrir-workflow/extension.mjs';
import { CLAIMS, STATE_TYPE, restore } from '../../.pi/extensions/fenrir-workflow/core.mjs';
import { executableIdentity, sourceIdentity } from '../../.pi/extensions/fenrir-workflow/storage.mjs';

// Shape-only TypeBox stub; the real Pi loader/schema smoke check is separate.
const Type = {
  String: options => ({ type: 'string', ...options }), Literal: value => ({ const: value }),
  Array: (items, options) => ({ type: 'array', items, ...options }),
  Object: properties => ({ type: 'object', properties }), Union: anyOf => ({ anyOf }),
};
async function harness(t, { clm = true, runCheck, continuityFailure = false, ui = false, consent = true } = {}) {
  const cwd = await mkdtemp(resolve(tmpdir(), 'fenrir-extension-test-'));
  await mkdir(resolve(cwd, '.pi'));
  await writeFile(resolve(cwd, 'evaluator.mjs'), '// trusted fixture evaluator');
  await writeFile(resolve(cwd, '.pi/fenrir-workflow.json'), JSON.stringify({ version: 1, requireContinuousContext: true,
    requiredChecks: ['qualify'], checks: {
      qualify: { kind: 'qualification', command: ['node', 'evaluator.mjs'], timeoutSeconds: 5, authorityPaths: ['evaluator.mjs'] },
      dev: { kind: 'development', command: ['node', 'evaluator.mjs'], timeoutSeconds: 5, authorityPaths: ['evaluator.mjs'] },
    } }));
  let entries = [], sessionId = 'test-session';
  const tools = new Map(), commands = new Map(), handlers = new Map();
  const annotations = [], sent = [], emitted = [], notices = [];
  let aborts = 0;
  const pi = {
    registerTool: tool => tools.set(tool.name, tool), registerCommand: (name, command) => commands.set(name, command),
    on: (name, handler) => { const list = handlers.get(name) || []; list.push(handler); handlers.set(name, list); return () => {}; },
    appendEntry: (customType, data) => entries.push({ type: 'custom', id: randomUUID(), customType, data: structuredClone(data) }),
    sendMessage: message => { entries.push({ type: 'custom_message', id: randomUUID(), ...structuredClone(message) }); sent.push(message); },
    sendUserMessage: text => { entries.push({ type: 'message', id: randomUUID(), message: { role: 'user', content: text } }); sent.push(text); },
    getAllTools: () => [...tools.values(), ...(clm ? [{ name: 'live_context_annotate', exposure: 'direct' }] : [])],
    events: { emit: (name, data) => emitted.push({ name, data }) },
  };
  const ctx = {
    cwd, mode: ui ? 'tui' : 'json', hasUI: ui, isIdle: () => true, hasPendingMessages: () => false, abort: () => { aborts++; },
    ui: { setStatus: () => {}, notify: (...args) => notices.push(args), confirm: async () => consent },
    sessionManager: { getBranch: () => entries, getSessionId: () => sessionId },
    tools: clm ? [{ name: 'live_context_annotate' }] : [],
    async executeTool(name, params) {
      assert.equal(name, 'live_context_annotate');
      annotations.push(params);
      if (continuityFailure) return { isError: true, result: { content: [], details: {} } };
      if (params.action === 'create') {
        assert.ok(entries.some(e => e.id === params.source), 'annotation source must be a real branch entry');
        return { isError: false, result: { content: [], details: { annotation: { id: 'lc-' + annotations.length } } } };
      }
      return { isError: false, result: { content: [], details: {} } };
    },
  };
  const fakeCheck = async ({ state, config, checkId }) => ({
    version: 1, id: randomUUID(), runId: state.id, phase: state.phase, checkId, kind: config.checks[checkId].kind,
    configHash: state.configHash, protectedHash: state.protectedHash,
    sourceHash: (await sourceIdentity(cwd, config)).hash, sourceStable: true, evidenceStable: true,
    executable: await executableIdentity(config.checks[checkId].command[0], cwd),
    verdict: 'PASS', cleanup: 'confirmed', runnerCleanup: 'confirmed',
    claims: config.checks[checkId].kind === 'qualification' ? CLAIMS : [], evidence: [],
    summary: 'Protocol stub only; not live TC0 evidence', stdout: 'fixture-stdout', stderr: 'fixture-stderr',
  });
  register(pi, Type, { runCheck: runCheck || fakeCheck });
  const command = text => commands.get('fenrir-workflow').handler(text, ctx);
  const tool = (name, params = {}) => tools.get(name).execute('call', params, undefined, undefined, ctx);
  const event = async (name, fields = {}) => {
    let value;
    for (const handler of handlers.get(name) || []) value = await handler({ type: name, ...fields }, ctx);
    return value;
  };
  const state = () => restore(entries, cwd);
  t.after(async () => { await event('session_shutdown'); await rm(cwd, { recursive: true, force: true }); });
  const start = async () => { await command('approve'); await command('start --turns=12 --minutes=2'); };
  const progress = outcome => tool('fenrir_progress', { phase: state()?.phase || 'select', outcome, summary: 'Measured fixture report', next: 'Next executable action', cleanup: 'confirmed', evidence: [] });
  const checkpoint = () => tool('fenrir_checkpoint', { summary: 'Current executable slice', gaps: 'Fixture gaps only', next: 'Read current status and rerun required checks', cleanup: 'confirmed', evidence: [] });
  return { cwd, pi, ctx, tools, handlers, annotations, sent, emitted, command, tool, event, state, start, progress, checkpoint,
    entries: () => structuredClone(entries), replaceBranch: branch => { entries = structuredClone(branch); },
    fork: id => { sessionId = id; }, aborts: () => aborts, fakeCheck };
}

test('extension is inert on registration, cannot model-authorize start, and has no context hook', async t => {
  const h = await harness(t);
  assert.equal(h.state(), null);
  assert.deepEqual([...h.tools.keys()], ['fenrir_status', 'fenrir_progress', 'fenrir_check', 'fenrir_checkpoint']);
  assert.equal(h.handlers.has('context'), false);
  assert.equal(h.sent.length, 0);
  await assert.rejects(h.command('start'), /approve/);
  await assert.rejects(h.progress('ready'), /No active/);
  await h.start();
  assert.equal(h.state().status, 'active');
  assert.equal(h.sent.filter(m => typeof m === 'string').length, 1);
  assert.equal(h.state().gateVerdict, 'UNKNOWN');
});

test('one human drive command reviews authority, authorizes finite budgets and continues automatically',async t=>{
  const h=await harness(t,{ui:true});
  await h.command('drive --turns=40 --minutes=15 --repairs=2 build Solo5 and TC0-A');
  assert.equal(h.state().status,'active');assert.equal(h.state().maxTurns,40);
  assert.equal(h.state().goal,'build Solo5 and TC0-A');
  await h.progress('ready');await h.progress('changed');
  await h.tool('fenrir_check',{checkId:'dev'});await h.progress('pass');
  assert.equal(h.state().phase,'build');assert.equal(h.state().gateVerdict,'UNKNOWN');
  const boundary=await h.event('agent_before_settle',{entries:[],continue:false,outcome:'completed'});
  assert.equal(boundary.continue,true);
  await assert.rejects(h.command('drive'),/Stop active/);
});

test('drive cannot self-approve in non-UI mode or survive declined human confirmation',async t=>{
  const noUi=await harness(t);await assert.rejects(noUi.command('drive'),/approve/);
  assert.equal(noUi.state(),null);
  const declined=await harness(t,{ui:true,consent:false});await declined.command('drive');
  assert.equal(declined.state(),null);assert.equal(declined.sent.filter(m=>typeof m==='string').length,0);
  const approved=await harness(t);await approved.command('approve');await approved.command('drive');
  assert.equal(approved.state().maxTurns,120);assert.equal(approved.state().gateVerdict,'UNKNOWN');
});

test('drive rejects authority drift during human review and invalid budgets before confirmation',async t=>{
  const h=await harness(t,{ui:true});let confirmations=0;
  h.ctx.ui.confirm=async()=>{confirmations++;await writeFile(resolve(h.cwd,'evaluator.mjs'),'changed during review');return true;};
  await assert.rejects(h.command('drive --turns=0'),/turns/);assert.equal(confirmations,0);
  await assert.rejects(h.command('drive'),/Authority changed/);assert.equal(confirmations,1);
  assert.equal(h.state(),null);
});

test('continuous-context availability is checked without touching its mirror', async t => {
  const missing = await harness(t, { clm: false });
  await missing.command('approve');
  await assert.rejects(missing.command('start'), /pi-clm/);
  const h = await harness(t);
  await h.start();
  await h.checkpoint();
  assert.equal(h.state().continuity, 'annotated');
  assert.equal(h.annotations[0].retention, 'continuity');
  const file = resolve(h.cwd, h.state().checkpoint.path);
  assert.equal(JSON.parse(await readFile(file, 'utf8')).gateVerdict, 'UNKNOWN');
  await h.checkpoint();
  assert.equal(h.annotations[1].action, 'create');
  assert.equal(h.annotations[2].action, 'resolve');
});

test('complete pipeline requires fresh named checks and a durable annotation', async t => {
  const h = await harness(t);
  await h.start();
  await h.progress('ready'); await h.progress('changed');
  await assert.rejects(h.progress('pass'), /receipt/);
  await h.tool('fenrir_check', { checkId: 'dev' });
  await h.progress('pass');
  assert.equal(h.state().phase, 'build');
  assert.equal((await h.tool('fenrir_status')).details.gateVerdict,'UNKNOWN');
  await h.progress('changed');
  await h.tool('fenrir_check', { checkId: 'qualify' });
  await h.progress('pass'); await h.progress('pass');
  await assert.rejects(h.progress('complete'), /checkpoint/);
  await h.checkpoint();
  await h.progress('complete');
  assert.equal(h.state().status, 'completed');
  assert.equal(h.state().gateVerdict, 'PASS');
  // This is a mocked protocol path, not an executed TC0 qualification.
});

test('current status invalidates historical PASS when source or executable evidence changes', async t => {
  const h = await harness(t);
  await h.start(); await h.progress('ready'); await h.progress('changed');
  await h.tool('fenrir_check', { checkId: 'qualify' });
  await h.progress('pass'); await h.progress('pass'); await h.checkpoint(); await h.progress('complete');
  assert.equal((await h.tool('fenrir_status')).details.gateVerdict, 'PASS');
  const original = h.entries();
  const changed = structuredClone(original);
  changed.findLast(e => e.type === 'custom' && e.customType === STATE_TYPE).data.receipts[0].executable.sha256 = 'wrong';
  h.replaceBranch(changed);
  assert.equal((await h.tool('fenrir_status')).details.gateVerdict, 'UNKNOWN');
  h.replaceBranch(original);
  await writeFile(resolve(h.cwd, 'candidate.mjs'), 'new source');
  const status = (await h.tool('fenrir_status')).details;
  assert.equal(status.gateVerdict, 'UNKNOWN');
  assert.equal(status.recordedGateVerdict, 'PASS');
});

test('failed annotation cannot quietly satisfy completion', async t => {
  const h = await harness(t, { continuityFailure: true });
  await h.start();
  await h.progress('ready'); await h.progress('changed');
  await h.tool('fenrir_check', { checkId: 'qualify' });
  await h.progress('pass'); await h.progress('pass');
  const check = await h.checkpoint();
  assert.equal(check.details.continuity, 'annotation-failed');
  await assert.rejects(h.progress('complete'), /checkpoint/);
  assert.equal(h.state().status, 'active');
});

test('protected edits and authority drift block automatic work', async t => {
  const h = await harness(t);
  await h.start();
  const guarded = await h.event('tool_call', { toolName: 'write', input: { path: 'evaluator.mjs' } });
  assert.equal(guarded.block, true);
  await writeFile(resolve(h.cwd, 'evaluator.mjs'), 'modified authority');
  const info = await h.tool('fenrir_status');
  assert.equal(h.state().status, 'blocked');
  assert.equal(info.details.currentGate.verdict, 'UNKNOWN');
  await assert.rejects(h.command('resume'), /drift/);
  await h.command('approve');
  await assert.rejects(h.command('resume'), /drift/);
  await h.command('start');
  assert.equal(h.state().status, 'active');
});

test('unconfigured evaluator blocks rather than becoming a skipped/pass check', async t => {
  const h = await harness(t);
  await h.start(); await h.progress('ready'); await h.progress('changed');
  const outcome = await h.tool('fenrir_check', { checkId: 'missing' });
  assert.equal(outcome.isError, true);
  assert.equal(h.state().status, 'blocked');
  assert.equal(h.state().gateVerdict, 'UNKNOWN');
});

test('human steering pauses; resume preserves budgets; reload and branching never auto-run', async t => {
  const h = await harness(t);
  await h.start(); await h.event('turn_start');
  const deadline = h.state().deadline;
  const oldBranch = h.entries();
  await h.event('input', { source: 'interactive', text: 'How are we doing?' });
  assert.equal(h.state().status, 'paused');
  await h.command('resume');
  assert.equal(h.state().turns, 1); assert.equal(h.state().deadline, deadline);
  await h.event('session_start');
  assert.equal(h.state().status, 'paused');
  h.replaceBranch(oldBranch); await h.event('session_tree');
  assert.equal(h.state().status, 'paused');
  h.fork('different-session');
  await assert.rejects(h.command('resume'), /Inherited run/);
});

test('native compaction leaves workflow state and checkpoint intact', async t => {
  const h = await harness(t);
  await h.start(); await h.checkpoint();
  const before = h.state();
  await h.event('session_compact');
  assert.deepEqual(h.state(), before);
  assert.equal(h.handlers.has('session_before_compact'), false);
});

test('settlement preserves prior drafts/continuations and enforces its own turn limit', async t => {
  const h = await harness(t);
  await h.start();
  const existing = { type: 'custom', customType: 'another-extension', data: { keep: true } };
  const boundary = await h.event('agent_before_settle', { entries: [existing], continue: false, outcome: 'completed' });
  assert.equal(boundary.continue, true); assert.deepEqual(boundary.entries[0], existing);
  const deferred = await h.event('agent_before_settle', { entries: [existing], continue: true, outcome: 'completed' });
  assert.equal(deferred, undefined);
  const changed = h.entries();
  const last = changed.findLast(e => e.type === 'custom' && e.customType === STATE_TYPE);
  last.data.maxTurns = 1;
  h.replaceBranch(changed);
  await h.event('turn_start'); await h.event('turn_end');
  assert.equal(h.state().status, 'paused');
  assert.equal(h.aborts(), 1);
});

test('a late checker completion cannot revive cancellation or promote its receipt', async t => {
  let resolveCheck;
  let fake;
  const h = await harness(t, { runCheck: options => new Promise(resolve => { resolveCheck = async () => resolve(await fake(options)); }) });
  fake = h.fakeCheck;
  await h.start(); await h.progress('ready'); await h.progress('changed');
  const pending = h.tool('fenrir_check', { checkId: 'qualify' });
  while (!resolveCheck) await new Promise(resolve => setTimeout(resolve, 1));
  assert.equal(h.state().cleanup, 'unresolved');
  await h.command('stop');
  await resolveCheck(); await pending;
  assert.equal(h.state().status, 'stopped');
  assert.equal(h.state().receipts.at(-1).verdict, 'UNKNOWN');
  assert.equal(h.state().cleanup, 'unresolved');
  await h.command('cleanup');
  assert.equal(h.state().cleanup, 'confirmed');
  assert.equal(h.state().receipts.at(-1).verdict, 'UNKNOWN');
});
