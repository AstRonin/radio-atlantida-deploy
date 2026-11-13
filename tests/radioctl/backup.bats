#!/usr/bin/env bats
# radioctl D6: the daily backup, its journal and Windows copies, retention,
# the lock, the restore drill, status, and the systemd units.

load helpers

setup() { common_setup; }

# The fake clock is 2023-11-14T22:13:20Z: dumps are db-2023-11-14T221320Z.
TODAY=2023-11-14

set_env() { sed -i "s|^$1=.*|$1=$2|" "$ROOT/.env"; }
win_on() {
  mkdir -p "$ROOT/win"
  set_env BACKUP_WINDOWS_COPY "$ROOT/win"
}
journal_files() {
  printf '{"event":"start"}\n' >"$ROOT/journal/journal-2023-11-13.jsonl"
  printf '{"event":"start"}\n' >"$ROOT/journal/journal-$TODAY.jsonl"
  echo other >"$ROOT/journal/notes.txt"
}
daily_dumps() { find "$1" -maxdepth 1 -name 'db-*.dump' | wc -l; }

# ---------------------------------------------------------------- backup

@test "backup writes a daily dump and records it; it changes nothing else" {
  run radioctl backup
  [ "$status" -eq 0 ]
  assert_contains "$output" "Backup done: db-${TODAY}T221320Z.dump"
  [ -s "$ROOT/backups/daily/db-${TODAY}T221320Z.dump" ]
  [ "$(st .last_backup.result)" = ok ]
  [ "$(st .last_backup.dump)" = "$ROOT/backups/daily/db-${TODAY}T221320Z.dump" ]
  [ "$(st .last_backup_utc)" = 2023-11-14T22:13:20Z ]
  [ "$(st .last_backup.windows_copy)" = disabled ]
  [ "$(st '.last_dump // "none"')" = none ]
  ls "$ROOT"/logs/backup-*.log
  run events
  [ "$output" = DUMP ]
}

@test "backup failure is recorded, keeps the last success, and is shown by status and the next update" {
  jq '.last_backup_utc = "2023-11-14T01:00:00Z"' "$ROOT/state.json" >"$ROOT/s" && mv "$ROOT/s" "$ROOT/state.json"
  stub_rc pg_dump 1
  run radioctl backup
  [ "$status" -eq 1 ]
  assert_contains "$output" "the backup failed: pg_dump failed"
  [ "$(st .last_backup.result)" = failed ]
  [ "$(st .last_backup_utc)" = 2023-11-14T01:00:00Z ]
  [ -z "$(ls "$ROOT/backups/daily" 2>/dev/null)" ]
  run radioctl status
  assert_contains "$output" "last daily backup FAILED at 2023-11-14T22:13:20Z: pg_dump failed"
  assert_contains "$output" "last successful backup 2023-11-14T01:00:00Z"
  rm "$STUB_DIR/pg_dump.rc"
  run radioctl update
  [ "$status" -eq 0 ]
  assert_contains "$output" "WARNING: the last daily backup failed at 2023-11-14T22:13:20Z: pg_dump failed"
}

@test "backup fails when db is not healthy" {
  echo unhealthy >"$STUB_DIR/health_db"
  run radioctl backup
  [ "$status" -eq 1 ]
  assert_contains "$output" "the database container (db) is not healthy"
  run events
  refute_contains "$output" DUMP
}

@test "backup copies the journal files beside the dump; a second backup the same day refreshes them" {
  journal_files
  run radioctl backup
  [ "$status" -eq 0 ]
  local j=$ROOT/backups/daily/journal-$TODAY
  [ -f "$j/journal-2023-11-13.jsonl" ]
  [ -f "$j/journal-$TODAY.jsonl" ]
  [ ! -e "$j/notes.txt" ]
  [ "$(st .last_backup.journal)" = ok ]
  echo '{"event":"end"}' >>"$ROOT/journal/journal-$TODAY.jsonl"
  set_clock $((CLOCK_OK + 60))
  run radioctl backup
  [ "$status" -eq 0 ]
  [ "$(daily_dumps "$ROOT/backups/daily")" -eq 2 ]
  grep -q '"end"' "$j/journal-$TODAY.jsonl"
  [ ! -e "$j.part" ]
}

