"""Hash-bound opt-in DEVELOPMENT bindings adaptation; no tender/startup changes."""
import difflib
import hashlib

ORIGINALS = {
    'bindings.c': '8580ae59e31b1e7706df7e7f7627d12506613bd01a0fdab6d297ea35e8fed53b',
    'net.c': '86c5c07f79c17bbba6ef58eaf347fcfbce7ade3f50c3fefa4fe17a8cc90a333e',
}


def apply(name, source):
    if name not in ORIGINALS or hashlib.sha256(source).hexdigest() != ORIGINALS[name]:
        raise ValueError('Pristine pinned bindings source required')
    original = source.decode('ascii')
    if name == 'bindings.c':
        start = original.index('solo5_time_t solo5_clock_monotonic(void)')
        end = original.index('/* solo5_set_tls_base is in tls.c */', start)
        replacement = '''/* Explicit cooperative environment profile only. State has no host inputs. */
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

'''
        patched = original[:start] + replacement + original[end:]
    else:
        start = original.index('void solo5_yield(solo5_time_t deadline, solo5_handle_set_t *ready_set)')
        # The pinned function is the last definition. Digest guards this boundary.
        patched = original[:start] + '''#include "virtual-env.h"

void solo5_yield(solo5_time_t deadline, solo5_handle_set_t *ready_set)
{
    /* No devices or future waits in this synthetic profile. No host timer use. */
    assert(npollfds == 0);
    assert(solo5_fenrir_env_ready(deadline));
    if (ready_set != NULL)
        *ready_set = 0;
}
'''
    patch = ''.join(difflib.unified_diff(original.splitlines(True), patched.splitlines(True),
                                       fromfile='stock/'+name, tofile='environment/'+name))
    return patched.encode('ascii'), patch
