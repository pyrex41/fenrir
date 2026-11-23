#!/bin/sh
# Run from a writable directory outside the checkout with a fresh output path.
set -eu
[ "$#" = 2 ] || { echo "usage: check-release.sh PACKAGE NEW_DIRECTORY" >&2; exit 2; }
package=$(cd "$1" && pwd -P)
mkdir "$2"
out=$(cd "$2" && pwd -P)
src=$package/libexec/fenrir
tc=$package/bin/fenrir-toolchain
cli=$package/bin/fenrir
unset FENRIR_NATIVE_BACKEND
"$tc" sh "$src/tests/native/check-package.sh" "$cli" "$out/cli" > "$out/cli.log" 2>&1
FENRIR_TEST_WITHOUT_JS_EMITTER=1 "$tc" sh "$src/tests/native/check-package-apps.sh" "$package" "$out/apps" > "$out/apps.log" 2>&1
"$tc" python3 "$src/tests/native/check-handler-roundtrips.py" --all "$out/roundtrips" --cli "$cli" > "$out/roundtrips.log" 2>&1
"$tc" python3 "$src/tests/native/check-dispatch-replay.py" "$out/dispatch" > "$out/dispatch.log" 2>&1
for target in macos-arm64 solo5-arm64-spt; do
    set --
    for f in "$src"/tests/native/*.fen; do
        if grep -Fq '\\ > outcome:' "$f"; then set -- "$@" "$f"; fi
    done
    [ "$#" -gt 0 ]
    "$cli" test --target "$target" "$@" > "$out/$target.log" 2>&1
    FENRIR_NATIVE_BACKEND=javascript "$cli" run --target "$target" "$src/examples/recursive-sum.fen" 10 > "$out/$target-comparison.txt"
    grep -Fxq 55 "$out/$target-comparison.txt"
done
echo "Passed $package"
