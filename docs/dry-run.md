# Mac dry run (Linux side)

The rehearsal of a release, and of every change to this repository that
touches `bin/radioctl`, `install/`, or `docker-compose.yml`, before it
reaches the station (deploy-init-plan.md D7 9.3). There is no staging
machine: the Linux half of the station runs in an Ubuntu 24.04 arm64 VM on
the developer's Mac, set up the way `install.ps1` sets up the WSL
distribution, in NAT-like mode (the Mac reaches the VM by its address, as
Windows 10 reaches the WSL VM). The Windows half is checked on Windows (the
acceptance list in `docs/runbook.md` §11).

Time: about two hours the first time, most of it waiting for images
(the first build of the backend and frontend images in the VM takes about
5 minutes on an M-series Mac).

Commands in a box run in the VM unless they say "on the Mac". With
OrbStack, `orb -m radio-dryrun` opens a shell as your user, and
`orb -m radio-dryrun sudo -iu radio` a shell as `radio`; a script can be
piped into either (`... bash -s <script`).

## What it covers, and what it cannot

| Rehearsed in the VM | Only on Windows (runbook §11) |
|---------------------|-------------------------------|
| `setup-distro.sh --network-mode nat` under systemd, three times (the later runs change nothing) | `install.ps1` itself: features, restart and resume, `wsl --import`, `.wslconfig`, the account checks; the first pass without systemd |
| Docker Engine and Compose at the pinned versions (arm64 packages of the same versions) | the amd64 packages and images on the real CPU |
| `radio-network.service` writing the VM address, the backend recreate when it changes | WSL's localhost forwarding of the `docker-proxy` sockets; the UDP path from the Windows browser to the WSL VM; mirrored networking on Windows 11 |
| `radioctl first-run`, update, older release, rollback, refused downgrade, restore, maintenance, backup, restore drill, cut-over and undo, a contract migration and the downgrade past it | the keep-alive task starting WSL without a sign-in, WSL's idle shutdown (the `radio-keepalive` helper itself can be run by hand) |
| the cut-over against a test Icecast behind TLS, the backend's mount check over HTTPS, UTF-8 titles on the mount | the production Icecast server, whichever the panel names at the station (today `listen.teploe.net:8001`, the default in `config/stream-defaults.json`; no source connection is made to it before the real cut-over) |
| the boot units after a restart of the VM (boot check, network) | the cold-reboot test within 5 minutes of power-on, Fast Startup, BIOS power-on |
| a media folder with group `radio-media` and group write on the VM's ext4 | the Windows media folder through the drive mount (9P): permissions, speed, Cyrillic names, Defender, indexing |
| the backup copy to a second folder | the Windows copy on `/mnt/c` |
| | Windows power, update, and time settings; clock agreement between Windows and WSL |

## 1. The VM

Any Ubuntu 24.04 arm64 VM where systemd is PID 1, the Mac can reach the
VM's address, and uid 1000 is free or is a user named `radio`
(`setup-distro.sh` creates `radio` as uid 1000 and refuses another user
there). At least 4 CPUs, 8 GB RAM, 40 GB disk.

| Tool | Create | Notes |
|------|--------|-------|
| OrbStack (simplest) | `orb create ubuntu:noble radio-dryrun` | see "OrbStack" below |
| UTM | Ubuntu Server 24.04 arm64 ISO, network "Shared Network" | name the installer's user `radio` (it gets uid 1000); the interface is `enp0s1`: see step 3.4 |
| Lima | `limactl start --name radio-dryrun --vm-type=vz --network=vzNAT template://ubuntu-24.04` | the Mac reaches the `lima0` address only: see step 3.4 |

Do not install Docker in the VM yourself: `setup-distro.sh` does it at the
pinned versions.

**OrbStack** (checked with OrbStack 2.2.5):

- Your user in the machine has your Mac uid (501), so uid 1000 is free.
  `eth0` has the address the Mac reaches (`orb list` shows it; also
  `radio-dryrun.orb.local`). systemd is PID 1 from the start.
