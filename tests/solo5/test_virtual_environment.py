"""Pure state/overlay development tests; not isolated candidate qualification."""
import base64
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('environment_overlay', ROOT / 'backends/solo5/overlays/virtual-environment/overlay.py')
overlay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(overlay)

HARNESS = r'''
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include "virtual-env.h"
int main(int argc, char **argv) {
    uint64_t m=71,w=72;
    assert(argc==2);
    assert(!solo5_fenrir_env_read(&m,&w));
    assert(m==71 && w==72);
    assert(!solo5_fenrir_env_ready(0));
    assert(!solo5_fenrir_env_advance(0));
    assert(!solo5_fenrir_env_init(UINT64_MAX));
    if (!strcmp(argv[1],"edge")) {
        assert(solo5_fenrir_env_init(UINT64_C(9223372036854775807)));
        assert(!solo5_fenrir_env_advance(1));
        assert(solo5_fenrir_env_read(&m,&w));
        assert(m==0 && w==UINT64_C(9223372036854775807));
        return 0;
    }
    assert(solo5_fenrir_env_init(1000));
    assert(!solo5_fenrir_env_init(2000));
    assert(!solo5_fenrir_env_read(0,&w));
    assert(!solo5_fenrir_env_read(&m,0));
    assert(!solo5_fenrir_env_read(&m,&m));
    assert(solo5_fenrir_env_read(&m,&w)); assert(m==0 && w==1000);
    assert(solo5_fenrir_env_ready(0)); assert(!solo5_fenrir_env_ready(1));
    assert(solo5_fenrir_env_advance(0));
    assert(solo5_fenrir_env_read(&m,&w)); assert(m==0 && w==1000);
    assert(solo5_fenrir_env_advance(10));
    assert(solo5_fenrir_env_read(&m,&w)); assert(m==10 && w==1010);
    assert(!solo5_fenrir_env_advance(9));
    assert(!solo5_fenrir_env_advance(UINT64_MAX));
    assert(!solo5_fenrir_env_advance(UINT64_C(9223372036854775807)));
    assert(solo5_fenrir_env_advance(10));
    assert(solo5_fenrir_env_read(&m,&w)); assert(m==10 && w==1010);
    assert(solo5_fenrir_env_ready(0)); assert(solo5_fenrir_env_ready(10));
    assert(!solo5_fenrir_env_ready(11));
    assert(solo5_fenrir_env_advance(UINT64_C(9223372036854774807)));
    assert(solo5_fenrir_env_read(&m,&w));
    assert(w==UINT64_C(9223372036854775807));
    return 0;
}
'''


class EnvironmentStateTests(unittest.TestCase):
    def run_state(self, mode):
        # Explicit isolated Linux toolchain, not /usr/bin/cc (local Xcode license
        # is unavailable). No pull/install, privileges, network or host mutation.
        spec = importlib.util.spec_from_file_location('env_unit_build', ROOT/'tools/solo5/build-control-stdin.py')
        build = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(build)
        image = build.json.loads(build.client.checked(['docker', 'image', 'inspect', build.client.IMAGE]))[0]
        if image['Config']['Labels'].get('org.fenrir.solo5.commit') != build.client.COMMIT:
            raise RuntimeError('Pinned toolchain image prerequisite differs')
        parent = ROOT / 'build/solo5'
        parent.mkdir(parents=True, exist_ok=True)
        box = build.Sandbox(image['Id'])
        with tempfile.TemporaryDirectory(prefix='env-state-unit-', dir=parent) as tmp:
            dest = Path(tmp)
            (dest/'test.c').write_text(HARNESS)
            mounts = [(dest/'test.c', '/inputs/test.c'),
                      (ROOT/'backends/solo5/virtual-env.c', '/inputs/virtual-env.c'),
                      (ROOT/'backends/solo5/virtual-env.h', '/inputs/virtual-env.h')]
            try:
                p = box.run('state-build-'+mode, ['sh', '-c',
                    'set -eu; cd /work; export TMPDIR=/work; cc -std=c99 -Wall -Wextra -Werror -I/inputs '
                    '/inputs/test.c /inputs/virtual-env.c -o /work/state-test; '
                    'base64 /work/state-test'], mounts, True)
                self.assertEqual((p.returncode, p.stderr), (0, ''))
                self.assertLess(len(p.stdout), 1048576)
                binary = dest/'state-test'
                binary.write_bytes(base64.b64decode(p.stdout.replace('\n', ''), validate=True))
                binary.chmod(0o555)
                # Build tmpfs is intentionally noexec. Transfer artifact and run
                # via a read-only bind in a fresh container, as guest builds do;
                # do not loosen tmpfs policy or bypass it with a dynamic loader.
                p = box.run('state-run-'+mode, ['/unit/state-test', mode],
                            [(binary, '/unit/state-test')])
                self.assertEqual((p.returncode, p.stdout, p.stderr), (0, '', ''))
            finally:
                box.verify_cleanup()

    def test_hand_state_and_rejections(self):
        self.run_state('hand')

    def test_wall_range_edge(self):
        self.run_state('edge')


class EnvironmentOverlayTests(unittest.TestCase):
    def test_unknown_and_wrong_sources_fail_closed(self):
        for name in ['bindings.c', 'net.c', 'crt_init.h', 'spt_core.c']:
            with self.assertRaises(ValueError):
                overlay.apply(name, b'not the pinned source')

    def test_pinned_adaptation_excludes_host_clock_and_timer_calls(self):
        vendor = ROOT / 'build/vendor/solo5/bindings/spt'
        if not vendor.is_dir():
            self.skipTest('Pinned vendor unavailable; live overlay build remains unverified')
        for name in ['bindings.c', 'net.c']:
            original = (vendor/name).read_bytes()
            self.assertEqual(hashlib.sha256(original).hexdigest(), overlay.ORIGINALS[name])
            patched, patch = overlay.apply(name, original)
            self.assertTrue(patch)
            for syscall in [b'sys_clock_gettime(', b'sys_timerfd_settime(', b'sys_epoll_pwait(']:
                self.assertNotIn(syscall, patched)
            self.assertIn(b'solo5_fenrir_env_', patched)
            self.assertNotIn(b'crt_init_ssp', patched)
            self.assertEqual(original, (vendor/name).read_bytes())
            with self.assertRaises(ValueError):
                overlay.apply(name, patched)


if __name__ == '__main__':
    unittest.main()
