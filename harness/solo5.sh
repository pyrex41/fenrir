# Sourced after jit.sh. Honor an explicit toolchain; otherwise prefer the
# built checkout, then the native Linux flake package (including aarch64).
# The Node builder validates the pin and resolves installed vs. checkout paths.
if [ -z "${FENRIR_SOLO5:-}" ]; then
  if [ -x "$root/build/vendor/solo5/tenders/spt/solo5-spt" ]; then
    FENRIR_SOLO5="$root/build/vendor/solo5"
  elif [ "$(uname -s)" = Linux ] && command -v nix >/dev/null 2>&1; then
    FENRIR_SOLO5=$(cd "$root" && nix build --no-link --print-out-paths .#solo5) || FENRIR_SOLO5=
  fi
fi
export FENRIR_SOLO5
