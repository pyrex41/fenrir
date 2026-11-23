# Online research: Ultracode, dynamic workflows, and Grok Build

Research date: 3 October 2026. Scope: official public documentation and selected commit-pinned public implementations. No harness was installed, no paid model runs were started, and no downloaded project code or installer was executed. Source inspection and documentation statements are not independently executed conformance evidence.

## Executive finding

The useful innovation is **putting orchestration into executable code instead of making the parent LLM remember and advance every step**. The model authors a task-specific program; a host runtime owns fan-out, resource limits, child sessions, result collection, progress and lifecycle. Intermediate results stay in script variables. The parent receives a final synthesis instead of every worker transcript.

Claude Code calls this dynamic workflows; Ultracode is its automatic workflow-orchestration setting. Official Grok Build also has scripted workflows, but saves **Rhai**, not JavaScript. Public community ports expose more of the implementation mechanics, but must not be confused with the official products.

**For Fenrir/Gleipnir:** borrow the orchestrator/worker split, structured handoffs and bounded repair loops. Do not borrow an LLM voting panel as acceptance authority, or mistake cached worker-result reuse for exact semantic replay.

## 1. Name and product disambiguation

| Name | What it actually is | Evidence level |
| --- | --- | --- |
| Claude Code dynamic workflows / Ultracode | Official script-based subagent orchestration; Ultracode enables automatic use | Official documentation; proprietary runtime not source-audited |
| Official Grok Build workflows | Background workflows authored/saved as `.rhai` files | Official documentation; internal Rhai runtime not source-audited |
| `QuintinShaw/pi-dynamic-workflows` | Independent Pi extension implementing a JavaScript workflow runtime | README, documentation and selected TypeScript inspected at pinned commit |
| `YuanpingSong/ultracodex` | Independent Agent Script runtime routing calls to Codex, Claude or OpenCode | Documentation and selected runtime/adapter source inspected at pinned commit |
| `just-every/plugin-ultracode` | Independent Codex plugin with script, fan-out and staged workflow surfaces | Documentation and selected JavaScript inspected at pinned commit |
| `PabloNAX/ultracode-skill` | Prompt/skill operating pattern using the host's native agent tools | README inspected; not a separate workflow execution service |
| `superagent-ai/grok-cli` | Community coding agent using the Grok API | README inspected; explicitly not official xAI Grok Build |
| `xai-org/grok-build-plugin-cc` | Official Claude Code bridge to the real Grok Build CLI | README and selected process/state source inspected at pinned commit |

Sharing a model, CLI binary name, or “Ultracode” label does not make these implementations equivalent.

## 2. Claude Code: what dynamic workflows do

