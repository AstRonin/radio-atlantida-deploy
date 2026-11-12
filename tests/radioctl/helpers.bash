# shellcheck shell=bash
# Shared setup of the bats tests of bin/radioctl (deploy-init-plan.md D7
# 9.1 item 9). Each test gets a copy of the deploy repository in
# $BATS_TEST_TMPDIR/deploy and a stub directory; docker and git are PATH
# stubs (tests/radioctl/stubs), the clock is a file, so no wait is real.

REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)

D_B100=sha256:b100000000000000000000000000000000000000000000000000000000000000
D_F100=sha256:f100000000000000000000000000000000000000000000000000000000000000
D_B101=sha256:b101000000000000000000000000000000000000000000000000000000000000
D_F101=sha256:f101000000000000000000000000000000000000000000000000000000000000
D_B102=sha256:b102000000000000000000000000000000000000000000000000000000000000
D_F102=sha256:f102000000000000000000000000000000000000000000000000000000000000
D_B110=sha256:b110000000000000000000000000000000000000000000000000000000000000

sha() { sha256sum | cut -c1-64; }

# The same hash as radioctl's config_hash.
config_hash() {
  (
    cd "$ROOT" || exit 1
    find "config/$1" -type f -print0 | LC_ALL=C sort -z | xargs -0 -r cat -- | sha
    find "config/$1" -type f | LC_ALL=C sort | sha
  ) | sha
}

stub_rc() { printf '%s\n' "$2" >"$STUB_DIR/$1.rc"; }
stub_out() { printf '%s\n' "$2" >"$STUB_DIR/$1.out"; }
api() { printf '%s\n' "$2" >"$STUB_DIR/api/$1.out"; }
api_rc() { printf '%s\n' "$2" >"$STUB_DIR/api/$1.rc"; }
events() { cat "$STUB_DIR/events.log" 2>/dev/null || true; }
calls() { cat "$STUB_DIR/calls.log" 2>/dev/null || true; }
st() { jq -r "$@" "$ROOT/state.json"; }
set_clock() { printf '%s' "$1" >"$STUB_DIR/clock"; }

# A time 13 minutes into an hour (2023-11-14T22:13:20Z): outside the
# prepush window.
CLOCK_OK=1700000000

radioctl() { "$ROOT/bin/radioctl" "$@"; }

queued() {
  local n=$1 i items=()
  for ((i = 0; i < n; i++)); do
    items+=("{\"id\":$i,\"title\":\"t$i\",\"planned_start_utc\":\"2023-11-14T22:2${i}:00Z\"}")
  done
  local IFS=,
  printf '{"control_link":{"connected":true},"output":{"state":"connected"},"queued":[%s]}' "${items[*]}"
}

# write_state <current btag> <bdigest> <ftag> <fdigest> [previous json] [cutover]
write_state() {
  local prev=${5:-null} cut=${6:-true}
  jq -n --arg bt "$1" --arg bd "$2" --arg ft "$3" --arg fd "$4" --argjson prev "$prev" \
    --arg script "$(sha <"$ROOT/config/liquidsoap/radio.liq")" \
    --arg ldef "$(jq -cS '.services.liquidsoap' "$STUB_DIR/compose_config.out" | sha)" \
    --arg ddef "$(jq -cS '.services.db' "$STUB_DIR/compose_config.out" | sha)" \
    --arg lh "$(config_hash loki)" --arg ah "$(config_hash alloy)" --arg gh "$(config_hash grafana)" \
    --argjson cut "$cut" '{
      schema: 1,
      current: {backend_tag: $bt, backend_digest: $bd, frontend_tag: $ft, frontend_digest: $fd},
      previous: $prev,
      applied: {liquidsoap_image: "savonet/liquidsoap:v2.4.6", liquidsoap_script_sha256: $script,
        liquidsoap_contract: 1, liquidsoap_definition_sha256: $ldef,
        db_image: "postgres:17.11", db_definition_sha256: $ddef,
        config_sha256: {loki: $lh, alloy: $ah, grafana: $gh}},
      pending_maintenance: [], history: [], last_result: "ok"}
      + (if $cut then {cutover_utc: "2023-11-01T03:00:00Z"} else {} end)' >"$ROOT/state.json"
}

write_applied() {
  cat >"$ROOT/runtime/applied.env" <<EOF
BACKEND_TAG=$1
BACKEND_DIGEST=$2
FRONTEND_TAG=$3
FRONTEND_DIGEST=$4
GRAFANA_URL=http://127.0.0.1:3000
EOF
  printf '%s\n' "$1" >"$STUB_DIR/running_backend"
}

