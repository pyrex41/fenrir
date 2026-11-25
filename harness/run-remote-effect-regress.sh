#!/bin/sh
# Remote-effect regressions (spec/tc1/EFFECTS.md §12). TESTS ONLY.
#
# Stub peer: supervisor/test/fenrir_member.erl is compiled as fenrir_member.
# Solo5 guests are not built. fenrir_relay, fenrir_journal and fenrir_wire are
# the real sources. The signature digest is tools/solo5/remote-build.mjs
# signatureDigest of the operation signature, which does not include the function.
#
# Both cases assert the contract. They fail on master a89bf40. This repository
# has no xfail/known-failing marker for a supervisor run, so the script exits 1
# and CI fails.
#
#   sh harness/run-remote-effect-regress.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
src="$root/supervisor/src"
test="$root/supervisor/test"
out="$root/build/remote-effect-regress"
ebin="$out/ebin"
rm -rf "$out"
mkdir -p "$ebin" "$out/vm" "$out/upgrade"
erlc -Werror -o "$ebin" \
  "$src/fenrir_journal.erl" "$src/fenrir_relay.erl" "$src/fenrir_run.erl" \
  "$src/fenrir_sup.erl" "$src/fenrir_member_sup.erl" "$src/fenrir_supervisor_app.erl" \
  "$src/fenrir_wire.erl" \
  "$test/fenrir_member.erl" "$test/fenrir_regress.erl"
cp "$src/fenrir_supervisor.app.src" "$ebin/fenrir_supervisor.app"
# Real digest of the Ledger.add signature. The function body is not an input.
digest=$(node --input-type=module -e '
import {signatureDigest} from "./tools/solo5/remote-build.mjs";
process.stdout.write(signatureDigest({class:"remote", name:"Ledger", operations:[
  {name:"add", argument_type:"I64", read_only:false, result_type:["Tuple","I64","I64"]}
]}));
')
echo "signature digest $digest"
export FENRIR_SIGNATURE_DIGEST="$digest"

fail=0
echo "---- vm loss ----"
export RUN_DIR="$out/vm"
export FENRIR_PEER_VERSION=1
export FENRIR_STUB_SCRIPT=vm1
cd "$out/vm"
erl -noshell -pa "$ebin" -run fenrir_regress vm_phase1 >"$out/vm1.stdout" 2>&1 &
shell_pid=$!
i=0
while [ ! -f "$out/vm/READY" ]; do
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then
    echo "phase 1 did not become ready" >&2
    cat "$out/vm1.stdout" >&2 || true
    kill -9 "$shell_pid" 2>/dev/null || true
    exit 2
  fi
  sleep 0.1
done
comm=$(cat "/proc/$shell_pid/comm" 2>/dev/null || echo missing)
if [ "$comm" = "beam.smp" ]; then beam=$shell_pid
else beam=$(ps -o pid=,comm= --ppid "$shell_pid" | awk '$2=="beam.smp" {print $1; exit}'); fi
comm=$(cat "/proc/$beam/comm" 2>/dev/null || echo missing)
echo "kill -9 pid=$beam comm=$comm"
[ "$comm" = "beam.smp" ] || { echo "not beam.smp" >&2; exit 2; }
kill -9 "$beam"
i=0
state=alive
while [ "$i" -lt 25 ]; do
  if [ ! -d "/proc/$beam" ]; then state=gone; break; fi
  state=$(awk '/^State:/ {print $2}' "/proc/$beam/status" 2>/dev/null || echo gone)
  case $state in gone|Z|X) break ;; esac
  i=$((i + 1))
  sleep 0.2
done
echo "after kill -9: $state"
case $state in gone|Z|X) ;; *) echo "VM still running" >&2; exit 2 ;; esac
export FENRIR_STUB_SCRIPT=vm2
set +e
erl -noshell -pa "$ebin" -run fenrir_regress vm_phase2 >"$out/vm2.stdout" 2>&1
vm=$?
set -e
echo "vm_phase2 exit $vm"
cat "$out/vm1.stdout" "$out/vm2.stdout"
if [ "$vm" -ne 1 ] && [ "$vm" -ne 0 ]; then exit "$vm"; fi
if [ "$vm" -ne 0 ]; then fail=1; fi

echo "---- upgrade ----"
export RUN_DIR="$out/upgrade"
export FENRIR_PEER_VERSION=2
export FENRIR_STUB_SCRIPT=upgrade
set +e
erl -noshell -pa "$ebin" -run fenrir_regress upgrade >"$out/upgrade.stdout" 2>&1
up=$?
set -e
echo "upgrade exit $up"
cat "$out/upgrade.stdout"
if [ "$up" -ne 1 ] && [ "$up" -ne 0 ]; then exit "$up"; fi
if [ "$up" -ne 0 ]; then fail=1; fi

if [ "$fail" -ne 0 ]; then
  echo "remote-effect regressions: FAIL (expected on master until the journal is durable and the digest covers the function)"
  exit 1
fi
echo "remote-effect regressions: pass"
exit 0