Primary source: [official workflows documentation](https://code.claude.com/docs/en/workflows), with context from the [announcement](https://claude.com/blog/introducing-dynamic-workflows-in-claude-code).

### Control flow

```text
Human request / saved workflow
    → Claude writes or selects a JavaScript script
    → launch permission evaluation
    → background workflow runtime executes script
    → script requests independent subagent sessions
    → subagents use ordinary permission-checked tools
    → script collects, branches, verifies and repeats
    → one final result returns to the conversation
```

The parent model designs the workflow, but the **script decides what runs next**. This is different from a skill, which supplies instructions the model follows turn by turn, and from an agent team, whose lead advances assignments through conversation/shared tasks.

### Authoring and activation

- Ask explicitly for a workflow or type the `ultracode` keyword in a human-origin prompt.
- `/effort ultracode` enables automatic orchestration for substantive tasks in that session.
- The current detailed docs distinguish the toggle from reasoning effort: the session can run Ultracode at its existing effort; launching with `claude --effort ultracode` also selects `xhigh`.
- Keyword activation is human-origin-sensitive. The current docs say it does not activate merely because `ultracode` appears in a `-p` prompt, scheduled prompt, webhook or unmarked SDK input. This does not mean headless Workflow calls are unavailable; they still go through the host's tool-permission evaluation.
- `/deep-research` is the documented bundled workflow. A saved script becomes a command under project `.claude/workflows/` or personal `~/.claude/workflows/`.

These behaviors have version requirements in the docs; do not infer that every older Claude Code build supports them.

### Program shape and primitives

A saved script begins with a literal `export const meta = { name, description, ... }`, followed by plain JavaScript with top-level await/return.

Documented primitives include:

- `agent(prompt, options)`: one child session; optional JSON Schema output.
- `parallel(thunks)`: simultaneous tasks with result collection.
- `pipeline(items, stages...)`: apply agent stages to a collection.
- `phase(title)`: progress grouping.
- `log(message)`: progress output.
- `args`: structured input supplied at invocation.

Loops, conditionals and intermediate state are ordinary JavaScript. The script does not directly read files or run shell commands; workers do that. Module loading is unavailable. Ambient `Date.now()`, `Math.random()` and no-argument `new Date()` are rejected to support stable re-execution of orchestration.

The public guide does not fully enumerate every internal runtime global. In particular, community budget/checkpoint helpers must not automatically be presented as official Claude APIs.

### Bounds, permissions and failure

The retrieved guide documents:

- Default concurrent-agent limit up to 16, reduced on lower CPU availability.
- A version-dependent environment override supporting 1–256 concurrent agents.
- 1,000 total agents per run.
- 4,096 items per `parallel`/`pipeline` call.
- Agent failure/individual stop may return `null`; scripts must account for missing results.
- Structured output is validated and has bounded repair attempts.
- Workflow size guidelines are advice to the authoring model, not hard caps.
- A large-workflow warning is advisory, not an enforced token budget.
- Approval of the workflow does not bypass permission checks for worker tool use.

The current guide says there is no general mid-run user-input primitive; for sign-off between stages it recommends separate workflows. This is a real difference from the Pi extension's checkpoint API.

### Resume: the crucial distinction

The runtime re-executes orchestration and returns completed worker results from its saved state. At the first changed prompt or failed call, that call and later calls run again.

Example: A, B, C, D start in that order; B fails. Relaunch can reuse A but reruns B, C and D, even if C and D had completed. Running workers stopped with the whole workflow start over rather than restoring their in-flight machine state.

Completed-result reuse survives through the original session's saved state; missing state produces `nothing to resume`, rather than an implicit new run. Stop/relaunch also waits for old agents to exit to avoid duplicate live workers.

**This is orchestration recovery, not replay of native instructions, tool side effects, OS scheduling or an exact target-language choice tape.** Blocking ambient time/randomness does not make fresh model calls deterministic, nor by itself establish determinism for completion-order-sensitive script logic.

## 3. Official Grok Build workflows

Primary sources: [Modes and Commands](https://docs.x.ai/build/modes-and-commands), [Subagents](https://docs.x.ai/build/features/subagents), [Worktrees](https://docs.x.ai/build/features/worktrees), [Headless & Scripting](https://docs.x.ai/build/cli/headless-scripting), and [Sandbox](https://docs.x.ai/build/features/sandbox).

### Documented lifecycle

```text
/create-workflow <description>
    → Grok asks about fan-out, verification and scope
    → authors and smoke-checks a Rhai script
    → saves .grok/workflows/<name>.rhai or ~/.grok/workflows/<name>.rhai
/workflow <name> <optional JSON args>
    → bounded background subagent run
    → verification and final result
/workflows
    → live dashboard for active and retained runs
```

The documented controls include `/workflow pause`, `/workflow resume`, `/workflow stop`, and save. Saved names can also be invoked as `/<name>`. `/deep-research` starts a built-in background research workflow. Workflows are documented as enabled by default and can be disabled through `[workflows] enabled = false` or `GROK_WORKFLOWS=0`.

**Important language difference:** Grok saves Rhai scripts. There is no basis for assuming a Claude JavaScript script, its globals, or its prefix-cache semantics will run unchanged in Grok.

### Worker contexts and workspace isolation

Subagents are independent child sessions with their own context and return a summary to the parent. The documented built-ins are:

- `general-purpose`: full-capability worker.
- `explore`: read/list/search, no shell or edits.
- `plan`: planning worker, no shell or edits.

Custom definitions live under `.grok/agents/` or `~/.grok/agents/`. Personas are behavioral overlays, not new enforcement mechanisms.

Workers can request git-worktree isolation. Official worktree documentation says new trees start from HEAD and include uncommitted changes, or can start from an explicit ref; they persist until removed. Worktree separation prevents edit collisions, but is not a credentials/network security boundary.

### External harness integration

Grok offers two documented integration levels:

1. `grok -p ... --output-format json|streaming-json` for headless jobs.
2. `grok agent stdio` for ACP JSON-RPC integration.

The ACP example initializes, authenticates, creates a session and sends `session/prompt`. Assistant content arrives through `session/update` chunks; the prompt response carries completion metadata. An adapter must observe both rather than treating one response as the entire transcript.

### Security is separate from workflow structure

The retrieved sandbox documentation says sandboxing is **off by default**. It documents Linux Landlock and macOS Seatbelt profiles, including these limitations:

- Child-network restrictions are Linux-only; the documented macOS setting is a no-op for that restriction.
- In-process model API/web-tool networking is outside child-network restrictions.
- Built-ins do not permanently protect credential paths such as `~/.ssh`; custom deny rules are needed.
- `~/.grok/` remains writable for persistence.

Thus “read-only agent,” “plan mode,” “worktree,” and “sandbox enabled” are different properties. None should be substituted for a tested evaluator isolation policy.

### What remains unverified

The official pages retrieved describe file format, creation, lifecycle, subagents and controls. They do **not** supply a complete public Rhai workflow host-function reference, exact concurrency/budget defaults, crash-consistent journal protocol, or resume-matching algorithm.

I did not locate/audit public source for the native Grok workflow engine. Therefore I do not claim its resume uses Claude's positional prefix rule, that its Rhai interpreter is deterministic, or that a returned workflow result means all verification was complete. Those require a pinned CLI/runtime inspection and measured tests.

## 4. Source-visible implementations: how the machinery works

### Pi dynamic workflows

Inspected commit: `3bea96cbbec3328f7579d821a23c060835d268f6` in [QuintinShaw/pi-dynamic-workflows](https://github.com/QuintinShaw/pi-dynamic-workflows/tree/3bea96cbbec3328f7579d821a23c060835d268f6).

The extension accepts generated JavaScript, parses it, creates a Node VM realm, injects orchestration APIs, and runs fresh Pi child sessions through `createAgentSession`. It supports model/tier routing, schema validation, background delivery, optional worktrees and additional helpers such as `verify`, `judgePanel`, `gate`, `retry`, `loopUntilDry` and `checkpoint`.

Source-backed details:

- [workflow.ts](https://github.com/QuintinShaw/pi-dynamic-workflows/blob/3bea96cbbec3328f7579d821a23c060835d268f6/src/workflow.ts#L892) allocates call indices before the concurrency limiter, hashes call identity, and reuses only an unchanged completed prefix. A cache miss makes that and subsequent calls live.
- [Call hashing](https://github.com/QuintinShaw/pi-dynamic-workflows/blob/3bea96cbbec3328f7579d821a23c060835d268f6/src/workflow.ts#L2264) includes prompt, model intent, tier, thinking, phase, agent definition, schema and relevant directory/isolation options. It does not itself hash every file a worker reads. Same prompt is therefore not source-bound acceptance evidence after repository changes.
- Token budgets are soft pre-call gates. Already-running workers can overshoot; this is not an independently enforced hard spending ceiling.
- The source explicitly says the Node VM is **not a security sandbox**. Its deterministic guards target accidental ambient randomness/time in trusted scripts.
- Child host extensions are disabled by default, with explicit trusted middleware opt-in; this reduces recursive orchestration and extension churn.
- An all-null fleet can still have workflow status `completed`, with a warning. That status means the orchestration returned, not that the requested work passed.
- [Run storage](https://github.com/QuintinShaw/pi-dynamic-workflows/blob/3bea96cbbec3328f7579d821a23c060835d268f6/docs/run-storage.md) uses an append-only delta log and a small committed head containing byte boundary, sequence and hash-chain tip. Committed corruption fails closed. The document limits its guarantee to process-crash/atomic-rename recovery, not universal power-loss durability.

The distinction between keyword authorization and execution is also useful: this extension's trigger arms the workflow tool; mentioning workflows in a question does not inherently force a run.

### ultracodex

Inspected commit: `ac349f864dd60d218ecadf56864b3cb74d72608e` in [YuanpingSong/ultracodex](https://github.com/YuanpingSong/ultracodex/tree/ac349f864dd60d218ecadf56864b3cb74d72608e).

Its [architecture](https://github.com/YuanpingSong/ultracodex/blob/ac349f864dd60d218ecadf56864b3cb74d72608e/docs/architecture.md) separates:

1. Loader: Acorn literal-meta parsing and Node VM execution.
2. Runtime: agent semantics, fan-out limits, semaphore and budgets.
3. Executors: backend protocol adapters with capability declarations.
4. Journal: append-only run events; UI/reporting fold the same events.
5. Runner: detached run process, controlled through a file stream.

Its Codex executor uses `codex app-server` JSON-RPC: initialize → thread/start → turn/start → item notifications → turn/completed. Other adapters use headless Claude or OpenCode HTTP/SSE. Engine-side schema validation remains authoritative even when wire-schema support degrades.

The [Executor Contract](https://github.com/YuanpingSong/ultracodex/blob/ac349f864dd60d218ecadf56864b3cb74d72608e/docs/executor-contract.md) is especially relevant: adapters declare schema/resume/interrupt/usage/sandbox capabilities and are tested through a common scripted-fake conformance kit. Fakes are protocol evidence, not live sandbox evidence.

Its inspected [runtime controller](https://github.com/YuanpingSong/ultracodex/blob/ac349f864dd60d218ecadf56864b3cb74d72608e/src/runtime.ts#L603) implements soft pause by stopping new launches while existing turns continue. Resume reopens that live gate. I did not establish crash-restart completed-prefix caching equivalent to Claude/Pi from the inspected code. An event journal, backend session continuation, and workflow replay are separate capabilities.

Unsupported sandbox capabilities warn rather than automatically failing the operation. Gleipnir must use a stricter rule when isolation is a required acceptance condition.

### Just Every Ultracode plugin

Inspected commit: `9dde0086e983413016bf62ab96ba6bb17b599fae` in [just-every/plugin-ultracode](https://github.com/just-every/plugin-ultracode/tree/9dde0086e983413016bf62ab96ba6bb17b599fae).

It supports fixed worker panels, steps/DAG-style workflows and imperative scripts, with independent Codex workers, a dashboard and journaled state. Its [script runner](https://github.com/just-every/plugin-ultracode/blob/9dde0086e983413016bf62ab96ba6bb17b599fae/scripts/ultracode-script-runner.js) compiles the body through an `AsyncFunction`, not an independently enforced process sandbox. Completed worker reuse looks up a content key for prompt/options; do not assume it has the same positional-prefix contract as Claude/Pi.

This illustrates why the brand name alone is insufficient to define resume or isolation semantics.

### Official Grok bridge for Claude Code

Inspected commit: `92b76a670713335229644e94add15ab40c80e547` in [xai-org/grok-build-plugin-cc](https://github.com/xai-org/grok-build-plugin-cc/tree/92b76a670713335229644e94add15ab40c80e547).

This is a process bridge, not the source of the Rhai workflow engine. It shells out to the real Grok CLI, keeps plugin-owned run/log/PID state, supports review/critique/delegation and imports Claude sessions into Grok.

Its default direct bridge run is read-only unless explicitly made write-capable. The delegate skill has a different default: it adds write capability unless the user asks for read-only. Entry-point policy matters.

The source [terminal-state claim](https://github.com/xai-org/grok-build-plugin-cc/blob/92b76a670713335229644e94add15ab40c80e547/plugins/grok-build/scripts/lib/state.mjs#L159) is locked: once cancelled, a late worker completion cannot overwrite it. Stop tracks both bridge and agent process trees. This is a useful lifecycle pattern, but plugin `completed` is still not a semantic acceptance verdict.

## 5. What to adopt for TC0-A

### Adopt now

- A small, inspectable controller with explicit stages and attempt bounds.
- Separate model, candidate, evaluator and reporting responsibilities.
- Structured worker handoffs containing revision, patch identity, evidence paths and limitations.
- An adapter capability contract and fake-protocol tests, followed by separate live boundary tests.
- Parent/controller-owned integration; use worktrees only for genuinely independent editing lanes.
- Journal run lifecycle and terminal settlement so cancellation cannot be overwritten by late results.
- Treat missing/failed/unverified work as explicit evidence, never filter it out and declare completion.

### Do not adopt as acceptance authority

- Majority votes from verifier agents.
- Agent-reported `done` or process exit zero.
- Cached answers whose dependencies/source identities are not verified.
- A VM language realm as security isolation.
- Advice-only budgets as hard resource limits.
- A large fleet before a single slice works.

### Minimal executable loop

```text
Materialize canonical program + hand trace
    → run Shen model and independent candidate
    → external evaluator compares observations
    → inject defect and generate a detecting case
    → reducer rechecks every proposed simplification
    → exact replay of retained original-candidate failure
    → bounded repair agent edits candidate-only paths
    → independent build and fresh regression/generated evaluation
    → publish source-bound evidence and remaining gaps
```

The orchestrator may arrange this loop, but the trusted evaluator executes fixed checks and owns PASS/FAIL/UNKNOWN. Agents can propose patches and interpret counterexamples; they cannot edit the oracle or replace an acceptance failure with a favorable reviewer vote.

Keep orchestration recovery and TC0 replay in separate stores/contracts. Reusing a cached research answer may save tokens. It must never substitute for freshly required candidate qualification. Reference-machine scheduling decisions remain TC0's semantic tape, not the order in which implementation workers were launched.

## 6. Remaining research/measurement gaps

Before selecting a production orchestrator:

1. Pin the actual installed Claude/Grok/Pi/backend versions; documentation is a moving snapshot.
2. For Grok, obtain the bundled/public Rhai host-function contract and test pause/resume/stop, failed workers and source drift. Exact resume matching remains unestablished here.
3. Measure one small arithmetic repair loop, including cost and retained failure evidence, before scaling parallelism.
4. Exercise crash/cancellation with independent process observation; fake protocol tests do not prove live cleanup.
5. Test evaluator write protection and credential/network isolation on the actual platform.
6. Decide whether cache reuse is allowed for each task class and invalidate it on relevant source/toolchain/evaluator changes.

**Recommendation:** Make TC0-A executable with a minimal external controller first. Reuse an existing workflow host where convenient, but do not turn workflow infrastructure selection into a new prerequisite or another large specification revision.
