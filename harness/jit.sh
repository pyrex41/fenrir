# Sourced by the runner scripts: sets $root and $jit.
# $jit is the Shen/JIT install directory (bin/shen-jit, lib/). FENRIR_SHEN_JIT
# overrides; otherwise the flake's pinned shen-jit output when nix can provide it;
# otherwise a hand-built copy under build/toolchain/shen-jit-0.7. Only the flake
# output satisfies the gate's toolchain row.
root=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${FENRIR_SHEN_JIT:-}" ] && command -v nix >/dev/null 2>&1; then
  FENRIR_SHEN_JIT=$(cd "$root" && nix build --no-link --print-out-paths .#shen-jit 2>/dev/null) || FENRIR_SHEN_JIT=
fi
jit="${FENRIR_SHEN_JIT:-$root/build/toolchain/shen-jit-0.7}"
