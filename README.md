# Fenrir / Gleipnir

Fenrir is the planned language; Gleipnir is its deterministic development and conformance harness. The immediate target is an executable **TC0-A** demonstration, not the full production language.

## Plans

- [Full vision](01_FULL_VISION.md)
- [Tiny core v0.2](02_TINY_LANGUAGE_CORE.md)
- [Vertical-slice execution plan](03_PHASED_EXECUTION_PLAN.md)
- [Original review](review.md)
- [Workflow research](workflow_research.md)

The specification ZIP is a historical v0.1 snapshot. The documents are not frozen executable acceptance authority. Arithmetic and pure-closure development demos have independent Shen/candidate observations and replay; complete TC0-A and language qualification remain unfinished.

The [next-slice workflow](campaigns/tc0/NEXT_SLICE.md) prepares integrated calls/closures, bounded generated reduction/replay, candidate-only repair and the dependency-ordered follow-ons. It includes the human activation command and explicit review/stop boundaries.

## Development controller

The project-local [Pi workflow extension](.pi/extensions/fenrir-workflow/README.md) drives bounded build/measure/repair work alongside `pi-clm` continuous context.

```text
/reload
/fenrir-workflow inspect
/fenrir-workflow approve
/fenrir-workflow start --turns=24 --minutes=30 --repairs=3
```

Review the manifest/commands before approval. Loading does not start a run. No global Pi settings are changed. The default manifest has development tests but intentionally no TC0 qualification evaluator; missing qualification remains UNKNOWN while development can continue within an authorized finite run. It cannot fabricate PASS.

```sh
npm test
```

Tests use Node 22.19+ and no downloaded dependencies or model calls. See the extension README for safety limits, check registration, cancellation and checkpoint recovery.
