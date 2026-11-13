#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# The production compose file renders and keeps its rules
# (deploy-init-plan.md D2, 9.1 item 1, §1, §1.1). It renders four times,
# with .env.example and tests/fixtures/applied.env, in NAT and in mirrored
# mode (tests/fixtures/network-*.env), each without and with
# `--profile monitoring`, and checks from `docker compose config --format
# json`:
#
#   - no `icecast` service; the fixed project name;
#   - application images are exactly the release.env references (fixture
#     tags and digests); every other image is a literal name:tag, never
#     latest;
#   - the only published ports: frontend 127.0.0.1:PANEL_PORT->8080/tcp,
#     backend LIVE_UDP_BIND:8189->8189/udp (127.0.0.1 or 0.0.0.0 from the
#     fixture), grafana 127.0.0.1:GRAFANA_PORT->3000/tcp (monitoring only);
#     db, liquidsoap, loki, alloy, migrate, grafana-role publish nothing;
#   - the media mounts of backend and liquidsoap are binds whose
#     create_host_path is not true (Compose drops a false value from the
#     rendered file, so "absent or false" is what is checked); backend's is
#     read-write, liquidsoap's read-only; backend's journal is read-only;
#   - migrate and grafana-role disable the health check; backend has
#     stop_grace_period 30s and group_add 10001.
#
# And from the files themselves: every `image:` of docker-compose.yml is a
# literal pin or the release.env variables; no `latest` tag in any tracked
# compose file, Dockerfile, or image variable of a script.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

bad=0
problem() {
  echo "compose: $*"
  bad=1
}

read_fixture() { sed -n "s/^$2=//p" "$1" | head -n 1; }
fx=tests/fixtures/applied.env
want_backend="ghcr.io/astronin/radio-atlantida-backend:$(read_fixture $fx BACKEND_TAG)@$(read_fixture $fx BACKEND_DIGEST)"
want_frontend="ghcr.io/astronin/radio-atlantida-frontend:$(read_fixture $fx FRONTEND_TAG)@$(read_fixture $fx FRONTEND_DIGEST)"
panel_port=$(read_fixture .env.example PANEL_PORT)
grafana_port=$(read_fixture .env.example GRAFANA_PORT)

# render <network fixture> [--profile monitoring]
render() {
  local net=$1
  shift
  docker compose -f docker-compose.yml --env-file .env.example --env-file "$fx" \
    --env-file "$net" "$@" config --format json
}

