#!/usr/bin/env bats
# radioctl update: the happy path and every failure path of plan 7.3.

load helpers

setup() { common_setup; }

@test "happy path: release.env is installed, migrated, recorded" {
  run radioctl update
  [ "$status" -eq 0 ]
  assert_contains "$output" "Installed 1.0.1 (was 1.0.0)"
  # Order: dump, migrate with the old backend running, then backend, frontend.
  run events
  [[ $output == *"DUMP"*"MIGRATE 1.0.1"*"UP backend 1.0.1"*"UP frontend 1.0.1"* ]]
  refute_contains "$output" "STOP backend"
  refute_contains "$output" "liquidsoap"
  refute_contains "$output" "UP db"
  [ "$(st .current.backend_tag)" = 1.0.1 ]
  [ "$(st .current.backend_digest)" = "$D_B101" ]
  [ "$(st .previous.backend_tag)" = 1.0.0 ]
  [ "$(st .last_result)" = ok ]
  [ "$(st '.history | length')" = 1 ]
  [ "$(st '.history[0].result')" = ok ]
  [ "$(st '.history[0].from')" = 1.0.0 ]
  [ "$(st '.history[0].to')" = 1.0.1 ]
  [ "$(st '.history[0].boundary')" = false ]
  [ "$(st '.history[0].restored')" = false ]
  [ "$(st '.history[0].min_app_version_before')" = 1.0.0 ]
  [ "$(st '.history[0].schema_version_before')" = 22 ]
  [ -f "$(st '.history[0].dump')" ]
  [ "$(st .last_dump)" = "$(st '.history[0].dump')" ]
  grep -q "^BACKEND_DIGEST=$D_B101$" "$ROOT/runtime/applied.env"
  grep -q "^FRONTEND_DIGEST=$D_F101$" "$ROOT/runtime/applied.env"
  ls "$ROOT"/logs/update-*.log
}

@test "the run log never contains a secret" {
  run radioctl update
  [ "$status" -eq 0 ]
  ! grep -rq -e changeme -e change-me "$ROOT/logs"
}

@test "dump failure stops the update before any change" {
  stub_rc pg_dump 1
  run radioctl update
  [ "$status" -eq 1 ]
  assert_contains "$output" "The database dump failed"
  assert_contains "$output" "Nothing was changed"
  run events
  refute_contains "$output" "MIGRATE"
  refute_contains "$output" "UP backend"
  [ "$(st .current.backend_tag)" = 1.0.0 ]
  [ -z "$(ls "$ROOT/backups/update" 2>/dev/null)" ]
}

@test "migrate exit 4 (rolled back): plain message, old images kept, no restore, history" {
  stub_rc migrate_up 4
  run radioctl update
  [ "$status" -eq 1 ]
  assert_undone 1.0.1 1.0.0
  run events
  refute_contains "$output" "RESTORE"
  refute_contains "$output" "UP backend"
  refute_contains "$output" "STOP backend"
  [ "$(st .current.backend_tag)" = 1.0.0 ]
  [ "$(st .last_result)" = failed ]
  [ "$(st '.history[-1].result')" = rolled_back ]
  [ "$(st '.history[-1].restored')" = false ]
  [ "$(st '.history[-1].to')" = 1.0.1 ]
  grep -q "^BACKEND_TAG=1.0.0$" "$ROOT/runtime/applied.env"
}

@test "migrate exit 5 (dirty): restores the pre-update dump without a prompt, restarts the old backend" {
  stub_rc migrate_up 5
  run radioctl update </dev/null
  [ "$status" -eq 1 ]
  assert_undone 1.0.1 1.0.0
  run events
  [[ $output == *"DUMP"*"MIGRATE 1.0.1"*"STOP backend"*"RESTORE"*"UP backend 1.0.0"* ]]
  grep -q "PGDMP fake dump" "$STUB_DIR/restored_from"
  [ "$(st '.history[-1].restored')" = true ]
  [ "$(st '.history[-1].result')" = rolled_back ]
  [ "$(st .current.backend_tag)" = 1.0.0 ]
}

@test "migrate exit 5 with a failed restore: the old backend still starts, the message says so" {
  stub_rc migrate_up 5
  stub_rc pg_restore 1
  run radioctl update
  [ "$status" -eq 1 ]
  assert_contains "$output" "the database could not be restored automatically; the developer must check it"
  assert_contains "$output" "Broadcasting continues on 1.0.0"
  run events
  [[ $output == *"RESTORE"*"UP backend 1.0.0"* ]]
  [ "$(st '.history[-1].restored')" = false ]
  [ "$(st '.history[-1].result')" = failed ]
}

