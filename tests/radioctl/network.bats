#!/usr/bin/env bats
# radioctl D4: `network` (radio-network.service: NAT vs mirrored, recreate
# only on change), `boot-check` (radio-boot-check.service), their units,
# install-units.sh, and radio-keepalive.

load helpers

setup() {
  common_setup
  export RADIOCTL_HOST_ENV=$BATS_TEST_TMPDIR/host.env
  export RADIOCTL_NET_WAIT=10
  host_mode nat
  printf '4: eth0    inet 172.20.240.2/20 brd 172.20.255.255 scope global eth0\\       valid_lft forever preferred_lft forever\n' >"$STUB_DIR/ip_addr.out"
}

host_mode() { printf 'RADIO_NETWORK_MODE=%s\n' "$1" >"$RADIOCTL_HOST_ENV"; }
net() { grep -v '^#' "$ROOT/runtime/network.env"; }
backend_created_with() {
  printf 'PATH=/usr/bin\nLIVE_PUBLIC_IPS=%s\nMEDIA_ROOT=/media\n' "$1" >"$STUB_DIR/container_env.out"
  printf '%s\n' "$2" >"$STUB_DIR/container_udp_bind.out"
}

# ---------------------------------------------------------------- network

@test "network, NAT mode: writes the eth0 address and 0.0.0.0, recreates the backend created with the old address" {
  backend_created_with 172.20.250.9 0.0.0.0
  run radioctl network
  [ "$status" -eq 0 ]
  [ "$(net)" = $'LIVE_UDP_BIND=0.0.0.0\nLIVE_PUBLIC_IPS=172.20.240.2' ]
  assert_contains "$output" "Network values (nat mode): LIVE_UDP_BIND=0.0.0.0 LIVE_PUBLIC_IPS=172.20.240.2"
  assert_contains "$output" "the backend was created with LIVE_PUBLIC_IPS=172.20.250.9 on 0.0.0.0; recreating it"
  run events
  [ "$output" = "UP backend 1.0.0" ]
  run calls
  assert_contains "$output" "ip -4 -o addr show dev eth0"
  assert_contains "$output" "--env-file $ROOT/runtime/network.env --profile monitoring up -d --no-deps backend"
  ls "$ROOT"/logs/network-*.log
}

@test "network, NAT mode: the same address does not recreate the backend" {
  backend_created_with 172.20.240.2 0.0.0.0
  run radioctl network
  [ "$status" -eq 0 ]
  assert_contains "$output" "the backend runs with these values"
  run events
  [ -z "$output" ]
  # A second boot with the same address: the file is not rewritten either.
  run radioctl network
  assert_contains "$output" "runtime/network.env unchanged"
  run events
  [ -z "$output" ]
}

@test "network, NAT mode: waits for a late eth0 address, fails when none comes" {
  backend_created_with 172.20.240.2 0.0.0.0
  echo 2 >"$STUB_DIR/ip_addr_after"
  run radioctl network
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ip ' "$STUB_DIR/calls.log")" -eq 3 ]
  rm "$STUB_DIR/ip_addr.out" "$ROOT/runtime/network.env"
  run radioctl network
  [ "$status" -eq 1 ]
  assert_contains "$output" "no IPv4 address on eth0 after 10s"
  [ ! -f "$ROOT/runtime/network.env" ]
}

@test "network, mirrored mode: writes 127.0.0.1 for both and reads no interface" {
  host_mode mirrored
  backend_created_with 127.0.0.1 127.0.0.1
  run radioctl network
  [ "$status" -eq 0 ]
  [ "$(net)" = $'LIVE_UDP_BIND=127.0.0.1\nLIVE_PUBLIC_IPS=127.0.0.1' ]
  assert_contains "$output" "the backend runs with these values"
  run calls
  refute_contains "$output" "ip -4"
  run events
  [ -z "$output" ]
}

@test "network: a mode change (Windows 11 upgrade) recreates the backend" {
  host_mode mirrored
  backend_created_with 172.20.240.2 0.0.0.0
  run radioctl network
  [ "$status" -eq 0 ]
  run events
  [ "$output" = "UP backend 1.0.0" ]
}

@test "network: --mode overrides host.env" {
  backend_created_with 127.0.0.1 127.0.0.1
  run radioctl network --mode mirrored
  [ "$status" -eq 0 ]
  [ "$(net)" = $'LIVE_UDP_BIND=127.0.0.1\nLIVE_PUBLIC_IPS=127.0.0.1' ]
}

@test "network before the first run: writes the file, touches no container" {
  rm "$ROOT/runtime/applied.env" "$ROOT/runtime/network.env" "$ROOT/.env"
  run radioctl network
  [ "$status" -eq 0 ]
  [ "$(net)" = $'LIVE_UDP_BIND=0.0.0.0\nLIVE_PUBLIC_IPS=172.20.240.2' ]
  assert_contains "$output" "no release installed yet: nothing to recreate"
  run calls
  refute_contains "$output" compose
}

