# Radio Atlantida station runbook

How to install, run, update, back up, and recover the Radio Atlantida
station machine. Written for the operator: the person who sits at the
station's Windows PC. Every step says what to click or type and what you
should see. Commands are typed in a Command Prompt (`cmd`) unless the step
says otherwise.

Background for developers: `docs/deploy-init-plan.md` (the plan) and
`docs/tech-design.md` §9 (the design). This runbook replaces the operational
sections that used to be in `README.md`.

Contents

1. [Before the install](#1-before-the-install)
2. [First install](#2-first-install)
3. [Before the first air: media, grid, emergency playlist](#3-before-the-first-air)
4. [Cut-over to this system, and undo](#4-cut-over-to-this-system-and-undo)
5. [Daily operation](#5-daily-operation)
6. [Updates and rollback](#6-updates-and-rollback)
7. [Maintenance window](#7-maintenance-window)
8. [Backups](#8-backups)
9. [Restore and the monthly drill](#9-restore-and-the-monthly-drill)
10. [Troubleshooting](#10-troubleshooting)
11. [Acceptance checklist (Windows) and the cold-reboot test](#11-acceptance-checklist-windows-and-the-cold-reboot-test)

---

## Quick reference

| I want to... | Do this |
|--------------|---------|
| open the panel | double-click "Radio panel" (or open `http://127.0.0.1:8080`) |
| see if everything is fine | `C:\RadioAtlantida\update.bat status` |
| install the new release | double-click "Radio update" |
| go back to the previous release | `update.bat rollback` |
| see the last run log | `update.bat logs` |
| back up now | `update.bat backup` |
| apply a pending Liquidsoap or database change | `update.bat maintenance`, in a quiet hour |

To run `update.bat` with words after it, open a Command Prompt and go to the
folder first:

```bat
cd /d C:\RadioAtlantida
update.bat status
```

(If the install used another folder with `-InstallRoot`, use that folder.)
Double-clicking "Radio update" is the same as `update.bat` with nothing
after it: it installs the release named in `release.env`.

All commands of `update.bat`:

| Command | What it does | Effect on air |
|---------|--------------|---------------|
| `update.bat` | download this repository's news, then install `release.env` (6.1) | panel and live voice drop ~30 s; the stream continues |
| `update.bat <backend> [<frontend>]` | install a given release, newer or older (6.2) | as above |
| `update.bat rollback` | install the release that ran before the last install (6.2) | as above |
| `update.bat restore [<dump>]` | restore the database; typed `RESTORE` (9.1) | panel down for the restore; the stream continues |
| `update.bat maintenance` | apply pending Liquidsoap or database changes; typed `MAINTENANCE` (7) | the stream stops for some seconds |
| `update.bat cutover [--undo]` | start (or stop) Liquidsoap on the external mount; typed `CUTOVER` (4) | starts (or stops) the stream |
| `update.bat status` | how the station is (5.2) | none |
| `update.bat logs [<service>]` | the last run log, or a service's log (10.1) | none |
| `update.bat backup` | the daily backup now (8.2) | none |
| `update.bat restore-drill` | the monthly restore test now (9.3) | none |
| `update.bat first-run` | the first configuration (run by `install.bat`) | |
| `update.bat compose <args>` | Docker Compose with the station's files, for looking only (`compose ps`) | |

Options before the command: `--dry-run` (show every step, change nothing),
`--yes` (answer yes to the ordinary questions; never a typed word),
`--no-wait` (stop instead of waiting for the hour boundary), `--no-fetch`
(do not download this repository's news first).

> **Never run `wsl --unregister radio-atlantida`.** It deletes the virtual
> disk of the station: the database, the playout journal, and the backups
> inside it. Only the Windows copy of the backups (`C:\RadioAtlantida\backups`)
> survives it. No step of this runbook needs it.

---

## 1. Before the install

### 1.1 The machine

- **Windows 10** version 21H2 or later (build 19044 or 19045) **with the
  cumulative updates up to at least November 2022** (build 19044.2311 or
  19045.2311; `winver` shows it), or **Windows 11**. Home is enough. 64-bit
  x86 (Intel or AMD); not ARM.
- Virtualization turned on in the BIOS/UEFI (see 1.2).
- RAM: 16 GB recommended. The Linux part of the station (the WSL virtual
  machine) gets half of the RAM, at least 4 GB and at most 16 GB (8 GB on a
  16 GB machine). With less than 16 GB the installer warns but continues.
- An SSD with **at least 40 GB free** on the drive of the install folder
  (default `C:\RadioAtlantida`). The virtual disk there holds the Docker
  images, the database, the journal, and the backups; it grows and does not
  shrink by itself. The media folder is separate (it stays where it is).
- Internet access. The station streams to the external Icecast server over
  the internet, so the internet connection is part of the air chain.
- **Docker Desktop must not be installed.** Uninstall it first if it is.

### 1.2 BIOS/UEFI settings (by hand, once)

Enter the BIOS/UEFI setup (usually Del or F2 at power-on) and set:

- **Restore on AC power loss: Power On** (the name varies: "AC Back",
  "After Power Loss", "Restore AC Power Loss"). After a power cut the
  machine starts by itself, and the station starts without anyone signing
  in.
- **Virtualization: enabled** ("Intel Virtualization Technology", "VT-x",
  "SVM Mode", or "AMD-V").

A UPS (uninterruptible power supply) is recommended.

### 1.3 Security note: Windows 10 without ESU

Windows 10 reached its end of support on 14 October 2025. Without Extended
Security Updates (ESU) the machine gets **no more security fixes**
(Microsoft Defender signatures still update). The station accepts this
because it exposes no inbound port: the panel, Grafana, and the live voice
port are reachable from this PC only, never from the network. Therefore:

- **Do not use the station PC for email, web browsing, or downloads** other
  than this runbook's steps.
- Do not install other software on it.
- An upgrade to Windows 11 is recommended later. After an upgrade, run
  `install.bat` again: it switches to Windows 11's mirrored networking by
  itself.
- If the machine does get updates (ESU enrolled, or Windows 11): in
  Settings > Windows Update use **"Pause updates"** (up to 5 weeks), and
  install updates by hand in a maintenance window (section 7), followed by
  the reboot check (11.2).

### 1.4 What to have ready

| Item | From | Notes |
|------|------|-------|
| GitHub user name and **read-only token** for the images | the developer | a fine-grained token, read-only on the `radio-atlantida-*` packages; write its **expiry date** in 1.6 |
| The **Icecast source password** of the mount `/atlantida` | the stream server's owner | typed once, kept in the station's `.env` |
| Where the station's tracks are | you | the Windows folder of tracks, for example `D:\RadioAtlantida\media` |
| A password for the Windows account `radio` | you choose | needed for the boot task; never expires |

### 1.5 The external Icecast server

The station streams to `https://listen.teploe.net:8001/atlantida`
(Icecast 2.4.4). There is no Icecast on the station PC. For the operator
and the server's owner:

- **TLS on port 8001.** Port 8001 accepts TLS only (plain HTTP is reset).
  The station's source connection and the outage detector's
  `GET /status-json.xsl` both use it. The server must stay reachable over
  TLS on 8001. Listeners use port 8100 (plain HTTP).
- **Mount `/atlantida`.** Its source password is `ICECAST_SOURCE_PASSWORD`
  in the station's `.env`, typed at the first run. Until the cut-over
  (section 4) the mount carries the source of the current playout system.
- **Charset.** Ask the server's owner to set `<charset>UTF-8</charset>` on
  `/atlantida`. Until then Cyrillic and Armenian titles show as `*` in the
  listeners' players and on the status page (accepted).
- **Outages.** The station watches the server. If the server or the
  internet connection fails, the panel shows an outage, and the items
  planned during it are marked missed.
- The stream format (host, port, mount, TLS, codec, bitrate, sample rate,
  channels, name, description, genre) is set in the panel under
  **"Stream output (Icecast)"**, not in files. The first run writes
  `listen.teploe.net`, `8001`, `/atlantida`, TLS on, MP3, 160 kbps,
  44100 Hz, stereo, "Radio Atlantida" (the format of the current stream).

### 1.6 Record sheet

Keep this filled in (on paper next to the PC, or in a safe place).

| What | Value |
|------|-------|
| Install date | |
| Windows edition and build (`winver`) | |
| ESU enrolled? | |
| Install folder (`-InstallRoot`) | `C:\RadioAtlantida` |
| Media folder | |
| GHCR user | |
| GHCR read token **expires on** | |
| Network mode (NAT on Windows 10, mirrored on Windows 11) | |
| Cut-over date and time | |

The token is never written here, only its expiry date. Renew it before it
expires (10.6).

---

## 2. First install

### 2.1 Create the account `radio` (once)

1. Sign in to Windows with any administrator account.
2. Download this repository as a ZIP from GitHub
   (`https://github.com/AstRonin/radio-atlantida-deploy`, Code > Download
   ZIP) and unpack it, for example to `C:\Install\radio-atlantida-deploy`.
3. In that folder, open a Command Prompt and run:

   ```bat
   install.bat -CreateAccount
   ```

   Type the new password twice (nothing is shown while you type). The
   account `radio` is a local administrator whose password never expires.
4. Sign out.

Why a separate account: the Linux part of the station belongs to the
Windows account that installed it, and the boot task runs as that account
without anyone signed in.

### 2.2 Run the install

1. Sign in to Windows as **`radio`**.
2. Copy the unpacked repository folder somewhere `radio` can read it (or
   download it again as `radio`).
3. Double-click **`install.bat`**. Accept the UAC prompt (it elevates
   itself; the account stays `radio`).
4. If Windows features had to be turned on, it asks to restart. Restart.
   After the restart, **sign in as `radio`**: the install continues by
   itself (a one-time logon task "Radio Atlantida install resume", which
   deletes itself).
5. Answer its questions:
   - the station's **Windows media folder** (default
     `D:\RadioAtlantida\media`). It must already exist, on an internal,
     fixed NTFS drive: not a network share, not a mapped drive, not a USB
     disk;
   - the **Windows Update active hours** (default 06:00 to 24:00, at most
     18 hours);
   - the **Windows password of `radio`** (stored only by Windows Task
     Scheduler, for the boot task);
   - then the questions of the first run: the **GHCR user**, the **read
     token**, the **Icecast source password** (none of them is shown or
     logged), and whether to save the proposed **stream settings** (answer
     yes).
6. At the end the install shows a summary: the Windows build, the network
   mode, the versions installed, the media folder, the next steps, and the
   log file. **The Grafana admin password is shown once**, by the first run,
   above the summary. Write it down in a safe place; it is never shown
   again.
7. The window waits for Enter. Close it.

The first run starts every service except Liquidsoap: the old system still
sends its stream to `/atlantida` until the cut-over (section 4).

Options of `install.bat` (type them after `install.bat`):

| Option | Meaning |
|--------|---------|
| `-DryRun` | check every step and show what it would do; change nothing |
| `-Yes` | accept the defaults of the media folder and active hours questions |
| `-MediaFolder "D:\Radio\media"` | the media folder, without the question |
| `-InstallRoot D:\RadioAtlantida` | install folder (default `C:\RadioAtlantida`); the virtual disk goes to `<InstallRoot>\wsl` |
| `-ActiveHoursStart 6 -ActiveHoursEnd 0` | the active hours, without the question |

Every run writes a log: `C:\ProgramData\RadioAtlantida\logs\install-<UTC time>.log`.
The finished steps are recorded in `C:\ProgramData\RadioAtlantida\install-state.json`.

### 2.3 What the install did

| Step | What |
|------|------|
| Preflight | checks Windows build and update level, edition, newest update (KB) and its date, ESU status (only logged; an old patch level only warns), 64-bit, virtualization, signed in as `radio`, no Docker Desktop, 40 GB free, internet (Ubuntu images, Docker, GHCR, GitHub); on Windows 10 it shows the support note once |
| Windows features | turns on "Windows Subsystem for Linux" and "Virtual Machine Platform"; restart and resume if needed |
| WSL | `wsl --update` (the Microsoft Store WSL), WSL 2 as default, at least the version pinned in `install/versions.env` |
| Network mode | Windows 11 22H2 or later: mirrored; otherwise NAT |
| `.wslconfig` | in `C:\Users\radio\.wslconfig`: memory half the RAM (4 to 16 GB), processors half the CPUs (at least 2), swap 4 GB, no idle shutdown of the VM; the network mode; your other keys are kept |
| Folders | checks the media folder; adds a Microsoft Defender exclusion for it and turns off its indexing; creates `C:\RadioAtlantida\backups` (the Windows copy of the backups) |
| Distribution | downloads the pinned Ubuntu 24.04 image, checks its SHA-256, imports it as the WSL distribution `radio-atlantida` into `<InstallRoot>\wsl`; an existing one is kept |
| Linux half | inside the distribution: users, Docker Engine and Compose at the pinned versions (held: an `apt upgrade` never changes them), automatic Ubuntu security updates (no automatic reboot), the boot units and the backup timers |
| Keep-alive task | Task Scheduler task "Radio Atlantida WSL": at boot and every 5 minutes, as `radio`, whether signed in or not; it keeps the distribution running |
| Host settings | no sleep, hibernation, or disk timeout on AC power; Fast Startup off (a shutdown is a real cold boot); active hours; Windows Time with NTP |
| Deploy repository | clones this repository to `/opt/radio-atlantida/deploy` inside the distribution and runs the first run (`radioctl first-run`) |
| Shortcuts | on the desktop: "Radio panel", "Radio media", "Radio update", and "Radio Grafana" when monitoring is on |

Running `install.bat` again is safe: it checks every step against the real
state and skips what is in place. A step that would stop the Linux part (a
changed `.wslconfig` or `/etc/wsl.conf`) asks first, because it interrupts
the air.

### 2.4 Check the install

1. Double-click **"Radio panel"**. The panel opens at `http://127.0.0.1:8080`.
2. Run `update.bat status`. Expect: the release, every container `running`
   (`healthy`) except `liquidsoap` (`exited` or not listed: it waits for
   the cut-over), backups with one daily backup, disk space, and the media
   folder `ok`.
3. Do the cold-reboot test now (11.2), before any air time.

---

## 3. Before the first air

All of this is done in the panel ("Radio panel").

1. **Media.** Copy new tracks into the station's Windows media folder
   (shortcut "Radio media"), then import the folder in the panel. The import
   registers the files where they lie; it never copies, moves, or renames.
   The rules of the media folder:
   - **Add files freely.**
   - **Never rename, move, or delete a file that is in the plan.** Liquidsoap
     would skip it and the item is reported as missing. To change a track's
     file, use **Replace file** in the panel.
   - Keep the folder on the same internal drive. If the drive is missing at
     boot, the backend and Liquidsoap do not start (on purpose: they never
     see an empty folder), and `update.bat status` shows `MISSING`.
   - The Defender exclusion and the indexing setting of the folder were set
     by the install; leave them.
2. **Grid and clocks**: build them, and let the plan cover at least the next
   24 hours.
3. **Emergency playlist**: set it (it plays when nothing else can).
4. **Stream settings**: "Stream output (Icecast)" shows the values of 1.5.
   Leave them for the cut-over.

---

## 4. Cut-over to this system, and undo

The mount `/atlantida` carries the old system's stream until you switch.
Choose a quiet time.

### 4.1 Cut-over

1. Run `update.bat status`. Every service except `liquidsoap` is healthy.
2. **Stop the old source** on the old system.
3. Run:

   ```bat
   update.bat cutover
   ```

   It checks that the backend is ready, the plan covers the next 24 hours,
   an emergency playlist is set, and the stream settings point to
   `listen.teploe.net:8001/atlantida` with TLS. If something is missing, it
   lists it and stops; nothing is changed.
4. Type **`CUTOVER`** when asked. Liquidsoap starts and connects. Within
   60 seconds it reports `Cut-over done` and the listen address.
5. **Listen to the stream** (`http://listen.teploe.net:8100/atlantida` in a
   player, or on another device) and check by ear.
6. Write the date and time in the record sheet (1.6).

From now on Liquidsoap starts at every boot like every other service.

### 4.2 Undo

If the stream is wrong and cannot be fixed at once:

1. Run `update.bat cutover --undo` and type **`CUTOVER`**. Liquidsoap
   stops.
2. Start the old source on the old system again.

The panel may show an outage for the gap. Run `update.bat cutover` again
when ready.

If `update.bat cutover` says Liquidsoap did not connect within 60 seconds,
it keeps retrying; check 10.4 ("Liquidsoap not connected"), or undo.

---

## 5. Daily operation

### 5.1 The panel

- Open it with "Radio panel" (`http://127.0.0.1:8080`). It works only on
  this PC, and the microphone for live voice works without HTTPS because
  the address is `127.0.0.1`.
- Live voice: the browser on this PC sends to the station's own address
  (in NAT mode the address of the Linux VM, which changes at every boot and
  is set by the station at boot). Nothing is reachable from the network.

### 5.2 Status

`update.bat status` shows, in plain lines:

- **Release**: the running release, the previous one, the one in
  `release.env`, the last result, whether the cut-over is done.
- **Containers**: each service and its health; the result of the last boot
  check (`ok: stack healthy at VM uptime N s`, `LATE: ...`, or
  `FAILED: ...`); the live voice address.
- **Air**: broadcast state, live on air, control link, output state, queued
  items.
- **Pending maintenance**: changes that wait for a maintenance window
  (section 7).
- **Backups**: the last daily backup (with the journal and Windows copy
  results), `OVERDUE` if no backup succeeded for 26 hours, the last update
  dump, the last restore drill, `DUE` if the last good drill is older than
  35 days.
- **Disk**: free space of the deploy folder, the backups, and the media
  folder; `LOW SPACE` below 15 %.
- **Media**: `ok`, `MISSING` (the drive is not there), or `NOT WRITABLE`.

Look at it once a day, and after every restart.

### 5.3 Stream output settings

Change them in the panel under "Stream output (Icecast)". A change applies
at once, with a gap of a few seconds in the stream; no restart and no
maintenance window. The panel refuses combinations the encoder cannot run.

### 5.4 Monitoring (Grafana)

- "Radio Grafana" opens `http://127.0.0.1:3000` (user `admin`, the password
  shown once at the first run). It shows the database view and the logs.
  It is optional; the station runs without it.
- Turn it off or on: set `MONITORING_ENABLED=false` (or `true`) in `.env`
  (10.6 shows how to edit `.env`) and run `update.bat`. The "Grafana" link
  in the panel follows at the next release install.
- Forgotten admin password:

  ```bat
  update.bat compose exec grafana grafana cli admin reset-admin-password NEW-PASSWORD
  ```

  Then also set `GRAFANA_ADMIN_PASSWORD=NEW-PASSWORD` in `.env` (it is used
  only when Grafana's data is created, but keep them equal).
- Change the database password Grafana reads with: set a new
  `GRAFANA_DB_PASSWORD` (letters and digits only) in `.env` and run
  `update.bat`; it updates the read-only role and restarts Grafana.

---

## 6. Updates and rollback

`update.bat` (and `update.bat <command>`) runs the update tool `radioctl`
inside the Linux part as the user `radio`. **It is the only way to change
the station.** It records what a rollback and a restore need; manual
`docker compose` commands are for looking only (`update.bat compose ps`).

Every changing command writes a log: `logs/<command>-<UTC time>.log` in
the deploy folder (10.1 shows where). `update.bat logs` shows the last one.

### 6.1 Install the new release

Double-click **"Radio update"** (or run `update.bat`). It:

1. checks Docker and the configuration (`.env`);
2. downloads the newest version of this repository (`git pull`) and shows
   what changed;
3. checks the release in `release.env`: both images exist with the
   recorded digests, the versions fit together, the release is not older
   than the database allows;
4. checks the air: an open outage stops the update; live voice on air asks
   first; Liquidsoap must have at least 2 items queued; it waits until the
   next hour's items have been sent (a few minutes before and one minute
   after the full hour);
5. downloads the images (the air is not touched);
6. **makes a database dump** (always; there is no way to skip it);
7. runs the database migrations while the old backend still runs;
8. restarts the backend: **the panel and live voice drop for about 30
   seconds; the stream continues** (Liquidsoap plays its queue);
9. then the panel, then Loki, Alloy, and Grafana (their problems are only
   warnings);
10. reports pending maintenance (section 7) without doing it.

When it ends with `Done`, the new release runs. If anything fails, it ends
with:

> Update to X failed and was undone. Broadcasting continues on Y. Send the
> log logs/update-....log to the developer.

Nothing else is needed from you: the previous release runs again (a
failed migration is undone; if the database could not be undone it is
restored from the dump made a minute before). Send the log file named in
the message to the developer. The only other message is "the database could
not be restored automatically; the developer must check it": then call the
developer.

Options (after `update.bat`): `--dry-run` (show every step, change
nothing), `--yes` (answer yes to the ordinary questions, never to a typed
word), `--no-wait` (stop instead of waiting for the hour boundary).

### 6.2 Install a given release, or roll back

- `update.bat 1.0.3` installs release 1.0.3 (backend and panel); `update.bat
  1.0.3 1.0.4` gives the panel another patch version. Newer or older; never
  below 1.0.0. An older release is refused when the database no longer
  supports it; the tool then names the dump to restore (9.2).
- `update.bat rollback` installs the release that ran before the last
  update, exactly as it was (by digest).
- The next plain `update.bat` returns to `release.env`.

Both have the same effect on air as an update (6.1).

### 6.3 Docker Engine, WSL, and Windows updates

These are done in a maintenance window (section 7):

- **A new `install/versions.env`** (the developer pins a new Docker Engine,
  Compose, or Ubuntu image): after `update.bat` has pulled it, every update
  stops with "Docker Engine is X, install/versions.env pins Y; run
  install.bat". Then:
  1. download this repository again as a ZIP (2.1 step 2) and unpack it
     over the old copy, so the Windows copy has the new `versions.env`
     (`install.bat` uses the Windows copy, not the one inside the
     distribution);
  2. run `install.bat` in a maintenance window; it upgrades the engine and
     restarts the containers;
  3. run `update.bat`, then the reboot check (11.2).
- **WSL** (`wsl --update`) and **Windows updates**: install by hand in a
  maintenance window, restart, then the reboot check.

---

## 7. Maintenance window

Some changes stop the stream for a few seconds, so they wait for a time
you choose: a new Liquidsoap image or playout script, a new PostgreSQL
image, a changed database or Liquidsoap definition. `update.bat` and
`update.bat status` list them as **pending maintenance**.

1. Choose a quiet time (no live voice, nothing important planned).
2. Run `update.bat maintenance`. It shows the pending changes and the items
   planned for the next 15 minutes, and warns what stops.
3. Type **`MAINTENANCE`**.
4. A database change makes a dump first. Liquidsoap restarts with an empty
   queue; the backend refills it at once. The stream is silent for some
   seconds; the panel records an outage and marks items missed unless the
   journal confirms they played.
5. It ends when Liquidsoap is connected again (within 60 seconds). If not,
   it says so and offers to return to the previous image.

Docker Engine, WSL, and Windows updates (6.3) are done in the same kind of
window.

---

## 8. Backups

### 8.1 What is backed up, and where

The database and the playout journal (the record of what aired). The media
folder is ordinary Windows files and is **not** backed up by the station:
copy it with any Windows backup tool.

| Where | What |
|-------|------|
| `/srv/radio/backups` inside the distribution (`\\wsl.localhost\radio-atlantida\srv\radio\backups` in Explorer) | the backups |
| `C:\RadioAtlantida\backups` | the same files, a copy on the Windows drive |

In both places:

| Folder | What |
|--------|------|
| `daily\db-<UTC>.dump` | the daily database dump |
| `update\db-<UTC>.dump` | the dump before every update, database maintenance, and restore |
| `daily\journal-<date>\`, `update\journal-<date>\` | the playout journal files, copied with the dumps of that day |

### 8.2 Schedule

- **Daily at 04:30 station time** (Yerevan) the timer `radio-backup.timer`
  runs `update.bat backup`: an online dump (the air is not affected), the
  journal copy, the Windows copy, and the clean-up. If the PC was off at
  04:30, it runs after the next start. It never runs during an update.
- `update.bat backup` runs it now.
- A failed backup is shown by `update.bat status` (`OVERDUE` after 26
  hours) and by the next `update.bat`. A missing or unwritable Windows copy
  folder is only a warning: the backup itself succeeded. Never create the
  Windows copy folder from inside Linux; if it is missing, create
  `C:\RadioAtlantida\backups` in Explorer.

### 8.3 How long backups are kept

In both places: the newest 14 daily dumps and the newest 14 update dumps.
Never deleted automatically: the dump of the last update, and the dumps
before the last 3 updates that raised the database's minimum release (the
only way back to an older release after such an update). A journal folder
goes with the last dump of its day.

To free space: `update.bat status` shows the free space. An older
"boundary" dump in `update\` may be deleted by hand in both places, after
asking the developer. **Never** delete the dump named in `state.json` as
`last_dump` (shown by `update.bat status` as "last update dump").

### 8.4 The risk

There is **no off-site copy**. A failure of the PC's disk loses the
database, both copies of the backups, the journal, and the media folder
together. Recovery point: at most 24 hours old (the daily dump), or seconds
before an update. **Never run `wsl --unregister radio-atlantida`**: it
deletes the virtual disk with the database and the backups inside it; only
`C:\RadioAtlantida\backups` would remain.

---

## 9. Restore and the monthly drill

### 9.1 Restore the database

```bat
update.bat restore
update.bat restore db-2026-11-20T043000Z.dump
```

Without a name it restores the dump of the last update. With a name it
takes a path, `daily\<name>` or `update\<name>`, or just the file name; it
looks in `/srv/radio/backups` first, then in `C:\RadioAtlantida\backups`.

1. It shows the dump's name and UTC time.
2. Type **`RESTORE`**. Every change made after that time is lost (plan,
   play log, settings, library edits).
3. It makes a safety dump of the current database, stops the backend (the
   stream continues from Liquidsoap's queue), restores, starts the backend,
   and checks it.

A restore does not change the release. After a restore you may need
`update.bat rollback` (the developer tells you).

### 9.2 Going back past a database change

If `update.bat <older release>` is refused because the database no longer
supports it, the tool lists the dumps taken before that change, newest
first, with what would be lost. Choose with the developer, then type
`RESTORE`; the tool restores the dump and installs the older release.

### 9.3 Monthly restore drill

On the 1st of every month at 05:30 station time, `radio-restore-drill.timer`
restores the newest daily dump into a **scratch** database, checks it, and
deletes the scratch database again. It never touches the station's
database. `update.bat restore-drill` runs it now. `update.bat status` shows
the last drill, and `DUE` after 35 days. A failed drill means the backups
may not be usable: send `logs/restore-drill-*.log` to the developer the
same day.

### 9.4 Production data to development

Copy a dump from `C:\RadioAtlantida\backups` to the developer by hand
(USB stick or a file share). The developer restores it into the dev stack
with `pg_restore --clean --if-exists`. Data never goes the other way.

---

## 10. Troubleshooting

### 10.1 Where the logs are

The deploy folder inside the distribution is `/opt/radio-atlantida/deploy`.
In Explorer: `\\wsl.localhost\radio-atlantida\opt\radio-atlantida\deploy\logs`.

| Log | Written by | When |
|-----|------------|------|
| `logs\update-<UTC>.log` | `update.bat` (also `rollback-`, `restore-`, `maintenance-`, `cutover-`, `first-run-`) | every changing command; `update.bat logs` shows the last one |
| `logs\backup-<UTC>.log`, `logs\restore-drill-<UTC>.log` | the timers or `update.bat backup` / `restore-drill` | daily, monthly |
| `logs\boot-<UTC>.log` | `radio-boot-check.service` | every boot: when the stack became healthy; the last line is shown by `update.bat status` |
| `logs\network-<UTC>.log` | `radio-network.service` | every boot: the live voice address, and whether the backend was recreated for it |
| `logs\keepalive.log` | the keep-alive task | one line per start of the distribution by the task |
| `C:\ProgramData\RadioAtlantida\logs\install-<UTC>.log` | `install.bat` | every install run |
| container logs | `update.bat logs backend` (or `liquidsoap`, `db`, `frontend`, ...) | the last 200 lines of that service |

Times in log names and lines are UTC (Yerevan is UTC+4).

When you send logs to the developer, send the file; never send `.env`
(it holds the passwords).

### 10.2 A shell inside the distribution

Some steps need a Linux shell. Open a Command Prompt and type:

```bat
wsl -d radio-atlantida
```

You are the user `radio`. `cd /opt/radio-atlantida/deploy` is the deploy
folder. `exit` closes the shell. Never use `wsl --unregister` or
`wsl --shutdown` unless a step says so (`--shutdown` stops the station).

### 10.3 The stack did not start after a restart

What happens at boot, with nobody signed in: the Task Scheduler task
"Radio Atlantida WSL" starts the distribution and keeps it running (it
writes a line to `logs\keepalive.log`) -> WSL mounts the Windows drives
(the media folder) -> systemd starts Docker -> `radio-network.service`
writes the live voice address (`logs\network-*.log`; in NAT mode it changes
at every boot, and the backend is recreated when it changed) -> Docker
starts the containers -> `radio-boot-check.service` waits up to 10 minutes
and writes `logs\boot-*.log` (`ok`, `LATE`, or `FAILED`).

Sign in as `radio` and run `update.bat status`.

1. **`update.bat` says the distribution does not exist**: you are signed in
   with another account. Sign in as `radio`.
2. **No containers / Docker does not answer**: the distribution did not
   start. Open Task Scheduler > "Radio Atlantida WSL" > History: the task
   should have started at boot and be running. Check `logs\keepalive.log`
   for a line from this boot. If the task did not run without a sign-in,
   this is the known fallback case (11.1, keep-alive item): tell the
   developer.
3. **Last boot check `FAILED: ...`** names the services that were not
   healthy. Look at `update.bat logs <service>`.
4. **`MISSING` media folder**: the drive of the media folder was not there
   at boot. Connect it and restart the PC (or run `update.bat` to start the
   services again).
5. **`LATE: ...`**: the stack became healthy, but later than 5 minutes.
   Note it and tell the developer if it repeats.

### 10.4 Problems and what to do

| Problem | Check | Then |
|---------|-------|------|
| The panel does not open | `update.bat status`: is `frontend` running? In NAT mode Windows reaches the panel through WSL's localhost forwarding; `wsl --status` shows WSL is running | if `frontend` runs and the page still does not open, restart the PC; if it repeats, tell the developer (11.1, NAT item) |
| Live voice does not connect | `update.bat status` shows "live voice on <address>:8189/udp"; `logs\network-*.log` of this boot | the address must be the VM's current address (NAT) or `127.0.0.1` (mirrored). Reload the panel page. If the address is old, restart the PC |
| "registry login failed" | the GHCR read token in `.env` expired or was revoked | renew it (10.6) |
| "Refused: the image ... was not found" | the release tag does not exist, or the token cannot read it | check the tag with the developer |
| An update ends with "failed and was undone" | the log named in the message | send it to the developer; the station runs on the previous release |
| "health timeout" | `update.bat logs backend` | the update was undone automatically; send the update log |
| Liquidsoap not connected to the server | `update.bat logs liquidsoap`: `401`/`403 Forbidden` = wrong password or the mount is busy (the old source still connected); TLS or certificate errors = the server's certificate; connection refused/timeouts = internet or server down | wrong password: see the note below; busy mount: stop the old source; server down: ask the server's owner. The panel shows an outage meanwhile |
| Non-Latin titles show as `*` | the mount's charset | ask the server's owner for `<charset>UTF-8</charset>` (1.5) |
| `OVERDUE` backups | `logs\backup-*.log` (the newest) | run `update.bat backup`; if it fails again, send the log |
| `LOW SPACE` | `update.bat status`, Disk | free space on that Windows drive; see 8.3 for old dumps |
| `NOT WRITABLE` media folder | the folder's Windows permissions | the station needs to write fixed files there (transcode, "Fix loudness"); tell the developer |
| "Docker Engine is X, install/versions.env pins Y; run install.bat" | a new `versions.env` came with the repository | 6.3 |
| "another radioctl run holds state.lock" (or it waits) | an update, backup, or drill is running | wait for it to finish |

**Changing the Icecast source password**: Liquidsoap reads it when it
starts. Edit `ICECAST_SOURCE_PASSWORD` in `.env` (10.6). `update.bat status`
then lists a pending Liquidsoap change; apply it with
`update.bat maintenance` (section 7; the stream stops for a few seconds) and
check that `update.bat status` shows output `connected`.

### 10.5 The station PC must be replaced or reinstalled

1. Copy `C:\RadioAtlantida\backups` to a USB disk (it has the database and
   journal dumps).
2. Install the new PC from section 2, with the same media folder contents.
3. Before the cut-over, copy the newest dump into
   `C:\RadioAtlantida\backups\daily\` on the new PC and restore it with
   `update.bat restore daily/<file name>` (9.1), then continue with
   section 3.

### 10.6 Edit `.env` (token, passwords, settings)

`.env` holds the station's passwords and per-machine settings. Edit it only
for the cases in this runbook.

1. Open a shell (10.2): `wsl -d radio-atlantida`.
2. `nano /opt/radio-atlantida/deploy/.env`
3. Change the one line, save with Ctrl+O and Enter, leave with Ctrl+X.
4. `exit`, then do what the step says (usually `update.bat`).

**Renewing the GHCR read token**: create the new token (the developer
does), set `GHCR_READ_TOKEN=<new token>` in `.env`, run `update.bat`, and
write the new expiry date in the record sheet (1.6).

---

## 11. Acceptance checklist (Windows) and the cold-reboot test

### 11.1 Windows acceptance

These could not be tested on the developer's Mac; each is marked "(verify
on Windows)" in the code or the plan. Run them on a Windows 10 machine of
the production build (or the production machine before air), and again
after a Windows update or a WSL or Docker Engine upgrade.

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
      (`memory` = half the RAM within 4 to 16 GB, `processors`, `swap`,
      `vmIdleTimeout`, `localhostForwarding`; `networkingMode` only in
      mirrored mode).
- [ ] `Register-ScheduledTask` accepts the keep-alive XML; the task runs as
      `radio` whether signed in or not (password stored), and WSL starts from
      it without a sign-in. Fallback if not: Sysinternals Autologon for
      `radio`, a lock-screen policy, and an "at logon" trigger.
- [ ] No idle shutdown: with nobody signed in, the stack still runs 30 minutes
      after boot (`logs/keepalive.log` has one line per boot); without the
      keep-alive task, WSL would stop the distribution (confirms plan 6.4).
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
      appears in `C:\RadioAtlantida\backups`.
- [ ] The Pester tests pass under Windows PowerShell 5.1 (CI job `windows`).
- [ ] An engine upgrade path works: with a changed `install/versions.env`,
      `update.bat` stops with "run install.bat", `install.bat` from a fresh
      copy upgrades Docker, and `update.bat` then succeeds (6.3).
- [ ] **Cold-reboot test** (11.2) passes.

### 11.2 Cold-reboot test (the reboot check)

Do it after the install, before the first air, and after every Windows,
WSL, or Docker Engine update.

1. Sign out (nobody signed in).
2. Switch the PC off completely (Start > Shut down; Fast Startup is off, so
   this is a cold boot), or cut the power if you test the BIOS setting.
3. Switch it on and note the time. Do not sign in.
4. Wait 10 minutes.
5. Sign in as `radio` and run `update.bat status`.

Pass when, **within 5 minutes of power-on**, the stack was healthy:

- before the cut-over: every service except `liquidsoap`;
- after the cut-over: every service, and Liquidsoap connected to the server
  (status: output `connected`).

How to read the time: the last boot check line (`ok: stack healthy at VM
uptime N s`) gives the seconds after the VM started; add the time from
power-on to the VM start. Windows' boot time:

```powershell
(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
```

and the keep-alive task's start in Task Scheduler's history (or the first
line of this boot in `logs\keepalive.log`).
