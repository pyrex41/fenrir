#!/bin/sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$1
cp "$here/reference.shen" "$out.shen"
cat > "$out" <<'SCRIPT'
#!/bin/sh
set -eu
jit=${FENRIR_SHEN_JIT:?set FENRIR_SHEN_JIT to the pinned installation}
chunk=${1:-8192}
case "$chunk" in ''|*[!0-9]*) exit 2 ;; esac
exec "$jit/bin/shen-jit" eval -q -m "$jit/lib/ffi.shenmod" -s fl.chunk "$chunk" -l "$0.shen"
SCRIPT
chmod +x "$out"
