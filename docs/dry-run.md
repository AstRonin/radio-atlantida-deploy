# Mac dry run (Linux side)

The rehearsal of a release, and of every change to this repository that
touches `bin/radioctl`, `install/`, or `docker-compose.yml`, before it
reaches the station (deploy-init-plan.md D7 9.3). There is no staging
machine: the Linux half of the station runs in an Ubuntu 24.04 arm64 VM on
the developer's Mac, set up the way `install.ps1` sets up the WSL
distribution, in NAT-like mode (the Mac reaches the VM by its address, as
Windows 10 reaches the WSL VM). The Windows half is checked on Windows (the
acceptance list in `docs/runbook.md` §11).

Time: about two hours the first time, most of it waiting for images.

## What it covers, and what it cannot

| Rehearsed in the VM | Only on Windows (runbook §11) |
|---------------------|-------------------------------|
| `setup-distro.sh --network-mode nat` under systemd, twice (the second run changes nothing) | `install.ps1` itself: features, restart and resume, `wsl --import`, `.wslconfig`, the account checks |
| Docker Engine and Compose at the pinned versions (arm64 packages of the same versions) | the amd64 packages and images on the real CPU |
| `radio-network.service` writing the VM address, the backend recreate when it changes | WSL's localhost forwarding of the `docker-proxy` sockets; the UDP path from the Windows browser to the WSL VM; mirrored networking on Windows 11 |
| `radioctl first-run`, update, older release, refused downgrade, rollback, restore, maintenance, backup, restore drill, cut-over and undo | the keep-alive task starting WSL without a sign-in, WSL's idle shutdown |
| the cut-over against a test Icecast behind TLS, the backend's mount check over HTTPS | the production Icecast server, whichever the panel names at the station (today `listen.teploe.net:8001`, the default in `config/stream-defaults.json`; no source connection is made to it before the real cut-over) |
| the boot units after `reboot` (boot check, network) | the cold-reboot test within 5 minutes of power-on, Fast Startup, BIOS power-on |
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
| OrbStack (simplest) | `orb create ubuntu:noble radio-dryrun` | your user has your Mac uid (uid 1000 is free); `eth0` is reachable from the Mac (`radio-dryrun.orb.local`); a shell: `orb -m radio-dryrun` |
| UTM | Ubuntu Server 24.04 arm64 ISO, network "Shared Network" | name the installer's user `radio` (it gets uid 1000); the interface is `enp0s1`: see step 3.4 |
| Lima | `limactl start --name radio-dryrun --vm-type=vz --network=vzNAT template://ubuntu-24.04` | the Mac reaches the `lima0` address only: see step 3.4 |

Do not install Docker in the VM yourself: `setup-distro.sh` does it at the
pinned versions.

## 2. The repository in the VM

In the VM, as your user (with `sudo`):

