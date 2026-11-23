import {isTaskSchema,TRAP_CODES} from '../tc0/pure-call-artifact.mjs';
import {byteScanTable} from './byte-scan.mjs';
import {resultPrinter, nativeVariants} from './result-printer.mjs';
// Recover the ordered field bindings introduced by frontend argument destructuring.
function tupleParameters(f) {
  if (f.argument_type?.[0] !== 'Tuple') return null;
  const parameters = [];
  let body = f.body;
  for (const type of f.argument_type.slice(1)) {
    const projection = body[3];
    if (body[0] !== 'let' || projection?.[0] !== 'project' ||
        projection[2][0] !== 'var' || projection[2][2] !== f.parameter_id ||
        Number(projection[3]) !== parameters.length) return null;
    parameters.push({id: body[2], type});
    body = body[4];
  }
  // The original tuple must never escape through a use of its binder.
  function usesTuple(node) {
    return Array.isArray(node) &&
      ((node[0] === 'var' && node[2] === f.parameter_id) || node.some(usesTuple));
  }
  if (parameters.length > 8 || usesTuple(body)) return null;
  return {parameters, body};
}

// Lower the argument convention after artifact validation. Both analyses and
// code generation consume the same ordered operands, including one boxed tuple
// for calls whose callee uses the tuple as a value.
function lowerCall(node, callee, caller, reusableTailFrame) {
  const argument = node[3];
  if (!callee.unpacked || argument[0] !== 'tuple') {
    return {kind: 'ordinary', origin: node[1], operands: [argument]};
  }
  const operands = argument.slice(2);
  if (operands.length !== callee.unpacked.parameters.length) {
    throw Error('Unpacked call arity differs at ' + node[1]);
  }
  const kind = callee.f === caller && reusableTailFrame ? 'self-loop' : 'fields';
  return {kind, origin: node[1], operands};
}

// Track operations that can run without allocating or capturing a continuation.
// Tuple literals below direct calls disappear only for an unpacked callee.
function allocationFree(node, f, functions, tail = false, allowRecursion = false) {
  const child = n => allocationFree(n, f, functions, false, allowRecursion);
  const branch = n => allocationFree(n, f, functions, tail, allowRecursion);
  switch (node[0]) {
    case 'var': case 'int': case 'bool': case 'unit': case 'bytes': return true;
    case 'prim': return ['add','sub','mul','div','neg','eq','lt','le','gt','ge','not','bytes_index','bytes_length']
      .includes(node[2]) && node.slice(3).every(child);
    case 'let': return child(node[3]) && branch(node[4]);
    case 'if': return child(node[2]) && branch(node[3]) && branch(node[4]);
    case 'call': {
      const callee = functions.get(node[2]);
      if (!callee) return false;
      const call = lowerCall(node, callee, f, tail);
      if (callee.f === f) {
        if (!allowRecursion || call.kind !== 'self-loop') return false;
      } else if (!callee.noAllocation) return false;
      return call.operands.every(child);
    }
    default: return false;
  }
}

function matches(node, pattern) {
  if (!Array.isArray(pattern)) return node === pattern;
  return Array.isArray(node) && node.length === pattern.length + 1 &&
    node[0] === pattern[0] && pattern.slice(1).every((child,i) => matches(node[i+2], child));
}

// Recognize the checked left fold over bytes[start..end). Strip source IDs
// only for matching. The original loop remains the precise trap path.
function byteSumReduction(f, loop) {
  if (JSON.stringify(f.argument_type) !== '["Tuple","Bytes","I64","I64","I64"]') return false;
  const [bytes, index, end, sum] = loop.parameters.map(p => ['var', p.id]);
  const expected = ['if', ['prim', 'eq', index, end], sum,
    ['call', f.name, ['tuple', bytes, ['prim', 'add', index, ['int', '1']], end,
      ['prim', 'add', sum, ['prim', 'bytes_index', bytes, index]]]]];
  return matches(loop.body, expected);
}

// Identify the arithmetic encoding of membership and insertion for a single
// power-of-two bit. Preserve checked arithmetic for all other signed inputs.
function bitSetOperation(def, membershipFunctions) {
  const args = def.unpacked?.parameters;
  if (args?.length !== 2 || args.some(p => p.type !== 'I64') || def.f.effects.length) return null;
  const [mask, bit] = args.map(p => ['var', p.id]);
  const body = def.unpacked.body;
  if (body[0] !== 'if') return null;
  const smaller = ['prim', 'lt', mask, bit];
  if (def.f.result_type === 'Bool' && body[4][0] === 'let') {
    const quotient = ['var', body[4][2]];
    const twiceHalf = ['prim', 'mul', ['int', '2'], ['prim', 'div', quotient, ['int', '2']]];
    const parity = ['prim', 'eq', ['prim', 'sub', quotient, twiceHalf], ['int', '1']];
    if (matches(body, ['if', smaller, ['bool', false],
        ['let', body[4][2], ['prim', 'div', mask, bit], parity]])) return 'membership';
  }
  if (def.f.result_type === 'I64' && body[4][0] === 'if') {
    const callee = body[4][2][2];
    const add = ['prim', 'add', mask, bit];
    if (membershipFunctions.has(callee) && matches(body, ['if', smaller, add,
        ['if', ['call', callee, ['tuple', mask, bit]], mask, add]])) return 'insert';
  }
  return null;
}

