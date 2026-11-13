# radio-atlantida-deploy

Production stack of Radio Atlantida: the Compose file, configuration copies,
the Windows host installer, and the update tool. No application code; the
backend and frontend run as prebuilt images from GitHub Container Registry.

The runbook (install, update, rollback, restore, maintenance, backups) is
written in Phase D7 of `docs/deploy-init-plan.md`. Until then, see that plan
and `docs/tech-design.md` §9. The sections below (Phases D3 to D6) become
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

`runtime/network.env` (`LIVE_UDP_BIND`, `LIVE_PUBLIC_IPS`) is written by
`radioctl network`, which `radio-network.service` runs at every boot (see
"Host install" below).

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

## Host install (`install.bat`, Phase D4)

The station machine runs Windows 10 (21H2, build 19044.2311 or later, with
the Microsoft Store WSL; Home is enough) or Windows 11, x64, virtualization
on, at least 16 GB RAM and 100 GB free on the drive of the distribution.
Docker Desktop must not be installed.

1. Create the dedicated local administrator account once, from any
   administrator account: `install.bat -CreateAccount` (the password is
   typed twice and never logged; it never expires).
2. Sign in to Windows as `radio`, download this repository (ZIP or `git
   clone`), and double-click `install.bat`. It elevates itself (UAC prompt).
3. If Windows features had to be enabled, it asks to restart. After the
   restart, sign in as `radio`: the install continues by itself (one-shot
   logon task "Radio Atlantida install resume", deleted when it continues).
4. Answer its questions: the station's Windows media folder (default
   `D:\RadioAtlantida\media`), the Windows Update active hours (default
   06:00-24:00, at most 18 hours), the Windows password of `radio` (stored
   only by Task Scheduler for the boot task), and then the questions of
   `radioctl first-run` (registry user and read token, the Icecast source
   password, the stream settings). The Grafana admin password is shown once.

Options: `-DryRun` (check every step, change nothing), `-Yes` (accept the
defaults of the media folder and active hours questions), `-MediaFolder
<path>`, `-InstallRoot <folder>` (default `C:\RadioAtlantida`, the virtual
disk of the distribution goes to `<InstallRoot>\wsl`), `-ActiveHoursStart`,
`-ActiveHoursEnd`. Every run writes
`C:\ProgramData\RadioAtlantida\logs\install-<UTC>.log`; the finished steps
are in `C:\ProgramData\RadioAtlantida\install-state.json`. A second run
checks every step against the real state and changes nothing; it re-applies
`install/versions.env` (a Docker Engine upgrade is a new `versions.env` and
an `install.bat` run in a maintenance window). A step that would stop WSL
on an installed station (a changed `.wslconfig` or `/etc/wsl.conf`) asks
first, because it interrupts the air.

What `install.ps1` does, in order (plan 6.2):

| Step | What |
|------|------|
| Preflight | build and update level, edition, newest KB with its date, ESU status (logged; an old patch level only warns), x64, virtualization, signed in as `radio`, no Docker Desktop, disk space, internet (Ubuntu images, Docker apt, GHCR, GitHub); the Windows 10 support note once |
| Windows features | `Microsoft-Windows-Subsystem-Linux`, `VirtualMachinePlatform` (`dism.exe`); restart and resume if needed |
| WSL | `wsl --update` (Store, else `--web-download`), `wsl --set-default-version 2`, `wsl --version` at least `WSL_MIN_VERSION` |
| Network mode | Windows 11 22H2+ (build 22621): `mirrored`; otherwise `nat` |
| `.wslconfig` | `[wsl2]` `memory=8GB`, `processors` = half the CPUs (at least 2), `swap=4GB`, `vmIdleTimeout=-1`; NAT: `localhostForwarding=true`; mirrored: `networkingMode=mirrored`; other keys kept |
| Folders | the media folder must exist on a fixed, internal, local NTFS drive (no share, mapped, removable, or USB drive); Defender exclusion; indexing off; `C:\RadioAtlantida\backups` (the Windows copy of the backups) |
| Distribution | the pinned Ubuntu 24.04 rootfs (`versions.env`), SHA-256 checked, `wsl --import radio-atlantida <InstallRoot>\wsl ... --version 2`; an existing distribution is kept |
| Linux half | copies `install/` and `docker-compose.yml` to `/var/lib/radio-atlantida/src`, runs `setup-distro.sh` as root, restarts the distribution when it asks (exit 10), runs it again |
| Keep-alive task | "Radio Atlantida WSL": at boot and every 5 minutes, as `radio` whether signed in or not, `wsl.exe -d radio-atlantida -u radio --exec /usr/local/bin/radio-keepalive`, no time limit, one instance, restart on failure |
| Host settings | no sleep, hibernation, or disk timeout on AC; hibernation and Fast Startup off; active hours; Windows Time automatic with NTP; no Pro-only update policy |
| Deploy repository | `git clone` to `/opt/radio-atlantida/deploy` as `radio`, `systemctl start radio-network.service`, `bin/radioctl first-run --media-root /mnt/<drive>/...` |
| Shortcuts | "Radio panel", "Radio media", "Radio update" (`<InstallRoot>\update.bat`), "Radio Grafana" when monitoring is on |

