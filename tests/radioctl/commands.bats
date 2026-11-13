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

# liquidsoap_env <ICECAST_SOURCE_PASSWORD>: the rendered compose config
# with that liquidsoap environment.
liquidsoap_env() {
  stub_out compose_config "$(jq -cn --arg pw "$1" '{services: {liquidsoap: {image: "savonet/liquidsoap:v2.4.6",
    environment: {TZ: "UTC", ICECAST_SOURCE_PASSWORD: $pw, LIQUIDSOAP_CONTROL_PASSWORD: "ctl"}},
    db: {image: "postgres:17.11"}, backend: {}, frontend: {}}}')"
}

@test "a changed source password in .env is a pending liquidsoap change; maintenance applies it" {
  liquidsoap_env old-secret-1
  write_state 1.0.0 "$D_B100" 1.0.0 "$D_F100"
  # A state.json from before the env hash: recorded while nothing changed.
  run radioctl maintenance
  [ "$status" -eq 0 ]
  assert_contains "$output" "Nothing is pending."
  [ -n "$(st '.applied.liquidsoap_env_sha256 // empty')" ]
  liquidsoap_env new-secret-2
  run radioctl maintenance <<<"MAINTENANCE"
  [ "$status" -eq 0 ]
  assert_contains "$output" "liquidsoap environment changed (.env values it reads at start, e.g. ICECAST_SOURCE_PASSWORD)"
  refute_contains "$output" "service definition changed"
  refute_contains "$output" "new-secret-2"
  ! grep -rq -e new-secret-2 -e old-secret-1 "$ROOT/logs" "$ROOT/state.json"
  run calls
  assert_contains "$output" "up -d --no-deps --force-recreate liquidsoap"
  run radioctl maintenance
  assert_contains "$output" "Nothing is pending."
}

@test "update lists a changed source password as pending maintenance" {
  liquidsoap_env old-secret-1
  write_state 1.0.0 "$D_B100" 1.0.0 "$D_F100"
  run radioctl maintenance
  liquidsoap_env new-secret-2
  run radioctl --yes update
  [ "$status" -eq 0 ]
  assert_contains "$output" "pending: liquidsoap environment changed"
  [ "$(st '.pending_maintenance[0]')" = "liquidsoap environment changed (.env values it reads at start, e.g. ICECAST_SOURCE_PASSWORD)" ]
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

cutover_ready() {
  write_state 1.0.0 "$D_B100" 1.0.0 "$D_F100" null false
  api api_track-plan "$(jq -n '{items: [range(24) | {items: [{}]}]}')"
}

# stream_api <host> <port> <mount> <tls>: the panel's stream settings.
stream_api() {
  api api_settings "$(jq -n --arg h "$1" --argjson p "$2" --arg m "$3" --argjson t "$4" '{items: [
    {key: "playout.emergency_playlist_id", value: 7},
    {key: "stream.icecast_host", value: $h}, {key: "stream.icecast_port", value: $p},
    {key: "stream.mount", value: $m}, {key: "stream.icecast_tls", value: $t},
    {key: "stream.codec", value: "aac"}, {key: "stream.bitrate_kbps", value: 128},
    {key: "stream.sample_rate_hz", value: 48000}, {key: "stream.channels", value: 1}]}')"
}

@test "cutover with another server shows the output and passes after confirmation" {
  cutover_ready
  stream_api radio.other.example 8100 /live false
  run radioctl cutover <<<"no"
  [ "$status" -eq 1 ]
  assert_contains "$output" "server    radio.other.example, port 8100, TLS off"
  assert_contains "$output" "mount     /live"
  assert_contains "$output" "format    aac, 128 kbps, 48000 Hz, 1 channel(s)"
  assert_contains "$output" "source    http://radio.other.example:8100/live"
  assert_contains "$output" "source password (ICECAST_SOURCE_PASSWORD): set"
  assert_contains "$output" "Start liquidsoap and stream to http://radio.other.example:8100/live with these settings now?"
  run events
  refute_contains "$output" "liquidsoap"
  run radioctl cutover <<<"CUTOVER"
  [ "$status" -eq 0 ]
  assert_contains "$output" "Cut-over done"
  refute_contains "$output" "teploe"
  refute_contains "$output" "$SOURCE_PW"
  ! grep -rq -e "$SOURCE_PW" "$ROOT/logs" "$ROOT/state.json"
  run events
  assert_contains "$output" "UP liquidsoap"
}

@test "the listen hint follows the current settings" {
  cutover_ready
  stream_api icecast.test 8443 /dry true
  run radioctl cutover <<<"CUTOVER"
  [ "$status" -eq 0 ]
  assert_contains "$output" "The source streams to https://icecast.test:8443/dry."
  assert_contains "$output" "https://icecast.test:8443/status-json.xsl (listenurl of /dry)"
  refute_contains "$output" "teploe"
}

