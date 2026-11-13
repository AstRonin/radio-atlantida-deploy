# radio-atlantida-deploy

Production stack of Radio Atlantida: the Compose file, configuration copies,
the Windows host installer, and the update tool. No application code; the
backend and frontend run as prebuilt images from GitHub Container Registry.

The runbook (install, update, rollback, restore, maintenance, backups) is
written in Phase D7 of `docs/deploy-init-plan.md`. Until then, see that plan
and `docs/tech-design.md` §9. The sections below (Phases D3, D5, and D6)
become part of it.

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
| `update.bat backup` | the daily backup now (the timer runs it at 04:30) |
| `update.bat restore-drill [<dump>]` | restore the newest daily dump into a scratch database, check it, drop it |
| `update.bat status` | release, containers, air, pending maintenance, backups and drill, disk, media |
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

Not in this version: `install.ps1`, `setup-distro.sh`, and
`radio-network.service`, which writes `runtime/network.env` (Phase D4).

## Backups (`update.bat backup`, `update.bat restore-drill`)

Backups stay on the machine; the recovery point is 24 hours between updates
and seconds before an update. **There is no off-site copy**: a loss of the
machine's disk loses the database, both copies of the dumps, the journal,
and the media folder together. **Never run `wsl --unregister
radio-atlantida`**: it deletes the virtual disk with the database, the
journal, and `BACKUP_ROOT`; only the Windows copy survives it.

Layout, the same under `BACKUP_ROOT` (`/srv/radio/backups`, ext4) and its
Windows copy `BACKUP_WINDOWS_COPY` (`/mnt/c/RadioAtlantida/backups`, that is
`C:\RadioAtlantida\backups`):

| Path | What |
|------|------|
| `daily/db-<UTC>.dump` | the daily `pg_dump -Fc` |
| `update/db-<UTC>.dump` | the dump before every update, `db` maintenance, and restore |
| `<daily or update>/journal-<UTC date>/` | the playout journal files (`journal-*.jsonl`), copied with every dump of that day |

- **Daily backup.** `radio-backup.timer` runs `radioctl backup` as `radio`
  every day at 04:30 station time (`Asia/Yerevan`, after the plan's nightly
  pass at 03:00), with `Persistent=true`, so a backup missed while the
  machine was off runs after the next boot. It dumps the database online
  (the air is not affected), copies the journal beside the dump, copies both
  to the Windows folder, and applies retention. It takes `state.lock`: it
  never runs during an update and waits for one up to an hour.
- **Windows copy.** The folder must exist (`install.bat` creates it); it is
  never created by `radioctl`, because a missing `C:` mount would make it a
  folder inside the virtual disk. A missing or unwritable folder is a
  warning: the backup itself succeeded. An empty `BACKUP_WINDOWS_COPY`
  turns the copy off.
- **Retention**, in both locations: the newest `BACKUP_DAILY_KEEP` (14)
  daily dumps and the newest `BACKUP_UPDATE_KEEP` (14) update dumps. Never
  removed by retention: the dump recorded as `last_dump`, and the pre-update
  dumps of the last `BACKUP_BOUNDARY_KEEP` (3) installs that raised
  `min_app_version` (the restore points of a downgrade across a contract
  migration). A journal folder goes with the last dump of its day. To free
  space, an older boundary dump can be deleted by hand from `update/` in
  both locations (`update.bat status` shows the disk space); never the one in
  `state.json` `last_dump`.
- **Restore.** `update.bat restore <dump>` takes a path, `daily/<name>` or
  `update/<name>`, or the bare file name; it looks in `BACKUP_ROOT` first,
  then in the Windows copy. Without a name it restores `last_dump`.
- **Restore drill.** `radio-restore-drill.timer` runs `radioctl
  restore-drill` on the 1st of every month at 05:30 station time
  (`Persistent=true`); `update.bat restore-drill` runs it by hand. It
  restores the newest daily dump into the scratch database
  `radio_restore_drill` of the same `db` container, checks the schema
  version (present, not dirty) and the row counts of the main tables, and
  drops the scratch database again. It never names the production database.
- **Results.** Every run writes `logs/backup-*.log` or
  `logs/restore-drill-*.log` and records `last_backup`, `last_backup_utc`
  (last success), or `last_drill` in `state.json`. `update.bat status` shows
  the last backup with its journal and Windows copy results and warnings, the
  last drill, `OVERDUE` when no backup succeeded for 26 hours, and `DUE`
  when the last good drill is older than 35 days. A failed daily backup is
  also shown by the next `update.bat`.
- **Production data to development**: copy a dump from
  `C:\RadioAtlantida\backups` to the Mac by hand and restore it into the dev
  stack with `pg_restore --clean --if-exists`. Never the other way.

The units are in `install/systemd/`. `setup-distro.sh` (D4) installs them as
root with `install/systemd/install-units.sh` (copies them to
`/etc/systemd/system`, reloads systemd, enables and starts both timers;
idempotent). The services do nothing until `radioctl first-run` has written
`runtime/applied.env`; the first run checks that the timers are enabled and
runs the first backup.

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
