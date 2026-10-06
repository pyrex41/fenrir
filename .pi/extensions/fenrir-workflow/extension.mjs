import { resolve, relative } from 'node:path';
import {
  APPROVAL_TYPE, CHECKPOINT_TYPE, PHASES, STATE_TYPE, addReceipt, advance, budgetReason,
  bump, countTurn, latestEntry, newState, parseCommand, pause, prompt, qualification, restore, resume, settle,
} from './core.mjs';
import {
  RUN_ROOT, acquireLock, atomicJson, evidenceReferences, loadConfig, lockExists,
  executableIdentity, privateDirectory, protectedIdentity, referencesValid, releaseLock, sha, sourceIdentity,
} from './storage.mjs';
import { processGroupAlive, runCheck } from './runner.mjs';

const summaryOf = state => state ? {
  id: state.id, status: state.status, slice: state.slice, phase: state.phase,
  goal: state.goal, turns: `${state.turns}/${state.maxTurns}`, deadline: state.deadline,
  repairs: `${state.repairs}/${state.maxRepairs}`, gateVerdict: state.gateVerdict,
  reason: state.reason, cleanup: state.cleanup, continuity: state.continuity,
  checkpoint: state.checkpoint, receipts: state.receipts.slice(-12).map(r => ({
    id: r.id, checkId: r.checkId, kind: r.kind, verdict: r.verdict,
    sourceHash: r.sourceHash, summary: r.summary, stdout: r.stdout, stderr: r.stderr,
  })),
} : { status: 'not-started', gateVerdict: 'UNKNOWN' };
const result = (data, isError = false) => ({
  content: [{ type: 'text', text: JSON.stringify(data, null, 2).slice(0, 24000) }],
  details: data, isError,
});