@test "cutover refuses an empty or invalid server" {
  cutover_ready
  stream_api "" 8001 /atlantida true
  run radioctl cutover <<<"CUTOVER"
  [ "$status" -eq 1 ]
  assert_contains "$output" "not ready: stream.icecast_host is not set"
  stream_api "bad host" 0 atlantida true
  run radioctl cutover <<<"CUTOVER"
  [ "$status" -eq 1 ]
  assert_contains "$output" "not ready: stream.icecast_host 'bad host' is not a host name or IP address"
  assert_contains "$output" "not ready: stream.icecast_port '0' is not a port"
  assert_contains "$output" "not ready: stream.mount 'atlantida' is not a mount"
  stream_api icecast 8000 /radio false
  run radioctl cutover <<<"CUTOVER"
  [ "$status" -eq 1 ]
  assert_contains "$output" "stream.icecast_host is 'icecast', the code default"
  api api_settings '{"items":[{"key":"playout.emergency_playlist_id","value":7}]}'
  run radioctl cutover <<<"CUTOVER"
  [ "$status" -eq 1 ]
  assert_contains "$output" "not ready: stream.icecast_port is not set"
  assert_contains "$output" "not ready: stream.mount is not set"
  run events
  refute_contains "$output" "liquidsoap"
  [ -z "$(st '.cutover_utc // empty')" ]
}

@test "cutover refuses a missing source password" {
  cutover_ready
  sed -i 's|^ICECAST_SOURCE_PASSWORD=.*|ICECAST_SOURCE_PASSWORD=change-me|' "$ROOT/.env"
  run radioctl cutover <<<"CUTOVER"
  [ "$status" -eq 1 ]
  assert_contains "$output" "not ready: the Icecast source password is not set: ICECAST_SOURCE_PASSWORD in .env"
  sed -i 's|^ICECAST_SOURCE_PASSWORD=.*|ICECAST_SOURCE_PASSWORD=|' "$ROOT/.env"
  run radioctl cutover <<<"CUTOVER"
  [ "$status" -eq 1 ]
  assert_contains "$output" ".env lacks: ICECAST_SOURCE_PASSWORD"
  sed -i "s|^ICECAST_SOURCE_PASSWORD=.*|ICECAST_SOURCE_PASSWORD=$SOURCE_PW|" "$ROOT/.env"
  api api_settings_secrets '{"items":[{"name":"ICECAST_SOURCE_PASSWORD","group":"stream","is_set":false}]}'
  run radioctl cutover <<<"CUTOVER"
  [ "$status" -eq 1 ]
  assert_contains "$output" "not ready: the backend reports ICECAST_SOURCE_PASSWORD as not set"
  run events
  refute_contains "$output" "liquidsoap"
}