- Your Mac home is mounted at the same path in the machine, so the VM can
  clone your local repositories, including commits not pushed yet.
- A machine is a container on the OrbStack VM's kernel: `/proc/uptime` is
  the OrbStack VM's uptime, not the machine's (step 5 has a drop-in for
  the boot check). Docker in the machine is its own engine, separate from
  the Mac's Docker (OrbStack's, or Docker Desktop's); nothing in this
  procedure touches the Mac's Docker or your dev stack.
- OrbStack forwards every TCP port the machine listens on at `127.0.0.1`
  to the same port on the Mac's `127.0.0.1` (setting
  `machines.forward_ports`, on by default), and ports on `0.0.0.0` to the
  Mac's LAN too (`machines.expose_ports_to_lan`). So the panel opens on the
  Mac at `http://127.0.0.1:8080` without a tunnel. A port the Mac already
  uses is not forwarded: the dev stack's Grafana holds `127.0.0.1:3000`,
  so give the station's Grafana another port (step 5). While the machine
  runs, a dev service that starts later may find its port taken by the
  forward; stop the machine (`orb stop radio-dryrun`) if that happens.
- OrbStack makes itself the Mac's default Docker context when installed
  (`docker context ls`; setting `docker.set_context`). If your dev stack
  runs in Docker Desktop, use `docker --context desktop-linux ...` for it.
