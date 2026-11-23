#!/bin/sh
# Run an installed Fenrir CLI outside its checkout, retaining the observations.
set -eu
[ "$#" = 2 ] || { echo 'usage: check-package.sh ABSOLUTE_CLI NEW_DIRECTORY' >&2; exit 2; }
cli=$1
case "$cli" in /*) ;; *) exit 2 ;; esac
profile_test=$(cd "$(dirname "$0")" && pwd)/check-execution-profile.py
mkdir "$2"
cd "$2"
unset FENRIR_SHEN_JIT
python3 "$profile_test" "$cli"
"$cli" profile > execution-profile.json
export FENRIR_TEST_CLI="$cli"
cat > program.fen <<'FEN'
(library "arithmetic.fen")
(define main {I64 --> I64} n -> (- (twice n) 1))
FEN
cat > arithmetic.fen <<'FEN'
(define add-one {I64 --> I64} n -> (+ n 1))
(define twice {I64 --> I64} n -> (+ (add-one n) 1))
FEN
cat > task.fen <<'FEN'
(library "arithmetic.fen")
(define main {I64 --> I64} n -> (do yield (emit "resumed" n) (add-one n)))
FEN
cat > concurrent.fen <<'FEN'
\\ > emit "worker": 1 (task 1)
\\ > outcome: Ok 1
(library "arithmetic.fen")
(define main {I64 --> I64}
  input -> (let events (channel I64 1)
                worker (spawn (lambda (_ : Unit)
                                (let result (add-one input)
                                  (do (emit "worker" result) (send events result) result))))
             (match (receive events)
               ((Item result) -> (do (await worker) result))
               (End -> 0))))
FEN
"$cli" check program.fen
cp arithmetic.fen arithmetic.original
for target in macos-arm64 solo5-arm64-spt; do
    if "$cli" build --target "$target" program.fen -o arithmetic.fen > collision.log 2>&1; then
        echo 'build replaced an imported source file' >&2
        exit 1
    fi
    grep -q 'would overwrite source' collision.log
    cmp arithmetic.original arithmetic.fen
done
for target in macos-arm64 solo5-arm64-spt; do
    "$cli" test --target "$target" concurrent.fen
    "$cli" build --target "$target" concurrent.fen -o "$target-concurrent"
    "$cli" record-schedule "$target" "./$target-concurrent" 41 "$target-concurrent.json"
    "$cli" replay "./$target-concurrent" "$target-concurrent.json"
    "$cli" build --target "$target" program.fen -o "$target"
    "$cli" record "$target" "./$target" 41 "$target-normal.json"
    "$cli" record "$target" "./$target" 9223372036854775807 "$target-trap.json"
    "$cli" record "$target" "./$target" 9223372036854775806 "$target-outer-trap.json"
    "$cli" replay "./$target" "$target-trap.json"
    "$cli" replay "./$target" "$target-outer-trap.json"
    "$cli" build --target "$target" task.fen -o "$target-task"
    "$cli" record "$target" "./$target-task" 9223372036854775807 "$target-task-trap.json"
    "$cli" replay "./$target-task" "$target-task-trap.json"
done
python3 - <<'PY'
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess

for malformed in ("+1", " 1", " -1", "- 1", "1 ", "1x"):
    result = subprocess.run(["./macos-arm64", malformed], capture_output=True)
    if result.returncode != 2 or result.stdout:
        raise ValueError(f"Darwin image accepted malformed input {malformed!r}")

profile = Path("execution-profile.json").read_bytes()
expected_profile = {"id": json.loads(profile)["id"], "sha256": hashlib.sha256(profile).hexdigest()}
for target in ("macos-arm64", "solo5-arm64-spt"):
    for case, status, output in [
        ("task-trap", 1, b'emit "resumed": 9223372036854775807 (task 0)\ntrap: Overflow\ntrap at: arithmetic.fen:1:36\n'),
        ("concurrent", 0, b'emit "worker": 42 (task 1)\n42\n'),
        ("normal", 0, b"42\n"),
        ("trap", 1, b"trap: Overflow\ntrap at: arithmetic.fen:1:36\n"),
        ("outer-trap", 1, b"trap: Overflow\ntrap at: arithmetic.fen:2:34\n"),
    ]:
        row = json.loads(Path(f"{target}-{case}.json").read_bytes())
        schema = "fenrir-native-schedule/2" if case == "concurrent" else "fenrir-native-observations/3"
        if row["profile"] != expected_profile or row["schema"] != schema:
            raise ValueError((target, case, "execution profile mismatch"))
        if case == "concurrent" and set(row["dispatches"]) != {0, 1}:
            raise ValueError((target, "missing root or worker dispatch"))
        if row["exit_status"] != status or base64.b64decode(row["observations"]) != output:
            raise ValueError((target, case, row))
    tampered = json.loads(Path(f"{target}-normal.json").read_bytes())
    tampered["profile"]["sha256"] = "0" * 64
    path = Path(f"{target}-altered-profile.json")
    path.write_text(json.dumps(tampered))
    bad = subprocess.run([os.environ["FENRIR_TEST_CLI"], "replay", target, path], capture_output=True)
    if bad.returncode == 0 or b"execution profile mismatch" not in bad.stderr:
        raise ValueError("replay accepted or misdiagnosed an altered profile digest")
PY
# A rejected rebuild must preserve both the executable and its replay identity.
cat > invalid.fen <<'FEN'
(define main {I64 --> I64} n -> (missing-function n))
FEN
for target in macos-arm64 solo5-arm64-spt; do
    cp "$target" "$target-before-failure"
    if "$cli" build --target "$target" invalid.fen -o "$target" > "$target-rejection.log" 2>&1; then
        echo "build unexpectedly accepted missing-function for $target" >&2
        exit 1
    fi
    grep -q 'missing-function' "$target-rejection.log"
    cmp "$target-before-failure" "$target"
    "$cli" replay "./$target" "$target-normal.json"
done
# Edit the imported library and verify the normal source-to-execution path.
cat > arithmetic.fen <<'FEN'
(define add-one {I64 --> I64} n -> (+ n 2))
(define twice {I64 --> I64} n -> (+ (add-one n) 1))
FEN
for target in macos-arm64 solo5-arm64-spt; do
    "$cli" run --target "$target" concurrent.fen 41 > "$target-edited.txt"
    printf 'emit "worker": 43 (task 1)\n43\n' | cmp - "$target-edited.txt"
    "$cli" replay "./$target-concurrent" "$target-concurrent.json"
done

package=$(cd "$(dirname "$cli")/.." && pwd -P)
native_tests="$package/libexec/fenrir/tests/native"
"$package/bin/fenrir-toolchain" python3 "$native_tests/check-handler-roundtrips.py" \
    --native-fixtures --cli "$cli" "$PWD/native-roundtrips" \
    cancel-during-trap.fen discontinue-joins-child.fen discontinue-pending-resume.fen \
    resume-under-perform.fen resume-before-perform.fen resume-conditional-operand.fen \
    resume-nested-conditional.fen resume-conditional-earlier.fen resume-conditional-trap.fen
"$package/bin/fenrir-toolchain" python3 "$native_tests/check-task-limits.py" "$cli" "$PWD/task-limits"
