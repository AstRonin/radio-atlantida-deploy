# radio-atlantida-deploy

Production stack of Radio Atlantida: the Compose file, configuration copies,
the Windows host installer, and the update tool. No application code; the
backend and frontend run as prebuilt images from GitHub Container Registry.

The runbook (install, update, rollback, restore, maintenance, backups) is
written in Phase D7 of `docs/deploy-init-plan.md`. Until then, see that plan
and `docs/tech-design.md` §9. The sections below (Phases D3 and D5) become
part of it.

## Production playout script

`config/liquidsoap/radio.liq` is the backend's `dev/liquidsoap/radio.liq` at
the release tag `v${BACKEND_TAG}` (`release.env`) with
`config/liquidsoap/production.patch` applied. It is never edited by hand: a
change is made in the backend, released, and copied here.

- **The patch is empty.** The dev script takes every startup value from the
  environment, and `docker-compose.yml` sets the production values (backend
  URLs on `http://backend:8090`, `OUTPUT_STATE_FILE`, `ICECAST_TLS=true`, the
  secrets). The stream itself (host, port, mount, TLS, format, name) comes
  from the backend's `stream.*` settings at runtime (`output.set`). The
  patch file holds a comment only; a real override would be a unified diff
  below it.
- **Contract header.** The script starts with
  `# radio-atlantida-contract: N` and `# min-backend: X.Y.Z`. A new contract
  number needs a Liquidsoap restart in a maintenance window; a backend below
  `min-backend` is refused (D5).
- **Source commit.** `config/backend-source.env` records the backend commit
  `config/` was taken from. No backend release tag exists yet, so the current
  copy comes from backend `main` at that commit; pass it with `--ref` until
  `v${BACKEND_TAG}` exists.

Checks (bash, docker; the smoke test also needs `go`):

```sh
# config/ (script, Grafana, Loki, Alloy) and the image pins equal the
# backend at the ref; exit 1 on drift. --update rewrites config/ instead.
scripts/check-backend-sync.sh [--ref REF] [--backend-dir ../radio-atlantida-backend]

# liquidsoap --check in savonet/liquidsoap:v2.4.6 with the production
# service definition, then the runtime smoke test with the backend's
# dev/liqsmoke tool at the same ref.
tests/liquidsoap/run.sh [--ref REF] [--backend-dir ../radio-atlantida-backend] [--check-only]
```

The ref defaults to `$BACKEND_REF`, else `v${BACKEND_TAG}`. Without
`--backend-dir` the backend is fetched from its public GitHub repository at
that ref (no token). The smoke test runs the compose project
`radio-deploy-liqsmoke` on `127.0.0.1` ports 18000 and 11234 and a stub
backend on port 18090, and removes it at the end.

## External Icecast server

Production has no Icecast container: Liquidsoap streams to the external
server `https://listen.teploe.net:8001/atlantida` (Icecast 2.4.4). For the
operator and the server owner:

- **TLS on port 8001.** Port 8001 accepts TLS only (plain HTTP is reset);
  the script connects with `http.transport.tls()`, which trusts the server's
  Let's Encrypt certificate through the image's system roots. Port 8100
  serves listeners over plain HTTP. The server must stay reachable over TLS
  on 8001 for the source connection and for `GET /status-json.xsl`, which
  the backend's outage detector reads; the station's outgoing internet
  connection is part of the air chain.
- **Mount `/atlantida`.** Its source password is `ICECAST_SOURCE_PASSWORD`
  in `.env`, entered by hand at the first run and never sent over the
  control link. The mount carries the current playout system's source until
  the cut-over (`radioctl cutover`, D4 6.9).
- **Charset.** Ask the server owner to set `<charset>UTF-8</charset>` on
  `/atlantida`. The script sends UTF-8 metadata; until the mount has it,
  Cyrillic and Armenian titles show as `*` (accepted).
