#!/usr/bin/env bats
# radioctl: maintenance, restore, cut-over, first run, status, lock, dry run.

load helpers

setup() { common_setup; }

# ---------------------------------------------------------------- maintenance

@test "maintenance with nothing pending does nothing" {
  run radioctl maintenance
  [ "$status" -eq 0 ]
  assert_contains "$output" "Nothing is pending."
}

@test "maintenance asks for MAINTENANCE; another answer changes nothing" {
  stub_out compose_config '{"services":{"liquidsoap":{"image":"savonet/liquidsoap:v2.4.7"},"db":{"image":"postgres:17.11"}}}'
  run radioctl maintenance <<<"yes"
  [ "$status" -eq 1 ]
  assert_contains "$output" "liquidsoap image savonet/liquidsoap:v2.4.6 -> savonet/liquidsoap:v2.4.7"
  assert_contains "$output" "Type MAINTENANCE to continue"
  assert_contains "$output" "Planned in the next 15 minutes:"
  run events
  refute_contains "$output" "UP liquidsoap"
}

@test "maintenance with MAINTENANCE recreates liquidsoap, checks it, records the applied values" {
  stub_out compose_config '{"services":{"liquidsoap":{"image":"savonet/liquidsoap:v2.4.7"},"db":{"image":"postgres:17.11"}}}'
  run radioctl --yes maintenance <<<"MAINTENANCE"
  [ "$status" -eq 0 ]
  run calls
  assert_contains "$output" "up -d --no-deps --force-recreate liquidsoap"
  run events
  refute_contains "$output" "DUMP"
  [ "$(st .applied.liquidsoap_image)" = savonet/liquidsoap:v2.4.7 ]
  [ "$(st '.pending_maintenance | length')" = 0 ]
}

@test "maintenance of db takes a dump first" {
  stub_out compose_config '{"services":{"liquidsoap":{"image":"savonet/liquidsoap:v2.4.6","command":["/etc/liquidsoap/radio.liq"]},"db":{"image":"postgres:17.12"}}}'
  run radioctl maintenance <<<"MAINTENANCE"
  [ "$status" -eq 0 ]
  run events
  [[ $output == *"DUMP"*"UP db"* ]]
  [ "$(st .applied.db_image)" = postgres:17.12 ]
}

@test "maintenance reports a liquidsoap that does not reconnect" {
  stub_out compose_config '{"services":{"liquidsoap":{"image":"savonet/liquidsoap:v2.4.7"},"db":{"image":"postgres:17.11"}}}'
  api api_playout_status '{"control_link":{"connected":true},"output":{"state":"disconnected"},"queued":[]}'
  run radioctl maintenance <<<"MAINTENANCE"
  [ "$status" -eq 1 ]
  assert_contains "$output" "Liquidsoap did not come back"
  [ "$(st .applied.liquidsoap_image)" = savonet/liquidsoap:v2.4.6 ]
}

# -------------------------------------------------------------------- restore

@test "restore asks for RESTORE; another answer changes nothing" {
  local d=$ROOT/backups/update/db-2023-11-01T100000Z.dump
  mkdir -p "${d%/*}"
  echo the-dump >"$d"
  run radioctl restore "$d" <<<"restore"
  [ "$status" -eq 1 ]
  assert_contains "$output" "Restore db-2023-11-01T100000Z.dump (taken 2023-11-01T10:00:00Z)"
  run events
  refute_contains "$output" "RESTORE"
  refute_contains "$output" "STOP"
}

@test "restore takes a safety dump, stops the backend first, migrates, starts it" {
  local d=$ROOT/backups/update/db-2023-11-01T100000Z.dump
  mkdir -p "${d%/*}"
  echo the-dump >"$d"
  # A relative name is looked up under BACKUP_ROOT.
  run radioctl restore update/db-2023-11-01T100000Z.dump <<<"RESTORE"
  [ "$status" -eq 0 ]
  run events
  [[ $output == *"DUMP"*"STOP backend"*"RESTORE"*"MIGRATE 1.0.0"*"UP backend 1.0.0"* ]]
  grep -q the-dump "$STUB_DIR/restored_from"
  [ "$(st .last_restore.dump)" = "$d" ]
  [ "$(st .current.backend_tag)" = 1.0.0 ]
}

@test "restore without an argument uses the dump of the last update" {
  run radioctl update
  [ "$status" -eq 0 ]
  run radioctl restore <<<"RESTORE"
  [ "$status" -eq 0 ]
  assert_contains "$output" "$(basename "$(st .history[0].dump)")"
}

# -------------------------------------------------------------------- cutover