- SSH: OrbStack's server is on `127.0.0.1:32222` with the key
  `~/.orbstack/ssh/id_ed25519`, and logs in as any user of the machine
  without a password: `ssh -p 32222 -i ~/.orbstack/ssh/id_ed25519
  radio@radio-dryrun@127.0.0.1`. (`ssh radio@radio-dryrun@orb` works only
  when `~/.ssh/config` includes OrbStack's SSH config.)

## 2. The repository in the VM

In the VM, as your user (with `sudo`):

```sh
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/AstRonin/radio-atlantida-deploy ~/deploy
# OrbStack: the local repository, with unpushed commits:
#   git clone file:///Users/<you>/.../radio-atlantida-deploy ~/deploy
# A branch under test: git -C ~/deploy checkout <branch>
# The copy install.ps1 makes (install/ and docker-compose.yml):
sudo mkdir -p /var/lib/radio-atlantida/src
sudo cp -R ~/deploy/install ~/deploy/docker-compose.yml /var/lib/radio-atlantida/src/
```

## 3. The Linux half (`setup-distro.sh`)

### 3.1 First pass

```sh
sudo bash /var/lib/radio-atlantida/src/install/setup-distro.sh --network-mode nat
```

Expect exit code 10 ("restart the distribution and run me again"): it wrote
`/etc/wsl.conf` (ignored outside WSL). It created the user `radio` (uid
1000), the group `radio-media` (gid 10001), installed Docker at the pinned
versions with the apt pin and hold, and the units. In a VM, systemd is
already PID 1, so this pass also started Docker and set the journal owner
(it pulls the Liquidsoap image); no restart is needed before the next pass
(on Windows, `install.ps1` runs `wsl --terminate` here).

### 3.2 Media folder

On the station this is the Windows folder through the drive mount; here a
folder with the same owner, group, and group write:

```sh
sudo install -d -o 1000 -g 10001 -m 2775 /srv/radio/media
# The "Windows copy" of the backups: a second folder (on the station /mnt/c/...).
sudo install -d -o 1000 -g 1000 -m 0755 /srv/radio/wincopy
```

A few test tracks, one with a Cyrillic and one with an Armenian name. The
backend's `dev/scripts/gen-media.sh` writes ten sine-tone MP3s with ffmpeg
in a container (Docker runs since 3.1); the others the same way. Any
readable copy of the script works (OrbStack: your Mac clone's path):

```sh
cd /tmp && sudo -u radio bash <backend repository>/dev/scripts/gen-media.sh /srv/radio/media
gen() { sudo -u radio docker run --rm --user 1000:10001 -v /srv/radio/media:/out \
  linuxserver/ffmpeg:9.0-cli-ls84 -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=$3:duration=$2:sample_rate=44100" -ac 2 -ar 44100 \
  -c:a libmp3lame -b:a 128k -metadata title="$4" -metadata artist="$5" "/out/$1"; }
gen 'Песня-тест.mp3' 200 466 'Песня тест' 'Тестовый артист'
gen 'Երգ-թեստ.mp3' 200 554 'Երգ թեստ' 'Թեստային կատարող'
```

### 3.3 Second and third pass

```sh
sudo bash /var/lib/radio-atlantida/src/install/setup-distro.sh --network-mode nat --media-root /srv/radio/media
sudo bash /var/lib/radio-atlantida/src/install/setup-distro.sh --network-mode nat --media-root /srv/radio/media
```

Both exit 0. On WSL the second pass is the one that starts Docker and sets
the journal owner; in a VM the first did, so both end with
`setup-distro: nothing to change.` after the checks (systemd, the Docker
and Compose versions, the media folder). Check:

```sh
systemctl is-system-running        # running (or degraded: list with systemctl --failed)
sudo docker version --format '{{.Server.Version}}'; docker compose version --short
apt-mark showhold                  # the five Docker packages
systemctl list-timers 'radio-*'    # radio-backup.timer, radio-restore-drill.timer
```

(Your own user is not in the group `docker`; `radio` is.)

### 3.4 Network interface (UTM, Lima)

`radioctl network` reads the VM address from `eth0`. If the address the
Mac reaches is on another interface, add it to the dry-run environment of
step 5 (`RADIOCTL_NET_DEV=enp0s1` or `lima0`).

## 4. Deploy folder, test certificates, images

### 4.1 Deploy folder

```sh
sudo -u radio git clone https://github.com/AstRonin/radio-atlantida-deploy /opt/radio-atlantida/deploy
# OrbStack, the local repository: sudo -u radio git clone file:///Users/<you>/.../radio-atlantida-deploy /opt/radio-atlantida/deploy
# A branch under test: sudo -u radio git -C /opt/radio-atlantida/deploy checkout <branch>
```

All later commands run as `radio` in that folder: `sudo -iu radio`, then
`cd /opt/radio-atlantida/deploy`. A fix made on the Mac during the
rehearsal reaches this copy with `git pull --ff-only` (the local
`release.env` change of 4.3 does not stop it).

### 4.2 Test Icecast certificate

A throwaway CA and a certificate for `icecast.test`, the TLS name of the
test Icecast in `tests/dryrun/compose.override.yml`:

```sh
mkdir -p ~/dryrun-certs && cd ~/dryrun-certs
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=dryrun-ca -keyout ca.key -out ca.pem
openssl req -newkey rsa:2048 -nodes -subj /CN=icecast.test -keyout key.pem -out server.csr
printf 'subjectAltName=DNS:icecast.test\n' > san.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 -extfile san.ext -out cert.pem
chmod 0644 ca.pem cert.pem key.pem && chmod 0755 . ~
cd /opt/radio-atlantida/deploy
```

(`key.pem` is readable by everyone so the unprivileged nginx can read it;
it is a test key.)

### 4.3 Application images

**A. GHCR (a real release).** `release.env` has the multi-arch digests;
the VM pulls the arm64 images with the same digests as production. Use a
read token at the first-run prompt. For an amd64 parity run, set
`DOCKER_DEFAULT_PLATFORM=linux/amd64` in the environment of step 5
(emulated; Liquidsoap timing is then not representative).

**B. Locally built images (before a release, or to rehearse unreleased
code).** A registry in the VM on `127.0.0.1:5000`, and two versions of each
image, so an update and a rollback can be rehearsed. The VM builds for its
own platform (arm64). 1.0.1 is built from a throwaway copy of the backend
with one more expand migration, so the update runs a migration; never add
it to your real clone:

```sh
docker run -d --name dryrun-registry --restart unless-stopped -p 127.0.0.1:5000:5000 registry:2.8.3
git clone https://github.com/AstRonin/radio-atlantida-backend ~/backend    # or file:///Users/<you>/...
git clone https://github.com/AstRonin/radio-atlantida-frontend ~/frontend
rm -rf ~/backend-1.0.1 && cp -a ~/backend ~/backend-1.0.1
n=$(ls ~/backend/internal/migrations/*.up.sql | sed 's|.*/||' | sort | tail -n 1 | cut -c1-4)
printf -- '-- dry run only: an expand migration\nCREATE TABLE dryrun_probe (id integer PRIMARY KEY);\n' \
  > ~/backend-1.0.1/internal/migrations/$(printf '%04d' $((10#$n + 1)))_dryrun_probe.up.sql
for v in 1.0.0 1.0.1; do
  src=~/backend; [ $v = 1.0.1 ] && src=~/backend-1.0.1
  docker build -q -f $src/docker/Dockerfile --build-arg VERSION=$v \
    -t 127.0.0.1:5000/radio-atlantida-backend:$v $src
  docker build -q -f ~/frontend/docker/Dockerfile --build-arg VERSION=$v \
    --build-arg API_VERSION="$(jq -r .info.version ~/frontend/api/openapi.json)" \
    -t 127.0.0.1:5000/radio-atlantida-frontend:$v ~/frontend
  docker push -q 127.0.0.1:5000/radio-atlantida-backend:$v
  docker push -q 127.0.0.1:5000/radio-atlantida-frontend:$v
done
digest() { docker buildx imagetools inspect --format '{{json .Manifest}}' "$1" | jq -r .digest; }
cat > release.env <<EOF
BACKEND_TAG=1.0.0
BACKEND_DIGEST=$(digest 127.0.0.1:5000/radio-atlantida-backend:1.0.0)
FRONTEND_TAG=1.0.0
FRONTEND_DIGEST=$(digest 127.0.0.1:5000/radio-atlantida-frontend:1.0.0)
EOF
```

(Check out the backend and frontend refs you want to rehearse before the
build. `VERSION` on the frontend build only makes the two frontend images
differ, as two releases do. `release.env` is now a local change: use
`--no-fetch` on every `update`, so `git pull` does not run.)

## 5. The dry-run environment

The switches of `bin/radioctl` (environment only, never `.env`), in one file
that both your shell and the systemd units read. `RADIOCTL_STREAM_OVERRIDE`
is merged over `config/stream-defaults.json`, the stream settings the first
run proposes; the cut-over then uses whatever the panel says, as at the
station:

```sh
cat > ~/dryrun.env <<'EOF'
RADIOCTL_COMPOSE_OVERRIDE=/opt/radio-atlantida/deploy/tests/dryrun/compose.override.yml
DRYRUN_CERTS=/home/radio/dryrun-certs
RADIOCTL_STREAM_OVERRIDE='{"stream.icecast_host":"icecast.test","stream.icecast_port":8443,"stream.name":"Radio Atlantida (dry run)"}'
# Option B (local registry) only:
RADIOCTL_BACKEND_IMAGE=127.0.0.1:5000/radio-atlantida-backend
RADIOCTL_FRONTEND_IMAGE=127.0.0.1:5000/radio-atlantida-frontend
# UTM or Lima only: RADIOCTL_NET_DEV=enp0s1
EOF
set -a; . ~/dryrun.env; set +a
```

Every later shell as `radio` needs the `set -a; . ~/dryrun.env; set +a`
line again; without it `radioctl` uses the GHCR images and no test
Icecast.

As root, let the boot units and timers use it too (otherwise the boot-time
backend recreate would drop the override):

```sh
for u in radio-network radio-boot-check radio-backup radio-restore-drill; do
  sudo mkdir -p /etc/systemd/system/$u.service.d
  printf '[Service]\nEnvironmentFile=/home/radio/dryrun.env\n' | sudo tee /etc/systemd/system/$u.service.d/dryrun.conf >/dev/null
done
# OrbStack only: the boot check measures the machine's uptime, not the OrbStack VM's.
sudo install -m 0644 /opt/radio-atlantida/deploy/tests/dryrun/orbstack-uptime.conf \
  /etc/systemd/system/radio-boot-check.service.d/orbstack-uptime.conf
sudo systemctl daemon-reload
sudo systemctl start radio-network.service
cat /opt/radio-atlantida/deploy/runtime/network.env   # LIVE_UDP_BIND=0.0.0.0, LIVE_PUBLIC_IPS=<VM address>
```

The panel and Grafana are bound to the VM's `127.0.0.1`, as on the station.
The browser on the Mac must use `http://127.0.0.1:...` (a secure context,
as on Windows, so the microphone works without HTTPS).

- OrbStack forwards both to the Mac by itself (section 1). After the first
  run, set `GRAFANA_PORT=13000` in `.env` and run `bin/radioctl --no-fetch
  update` if the Mac's port 3000 is taken (a dev stack's Grafana): it
  recreates Grafana and the panel only, and the panel's Grafana link
  follows (runbook 5.4).
- Otherwise forward them over SSH:

  ```sh
  # On the Mac
  ssh -N -L 8080:127.0.0.1:8080 -L 3000:127.0.0.1:3000 radio@<VM address>
  # OrbStack: ssh -N -p 32222 -i ~/.orbstack/ssh/id_ed25519 -L ... radio@radio-dryrun@127.0.0.1
  ```

## 6. Rehearsal

Run each step as `radio` in `/opt/radio-atlantida/deploy` with the
environment of step 5, and check the result before the next one. Every
changing command writes `logs/<command>-<UTC>.log`. Answers can be piped
(`echo CUTOVER | bin/radioctl cutover`); give `</dev/null` to commands
that ask nothing. An `update` started within `playout.prepush_minutes` + 1
minutes before a full hour (or in the first minute after it) waits for the
hour's items to be sent; `--no-wait` stops instead.

On the Mac, listen to `http://<VM address>:8100/atlantida` (the test
Icecast's listener port, plain HTTP) in any player, e.g. `ffplay` or VLC.
Its status page `http://<VM address>:8100/status-json.xsl` shows the
mount and the title (`source.title`).

| # | Command | Expect |
|---|---------|--------|
| 1 | `bin/radioctl first-run --media-root /srv/radio/media` | prompts for the GHCR user and token (option B: any non-empty value), the Icecast source password (any; the test Icecast takes it from `.env`); stream settings proposed with `icecast.test`, `8443` (the rest from `config/stream-defaults.json`): answer `e` once and keep every value with Enter to see the edit prompt, then `y`; everything starts except `liquidsoap`; the Grafana password shown once; the first backup, with the warning that the Windows copy folder (`/mnt/c/...`) does not exist. Then edit `.env`: `BACKUP_WINDOWS_COPY=/srv/radio/wincopy` (and `GRAFANA_PORT`, step 5) |
| 2 | `bin/radioctl status` | the release, every service healthy except `liquidsoap` (not listed), broadcast `unreachable` (nothing streams yet), live voice on the VM address, one daily backup |
| 3 | the panel (`http://127.0.0.1:8080` on the Mac) | import `/media` (Cyrillic and Armenian names), build a grid and clocks covering 24 hours, set the emergency playlist (or through the API: see below) |
| 4 | `bin/radioctl compose up -d icecast-test icecast-tls`, then `bin/radioctl cutover` (type `CUTOVER`) | preconditions met; the output shown is `icecast.test`, port 8443, TLS on, the mount and format of the panel, source password `set`; `Cut-over done` with the status page `https://icecast.test:8443/status-json.xsl`; on the Mac the stream plays and the status page shows the titles, Cyrillic and Armenian ones readable; `status`: output `connected`, broadcast `connected` (the mount check over HTTPS) |
| 5 | live voice from the Mac browser (the panel) | the session connects to `<VM address>:8189/udp` |
| 6 | the hour-boundary and fallback acceptance test of design §8.10 (plan 5.3 task 5) | as described there |
| 7 | edit `release.env` to 1.0.1 (option B: its digests), `bin/radioctl --no-fetch update` | air check passes; dump in `/srv/radio/backups/update/` and `/srv/radio/wincopy/update/`; migrations; the backend restarts while the stream continues (listen); `Done` |
| 8 | `bin/radioctl --no-fetch update 1.0.0` | older release: no migration; `Installed 1.0.0 (was 1.0.1)` |
| 9 | `bin/radioctl rollback` | the previous release (1.0.1) by digest; the migration step finds nothing to do |
| 10 | `bin/radioctl compose exec -T db psql -U radio -d radio -c "UPDATE schema_compat SET min_app_version = '1.0.1'"`, then `bin/radioctl --no-fetch update 1.0.0`; afterwards set it back to `'1.0.0'` | refused: the database needs at least 1.0.1; the restore points (pre-update dumps) are listed; type nothing (Enter or Ctrl+C): `Not confirmed`, nothing changed. (It must run while a release newer than 1.0.0 runs, so after step 9: with 1.0.0 running, `update 1.0.0` is "already running") |
| 11 | `bin/radioctl restore` (type `RESTORE`) | safety dump, backend stopped and started, health gate; the stream continues |
| 12 | change one comment line in `config/liquidsoap/radio.liq`; `bin/radioctl status`; `bin/radioctl maintenance` (type `MAINTENANCE`); `git checkout config/liquidsoap/radio.liq`; `bin/radioctl maintenance` again | `status` lists `liquidsoap script config/liquidsoap/radio.liq changed`; the stream stops for some seconds and reconnects within 60 s (both times: the checkout is a change too) |
| 13 | `bin/radioctl backup`; `ls /srv/radio/backups/daily /srv/radio/wincopy/daily`; as your user (`radio` has no `sudo`): `sudo systemctl start radio-backup.service` | the dump and the journal folder in both places; the unit runs the same backup with the dry-run environment |
| 14 | `bin/radioctl restore-drill` | `radio_restore_drill` restored, checked, dropped; `status` shows the drill |
| 15 | restart the VM (OrbStack, on the Mac: `orb restart radio-dryrun`; UTM, Lima: `sudo reboot`); after the boot `bin/radioctl status` | `logs/boot-*.log` ends `ok: stack healthy at VM uptime N s`; `logs/network-*.log` shows the address (and the backend recreate if it changed); Liquidsoap connected again; `systemctl list-timers 'radio-*'`. `RADIO_KEEPALIVE_SLEEP=0 /usr/local/bin/radio-keepalive` as `radio` writes its line to `logs/keepalive.log` |
| 16 | `bin/radioctl cutover --undo` (type `CUTOVER`) | `liquidsoap` stopped (`exited`); `status`: cut-over not yet; broadcast `unreachable` once the mount check notices (some seconds) |
| 17 | `bin/radioctl --dry-run update`, and `bin/radioctl --dry-run --no-fetch update 1.0.0` | every step printed, nothing changed (`state.json` and `runtime/` unchanged) |
| 18 | `bin/radioctl cutover` again (type `CUTOVER`), then the password change of runbook 10.7: Set a new `ICECAST_SOURCE_PASSWORD` in `.env`, `bin/radioctl status`, `bin/radioctl compose up -d icecast-test` (the test Icecast reads the same `.env`), then `bin/radioctl maintenance` (type `MAINTENANCE`) | `status` and `maintenance` list `liquidsoap environment changed (... ICECAST_SOURCE_PASSWORD)`, never the value; between the Icecast restart and the maintenance `logs liquidsoap` shows `401`, the panel `reconnecting` or an outage; Liquidsoap connected again within 60 s; `status`: broadcast `connected` |

**Step 3 through the API** (no clicks; the backend publishes no port, so
the calls go through its container; `jq` and `curl` as in `radioctl`):

```sh
api() { if [ -n "${3:-}" ]; then printf '%s' "$3" | docker exec -i radio-atlantida-backend-1 curl -sS -X "$1" \
  -H 'Content-Type: application/json' --data-binary @- "http://127.0.0.1:8090$2"; else
  docker exec radio-atlantida-backend-1 curl -sS -X "$1" "http://127.0.0.1:8090$2" </dev/null; fi; }
m=$(api POST /api/playlists '{"name":"Music","type_id":1,"clock_rule":"fill"}' | jq .id)
e=$(api POST /api/playlists '{"name":"Emergency","type_id":1,"clock_rule":"fill"}' | jq .id)
api POST /api/import "{\"type_id\":1,\"playlist_ids\":[$m,$e]}"      # an operation; GET /api/operations/<id>
c=$(api POST /api/clocks "{\"name\":\"Dry run hour\",\"playlists\":[{\"playlist_id\":$m}]}" | jq .clock.id)
api POST /api/grid/assign "{\"clock_id\":$c,\"weekdays\":[1,2,3,4,5,6,7],\"hours\":[$(seq -s, 0 23)],\"valid_from\":\"$(TZ=Asia/Yerevan date +%F)\"}"
api PATCH /api/settings "{\"values\":{\"playout.emergency_playlist_id\":$e}}"
```

(Type 1 is `music` in `GET /api/playlist-types`. The plan is built a few
seconds after the grid assignment.)

**Before a release with migrations** (plan 9.3 item 2): restore a recent
production dump in the VM (`bin/radioctl restore <path>`, the file copied
into `/srv/radio/backups/update/`), then run `bin/radioctl --no-fetch
update` to the new release, with the previous release running: the
migration runs against real data while the old backend serves. For a
release with a contract migration, check that `min_app_version` was raised
(`SELECT min_app_version FROM schema_compat`) and that
`bin/radioctl --no-fetch update <previous tag>` is refused.

**A contract migration with option B** (rehearses that path without a
real one): a throwaway 1.0.2 backend from the 1.0.1 copy, with a
migration that raises `min_app_version` and `TargetMinAppVersion` raised
with it (the frontend stays 1.0.1):

```sh
rm -rf ~/backend-1.0.2 && cp -a ~/backend-1.0.1 ~/backend-1.0.2
n=$(ls ~/backend-1.0.2/internal/migrations/*.up.sql | sed 's|.*/||' | sort | tail -n 1 | cut -c1-4)
printf -- "-- dry run only: a contract migration\nDROP TABLE dryrun_probe;\nUPDATE schema_compat SET min_app_version = '1.0.2', set_by_migration = %d, updated_at = now() WHERE id = 1;\n" \
  $((10#$n + 1)) > ~/backend-1.0.2/internal/migrations/$(printf '%04d' $((10#$n + 1)))_dryrun_contract.up.sql
sed -i 's/^const TargetMinAppVersion = .*/const TargetMinAppVersion = "1.0.2"/' ~/backend-1.0.2/internal/migrations/compat.go
docker build -q -f ~/backend-1.0.2/docker/Dockerfile --build-arg VERSION=1.0.2 \
  -t 127.0.0.1:5000/radio-atlantida-backend:1.0.2 ~/backend-1.0.2
docker push -q 127.0.0.1:5000/radio-atlantida-backend:1.0.2
cd /opt/radio-atlantida/deploy
bin/radioctl --no-fetch update 1.0.2 1.0.1 </dev/null
echo RESTORE | bin/radioctl --no-fetch update 1.0.1
```

Expect, on the update to 1.0.2: `1.0.1 cannot run on the migrated schema
(needs 1.0.2): stopping the backend first`, then `Installed backend 1.0.2,
frontend 1.0.1`, the stream continuing, and `min_app_version` 1.0.2. On
the way back: refused, the restore points listed (the newest is the dump
taken before 1.0.2), and after `RESTORE` the dump restored and 1.0.1
installed (`min_app_version` 1.0.0 again, runbook 9.2).

## 7. Clean up

Delete the VM (`orb delete radio-dryrun`, UTM: delete, `limactl delete
radio-dryrun`). Delete any production dump copied to the Mac after the
rehearsal.