@test "a migrate that did not start (exit 1) aborts without restore" {
  stub_rc migrate_up 1
  run radioctl update
  [ "$status" -eq 1 ]
  assert_undone 1.0.1 1.0.0
  assert_contains "$output" "the database was not changed"
  run events
  refute_contains "$output" "RESTORE"
  refute_contains "$output" "UP backend"
}

@test "target-compat above the running release: old backend stopped before migrating, restarted on exit 4" {
  echo 1.0.1 >"$STUB_DIR/target_compat"
  stub_rc migrate_up 4
  run radioctl update
  [ "$status" -eq 1 ]
  assert_undone 1.0.1 1.0.0
  run events
  [[ $output == *"STOP backend"*"MIGRATE 1.0.1"*"UP backend 1.0.0"* ]]
  refute_contains "$output" "RESTORE"
}

@test "target-compat above the running release: the update succeeds with the backend stopped first" {
  echo 1.0.1 >"$STUB_DIR/target_compat"
  run radioctl update
  [ "$status" -eq 0 ]
  run events
  [[ $output == *"STOP backend"*"MIGRATE 1.0.1"*"UP backend 1.0.1"* ]]
}

@test "a database already dirty at preflight stops with the plain message" {
  stub_out db_version "21 t"
  run radioctl update
  [ "$status" -eq 1 ]
  assert_contains "$output" "Update to 1.0.1 failed and was not started: the database is dirty (schema version 21). Broadcasting continues on 1.0.0. Send the log logs/"
  run calls
  refute_contains "$output" " pull"
  run events
  refute_contains "$output" "DUMP"
  [ "$(st '.history[-1].result')" = failed ]
}

@test "health gate timeout rolls back by digest" {
  api_rc "readyz@1.0.1" 22
  run radioctl update
  [ "$status" -eq 1 ]
  assert_undone 1.0.1 1.0.0
  run events
  [[ $output == *"UP backend 1.0.1"*"UP backend 1.0.0"*"UP frontend 1.0.0"* ]]
  grep -q "^BACKEND_DIGEST=$D_B100$" "$ROOT/runtime/applied.env"
  grep -q "^FRONTEND_DIGEST=$D_F100$" "$ROOT/runtime/applied.env"
  [ "$(st .current.backend_tag)" = 1.0.0 ]
  [ "$(st '.history[-1].result')" = rolled_back ]
  # The gate waited at least 60 s of (fake) time.
  (($(cat "$STUB_DIR/clock") - CLOCK_OK >= 60))
}

@test "after the cut-over the health gate needs the control link and queued items" {
  api "api_playout_status@1.0.1" '{"control_link":{"connected":false},"queued":[]}'
  run radioctl update
  [ "$status" -eq 1 ]
  assert_undone 1.0.1 1.0.0
}

@test "before the cut-over the health gate needs /readyz only" {
  write_state 1.0.0 "$D_B100" 1.0.0 "$D_F100" null false
  api "api_playout_status@1.0.1" '{"control_link":{"connected":false},"queued":[]}'
  run radioctl update
  [ "$status" -eq 0 ]
  assert_contains "$output" "air check skipped"
}

@test "frontend failure rolls back" {
  echo unhealthy >"$STUB_DIR/health_frontend"
  run radioctl update
  [ "$status" -eq 1 ]
  assert_undone 1.0.1 1.0.0
  run events
  [[ $output == *"UP frontend 1.0.1"*"UP backend 1.0.0"*"UP frontend 1.0.0"* ]]
}

@test "monitoring failure is only a warning" {
  stub_rc grafana_role 1
  run radioctl update
  [ "$status" -eq 0 ]
  assert_contains "$output" "WARNING: monitoring: failed (grafana-role)"
  [ "$(st .current.backend_tag)" = 1.0.1 ]
}

@test "a changed Loki config hash recreates loki only" {
  echo "# changed" >>"$ROOT/config/loki/loki.yaml"
  run radioctl update
  [ "$status" -eq 0 ]
  run calls
  assert_contains "$output" "up -d --no-deps --force-recreate loki"
  refute_contains "$output" "--force-recreate alloy"
  [ "$(st .applied.config_sha256.loki)" = "$(config_hash loki)" ]
}

@test "a changed Liquidsoap image becomes pending; liquidsoap is not restarted" {
  stub_out compose_config '{"services":{"liquidsoap":{"image":"savonet/liquidsoap:v2.4.7"},"db":{"image":"postgres:17.11"}}}'
  run radioctl update
  [ "$status" -eq 0 ]
  assert_contains "$output" "pending: liquidsoap image savonet/liquidsoap:v2.4.6 -> savonet/liquidsoap:v2.4.7"
  assert_contains "$output" "Run 'update.bat maintenance'"
  run calls
  refute_contains "$output" "liquidsoap"$'\n'
  run events
  refute_contains "$output" "liquidsoap"
  [ "$(st '.pending_maintenance[0]')" = "liquidsoap image savonet/liquidsoap:v2.4.6 -> savonet/liquidsoap:v2.4.7" ]
  [ "$(st .applied.liquidsoap_image)" = savonet/liquidsoap:v2.4.6 ]
}

