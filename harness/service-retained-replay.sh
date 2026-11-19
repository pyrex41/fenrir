# Shared by both service runners. The Shen loader prints definitions first;
# the final line must be the replay report for this counterexample.
service_replay_retained() {
  replay_artifacts=$1
  shift
  replay_failed=0
  for replay_file in "$@"; do
    child_status=0
    replay_output=$(run replay "$replay_file" ${replay_artifacts:+"$replay_artifacts"} 2>&1) || child_status=$?
    replay_line=$(printf '%s\n' "$replay_output" | tail -n 1)
    if [ "$child_status" -eq 0 ] && printf '%s\n' "$replay_line" | node -e '
      const {readFileSync} = require("node:fs");
      const file = process.argv[1];
      try {
        const fixture = JSON.parse(readFileSync(file, "utf8"));
        const report = JSON.parse(readFileSync(0, "utf8"));
        if (report.schema === "fenrir.service.replay/1" && report.status === "reproduced" &&
            report.schedule_enabled === true && report.file === file &&
            typeof fixture.machine === "string" && report.machine === fixture.machine &&
            typeof fixture.check === "string" && report.check === fixture.check &&
            Number.isSafeInteger(fixture.length) && report.length === fixture.length &&
            report.first_failure_at === fixture.length) process.exit(0);
      } catch {}
      process.exitCode = 1;
    ' "$replay_file"; then
      printf 'reproduced: %s\n' "${replay_file#"$root"/}"
    else
      printf 'NOT reproduced: %s (replay exit %s): %s\n' "${replay_file#"$root"/}" "$child_status" "$replay_line"
      replay_failed=1
    fi
  done
  return "$replay_failed"
}
