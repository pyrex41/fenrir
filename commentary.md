# Fenrir, Gleipnir, and the Pi development loop

Commentary based on the repository, installed Pi extension loader, and recorded development session inspected on 5 October 2026. This describes the idea and assesses its implementation; it does not amend the language specification or establish qualification.

## The idea in two paragraphs

Fenrir is an experiment in building a native, effect-aware language together with an executable specification of its behavior. It takes inspiration from Koka's effects and Elixir's concurrency and supervision, with Shen defining the language and runtime semantics. Its companion harness, Gleipnir, is intended to make scheduling, time, inputs, and faults explicit, so it can explore legal executions and check an implementation against the model. The goal is to turn difficult runtime bugs into small programs with precise, reproducible counterexamples.

The project also experiments with a persistent coding agent as the implementation worker. A project-local Pi extension keeps the agent moving through bounded development phases, preserves task state across context changes, and records evidence. The intended feedback loop is that an agent implements part of the compiler or runtime, Gleipnir discovers and minimizes a discrepancy, the agent receives a replayable failure, and a fresh evaluation checks its repair. The central bet is that executable semantics, adversarial testing, and persistent agent workflows can make building an ambitious language more tractable. The hard questions remain model correctness, implementation independence, exploration coverage, and the relationship between simulated behavior and production execution.

## What makes the language and harness interesting

The strongest feature is the concrete development loop:

```text
Executable Shen semantics
    → independent candidate implementation
    → generated executions and observed discrepancies
    → reduced counterexample
    → exact replay against the original candidate
    → candidate-only repair
    → fresh independent evaluation
```

This supplies a way to measure progress beyond whether an agent says it finished or a compiler produces a binary. The harness should explain which behavior disagrees with the contract, preserve the original failure, and establish whether a patch improves the implementation.

The proposed semantics are deliberate about evaluation order, closure capture, tail calls, effects, task ownership, cancellation, resources, and virtual time. The distinction between reference-machine steps and future compiled scheduling boundaries is especially valuable: changes to interpreter staging should not silently change production concurrency semantics.

The evidence vocabulary is equally important. Exact replay can reproduce an implementation defect while conformance remains Diverged. Model agreement on a trap can establish conformance for that execution while the application still fails. Completing a bounded sample establishes only the sampled scope. These distinctions make the results more useful and harder to overstate.

Different implementation languages alone do not guarantee independence. Two machines can reproduce the same mistaken interpretation of a contract. Hand-derived traces, distinguishing fixtures, arithmetic boundary expectations, mutation controls, and independent semantic review remain necessary.

## The intended Shen ownership boundary