check_rendered() {
  local json=$1 label=$2 bind=$3 monitoring=$4 out
  out=$(jq -r --arg bind "$bind" --argjson mon "$monitoring" \
    --arg wb "$want_backend" --arg wf "$want_frontend" \
    --arg pp "$panel_port" --arg gp "$grafana_port" '
    def s: .services;
    def ports($n): (s[$n].ports // []) | map({host_ip, target: (.target | tostring),
      published: (.published | tostring), protocol: (.protocol // "tcp")});
    def media($n): (s[$n].volumes // []) | map(select(.target == "/media"));
    def journal($n): (s[$n].volumes // []) | map(select(.target == "/journal"));
    [
      (if .name != "radio-atlantida" then "project name is \(.name)" else empty end),
      (if s | has("icecast") then "an icecast service exists" else empty end),
      (if s.backend.image != $wb then "backend image is \(s.backend.image), expected \($wb)" else empty end),
      (if s.migrate.image != $wb then "migrate image is \(s.migrate.image), expected \($wb)" else empty end),
      (if s.frontend.image != $wf then "frontend image is \(s.frontend.image), expected \($wf)" else empty end),
      (s | to_entries[] | select(.key != "backend" and .key != "migrate" and .key != "frontend")
        | select((.value.image // "") | test("^[a-z0-9./_-]+:[A-Za-z0-9._-]+$") | not)
        | "\(.key): image \(.value.image) is not a literal name:tag"),
      (s | to_entries[] | select((.value.image // "") | test(":latest(@|$)"))
        | "\(.key): image \(.value.image) uses latest"),
      (if ports("frontend") != [{host_ip: "127.0.0.1", target: "8080", published: $pp, protocol: "tcp"}]
        then "frontend ports are \(ports("frontend")), expected only 127.0.0.1:\($pp)->8080/tcp" else empty end),
      (if ports("backend") != [{host_ip: $bind, target: "8189", published: "8189", protocol: "udp"}]
        then "backend ports are \(ports("backend")), expected only \($bind):8189->8189/udp" else empty end),
      (if $mon then
         (if ports("grafana") != [{host_ip: "127.0.0.1", target: "3000", published: $gp, protocol: "tcp"}]
           then "grafana ports are \(ports("grafana")), expected only 127.0.0.1:\($gp)->3000/tcp" else empty end),
         (if s["grafana-role"].healthcheck.disable != true then "grafana-role does not disable the health check" else empty end)
       else
         (if (s | has("grafana")) or (s | has("grafana-role")) then "grafana is rendered without the monitoring profile" else empty end)
       end),
      (s | to_entries[] | select(.key | IN("frontend", "backend", "grafana") | not)
        | select((.value.ports // []) | length > 0) | "\(.key) publishes \(.value.ports)"),
      (["backend", "liquidsoap"][] as $n
        | if (media($n) | length) != 1 then "\($n) has \(media($n) | length) /media mounts, expected 1"
          else media($n)[0] |
            (if .type != "bind" then "\($n): /media is a \(.type), expected a bind" else empty end),
            (if .bind.create_host_path == true then "\($n): /media has create_host_path true" else empty end)
          end),
      (if (media("backend")[0].read_only // false) then "backend: /media is read-only, expected read-write" else empty end),
      (if (media("liquidsoap")[0].read_only // false) != true then "liquidsoap: /media is not read-only" else empty end),
      (if (journal("backend") | length) != 1 or (journal("backend")[0].read_only // false) != true
        then "backend: /journal is not one read-only mount" else empty end),
      (if s.migrate.healthcheck.disable != true then "migrate does not disable the health check" else empty end),
      (if s.backend.stop_grace_period != "30s" then "backend stop_grace_period is \(s.backend.stop_grace_period), expected 30s" else empty end),
      (if ((s.backend.group_add // []) | map(tostring) | index("10001")) == null then "backend group_add lacks 10001" else empty end)
    ] | .[]' <<<"$json")
  if [[ -n $out ]]; then
    while IFS= read -r line; do problem "$label: $line"; done <<<"$out"
  else
    echo "ok - $label"
  fi
}

for mode in nat mirrored; do
  net=tests/fixtures/network-$mode.env
  bind=$(read_fixture "$net" LIVE_UDP_BIND)
  json=$(render "$net") || {
    problem "$mode: docker compose config failed"
    continue
  }
  check_rendered "$json" "$mode" "$bind" false
  json=$(render "$net" --profile monitoring) || {
    problem "$mode + monitoring: docker compose config failed"
    continue
  }
  check_rendered "$json" "$mode + monitoring" "$bind" true
done

# The file itself: image lines are literal pins or the release.env variables.
while IFS= read -r line; do
  ref=$(sed -E 's/^[[:space:]]*image:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' <<<"$line")
  case $ref in
    '*backend-image') ;;
    'ghcr.io/astronin/radio-atlantida-frontend:${FRONTEND_TAG:?run through radioctl}@${FRONTEND_DIGEST:?run through radioctl}') ;;
    *'$'*) problem "docker-compose.yml: image '$ref' uses a variable other than the release.env ones" ;;
    *:*) ;;
    *) problem "docker-compose.yml: image '$ref' has no tag" ;;
  esac
done < <(grep -E '^[[:space:]]*image:' docker-compose.yml)
grep -q '^x-backend-image: &backend-image ghcr.io/astronin/radio-atlantida-backend:${BACKEND_TAG:?run through radioctl}@${BACKEND_DIGEST:?run through radioctl}$' docker-compose.yml ||
  problem "docker-compose.yml: the backend image anchor is not the release.env reference"

# No latest tag anywhere an image is named: compose files, Dockerfiles, and
# `image=` variables of the scripts.
while IFS= read -r -d '' f; do
  while IFS= read -r hit; do
    problem "$f: $hit"
  done < <(grep -nE '^[[:space:]]*(image:|FROM[[:space:]]|image=)' "$f" | grep -E ':latest([@[:space:]"]|$)|^[^:]*:[[:space:]]*(image:|FROM|image=)[[:space:]]*[a-z0-9./_-]+[[:space:]]*$' || true)
done < <(git ls-files -z -- '*.yml' '*.yaml' '*Dockerfile' '*.sh' 'bin/*')

if ((bad)); then
  echo "compose: FAIL"
  exit 1
fi
echo "compose: OK (4 renders; images, ports, mounts, health checks)"
