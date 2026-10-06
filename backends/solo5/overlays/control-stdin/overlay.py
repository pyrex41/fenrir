"""Project-owned exact-source overlay, ISC license as retained in upstream source.
Development only: pipe-only opt-in stdin read, no other policy or time changes.
"""
import hashlib
import difflib
ORIGINAL_SHA256 = 'fcd27a4cdc23278473138711a21cd30717f69f05f8bbe88fceff6ee255b39d10'


def apply(original):
    if hashlib.sha256(original).hexdigest() != ORIGINAL_SHA256:
        raise ValueError('Overlay requires exact pristine Solo5 v0.9.3 core source')
    source = original.decode()
    changes = [
        ('#include <err.h>','#include <err.h>\n#include <fcntl.h>'),
        ('static bool use_exec_heap = false;',
         'static bool use_exec_heap = false;\nstatic bool fenrir_control_stdin = false;'),
        ('    if (!strncmp("--x-exec-heap", cmdarg, 13)) {',
         '    if (!strcmp("--fenrir-control-stdin", cmdarg)) {\n'
         '        fenrir_control_stdin = true;\n'
         '        return 0;\n'
         '    }\n'
         '    if (!strncmp("--x-exec-heap", cmdarg, 13)) {'),
        ('    int rc = -1;\n\n    rc = seccomp_rule_add(spt->sc_ctx, SCMP_ACT_ALLOW, SCMP_SYS(write), 1,',
         '    int rc = -1;\n\n'
         '    /* Fenrir DEVELOPMENT transport: only an explicitly wired pipe. */\n'
         '    if (fenrir_control_stdin) {\n'
         '        struct stat input;\n'
         '        int flags = fcntl(STDIN_FILENO, F_GETFL);\n'
         '        if (fstat(STDIN_FILENO, &input) != 0 || !S_ISFIFO(input.st_mode) ||\n'
         '                flags < 0 || (flags & O_ACCMODE) == O_WRONLY)\n'
         '            errx(1, "Fenrir stdin requires an explicit readable pipe");\n'
         '        rc = seccomp_rule_add(spt->sc_ctx, SCMP_ACT_ALLOW, SCMP_SYS(read), 2,\n'
         '                SCMP_A0(SCMP_CMP_EQ, STDIN_FILENO),\n'
         '                SCMP_A2(SCMP_CMP_LE, 65536));\n'
         '        if (rc != 0)\n'
         '            errx(1, "Fenrir read(fd=0,count<=65536) rule failed: %s",\n'
         '                    strerror(-rc));\n'
         '    }\n\n'
         '    rc = seccomp_rule_add(spt->sc_ctx, SCMP_ACT_ALLOW, SCMP_SYS(write), 1,'),
        ('    return "--x-exec-heap (make the heap executable)."',
         '    return "--fenrir-control-stdin (Fenrir development pipe input only).\\n"\n'
         '           "--x-exec-heap (make the heap executable)."')]
    for old,new in changes:
        if source.count(old) != 1:
            raise ValueError('Overlay context is not unique')
        source = source.replace(old,new)
    patched = source.encode()
    patch = ''.join(difflib.unified_diff(original.decode().splitlines(True),source.splitlines(True),
                                      fromfile='a/tenders/spt/spt_core.c',tofile='b/tenders/spt/spt_core.c'))
    return patched, patch
