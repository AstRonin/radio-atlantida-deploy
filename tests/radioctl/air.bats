#!/usr/bin/env bats
# radioctl: the air check (plan 7.3 steps 4 and 8).

load helpers

setup() { common_setup; }

@test "an open outage stops the update" {
  api api_broadcast_status '{"state":"unreachable"}'
  run radioctl update
  [ "$status" -eq 1 ]
  assert_contains "$output" "An outage is open"
  run events
  refute_contains "$output" "DUMP"
}

@test "on_air null asks for confirmation; no stops" {
  api api_status_live '{"on_air":null}'
  run radioctl update <<<"n"
  [ "$status" -eq 1 ]
  assert_contains "$output" "Live voice may be on air (on_air: null)"
  run events
  refute_contains "$output" "DUMP"
}

@test "on_air true asks; yes continues" {
  api api_status_live '{"on_air":true}'
  run radioctl update <<<"y"
  [ "$status" -eq 0 ]
  assert_contains "$output" "Live voice may be on air (on_air: true)"
}

@test "--yes answers the on-air question" {
  api api_status_live '{"on_air":true}'
  run radioctl --yes update </dev/null
  [ "$status" -eq 0 ]
}

@test "an unreachable endpoint asks for confirmation, never read as off air" {
  api_rc api_broadcast_status 7
  run radioctl update </dev/null
  [ "$status" -eq 1 ]
  assert_contains "$output" "The broadcast status could not be read. Continue anyway?"
  run events
  refute_contains "$output" "DUMP"
}

@test "fewer than 2 queued items waits, then stops after 2 minutes" {
  api api_playout_status "$(queued 1)"
  run radioctl update
  [ "$status" -eq 1 ]
  assert_contains "$output" "waiting: fewer than 2 items queued"
  assert_contains "$output" "fewer than 2 items queued or no control link after 2 minutes"
  (($(cat "$STUB_DIR/clock") - CLOCK_OK >= 120))
  run events
  refute_contains "$output" "DUMP"
}

@test "a disconnected control link waits, then stops" {
  api api_playout_status '{"control_link":{"connected":false},"queued":[{},{},{}]}'
  run radioctl update
  [ "$status" -eq 1 ]
  assert_contains "$output" "after 2 minutes"
}

@test "the prepush window waits until the first minute after the hour has passed" {
  # 22:56:40 UTC: 200 s before the hour, inside 5 + 1 minutes.
  set_clock $((CLOCK_OK + 43 * 60 + 20))
  run radioctl update
  [ "$status" -eq 0 ]
  assert_contains "$output" "waiting 260s: the next hour's items are being pushed"
  # Done after 23:01:00.
  (($(cat "$STUB_DIR/clock") >= CLOCK_OK + 47 * 60 + 40))
}

@test "the first minute after the hour waits too" {
  # 23:00:20 UTC.
  set_clock $((CLOCK_OK + 47 * 60))
  run radioctl update
  [ "$status" -eq 0 ]
  assert_contains "$output" "waiting 40s"
}

@test "--no-wait stops in the prepush window" {
  set_clock $((CLOCK_OK + 43 * 60 + 20))
  run radioctl --no-wait update
  [ "$status" -eq 1 ]
  assert_contains "$output" "stopped (--no-wait)"
  run events
  refute_contains "$output" "DUMP"
}

@test "the window uses playout.prepush_minutes and the station time zone" {
  api api_settings '{"items":[{"key":"playout.prepush_minutes","value":1},{"key":"station.timezone","value":"UTC"}]}'
  # 22:56:40: outside a 1 + 1 minute window.
  set_clock $((CLOCK_OK + 43 * 60 + 20))
  run radioctl update
  [ "$status" -eq 0 ]
  refute_contains "$output" "waiting"
}

@test "before the cut-over the air check is skipped" {
  write_state 1.0.0 "$D_B100" 1.0.0 "$D_F100" null false
  api api_broadcast_status '{"state":"unreachable"}'
  run radioctl update
  [ "$status" -eq 0 ]
  assert_contains "$output" "before the cut-over: air check skipped"
}