common_setup() {
  ROOT=$BATS_TEST_TMPDIR/deploy
  STUB_DIR=$BATS_TEST_TMPDIR/stub
  export STUB_DIR
  mkdir -p "$ROOT"/{bin,scripts/lib,runtime,install,media,journal,backups} "$STUB_DIR"/{api,registry}
  cp "$REPO/bin/radioctl" "$ROOT/bin/"
  cp "$REPO/scripts/lib/contract.sh" "$ROOT/scripts/lib/"
  cp -R "$REPO/config" "$ROOT/"
  cp "$REPO/docker-compose.yml" "$REPO/.env.example" "$ROOT/"

  cat >"$ROOT/release.env" <<EOF
BACKEND_TAG=1.0.1
BACKEND_DIGEST=$D_B101
FRONTEND_TAG=1.0.1
FRONTEND_DIGEST=$D_F101
EOF
  sed -e "s|^MEDIA_ROOT=.*|MEDIA_ROOT=$ROOT/media|" \
    -e "s|^PLAYOUT_JOURNAL_ROOT=.*|PLAYOUT_JOURNAL_ROOT=$ROOT/journal|" \
    -e "s|^BACKUP_ROOT=.*|BACKUP_ROOT=$ROOT/backups|" \
    -e "s|^BACKUP_WINDOWS_COPY=.*|BACKUP_WINDOWS_COPY=|" \
    "$REPO/.env.example" >"$ROOT/.env"
  : >"$ROOT/install/versions.env"
  printf 'LIVE_UDP_BIND=127.0.0.1\nLIVE_PUBLIC_IPS=127.0.0.1\n' >"$ROOT/runtime/network.env"

  local r=$STUB_DIR/registry
  echo "$D_B100" >"$r/radio-atlantida-backend:1.0.0"
  echo "$D_F100" >"$r/radio-atlantida-frontend:1.0.0"
  echo "$D_B101" >"$r/radio-atlantida-backend:1.0.1"
  echo "$D_F101" >"$r/radio-atlantida-frontend:1.0.1"
  echo "$D_B102" >"$r/radio-atlantida-backend:1.0.2"
  echo "$D_F102" >"$r/radio-atlantida-frontend:1.0.2"
  echo "$D_B110" >"$r/radio-atlantida-backend:1.1.0"

  api readyz '{"status":"ok","checks":{"database":"ok"}}'
  api api_playout_status "$(queued 3)"
  api api_broadcast_status '{"state":"connected","time":"2023-11-14T22:13:20Z"}'
  api api_status_live '{"on_air":false,"time":"2023-11-14T22:13:20Z"}'
  api api_settings '{"items":[{"key":"playout.prepush_minutes","value":5},{"key":"station.timezone","value":"UTC"},
    {"key":"playout.emergency_playlist_id","value":7},
    {"key":"stream.icecast_host","value":"listen.teploe.net"},{"key":"stream.icecast_port","value":8001},
    {"key":"stream.mount","value":"/atlantida"},{"key":"stream.icecast_tls","value":true}]}'
  stub_out compose_config '{"services":{"liquidsoap":{"image":"savonet/liquidsoap:v2.4.6","command":["/etc/liquidsoap/radio.liq"]},"db":{"image":"postgres:17.11"},"backend":{},"frontend":{}}}'
  stub_rc volume_inspect 1
  set_clock "$CLOCK_OK"

  write_state 1.0.0 "$D_B100" 1.0.0 "$D_F100" \
    "{\"backend_tag\":\"0.9.9\",\"backend_digest\":\"sha256:old\",\"frontend_tag\":\"0.9.9\",\"frontend_digest\":\"sha256:oldf\"}"
  write_applied 1.0.0 "$D_B100" 1.0.0 "$D_F100"

  export PATH="$REPO/tests/radioctl/stubs:$PATH"
  export RADIOCTL_FAKE_CLOCK=$STUB_DIR/clock
  export RADIOCTL_LOCK_WAIT=0
  unset RADIOCTL_LOCK_HELD RADIOCTL_REEXEC COMPOSE_PROJECT_NAME
}

# The one plain message of every failure path ($output is set by bats run).
assert_undone() {
  # shellcheck disable=SC2154

  [[ $output == *"Update to $1 failed and was undone. Broadcasting continues on $2. Send the log logs/"*".log to the developer."* ]] || {
    echo "plain message missing; output:"
    echo "$output"
    return 1
  }
}

assert_contains() {
  [[ $1 == *"$2"* ]] || {
    printf 'expected to contain: %s\n--- actual:\n%s\n' "$2" "$1"
    return 1
  }
}

refute_contains() {
  [[ $1 != *"$2"* ]] || {
    printf 'expected not to contain: %s\n--- actual:\n%s\n' "$2" "$1"
    return 1
  }
}