@test "RADIOCTL_STREAM_OVERRIDE must be a JSON object" {
  RADIOCTL_STREAM_OVERRIDE='[1]' run radioctl status
  [ "$status" -eq 2 ]
  assert_contains "$output" "RADIOCTL_STREAM_OVERRIDE is not a JSON object"
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

@test "first run: .env written, stack started without liquidsoap, no air check, no pre-update dump" {
  first_run_setup
  run radioctl --yes first-run --media-root "$ROOT/media" <<<$'ghuser\nghtoken\nicepass'
  [ "$status" -eq 0 ]
  assert_contains "$output" "First run done: 1.0.1 is running"
  refute_contains "$output" "Air check"
  refute_contains "$output" "ghtoken"
  refute_contains "$output" "icepass"
  run events
  # The only dump is the first daily backup, after the stack is up (6.8 step 7).
  [[ $output == *"UP db"*"MIGRATE 1.0.1"*"UP backend 1.0.1"*"UP frontend 1.0.1"*"DUMP" ]]
  refute_contains "$output" "liquidsoap"
  [ "$(grep -c DUMP <<<"$output")" -eq 1 ]
  [ ! -e "$ROOT/backups/update" ]
  [ "$(stat -c %a "$ROOT/.env")" = 600 ]
  grep -q '^GHCR_READ_TOKEN=ghtoken$' "$ROOT/.env"
  grep -q "^MEDIA_ROOT=$ROOT/media$" "$ROOT/.env"
  ! grep -q '^POSTGRES_PASSWORD=changeme$' "$ROOT/.env"
  [ "$(st .current.backend_tag)" = 1.0.1 ]
  [ "$(st .last_result)" = ok ]
  [ "$(st .applied.liquidsoap_image)" = savonet/liquidsoap:v2.4.6 ]
  # The stream settings are exactly config/stream-defaults.json.
  [ "$(jq -cS .values "$STUB_DIR/patch_body")" = "$(jq -cS . "$ROOT/config/stream-defaults.json")" ]
  ! grep -rq -e ghtoken -e icepass "$ROOT/logs"
}

@test "first run proposes config/stream-defaults.json, with the dry-run overlay" {
  first_run_setup
  jq '."stream.icecast_host" = "moved.example.net" | ."stream.icecast_port" = 9000' \
    "$REPO/config/stream-defaults.json" >"$ROOT/config/stream-defaults.json"
  run radioctl --yes first-run <<<$'ghuser\nghtoken\nicepass'
  [ "$status" -eq 0 ]
  assert_contains "$output" "stream.icecast_host = moved.example.net"
  assert_contains "$output" "Save these stream settings? yes (--yes)"
  [ "$(jq -r '.values["stream.icecast_host"]' "$STUB_DIR/patch_body")" = moved.example.net ]
  [ "$(jq -r '.values["stream.icecast_port"]' "$STUB_DIR/patch_body")" = 9000 ]
  [ "$(jq -r '.values["stream.bitrate_kbps"]' "$STUB_DIR/patch_body")" = 160 ]

  first_run_setup
  rm -f "$STUB_DIR/patch_body"
  RADIOCTL_STREAM_OVERRIDE='{"stream.icecast_host":"icecast.test","stream.icecast_port":8443}' \
    run radioctl --yes first-run <<<$'ghuser\nghtoken\nicepass'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.values["stream.icecast_host"]' "$STUB_DIR/patch_body")" = icecast.test ]
  [ "$(jq -r '.values["stream.icecast_port"]' "$STUB_DIR/patch_body")" = 8443 ]
  [ "$(jq -r '.values["stream.mount"]' "$STUB_DIR/patch_body")" = "$(jq -r '."stream.mount"' "$ROOT/config/stream-defaults.json")" ]
}

@test "first run: an edited server is sent in the PATCH" {
  first_run_setup
  # Secrets, then: edit; host (an invalid one first), port, mount kept, TLS off; save.
  run radioctl first-run <<<$'ghuser\nghtoken\nicepass\ne\nbad host!\nnew.example.org\n8100\n\nfalse\ny'
  [ "$status" -eq 0 ]
  assert_contains "$output" "must be a host name or an IP address"
  assert_contains "$output" "stream.icecast_host = new.example.org"
  [ "$(jq -r '.values["stream.icecast_host"]' "$STUB_DIR/patch_body")" = new.example.org ]
  [ "$(jq '.values["stream.icecast_port"]' "$STUB_DIR/patch_body")" = 8100 ]
  [ "$(jq '.values["stream.icecast_tls"]' "$STUB_DIR/patch_body")" = false ]
  [ "$(jq -r '.values["stream.mount"]' "$STUB_DIR/patch_body")" = "$(jq -r '."stream.mount"' "$ROOT/config/stream-defaults.json")" ]
  [ "$(jq -r '.values["stream.codec"]' "$STUB_DIR/patch_body")" = mp3 ]
}

@test "first run: n leaves the stream settings to the panel" {
  first_run_setup
  rm -f "$STUB_DIR/patch_body"
  run radioctl first-run <<<$'ghuser\nghtoken\nicepass\nn'
  [ "$status" -eq 0 ]
  assert_contains "$output" "not saved; set them in the panel"
  [ ! -f "$STUB_DIR/patch_body" ]
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
  run radioctl status
  [ "$status" -eq 0 ]
  assert_contains "$output" "running   1.0.0"
  assert_contains "$output" "release.env 1.0.1"
  assert_contains "$output" "broadcast connected"
  assert_contains "$output" "control link true, output connected, queued 3"
  [[ $output == *"Pending maintenance"$'\n'"    none"* ]]
  assert_contains "$output" "$ROOT/media ok"
  local re='[0-9]+% free, [0-9]+\.[0-9] GB'
  [[ $output =~ $re ]]
}

@test "status compares pending maintenance now, without an update" {
  local before
  before=$(sha256sum "$ROOT/state.json")
  printf '# a changed comment\n' >>"$ROOT/config/liquidsoap/radio.liq"
  run radioctl status
  [ "$status" -eq 0 ]
  assert_contains "$output" "liquidsoap script config/liquidsoap/radio.liq changed"
  # Read-only: the recorded list is not rewritten.
  [ "$before" = "$(sha256sum "$ROOT/state.json")" ]
}

@test "status falls back to the recorded pending maintenance when compose does not answer" {
  jq '.pending_maintenance = ["liquidsoap image a -> b"]' "$ROOT/state.json" >"$ROOT/s" && mv "$ROOT/s" "$ROOT/state.json"
  stub_rc compose_config 1
  run radioctl status
  [ "$status" -eq 0 ]
  assert_contains "$output" "liquidsoap image a -> b"
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

@test "an unknown command prints the usage" {
  run radioctl frobnicate
  [ "$status" -eq 2 ]
  assert_contains "$output" "Usage: radioctl"
}
