import {taskResults} from '../tc0/pure-call-artifact.mjs';

export function nativeVariants(type, constructors) {
  const builtin = taskResults(type);
  return builtin ? new Map(builtin.map(({name, fields}, tag) => [name, {tag, fields}]))
                 : constructors.get(type === 'TrapCode' ? type : type[1]);
}

// Emit a typed printer once per reachable result type. Recursive datatypes
// reuse their label. The host writer does not allocate in the managed heap.
export function resultPrinter(result, constructors, prefix, events = []) {
  const types = new Map(), strings = new Map(), lines = [];
  function label(type) {
    const key = JSON.stringify(type);
    if (!types.has(key)) types.set(key, {type, name: 'Lprint' + types.size});
    return types.get(key).name;
  }
  function text(value) {
    if (!strings.has(value)) strings.set(value, 'Lstr' + strings.size);
    const name = strings.get(value);
    lines.push(...(prefix ? ['adrp x0, ' + name + '@PAGE', 'add x0, x0, ' + name + '@PAGEOFF'] :
      ['adrp x0, ' + name, 'add x0, x0, :lo12:' + name]), 'mov x1, #' + Buffer.byteLength(value),
      'bl ' + prefix + 'fen_write');
  }
  function fields(name, members) {
    text(members.length ? '(' + name : name);
    members.forEach((member, i) => {
      text(' ');
      lines.push('ldr x0, [x19, #' + (8*i) + ']', 'bl ' + label(member));
    });
    if (members.length) text(')');
  }
  lines.push('.text', '.globl ' + prefix + 'fen_print_result', prefix + 'fen_print_result:',
    'b ' + (result === 'Bool' ? prefix + 'fen_write_i64' : label(result)));
  for (const event of events) {
    lines.push(event.symbol + ':', 'stp x19, x30, [sp, #-16]!', 'mov x19, x0');
    text('emit ' + JSON.stringify(event.name) + ': ');
    lines.push('mov x0, x19', 'bl ' + label(event.type));
    if (event.task) {
      text(' (task ');
      lines.push('bl ' + prefix + 'fen_print_task_id');
      text(')');
    }
    text('\n');
    lines.push('ldp x19, x30, [sp], #16', 'ret');
  }
  for (const {type, name} of types.values()) {
    lines.push(name + ':');
    if (type === 'Bytes') {
      lines.push('b ' + prefix + 'fen_print_bytes');
      continue;
    }
    if (type === 'I64') {
      lines.push('b ' + prefix + 'fen_write_i64');
      continue;
    }
    lines.push('stp x19, x30, [sp, #-16]!', 'mov x19, x0');
    if (type === 'Unit') {
      text('unit');
    } else if (type === 'Bool') {
      lines.push('cbz x0, ' + name + 'false');
      text('true');
      lines.push('b ' + name + 'done', name + 'false:');
      text('false');
    } else if (type[0] === 'Tuple') {
      fields('tuple', type.slice(1));
    } else if (type === 'TrapCode' || type[0] === 'Data' || taskResults(type)) {
      const variants = nativeVariants(type, constructors);
      lines.push('bl ' + prefix + 'fen_tag');
      for (const ctor of variants.values())
        lines.push('mov x1, #' + ctor.tag, 'cmp x0, x1', 'b.eq ' + name + 'v' + ctor.tag);
      lines.push('brk #0');
      for (const [ctorName, ctor] of variants) {
        lines.push(name + 'v' + ctor.tag + ':');
        fields(ctorName, ctor.fields);
        lines.push('b ' + name + 'done');
      }
    } else throw Error('Unsupported native result type: ' + JSON.stringify(type));
    lines.push(name + 'done:', 'ldp x19, x30, [sp], #16', 'ret');
  }
  for (const [value, name] of strings)
    lines.push(name + ':', '.byte ' + Array.from(Buffer.from(value)).join(','));
  return lines.join('\n') + '\n';
}
