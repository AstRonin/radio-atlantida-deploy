#!/usr/bin/env bats
# radioctl: release check, compatibility, older targets, the downgrade guard
# (plan 7.3 step 3, 7.4, §10.4).

load helpers

setup() { common_setup; }

assert_nothing_changed() {
  run events
  refute_contains "$output" "DUMP"
  refute_contains "$output" "UP "
  refute_contains "$output" "STOP "
  [ "$(st .current.backend_tag)" = "${1:-1.0.0}" ]
}

@test "release.env digest mismatch stops before any change" {
  echo sha256:other >"$STUB_DIR/registry/radio-atlantida-backend:1.0.1"
  run radioctl update
  [ "$status" -eq 1 ]
  assert_contains "$output" "is sha256:other in the registry, not $D_B101"
  assert_contains "$output" "Nothing was changed"
  assert_nothing_changed
}

@test "release.env without digests stops" {
  sed -i 's/^BACKEND_DIGEST=.*/BACKEND_DIGEST=/' "$ROOT/release.env"
  run radioctl update
  [ "$status" -eq 1 ]
  assert_contains "$output" "release.env has no digest"
  assert_nothing_changed
}

@test "update <tag> with a missing image stops" {
  run radioctl update 1.0.5
  [ "$status" -eq 1 ]
  assert_contains "$output" "radio-atlantida-backend:1.0.5 was not found in the registry"
  assert_nothing_changed
}

@test "update <b> <f> with different MAJOR.MINOR stops" {
  run radioctl update 1.1.0 1.0.1
  [ "$status" -eq 1 ]
  assert_contains "$output" "backend 1.1.0 and frontend 1.0.1 differ in MAJOR.MINOR"
  assert_nothing_changed
}

@test "the frontend tag defaults to the backend tag; digests come from the registry" {
  run radioctl update 1.0.2
  [ "$status" -eq 0 ]
  [ "$(st .current.frontend_tag)" = 1.0.2 ]
  [ "$(st .current.frontend_digest)" = "$D_F102" ]
  grep -q "^FRONTEND_TAG=1.0.2$" "$ROOT/runtime/applied.env"
  run events
  assert_contains "$output" "UP frontend 1.0.2"
}

@test "separate tags of the same MAJOR.MINOR are allowed" {
  run radioctl update 1.0.2 1.0.1
  [ "$status" -eq 0 ]
  assert_contains "$output" "Installed backend 1.0.2, frontend 1.0.1"
}

@test "an install below 1.0.0 is refused" {
  echo sha256:x >"$STUB_DIR/registry/radio-atlantida-backend:0.9.0"
  run radioctl update 0.9.0
  [ "$status" -eq 1 ]
  assert_contains "$output" "0.9.0 is below 1.0.0"
  assert_nothing_changed
}

@test "a tag that is not X.Y.Z is refused" {
  run radioctl update v1.0.1
  [ "$status" -eq 1 ]
  assert_contains "$output" "'v1.0.1' is not a release tag"
}

@test "a target below the script's min-backend is refused" {
  sed -i 's/^# min-backend: .*/# min-backend: 1.0.2/' "$ROOT/config/liquidsoap/radio.liq"
  run radioctl update 1.0.1
  [ "$status" -eq 1 ]
  assert_contains "$output" "backend 1.0.1 is below 1.0.2, the min-backend of config/liquidsoap/radio.liq"
  assert_nothing_changed
}

@test "a newer target migrates, an older one does not" {
  write_state 1.0.1 "$D_B101" 1.0.1 "$D_F101"
  write_applied 1.0.1 "$D_B101" 1.0.1 "$D_F101"
  run radioctl update 1.0.0
  [ "$status" -eq 0 ]
  assert_contains "$output" "older release: no migration"
  run events
  refute_contains "$output" "MIGRATE"
  [[ $output == *"DUMP"*"UP backend 1.0.0"*"UP frontend 1.0.0"* ]]
  [ "$(st .current.backend_tag)" = 1.0.0 ]
  [ "$(st .previous.backend_tag)" = 1.0.1 ]
  assert_contains "$(cat "$ROOT"/logs/update-*.log)" "direction: older"
}

@test "a missing schema_compat table counts as 1.0.0" {
  write_state 1.0.1 "$D_B101" 1.0.1 "$D_F101"
  write_applied 1.0.1 "$D_B101" 1.0.1 "$D_F101"
  stub_out db_has_compat f
  stub_out db_min_app 9.9.9
  run radioctl update 1.0.0
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$ROOT"/logs/update-*.log)" "min_app_version=1.0.0"
  [ "$(st '.history[-1].min_app_version_before')" = 1.0.0 ]
}

boundary_history() {
  local d=$ROOT/backups/update
  mkdir -p "$d"
  echo old-dump-1 >"$d/db-2023-10-01T100000Z.dump"
  echo old-dump-2 >"$d/db-2023-10-05T100000Z.dump"
  jq --arg d1 "$d/db-2023-10-01T100000Z.dump" --arg d2 "$d/db-2023-10-05T100000Z.dump" '
    .history = [
      {utc: "2023-10-01T10:00:00Z", from: "1.0.0", to: "1.0.1", dump: $d1,
       min_app_version_before: "1.0.0", min_app_version_after: "1.0.0", boundary: false},
      {utc: "2023-10-05T10:00:00Z", from: "1.0.1", to: "1.0.2", dump: $d2,
       min_app_version_before: "1.0.0", min_app_version_after: "1.0.2", boundary: true}]' \
    "$ROOT/state.json" >"$ROOT/s"
  mv "$ROOT/s" "$ROOT/state.json"
}