@test "no journal files yet: no journal folder, not a warning" {
  run radioctl backup
  [ "$status" -eq 0 ]
  assert_contains "$output" "journal: no journal files yet"
  refute_contains "$output" WARNING
  [ ! -e "$ROOT/backups/daily/journal-$TODAY" ]
  [ "$(st .last_backup.journal)" = none ]
}

@test "the Windows copy gets the same set when its folder exists" {
  journal_files
  win_on
  run radioctl backup
  [ "$status" -eq 0 ]
  cmp "$ROOT/backups/daily/db-${TODAY}T221320Z.dump" "$ROOT/win/daily/db-${TODAY}T221320Z.dump"
  [ -f "$ROOT/win/daily/journal-$TODAY/journal-$TODAY.jsonl" ]
  [ "$(st .last_backup.windows_copy)" = ok ]
  [ -z "$(find "$ROOT/win" -name '*.part')" ]
}

@test "a missing Windows folder is a warning only and is not created" {
  set_env BACKUP_WINDOWS_COPY /mnt/c/RadioAtlantida/backups
  run radioctl backup
  [ "$status" -eq 0 ]
  assert_contains "$output" 'WARNING: Windows copy skipped: /mnt/c/RadioAtlantida/backups (C:\RadioAtlantida\backups) does not exist'
  assert_contains "$output" "Backup done with 1 warning(s)"
  [ ! -e /mnt/c/RadioAtlantida ]
  [ "$(st .last_backup.result)" = ok ]
  [ "$(st .last_backup.windows_copy)" = missing ]
  [ "$(st '.last_backup.warnings | length')" = 1 ]
  run radioctl status
  assert_contains "$output" "Windows copy missing"
  assert_contains "$output" "warning: Windows copy skipped"
}

@test "an unwritable Windows copy is a warning only" {
  win_on
  : >"$ROOT/win/daily"
  run radioctl backup
  [ "$status" -eq 0 ]
  assert_contains "$output" "WARNING: Windows copy to $ROOT/win/daily failed"
  [ "$(st .last_backup.windows_copy)" = failed ]
  [ -s "$ROOT/backups/daily/db-${TODAY}T221320Z.dump" ]
}

@test "the pre-update dump gets the journal and Windows copies too" {
  journal_files
  win_on
  run radioctl update
  [ "$status" -eq 0 ]
  local d
  d=$(basename "$(st .last_dump)")
  [ -f "$ROOT/win/update/$d" ]
  [ -f "$ROOT/backups/update/journal-$TODAY/journal-$TODAY.jsonl" ]
  [ -f "$ROOT/win/update/journal-$TODAY/journal-$TODAY.jsonl" ]
}

# ------------------------------------------------------------- retention

@test "retention keeps the newest daily sets in both locations and their journal folders" {
  win_on
  local base i
  for base in "$ROOT/backups/daily" "$ROOT/win/daily"; do
    mkdir -p "$base"
    for i in $(seq -w 1 20); do : >"$base/db-2023-10-${i}T043000Z.dump"; done
    mkdir -p "$base/journal-2023-10-01" "$base/journal-2023-10-20"
  done
  run radioctl backup
  [ "$status" -eq 0 ]
  for base in "$ROOT/backups/daily" "$ROOT/win/daily"; do
    # The new dump and the 13 newest old ones (2023-10-08 .. 2023-10-20).
    [ "$(daily_dumps "$base")" -eq 14 ]
    [ -e "$base/db-${TODAY}T221320Z.dump" ]
    [ -e "$base/db-2023-10-08T043000Z.dump" ]
    [ ! -e "$base/db-2023-10-07T043000Z.dump" ]
    [ ! -e "$base/journal-2023-10-01" ]
    [ -d "$base/journal-2023-10-20" ]
  done
  assert_contains "$output" "retention: removing daily/db-2023-10-01T043000Z.dump (Windows copy)"
}

@test "BACKUP_DAILY_KEEP sets the number of daily sets" {
  set_env BACKUP_DAILY_KEEP 3
  mkdir -p "$ROOT/backups/daily"
  local i
  for i in 1 2 3 4 5; do : >"$ROOT/backups/daily/db-2023-10-0${i}T043000Z.dump"; done
  run radioctl backup
  [ "$status" -eq 0 ]
  [ "$(daily_dumps "$ROOT/backups/daily")" -eq 3 ]
  [ -e "$ROOT/backups/daily/db-2023-10-04T043000Z.dump" ]
}