- **Stream settings.** Host, port, mount, TLS, codec, bitrate, sample rate,
  channels, name, description, and genre are backend settings, edited in
  the panel under "Stream output (Icecast)" and applied at runtime with a
  gap of a few seconds; no Liquidsoap restart. The first run writes
  `listen.teploe.net`, `8001`, `/atlantida`, TLS on, MP3, 160 kbps,
  44100 Hz, stereo, name "Radio Atlantida" (the current stream's format).
- **Outages.** The outage detector watches the external server: a provider
  outage opens an outage and marks items missed, like any other.

## Update tool (`update.bat` -> `bin/radioctl`)

`update.bat` runs `bin/radioctl` inside the WSL distribution `radio-atlantida`
as the user `radio` (`/opt/radio-atlantida/deploy`). `radioctl` is the only
way to change the production stack: it records in `state.json` what a
rollback and a restore need. Every changing command writes
`logs/<command>-YYYY-MM-DDTHHMMSSZ.log` (UTC); secrets are never printed or
logged.

| Command | What it does |
|---------|--------------|
| `update.bat` | `git pull --ff-only`, then install `release.env` |
| `update.bat <backend> [<frontend>]` | install any release >= 1.0.0, newer or older (frontend tag defaults to the backend tag) |
| `update.bat rollback` | install the release that ran before the last install, by digest |
| `update.bat restore [<dump>]` | restore the last update dump, or `<dump>`; typed `RESTORE` |
| `update.bat maintenance` | apply pending `liquidsoap`/`db` changes; typed `MAINTENANCE` |
| `update.bat cutover [--undo]` | start (or stop) `liquidsoap` on the external mount; typed `CUTOVER` |
| `update.bat first-run` | first configuration of a new machine (called by `install.bat`) |
| `update.bat status` | release, containers, air, pending maintenance, backups, disk, media |
| `update.bat logs [<service>]` | the last run log, or a service's container log |
| `update.bat compose <args>` | `docker compose` with the production files, for diagnostics |

Options: `--dry-run` (print every step, change nothing), `--yes` (answer the
non-destructive questions; never a typed word), `--no-wait` (stop instead of
waiting for the prepush window), `--no-fetch`.

An update (plan 7.3): preflight; release check (images and digests,
MAJOR.MINOR, the script's `min-backend`, the downgrade guard
`schema_compat.min_app_version`); air check after the cut-over (open outage
stops, live on air asks, at least 2 items queued, not around the hour
boundary); pull; a mandatory `pg_dump`; `migrate up` while the old backend
runs (newer targets only); backend, health gate, frontend; Loki, Alloy,
Grafana (warnings only); pending maintenance is reported, `liquidsoap` and
`db` are never restarted. Every failure ends with "Update to X failed and was
undone. Broadcasting continues on Y. Send the log ... to the developer." A
migration exit 5 (dirty) restores the pre-update dump automatically; a
failed health gate reinstalls the previous release by digest.

Not in this version: `backup`, `restore-drill`, the daily timer, the journal
and Windows copies of a dump (Phase D6); `install.ps1`, `setup-distro.sh`,
and `radio-network.service`, which writes `runtime/network.env` (Phase D4).

Tests (bats-core 1.11.1 in Docker; `docker`, `git`, and the clock are
stubs, so no stack is needed):

```sh
tests/radioctl/run.sh            # all tests
tests/radioctl/run.sh -f restore # by name
```

Dry-run switches (environment only, never `.env`): `COMPOSE_PROJECT_NAME`,
`RADIOCTL_BACKEND_IMAGE`, `RADIOCTL_FRONTEND_IMAGE` (a test registry),
`RADIOCTL_COMPOSE_OVERRIDE` (an extra compose file), `RADIOCTL_HEALTH_TIMEOUT`,
`RADIOCTL_LOCK_WAIT`, `RADIOCTL_FAKE_CLOCK` (tests).
