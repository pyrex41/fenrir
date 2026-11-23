import {TC1_DURABLE_SCHEMA, TC1_REMOTE_SCHEMA, TC1_SERVING_SCHEMA} from '../tc0/pure-call-artifact.mjs';
import {nativeProfile} from '../tc1/native-profile.mjs';

export class NativeProfileError extends Error {
  constructor(position, reason) {
    const site = position ? `${position.file}:${position.line}:${position.column}: ` : '';
    super(`${site}${nativeProfile.id}: ${reason}`);
  }
}

// Only numeric resource limits from the stamped descriptor enter the C build.
export function runtimeConfigHeader(limits) {
  const definitions = {
    FEN_CHILD_SLOTS: limits.max_live_nonroot_children,
    FEN_HANDLER_SLOTS: limits.max_inherited_handlers,
    FEN_HEAP_SLOTS: limits.managed_heap_slots,
    FEN_TASK_STACK_BYTES: limits.task_stack_bytes,
  };
  const lines = [];
  for (const [macro, value] of Object.entries(definitions)) {
    if (!Number.isSafeInteger(value) || value < 1 || value > 0x7fffffff)
      throw new NativeProfileError(null, `Invalid positive C integer for ${macro}`);
    lines.push(`#define ${macro} ${value}`);
  }
  if (limits.task_stack_bytes % 16)
    throw new NativeProfileError(null, 'Task stack size must be a multiple of 16 bytes');
  return lines.join('\n') + '\n';
}

function findPerform(node, names) {
  if (!Array.isArray(node)) return;
  if (node[0] === 'perform' && names.has(node[2])) return node;
  for (const child of node) {
    const found = findPerform(child, names);
    if (found) return found;
  }
}

// The frontend has already validated the artifact. A declaration alone does
// not require an adapter: a durable operation can be handled locally, and an
// unused remote declaration is legal in an otherwise standalone program.
export function requireStandaloneProfile(program) {
  const schema = program.schema_version;
  const entry = program.functions.find(f => f.name === program.entry);
  const position = id => program.source_map.find(row => row.id === id);
  const rejectAdapter = (id, reason) => {
    const adapter = nativeProfile.adapter_schemas[schema];
    throw new NativeProfileError(position(id), `${reason} requires ${adapter.description}. Run the example with ${adapter.runner}`);
  };
  if (schema === TC1_SERVING_SCHEMA)
    rejectAdapter(program.functions[0].id, 'Serving a remote effect');
  if (!nativeProfile.artifact_schemas.includes(schema))
    throw new NativeProfileError(position(entry?.id), `Unsupported artifact schema ${schema}`);
  if (schema === TC1_REMOTE_SCHEMA) {
    const names = new Set(program.effects.filter(d => d.class === 'remote').map(d => d.name));
    for (const f of program.functions) {
      const use = findPerform(f.body, names);
      if (use) rejectAdapter(use[1], `Remote operation ${use[2]}.${use[3]}`);
    }
  }
  if (schema === TC1_DURABLE_SCHEMA) {
    const names = program.effects.filter(d => d.class === 'durable').map(d => d.name);
    if (entry.argument_type !== nativeProfile.entry.argument || entry.effects.some(name => names.includes(name)))
      rejectAdapter(entry.id, 'The durable entry');
  }
}