@test "daily retention never touches the update dumps" {
  set_env BACKUP_DAILY_KEEP 1
  mkdir -p "$ROOT/backups/update" "$ROOT/backups/daily"
  : >"$ROOT/backups/update/db-2023-10-01T000000Z.dump"
  : >"$ROOT/backups/daily/db-2023-10-01T000000Z.dump"
  run radioctl backup
  [ "$status" -eq 0 ]
  [ -e "$ROOT/backups/update/db-2023-10-01T000000Z.dump" ]
  [ ! -e "$ROOT/backups/daily/db-2023-10-01T000000Z.dump" ]
}

@test "update retention applies to the Windows copy, keeping the recorded and boundary dumps" {
  win_on
  local d=$ROOT/win/update i
  mkdir -p "$d" "$d/journal-2023-10-01" "$d/journal-2023-10-02"
  for i in $(seq -w 1 20); do : >"$d/db-2023-10-${i}T000000Z.dump"; done
  # history and last_dump name BACKUP_ROOT paths; the copy matches by name.
  jq --arg b1 "$ROOT/backups/update/db-2023-10-01T000000Z.dump" \
    --arg b2 "$ROOT/backups/update/db-2023-10-02T000000Z.dump" '
    .history = [{dump: $b1, boundary: true}, {dump: $b2, boundary: true}]' \
    "$ROOT/state.json" >"$ROOT/s" && mv "$ROOT/s" "$ROOT/state.json"
  run radioctl update
  [ "$status" -eq 0 ]
  # 14 newest (the new dump and 13 old) + the 2 boundary dumps.
  [ "$(daily_dumps "$d")" -eq 16 ]
  [ -e "$d/db-2023-10-01T000000Z.dump" ]
  [ -e "$d/db-2023-10-02T000000Z.dump" ]
  [ ! -e "$d/db-2023-10-03T000000Z.dump" ]
  [ -d "$d/journal-2023-10-01" ]
  [ -e "$d/$(basename "$(st .last_dump)")" ]
}

# ------------------------------------------------------------------ lock

@test "backup does not run while an update holds state.lock; the reason is logged" {
  exec 8>>"$ROOT/state.lock"
  flock -n 8
  run radioctl backup
  exec 8>&-
  [ "$status" -eq 1 ]
  assert_contains "$output" "another radioctl is running"
  run events
  [ -z "$output" ]
  grep -q "another radioctl is running" "$ROOT"/logs/backup-*.log
  [ -z "$(st '.last_backup // empty')" ]
}

@test "an update does not run while a backup holds state.lock" {
  exec 8>>"$ROOT/state.lock"
  flock -n 8
  run radioctl update
  exec 8>&-
  [ "$status" -eq 1 ]
  run events
  [ -z "$output" ]
}

# -------------------------------------------------------------- dry runs

@test "backup --dry-run changes nothing" {
  journal_files
  win_on
  local before
  before=$(sha256sum "$ROOT/state.json")
  run radioctl --dry-run backup
  [ "$status" -eq 0 ]
  assert_contains "$output" "[dry-run] pg_dump -Fc"
  assert_contains "$output" "[dry-run] copy 2 journal file(s)"
  assert_contains "$output" "[dry-run] copy db-${TODAY}T221320Z.dump and its journal folder to $ROOT/win/daily"
  [ "$before" = "$(sha256sum "$ROOT/state.json")" ]
  [ ! -e "$ROOT/backups/daily" ]
  [ -z "$(ls "$ROOT/win")" ]
  run events
  [ -z "$output" ]
}

# ---------------------------------------------------------- restore drill

drill_dump() {
  mkdir -p "$ROOT/backups/daily"
  echo older >"$ROOT/backups/daily/db-2023-11-12T003000Z.dump"
  echo newest >"$ROOT/backups/daily/db-2023-11-13T003000Z.dump"
  : >"$STUB_DIR/calls.log"
}

# The production database (POSTGRES_DB=radio) is never named by the drill.
assert_production_untouched() {
  run grep -E -- '-d radio( |$)' "$STUB_DIR/calls.log"
  [ "$status" -eq 1 ] || {
    echo "the drill named the production database:"
    echo "$output"
    return 1
  }
  run events
  refute_contains "$output" "RESTORE radio"$'\n'
  [[ $output != *"RESTORE radio" ]]
  refute_contains "$output" "STOP"
  refute_contains "$output" "UP "
  refute_contains "$output" "DUMP"
}

