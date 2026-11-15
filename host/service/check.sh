#!/bin/sh
# Stage A3 (04_DIRECTION_AMENDMENT.md section 8): the SQLite adapter under an OTP
# supervisor with the Fenrir handler as a Solo5 worker; unit tests, black-box crash and
# history campaigns against the A1 contract, host mutants. Development evidence only:
# "observed history accepted; bounded crash campaign". Never a gate verdict.
#
#   sh host/service/check.sh [quick|full]     (default quick)
#
# Builds everything through nix (the flake's fenrir-a3-tools: Erlang/OTP, SQLite, gcc,
# node), writes build/host/service/<run>/report.json and prints it. Exit 0 exactly when
# the report's status is development-pass.
set -eu
mode=${1:-quick}
case "$mode" in quick|full) ;; *) echo "usage: check.sh [quick|full]" >&2; exit 2 ;; esac
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
export PATH="$PATH:/nix/var/nix/profiles/default/bin"
repo=$root
. "$repo/harness/jit.sh"
root=$repo # jit.sh sets root from $0, which is two levels down here
. "$repo/harness/solo5.sh"
FENRIR_SHEN_JIT=$jit
export FENRIR_SHEN_JIT
tools=$(cd "$root" && nix build --no-link --print-out-paths .#fenrir-a3-tools)
if [ -z "$FENRIR_SOLO5" ] || [ ! -x "$FENRIR_SOLO5/tenders/spt/solo5-spt" ]; then
  echo '{"status":"development-fail","reason":"BLOCKED: no Solo5 (harness/solo5.sh)"}'
  exit 1
fi
out="$root/build/host/service/$(date +%s)-$$"
ebin="$out/ebin"
mkdir -p "$ebin" "$out/bin"
log="$out/check.log"
step() { echo "== $*" >&2; }

step "build: SQLite port program and Erlang modules"
"$tools/bin/gcc" -std=c11 -O2 -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L -I"$tools/include" \
  "$here/c_src/fenrir_sqlite_port.c" -L"$tools/lib" -Wl,-rpath,"$tools/lib" -lsqlite3 -o "$out/bin/fenrir_sqlite_port"
"$tools/bin/erlc" -Wall -Werror -o "$ebin" "$here"/src/*.erl "$here"/test/*.erl
FENRIR_SQLITE_PORT="$out/bin/fenrir_sqlite_port"
export FENRIR_SQLITE_PORT

step "artifact: the handler, elaborated by the frontend"
pinned=$(cat "$here/artifacts/accepted-job.sha256")
artifact="$out/accepted-job.json"
emit=0
sh "$root/frontend/fenrir.sh" emit "$root/examples/service/accepted-job.fen" "$artifact" > "$out/emit.txt" 2>&1 || emit=$?
if [ "$emit" -eq 0 ]; then
  source="frontend emit in this tree"
else
  # Known issue at bf5cb36: emit exits 3 (a second validator does not know the durable
  # schema). The committed copy was emitted by the frontend of a sibling worktree.
  cp "$here/artifacts/accepted-job.json" "$artifact"
  source="committed copy host/service/artifacts/accepted-job.json (frontend emit exited $emit in this tree)"
fi
asha=$(sha256sum "$artifact" | cut -d' ' -f1)
if [ "$asha" != "$pinned" ]; then
  echo "{\"status\":\"development-fail\",\"reason\":\"artifact sha256 $asha differs from the pinned $pinned ($source)\"}"
  exit 1
fi

step "image: the guest image over the request domain"
image=$(FENRIR_SOLO5=$FENRIR_SOLO5 "$tools/bin/node" "$here/tools/build-image.mjs" "$artifact" "$out/image" 3 3 2 8)
other=$(FENRIR_SOLO5=$FENRIR_SOLO5 "$tools/bin/node" "$root/tools/solo5/control-durable-build.mjs")/control.spt

if [ "$mode" = full ]; then
  repeats=5; random=60; mutant_random=6; sqlite_repeats=2; batches=20
else
  repeats=1; random=12; mutant_random=3; sqlite_repeats=1; batches=10
fi
cat > "$out/config.term" <<EOF
#{out => "$out", root => "$root", erl => "$tools/bin/erl", ebin => "$ebin",
  node_launch => "$here/priv/node-launch", launcher => "$here/priv/spt-launch",
  sqlite_port => "$out/bin/fenrir_sqlite_port", image => "$image", artifact => "$artifact",
  other_image => "$other",
  hand_traces => "$root/spec/service/hand-traces.json", a2_runs => "$root/tests/host/a2-runs.json",
  tenants => 3, repeats => $repeats, random_schedules => $random, schedule_length => 10,
  sqlite_kill_repeats => $sqlite_repeats, concurrent_batches => $batches, mutant_random_schedules => $mutant_random,
  mutants => [volatile_mailbox, respond_before_commit, two_transactions, busy_as_success, no_dedup,
              no_transaction, sync_off, equivalent_control],
  families => ${FENRIR_A3_FAMILIES:-all},
  mode => $mode, artifact_source => "$source"}.
EOF
erl() { "$tools/bin/erl" -noshell -noinput -pa "$ebin" "$@" < /dev/null; }

step "unit tests"
erl -run fenrir_unit main "$out/config.term" >> "$log" 2>&1 || true
tail -n 1 "$log" >&2

step "campaigns ($mode)"
erl -run fenrir_campaign main "$out/config.term" >> "$log" 2>&1 || true
tail -n 1 "$log" >&2

step "history checker: campaign histories and the checker's own negative tests"
ls "$root"/tests/host/histories/*.json > "$out/negative.txt"
hist=0
sh "$root/harness/run-service-history.sh" "$out/histories.txt" "$out/verdicts" > /dev/null || hist=$?
sh "$root/harness/run-service-history.sh" "$out/negative.txt" "$out/negative" > /dev/null || hist=$?

step "report"
erl -run fenrir_report main "$out/config.term" "$hist" >> "$log" 2>&1 || true
if [ ! -s "$out/report.json" ]; then echo '{"status":"development-fail","reason":"no report written"}'; exit 1; fi
cat "$out/report.json"
echo >&2 "output: $out"
grep -q '"status":"development-pass"' "$out/report.json"
