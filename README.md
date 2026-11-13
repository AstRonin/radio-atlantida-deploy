# radio-atlantida-deploy

Production stack of Radio Atlantida: the Compose file, configuration copies,
the Windows host installer, and the update tool. No application code; the
backend and frontend run as prebuilt images from GitHub Container Registry.

- **Operators:** [`docs/runbook.md`](docs/runbook.md) (install, daily
  operation, updates, maintenance, cut-over, backups, restore,
  troubleshooting, the Windows acceptance checklist).
- **Developers:** this file, [`docs/dry-run.md`](docs/dry-run.md) (the Mac
  rehearsal of a release), `docs/deploy-init-plan.md` (the plan), and
  `docs/tech-design.md` §9 (the design).

## Layout

| Path | What |
|------|------|
| `docker-compose.yml` | the production stack; infrastructure images pinned literally, application images by tag and digest from `runtime/applied.env` |
| `release.env` | the release this repository installs (`BACKEND_TAG`, `BACKEND_DIGEST`, `FRONTEND_TAG`, `FRONTEND_DIGEST`); a station release is a PR that changes it |
| `.env.example` | the template of the station's `.env` (written by `radioctl first-run`, never committed) |
| `config/` | copies of the backend's `dev/` files at the release: `liquidsoap/radio.liq` (+ `production.patch`), `grafana/`, `loki/`, `alloy/`; `backend-source.env` records the backend commit. Also this repository's own `stream-defaults.json`: the stream settings `radioctl first-run` proposes (the current Icecast server; the panel settings are the truth afterwards) |
| `install.bat`, `install.ps1` | the Windows half of the host install (Windows PowerShell 5.1) |
| `install/` | the Linux half: `setup-distro.sh`, `wsl.conf`, `radio-keepalive`, the systemd units, `versions.env` (pinned Ubuntu rootfs, Docker Engine, Compose, buildx, WSL) |
| `update.bat`, `bin/radioctl` | the update tool (bash, inside the WSL distribution) |
| `scripts/` | the CI checks (below) and the shared bash libraries |
| `tests/` | bats (`radioctl`), Pester (`install.ps1`), the distro test, the Liquidsoap smoke test, fixtures, the dry-run compose override |
| `docs/` | the runbook and the dry run (maintained here), and the plans and design (copies pushed from `radio-atlantida-docs`) |

Runtime files (never committed), inside the distribution under
`/opt/radio-atlantida/deploy`: `.env`, `state.json`, `state.lock`,
`runtime/` (`applied.env`, `target.env`, `network.env`), `logs/`. Backups
are under `/srv/radio/backups` with a copy in `C:\RadioAtlantida\backups`.

Line endings: LF everywhere except `*.bat` and `*.ps1` (CRLF; `*.ps1` also
UTF-8 with BOM), set by `.gitattributes` and checked in CI.

## Tests and CI

`.github/workflows/ci.yml` runs on every push to `main` and every pull
request. Every job calls scripts of this repository, so each one runs the
same way on the Mac (bash, Docker; the Liquidsoap job also needs Go).

