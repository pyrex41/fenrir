import { randomUUID } from 'node:crypto';

export const STATE_TYPE = 'fenrir-workflow-state-v1';
export const CHECKPOINT_TYPE = 'fenrir-workflow-checkpoint-v1';
export const APPROVAL_TYPE = 'fenrir-workflow-approval-v1';
export const PHASES = ['select', 'build', 'measure', 'repair', 'verify', 'assess'];
export const CLAIMS = [
  'canonical-program', 'hand-derived-trace', 'model-candidate-agreement',
  'defect-discovered-and-reduced', 'exact-original-failure-replay', 'fresh-repair-evaluation',
];
export const DEFAULT_GOAL = 'Build the first executable TC0-A demonstration: canonical program, hand trace, Shen model and independent candidate, injected defect, discovery/reduction, exact original-failure replay, and repair with fresh evaluation.';

export const clone = value => structuredClone(value);
export function latestEntry(entries, type) {
  return entries.findLast(entry => entry.type === 'custom' && entry.customType === type);
}
export function restore(entries, cwd) {
  const state = latestEntry(entries, STATE_TYPE)?.data;
  if (!state) return null;
  if (state.version !== 1 || state.cwd !== cwd || !PHASES.includes(state.phase) ||
      !['active', 'paused', 'blocked', 'stopped', 'completed'].includes(state.status) ||
      !Number.isSafeInteger(state.revision) || !Number.isSafeInteger(state.deadline) ||
      !Number.isSafeInteger(state.turns) || state.turns < 0 || !Number.isSafeInteger(state.maxTurns) || state.maxTurns < 1 ||
      !Number.isSafeInteger(state.repairs) || state.repairs < 0 || !Number.isSafeInteger(state.maxRepairs) || state.maxRepairs < 0 ||
      typeof state.id !== 'string' || typeof state.sessionId !== 'string' ||
      !['confirmed', 'unresolved'].includes(state.cleanup) || !Array.isArray(state.receipts)) {
    throw new Error('Malformed or foreign workflow state; do not silently resume it');
  }
  return clone(state);
}
export function bump(state, patch) {
  return { ...clone(state), ...patch, revision: state.revision + 1 };
}
export function pause(state, reason, status = 'paused') {
  return bump(state, { status, reason });
}
function limit(value, fallback, min, max, name) {
  const n = value ?? fallback;
  if (!Number.isSafeInteger(n) || n < min || n > max) throw new Error(`${name} must be ${min}..${max}`);
  return n;
}
export function newState({ cwd, sessionId, goal = DEFAULT_GOAL, configHash, protectedHash, options = {}, now = Date.now() }) {
  if (typeof goal !== 'string' || !goal.trim() || goal.length > 8000) throw new Error('Goal must be 1..8000 characters');
  const turns = limit(options.turns, 24, 1, 200, 'turns');
  const minutes = limit(options.minutes, 30, 1, 240, 'minutes');
  return {
    version: 1, id: randomUUID(), cwd, sessionId, goal: goal.trim(), slice: 'TC0-A',
    status: 'active', phase: 'select', revision: 0, started: now,
    deadline: now + minutes * 60000, maxTurns: turns, turns: 0,
    maxRepairs: limit(options.repairs, 3, 0, 20, 'repairs'), repairs: 0,
    configHash, protectedHash, receipts: [], reportSerial: 0, settledSerial: -1,
    stalls: 0, checkpoint: null, annotationId: null, continuity: 'not-checkpointed',
    cleanup: 'confirmed', reason: null, gateVerdict: 'UNKNOWN',
  };
}
export function budgetReason(state, now = Date.now()) {
  if (now >= state.deadline) return 'Workflow time budget exhausted; no automatic renewal';
  if (state.turns >= state.maxTurns) return 'Workflow assistant-turn budget exhausted; no automatic renewal';
  return null;
}
export function countTurn(state, now = Date.now()) {
  const reason = budgetReason(state, now);
  return reason ? pause(state, reason) : bump(state, { turns: state.turns + 1 });
}
export function resume(state, now = Date.now()) {
  if (!['paused', 'blocked'].includes(state.status)) throw new Error('Only a paused/blocked run can resume');
  if (state.cleanup !== 'confirmed') throw new Error('Unresolved runner cleanup blocks resume');
  const reason = budgetReason(state, now);
  if (reason) throw new Error(`${reason}; start a new explicitly authorized run instead`);
  return bump(state, { status: 'active', reason: null, stalls: 0 });
}
export function addReceipt(state, receipt) {
  if (receipt.runId !== state.id || receipt.configHash !== state.configHash || receipt.protectedHash !== state.protectedHash) {
    throw new Error('Receipt belongs to another run or evaluator authority');
  }
  return bump(state, { receipts: [...state.receipts, clone(receipt)].slice(-128),
    cleanup: receipt.runnerCleanup === 'confirmed' && receipt.cleanup === 'confirmed' ? 'confirmed' : 'unresolved' });
}
function fresh(receipt, state, sourceHash) {
  return receipt.runId === state.id && receipt.configHash === state.configHash &&
    receipt.protectedHash === state.protectedHash && receipt.sourceHash === sourceHash &&
    receipt.sourceStable && receipt.evidenceStable && receipt.runnerCleanup === 'confirmed' && receipt.cleanup === 'confirmed';
}
export function qualification(state, config, sourceHash) {
  const reasons = [];
  const admitted = [];
  if (!config.requiredChecks.length) reasons.push('No required qualification checks configured');
  for (const id of config.requiredChecks) {
    const receipt = state.receipts.findLast(r => r.checkId === id);
    if (!config.checks[id]) { reasons.push(`Required evaluator ${id} is not configured`); continue; }
    if (config.checks[id].kind !== 'qualification') { reasons.push(`${id} is only a development check`); continue; }
    if (!receipt || !fresh(receipt, state, sourceHash)) { reasons.push(`${id} needs fresh source-bound evidence and confirmed cleanup`); continue; }
    if (receipt.kind !== 'qualification' || receipt.verdict !== 'PASS') { reasons.push(`${id}: ${receipt.verdict}`); continue; }
    admitted.push(receipt);
  }
  const claims = new Set(admitted.flatMap(r => r.claims));
  for (const claim of config.requiredClaims) if (!claims.has(claim)) reasons.push(`Missing qualified claim: ${claim}`);
  return { verdict: reasons.length ? 'UNKNOWN' : 'PASS', reasons, checks: admitted.map(r => r.id) };
}
export function advance(state, report, config, sourceHash, now = Date.now()) {
  if (state.status !== 'active') throw new Error('Workflow is not active');
  if (report.phase !== state.phase) throw new Error(`Expected phase ${state.phase}, not ${report.phase}`);
  if (!report.summary?.trim() || !report.next?.trim()) throw new Error('Summary and next action are required');
  const reason = budgetReason(state, now);
  // The final allowed turn may report/finish; prevent only subsequent continuation.
  if (now >= state.deadline) return pause(state, reason);
  if (report.cleanup !== 'confirmed') return bump(state, { status: 'blocked', reason: 'Report has unresolved cleanup', cleanup: 'unresolved' });
  const patch = { reportSerial: state.reportSerial + 1, lastReport: clone(report), cleanup: 'confirmed' };
  // Missing qualification is not a development blocker. An actual source change
  // can return verification to build, but never manufacture a gate receipt.
  if (state.phase === 'verify' && report.outcome === 'changed') {
    const baseline = state.lastBuildSourceHash ?? state.receipts.at(-1)?.sourceHash;
    if (!report.evidence?.length || !baseline || sourceHash === baseline) throw new Error('Return to build requires changed source and artifact evidence');
    return bump(state, { ...patch, phase: 'build', lastBuildSourceHash: sourceHash, gateVerdict: 'UNKNOWN', reason: null });
  }
  if (['unknown', 'blocked'].includes(report.outcome)) return bump(state, { ...patch, status: 'blocked', reason: report.summary });
  const pairs = { select: 'ready', build: 'changed', repair: 'changed', verify: 'pass', assess: 'complete' };
  let phase = state.phase;
  if (phase === 'measure' || (phase === 'verify' && report.outcome === 'fail')) {
    if (!['pass', 'fail'].includes(report.outcome)) throw new Error('Measure requires pass/fail from an executed check');
    const last = state.receipts.findLast(r => r.phase === phase && fresh(r, state, sourceHash));
    if (!last || last.verdict !== report.outcome.toUpperCase()) throw new Error('Measure outcome needs a fresh matching fenrir_check receipt');
    if (report.outcome === 'fail') {
      if (state.repairs >= state.maxRepairs) return bump(state, { ...patch, status: 'paused', reason: 'Repair-attempt budget exhausted' });
      return bump(state, { ...patch, phase: 'repair', repairs: state.repairs + 1 });
    }
    // A green development command does not mean the whole slice is built.
    // Stay in the development loop until ALL qualification requirements exist.
    phase = qualification(state, config, sourceHash).verdict === 'PASS' ? 'verify' : 'build';
    patch.lastMeasuredSourceHash = sourceHash;
  } else {
    if (report.outcome !== pairs[phase]) throw new Error(`${phase} requires ${pairs[phase]}`);
    if (phase === 'verify' || phase === 'assess') {
      const gate = qualification(state, config, sourceHash);
      if (gate.verdict !== 'PASS') throw new Error(`Qualification remains UNKNOWN: ${gate.reasons.join('; ')}`);
      if (phase === 'assess') return bump(state, { ...patch, status: 'completed', gateVerdict: 'PASS', gate, reason: 'Required source-bound TC0-A checks satisfied' });
      patch.gate = gate;
    }
    if (phase === 'build' || phase === 'repair') patch.lastBuildSourceHash = sourceHash;
    phase = { select: 'build', build: 'measure', repair: 'measure', verify: 'assess' }[phase];
  }
  return bump(state, { ...patch, phase, gateVerdict: 'UNKNOWN', reason: null });
}
export function settle(state, { outcome, alreadyContinuing = false, running = false, pending = false, now = Date.now() } = {}) {
  if (state.status !== 'active') return { state, continue: false };
  const reason = budgetReason(state, now);
  if (reason) return { state: pause(state, reason), continue: false };
  if (outcome !== 'completed') return { state: pause(state, `Agent ${outcome || 'failed'}; inspect checkpoint before resume`), continue: false };
  if (running || state.cleanup !== 'confirmed') return { state: pause(state, 'Runner or cleanup still unresolved', 'blocked'), continue: false };
  if (alreadyContinuing || pending) return { state, continue: false, deferred: true };
  const stalls = state.reportSerial === state.settledSerial ? state.stalls + 1 : 0;
  if (stalls >= 2) return { state: pause(state, 'Two settlement boundaries without measured phase progress'), continue: false };
  return { state: bump(state, { stalls, settledSerial: state.reportSerial }), continue: true };
}
export function parseCommand(text) {
  const tokens = text.trim().split(/\s+/).filter(Boolean);
  const action = tokens.shift() || 'status';
  if (!['start', 'drive', 'resume', 'pause', 'stop', 'status', 'approve', 'inspect', 'cleanup'].includes(action)) throw new Error('Use drive, start, resume, pause, stop, status, inspect, approve or cleanup');
  const options = {};
  if (!['start', 'drive'].includes(action)) {
    if (tokens.length) throw new Error(`${action} takes no arguments`);
    return { action, options };
  }
  while (tokens[0]?.startsWith('--')) {
    const match = /^--(turns|minutes|repairs)=(\d+)$/.exec(tokens.shift());
    if (!match || match[1] in options) throw new Error('Use unique --turns=N --minutes=N --repairs=N before the goal');
    options[match[1]] = Number(match[2]);
  }
  return { action, options, goal: tokens.join(' ') || DEFAULT_GOAL };
}
export function prompt(state) {
  const task = {
    select: 'Read the v0.2 plans. Select one executable TC0-A slice, concrete file boundaries and hand-derived acceptance expectations. Report ready; do not write another large prose revision.',
    build: 'Build small checked schemas/byte vectors and explicit pure frames alongside the Shen model and independently structured candidate. Preserve capture_support=[] in closures. Do not import oracle transitions into the candidate. Report changed with actual artifact references.',
    measure: 'Run an available named approved fenrir_check. Keep qualification UNKNOWN when its evaluator/evidence is absent; do not call an unconfigured evaluator or treat absence as a build blocker. Development-check success returns to build for the next missing component, not to completion. Inject/find and reduce defects, keeping original evidence. Report the observed pass/fail.',
    repair: 'Repair candidate-only code against the retained failure. Do not weaken the oracle, goldens, gate or protected evaluator. Retain the original candidate/tape for exact original-failure replay; cross-patch scenario replay is a separate claim. Report changed.',
    verify: 'Run required qualification checks only when configured. Cover canonical program, hand trace, independent agreement, defect discovery/reduction, exact original failure replay and fresh repair evaluation. Missing claims cannot pass but do not block development. To build more, report changed with actual changed-source artifact evidence to return to build. Stop for unavailable prerequisites, unresolved cleanup or human authority review.',
    assess: 'Inspect required receipt/evidence hashes and cleanup. Report complete only with qualified required claims. Otherwise report blocked/unknown with the exact gap. Completion concerns this TC0-A scope, not production Fenrir.',
  }[state.phase];
  return `[Fenrir workflow ${state.id}: ${state.phase}; ${state.turns}/${state.maxTurns} turns; repair ${state.repairs}/${state.maxRepairs}]\nGoal: ${state.goal}\n${task}\nUse fenrir_status for durable state, fenrir_checkpoint before discarding useful context, and fenrir_progress for measured phase transitions. The controller—not conversation summaries—owns phase/budgets. Do not push/deploy, run background candidate processes, or alter evaluator authority. Inspect existing tools and development environment first; missing Shen/toolchain/isolation prerequisites are blockers, not PASS.\n${state.checkpoint ? `Last checkpoint: ${state.checkpoint.summary}\nNext: ${state.checkpoint.next}\nGaps: ${state.checkpoint.gaps}` : 'No checkpoint yet.'}`;
}
