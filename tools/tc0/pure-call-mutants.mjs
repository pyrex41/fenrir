// Candidate-only mutants for the evaluator; UNQUALIFIED development tooling.
// Each mutant is a source transform of runtime/tc0/pure-call-machine.mjs applied here,
// so the candidate itself carries exactly one semantics. Every edit must match the
// candidate source exactly once; a candidate that changed shape makes the mutant
// unavailable (reported, never silently skipped).
import { readFileSync } from 'node:fs';
import { PureCallMachine } from '../../runtime/tc0/pure-call-machine.mjs';

export const MUTANTS = {
  // Operands collected right-to-left; values restored to declared order at Ready.
  reverseOperands: {
    flag: '--reverse-operands',
    edits: [
      [
        "        const operands =\n          t === 'prim'",
        "        const forward =\n          t === 'prim'"
      ],
      [
        '                : [x[1]];\n        const f = {',
        '                : [x[1]];\n        const operands = [...forward].reverse();\n        const f = {'
      ],
      [
        '              metadata: f.metadata,\n              values,\n',
        '              metadata: f.metadata,\n              values: [...values].reverse(),\n'
      ]
    ]
  },
  // Two's-complement wrap instead of the Overflow trap.
  wrapOverflow: {
    flag: '--wrap-overflow',
    edits: [
      [
        "            this.control = { kind: 'Unwind', code: 'Overflow' };\n          else value(['int', String(n)]);",
        "            value(['int', String(BigInt.asIntN(64, n))]);\n          else value(['int', String(n)]);"
      ]
    ]
  },
  // Match arm chosen by the constructor's declared position instead of its name.
  armByPosition: {
    flag: '--arm-by-position',
    edits: [
      [
        'const arm = f.arms.find(arm => arm[0] === c.value[2]);',
        'const arm = f.arms[this.constructorIndex(c.value[1], c.value[2])];'
      ],
      [
        "    this.control = { kind: 'Eval', expr: entry.body, tail: true };\n  }\n",
        "    this.control = { kind: 'Eval', expr: entry.body, tail: true };\n  }\n" +
          "  // A constructor's position in its declaration.\n" +
          '  constructorIndex(type, name) {\n' +
          '    const names =\n' +
          "      type === 'TrapCode'\n" +
          "        ? ['Overflow', 'DivZero', 'Bounds', 'InvalidDuration', 'TaskLimit', 'ChildFailed']\n" +
          '        : this.artifact.datatypes.find(d => d.name === type).constructors.map(c => c.name);\n' +
          '    return names.indexOf(name);\n' +
          '  }\n'
      ]
    ]
  }
};

const CANDIDATE = new URL('../../runtime/tc0/pure-call-machine.mjs', import.meta.url);

export function mutantSource(source, option) {
  if (!Object.hasOwn(MUTANTS, option)) throw new Error('Unknown mutant: ' + option);
  let out = source;
  for (const [from, to] of MUTANTS[option].edits) {
    if (out.split(from).length !== 2)
      throw new Error(`Candidate changed shape; mutant ${option} does not apply`);
    out = out.replace(from, to);
  }
  return out;
}

// The candidate imports nothing, so a transformed copy loads from a data: URL with no
// file writes. A mutant that does not apply is kept as its error.
const source = readFileSync(CANDIDATE, 'utf8');
const machines = {};
for (const option of Object.keys(MUTANTS)) {
  try {
    const url = 'data:text/javascript,' + encodeURIComponent(mutantSource(source, option));
    machines[option] = (await import(url)).PureCallMachine;
  } catch (e) {
    machines[option] = e;
  }
}

// The reference candidate, or the candidate under at most one mutant. The instance's
// `variant` names the mutant so replay identities never confuse it with the reference.
export function createMachine(artifact, input, options = {}) {
  const on = Object.keys(options).filter(k => options[k]);
  if (on.some(k => !Object.hasOwn(MUTANTS, k))) throw new Error('Unknown mutant option');
  if (on.length > 1) throw new Error('At most one mutant at a time');
  if (!on.length) return new PureCallMachine(artifact, input);
  const Machine = machines[on[0]];
  if (Machine instanceof Error) throw Machine;
  return Object.assign(new Machine(artifact, input), { variant: on[0] });
}
