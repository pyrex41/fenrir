// Report same-constructor rebuilds in validated match arms for ownership analysis.
// A field delta describes value construction. It does not establish uniqueness.
import {readFileSync} from 'node:fs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';

const {artifact} = validatePureCallArtifact(readFileSync(process.argv[2]), ['int', '0'], {maxNodes: 2000});
const updates = [];
const owners = new Map();
for (const datatype of artifact.datatypes) {
  for (const ctor of datatype.constructors) {
    owners.set(ctor.name, owners.has(ctor.name) ? null : datatype.name);
  }
}

function inspectResult(node, name, fields, subject, functionName) {
  switch (node[0]) {
    case 'let':
      inspectResult(node[4], name, fields, subject, functionName);
      break;
    case 'if':
      for (const branch of node.slice(3))
        inspectResult(branch, name, fields, subject, functionName);
      break;
    case 'construct': {
      if (node[2] !== owners.get(name) || node[3] !== name) return;
      const changed = [];
      for (const [index, field] of node.slice(4).entries()) {
        if (field[0] !== 'var' || field[2] !== fields[index]) changed.push(index);
      }
      if (changed.length < fields.length) {
        updates.push({function: functionName, node: node[1], subject, datatype: node[2],
                      constructor: name, changed});
      }
      break;
    }
  }
}

function visit(node, functionName) {
  if (!Array.isArray(node)) return;
  if (node[0] === 'match' && node[2][0] === 'var') {
    for (const [name, fields, body] of node.slice(3))
      inspectResult(body, name, fields, node[2][2], functionName);
  }
  for (const child of node) visit(child, functionName);
}

for (const fn of artifact.functions) visit(fn.body, fn.name);
// For direct tuple calls, find reads of a binding or its direct let aliases in later operands
// or in expressions that can execute after the call. None found is inconclusive: heap aliases, captures,
// callers, other expression forms and alternative branches still matter.
function inspectCallUses(fn) {
  const calls = [];
  // The validator assigns distinct binder IDs. Resolve immutable variable-to-variable
  // lets in definition order; a use can only refer to a binder in lexical scope.
  const origins = new Map();
  const origin = binding => origins.get(binding) ?? binding;
  function collectAliases(node) {
    if (!Array.isArray(node)) return;
    if (node[0] === 'let' && node[3][0] === 'var')
      origins.set(node[2], origin(node[3][2]));
    for (const child of node) collectAliases(child);
  }
  collectAliases(fn.body);
  function reads(node, binding, found) {
    if (!Array.isArray(node)) return;
    if (node[0] === 'var' && origin(node[2]) === origin(binding)) found.push(node[1]);
    for (const child of node) reads(child, binding, found);
  }
  function scan(node, later) {
    if (!Array.isArray(node)) return;
    if (node[0] === 'let') {
      scan(node[3], [node[4], ...later]);
      scan(node[4], later);
      return;
    }
    if (node[0] === 'call' && node[3][0] === 'tuple') {
      const args = node[3].slice(2);
      for (const [index, arg] of args.entries()) {
        if (arg[0] !== 'var') continue;
        const uses = [];
        for (const expr of [...args.slice(index + 1), ...later]) reads(expr, arg[2], uses);
        // All argument values coexist at entry, including ones evaluated first.
        const sameBindingArguments = [];
        for (const [otherIndex, other] of args.entries()) {
          if (otherIndex !== index && other[0] === 'var' && origin(other[2]) === origin(arg[2]))
            sameBindingArguments.push(otherIndex);
        }
        if (uses.length || sameBindingArguments.length) {
          const finding = {caller: fn.name, callee: node[2], call: node[1],
                           argument: index, binding: arg[2], laterReads: uses};
          if (sameBindingArguments.length) finding.sameBindingArguments = sameBindingArguments;
          calls.push(finding);
        }
      }
    }
    // A call nested in an operand can complete before a sibling reads the
    // same binding. Carry that continuation into the nested expression.
    const start = {tuple: 2, apply: 2, construct: 4, prim: 3}[node[0]];
    if (typeof start === 'number') {
      const operands = node.slice(start);
      for (const [index, operand] of operands.entries())
        scan(operand, [...operands.slice(index + 1), ...later]);
      return;
    }
    if (node[0] === 'if' || node[0] === 'match') {
      const branches = node[0] === 'if' ? node.slice(3) : node.slice(3).map(arm => arm[2]);
      scan(node[2], [...branches, ...later]);
      for (const branch of branches) scan(branch, later);
      return;
    }
    for (const child of node) scan(child, later);
  }
  scan(fn.body, []);
  return calls;
}