@test "cutover checks its preconditions" {
  write_state 1.0.0 "$D_B100" 1.0.0 "$D_F100" null false
  api api_track-plan '{"items":[{"items":[{}]}]}'
  run radioctl cutover <<<"CUTOVER"
  [ "$status" -eq 1 ]
  assert_contains "$output" "not ready: the plan covers 1 of the next 24 hours"
  run events
  refute_contains "$output" "liquidsoap"
}

@test "cutover asks for CUTOVER, starts liquidsoap, records cutover_utc" {
  write_state 1.0.0 "$D_B100" 1.0.0 "$D_F100" null false
  api api_track-plan "$(jq -n '{items: [range(24) | {items: [{}]}]}')"
  run radioctl cutover <<<"no"
  [ "$status" -eq 1 ]
  run events
  refute_contains "$output" "liquidsoap"
  run radioctl cutover <<<"CUTOVER"
  [ "$status" -eq 0 ]
  assert_contains "$output" "Cut-over done"
  run events
  assert_contains "$output" "UP liquidsoap"
  [ -n "$(st '.cutover_utc // empty')" ]
}

@test "cutover --undo asks for CUTOVER and stops liquidsoap" {
  run radioctl cutover --undo <<<"CUTOVER"
  [ "$status" -eq 0 ]
  run events
  assert_contains "$output" "STOP liquidsoap"
  [ -z "$(st '.cutover_utc // empty')" ]
}

# ------------------------------------------------------------------ first run

first_run_setup() {
  rm -f "$ROOT/state.json" "$ROOT/.env" "$ROOT/runtime/applied.env"
  # The installer writes the host paths; here they point into the test root.
  sed -i -e "s|^MEDIA_ROOT=.*|MEDIA_ROOT=$ROOT/media|" -e "s|^PLAYOUT_JOURNAL_ROOT=.*|PLAYOUT_JOURNAL_ROOT=$ROOT/journal|" \
    -e "s|^BACKUP_ROOT=.*|BACKUP_ROOT=$ROOT/backups|" "$ROOT/.env.example"
  echo stopped >"$STUB_DIR/running_backend"
  # The stub starts the backend on "up"; the first run then reads /readyz.
}

@test "first run: .env written, stack started without liquidsoap, no air check, no dump" {
  first_run_setup
  run radioctl --yes first-run --media-root "$ROOT/media" <<<$'ghuser\nghtoken\nicepass'
  [ "$status" -eq 0 ]
  assert_contains "$output" "First run done: 1.0.1 is running"
  refute_contains "$output" "Air check"
  refute_contains "$output" "ghtoken"
  refute_contains "$output" "icepass"
  run events
  [[ $output == *"UP db"*"MIGRATE 1.0.1"*"UP backend 1.0.1"*"UP frontend 1.0.1"* ]]
  refute_contains "$output" "liquidsoap"
  refute_contains "$output" "DUMP"
  [ "$(stat -c %a "$ROOT/.env")" = 600 ]
  grep -q '^GHCR_READ_TOKEN=ghtoken$' "$ROOT/.env"
  grep -q "^MEDIA_ROOT=$ROOT/media$" "$ROOT/.env"
  ! grep -q '^POSTGRES_PASSWORD=changeme$' "$ROOT/.env"
  [ "$(st .current.backend_tag)" = 1.0.1 ]
  [ "$(st .last_result)" = ok ]
  [ "$(st .applied.liquidsoap_image)" = savonet/liquidsoap:v2.4.6 ]
  [ "$(jq -r '.values["stream.icecast_host"]' "$STUB_DIR/patch_body")" = listen.teploe.net ]
  [ "$(jq -r '.values["stream.bitrate_kbps"]' "$STUB_DIR/patch_body")" = 160 ]
  [ "$(jq -r '.values["stream.icecast_tls"]' "$STUB_DIR/patch_body")" = true ]
  ! grep -rq -e ghtoken -e icepass "$ROOT/logs"
}

@test "first run refuses an empty prompted value" {
  first_run_setup
  run radioctl --yes first-run <<<$'\nghuser\nghtoken\nicepass'
  [ "$status" -eq 0 ]
  assert_contains "$output" "GHCR_USER may not be empty"
}

@test "update without an installed release takes the first-run path" {
  first_run_setup
  cp "$ROOT/.env.example" "$ROOT/.env"
  run radioctl --yes update
  [ "$status" -eq 0 ]
  assert_contains "$output" "running the first run"
  [ "$(st .current.backend_tag)" = 1.0.1 ]
}

@test "first run with a database volume and no state stops" {
  first_run_setup
  stub_rc volume_inspect 0
  run radioctl first-run <<<$'a\nb\nc'
  [ "$status" -eq 1 ]
  assert_contains "$output" "radio-atlantida_pgdata exists but state.json does not"
  [ ! -f "$ROOT/.env" ]
}

