// The injected defects of the JavaScript handler machine (runtime/tc1/handler-machine.mjs),
// as report key -> constructor option. Shared by the batch runners so the hand fixtures
// and the exhaustive family are run against the same six.
export const MUTANTS=Object.freeze({forgotten_resume:'forgottenResume',double_resume:'doubleResume',outermost_handler:'outermostHandler',
  dynamic_clause_environment:'dynamicClauseEnvironment',resume_returns_argument:'resumeReturnsArgument',shallow_resume:'shallowResume'});
