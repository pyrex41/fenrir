// Compute the action for each possible byte in a checked forward scan.
// Every table entry must come from a total, side-effect-free evaluation.
const isVar = (n, id) => n?.[0] === 'var' && n[2] === id;
const isInt = (n, value) => n?.[0] === 'int' && n[2] === value;
const isPrim = (n, op) => n?.[0] === 'prim' && n[2] === op;

function predicate(n, env, functions, budget) {
  if (--budget.remaining < 0 || !Array.isArray(n)) return undefined;
  const evalNode = child => predicate(child, env, functions, budget);
  if (n[0] === 'var') return env.get(n[2]);
  if (n[0] === 'int') return BigInt(n[2]);
  if (n[0] === 'bool') return n[2];
  if (n[0] === 'if') {
    const condition = evalNode(n[2]);
    return typeof condition === 'boolean' ? evalNode(condition ? n[3] : n[4]) : undefined;
  }
  if (n[0] === 'call') {
    const callee = functions.get(n[2]);
    if (!callee?.noAllocation || !callee.unpacked || n[3][0] !== 'tuple') return undefined;
    const bindings = new Map();
    for (const [i, p] of callee.unpacked.parameters.entries()) {
      const value = evalNode(n[3][i + 2]);
      if (value === undefined) return undefined;
      bindings.set(p.id, value);
    }
    return predicate(callee.unpacked.body, bindings, functions, budget);
  }
  if (n[0] !== 'prim') return undefined;
  const a = evalNode(n[3]);
  if (n[2] === 'not') return typeof a === 'boolean' ? !a : undefined;
  if (n.length !== 5) return undefined;
  const b = evalNode(n[4]);
  if (a === undefined || b === undefined) return undefined;
  switch (n[2]) {
    case 'eq': return a === b;
    case 'lt': return a < b;
    case 'le': return a <= b;
    case 'gt': return a > b;
    case 'ge': return a >= b;
    default: return undefined;
  }
}

export function byteScanTable(f, unpacked, functions) {
  if (JSON.stringify(f.argument_type) !== '["Tuple","Bytes","I64"]' || f.result_type !== 'I64') return null;
  const [bytes, index] = unpacked.parameters.map(p => p.id);
  const body = unpacked.body;
  if (body[0] !== 'if' || !isPrim(body[2], 'eq') || !isVar(body[2][3], index) ||
      !isPrim(body[2][4], 'bytes_length') || !isVar(body[2][4][3], bytes) || !isInt(body[3], '-1')) return null;
  const step = body[4];
  if (step[0] !== 'let' || !isPrim(step[3], 'bytes_index') ||
      !isVar(step[3][3], bytes) || !isVar(step[3][4], index)) return null;
  const table = [];
  for (let byte = 0; byte < 256; byte++) {
    const env = new Map([[step[2], BigInt(byte)]]);
    const budget = {remaining: 128};
    let action = step[4];
    while (action[0] === 'if') {
      const take = predicate(action[2], env, functions, budget);
      if (typeof take !== 'boolean') return null;
      action = take ? action[3] : action[4];
    }
    if (isInt(action, '-1')) table.push(0);
    else if (isVar(action, index)) table.push(1);
    else if (action[0] === 'call' && action[2] === f.name && action[3][0] === 'tuple' &&
             isVar(action[3][2], bytes) && isPrim(action[3][3], 'add') &&
             isVar(action[3][3][3], index) && isInt(action[3][3][4], '1')) table.push(2);
    else return null;
  }
  return table;
}