@test "a changed radio.liq (contract) is reported, not applied" {
  sed -i 's/^# radio-atlantida-contract: 1$/# radio-atlantida-contract: 2/' "$ROOT/config/liquidsoap/radio.liq"
  run radioctl update
  [ "$status" -eq 0 ]
  assert_contains "$output" "pending: liquidsoap script contract 1 -> 2"
  run events
  refute_contains "$output" "liquidsoap"
}

@test "a changed db image becomes pending; db is not restarted" {
  stub_out compose_config '{"services":{"liquidsoap":{"image":"savonet/liquidsoap:v2.4.6","command":["/etc/liquidsoap/radio.liq"]},"db":{"image":"postgres:17.12"}}}'
  run radioctl update
  [ "$status" -eq 0 ]
  assert_contains "$output" "pending: db image postgres:17.11 -> postgres:17.12"
  run events
  refute_contains "$output" "UP db"
}

@test "the same release again: nothing is restarted, no dump" {
  write_state 1.0.1 "$D_B101" 1.0.1 "$D_F101"
  write_applied 1.0.1 "$D_B101" 1.0.1 "$D_F101"
  run radioctl update
  [ "$status" -eq 0 ]
  assert_contains "$output" "Release 1.0.1 is already running."
  run events
  refute_contains "$output" "DUMP"
  refute_contains "$output" "UP backend"
}

@test "history gets one entry per install" {
  run radioctl update
  [ "$status" -eq 0 ]
  run radioctl update 1.0.2
  [ "$status" -eq 0 ]
  [ "$(st '.history | length')" = 2 ]
  [ "$(st '.history[1].from')" = 1.0.1 ]
  [ "$(st '.history[1].to')" = 1.0.2 ]
  [ "$(st .previous.backend_tag)" = 1.0.1 ]
}

@test "a contract migration raising min_app_version marks the entry as a boundary" {
  echo 1.0.1 >"$STUB_DIR/db_min_app_after.out"
  run radioctl update
  [ "$status" -eq 0 ]
  [ "$(st '.history[-1].min_app_version_before')" = 1.0.0 ]
  [ "$(st '.history[-1].min_app_version_after')" = 1.0.1 ]
  [ "$(st '.history[-1].boundary')" = true ]
}

@test "retention keeps the newest update dumps, the recorded dump, and boundary dumps" {
  local d=$ROOT/backups/update i
  mkdir -p "$d"
  for i in $(seq -w 1 20); do : >"$d/db-2023-10-${i}T000000Z.dump"; done
  jq --arg b1 "$d/db-2023-10-01T000000Z.dump" --arg b2 "$d/db-2023-10-02T000000Z.dump" \
    --arg b3 "$d/db-2023-10-03T000000Z.dump" --arg b4 "$d/db-2023-10-04T000000Z.dump" '
    .history = [
      {dump: $b1, boundary: true}, {dump: $b2, boundary: true},
      {dump: $b3, boundary: true}, {dump: $b4, boundary: true}]' "$ROOT/state.json" >"$ROOT/s" && mv "$ROOT/s" "$ROOT/state.json"
  run radioctl update
  [ "$status" -eq 0 ]
  # 14 newest (the new dump and 13 old) + the last 3 boundary dumps (2..4).
  [ "$(find "$d" -name '*.dump' | wc -l)" -eq 17 ]
  [ ! -e "$d/db-2023-10-01T000000Z.dump" ]
  [ -e "$d/db-2023-10-02T000000Z.dump" ]
  [ -e "$d/db-2023-10-04T000000Z.dump" ]
  [ ! -e "$d/db-2023-10-05T000000Z.dump" ]
  [ -e "$d/db-2023-10-08T000000Z.dump" ]
  [ -e "$(st .last_dump)" ]
}

@test "update fetches the repository and stops when git pull fails" {
  mkdir "$ROOT/.git"
  stub_rc git_pull 1
  run radioctl update
  [ "$status" -eq 1 ]
  assert_contains "$output" "git pull --ff-only failed"
  run calls
  assert_contains "$output" "git -C $ROOT pull --ff-only"
}

@test "--no-fetch skips git" {
  mkdir "$ROOT/.git"
  run radioctl --no-fetch update
  [ "$status" -eq 0 ]
  run calls
  refute_contains "$output" "pull --ff-only"
}
