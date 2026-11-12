// Hash-bound opt-in DEVELOPMENT bindings adaptation; no tender/startup changes.
import {createHash} from 'node:crypto';
import {unifiedDiff} from '../unified-diff.mjs';

export const ORIGINALS={
  'bindings.c':'8580ae59e31b1e7706df7e7f7627d12506613bd01a0fdab6d297ea35e8fed53b',
  'net.c':'86c5c07f79c17bbba6ef58eaf347fcfbce7ade3f50c3fefa4fe17a8cc90a333e',
};

const index=(text,needle,from=0)=>{
  const at=text.indexOf(needle,from);
  if(at<0)throw new Error('Overlay anchor missing');
  return at;
};

// name: 'bindings.c' or 'net.c'; source: Buffer. Returns [patched Buffer, patch text].
export function apply(name,source) {
  if(!Object.hasOwn(ORIGINALS,name)||createHash('sha256').update(source).digest('hex')!==ORIGINALS[name])
    throw new Error('Pristine pinned bindings source required');
  if(source.some(byte=>byte>127))throw new Error('Pinned bindings source is not ASCII');
  const original=source.toString('latin1');
  let patched;
  if(name==='bindings.c') {
    const start=index(original,'solo5_time_t solo5_clock_monotonic(void)');
    const end=index(original,'/* solo5_set_tls_base is in tls.c */',start);
    const replacement=`/* Explicit cooperative environment profile only. State has no host inputs. */
#include "virtual-env.c"

solo5_time_t solo5_clock_monotonic(void)
{
    uint64_t monotonic, wall;
    assert(solo5_fenrir_env_read(&monotonic, &wall));
    return monotonic;
}

solo5_time_t solo5_clock_wall(void)
{
    uint64_t monotonic, wall;
    assert(solo5_fenrir_env_read(&monotonic, &wall));
    return wall;
}

`;
    patched=original.slice(0,start)+replacement+original.slice(end);
  } else {
    const start=index(original,'void solo5_yield(solo5_time_t deadline, solo5_handle_set_t *ready_set)');
    // The pinned function is the last definition. Digest guards this boundary.
    patched=original.slice(0,start)+`#include "virtual-env.h"

void solo5_yield(solo5_time_t deadline, solo5_handle_set_t *ready_set)
{
    /* No devices or future waits in this synthetic profile. No host timer use. */
    assert(npollfds == 0);
    assert(solo5_fenrir_env_ready(deadline));
    if (ready_set != NULL)
        *ready_set = 0;
}
`;
  }
  const patch=unifiedDiff(original,patched,'stock/'+name,'environment/'+name);
  return [Buffer.from(patched,'latin1'),patch];
}