// Emit direct ARM64 for typed tuple values. Stack slots are split into raw
// temporaries and exact pointer roots so arbitrary I64s never reach the GC.
export function managedImage(program, prefix, codes, exports = new Map(), host = {}) {
  const lines = ['.text', '.p2align 2'];
  const literals = [];
  const allocateConstructor = Symbol('allocate constructor');
  const constructorCalls = [];
  let comparesObjects = false;
  // Image objects may reference other immutable image objects. Pointer words
  // belong in relocatable data so Darwin can rebase them at load time.
  const constants = new Map();
  function constant(tag, words, hex = '', mask = 0, relocatable = mask !== 0) {
    const key = JSON.stringify([tag, words, hex, mask]);
    if (constants.has(key)) return constants.get(key);
    const name = 'Lconstant' + constants.size;
    constants.set(key, name);
    if (relocatable) literals.push(prefix ? '.section __DATA_CONST,__const' : '.section .rodata');
    literals.push('.p2align 3', name + ':', ...words.map(w => '.quad ' + w),
      '.zero ' + (8 * (9 - words.length)), '.long ' + tag, '.byte ' + mask + ',2,0,0');
    if (relocatable) literals.push('.text');
    if (hex) literals.push('.byte ' + [...Buffer.from(hex, 'hex')].join(','));
    return name;
  }
  function address(code, name, reg = 'x0') {
    const page = prefix ? name + '@PAGE' : name;
    const offset = prefix ? name + '@PAGEOFF' : ':lo12:' + name;
    code.push('adrp ' + reg + ', ' + page, 'add ' + reg + ', ' + reg + ', ' + offset);
  }
  const events = [];
  const positions = new Map(program.source_map.map(p => [p.id, p]));
  function locationLiteral(symbol, id) {
    const p = positions.get(id);
    const location = Buffer.from('trap at: ' + p.file + ':' + p.line + ':' + p.column + '\n');
    literals.push(symbol + ':', '.byte ' + [...location, 0].join(','));
  }
  const functions = new Map(program.functions.map((f, i) => [f.name, {f, label: 'Lfn' + i}]));
  for (const def of functions.values()) def.unpacked = tupleParameters(def.f);
  const membershipFunctions = new Set();
  for (const def of functions.values()) {
    if (bitSetOperation(def, membershipFunctions) === 'membership')
      membershipFunctions.add(def.f.name);
  }
  // Discover leaf helpers first. A subsequent pass can then admit their callers.
  let changed;
  do {
    changed = false;
    for (const def of functions.values()) {
      if (def.noAllocation) continue;
      const body = def.unpacked?.body ?? def.f.body;
      if (!allocationFree(body, def.f, functions, true)) {
        // A self tail call with explicit fields becomes a local back edge.
        // Publish the final calling convention before analyzing its callers.
        if (!def.unpacked || !allocationFree(body, def.f, functions, true, true)) continue;
        def.loop = def.unpacked;
      }
      def.noAllocation = true;
      changed = true;
    }
  } while (changed);
  const entry = functions.get(program.entry).f;
  if (JSON.stringify(entry.argument_type) !== JSON.stringify(host.entryType ?? 'I64')) throw Error('Unsupported managed entry profile');
  const effects = new Map(program.effects.map((d,i) => [d.name, {id:i, ops:d.operations}]));
  const constructors = new Map();
  let nextTag = 1;
  const traps = {name: 'TrapCode', constructors: TRAP_CODES.map(name => ({name, fields: []}))};
  for (const datatype of [traps, ...program.datatypes]) {
    constructors.set(datatype.name, new Map(datatype.constructors.map(c =>
      [c.name, {tag: nextTag++, fields: c.fields}])));
  }
  function powerOfTwoShift(node) {
    if (node[0] !== 'int') return undefined;
    const value = BigInt(node[2]);
    if (value <= 0n || (value & (value - 1n)) !== 0n) return undefined;
    return value.toString(2).length - 1;
  }

  // x - d * (x / d), with d a positive power of two. Truncation toward
  // zero bounds the product between zero and x, so neither operation traps.
  function remainderShift(node) {
    const [, , op, x, product] = node;
    if (op !== 'sub' || x?.[0] !== 'var' || product?.[0] !== 'prim' || product[2] !== 'mul')
      return undefined;
    const factor = product[3][0] === 'int' ? product[3] : product[4];
    const quotient = factor === product[3] ? product[4] : product[3];
    if (quotient[0] !== 'prim' || quotient[2] !== 'div' || quotient[3][0] !== 'var' ||
        quotient[3][2] !== x[2] || quotient[4][0] !== 'int' || quotient[4][2] !== factor[2])
      return undefined;
    return powerOfTwoShift(factor);
  }

  function literalValue(node) {
    const [tag, , value] = node;
    if (tag === 'int' || tag === 'bool') {
      return {word: String(BigInt(value)), type: tag === 'int' ? 'I64' : 'Bool'};
    }
    if (tag === 'bytes') {
      return {word: constant(0xffffffff, [String(value.length / 2)], value), type: 'Bytes', pointer: true};
    }
    if (tag !== 'construct' && tag !== 'tuple') return null;
    const ctor = tag === 'construct' ? constructors.get(value).get(node[3]) : null;
    const fields = [];
    for (const child of node.slice(ctor ? 4 : 2)) {
      const field = literalValue(child);
      if (!field) return null;
      fields.push(field);
    }
    if (fields.length > 8) throw Error('Native object field limit exceeded');
    const mask = fields.reduce((bits, field, i) => field.pointer ? bits | (1 << i) : bits, 0);
    return {word: constant(ctor?.tag ?? 0, fields.map(f => f.word), '', mask), pointer: true,
            type: ctor ? (value === 'TrapCode' ? value : ['Data', value]) : ['Tuple', ...fields.map(f => f.type)]};
  }
  host.describeConstructors?.(constructors);
  const bindings = new Map(codes.map(c => [c.code_id, c.free_bindings]));
  const answerTypes = new Map();
  const pending = [...functions.values()];
  for (const {f, label, captures = [], resumption} of pending) {
    const code = [];
    let handlerCount = 0;
    let scopeCount = 0;
    let unwind = label + 'end';
    const explicit = new Map();
    let mayCollect = false;
    const unlinkRoots = Symbol("unlink roots");
    const clearIterationRoots = Symbol('clear iteration roots');
    const failurePaths = new Map();
    function failure(id, status) {
      const symbol = label + 'fail' + id + '_' + status;
      failurePaths.set(symbol, {id, status, destination: unwind});
      return symbol;
    }
    const slots = [];
    let nextRoot = 0;
    const isPointer = t => t === 'SendResult' || t === 'Bytes' || t === 'TrapCode' || Array.isArray(t) && ['Tuple', 'Data', 'Arrow', 'Task', 'Outcome', 'Channel', 'ReceiveResult'].includes(t[0]);
    const fresh = type => {
      if (!isPointer(type) && !['I64','Bool','Unit'].includes(type)) throw Error('Unsupported managed type');
      const slot = {type, id: slots.length};
      if (isPointer(type)) slot.rootIndex = nextRoot++;
      slots.push(slot);
      return slot;
    };
    const ref = slot => '@' + slot.id + '@';
    const save = slot => code.push('str x0, [sp, ' + ref(slot) + ']');
    const load = (slot, reg = 'x0') => {
      // Match fields remain reachable through their immutable, rooted subject.
      // Read them when consumed, including when copying a capture into a closure.
      if (slot.returned) {
        if (reg !== 'x0') throw Error('tail result consumed outside return position');
      } else if (slot.subject) {
        load(slot.subject, reg);
        code.push('ldr ' + reg + ', [' + reg + ', #' + (8 * slot.field) + ']');
      } else if (slot.image) address(code, slot.image, reg);
      else code.push('ldr ' + reg + ', [sp, ' + ref(slot) + ']');
    };
    const {loop, unpacked} = functions.get(f.name) ?? {};
    const incoming = [];
    // An unpacked entry carries only its fields beyond the boxed ABI adapter.
    const argument = unpacked ? null : fresh(f.argument_type);
    const env = new Map();
    if (argument) env.set(f.parameter_id, argument);
    const capturedSlots = captures.map(({id, type}) => {
      const slot = fresh(type);
      env.set(id, slot);
      return slot;
    });
    // No allocation occurs between unlinking our roots and the callee linking
    // its frame. The outgoing argument and closure survive fen_leave in the
    // reserved result area. Restore the original return address before branching.
    function tailBranch(destination) {
      code.push(unlinkRoots, 'mov sp, x29', 'ldp x29, x30, [sp], #16');
      if (destination) code.push('b ' + destination);
      else code.push('ldr x2, [x1]', 'br x2');
    }
    function captureBindings(id, body, origin) {
      const free = new Set();
      function visit(node) {
        if (!Array.isArray(node)) return;
        if (node[0] === 'var' && env.has(node[2])) free.add(node[2]);
        node.forEach(visit);
      }
      visit(body);
      bindings.set(id, [...free]);
      positions.set(id, positions.get(origin));
    }
    // Find a resumption through strict operands. Build its evaluation context
    // only after finding the use, so an unsuccessful search emits no code.
    function splitResume(node) {
      if (node[0] === 'resume' && node[2] === resumption) {
        const id = node[1] + 'answer';
        return {node, id, after: ['var', id, id], before: []};
      }
      let indices;
      switch (node[0]) {
        case 'prim': case 'call': case 'emit':
          indices = node.slice(3).map((_, i) => i + 3); break;
        case 'tuple': case 'apply':
          indices = node.slice(2).map((_, i) => i + 2); break;
        case 'construct':
          indices = node.slice(4).map((_, i) => i + 4); break;
        case 'project': case 'if': case 'match': indices = [2]; break;
        case 'let': indices = [3]; break;
        default: return null;
      }
      for (const index of indices) {
        const part = splitResume(node[index]);
        if (!part) continue;
        const after = [...node];
        const before = [];
        for (const earlier of indices) {
          if (earlier === index) break;
          const id = node[1] + 'operand' + earlier;
          before.push([id, node[earlier]]);
          after[earlier] = ['var', id, id];
        }
        after[index] = part.after;
        return {...part, before: before.concat(part.before), after};
      }
      return null;
    }
    function emit(e, tail = false) {
      const [tag, , v] = e;
      let type;
      if (tag === 'var') return env.get(v);
      if (tail && resumption && tag !== 'resume' && !(tag === 'let' && e[3][0] === 'resume')) {
        const part = splitResume(e);
        if (part) {
          for (const [id, expr] of part.before) env.set(id, emit(expr));
          const binding = e[1] + 'resumed';
          positions.set(binding, positions.get(e[1]));
          return emit(['let', binding, part.id, part.node, part.after], true);
        }
      }
      if (tag === 'let') {
        if (e[3][0] === 'resume' && e[3][2] === resumption && tail) {
          const payload = emit(e[3][3]);
          const id = e[1] + 'after';
          captureBindings(id, e[4], e[1]);
          const answer = answerTypes.get(resumption);
          const closure = emit(['lambda', id, v, answer, answer, [], [], e[4]]);
          load(closure);
          code.push('bl ' + prefix + 'fen_defer_clause', 'cbnz x0, ' + failure(e[3][1], 3));
          return payload;
        }
        const body = e[4];
        if (e[3][0] === 'construct' && body[0] === 'match' &&
            body[2][0] === 'var' && body[2][2] === v) {
          // The fresh parent has a single consumer if no arm can observe its
          // binder, including through a closure. Its children may still alias.
          const usesParent = node => Array.isArray(node) &&
            ((node[0] === 'var' && node[2] === v) || node.some(usesParent));
          const arms = body.slice(3);
          if (!arms.some(arm => usesParent(arm[2])))
            return emit(['match', body[1], e[3], ...arms], tail);
        }
        env.set(v, emit(e[3]));
        return emit(body, tail);
      }
      if (tag === 'scope') {
        mayCollect = true;
        const frame = 'add x0, sp, #SCOPE' + scopeCount++ + 'OFFSET';
        const outer = unwind;
        const abort = label + 'scopeAbort' + e[1];
        const done = label + 'scopeDone' + e[1];
        code.push(frame, 'bl ' + prefix + 'fen_enter_scope');
        unwind = abort;
        const result = emit(v);
        unwind = outer;
        code.push(frame, 'mov x1, #0', 'bl ' + prefix + 'fen_leave_scope',
                  'cbnz x0, ' + failure(e[1], 5), 'b ' + done,
                  abort + ':', 'stp x0, x1, [sp]', frame, 'mov x1, #1',
                  'bl ' + prefix + 'fen_leave_scope', 'ldp x0, x1, [sp]', 'b ' + outer, done + ':');
        return result;
      }
      if (tag === 'spawn') {
        mayCollect = true;
        const closure = emit(v);
        type = ['Task', closure.type[2]];
        load(closure);
        code.push('mov x1, #' + Number(isPointer(type[1])), 'bl ' + prefix + 'fen_spawn_closure',
                  'cmp x1, #3', 'b.eq ' + failure(e[1], 3),
                  'cmp x1, #5', 'b.eq ' + failure(e[1], 5),
                  'cbnz x1, ' + failure(e[1], 7));
      } else if (tag === 'channel') {
        mayCollect = true;
        type = ['Channel', v];
        code.push('mov x0, #' + e[3], 'mov x1, #' + Number(isPointer(v)),
                  'bl ' + prefix + 'fen_new_channel', 'cbz x0, ' + failure(e[1], 3));
      } else if (tag === 'close') {
        mayCollect = true;
        load(emit(v));
        code.push('bl ' + prefix + 'fen_close_handle', 'mov x0, #0');
        type = 'Unit';
      } else if (tag === 'send') {
        mayCollect = true;
        type = 'SendResult';
        const channel = emit(v);
        load(emit(e[3]), 'x1');
        load(channel);
        code.push('bl ' + prefix + 'fen_send_handle', 'cbz x0, 1f');
        address(code, constant(0, []));
        code.push('b 2f', '1:');
        address(code, constant(1, []));
        code.push('2:');
      } else if (tag === 'receive') {
        mayCollect = true;
        const channel = emit(v);
        type = ['ReceiveResult', channel.type[1]];
        const payload = fresh(channel.type[1]);
        load(channel);
        code.push('bl ' + prefix + 'fen_receive_handle', 'cbz x1, 1f');
        save(payload);
        code.push('mov x0, #' + Number(isPointer(payload.type)), 'mov x1, #0',
                  'bl ' + prefix + 'fen_allocate', 'cbz x0, ' + failure(e[1], 3));
        load(payload, 'x2');
        code.push('str x2, [x0]', 'b 2f', '1:');
        address(code, constant(1, []));
        code.push('2:');
      } else if (tag === 'cancel') {
        mayCollect = true;
        load(emit(v));
        code.push('bl ' + prefix + 'fen_cancel_handle', 'mov x0, #0');
        type = 'Unit';
      } else if (tag === 'await') {
        mayCollect = true;
        const task = emit(v);
        type = ['Outcome', task.type[1]];
        const variants = nativeVariants(type, constructors);
        const done = label + 'awaitDone' + e[1];
        const ok = done + 'ok';
        load(task);
        code.push('bl ' + prefix + 'fen_await_handle', 'cbz x1, ' + ok);
        for (const [status, trap] of [[1,'Overflow'],[2,'DivZero'],[4,'Bounds'],[5,'ChildFailed'],[7,'TaskLimit'],[9,'InvalidDuration'],[8,null]]) {
          const next = done + 'skip' + status;
          code.push('cmp x1, #' + status, 'b.ne ' + next);
          const object = trap
            ? constant(variants.get('Failed').tag, [constant(constructors.get('TrapCode').get(trap).tag, [])], '', 1)
            : constant(variants.get('Cancelled').tag, []);
          address(code, object);
          code.push('b ' + done, next + ':');
        }
        code.push('b ' + unwind, ok + ':');
        const payload = fresh(task.type[1]);
        save(payload);
        code.push('mov x0, #' + Number(isPointer(payload.type)), 'mov x1, #' + variants.get('Ok').tag,
                  'bl ' + prefix + 'fen_allocate', 'cbz x0, ' + failure(e[1], 3));
        load(payload, 'x2');
        code.push('str x2, [x0]', done + ':');
      } else if (tag === 'now') {
        code.push('bl ' + prefix + 'fen_root_now');
        type = 'I64';
      } else if (tag === 'sleep') {
        mayCollect = true;
        load(emit(v));
        code.push('bl ' + prefix + 'fen_root_sleep', 'cmp x1, #9', 'b.eq ' + failure(e[1], 9),
                  'cbnz x1, ' + failure(e[1], 1));
        type = 'Unit';
      } else if (tag === 'yield') {
        mayCollect = true; // Another runnable task may allocate while this frame is parked.
        code.push('bl ' + prefix + 'fen_root_yield', 'mov x0, #0');
        type = 'Unit';
      } else if (tag === 'unit') {
        type = 'Unit';
        code.push('mov x0, #0');
      } else if (tag === 'emit') {
        const payload = emit(e[3]);
        const symbol = 'Lemit' + e[1];
        events.push({symbol, name: v, type: payload.type, task: isTaskSchema(program.schema_version)});
        load(payload);
        code.push('bl ' + symbol, 'mov x0, #0');
        type = 'Unit';
      } else if (tag === 'int' || tag === 'bool') {
        type = tag === 'int' ? 'I64' : 'Bool';
        const n = BigInt.asUintN(64, BigInt(v));
        const words = [0n, 16n, 32n, 48n].map(shift => Number((n >> shift) & 65535n));
        const ones = words.filter(word => word === 65535).length;
        const zeros = words.filter(word => word === 0).length;
        const fill = ones > zeros ? 65535 : 0;
        const first = Math.max(0, words.findIndex(word => word !== fill));
        code.push((fill ? 'movn' : 'movz') + ' x0, #' + (words[first] ^ fill) + ', lsl #' + (16 * first));
        words.forEach((word, i) => {
          if (i !== first && word !== fill) code.push('movk x0, #' + word + ', lsl #' + (16 * i));
        });
      } else if (tag === 'bytes') {
        return {image: constant(0xffffffff, [String(v.length / 2)], v), type: 'Bytes'};
      } else if (tag === 'if') {
        const branch = label + 'if' + e[1];
        load(emit(v));
        code.push('cbz x0, ' + branch + 'else');
        const firstBranchRoot = nextRoot;
        const yes = emit(e[3], tail);
        load(yes);
        code.push('b ' + branch + 'done', branch + 'else:');
        const yesEnd = nextRoot;
        nextRoot = firstBranchRoot;
        load(emit(e[4], tail));
        nextRoot = Math.max(yesEnd, nextRoot);
        code.push(branch + 'done:');
        type = yes.type;
      } else if (tag === 'tuple' || tag === 'construct') {
        const ctor = tag === 'construct' ? constructors.get(v).get(e[3]) : null;
        const children = e.slice(ctor ? 4 : 2);
        if (children.length > 8) throw Error('Native object field limit exceeded');
        const literal = literalValue(e);
        if (literal) return {image: literal.word, type: literal.type};
        mayCollect = true;
        const fields = children.map(child => emit(child));
        type = ctor ? (v === 'TrapCode' ? v : ['Data', v]) : ['Tuple', ...fields.map(s => s.type)];
        const mask = fields.reduce((m,s,i) => m | (Number(isPointer(s.type)) << i), 0);
        const allocator = fields.length === 8 ? 'bl ' + prefix + 'fen_allocate_full' : allocateConstructor;
        code.push('mov x0, #' + mask, 'mov x1, #' + (ctor ? ctor.tag : 0), allocator, 'cbz x0, ' + failure(e[1], 3));
        // All children are evaluated and the new object allocated. The copy
        // sequence makes no calls, so x4 can hold an immutable match subject.
        let retained;
        function loadField(slot, reg) {
          if (slot.subject && slot.subject === retained)
            code.push('ldr ' + reg + ', [x4, #' + (8 * slot.field) + ']');
          else load(slot, reg);
        }
        for (let i = 0; i < fields.length; i += 2) {
          const left = fields[i], right = fields[i + 1];
          if (left.subject && right?.subject === left.subject && right.field === left.field + 1) {
            if (retained !== left.subject) {
              load(left.subject, 'x4');
              retained = left.subject;
            }
            code.push('ldp x2, x3, [x4, #' + (8 * left.field) + ']',
                      'stp x2, x3, [x0, #' + (8 * i) + ']');
            continue;
          }
          loadField(left, 'x2');
          if (right) {
            loadField(right, 'x3');
            code.push('stp x2, x3, [x0, #' + (8*i) + ']');
          } else {
            code.push('str x2, [x0, #' + (8*i) + ']');
          }
        }
      } else if (tag === 'match') {
        // An immediately matched constructor has no observable cell identity.
        // Evaluate even unused fields in source order, retaining their ordinary
        // slots (and roots) until the selected arm consumes them.
        if (v[0] === 'construct' && v.length - 4 <= 8) {
          const [, binders, body] = e.slice(3).find(([name]) => name === v[3]);
          const fields = v.slice(4).map(field => emit(field));
          binders.forEach((binder, index) => env.set(binder, fields[index]));
          return emit(body, tail);
        }
        const subject = emit(v);
        const variants = nativeVariants(subject.type, constructors);
        const dispatch = label + 'match' + e[1];
        const arms = e.slice(3);
        load(subject);
        code.push('ldr w0, [x0, #72]');
        for (const [name] of arms) {
          const id = variants.get(name).tag;
          if (id <= 4095) code.push('cmp w0, #' + id);
          else code.push('mov x2, #' + id, 'cmp x0, x2');
          code.push('b.eq ' + dispatch + 'arm' + id);
        }
        code.push('brk #0'); // unreachable for a validated exhaustive match
        const firstArmRoot = nextRoot;
        let armsEnd = nextRoot;
        for (const [name, binders, body] of arms) {
          nextRoot = firstArmRoot;
          const ctor = variants.get(name);
          code.push(dispatch + 'arm' + ctor.tag + ':');
          binders.forEach((binder, field) => {
            env.set(binder, {type: ctor.fields[field], subject, field});
          });
          const result = emit(body, tail);
          type = result.type;
          load(result);
          armsEnd = Math.max(armsEnd, nextRoot);
          code.push('b ' + dispatch + 'end');
        }
        nextRoot = armsEnd;
        code.push(dispatch + 'end:');
      } else if (tag === 'project') {
        // Projection remains strict in every operand, including those after
        // the selected field. Its ordinary slot keeps it live across calls.
        if (v[0] === 'tuple' && v.length - 2 <= 8) {
          const fields = v.slice(2).map(field => emit(field));
          return fields[Number(e[3])];
        }
        const tuple = emit(v);
        type = tuple.type[Number(e[3]) + 1];
        load(tuple);
        code.push('ldr x0, [x0, #' + (8*Number(e[3])) + ']');
      } else if (tag === 'resume' || tag === 'discontinue') {
        if (v !== resumption || (tag === 'resume' && !tail))
          throw Error('Native resume with a following clause continuation is pending');
        const payload = tag === 'resume' ? emit(e[3]) : null;
        code.push('mov x0, #' + (payload ? 1 : 2), 'bl ' + prefix + 'fen_use_resumption',
                  'cbz x0, ' + failure(e[1], 6));
        if (payload) return payload;
        code.push('mov x0, #0');
        type = 'Unit';
      } else if (tag === 'perform') {
        mayCollect = true;
        const effect = effects.get(v);
        const op = effect.ops.findIndex(o => o.name === e[3]);
        load(emit(e[4]));
        const hostOp = host.operations?.get(v)?.get(e[3]);
        if (hostOp) {
          if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(hostOp)) throw Error('Invalid native host operation');
          code.push('bl ' + prefix + hostOp);
        } else {
          code.push('mov x1, #' + effect.id, 'mov x2, #' + op, 'bl ' + prefix + 'fen_perform');
        }
        code.push('cbnz x1, ' + unwind);
        type = effect.ops[op].result_type;
      } else if (tag === 'handle') {
        const effect = effects.get(v);
        if (effect.ops.length > 8) throw Error('Native handler exceeds eight operations');
        const closures = effect.ops.map((op,i) => {
          const clause = e[3].find(c => c[0] === op.name);
          const binder = clause[1], body = clause.at(-1);
          const id = e[1] + 'op' + i;
          if (clause.length === 4) explicit.set(id, clause[2]);
          captureBindings(id, body, e[1]);
          return ['lambda', id, binder, op.argument_type, op.result_type, [], [], body];
        });
        const table = emit(['tuple', e[1], ...closures]);
        const frame = 'HANDLER' + handlerCount++ + 'OFFSET';
        const deferred = fresh(['Tuple']);
        load(table, 'x1');
        code.push('add x3, sp, ' + ref(deferred));
        code.push('add x0, sp, #' + frame, 'mov x2, #' + effect.id, 'bl ' + prefix + 'fen_install_handler');
        const outerUnwind = unwind;
        const landing = label + 'handler' + e[1];
        unwind = landing;
        const value = emit(e[4]);
        for (const c of e[3]) if (c.length === 4) answerTypes.set(c[2], value.type);
        unwind = outerUnwind;
        const result = fresh(value.type);
        load(value);
        code.push('b ' + landing + 'save', landing + ':', 'add x2, sp, #' + frame,
                  'cmp x1, x2', 'b.ne ' + outerUnwind, landing + 'save:');
        save(result);
        code.push('add x1, sp, #' + frame, 'bl ' + prefix + 'fen_finish_handler',
                  'cbnz x1, ' + outerUnwind);
        save(result);
        return result;
      } else if (tag === 'lambda') {
        const captures = bindings.get(e[1]).map(id => ({id, type: env.get(id).type}));
        if (captures.length > 7) throw Error('Closure exceeds seven inline captures');
        const bodyLabel = 'Llambda' + e[1];
        pending.push({label: bodyLabel, captures, resumption: explicit.get(e[1]),
          f: {parameter_id: v, argument_type: e[3], body: e[7]}});
        type = ['Arrow', e[3], e[4], e[5]];
        if (!captures.length) {
          // The entry address needs relocation but is never a managed pointer.
          return {image: constant(0, [bodyLabel], '', 0, true), type};
        }
        mayCollect = true;
        const mask = captures.reduce((m,c,i) => m | (Number(isPointer(c.type)) << (i+1)), 0);
        code.push('mov x0, #' + mask, 'mov x1, #0', 'bl ' + prefix + 'fen_allocate',
                  'cbz x0, ' + failure(e[1], 3), 'adr x2, ' + bodyLabel, 'str x2, [x0]');
        captures.forEach((c,i) => {
          load(env.get(c.id), 'x2');
          code.push('str x2, [x0, #' + (8*(i+1)) + ']');
        });
      } else if (tag === 'apply') {
        if (!tail) mayCollect = true;
        const closure = emit(v);
        load(emit(e[3]));
        load(closure, 'x1');
        if (tail) tailBranch();
        else code.push('ldr x2, [x1]', 'blr x2', 'cbnz x1, ' + unwind);
        type = closure.type[2];
      } else if (tag === 'call') {
        const callee = functions.get(v);
        const reusableTailFrame = tail && unwind === label + 'end' && !resumption;
        const call = lowerCall(e, callee, f, reusableTailFrame);
        if (call.kind === 'self-loop') {
          // Evaluate before rebinding: swaps and references to earlier arguments
          // must see the old iteration until every operand has completed.
          const moves = call.operands.map((expr, i) => ({
            source: emit(expr),
            destination: incoming[i],
          })).filter(({source, destination}) => source !== destination);
          // Destructured tuples have at most eight fields. Stage changed values
          // in caller-saved registers so overlapping moves preserve old bindings.
          moves.forEach(({source}, i) => load(source, 'x' + (8 + i)));
          moves.forEach(({destination}, i) => {
            code.push('str x' + (8 + i) + ', [sp, ' + ref(destination) + ']');
          });
          if (!loop) code.push(clearIterationRoots);
          code.push('b ' + label + 'loop');
          type = f.result_type;
        } else {
          if (!tail && !callee.noAllocation) mayCollect = true;
          if (call.kind === 'fields') {
            const fields = call.operands.map(node => emit(node));
            if (tail) code.push(unlinkRoots);
            fields.forEach((field,i) => load(field, 'x' + (8+i)));
            if (tail) {
              code.push('mov sp, x29', 'ldp x29, x30, [sp], #16', 'b ' + callee.label + 'fields');
            } else {
              code.push('bl ' + callee.label + 'fields', 'cbnz x1, ' + unwind);
            }
            if (tail) return {type: callee.f.result_type, returned: true};
            const result = fresh(callee.f.result_type);
            save(result);
            return result;
          }
          load(emit(call.operands[0]));
          if (tail) tailBranch(callee.label);
          else code.push('bl ' + callee.label, 'cbnz x1, ' + unwind);
          type = callee.f.result_type;
        }
      } else if (tag === 'prim' && v === 'sub' && remainderShift(e) !== undefined) {
        const shift = remainderShift(e);
        load(emit(e[3]));
        if (shift === 0) code.push('mov x0, #0');
        else {
          const mask = '#' + ((1n << BigInt(shift)) - 1n);
          code.push('cmp x0, #0', 'neg x2, x0', 'and x2, x2, ' + mask,
                    'and x0, x0, ' + mask, 'csneg x0, x0, x2, ge');
        }
        type = 'I64';
      } else if (tag === 'prim' && e[4]?.[0] === 'int' &&
                 ['add','sub','lt','le','gt','ge','eq'].includes(v) &&
                 BigInt(e[4][2]) >= 0n && BigInt(e[4][2]) <= 4095n) {
        load(emit(e[3]));
        const immediate = '#' + e[4][2];
        if (v === 'add' || v === 'sub') {
          code.push(v + 's x0, x0, ' + immediate, 'b.vs ' + failure(e[1], 1));
          type = 'I64';
        } else {
          code.push('cmp x0, ' + immediate, 'cset x0, ' + v);
          type = 'Bool';
        }
      } else if (tag === 'prim' && v === 'mul' &&
                 (powerOfTwoShift(e[3]) !== undefined || powerOfTwoShift(e[4]) !== undefined)) {
        const constant = powerOfTwoShift(e[3]) !== undefined ? 3 : 4;
        const shift = powerOfTwoShift(e[constant]);
        load(emit(e[constant === 3 ? 4 : 3]));
        if (shift) {
          // Sign-extending the shifted result must recover the original operand.
          code.push('lsl x2, x0, #' + shift, 'cmp x0, x2, asr #' + shift,
                    'b.ne ' + failure(e[1], 1), 'mov x0, x2');
        }
        type = 'I64';
      } else if (tag === 'prim' && v === 'div' && powerOfTwoShift(e[4]) !== undefined) {
        load(emit(e[3]));
        const shift = powerOfTwoShift(e[4]);
        if (shift) {
          // Bias negative operands before shifting to truncate toward zero.
          code.push('asr x2, x0, #63', 'add x0, x0, x2, lsr #' + (64 - shift),
                    'asr x0, x0, #' + shift);
        }
        type = 'I64';
      } else if (tag === 'prim') {
        const operands = e.slice(3).map(child => emit(child));
        load(operands[0]);
        if (operands.length === 2) load(operands[1], 'x2');
        type = 'I64';
        switch (v) {
          case 'bytes_length':
            code.push('ldr x0, [x0]');
            break;
          case 'bytes_index':
            // Image and host byte leaves carry their bytes after the fixed header.
            // Bounds-check unsigned to catch negative indices, then use the rope
            // walker only for a concatenated value.
            code.push('ldr x3, [x0]', 'cmp x2, x3', 'b.hs ' + failure(e[1], 4),
                      'ldr w3, [x0, #72]', 'cmn w3, #1', 'b.ne 1f',
                      'add x0, x0, #80', 'ldrb w0, [x0, x2]', 'b 2f', '1:',
                      'mov x1, x2', 'bl ' + prefix + 'fen_bytes_index', '2:');
            break;
          case 'bytes_concat':
            mayCollect = true;
            code.push('mov x1, x2', 'bl ' + prefix + 'fen_bytes_concat', 'cbz x0, ' + failure(e[1], 3));
            type = 'Bytes';
            break;
          case 'add': case 'sub':
            code.push(v + 's x0, x0, x2', 'b.vs ' + failure(e[1], 1));
            break;
          case 'neg':
            code.push('negs x0, x0', 'b.vs ' + failure(e[1], 1));
            break;
          case 'mul':
            code.push('smulh x3, x0, x2', 'mul x0, x0, x2', 'cmp x3, x0, asr #63',
                      'b.ne ' + failure(e[1], 1));
            break;
          case 'div':
            code.push('cbz x2, ' + failure(e[1], 2), 'cmn x2, #1',
                      'b.ne 1f', 'negs x3, x0', 'b.vs ' + failure(e[1], 1),
                      '1:', 'sdiv x0, x0, x2');
            break;
          case 'lt': case 'le': case 'gt': case 'ge': case 'eq':
            if (isPointer(operands[0].type)) {
              if (v !== 'eq') throw Error('Ordered comparison requires scalar operands');
              comparesObjects = true;
              code.push('mov x1, x2', 'bl ' + prefix + 'fen_equal');
            } else {
              code.push('cmp x0, x2', 'cset x0, ' + v);
            }
            type = 'Bool';
            break;
          case 'not':
            code.push('eor x0, x0, #1');
            type = 'Bool';
            break;
          default: throw Error('Unsupported managed primitive: ' + v);
        }
      } else throw Error('Unsupported managed expression: ' + tag + ' ' + v);
      // Tail-position branches join with their value in x0. No collecting
      // operation intervenes before the epilogue forwards that value.
      if (tail) return {type, returned: true};
      const result = fresh(type);
      save(result);
      return result;
    }
    if (unpacked) {
      for (const {id, type} of unpacked.parameters) {
        const slot = fresh(type);
        env.set(id, slot);
        incoming.push(slot);
      }
      const table = loop && byteScanTable(f, unpacked, functions);
      if (table) {
        // Only a flat leaf and an in-range starting index take the fast path.
        // Then advancing by one cannot overflow the signed byte length.
        const scan = label + 'scan';
        literals.push(scan + 'table:', '.byte ' + table.join(','));
        load(incoming[0], 'x2');
        load(incoming[1], 'x3');
        code.push('ldr w4, [x2, #72]', 'cmn w4, #1', 'b.ne ' + label + 'loop',
                  'ldr x4, [x2]', 'cmp x3, x4', 'b.hi ' + label + 'loop',
                  'add x2, x2, #80');
        address(code, scan + 'table');
        // Skip sixteen bytes together when every byte is in one contiguous
        // continue range. Mixed vectors fall through to the exact action table.
        let lo = 0, hi = -1, start = 0;
        for (let i = 0; i <= table.length; ++i) {
          if (table[i] === 2) continue;
          if (i - start > hi - lo + 1) { lo = start; hi = i - 1; }
          start = i + 1;
        }
        if (hi >= lo) {
          code.push('movi v1.16b, #' + lo, 'movi v2.16b, #' + hi, scan + ':',
                    'sub x6, x4, x3', 'cmp x6, #16', 'b.lo ' + scan + 'byte',
                    'ldr q0, [x2, x3]', 'cmhs v3.16b, v0.16b, v1.16b',
                    'cmhs v4.16b, v2.16b, v0.16b', 'and v3.16b, v3.16b, v4.16b',
                    'uminv b3, v3.16b', 'umov w5, v3.b[0]', 'cbz w5, ' + scan + 'byte',
                    'add x3, x3, #16', 'b ' + scan, scan + 'byte:');
        } else code.push(scan + ':');
        code.push('cmp x3, x4', 'b.eq ' + scan + 'bad',
                  'ldrb w5, [x2, x3]', 'ldrb w5, [x0, x5]', 'cbz w5, ' + scan + 'bad',
                  'cmp w5, #1', 'b.eq ' + scan + 'found', 'add x3, x3, #1', 'b ' + scan,
                  scan + 'bad:', 'mov x3, #-1', scan + 'found:', 'mov x0, x3',
                  'mov x1, #0', 'b ' + label + 'end');
      }
      if (loop && byteSumReduction(f, loop)) {
        incoming.forEach((slot, i) => load(slot, 'x' + i));
        code.push('bl ' + prefix + 'fen_try_byte_sum', 'cbz x1, ' + label + 'loop',
                  'mov x1, #0', 'b ' + label + 'end');
      }
      code.push(label + 'loop:');
    }
    load(emit((unpacked ?? loop)?.body ?? f.body, true));
    code.push('mov x1, #0', 'b ' + label + 'end');
    for (const [symbol, {id, status, destination}] of failurePaths) {
      const data = symbol + 'location';
      locationLiteral(data, id);
      code.push(symbol + ':');
      address(code, data);
      code.push('bl ' + prefix + 'fen_set_location', 'mov x1, #' + status, 'b ' + destination);
    }
    code.push(label + 'end:');
    if (handlerCount) code.push('stp x0, x1, [sp]', 'ldr x0, [sp, #40]',
      'bl ' + prefix + 'fen_restore_handler', 'ldp x0, x1, [sp]');
    code.push(unlinkRoots, 'mov sp, x29','ldp x29, x30, [sp], #16','ret');
    // Expression lowering materializes every result in a slot. A value
    // consumed immediately is still in x0. Keep stores visible to the GC
    // and stores whose slots can be read on another control-flow path.
    const reduced = [];
    const elidedSlots = new Set();
    const references = new Map();
    for (const instruction of code) {
      if (typeof instruction !== 'string') continue;
      for (const match of instruction.matchAll(/@(\d+)@/g)) {
        const id = Number(match[1]);
        references.set(id, (references.get(id) ?? 0) + 1);
      }
    }
    const inverseCondition = {eq: 'ne', lt: 'ge', le: 'gt', gt: 'le', ge: 'lt'};
    for (let i = 0; i < code.length; i++) {
      const instruction = code[i];
      // Branch on the comparison flags when the condition has no other consumer.
      const condition = typeof instruction === 'string' && /^cset x0, (eq|lt|le|gt|ge)$/.exec(instruction);
      if (condition) {
        const spill = /^str x0, \[sp, @(\d+)@\]$/.exec(code[i + 1]);
        const branch = typeof code[i + 3] === 'string' && /^cbz x0, (\w+)$/.exec(code[i + 3]);
        if (spill && branch && references.get(Number(spill[1])) === 2 &&
            code[i + 2] === 'ldr x0, [sp, @' + spill[1] + '@]') {
          elidedSlots.add(Number(spill[1]));
          reduced.push('b.' + inverseCondition[condition[1]] + ' ' + branch[1]);
          i += 3;
          continue;
        }
      }
      const store = typeof instruction === 'string' && /^str x0, \[sp, @(\d+)@\]$/.exec(instruction);
      if (store && code[i + 1] === 'ldr x0, [sp, @' + store[1] + '@]') {
        i++;
        const id = Number(store[1]);
        if (references.get(id) === 2 && !isPointer(slots[id].type)) {
          elidedSlots.add(id);
          continue;
        }
      }
      reduced.push(instruction);
    }
    // Alternative arms cannot execute together. Their result is in x0 at
    // the join, and incoming roots precede all arm-local slots.
    const roots = [];
    for (const slot of slots) {
      if (slot.rootIndex !== undefined) roots[slot.rootIndex] ??= slot;
    }
    // Keep frequently accessed scalar slots in preserved registers across calls
    // and loop backedges. Any use other than a plain load/store requires memory.
    const registers = new Map();
    const scalarAccess = /^(ldr|str) (x\d+), \[sp, @(\d+)@\]$/;
    if (unpacked && !captures.length && reduced.includes(clearIterationRoots)) {
      const counts = new Map();
      const needsAddress = new Set();
      for (const op of reduced) {
        if (typeof op !== 'string') continue;
        const access = scalarAccess.exec(op);
        if (access) {
          const id = Number(access[3]);
          if (!isPointer(slots[id].type)) counts.set(id, (counts.get(id) ?? 0) + 1);
        } else {
          for (const match of op.matchAll(/@(\d+)@/g)) needsAddress.add(Number(match[1]));
        }
      }
      const ranked = [...counts].filter(([id, count]) => count >= 3 && !needsAddress.has(id))
        .sort((a, b) => b[1] - a[1]).slice(0, 8);
      for (const [id] of ranked) registers.set(id, 'x' + (19 + registers.size));
    }
    const ordered = roots.concat(slots.filter(s => !isPointer(s.type) &&
      !elidedSlots.has(s.id) && !registers.has(s.id)));
    const frame = 48 + handlerCount * 32 + scopeCount * 64; // result/status at 0..15, root descriptor at 16..39
    const size = Math.ceil((frame + 8 * ordered.length)/16)*16;
    if (size > 4080) throw Error('Managed stack frame exceeds alpha limit');
    ordered.forEach((s,i) => { s.offset = frame + 8*i; });
    for (const slot of slots) {
      if (slot.rootIndex !== undefined) slot.offset = roots[slot.rootIndex].offset;
    }
    if (exports.has(f.name)) {
      const symbol = prefix + exports.get(f.name);
      if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(symbol)) throw Error('Invalid native export name');
      lines.push('.globl ' + symbol, symbol + ':');
    }
    if (f.name === program.entry) {
      const entry = prefix + (isTaskSchema(program.schema_version) ? 'fenrir_task_entry' : 'fenrir_entry');
      if (isTaskSchema(program.schema_version)) {
        const loc = prefix + 'fenrir_task_root_location';
        locationLiteral('LtaskRootLocation', f.body[1]);
        lines.push('.globl ' + loc, loc + ':');
        address(lines, 'LtaskRootLocation');
        lines.push('ret');
        const flag = prefix + 'fenrir_task_result_is_object';
        lines.push('.globl ' + flag, flag + ':', 'mov x0, #' + Number(isPointer(f.result_type)), 'ret');
      }
      lines.push('.globl ' + entry, entry + ':');
    }
    lines.push(label + ':');
    // Exported and indirect callers use the boxed ABI. Known direct callers
    // enter just below these loads with x8..x15 already populated.
    if (unpacked) {
      for (let i = 0; i < incoming.length; i += 2) {
        if (i + 1 < incoming.length) {
          lines.push('ldp x' + (8+i) + ', x' + (9+i) + ', [x0, #' + 8*i + ']');
        } else {
          lines.push('ldr x' + (8+i) + ', [x0, #' + 8*i + ']');
        }
      }
      lines.push(label + 'fields:');
      // x8..x11 must survive every fallback, including a partial sum that overflowed.
      if (loop && byteSumReduction(f, loop)) {
        const slow = label + 'sumSlow';
        const scan = label + 'sumScan';
        const done = label + 'sumDone';
        lines.push('cmp x9, x10', 'b.hi ' + slow, 'sub x2, x10, x9',
                   'cmp x2, #16', 'b.hi ' + slow, 'ldr x3, [x8]', 'cmp x10, x3',
                   'b.hi ' + slow, 'ldr w3, [x8, #72]', 'cmn w3, #1',
                   'add x4, x8, #80', 'b.eq ' + scan + 'Init', 'cmn w3, #3',
                   'b.ne ' + slow, 'add x4, x8, #8', scan + 'Init:',
                   'add x4, x4, x9', 'mov x0, x11', 'cbz x2, ' + done, scan + ':',
                   'ldrb w3, [x4], #1', 'adds x0, x0, x3', 'b.vs ' + slow,
                   'subs x2, x2, #1', 'b.ne ' + scan, done + ':', 'mov x1, #0',
                   'ret', slow + ':');
      }
      const op = bitSetOperation(functions.get(f.name), membershipFunctions);
      if (op) {
        const slow = label + 'arithmetic';
        lines.push('tbnz x8, #63, ' + slow, 'cmp x9, #0', 'b.le ' + slow,
                   'sub x2, x9, #1', 'tst x2, x9', 'b.ne ' + slow);
        if (op === 'membership') lines.push('tst x8, x9', 'cset x0, ne');
        else lines.push('orr x0, x8, x9');
        lines.push('mov x1, #0', 'ret', slow + ':');
      }
      // A match directly on an incoming field may immediately return another
      // incoming value. That path cannot allocate and needs no stack frame.
      const body = unpacked.body;
      if (mayCollect && body[0] === 'match' && body[2][0] === 'var') {
        const [name, binders, result] = body[3];
        const subject = unpacked.parameters.findIndex(p => p.id === body[2][2]);
        const answer = result[0] === 'var' && !binders.includes(result[2])
          ? unpacked.parameters.findIndex(p => p.id === result[2]) : -1;
        if (subject >= 0 && answer >= 0) {
          const tag = nativeVariants(unpacked.parameters[subject].type, constructors).get(name).tag;
          if (tag <= 4095) {
            lines.push('ldr w2, [x' + (8 + subject) + ', #72]', 'cmp w2, #' + tag,
                       'b.ne ' + label + 'frame', 'mov x0, x' + (8 + answer),
                       'mov x1, #0', 'ret', label + 'frame:');
          }
        }
      }
    }
    lines.push('stp x29, x30, [sp, #-16]!','mov x29, sp');
    const restoreRegisters = [];
    for (let i = 0; i < registers.size; i += 2) {
      const pair = 'x' + (19+i) + ', ' + (i+1 < registers.size ? 'x' + (20+i) : 'xzr');
      lines.push('stp ' + pair + ', [sp, #-16]!');
      restoreRegisters.push('ldp ' + pair + ', [x29, #-' + (16 + 8*i) + ']');
    }
    lines.push('sub sp, sp, #' + size);
    const needsFrame = mayCollect && roots.length > 0;
    function zeroTemporaryRoots() {
      // Arguments and captures are populated before the frame is registered.
      const initialized = new Set([...capturedSlots, ...(unpacked ? incoming : [argument])]);
      const empty = roots.filter(slot => !initialized.has(slot));
      for (let i = 0; i < empty.length; i++) {
        const offset = empty[i].offset;
        if (offset <= 504 && empty[i + 1]?.offset === offset + 8) {
          lines.push('stp xzr, xzr, [sp, #' + offset + ']');
          i++;
        } else {
          lines.push('str xzr, [sp, #' + offset + ']');
        }
      }
    }
    if (needsFrame) zeroTemporaryRoots();
    capturedSlots.forEach((s,i) => lines.push('ldr x2, [x1, #' + (8*(i+1)) + ']',
                                             'str x2, [sp, #' + s.offset + ']'));
    if (unpacked) {
      for (let i = 0; i < incoming.length; i++) {
        const register = registers.get(incoming[i].id);
        if (register) {
          lines.push('mov ' + register + ', x' + (8+i));
          continue;
        }
        const offset = incoming[i].offset;
        if (offset <= 504 && incoming[i + 1]?.offset === offset + 8) {
          lines.push('stp x' + (8+i) + ', x' + (9+i) + ', [sp, #' + offset + ']');
          i++;
        } else {
          lines.push('str x' + (8+i) + ', [sp, #' + offset + ']');
        }
      }
    } else lines.push('str x0, [sp, #' + argument.offset + ']');
    if (handlerCount) lines.push('bl ' + prefix + 'fen_current_handler', 'str x0, [sp, #40]');
    if (needsFrame) lines.push('add x0, sp, #16', 'add x1, sp, #' + frame,
                               'mov x2, #' + roots.length,'bl ' + prefix + 'fen_enter');
    for (const instruction of reduced) {
      if (instruction === 'mov sp, x29') lines.push(...restoreRegisters);
      const access = registers.size && typeof instruction === 'string' && scalarAccess.exec(instruction);
      const register = access && registers.get(Number(access[3]));
      if (register) {
        const [to, from] = access[1] === 'ldr' ? [access[2], register] : [register, access[2]];
        lines.push('mov ' + to + ', ' + from);
      } else if (instruction === allocateConstructor) {
        constructorCalls.push(lines.length);
        lines.push('bl ' + prefix + 'fen_allocate');
      } else if (instruction === clearIterationRoots) {
        if (needsFrame) zeroTemporaryRoots();
      } else if (instruction === unlinkRoots) {
        if (needsFrame) lines.push('bl ' + prefix + 'fen_leave_result');
      } else lines.push(instruction.replace(/SCOPE(\d+)OFFSET/g, (_,i) => 48 + 32*handlerCount + 64*i).replace(/HANDLER(\d+)OFFSET/g, (_,i) => 48 + 32*i).replace(/@(\d+)@/g, (_,i) => '#' + slots[i].offset));
    }
  }
  // The collector visits only mask-selected words. All declared fields are
  // initialized before the next call. Generic equality also reads padding,
  // and external callers can inspect objects that cross the entry boundary.
  if (!comparesObjects && !exports.size && !Object.keys(host).length &&
      !program.effects.length && !isTaskSchema(program.schema_version) &&
      entry.argument_type === 'I64' && entry.result_type === 'I64') {
    for (const index of constructorCalls) lines[index] = 'bl ' + prefix + 'fen_allocate_full';
  }
  return lines.join('\n') + '\n' + resultPrinter(entry.result_type, constructors, prefix, events) + literals.join('\n') + '\n';
}