@test "restore drill restores the newest daily dump into the scratch database, checks it, drops it" {
  drill_dump
  run radioctl restore-drill
  [ "$status" -eq 0 ]
  assert_contains "$output" "Restore drill: db-2023-11-13T003000Z.dump (taken 2023-11-13T00:30:00Z)"
  assert_contains "$output" "schema version 22, not dirty"
  assert_contains "$output" "tracks           812"
  assert_contains "$output" "Restore drill passed"
  grep -q newest "$STUB_DIR/restored_from"
  run events
  # A leftover scratch database is dropped first, then created, restored, dropped.
  [ "$output" = "$(printf 'DROPDB\nCREATEDB\nRESTORE radio_restore_drill\nDROPDB')" ]
  assert_production_untouched
  [ "$(st .last_drill.result)" = ok ]
  [ "$(st .last_drill.schema_version)" = 22 ]
  [ "$(st .last_drill.counts.tracks)" = 812 ]
  [ "$(st .last_drill.scratch_dropped)" = true ]
  ls "$ROOT"/logs/restore-drill-*.log
}

@test "a failed restore in the drill is reported, the scratch database is still dropped, production untouched" {
  drill_dump
  stub_rc pg_restore 1
  run radioctl restore-drill
  [ "$status" -eq 1 ]
  assert_contains "$output" "restore drill FAILED: pg_restore into radio_restore_drill failed. The production database was not touched."
  run events
  [[ $output == *"RESTORE radio_restore_drill"*"DROPDB" ]]
  assert_production_untouched
  [ "$(st .last_drill.result)" = failed ]
  [ "$(st .last_drill.error)" = "pg_restore into radio_restore_drill failed" ]
}

@test "the drill fails on a dirty restored schema" {
  drill_dump
  stub_out db_version "22 t"
  run radioctl restore-drill
  [ "$status" -eq 1 ]
  assert_contains "$output" "the restored schema (version 22) is dirty"
  [ "$(st .last_drill.result)" = failed ]
}

@test "the drill fails when a main table is missing" {
  drill_dump
  stub_out db_drill_counts $'settings|40\ntracks|-1\nplay_log|5'
  run radioctl restore-drill
  [ "$status" -eq 1 ]
  assert_contains "$output" "tables missing in the restored database: tracks"
  run events
  [[ $output == *"DROPDB" ]]
}

@test "the drill without a daily dump fails with a hint" {
  run radioctl restore-drill
  [ "$status" -eq 1 ]
  assert_contains "$output" "no daily dump in $ROOT/backups/daily"
  [ "$(st .last_drill.result)" = failed ]
  run events
  [ -z "$output" ]
}

@test "the drill uses the Windows copy when BACKUP_ROOT has no daily dump, or a named dump" {
  win_on
  mkdir -p "$ROOT/win/daily" "$ROOT/backups/update"
  echo win >"$ROOT/win/daily/db-2023-11-13T003000Z.dump"
  run radioctl restore-drill
  [ "$status" -eq 0 ]
  grep -q win "$STUB_DIR/restored_from"
  echo upd >"$ROOT/backups/update/db-2023-11-01T100000Z.dump"
  run radioctl restore-drill db-2023-11-01T100000Z.dump
  [ "$status" -eq 0 ]
  grep -q upd "$STUB_DIR/restored_from"
}

@test "restore-drill --dry-run changes nothing" {
  drill_dump
  local before
  before=$(sha256sum "$ROOT/state.json")
  run radioctl --dry-run restore-drill
  [ "$status" -eq 0 ]
  assert_contains "$output" "[dry-run] pg_restore -d radio_restore_drill"
  [ "$before" = "$(sha256sum "$ROOT/state.json")" ]
  run events
  [ -z "$output" ]
}

@test "the drill does not run while an update holds state.lock" {
  drill_dump
  exec 8>>"$ROOT/state.lock"
  flock -n 8
  run radioctl restore-drill
  exec 8>&-
  [ "$status" -eq 1 ]
  run events
  [ -z "$output" ]
}

