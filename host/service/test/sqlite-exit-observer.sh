#!/bin/sh
# SQLite sweeps only: report the C child's wait status before the port wrapper
# exits. Preserve its binary protocol on stdin/stdout; never write to stdout.
result=$FENRIR_SQLITE_EXIT_DIR/sqlite-exit-$$
: > "$result" || exit 1
exec 3<&0
"$FENRIR_REAL_SQLITE_PORT" <&3 3<&- &
child=$!
wait "$child"
status=$?
printf '%s' "$status" > "$result" || exit 1
exit "$status"