The [execution plan](03_PHASED_EXECUTION_PLAN.md#3-repository-and-ownership-strategy) places semantic models and properties in Shen and keeps generic campaign/history capabilities in ShenCheck, connected through a versioned TC0 adapter. That is a meaningful architectural commitment.

| Component | Intended responsibility |
| --- | --- |
| Shen | Language semantics, language-specific generators and shrinkers, and semantic properties |
| ShenCheck and its TC0 adapter | Campaign execution, choice recording, replay, corpus, minimization infrastructure, protocol validation, and evidence |
| Independent candidate | Implement the language/runtime behavior under test |
| Process and Solo5 adapters | Launch candidates, mediate requests, transport observations, and enforce execution limits |
| Pi workflow extension | Coordinate bounded implementation work and consume evaluator results |

Host infrastructure can use Rust or another suitable implementation language. The important question is which component owns semantic decisions and whether generic harness capabilities are reused through the intended boundary.

The current bootstrap has drifted from that organization. Node implements the JavaScript candidates, artifact validation, generators, reduction proposals, and semantic replay machinery. Python implements several comparison and campaign runners, including discrepancy classification and reduction orchestration. Shen supplies executable reference models that those programs invoke. Those are substantial harness responsibilities, rather than incidental build glue.

There is a recent change in the native arithmetic slice: its [Go host](tools/solo5/native-arithmetic/README.md) now invokes Shen and Docker directly, replacing that slice's Python build/session adapters. Node remains involved in artifact validation and data lowering. Earlier Python tools and the Node pure-language harness remain elsewhere in the repository. Moving the native host to Go changes its implementation language; integration with the intended Shen/ShenCheck ownership boundary is still separate work.

JavaScript's exact BigInt arithmetic and Python's convenient subprocess handling are plausible bootstrap conveniences. The inspected checkout does not establish the original decision history. The useful fixtures and counterexamples can survive an architectural correction without making those temporary implementations the permanent harness.

## What Pi and fenrir-workflow actually do

The [fenrir-workflow extension](.pi/extensions/fenrir-workflow/README.md) turns the current Pi coding session into a serial, bounded development worker. A human starts a finite run with a goal, turn limit, deadline, and repair-attempt limit. The extension then keeps that session working through explicit phases.

Its key integration point is Pi's `agent_before_settle` boundary. When the agent would normally finish, the extension checks workflow state and can request another continuation with the next phase instruction. The installed Pi runtime implements that boundary. This gives the project sustained work without requiring periodic human nudges.

The controller persists phase, budgets, receipts, and checkpoint pointers as custom entries on the active Pi branch. It counts assistant turns, stops at time or turn limits, and detects repeated settlement without reported phase progress. Human steering pauses continuation; session changes require explicit resumption. New runs require authorization rather than silently replenishing an exhausted budget.

The exposed tools are small and specific:

- `fenrir_status` reads durable workflow state and assesses current gate evidence.
- `fenrir_progress` reports phase progress and requests a permitted transition.
- `fenrir_check` runs an approved named command and retains a source-bound receipt.
- `fenrir_checkpoint` records evidence references, gaps, and the next action.

The current coding session is the worker. The extension itself does not spawn a recursive agent fleet or make nested paid model calls. Its Node/TypeScript implementation fits its role as a Pi extension; that is distinct from putting the language's semantic harness in Node.

## Context continuity and evidence authority

Pi's installed `pi-clm` extension lets the agent manage conversational context. Fenrir's workflow extension leaves that context projection to CLM and maintains its control state separately.

A checkpoint hashes referenced evidence files, writes an advisory checkpoint, and creates a continuity annotation through `live_context_annotate`. The annotation preserves a task obligation and recall pointer while old conversation content can be compressed. The workflow branch journal retains the phase and budgets independently of the edited conversation.

That separation is sound: conversational compression should not rewrite whether a check passed, grant more execution budget, or establish a qualification claim. Restoring an agent's context is also distinct from replaying a target program's semantic choices.

The approved-check runner adds useful operational discipline: fixed argv, bounded output, a watchdog, a private process environment, source and authority hashes, and process-group cleanup. For qualification checks it expects a structured evaluator report, consistent exit status, retained evidence, and the required claims. The external evaluator still owns whether those claims are true.

These controls are workflow protections. Hashes and edit hooks do not establish OS isolation against arbitrary same-user shell code. Candidate execution requires its own measured isolation boundary, and the extension documents that limitation.

## How the workflow is being used

The inspected Pi session recorded nine development runs, 38 `fenrir_check` results, and 38 checkpoints. The runs covered arithmetic, closures, integrated calls, Solo5 transport, virtual clocks, and native arithmetic. The final recorded states showed budget, human-stop, stall, and review-boundary stops; all retained qualification UNKNOWN.

For example, a language-development run reached its 120-turn limit. The native arithmetic sprint stopped at 184 of 200 turns after preparing an independent-review handoff. Those journal records are stronger evidence of actual controller use than examples in the README. They remain historical session records, rather than evidence that a controller is currently running.

The native sprint's [handoff](tools/solo5/native-arithmetic/REPAIR_HANDOFF.md) reports 13 native hand artifacts, generated mutant discovery, bounded reduction, and strict original/smaller failure replay. Only the first case of its 16-case generated family was executed before discovery stopped; the other 15 do not provide coverage. Genuinely independent repair remains unexecuted. During this review, the 18 files referenced by its final checkpoint matched their recorded hashes. That verifies retained file identity, not fresh native execution or every claim in the report.

The review freshly ran all 40 workflow-controller tests and loaded the extension through installed Pi 1.0.1; both passed. It also freshly compared eight pure-call hand cases against the Shen executable, with agreement on the tested transitions and outcomes. Native Solo5 campaigns were not rerun as part of this commentary review.

## The missing connection

The [workflow manifest](.pi/fenrir-workflow.json) registers only `workflow-tests`, a development command that tests the controller itself. It names `tc0-a-qualification` as required, but that evaluator is intentionally unconfigured.

Consequently, passing the registered development check verifies the controller, while Shen/candidate comparison, reduction, and replay are executed separately and referenced in progress reports and checkpoints. The controller can require a fresh receipt before advancing, but its currently registered command does not establish that the selected language milestone passed.

This is the central implementation gap: automatic continuation is working, while automated enforcement of semantic development progress is incomplete. The extension correctly refuses to turn its own passing tests into language qualification. The next improvement is to connect it to real, independently reviewed semantic checks through the Shen/ShenCheck harness.

Development checks can establish bounded model/candidate agreement, failure detection, and replay without claiming full TC0 qualification. Keeping those two levels separate allows useful work to continue while ensuring that the controller's measure phase checks the component being developed.

## Assessment and next milestone

The project combines three worthwhile ideas: a language with executable semantics, a deterministic counterexample harness, and a persistent implementation agent. The Pi extension already supplies useful control and continuity. The semantics and small candidate machines supply real development evidence. The ambitious parts are still the complete harness integration, independent repair evaluation, broader coverage, and production refinement.

The main execution risk is scope. Language design, compiler development, runtime semantics, isolation infrastructure, deterministic transport, and agent orchestration can each become a project of their own. Progress should be judged by complete, reviewable feedback loops rather than the number of subsystems added.

A convincing next milestone would restore the intended harness boundary for one existing pure-language slice, expose its actual semantic checks to the Pi controller, and finish one independently evaluated candidate-only repair. Preserve the original mutant and exact failure replay, evaluate the patch against fresh cases, and provide a documented reproduction command. That would demonstrate the central promise while retaining the prototype's useful work and honest evidence limits.