| Job (runner) | Command | Checks |
|--------------|---------|--------|
| `lint` (ubuntu) | `scripts/check-line-endings.sh` | `.gitattributes` eol per file (CRLF `*.bat`/`*.ps1`, LF elsewhere), LF in the index, the working tree matches, UTF-8 BOM on `*.ps1` only, no case-only path duplicates |
| | `scripts/check-shell.sh` | shellcheck 0.10.0 (pinned image) on every tracked bash file: `*.sh`, `*.bash`, and every file with a bash shebang (`bin/radioctl`, `install/radio-keepalive`, the test stubs) |
| | actionlint 1.7.7 (pinned image) | this workflow |
| `compose` (ubuntu) | `scripts/check-compose.sh` | renders with `.env.example` and the NAT and mirrored fixtures, with and without `--profile monitoring`: no `icecast`; application images are the release references, all others literal `name:tag`, no `latest` anywhere (compose files, Dockerfiles, script image variables); published ports only panel and Grafana on `127.0.0.1` and the UDP port on `LIVE_UDP_BIND`; media mounts are binds with `create_host_path` not true (Compose drops a false value), backend read-write, liquidsoap read-only; journal read-only in backend; one-shot jobs disable the health check; backend grace period 30 s and group 10001 |
| | `scripts/check-config.sh` | `loki -verify-config`, `alloy validate`, `alloy fmt` equal to the file (the pinned images, as the backend CI); Grafana provisioning YAML parses, dashboard JSON parses, every data source uid a dashboard uses is provisioned |
| `release` (ubuntu) | `scripts/check-release.sh` | tags X.Y.Z, at least 1.0.0, same MAJOR.MINOR; digests set once the backend tag exists (a warning before the first release); with digests, both Git tags exist; with the `GHCR_USER` variable and `GHCR_READ_TOKEN` secret, each digest is the tag's manifest list digest in GHCR |
| `backend-sync` (ubuntu) | `scripts/check-backend-sync.sh` | `config/` equals the backend's `dev/` at the backend ref (the script with `production.patch`), the contract header, the image pins equal `docker-compose.dev.yml` and `dev/liqsmoke/compose.yml` |
| `liquidsoap` (ubuntu, Go from the backend's `go.mod`) | `tests/liquidsoap/run.sh` | `liquidsoap --check` in the pinned image, then the backend's smoke tool (`dev/liqsmoke`) at the backend ref: every codec x channels x sample rate, the encoder limits, rapid output switches (4b), TLS, restart from the state file, the crash-loop guard (7) |
| `radioctl` (ubuntu) | `tests/radioctl/run.sh` | the bats tests of `bin/radioctl` (bats-core 1.11.1; docker, git, the clock stubbed) |
| `distro` (ubuntu) | `tests/distro/run.sh`, `tests/distro/run.sh --with-apt` | `setup-distro.sh` twice in `ubuntu:24.04` (files, users, units), `systemd-analyze verify` of the units; then the pinned Docker apt install (key, pin, hold) |
| `versions` (ubuntu) | `scripts/check-versions.sh --download` | `install/versions.env`: the rootfs URL answers, `SHA256SUMS` lists the pinned checksum, the downloaded file has it; Docker's apt key fingerprint; every pinned package version exists for noble amd64 |
| `install` (ubuntu) | `tests/install/run.sh` | the Pester tests of `install.ps1` (Pester 5.7.1, Windows mocked) and PSScriptAnalyzer 1.25.0 in PowerShell 7.5 (pinned image) |
| `windows` (windows-latest) | `tests\install\run-windows.ps1` | the same Pester tests and PSScriptAnalyzer settings under Windows PowerShell 5.1 |

Locally, the same commands; for example `tests/radioctl/run.sh -f restore`
runs the bats tests by name. Runners other than `windows` need only Docker.
Nothing touches the dev stack (`radio-atlantida-dev`): the smoke test uses
the compose project `radio-deploy-liqsmoke` on `127.0.0.1` ports 18000 and
11234 and a stub backend on port 18090, and removes it.

## Config sync with the backend

`config/liquidsoap/radio.liq` is the backend's `dev/liquidsoap/radio.liq` at
the release with `config/liquidsoap/production.patch` applied (the patch is
empty: the dev script reads every startup value from the environment, and
`docker-compose.yml` sets the production values). `config/grafana/`,
`config/loki/loki.yaml`, and `config/alloy/config.alloy` equal the backend's
`dev/` files. They are never edited here: a change is made in the backend,
released, and copied.

```sh
# Check (exit 1 on drift), or rewrite config/ from the backend with --update.
scripts/check-backend-sync.sh [--ref REF] [--backend-dir ../radio-atlantida-backend] [--update]
# liquidsoap --check, then the runtime smoke test at the same ref.
tests/liquidsoap/run.sh [--ref REF] [--backend-dir ../radio-atlantida-backend] [--check-only]
```

**The backend ref** (one rule for both scripts and CI,
`scripts/lib/backend-source.sh`; `scripts/backend-ref.sh` prints it):

1. `--ref`, else `BACKEND_REF` from the environment (CI: the workflow-level
   `env.BACKEND_REF`, empty by default);
2. else `v${BACKEND_TAG}` of `release.env` when that tag exists in the
   backend repository (or in `--backend-dir`);
3. else `BACKEND_SOURCE_COMMIT` of `config/backend-source.env`, with a
   warning (a `::warning::` annotation in CI). This covers the time before
   the first backend release tag. Once `release.env` has digests, the
   `release` job requires the tag, so the fallback cannot hide a missing
   tag.

Without `--backend-dir` the backend is fetched from its public GitHub
repository (no token); CI checks it out once per job with
`actions/checkout` at the resolved ref. `--update` records the commit in
`config/backend-source.env`. The contract header of the script
(`# radio-atlantida-contract: N`, `# min-backend: X.Y.Z`) is read by
`radioctl`: a new contract needs a Liquidsoap restart in a maintenance
window; a backend below `min-backend` is refused.

## A release of the station

1. Backend and frontend tag their releases (`vX.Y.Z`); the images are
   multi-arch manifest lists in GHCR.
2. A PR here sets `release.env` (tags and the manifest list digests from
   `docker buildx imagetools inspect`) and, if the backend's `dev/` changed,
   runs `scripts/check-backend-sync.sh --update` at the new tag.
3. CI is green; the dry run (`docs/dry-run.md`) passes, with the
   migration rehearsal on a production dump if the release has migrations.
4. Merge. On the station, the operator runs "Radio update"
   (`docs/runbook.md` §6).

A change of `install/versions.env` (Docker Engine, Compose, the Ubuntu
image) is applied with `install.bat` in a maintenance window (runbook
§6.3); `radioctl` refuses to update until the engine matches.

## `radioctl` dry-run and test switches

Environment only, never `.env`: `COMPOSE_PROJECT_NAME`,
`RADIOCTL_BACKEND_IMAGE`, `RADIOCTL_FRONTEND_IMAGE` (a test registry),
`RADIOCTL_COMPOSE_OVERRIDE` (an extra compose file, e.g.
`tests/dryrun/compose.override.yml`), `RADIOCTL_STREAM_OVERRIDE` (a JSON
object merged over `config/stream-defaults.json`, the stream settings the
first run proposes; the cut-over uses whatever the panel says), `RADIOCTL_HEALTH_TIMEOUT`, `RADIOCTL_LOCK_WAIT`, `RADIOCTL_NET_DEV`,
`RADIOCTL_FAKE_CLOCK` and the other test switches listed at the top of
`bin/radioctl`. `DOCKER_DEFAULT_PLATFORM=linux/amd64` forces amd64 images
for a parity run.