```sh
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/AstRonin/radio-atlantida-deploy ~/deploy
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
versions with the apt pin and hold, and the units.

### 3.2 Media folder

On the station this is the Windows folder through the drive mount; here a
folder with the same owner, group, and group write:

```sh
sudo install -d -o 1000 -g 10001 -m 2775 /srv/radio/media
# A few test tracks, one with a Cyrillic and one with an Armenian name:
sudo -u radio cp /path/to/tracks/*.mp3 /srv/radio/media/
# The "Windows copy" of the backups: a second folder (on the station /mnt/c/...).
sudo install -d -o 1000 -g 1000 -m 0755 /srv/radio/wincopy
```

### 3.3 Second and third pass

```sh
sudo bash /var/lib/radio-atlantida/src/install/setup-distro.sh --network-mode nat --media-root /srv/radio/media
sudo bash /var/lib/radio-atlantida/src/install/setup-distro.sh --network-mode nat --media-root /srv/radio/media
```

The second pass starts Docker, sets the journal owner from the Liquidsoap
image, and checks systemd, the Docker and Compose versions, and the media
folder. The third ends with `setup-distro: nothing to change.` Check:

```sh
systemctl is-system-running        # running (or degraded: list with systemctl --failed)
docker version --format '{{.Server.Version}}'; docker compose version --short
apt-mark showhold                  # the five Docker packages
systemctl list-timers 'radio-*'    # radio-backup.timer, radio-restore-drill.timer
```

### 3.4 Network interface (UTM, Lima)

`radioctl network` reads the VM address from `eth0`. If the address the
Mac reaches is on another interface, add it to the dry-run environment of
step 5 (`RADIOCTL_NET_DEV=enp0s1` or `lima0`).

## 4. Deploy folder, test certificates, images

### 4.1 Deploy folder

```sh
sudo -u radio git clone https://github.com/AstRonin/radio-atlantida-deploy /opt/radio-atlantida/deploy
# A branch under test: sudo -u radio git -C /opt/radio-atlantida/deploy checkout <branch>
```

All later commands run as `radio` in that folder: `sudo -iu radio`, then
`cd /opt/radio-atlantida/deploy`.

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
image, so an update and a rollback can be rehearsed:

```sh
docker run -d --name dryrun-registry --restart unless-stopped -p 127.0.0.1:5000:5000 registry:2.8.3
git clone https://github.com/AstRonin/radio-atlantida-backend ~/backend
git clone https://github.com/AstRonin/radio-atlantida-frontend ~/frontend
for v in 1.0.0 1.0.1; do
  docker build -f ~/backend/docker/Dockerfile --build-arg VERSION=$v \
    -t 127.0.0.1:5000/radio-atlantida-backend:$v ~/backend
  docker build -f ~/frontend/docker/Dockerfile \
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
build; the two versions may be the same code, or the second one the change
under test. `release.env` is now a local change: use `--no-fetch` on every
`update`, so `git pull` does not run.)

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

As root, let the boot units and timers use it too (otherwise the boot-time
backend recreate would drop the override):

```sh
for u in radio-network radio-boot-check radio-backup radio-restore-drill; do
  sudo mkdir -p /etc/systemd/system/$u.service.d
  printf '[Service]\nEnvironmentFile=/home/radio/dryrun.env\n' | sudo tee /etc/systemd/system/$u.service.d/dryrun.conf >/dev/null
done
sudo systemctl daemon-reload
sudo systemctl start radio-network.service
cat /opt/radio-atlantida/deploy/runtime/network.env   # LIVE_UDP_BIND=0.0.0.0, LIVE_PUBLIC_IPS=<VM address>
```

The panel and Grafana are bound to the VM's `127.0.0.1`, as on the station.
From the Mac, forward them (the browser then uses `http://127.0.0.1:8080`, a
secure context, as on Windows):

```sh
ssh -N -L 8080:127.0.0.1:8080 -L 3000:127.0.0.1:3000 radio@<VM address>
```

(OrbStack: `ssh -N -L ... radio@radio-dryrun@orb`; set a password or key
for `radio` first.)

## 6. Rehearsal

Run each step as `radio` in `/opt/radio-atlantida/deploy` with the
environment of step 5, and check the result before the next one. Every
changing command writes `logs/<command>-<UTC>.log`.

| # | Command | Expect |
|---|---------|--------|
| 1 | `bin/radioctl first-run --media-root /srv/radio/media` | prompts for the GHCR user and token (option B: any non-empty value), the Icecast source password (any; the test Icecast takes it from `.env`); edit `.env` afterwards to `BACKUP_WINDOWS_COPY=/srv/radio/wincopy`; stream settings proposed with `icecast.test`, `8443` (the rest from `config/stream-defaults.json`): answer `e` once and keep every value with Enter to see the edit prompt, then `y`; everything starts except `liquidsoap`; the Grafana password shown once; the first backup |
| 2 | `bin/radioctl status` | the release, every service healthy except `liquidsoap`, live voice on the VM address, one daily backup |
| 3 | panel through the SSH tunnel | import `/media` (Cyrillic and Armenian names), build a grid and clocks covering 24 hours, set the emergency playlist |
| 4 | `bin/radioctl compose up -d icecast-test icecast-tls`, then `bin/radioctl cutover` (type `CUTOVER`) | preconditions met; the output shown is `icecast.test`, port 8443, TLS on, the mount and format of the panel, source password `set`; `Cut-over done` with the status page `https://icecast.test:8443/status-json.xsl`; listen on the Mac to `http://<VM address>:8100/atlantida`; `status`: output `connected`, broadcast `connected` (the mount check over HTTPS) |
| 5 | live voice from the Mac browser (panel through the tunnel) | the session connects to `<VM address>:8189/udp` |
| 6 | the hour-boundary and fallback acceptance test of design §8.10 (plan 5.3 task 5) | as described there |
| 7 | edit `release.env` to 1.0.1 (option B: its digests), `bin/radioctl --no-fetch update` | air check passes; dump in `/srv/radio/backups/update/`; migrations; the backend restarts while the stream continues (listen); `Done` |
| 8 | `bin/radioctl --no-fetch update 1.0.0` | older release: no migration; `Done` |
| 9 | `bin/radioctl compose exec -T db psql -U radio -d radio -c "UPDATE schema_compat SET min_app_version = '1.0.1'"`, then `bin/radioctl --no-fetch update 1.0.0`; afterwards set it back to `'1.0.0'` | refused: below `min_app_version`; the boundary dumps are offered; type nothing (Ctrl+C) |
| 10 | `bin/radioctl rollback` | the previous release by digest |
| 11 | `bin/radioctl restore` (type `RESTORE`) | safety dump, backend stopped and started, health gate; the stream continues |
| 12 | change one comment line in `config/liquidsoap/radio.liq`; `bin/radioctl status`; `bin/radioctl maintenance` (type `MAINTENANCE`); `git checkout config/liquidsoap/radio.liq`; `bin/radioctl maintenance` again | pending maintenance listed; the stream stops for some seconds and reconnects within 60 s |
| 13 | `bin/radioctl backup`; `ls /srv/radio/backups/daily /srv/radio/wincopy/daily` | the dump and the journal folder in both places |
| 14 | `bin/radioctl restore-drill` | `radio_restore_drill` restored, checked, dropped; `status` shows the drill |
| 15 | `sudo reboot`; after the boot `bin/radioctl status` | `logs/boot-*.log` ends `ok: stack healthy at VM uptime N s`; `logs/network-*.log` shows the address (and the backend recreate if it changed); Liquidsoap connected again; `systemctl list-timers 'radio-*'` |
| 16 | `bin/radioctl cutover --undo` (type `CUTOVER`) | `liquidsoap` stopped; `status`: cut-over not yet |
| 17 | `bin/radioctl --dry-run update` | every step printed, nothing changed |
| 18 | `bin/radioctl cutover` again (type `CUTOVER`), then the password change of runbook 10.7: Set a new `ICECAST_SOURCE_PASSWORD` in `.env`, `bin/radioctl compose up -d icecast-test` (the test Icecast reads the same `.env`), then `bin/radioctl maintenance` (type `MAINTENANCE`) | `liquidsoap environment changed (... ICECAST_SOURCE_PASSWORD)` listed, never the value; the panel shows `reconnecting` or an outage for the gap; Liquidsoap connected again within 60 s; `status`: broadcast `connected` |

**Before a release with migrations** (plan 9.3 item 2): restore a recent
production dump in the VM (`bin/radioctl restore <path>`, the file copied
into `/srv/radio/backups/update/`), then run `bin/radioctl --no-fetch
update` to the new release, with the previous release running: the
migration runs against real data while the old backend serves. For a
release with a contract migration, check that `min_app_version` was raised
(`SELECT min_app_version FROM schema_compat`) and that
`bin/radioctl --no-fetch update <previous tag>` is refused.

## 7. Clean up

Delete the VM (`orb delete radio-dryrun`, UTM: delete, `limactl delete
radio-dryrun`). Delete any production dump copied to the Mac after the
rehearsal.
