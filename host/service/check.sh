#!/bin/sh
# Stage A3 (04_DIRECTION_AMENDMENT.md section 8): the SQLite adapter under an OTP
# supervisor with the Fenrir handler as a Solo5 worker; unit tests, black-box crash and
# history campaigns against the A1 contract, host mutants. Development evidence only:
# "observed history accepted; bounded crash campaign". Never a gate verdict.
#
#   sh host/service/check.sh [quick|full]     (default quick)
#
# Uses the flake's fenrir-a3-tools (Erlang/OTP, SQLite, gcc, node) by default.
# FENRIR_A3_TOOLS can name a prebuilt prefix with the same bin/include/lib layout;
# the report distinguishes this from the Nix package. Writes and prints
# build/host/service/<run>/report.json. Exit 0 only on development-pass.
set -eu
mode=${1:-quick}
case "$mode" in quick|full) ;; *) echo "usage: check.sh [quick|full]" >&2; exit 2 ;; esac
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
# Fail before asking Nix to build when the service's shared dependencies have
# not been reconciled. This is not a campaign run or a development verdict.
for input in harness/solo5.sh tools/solo5/control-durable-build.mjs backends/solo5/pure-call/control.c; do
  if [ ! -f "$root/$input" ]; then
    printf 'A3 campaign blocked: missing %s; see host/service/INTEGRATION.md\n' "$input" >&2
    exit 2
  fi
done
export PATH="$PATH:/nix/var/nix/profiles/default/bin"
repo=$root
# jit.sh derives its default prefix from $0, which is in host/service here.
# Supply the repository-relative fallback explicitly if Nix is not available.
if [ -z "${FENRIR_SHEN_JIT:-}" ] && ! command -v nix >/dev/null 2>&1; then
  FENRIR_SHEN_JIT="$repo/build/toolchain/shen-jit-0.12"
fi
. "$repo/harness/jit.sh"
root=$repo # jit.sh sets root from $0, which is two levels down here
. "$repo/harness/solo5.sh"
FENRIR_SHEN_JIT=$jit
export FENRIR_SHEN_JIT
if [ -z "${FENRIR_SOLO5:-}" ] ||
   { [ ! -x "$FENRIR_SOLO5/tenders/spt/solo5-spt" ] && [ ! -x "$FENRIR_SOLO5/bin/solo5-spt" ]; }; then
  echo 'A3 campaign blocked: no installed or checkout Solo5 spt tender (harness/solo5.sh)' >&2
  exit 2
fi
if [ -n "${FENRIR_A3_TOOLS:-}" ]; then
  tools=$(cd "$FENRIR_A3_TOOLS" && pwd)
  tool_source=explicit_prefix
else
  tools=$(cd "$root" && nix build --no-link --print-out-paths .#fenrir-a3-tools)
  tool_source=nix_build
fi
for tool in gcc erl erlc node; do
  if [ ! -x "$tools/bin/$tool" ]; then
    printf 'A3 campaign blocked: missing %s/bin/%s\n' "$tools" "$tool" >&2
    exit 2
  fi
done
export PATH="$tools/bin:$PATH"
out="$root/build/host/service/$(date +%s)-$$"
ebin="$out/ebin"
mkdir -p "$ebin" "$out/bin"
log="$out/check.log"
step() { echo "== $*" >&2; }

step "build: SQLite port program and Erlang modules"
"$tools/bin/gcc" -std=c11 -O2 -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L -I"$tools/include" \
  "$here/c_src/fenrir_sqlite_port.c" -L"$tools/lib" -Wl,-rpath,"$tools/lib" -lsqlite3 -o "$out/bin/fenrir_sqlite_port"
"$tools/bin/erlc" -Wall -Werror -o "$ebin" "$here"/src/*.erl "$here"/test/*.erl
cp "$here/src/fenrir_service.app.src" "$ebin/fenrir_service.app"
FENRIR_SQLITE_PORT="$out/bin/fenrir_sqlite_port"
export FENRIR_SQLITE_PORT

step "artifact: the handler, elaborated by the frontend"
pinned=$(cat "$here/artifacts/accepted-job.sha256")
artifact="$out/accepted-job.json"
emit=0
# The source map carries the file as named on the command line (SURFACE.md section 2),
# so the handler is named relative to the repository root: the artifact's bytes, and
# with them the pinned hash, are then the same on every machine.
(cd "$root" && sh frontend/fenrir.sh emit examples/service/accepted-job.fen "$artifact") > "$out/emit.txt" 2>&1 || emit=$?
if [ "$emit" -eq 0 ]; then
  source="frontend emit in this tree"
else
  # The committed copy is the same emit (repository-relative name), kept so a tree
  # whose frontend cannot run still has the pinned bytes; the report says which was used.
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
  mode => $mode, artifact_source => "$source", tool_source => $tool_source}.
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