# --------------------------------------------------------------- restore

@test "restore finds a bare dump name in daily/ and a dump only in the Windows copy" {
  win_on
  mkdir -p "$ROOT/backups/daily" "$ROOT/win/update"
  echo daily >"$ROOT/backups/daily/db-2023-11-13T003000Z.dump"
  run radioctl restore db-2023-11-13T003000Z.dump <<<"RESTORE"
  [ "$status" -eq 0 ]
  grep -q daily "$STUB_DIR/restored_from"
  [ "$(st .last_restore.dump)" = "$ROOT/backups/daily/db-2023-11-13T003000Z.dump" ]
  # last_dump names a lost BACKUP_ROOT file; its Windows copy is used.
  echo wincopy >"$ROOT/win/update/db-2023-11-01T100000Z.dump"
  jq --arg d "$ROOT/backups/update/db-2023-11-01T100000Z.dump" '.last_dump = $d' "$ROOT/state.json" >"$ROOT/s" && mv "$ROOT/s" "$ROOT/state.json"
  run radioctl restore <<<"RESTORE"
  [ "$status" -eq 0 ]
  grep -q wincopy "$STUB_DIR/restored_from"
}

# ---------------------------------------------------------------- status

@test "status shows the last backup and the last drill" {
  run radioctl backup
  [ "$status" -eq 0 ]
  mkdir -p "$ROOT/backups/daily"
  run radioctl restore-drill
  [ "$status" -eq 0 ]
  run radioctl status
  [ "$status" -eq 0 ]
  assert_contains "$output" "last daily backup 2023-11-14T22:13:20Z ok: db-${TODAY}T221320Z.dump, journal none, Windows copy disabled"
  assert_contains "$output" "last restore drill 2023-11-14T22:13:20Z ok: db-${TODAY}T221320Z.dump, schema version 22"
  refute_contains "$output" OVERDUE
  refute_contains "$output" DUE
}

@test "status flags an overdue backup, a due drill, and a failed drill" {
  jq '.last_backup_utc = "2023-11-13T00:30:00Z"
    | .last_backup = {utc: "2023-11-13T00:30:00Z", result: "ok", dump: "/x/daily/db-2023-11-13T003000Z.dump", journal: "ok", windows_copy: "ok", warnings: []}
    | .last_drill = {utc: "2023-09-01T01:30:00Z", result: "ok", dump: "/x/daily/db-2023-09-01T003000Z.dump", schema_version: 22}' \
    "$ROOT/state.json" >"$ROOT/s" && mv "$ROOT/s" "$ROOT/state.json"
  run radioctl status
  assert_contains "$output" "OVERDUE: no successful daily backup for 45 hours"
  assert_contains "$output" "DUE: the last successful restore drill is 74 days old"
  jq '.last_drill = {utc: "2023-11-14T01:30:00Z", result: "failed", error: "pg_restore into radio_restore_drill failed", log: "logs/restore-drill-x.log"}' \
    "$ROOT/state.json" >"$ROOT/s" && mv "$ROOT/s" "$ROOT/state.json"
  run radioctl status
  assert_contains "$output" "last restore drill FAILED at 2023-11-14T01:30:00Z: pg_restore into radio_restore_drill failed (log logs/restore-drill-x.log)"
}

@test "status without any backup or drill" {
  run radioctl status
  assert_contains "$output" "last daily backup none"
  assert_contains "$output" "last restore drill never"
}

# ------------------------------------------------------------- first run

first_run_setup() {
  rm -f "$ROOT/state.json" "$ROOT/.env" "$ROOT/runtime/applied.env"
  sed -i -e "s|^MEDIA_ROOT=.*|MEDIA_ROOT=$ROOT/media|" -e "s|^PLAYOUT_JOURNAL_ROOT=.*|PLAYOUT_JOURNAL_ROOT=$ROOT/journal|" \
    -e "s|^BACKUP_ROOT=.*|BACKUP_ROOT=$ROOT/backups|" -e "s|^BACKUP_WINDOWS_COPY=.*|BACKUP_WINDOWS_COPY=|" "$ROOT/.env.example"
  echo stopped >"$STUB_DIR/running_backend"
}