@test "network: no backend container, nothing to recreate" {
  : >"$STUB_DIR/ps_q_backend.out"
  run radioctl network
  [ "$status" -eq 0 ]
  assert_contains "$output" "no backend container: nothing to recreate"
  run events
  [ -z "$output" ]
}

@test "network --dry-run changes nothing" {
  backend_created_with 172.20.250.9 0.0.0.0
  before=$(cat "$ROOT/runtime/network.env")
  run radioctl --dry-run network
  [ "$status" -eq 0 ]
  assert_contains "$output" "[dry-run] write runtime/network.env"
  assert_contains "$output" "[dry-run] docker compose up -d --no-deps backend"
  [ "$(cat "$ROOT/runtime/network.env")" = "$before" ]
  run events
  [ -z "$output" ]
}

@test "network: no mode or an unknown mode stops" {
  rm "$RADIOCTL_HOST_ENV"
  run radioctl network
  [ "$status" -eq 1 ]
  assert_contains "$output" "no network mode"
  host_mode bridge
  run radioctl network
  [ "$status" -eq 1 ]
  assert_contains "$output" "unknown network mode 'bridge'"
}

@test "network: a failed recreate is an error" {
  backend_created_with 172.20.250.9 0.0.0.0
  stub_rc up_backend 1
  run radioctl network
  [ "$status" -eq 1 ]
  assert_contains "$output" "recreating the backend failed"
}

@test "network waits for the lock of a running update" {
  exec 8>>"$ROOT/state.lock"
  flock -n 8
  run radioctl network
  [ "$status" -eq 1 ]
  assert_contains "$output" "another radioctl is running"
}

@test "logs shows the last run log, not a network or boot log" {
  mkdir -p "$ROOT/logs"
  echo update-line >"$ROOT/logs/update-2023-11-14T200000Z.log"
  echo net-line >"$ROOT/logs/network-2023-11-14T210000Z.log"
  echo boot-line >"$ROOT/logs/boot-2023-11-14T210000Z.log"
  run radioctl logs
  [ "$status" -eq 0 ]
  assert_contains "$output" update-line
}

# ------------------------------------------------------------- boot check

boot_log() { cat "$ROOT"/logs/boot-*.log; }

@test "boot-check: healthy within 5 minutes is ok, with the VM uptime" {
  RADIOCTL_UPTIME0=40 run radioctl boot-check
  [ "$status" -eq 0 ]
  assert_contains "$output" "boot check: waiting up to 600s for db backend frontend loki alloy grafana liquidsoap (VM uptime 40s)"
  assert_contains "$output" "ok: stack healthy at VM uptime 40s (target 300s)"
  [[ $(tail -n 1 "$ROOT"/logs/boot-*.log) == *"ok: stack healthy at VM uptime 40s (target 300s)" ]]
}

@test "boot-check: waits for the services; healthy after the target is LATE" {
  echo starting >"$STUB_DIR/health_backend"
  # The fake clock advances 5 s per wait; the backend gets healthy later.
  (
    while [[ $(cat "$STUB_DIR/clock") -lt $((CLOCK_OK + 100)) ]]; do sleep 0.05; done
    echo healthy >"$STUB_DIR/health_backend"
  ) &
  RADIOCTL_UPTIME0=250 run radioctl boot-check
  wait
  [ "$status" -eq 0 ]
  assert_contains "$output" "LATE: stack healthy at VM uptime"
  assert_contains "$output" "over the 300s target"
}

@test "boot-check: not healthy after 10 minutes is FAILED with the services, exit 0" {
  echo unhealthy >"$STUB_DIR/health_backend"
  : >"$STUB_DIR/ps_q_alloy.out"
  RADIOCTL_UPTIME0=30 run radioctl boot-check
  [ "$status" -eq 0 ]
  assert_contains "$output" "FAILED: not healthy after 600s (VM uptime 630s): backend=unhealthy alloy=missing"
  [[ $(tail -n 1 "$ROOT"/logs/boot-*.log) == *FAILED* ]]
}

@test "boot-check: liquidsoap only after the cut-over, grafana only with monitoring" {
  write_state 1.0.0 "$D_B100" 1.0.0 "$D_F100" null false
  sed -i 's/^MONITORING_ENABLED=.*/MONITORING_ENABLED=false/' "$ROOT/.env"
  echo exited >"$STUB_DIR/health_liquidsoap"
  echo exited >"$STUB_DIR/health_grafana"
  RADIOCTL_UPTIME0=10 run radioctl boot-check
  [ "$status" -eq 0 ]
  assert_contains "$output" "for db backend frontend loki alloy (VM uptime 10s)"
  assert_contains "$output" "ok: stack healthy"
}

