#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq and yq expressions are single-quoted on purpose
# The configuration files under config/ load in the images that run them
# (deploy-init-plan.md 9.1 items 4 and 5), as the backend CI checks its dev/
# copies (backend .github/workflows/ci.yml, "Loki and Alloy configuration"):
#
#   - config/loki/loki.yaml: `loki -verify-config` in the pinned Loki image;
#   - config/alloy/config.alloy: `alloy validate`, and `alloy fmt` output
#     equal to the committed file, in the pinned Alloy image;
#   - config/grafana: the provisioning YAML parses (pinned yq image), the
#     dashboard JSON parses, and every data source uid a dashboard names is
#     a provisioned one.
#
# The Loki and Alloy images are read from the rendered docker-compose.yml,
# so the check always uses the pins production runs.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# mikefarah/yq:4.44.3, multi-arch index digest (checked 2026-11-13).
yq_image=mikefarah/yq:4.44.3@sha256:5b3d851bf28b04ef902fee86305f4dd7e063919c1cafedab2042adb16221c025

bad=0
problem() {
  echo "config: $*"
  bad=1
}

json=$(docker compose -f docker-compose.yml --env-file .env.example --env-file tests/fixtures/applied.env \
  --env-file tests/fixtures/network-nat.env config --format json)
loki=$(jq -r .services.loki.image <<<"$json")
alloy=$(jq -r .services.alloy.image <<<"$json")

echo "== Loki ($loki)"
docker run --rm -v "$root/config/loki/loki.yaml:/etc/loki/loki.yaml:ro" "$loki" \
  -config.file=/etc/loki/loki.yaml -verify-config || problem "config/loki/loki.yaml fails -verify-config"

echo "== Alloy ($alloy)"
docker run --rm -v "$root/config/alloy:/cfg:ro" "$alloy" validate /cfg/config.alloy ||
  problem "config/alloy/config.alloy fails alloy validate"
# alloy fmt prints the formatted file; it must equal the committed one.
if ! fmt=$(docker run --rm -v "$root/config/alloy:/cfg:ro" "$alloy" fmt /cfg/config.alloy); then
  problem "alloy fmt failed"
elif ! diff -u config/alloy/config.alloy - <<<"$fmt"; then
  problem "config/alloy/config.alloy is not alloy fmt output (fix it in the backend's dev/alloy and sync)"
fi

echo "== Grafana provisioning and dashboards"
uids=()
while IFS= read -r -d '' f; do
  if ! out=$(docker run --rm -i "$yq_image" -o=json '.' <"$f"); then
    problem "$f does not parse as YAML"
    continue
  fi
  while IFS= read -r u; do [[ -n $u ]] && uids+=("$u"); done < <(jq -r '(.datasources // [])[] | .uid // empty' <<<"$out")
done < <(git ls-files -z -- 'config/grafana/provisioning/*.yaml' 'config/grafana/provisioning/*.yml')
((${#uids[@]})) || problem "no provisioned data source uid found"
echo "provisioned data source uids: ${uids[*]}"
known=$(printf '%s\n' "${uids[@]}" | jq -R . | jq -s .)
while IFS= read -r -d '' f; do
  if ! jq -e . "$f" >/dev/null 2>&1; then
    problem "$f does not parse as JSON"
    continue
  fi
  # Every datasource reference (object with a uid, or a bare uid string),
  # except Grafana's built-in ones and template variables.
  missing=$(jq -r --argjson known "$known" '
    [.. | objects | select(has("datasource")) | .datasource
      | if type == "object" then .uid else . end
      | select(type == "string")
      | select(startswith("$") | not)
      | select(. != "grafana" and . != "-- Grafana --" and . != "-- Dashboard --" and . != "-- Mixed --")]
    | unique | map(select(. as $u | $known | index($u) | not)) | .[]' "$f")
  [[ -z $missing ]] || problem "$f names data source uids that are not provisioned: ${missing//$'\n'/ }"
  echo "ok - $f"
done < <(git ls-files -z -- 'config/grafana/dashboards/*.json')

if ((bad)); then
  echo "config: FAIL"
  exit 1
fi
echo "config: OK (Loki, Alloy, Grafana)"