`install/setup-distro.sh` (root, idempotent): `/etc/wsl.conf` from
`install/wsl.conf` (systemd, default user `radio`, no Windows `PATH`, drive
mount `uid=1000,gid=10001,umask=002,fmask=002` without `metadata`); user
`radio` (uid 1000; the stock `ubuntu` user of the image is renamed), group
`radio-media` (gid 10001), `radio` in `radio-media` and `docker`; base
packages (with `tzdata`: the timers name `Asia/Yerevan`); Docker's apt
repository with the pinned key fingerprint, `docker-ce`, `docker-ce-cli`,
`containerd.io`, `docker-compose-plugin`, `docker-buildx-plugin` at the
pinned versions with an apt pin (`/etc/apt/preferences.d/radio-atlantida-docker`)
and `apt-mark hold`; `unattended-upgrades` for Ubuntu security updates only,
no reboot; `/etc/docker/daemon.json` (json-file 10m x 3, userland proxy on);
`/srv/radio/journal` (owned by the user of the pinned Liquidsoap image),
`/srv/radio/backups` (`radio`, 0700), `/opt/radio-atlantida` (`radio`);
`/etc/radio-atlantida/host.env` (`RADIO_NETWORK_MODE`);
`/usr/local/bin/radio-keepalive`; the units (`install/systemd/install-units.sh`).
On a fresh import the first pass runs without systemd and exits 10; the
second pass, under systemd, starts Docker and checks systemd, the Docker and
Compose versions, and that `radio` can create and rename a file in the
media folder.

At boot, with nobody signed in: the keep-alive task starts the distribution
(its `wsl.exe` stays, as `sleep infinity`, so WSL does not stop the idle
distribution) -> WSL mounts the Windows drives -> systemd starts Docker ->
`radio-network.service` (`radioctl network`) writes `runtime/network.env`:
in NAT mode `LIVE_UDP_BIND=0.0.0.0` and `LIVE_PUBLIC_IPS=<eth0 address>`
(it changes at every boot), in mirrored mode `127.0.0.1` for both; it
recreates `backend` only when the running container was created with other
values -> Docker starts the containers (`restart: unless-stopped`) ->
`radio-boot-check.service` (`radioctl boot-check`) waits up to 10 minutes
and writes `logs/boot-<UTC>.log`, whose last line `update.bat status`
shows: `ok: stack healthy at VM uptime N s (target 300s)`, `LATE: ...`, or
`FAILED: ...` with the services that were not healthy. `radio-keepalive`
writes one line per start to `logs/keepalive.log`.

The panel is `http://127.0.0.1:8080` (a secure context, so the microphone
works without HTTPS); live voice goes to `LIVE_PUBLIC_IPS:8189/udp`. Nothing
is reachable from the LAN.

BIOS/UEFI (by hand, not scripted): "Restore on AC power loss: Power On",
virtualization (VT-x/AMD-V) enabled; a UPS is recommended. **Never run `wsl
--unregister radio-atlantida`** (it deletes the database and the backups
inside the virtual disk).

Security note: without ESU, Windows 10 gets no more security fixes since
14 October 2025. The station exposes no inbound port; do not use the machine
for email or browsing. An upgrade to Windows 11 is recommended later;
`install.bat` then switches to mirrored networking by itself. If ESU is
enrolled, use "Pause updates" and install updates by hand in a maintenance
window, followed by the reboot check.

Tests (Docker; nothing here runs Windows itself):

```sh
tests/install/run.sh            # Pester 5.7.1 tests of install.ps1 (75, Windows mocked) and PSScriptAnalyzer 1.25.0, PowerShell 7.5
tests/distro/run.sh             # setup-distro.sh twice in ubuntu:24.04 (files, users, units), systemd-analyze verify
tests/distro/run.sh --with-apt  # also the pinned Docker apt install (key, pin, hold); slow
tests/radioctl/run.sh -f network  # radioctl network, boot-check, the units, radio-keepalive
```

### D4 acceptance on Windows

These could not be tested on the Mac; each is marked "(verify on Windows)"
in the code or the plan. Run them on a Windows 10 machine of the production
build (or the production machine before air), and again after a Windows
update or a WSL or Docker Engine upgrade.