/** Thin Pi adapter; the worker is the current coding session, not a recursive fleet. */
export default function register(pi, Type, dependencies = {}) {
  const executeCheck = dependencies.runCheck || runCheck;
  let lock = null, budgetTimer = null, activeCheck = null;
  const root = ctx => resolve(ctx.cwd);
  const state = ctx => restore(ctx.sessionManager.getBranch(), root(ctx));
  const persist = (next, ctx) => {
    pi.appendEntry(STATE_TYPE, next);
    ctx.ui.setStatus('fenrir-workflow', `Fenrir ${next.status}: ${next.phase} · ${next.turns}/${next.maxTurns} · ${next.gateVerdict}`);
    pi.events.emit('fenrir-workflow:state', summaryOf(next));
  };
  const clearBudget = () => { clearTimeout(budgetTimer); budgetTimer = null; };
  async function unlock() {
    const owned = lock;
    if (!owned) return;
    await releaseLock(owned);
    if (lock === owned) lock = null;
  }
  async function pauseRun(ctx, reason, status = 'paused', abort = false) {
    const current = state(ctx);
    if (!current || current.status !== 'active') return current;
    const next = pause(current, reason, status);
    persist(next, ctx); clearBudget(); activeCheck?.controller.abort();
    if (abort) ctx.abort();
    if (!activeCheck && next.cleanup === 'confirmed') await unlock();
    return next;
  }
  function armBudget(ctx, next) {
    clearBudget();
    budgetTimer = setTimeout(() => {
      pauseRun(ctx, 'Workflow time budget exhausted; inspect cleanup before explicit resume', 'paused', true)
        .catch(error => ctx.ui.notify(error.message, 'error'));
    }, Math.max(1, next.deadline - Date.now()));
    budgetTimer.unref?.();
  }
  async function checkedContext(ctx, current) {
    const loaded = await loadConfig(root(ctx));
    const authority = await protectedIdentity(root(ctx), loaded.config);
    if (current && (loaded.configHash !== current.configHash || authority.hash !== current.protectedHash)) {
      await pauseRun(ctx, 'Evaluator/config authority drift; human reapproval and a new run required', 'blocked');
      throw new Error('Evaluator/config authority drift; do not update the oracle in a candidate repair');
    }
    return { ...loaded, protectedHash: authority.hash };
  }
  const assertUnchanged = (ctx, before) => {
    const current = state(ctx);
    if (!current || current.id !== before.id || current.revision !== before.revision || current.status !== before.status) throw new Error('Workflow changed during inspection; retry against current state');
  };
  async function requireActive(ctx) {
    const current = state(ctx);
    if (!current || current.status !== 'active') throw new Error('No active workflow; start/resume is human-command-only');
    if (!lock) throw new Error('Controller lease missing; stop and inspect before resuming');
    const checked = await checkedContext(ctx, current);
    assertUnchanged(ctx, current);
    return { current, ...checked };
  }
  async function validateReceiptEvidence(ctx, current, config) {
    for (const receipt of current.receipts) {
      if (!(await referencesValid(root(ctx), receipt.evidence))) receipt.evidenceStable = false;
      try {
        const spec = config.checks[receipt.checkId];
        const executable = await executableIdentity(spec.command[0], root(ctx));
        if (executable.path !== receipt.executable?.path || executable.sha256 !== receipt.executable?.sha256) receipt.evidenceStable = false;
      } catch { receipt.evidenceStable = false; }
    }
  }
  async function checkpointFile(ctx, next) {
    const directory = await privateDirectory(root(ctx), `${RUN_ROOT}/${sha(next.sessionId).slice(0, 16)}/${next.id}`);
    const path = resolve(directory, `checkpoint-${next.revision}.json`);
    await atomicJson(path, { ...next, note: 'Advisory workflow checkpoint; receipts remain separately checked evidence, not conversational authority' });
    return relative(root(ctx), path);
  }
  async function show(ctx) {
    const current = state(ctx);
    const info = summaryOf(current);
    if (current) {
      try {
        const checked = await checkedContext(ctx, current);
        await validateReceiptEvidence(ctx, current, checked.config);
        info.availableChecks = Object.entries(checked.config.checks).map(([id, check]) => ({ id, kind: check.kind }));
        info.requiredChecks = checked.config.requiredChecks;
        info.currentGate = qualification(current, checked.config, (await sourceIdentity(root(ctx), checked.config)).hash);
      } catch (error) { info.currentGate = { verdict: 'UNKNOWN', reasons: [error.message] }; }
      info.recordedGateVerdict = current.gateVerdict;
      info.gateVerdict = info.currentGate.verdict;
    }
    info.runningCheck = activeCheck?.checkId || null;
    info.lockOccupied = await lockExists(root(ctx));
    info.note = 'No OS sandbox is provided by this controller; development command success is not TC0 conformance.';
    return info;
  }
  const publish = data => pi.sendMessage({ customType: CHECKPOINT_TYPE, content: JSON.stringify(data, null, 2), display: true }, { triggerTurn: false });

  pi.registerCommand('fenrir-workflow', {
    description: 'Build Fenrir/Gleipnir: drive [--turns=N --minutes=N --repairs=N] [goal] (review/start once) | inspect | approve | start | status | pause | stop | cleanup | resume',
    async handler(args, ctx) {
      const parsed = parseCommand(args);
      const cwd = root(ctx);
      if (parsed.action === 'status') { publish(await show(ctx)); return; }
      if (parsed.action === 'inspect') {
        const checked = await checkedContext(ctx, null);
        publish({ ...checked, note: 'Inspect the full command argv, authority paths, ignores and required claims before /fenrir-workflow approve. Approval is not qualification.' });
        return;
      }
      if (parsed.action === 'pause' || parsed.action === 'stop') {
        let current = state(ctx);
        if (current?.status === 'active') current = await pauseRun(ctx, `Human ${parsed.action} requested`, parsed.action === 'stop' ? 'stopped' : 'paused', true);
        else if (current && parsed.action === 'stop') { current = pause(current, 'Human stop requested', 'stopped'); persist(current, ctx); }
        clearBudget(); activeCheck?.controller.abort();
        if (!activeCheck && current?.cleanup === 'confirmed') await unlock();
        publish(summaryOf(current)); return;
      }
      if (!ctx.isIdle() || activeCheck) throw new Error('Wait for active execution/cleanup before changing authority or starting/resuming');
      if (parsed.action === 'cleanup') {
        const current = state(ctx);
        if (!current || current.status === 'active') throw new Error('Cleanup acknowledgement requires an inactive run');
        if (current.receipts.some(r => r.runnerCleanup !== 'confirmed' && (!r.processGroup || processGroupAlive(r.processGroup)))) throw new Error('Runner process-group cleanup is unresolved; inspect it externally first');
        persist(bump(current, { cleanup: 'confirmed', cleanupAcknowledgedAt: Date.now(), cleanupAcknowledgedBy: 'human-command' }), ctx);
        await unlock();
        publish({ note: 'Human acknowledged external cleanup. Old failed/incomplete receipts are not promoted; rerun required checks.' }); return;
      }
      if (parsed.action === 'approve') {
        if (state(ctx)?.status === 'active' || await lockExists(cwd)) throw new Error('Stop the controller and resolve its lease before approving changed authority');
        const checked = await checkedContext(ctx, null);
        pi.appendEntry(APPROVAL_TYPE, { version: 1, cwd, configHash: checked.configHash, protectedHash: checked.protectedHash, approvedAt: Date.now() });
        publish({ status: 'approved-commands', configHash: checked.configHash, protectedHash: checked.protectedHash, gateVerdict: 'UNKNOWN', next: '/fenrir-workflow start' }); return;
      }
      if (parsed.action === 'drive') {
        const previous = state(ctx);
        if (previous?.status === 'active' || previous?.cleanup === 'unresolved' || await lockExists(cwd)) throw new Error('Stop active work and resolve cleanup/lease before a new drive');
        parsed.options = { turns: 120, minutes: 120, repairs: 6, ...parsed.options };
        const preview = await checkedContext(ctx, null);
        // Validate budgets BEFORE requesting approval; never auto-renew an old run.
        newState({ cwd, sessionId: ctx.sessionManager.getSessionId(), goal: parsed.goal, options: parsed.options, ...preview });
        publish({ status: 'drive-review', goal: parsed.goal, budgets: parsed.options, ...preview,
          note: 'Bounded autonomous development; missing qualification remains UNKNOWN. No push/deploy, auto-renewal or OS sandbox. Review full argv and authority before confirming.' });
        if (ctx.hasUI) {
          if (!(await ctx.ui.confirm('Start bounded Fenrir drive?', 'Approve the displayed commands/authority and budgets? Development continues through missing qualification evidence; unavailable prerequisites/cleanup/authority drift stop it.'))) return;
          const fresh = await checkedContext(ctx, null);
          if (fresh.configHash !== preview.configHash || fresh.protectedHash !== preview.protectedHash) throw new Error('Authority changed during review; inspect again');
          pi.appendEntry(APPROVAL_TYPE, { version: 1, cwd, configHash: fresh.configHash, protectedHash: fresh.protectedHash, approvedAt: Date.now(), approvedBy: 'human-drive-confirmation' });
        }
        // Non-UI drive requires an already explicitly approved manifest below.
      }
      const checked = await checkedContext(ctx, parsed.action === 'resume' ? state(ctx) : null);
      const approval = latestEntry(ctx.sessionManager.getBranch(), APPROVAL_TYPE)?.data;
      if (!approval || approval.cwd !== cwd || approval.configHash !== checked.configHash || approval.protectedHash !== checked.protectedHash) throw new Error('Run /fenrir-workflow inspect, review commands/authority, then explicitly /fenrir-workflow approve');
      if (checked.config.requireContinuousContext && !pi.getAllTools().some(t => t.name === 'live_context_annotate' && !['hidden', 'model-only'].includes(t.exposure))) throw new Error('pi-clm annotation tool unavailable; load pi-clm before using this workflow');
      const foreign = ctx.sessionManager.getBranch().findLast(e => e.type === 'custom' && e.customType === 'fg-qualification-drive')?.data;
      if (foreign?.status === 'active') throw new Error('Another automatic qualification driver is active; stop it before this workflow');
      let next;
      const previous = state(ctx);
      if (parsed.action === 'resume') {
        if (!previous) throw new Error('No run to resume');
        if (previous.sessionId !== ctx.sessionManager.getSessionId()) throw new Error('Inherited run from another session: start a new run instead of sharing its lease/evidence');
        next = resume(previous);
      } else {
        if (previous?.status === 'active' || previous?.cleanup === 'unresolved') throw new Error('Stop the active run or acknowledge unresolved cleanup before starting another');
        next = newState({ cwd, sessionId: ctx.sessionManager.getSessionId(), goal: parsed.goal, options: parsed.options, ...checked });
      }
      lock = await acquireLock(cwd, { sessionId: ctx.sessionManager.getSessionId(), runId: next.id });
      try { persist(next, ctx); armBudget(ctx, next); }
      catch (error) { await unlock(); throw error; }
      pi.sendUserMessage(prompt(next));
    },
  });

  const text = () => Type.String({ minLength: 1, maxLength: 8000 });
  const enumeration = values => Type.Union(values.map(v => Type.Literal(v)));
  const paths = () => Type.Array(Type.String({ minLength: 1, maxLength: 4096 }), { maxItems: 64, uniqueItems: true });
  const baseTool = { executionMode: 'sequential', annotations: { openWorldHint: false } };
  pi.registerTool({
    ...baseTool, name: 'fenrir_status', label: 'Fenrir workflow status',
    description: 'Inspect branch-local Fenrir development state, current source-bound qualification and active runner. Does not start/resume or grant coverage.',
    parameters: Type.Object({}),
    async execute(_id, _params, _signal, _update, ctx) { return result(await show(ctx)); },
  });
  pi.registerTool({
    ...baseTool, name: 'fenrir_progress', label: 'Fenrir measured phase progress',
    description: 'Advance the bounded development loop. Measure needs a fresh check receipt; development success returns to build while qualification is missing. In verify, changed-source artifact evidence can return to build without passing claims. Verify/complete still require all approved qualification checks and claims. Cannot start/renew a drive.',
    parameters: Type.Object({ phase: enumeration(PHASES), outcome: enumeration(['ready', 'changed', 'pass', 'fail', 'complete', 'unknown', 'blocked']), summary: text(), next: text(), evidence: paths(), cleanup: enumeration(['confirmed', 'unresolved']) }),
    async execute(_id, params, _signal, _update, ctx) {
      const { current, config } = await requireActive(ctx);
      const evidence = await evidenceReferences(root(ctx), params.evidence);
      await validateReceiptEvidence(ctx, current, config);
      const identity = await sourceIdentity(root(ctx), config);
      assertUnchanged(ctx, current);
      const next = advance(current, { ...params, evidence }, config, identity.hash);
      if (next.status === 'completed' && config.requireContinuousContext && current.continuity !== 'annotated') throw new Error('Publish a durable fenrir_checkpoint with pi-clm continuity before completing');
      persist(next, ctx);
      if (next.status !== 'active') { clearBudget(); if (next.cleanup === 'confirmed') await unlock(); }
      return result({ ...summaryOf(next), nextAction: next.status === 'active' ? prompt(next) : next.reason });
    },
  });
  pi.registerTool({
    ...baseTool, name: 'fenrir_check', label: 'Run approved Fenrir check',
    description: 'Run one human-approved argv synchronously under the workflow lease. Retains source-bound logs/receipt, validates external qualification JSON and joins process-group cleanup. No arbitrary commands or agent-supplied verdicts.',
    parameters: Type.Object({ checkId: Type.String({ minLength: 1, maxLength: 64 }) }),
    async execute(_id, params, signal, update, ctx) {
      if (activeCheck) throw new Error('An evaluator is already running');
      const { current, config } = await requireActive(ctx);
      if (!['measure', 'verify'].includes(current.phase)) throw new Error('Checks run in measure or verify; first record the selected/build artifacts');
      if (!Object.hasOwn(config.checks, params.checkId)) {
        persist(pause(current, `Evaluator ${params.checkId} is not configured; request human-reviewed registration`, 'blocked'), ctx);
        clearBudget(); await unlock();
        return result({ gateVerdict: 'UNKNOWN', reason: 'Unconfigured evaluator; agent may propose config changes only outside an active run' }, true);
      }
      const controller = new AbortController();
      const abort = () => controller.abort();
      signal?.addEventListener('abort', abort, { once: true });
      if (signal?.aborted) abort();
      const work = { checkId: params.checkId, controller, promise: null };
      activeCheck = work;
      // Record owned execution before launch so cancellation/reload cannot claim clean idle state.
      persist(bump(current, { cleanup: 'unresolved' }), ctx);
      try {
        work.promise = executeCheck({ cwd: root(ctx), state: current, config, checkId: params.checkId, signal: controller.signal,
          onUpdate: message => update?.(result({ running: params.checkId, message })) });
        let receipt = await work.promise;
        if (controller.signal.aborted) receipt = { ...receipt, verdict: 'UNKNOWN', claims: [], cleanup: 'unresolved', summary: 'Cancelled execution; late completion cannot promote evidence' };
        const after = state(ctx);
        if (!after || after.id !== current.id) throw new Error('Check finished on an abandoned workflow/session; no receipt promotion');
        let next = addReceipt(after, receipt);
        if (['UNKNOWN', 'BLOCKED'].includes(receipt.verdict) && next.status === 'active') next = pause(next, receipt.summary, 'blocked');
        persist(next, ctx);
        return result({ receipt, gateVerdict: 'UNKNOWN', note: receipt.kind === 'development' ? 'Development result only; no language conformance credit' : 'Receipt is evidence for its approved scope, not automatic whole-language qualification' }, ['UNKNOWN', 'BLOCKED'].includes(receipt.verdict));
      } catch (error) {
        const after = state(ctx);
        if (after?.id === current.id) persist(pause(bump(after, { cleanup: 'unresolved' }), `Check infrastructure failure: ${error.message}`, after.status === 'active' ? 'blocked' : after.status), ctx);
        throw error;
      } finally {
        signal?.removeEventListener('abort', abort);
        if (activeCheck === work) activeCheck = null;
        const after = state(ctx);
        if (after?.status !== 'active') { clearBudget(); if (after?.cleanup === 'confirmed') await unlock(); }
      }
    },
  });
  pi.registerTool({
    ...baseTool, name: 'fenrir_checkpoint', label: 'Fenrir continuity checkpoint',
    description: 'Persist concise build state, evidence hashes, gaps and next action. Creates/resolves a pi-clm continuity annotation through its public tool. Never edits LIVE_CONTEXT.md or promotes reports to qualification.',
    parameters: Type.Object({ summary: text(), gaps: text(), next: text(), evidence: paths(), cleanup: enumeration(['confirmed', 'unresolved']) }),
    async execute(_id, params, signal, _update, ctx) {
      const before = state(ctx);
      if (!before) throw new Error('No workflow to checkpoint');
      if (activeCheck) throw new Error('Wait for evaluator cleanup before checkpointing');
      const evidence = await evidenceReferences(root(ctx), params.evidence);
      assertUnchanged(ctx, before);
      const checkpoint = { ...params, evidence, recordedAt: Date.now(), phase: before.phase };
      let next = bump(before, { checkpoint, cleanup: before.cleanup === 'unresolved' ? 'unresolved' : params.cleanup });
      // Use a durable source already in the branch, never fabricated mirror IDs.
      const branch = ctx.sessionManager.getBranch();
      const source = branch.findLast(e => (e.type === 'custom_message' && e.customType === CHECKPOINT_TYPE) ||
        (e.type === 'message' && e.message.role === 'toolResult' && e.message.toolName === 'fenrir_checkpoint')) ||
        branch.findLast(e => e.type === 'message' && e.message.role === 'user');
      let continuityError = null;
      if (source && ctx.tools.some(t => t.name === 'live_context_annotate')) {
        const annotation = await ctx.executeTool('live_context_annotate', {
          action: 'create', source: source.id, title: `Fenrir ${next.slice}: ${next.phase}`,
          reason: 'Keep the build goal and current evidence pointer available through context edits; workflow state/receipts remain authority.',
          futureAction: `Use fenrir_status; ${params.next}`.slice(0, 400), retention: 'continuity',
        }, { signal });
        const id = annotation.result?.details?.annotation?.id;
        if (!annotation.isError && typeof id === 'string') {
          next.annotationId = id; next.continuity = 'annotated';
          if (before.annotationId) {
            const resolved = await ctx.executeTool('live_context_annotate', { action: 'resolve', id: before.annotationId, resolution: 'Superseded by a newer Fenrir checkpoint; inspect current branch state.' }, { signal });
            if (resolved.isError) continuityError = 'Previous annotation could not be resolved; both pointers retained';
          }
        } else { next.continuity = 'annotation-failed'; continuityError = 'pi-clm refused checkpoint annotation'; }
      } else { next.continuity = 'unavailable'; continuityError = 'No callable pi-clm annotation tool or durable source'; }
      assertUnchanged(ctx, before);
      next.checkpoint.path = await checkpointFile(ctx, next);
      assertUnchanged(ctx, before);
      if (params.cleanup !== 'confirmed' && next.status === 'active') next = pause(next, 'Checkpoint records unresolved cleanup', 'blocked');
      persist(next, ctx);
      pi.sendMessage({ customType: CHECKPOINT_TYPE, content: `Fenrir checkpoint: ${params.summary}\nGaps: ${params.gaps}\nNext: ${params.next}\nState: ${next.checkpoint.path}\nEvidence remains source-bound; this note is not a verdict.`, display: false }, { triggerTurn: false });
      if (next.status !== 'active' && next.cleanup === 'confirmed') { clearBudget(); await unlock(); }
      return result({ checkpoint: next.checkpoint, annotationId: next.annotationId, continuity: next.continuity, continuityError, gateVerdict: 'UNKNOWN' });
    },
  });

  // Do not install a context transform: pi-clm owns projection/mirror consistency.
  pi.on('before_agent_start', async (_event, ctx) => {
    const current = state(ctx);
    if (current?.status === 'active') return { message: { customType: 'fenrir-workflow-guidance', content: prompt(current), display: false } };
  });
  pi.on('turn_start', async (_event, ctx) => {
    const current = state(ctx);
    if (current?.status !== 'active') return;
    const next = countTurn(current); persist(next, ctx);
    if (next.status !== 'active') { clearBudget(); activeCheck?.controller.abort(); ctx.abort(); if (!activeCheck && next.cleanup === 'confirmed') await unlock(); }
  });
  pi.on('turn_end', async (_event, ctx) => {
    const current = state(ctx);
    if (current?.status === 'active' && budgetReason(current)) await pauseRun(ctx, budgetReason(current), 'paused', true);
  });
  pi.on('agent_before_settle', async (event, ctx) => {
    const current = restore([...ctx.sessionManager.getBranch(), ...event.entries], root(ctx));
    if (!current || current.status !== 'active') return;
    try { await checkedContext(ctx, current); }
    catch { return; }
    const decision = settle(current, { outcome: event.outcome, alreadyContinuing: event.continue,
      pending: ctx.hasPendingMessages(), running: !!activeCheck });
    if (decision.deferred) return;
    if (!decision.continue) { clearBudget(); if (!activeCheck && decision.state.cleanup === 'confirmed') await unlock(); }
    return {
      entries: [...event.entries, { type: 'custom', customType: STATE_TYPE, data: decision.state }, {
        type: 'custom_message', customType: 'fenrir-workflow-next', display: !decision.continue,
        content: decision.continue ? prompt(decision.state) : `Fenrir workflow ${decision.state.status}: ${decision.state.reason}. Read fenrir_status and resolve gaps/cleanup before explicitly resuming.`,
      }], continue: event.continue || decision.continue,
    };
  });
  pi.on('tool_call', async (event, ctx) => {
    const current = state(ctx);
    if (current?.status !== 'active') return;
    try {
      const { config } = await checkedContext(ctx, current);
      const path = event.input?.path;
      if (['write', 'edit'].includes(event.toolName) && typeof path === 'string') {
        const target = relative(root(ctx), resolve(root(ctx), path));
        if (config.protectedPaths.some(p => target === p || target.startsWith(p + '/'))) return { block: true, reason: 'Protected evaluator/specification path; propose a separate human-reviewed authority change' };
      }
    } catch (error) { return { block: true, reason: error.message }; }
  });
  pi.on('input', async (event, ctx) => {
    if (event.source !== 'extension' && !event.text.trim().startsWith('/fenrir-workflow')) await pauseRun(ctx, 'Human steering received; automatic continuation paused');
  });
  const restorePaused = async (ctx, reason) => {
    clearBudget();
    const current = state(ctx);
    if (current?.status === 'active') persist(pause(current, reason), ctx);
    if (!activeCheck && current?.cleanup === 'confirmed') await unlock();
    if (current) ctx.ui.setStatus('fenrir-workflow', `Fenrir ${state(ctx).status}: ${current.phase}`);
  };
  pi.on('session_start', async (_event, ctx) => restorePaused(ctx, 'Session start/reload: explicit resume required'));
  pi.on('session_before_switch', async (_event, ctx) => {
    await pauseRun(ctx, 'Session switch requested', 'paused', true);
    if (activeCheck) return { cancel: true };
  });
  pi.on('session_before_fork', async (_event, ctx) => {
    await pauseRun(ctx, 'Session fork requested', 'paused', true);
    if (activeCheck) return { cancel: true };
  });
  pi.on('session_before_tree', async (_event, ctx) => {
    await pauseRun(ctx, 'Branch navigation requested', 'paused', true);
    if (activeCheck) return { cancel: true };
  });
  pi.on('session_tree', async (_event, ctx) => restorePaused(ctx, 'Branch navigation: explicit resume required'));
  pi.on('session_compact', async (_event, ctx) => {
    // Native compaction leaves custom branch state intact; do not rewrite/reset CLM.
    const current = state(ctx);
    if (current?.status === 'active') ctx.ui.setStatus('fenrir-workflow', `Fenrir ${current.phase}: checkpoint survives compaction`);
  });
  pi.on('session_shutdown', async (_event, ctx) => {
    clearBudget(); await pauseRun(ctx, 'Session shutdown: inspect cleanup before resume', 'paused', true);
    activeCheck?.controller.abort();
    if (activeCheck?.promise) { try { await activeCheck.promise; } catch { /* owner records infrastructure failure */ } }
    if (!activeCheck && state(ctx)?.cleanup === 'confirmed') await unlock();
  });
}