@test "a failed first run does not roll back, and the next run takes the first-run path again" {
  first_run_setup
  stub_rc migrate_up 1
  run radioctl --yes first-run <<<$'a\nb\nc'
  [ "$status" -eq 1 ]
  assert_contains "$output" "The first run failed at: migrate (exit 1). Nothing is rolled back"
  [ "$(st .last_result)" = failed ]
  run events
  refute_contains "$output" "STOP"
  refute_contains "$output" "RESTORE"
  rm "$STUB_DIR/migrate_up.rc"
  run radioctl --yes update
  [ "$status" -eq 0 ]
  assert_contains "$output" "running the first run"
  [ "$(st .last_result)" = ok ]
}

@test "first run on an installed machine is refused" {
  run radioctl first-run
  [ "$status" -eq 1 ]
  assert_contains "$output" "a release is installed already"
}

# --------------------------------------------------------------------- status

@test "status shows the release, air state and pending maintenance" {
  jq '.pending_maintenance = ["liquidsoap image a -> b"]' "$ROOT/state.json" >"$ROOT/s" && mv "$ROOT/s" "$ROOT/state.json"
  run radioctl status
  [ "$status" -eq 0 ]
  assert_contains "$output" "running   1.0.0"
  assert_contains "$output" "release.env 1.0.1"
  assert_contains "$output" "broadcast connected"
  assert_contains "$output" "control link true, output connected, queued 3"
  assert_contains "$output" "liquidsoap image a -> b"
  assert_contains "$output" "$ROOT/media ok"
}

@test "status reports a missing media mount" {
  rmdir "$ROOT/media"
  run radioctl status
  [ "$status" -eq 0 ]
  assert_contains "$output" "MISSING: $ROOT/media is not mounted"
}

# ---------------------------------------------------------- dry run, lock, misc

@test "--dry-run changes nothing and prints the steps" {
  local before
  before=$(sha256sum "$ROOT/state.json" "$ROOT/runtime/applied.env")
  run radioctl --dry-run update
  [ "$status" -eq 0 ]
  assert_contains "$output" "DRY RUN: nothing is changed."
  assert_contains "$output" "[dry-run] pg_dump -Fc"
  assert_contains "$output" "[dry-run] migrate target-compat; migrate up"
  assert_contains "$output" "[dry-run] docker compose up -d --no-deps backend"
  assert_contains "$output" "nothing was changed"
  [ "$before" = "$(sha256sum "$ROOT/state.json" "$ROOT/runtime/applied.env")" ]
  run events
  [ -z "$output" ]
  [ ! -d "$ROOT/backups/update" ] || [ -z "$(ls "$ROOT/backups/update")" ]
}

@test "--dry-run of every changing command changes nothing" {
  local before
  write_state 1.0.1 "$D_B101" 1.0.1 "$D_F101" "{\"backend_tag\":\"1.0.0\",\"backend_digest\":\"$D_B100\",\"frontend_tag\":\"1.0.0\",\"frontend_digest\":\"$D_F100\"}"
  write_applied 1.0.1 "$D_B101" 1.0.1 "$D_F101"
  before=$(sha256sum "$ROOT/state.json")
  stub_out compose_config '{"services":{"liquidsoap":{"image":"savonet/liquidsoap:v2.4.7"},"db":{"image":"postgres:17.11"}}}'
  run radioctl --dry-run maintenance
  [ "$status" -eq 0 ]
  run radioctl --dry-run rollback
  [ "$status" -eq 0 ]
  run radioctl --dry-run cutover --undo
  [ "$status" -eq 0 ]
  run radioctl --dry-run restore "$ROOT/release.env"
  [ "$status" -eq 0 ]
  run events
  [ -z "$output" ]
  [ "$before" = "$(sha256sum "$ROOT/state.json")" ]
}

@test "the lock blocks a second run" {
  exec 8>>"$ROOT/state.lock"
  flock -n 8
  run radioctl update
  exec 8>&-
  [ "$status" -eq 1 ]
  assert_contains "$output" "another radioctl is running"
  run events
  [ -z "$output" ]
}

@test "compose passes through with the production env files" {
  run radioctl compose ps
  [ "$status" -eq 0 ]
  run calls
  assert_contains "$output" "--env-file $ROOT/.env --env-file $ROOT/runtime/applied.env --env-file $ROOT/runtime/network.env --profile monitoring ps"
}

@test "logs shows the last run log" {
  run radioctl update
  run radioctl logs
  [ "$status" -eq 0 ]
  assert_contains "$output" "logs/update-"
  assert_contains "$output" "Installed 1.0.1"
}

@test "backup and restore-drill are D6" {
  run radioctl backup
  [ "$status" -eq 1 ]
  assert_contains "$output" "Phase D6"
}

@test "an unknown command prints the usage" {
  run radioctl frobnicate
  [ "$status" -eq 2 ]
  assert_contains "$output" "Usage: radioctl"
}