- [ ] A full install from a fresh Windows, with the features restart and the
      resume (the resume task runs elevated at logon and is deleted), finishes.
- [ ] A second `install.bat` run changes nothing (log: every step skipped,
      `setup-distro: nothing to change.`); `install.bat -DryRun` changes nothing.
- [ ] Self-elevation keeps the account `radio`; the elevated window waits for
      Enter at the end.
- [ ] The Store WSL on the production build: `wsl --version` prints at least
      `WSL_MIN_VERSION` after `wsl --update` (or `--web-download`).
- [ ] `wsl --import` of the pinned rootfs works on Windows 10 with
      `--version 2` and shows no first-run dialog.
- [ ] systemd runs in the distribution (`systemctl is-system-running`:
      running, or degraded with only known units); Docker and Compose are the
      pinned versions.
- [ ] `.wslconfig`: the installed WSL accepts every key without a warning
      (`memory`, `processors`, `swap`, `vmIdleTimeout`, `localhostForwarding`;
      `networkingMode` only in mirrored mode).
- [ ] `Register-ScheduledTask` accepts the keep-alive XML; the task runs as
      `radio` whether signed in or not (password stored), and WSL starts from
      it without a sign-in. Fallback if not: Sysinternals Autologon for
      `radio`, a lock-screen policy, and an "at logon" trigger.
- [ ] No idle shutdown: with nobody signed in, the stack still runs 30 minutes
      after boot (`logs/keepalive.log` has one line per boot); without the
      keep-alive task, WSL would stop the distribution (confirms 6.4).
- [ ] The manager's sign-in as `radio` joins the same running VM
      (`update.bat status` shows the containers started at boot).
- [ ] NAT mode: the panel `http://127.0.0.1:8080` and Grafana
      `http://127.0.0.1:3000` open in the Windows browser through localhost
      forwarding of the `docker-proxy` sockets on the VM's `127.0.0.1` (if
      not: bind them to the VM address, plan 6.5 fallback).
- [ ] A live voice session from the Windows browser (panel on `127.0.0.1`)
      to the VM address, also after two reboots: the address changed and
      `radio-network.service` recreated the backend (`logs/network-*.log`).
- [ ] No LAN host reaches `<VM address>:8189/udp`.
- [ ] Mirrored mode (only on Windows 11 22H2+): `LIVE_PUBLIC_IPS=127.0.0.1`
      and a live session work.
- [ ] Media folder through the drive mount: files appear as
      `radio:radio-media` with group write; a transcode ("Fix loudness")
      writes a fixed file and the rename succeeds; Cyrillic and Armenian file
      names import; time the first import of the whole folder.
- [ ] Arguments with spaces and Cyrillic (the media folder) reach
      `radioctl first-run --media-root` unchanged through `wsl.exe --exec`;
      its prompts appear in the install window and secrets are not echoed.
- [ ] The media folder checks: a network share, a mapped drive, a removable
      drive, and an external USB disk are refused (`DriveInfo`,
      `Get-Partition | Get-Disk` bus type).
- [ ] The Defender exclusion is listed (`Get-MpPreference`); the folder has
      "contents indexed" off.
- [ ] The preflight log shows the edition, the newest KB with its date, and
      the ESU status (the ESU license query may not see a consumer ESU
      enrolment: compare with Settings > Windows Update).
- [ ] Settings > Windows Update shows the chosen active hours and does not
      adjust them automatically (`SmartActiveHoursState=0`); no Pro-only
      policy is set.
- [ ] Power: no sleep or hibernation on AC (`powercfg /a`, `/q`); Fast
      Startup is off, so a shutdown is a cold boot.
- [ ] Time: `w32tm /query /status` shows the NTP peers; Windows and WSL
      clocks differ by less than 1 s (`date -u` in WSL against Windows).
- [ ] The desktop shortcuts open the panel, Grafana, the media folder, and
      `update.bat`.
- [ ] The daily backup timer runs after a reboot and the Windows copy
      appears in `C:\RadioAtlantida\backups` (D6).
- [ ] **Cold-reboot test:** power the machine off and on with nobody signed
      in. Within **5 minutes of power-on** the stack is healthy (before the
      cut-over: every service except `liquidsoap`; after it, Liquidsoap
      connected to the server). `logs/boot-*.log` gives the VM uptime when
      it was healthy; add the time from power-on to the VM start (Windows
      boot time: `(Get-CimInstance Win32_OperatingSystem).LastBootUpTime`,
      and the keep-alive task's history). Then sign in as `radio` and run
      `update.bat status`.
- [ ] The Pester tests pass under Windows PowerShell 5.1 (D7 CI on a Windows
      runner).