@test "first run checks the timers and runs the first backup after the stack is up" {
  first_run_setup
  run radioctl --yes first-run <<<$'a\nb\nc'
  [ "$status" -eq 0 ]
  assert_contains "$output" "radio-backup.timer enabled"
  assert_contains "$output" "radio-restore-drill.timer enabled"
  run events
  [[ $output == *"UP frontend 1.0.1"*"DUMP" ]]
  [ "$(daily_dumps "$ROOT/backups/daily")" -eq 1 ]
  [ "$(st .last_backup.result)" = ok ]
  [ "$(st '.last_dump // "none"')" = none ]
  [ "$(st '.history[0].dump')" = null ]
  run calls
  assert_contains "$output" "systemctl is-enabled --quiet radio-backup.timer"
}

@test "first run: a timer that is not enabled and a failed first backup are warnings" {
  first_run_setup
  stub_rc systemctl_enabled 1
  stub_rc pg_dump 1
  run radioctl --yes first-run <<<$'a\nb\nc'
  [ "$status" -eq 0 ]
  assert_contains "$output" "WARNING: radio-backup.timer is not enabled; as root run install/systemd/install-units.sh"
  assert_contains "$output" "WARNING: the first backup failed"
  [ "$(st .current.backend_tag)" = 1.0.1 ]
  [ "$(st .last_result)" = ok ]
  [ "$(st .last_backup.result)" = failed ]
}

# --------------------------------------------------------- systemd units

unit_value() { sed -n "s/^$2=//p" "$REPO/install/systemd/$1"; }

@test "radio-backup.timer: daily at 04:30 station time, Persistent=true" {
  [ "$(unit_value radio-backup.timer OnCalendar)" = "*-*-* 04:30:00 Asia/Yerevan" ]
  [ "$(unit_value radio-backup.timer Persistent)" = true ]
  [ "$(unit_value radio-backup.timer Unit)" = radio-backup.service ]
  [ "$(unit_value radio-backup.timer WantedBy)" = timers.target ]
}

@test "radio-backup.service: radioctl backup as radio, oneshot, waits for an update's lock" {
  [ "$(unit_value radio-backup.service Type)" = oneshot ]
  [ "$(unit_value radio-backup.service User)" = radio ]
  [ "$(unit_value radio-backup.service ExecStart)" = "/opt/radio-atlantida/deploy/bin/radioctl backup" ]
  [ "$(unit_value radio-backup.service WorkingDirectory)" = /opt/radio-atlantida/deploy ]
  [ "$(unit_value radio-backup.service Environment)" = RADIOCTL_LOCK_WAIT=3600 ]
  [ "$(unit_value radio-backup.service After)" = docker.service ]
  [ "$(unit_value radio-backup.service ConditionPathExists)" = /opt/radio-atlantida/deploy/runtime/applied.env ]
}

@test "radio-restore-drill: monthly after the backup, Persistent=true, radioctl restore-drill as radio" {
  [ "$(unit_value radio-restore-drill.timer OnCalendar)" = "*-*-01 05:30:00 Asia/Yerevan" ]
  [ "$(unit_value radio-restore-drill.timer Persistent)" = true ]
  [ "$(unit_value radio-restore-drill.service User)" = radio ]
  [ "$(unit_value radio-restore-drill.service ExecStart)" = "/opt/radio-atlantida/deploy/bin/radioctl restore-drill" ]
}

@test "install-units.sh installs the units, reloads, enables the timers; a second run rewrites nothing" {
  local dest=$BATS_TEST_TMPDIR/units
  mkdir -p "$dest"
  SYSTEMD_UNIT_DIR=$dest run "$REPO/install/systemd/install-units.sh"
  [ "$status" -eq 0 ]
  cmp "$REPO/install/systemd/radio-backup.timer" "$dest/radio-backup.timer"
  cmp "$REPO/install/systemd/radio-restore-drill.service" "$dest/radio-restore-drill.service"
  [ "$(stat -c %a "$dest/radio-backup.service")" = 644 ]
  run calls
  assert_contains "$output" "systemctl daemon-reload"
  assert_contains "$output" "systemctl enable --now radio-backup.timer radio-restore-drill.timer"
  : >"$STUB_DIR/calls.log"
  SYSTEMD_UNIT_DIR=$dest run "$REPO/install/systemd/install-units.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run calls
  refute_contains "$output" daemon-reload
  assert_contains "$output" "systemctl enable --now"
}