@test "an older target below min_app_version is refused and the boundary dumps are offered" {
  write_state 1.0.2 "$D_B102" 1.0.2 "$D_F102"
  write_applied 1.0.2 "$D_B102" 1.0.2 "$D_F102"
  boundary_history
  stub_out db_min_app 1.0.2
  run radioctl update 1.0.1 <<<"no"
  [ "$status" -eq 1 ]
  assert_contains "$output" "Refused: the database needs at least release 1.0.2"
  assert_contains "$output" "db-2023-10-05T100000Z.dump  taken 2023-10-05T10:00:00Z before the update from 1.0.1"
  assert_contains "$output" "db-2023-10-01T100000Z.dump  taken 2023-10-01T10:00:00Z"
  assert_contains "$output" "loses every change since 2023-10-05T10:00:00Z"
  assert_contains "$output" "Type RESTORE to continue"
  assert_contains "$output" "Not confirmed."
  assert_nothing_changed 1.0.2
  run events
  refute_contains "$output" "RESTORE"
}

@test "--yes does not answer the typed RESTORE" {
  write_state 1.0.2 "$D_B102" 1.0.2 "$D_F102"
  write_applied 1.0.2 "$D_B102" 1.0.2 "$D_F102"
  boundary_history
  stub_out db_min_app 1.0.2
  run radioctl --yes update 1.0.1 </dev/null
  [ "$status" -eq 1 ]
  assert_nothing_changed 1.0.2
}

@test "typed RESTORE restores the boundary dump and installs the older target" {
  write_state 1.0.2 "$D_B102" 1.0.2 "$D_F102"
  write_applied 1.0.2 "$D_B102" 1.0.2 "$D_F102"
  boundary_history
  stub_out db_min_app 1.0.2
  run radioctl update 1.0.1 <<<"RESTORE"
  [ "$status" -eq 0 ]
  grep -q old-dump-2 "$STUB_DIR/restored_from"
  run events
  # Safety dump first, then the restore with the backend stopped, then the
  # target (the dump is from 1.0.1 itself: no migration).
  [[ $output == *"DUMP"*"STOP backend"*"RESTORE"*"UP backend 1.0.1"*"UP frontend 1.0.1"* ]]
  refute_contains "$output" "MIGRATE"
  [ "$(st .current.backend_tag)" = 1.0.1 ]
  [ "$(st '.history[-1].kind')" = restore-install ]
  [ "$(st '.history[-1].restored')" = true ]
}

@test "no restore point for the older target: refused" {
  write_state 1.0.2 "$D_B102" 1.0.2 "$D_F102"
  write_applied 1.0.2 "$D_B102" 1.0.2 "$D_F102"
  stub_out db_min_app 1.0.2
  run radioctl update 1.0.1
  [ "$status" -eq 1 ]
  assert_contains "$output" "No dump taken while the database still accepted 1.0.1 is available"
  assert_nothing_changed 1.0.2
}

@test "rollback installs the previous release by digest" {
  run radioctl update
  [ "$status" -eq 0 ]
  run radioctl rollback
  [ "$status" -eq 0 ]
  [ "$(st .current.backend_tag)" = 1.0.0 ]
  [ "$(st .current.backend_digest)" = "$D_B100" ]
  [ "$(st '.history[-1].kind')" = rollback ]
  grep -q "^BACKEND_DIGEST=$D_B100$" "$ROOT/runtime/applied.env"
  assert_contains "$output" "differs from release.env (1.0.1)"
}

@test "rollback without a previous release is refused" {
  write_state 1.0.0 "$D_B100" 1.0.0 "$D_F100"
  run radioctl rollback
  [ "$status" -eq 1 ]
  assert_contains "$output" "no previous release is recorded"
}

@test "a Docker version different from versions.env stops" {
  printf 'DOCKER_CE_VERSION=5:28.1.1-1~ubuntu.24.04~noble\n' >"$ROOT/install/versions.env"
  run radioctl update
  [ "$status" -eq 1 ]
  assert_contains "$output" "Docker Engine is 28.0.1, install/versions.env pins 28.1.1; run install.bat"
  assert_nothing_changed
}

@test "a Compose version different from versions.env stops" {
  printf 'DOCKER_COMPOSE_PLUGIN_VERSION=2.35.1-1~ubuntu.24.04~noble\n' >"$ROOT/install/versions.env"
  run radioctl update
  [ "$status" -eq 1 ]
  assert_contains "$output" "Docker Compose is 2.34.0, install/versions.env pins 2.35.1"
}

@test "matching pinned versions pass" {
  printf 'DOCKER_CE_VERSION=5:28.0.1-1~ubuntu.24.04~noble\nDOCKER_COMPOSE_PLUGIN_VERSION=2.34.0-1~ubuntu.24.04~noble\n' >"$ROOT/install/versions.env"
  run radioctl update
  [ "$status" -eq 0 ]
}

@test "a missing .env variable is named, its value never shown" {
  sed -i 's/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=/' "$ROOT/.env"
  run radioctl update
  [ "$status" -eq 1 ]
  assert_contains "$output" ".env lacks: POSTGRES_PASSWORD"
}

@test "monitoring on requires the Grafana passwords" {
  sed -i 's/^GRAFANA_DB_PASSWORD=.*/GRAFANA_DB_PASSWORD=/' "$ROOT/.env"
  run radioctl update
  [ "$status" -eq 1 ]
  assert_contains "$output" ".env lacks: GRAFANA_DB_PASSWORD"
}
