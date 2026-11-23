#!/bin/sh
# Run on Linux ARM64 with the Solo5 toolchain on PATH.
set -eu
[ "$#" -eq 2 ] || [ "$#" -eq 3 ] || { echo 'usage: link-spt.sh PROGRAM OUTPUT [RUNTIME_CONFIG_HEADER]' >&2; exit 2; }
assembly=$1
output=$2
if [ "$#" = 3 ]; then set -- -include "$3"; else set --; fi
root=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo '{"type":"solo5.manifest","version":1,"devices":[]}' > "$work/manifest.json"
solo5-elftool gen-manifest "$work/manifest.json" "$work/manifest.c"
cc=aarch64-solo5-none-static-cc
runtime=${FENRIR_NATIVE_RUNTIME:-$root/../../runtime/native}
"$cc" -O2 -I"$runtime" -c "$assembly" -o "$work/program.o"
"$cc" -O2 -c "${FENRIR_SOLO5_MAIN:-$root/solo5-main.c}" -o "$work/main.o"
"$cc" -c "$work/manifest.c" -o "$work/manifest.o"
"$cc" -O2 -c "$runtime/heap.c" -o "$work/heap.o"
"$cc" "$@" -O2 -c "$runtime/managed.c" -o "$work/managed.o"
if grep -q '^fenrir_task_entry:$' "$assembly"; then
    for unit in task-entry.c scheduler.c context.S; do
        "$cc" "$@" -O2 -c "$runtime/$unit" -o "$work/$unit.o"
    done
    set -- "$work/task-entry.c.o" "$work/scheduler.c.o" "$work/context.S.o"
else
    set --
fi
aarch64-solo5-none-static-ld "$@" -z solo5-abi=spt "$work/manifest.o" "$work/main.o" "$work/program.o" "$work/heap.o" "$work/managed.o" -o "$output"
