# Sourced by the runner scripts after jit.sh: sets and exports $FENRIR_SOLO5, the built
# Solo5 (tenders/spt/solo5-spt, toolchain/bin, elftool/). FENRIR_SOLO5 overrides; otherwise
# the hand-built checkout at build/vendor/solo5; otherwise the flake's pinned solo5 output
# when nix can provide it. Left empty when none is available (tools/solo5/freerun.mjs
# repeats this lookup and reports BLOCKED-style errors itself).
if [ -z "${FENRIR_SOLO5:-}" ]; then
  if [ -x "$root/build/vendor/solo5/tenders/spt/solo5-spt" ]; then
    FENRIR_SOLO5="$root/build/vendor/solo5"
  elif command -v nix >/dev/null 2>&1; then
    FENRIR_SOLO5=$(cd "$root" && nix build --no-link --print-out-paths .#solo5 2>/dev/null) || FENRIR_SOLO5=
  fi
fi
export FENRIR_SOLO5