function imageLiteral(node) {
  if (['int', 'bool', 'bytes'].includes(node[0])) return true;
  if (node[0] === 'construct') return node.slice(4).every(imageLiteral);
  return node[0] === 'tuple' && node.slice(2).every(imageLiteral);
}

// Entry facts for the outer constructor cell only. A callee can subsequently
// share the argument. The caller may already share any of its children.
function freshCallArguments(fn, returned) {
  const findings = [];
  function uses(node, id) {
    if (!Array.isArray(node)) return 0;
    if (node[0] === 'var') return Number(node[2] === id);
    return node.reduce((n, child) => n + uses(child, id), 0);
  }
  function visit(node, binding) {
    if (!Array.isArray(node)) return;
    if (node[0] === 'let') {
      visit(node[3]);
      // Limit the live range to one immediate call. In particular, a single
      // syntactic use in a closure could execute more than once.
      const direct = node[4][0] === 'call' && uses(node[4], node[2]) === 1;
      visit(node[4], direct ? {id: node[2], value: node[3]} : undefined);
      return;
    }
    if (node[0] === 'call' && node[3][0] === 'tuple') {
      for (const [argument, arg] of node[3].slice(2).entries()) {
        const value = binding && arg[0] === 'var' && arg[2] === binding.id ? binding.value : arg;
        if (value[0] === 'construct' && !imageLiteral(value)) {
          findings.push({caller: fn.name, callee: node[2], call: node[1], argument,
                         constructor: value[3], allocation: value[1]});
        } else if (value[0] === 'call' && returned.has(value[2])) {
          for (const [tag, origins] of Object.entries(returned.get(value[2]))) {
            if (origins.length === 1 && origins[0] === 'fresh')
              findings.push({caller: fn.name, callee: node[2], call: node[1], argument,
                             constructor: tag, producer: value[2], producerCall: value[1]});
          }
        }
      }
    }
    for (const child of node) visit(child);
  }
  visit(fn.body);
  return findings;
}

// For each successful return tag, record every possible outer-cell origin.
// Start recursion at no successful returns and grow the finite sets until
// stable. An unrecognized result expression can return any existing cell.
function resultOrigins() {
  const datatypes = new Map(artifact.datatypes.map(d => [d.name, d.constructors.map(c => c.name)]));
  const defs = artifact.functions.filter(f => f.result_type?.[0] === 'Data');
  const summaries = new Map(defs.map(f => [f.name, new Map()]));
  let changed;
  do {
    changed = false;
    for (const fn of defs) {
      const summary = summaries.get(fn.name);
      const tags = datatypes.get(fn.result_type[1]);
      function add(tag, origin) {
        if (!summary.has(tag)) summary.set(tag, new Set());
        const origins = summary.get(tag);
        if (!origins.has(origin)) {
          origins.add(origin);
          changed = true;
        }
      }
      // Binder IDs are unique in the validated artifact. A numeric origin
      // identifies the incoming argument (-1), or a field of its tuple.
      const parameters = new Map([[fn.parameter_id, -1]]);
      function inspect(node, refinements) {
        switch (node[0]) {
          case 'construct':
            add(node[3], imageLiteral(node) ? 'image' : 'fresh');
            return;
          case 'let': {
            const value = node[3];
            if (value[0] === 'project' && value[2][0] === 'var' && value[2][2] === fn.parameter_id)
              parameters.set(node[2], Number(value[3]));
            else if (value[0] === 'var' && parameters.has(value[2]))
              parameters.set(node[2], parameters.get(value[2]));
            if (value[0] === 'var' && refinements.has(value[2])) {
              refinements = new Map(refinements);
              refinements.set(node[2], refinements.get(value[2]));
            }
            inspect(node[4], refinements);
            return;
          }
          case 'if':
            inspect(node[3], refinements);
            inspect(node[4], refinements);
            return;
          case 'match':
            for (const [name, , arm] of node.slice(3)) {
              const next = new Map(refinements);
              if (node[2][0] === 'var') next.set(node[2][2], name);
              inspect(arm, next);
            }
            return;
          case 'call':
            if (summaries.has(node[2])) {
              for (const [tag, origins] of summaries.get(node[2]))
                for (const origin of origins) {
                  if (typeof origin !== 'number') {
                    add(tag, origin);
                    continue;
                  }
                  const arg = origin === -1 ? node[3] :
                    node[3][0] === 'tuple' ? node[3][2 + origin] : null;
                  const known = arg?.[0] === 'construct' ? arg[3] :
                    arg?.[0] === 'var' ? refinements.get(arg[2]) : undefined;
                  if (known !== undefined && known !== tag) continue;
                  add(tag, arg?.[0] === 'var' ? parameters.get(arg[2]) ?? 'unknown' : 'unknown');
                }
              return;
            }
            break;
          case 'var':
            for (const tag of tags)
              if (!refinements.has(node[2]) || tag === refinements.get(node[2]))
                add(tag, parameters.get(node[2]) ?? 'unknown');
            return;
        }
        for (const tag of tags) add(tag, 'unknown');
      }
      inspect(fn.body, new Map());
    }
  } while (changed);
  return defs.map(fn => ({
    function: fn.name,
    results: Object.fromEntries(Array.from(summaries.get(fn.name),
      ([tag, origins]) => [tag, [...new Set([...origins].map(o => typeof o === 'number' ? 'unknown' : o))].sort()])),
  }));
}