@test "boot-check: skipped before the first run" {
  rm "$ROOT/runtime/applied.env"
  run radioctl boot-check
  [ "$status" -eq 0 ]
  assert_contains "$output" "boot check: skipped, no release installed yet"
}

@test "status shows the last boot check line and the network values" {
  RADIOCTL_UPTIME0=40 radioctl boot-check >/dev/null
  run radioctl status
  assert_contains "$output" "boot check: "
  assert_contains "$output" "ok: stack healthy at VM uptime 40s (target 300s)"
  assert_contains "$output" "network: live voice on 127.0.0.1:8189/udp (bound to 127.0.0.1)"
}

# ------------------------------------------------------------------ units

unit_value() { sed -n "s/^$2=//p" "$REPO/install/systemd/$1"; }

@test "radio-network.service: radioctl network as radio after Docker, at boot" {
  [ "$(unit_value radio-network.service Type)" = oneshot ]
  [ "$(unit_value radio-network.service User)" = radio ]
  [ "$(unit_value radio-network.service ExecStart)" = "/opt/radio-atlantida/deploy/bin/radioctl network" ]
  [ "$(unit_value radio-network.service After)" = docker.service ]
  [ "$(unit_value radio-network.service ConditionPathExists)" = /opt/radio-atlantida/deploy/bin/radioctl ]
  [ "$(unit_value radio-network.service WantedBy)" = multi-user.target ]
}

@test "radio-boot-check.service: radioctl boot-check after the network unit, does not block the boot" {
  [ "$(unit_value radio-boot-check.service Type)" = simple ]
  [ "$(unit_value radio-boot-check.service User)" = radio ]
  [ "$(unit_value radio-boot-check.service ExecStart)" = "/opt/radio-atlantida/deploy/bin/radioctl boot-check" ]
  [ "$(unit_value radio-boot-check.service After)" = "docker.service radio-network.service" ]
  [ "$(unit_value radio-boot-check.service ConditionPathExists)" = /opt/radio-atlantida/deploy/runtime/applied.env ]
  [ "$(unit_value radio-boot-check.service WantedBy)" = multi-user.target ]
}

@test "install-units.sh installs the boot units and enables them without starting them" {
  local dest=$BATS_TEST_TMPDIR/units
  mkdir -p "$dest"
  SYSTEMD_BOOTED=yes SYSTEMD_UNIT_DIR=$dest run "$REPO/install/systemd/install-units.sh"
  [ "$status" -eq 0 ]
  cmp "$REPO/install/systemd/radio-network.service" "$dest/radio-network.service"
  cmp "$REPO/install/systemd/radio-boot-check.service" "$dest/radio-boot-check.service"
  run calls
  assert_contains "$output" "systemctl enable --quiet radio-network.service radio-boot-check.service"
  refute_contains "$output" "--now radio-network"
}

@test "install-units.sh without a running systemd only enables (first pass of setup-distro.sh)" {
  local dest=$BATS_TEST_TMPDIR/units
  mkdir -p "$dest"
  SYSTEMD_BOOTED=no SYSTEMD_UNIT_DIR=$dest run "$REPO/install/systemd/install-units.sh"
  [ "$status" -eq 0 ]
  run calls
  refute_contains "$output" daemon-reload
  refute_contains "$output" "--now"
  assert_contains "$output" "systemctl enable --quiet radio-network.service radio-boot-check.service radio-backup.timer radio-restore-drill.timer"
}

# -------------------------------------------------------------- keep-alive

@test "radio-keepalive writes one line and then sleeps (exec)" {
  mkdir -p "$BATS_TEST_TMPDIR/logs"
  RADIO_KEEPALIVE_LOG=$BATS_TEST_TMPDIR/logs/keepalive.log RADIO_KEEPALIVE_SLEEP=0 run "$REPO/install/radio-keepalive"
  [ "$status" -eq 0 ]
  [[ $(cat "$BATS_TEST_TMPDIR/logs/keepalive.log") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\ keep-alive\ started\ \(pid\ [0-9]+,\ VM\ uptime\ [0-9]+\ s\)$ ]]
  grep -q 'exec sleep "${RADIO_KEEPALIVE_SLEEP:-infinity}"' "$REPO/install/radio-keepalive"
}

@test "radio-keepalive without the log folder writes to stderr and still sleeps" {
  RADIO_KEEPALIVE_LOG=$BATS_TEST_TMPDIR/missing/keepalive.log RADIO_KEEPALIVE_SLEEP=0 run "$REPO/install/radio-keepalive"
  [ "$status" -eq 0 ]
  assert_contains "$output" "keep-alive started"
}