// Record the movement of data arguments on recursive edges. Only a direct
// projection from the incoming tuple establishes an argument's identity.
function recursiveDataEdges(fn) {
  if (fn.argument_type?.[0] !== 'Tuple') return [];
  const slots = fn.argument_type.slice(1).flatMap((type, i) => type[0] === 'Data' ? [i] : []);
  if (!slots.length) return [];
  const projections = new Map();
  const edges = [];
  function source(node) {
    if (node?.[0] === 'var') return projections.get(node[2]);
    if (node?.[0] === 'project' && node[2][0] === 'var' && node[2][2] === fn.parameter_id)
      return Number(node[3]);
  }
  function visit(node, tail, ranges) {
    if (!Array.isArray(node)) return;
    if (node[0] === 'let') {
      visit(node[3], false, ranges);
      const origin = source(node[3]);
      if (origin !== undefined) projections.set(node[2], origin);
      const value = node[3];
      if (value[0] === 'prim' && value[2] === 'bytes_index') {
        ranges = new Map(ranges);
        ranges.set(node[2], [0, 255]);
      }
      visit(node[4], tail, ranges);
      return;
    }
    if (node[0] === 'if') {
      const condition = node[2];
      visit(condition, false, ranges);
      for (const branch of [3, 4]) {
        let next = ranges;
        if (condition[0] === 'prim' && condition[3]?.[0] === 'var' && condition[4]?.[0] === 'int') {
          const id = condition[3][2];
          const bound = Number(condition[4][2]);
          if (ranges.has(id) && Number.isSafeInteger(bound) && bound >= -1 && bound <= 256) {
            let [lo, hi] = ranges.get(id);
            const yes = branch === 3;
            switch (condition[2]) {
              case 'lt': if (yes) hi = Math.min(hi, bound - 1); else lo = Math.max(lo, bound); break;
              case 'gt': if (yes) lo = Math.max(lo, bound + 1); else hi = Math.min(hi, bound); break;
            }
            if (lo > hi) continue;
            next = new Map(ranges);
            next.set(id, [lo, hi]);
          }
        }
        visit(node[branch], tail, next);
      }
      return;
    }
    if (node[0] === 'match') {
      visit(node[2], false, ranges);
      for (const branch of node.slice(3)) visit(branch[2], tail, ranges);
      return;
    }
    if (node[0] === 'call' && node[2] === fn.name) {
      const args = node[3][0] === 'tuple' ? node[3].slice(2) : [];
      const transfers = slots.map(slot => {
        const value = args[slot];
        const from = source(value);
        if (from !== undefined) return {slot, from};
        if (value?.[0] === 'call' && value[3][0] === 'tuple') {
          const inputs = value[3].slice(2);
          const byteRanges = inputs.flatMap((v, argument) =>
            v[0] === 'var' && ranges.has(v[2]) ? [{argument, range: ranges.get(v[2])}] : []);
          return {slot, producer: value[2], inputs: inputs.map(v => source(v) ?? null), byteRanges};
        }
        return {slot, unknown: true};
      });
      edges.push({function: fn.name, call: node[1], tail, transfers});
    }
    for (const child of node) visit(child, false, ranges);
  }
  visit(fn.body, true, new Map());
  return edges;
}

let result = updates;
if (process.argv.includes('--recursive-data-edges')) result = artifact.functions.flatMap(recursiveDataEdges);
if (process.argv.includes('--call-uses')) result = artifact.functions.flatMap(inspectCallUses);
if (process.argv.includes('--fresh-arguments')) {
  const returned = new Map(resultOrigins().map(r => [r.function, r.results]));
  result = artifact.functions.flatMap(fn => freshCallArguments(fn, returned));
}
if (process.argv.includes('--result-origins')) result = resultOrigins();
console.log(JSON.stringify(result, null, 2));
