# Frontend Initialization Plan (radio-atlantida-frontend)

Status: Draft for Claude Code
Based on: `docs/base.md` (requirements), `docs/tech-design.md` (technical design), `docs/backend-init-plan.md` (backend plan, for the shared conventions)
Last updated: 2026-10-13

## 0. How to use this plan

- **Context documents.** Before any work, Claude Code reads three files, which are copied into the repository under `docs/`:
  - `docs/base.md` — the product requirements. Use it to understand the goal of every screen, even when the current phase does not build it.
  - `docs/tech-design.md` — the technical design. It is the authority on how things are built, and §6 (API, settings, help, validation, track preview) is the part that defines the panel.
  - `docs/frontend-init-plan.md` — this plan. It says what to build now.
- This plan is the task list for Claude Code. Work one phase at a time. Each phase ends with a green build, passing tests, and a commit (one PR per phase).
- The technical design is the authority. If this plan and the design disagree, stop and ask.
- Section 9 lists decisions and open points. Items marked **ASK** must be confirmed by the developers before the phase that needs them. Items marked **DEFAULT** are applied unless the developers say otherwise.
- Scope of initialization: Phases F1 to F5. They produce a running panel with the application shell, the typed API client, error and live-update plumbing, shared UI (help, validation, time, track picker), the settings pages, and the library pages with track preview. Clocks, grid, rotation views, the played-tracks list, outages, and logs are later phases (Section 8).

## 1. Ground rules for the code

- **Single operator, no authentication.** The panel has no login, no roles, and no user menu. Do not add any auth scaffolding (no guards, no token storage, no login page). The API is reachable only on a private network (design §6, §10).
- **The backend is the authority.** The panel never writes request or response types by hand. All REST payloads and WebSocket event payloads use types generated from the backend specification (§6.4 of the design), used with Angular `HttpClient`. A DTO change in Go must show up as a compile error in the Angular build.
- **No secrets in the frontend.** The panel never holds the Icecast source password, Liquidsoap credentials, or database settings. The secrets endpoint returns only whether a secret is set (§6.3).
- **Times.** The API sends ISO 8601 UTC strings ending with `Z`. The panel converts them for display in the timezone chosen in settings (IANA name, default `Asia/Yerevan`). Times are never displayed in the browser's default zone.
- **Clock and station rules are shown, never recomputed.** The panel does not calculate rotation, fitting, or separation. It sends the template and shows the backend's dry-check result, warnings, and filler choices (§6.0).
- **Forms validate twice.** Reactive forms with validators and HTML5 input types give immediate feedback (§6.2). The backend's per-field errors are then shown next to the same inputs.
- **Help is static content.** Help texts ship with the release as JSON files in the Angular project. They do not come from the backend (§6.1).
- **Nothing blocks the air.** The panel is not in the playout path. A slow or failed panel never affects the stream (design §12).
- **Requests use Angular `HttpClient`.** No separate HTTP client library. The only generated artifact is the set of TypeScript types (see 9.2).
- **Languages.** No user-visible string is hard-coded in a template or in TypeScript. See 1.3.
- **Dependencies.** Prefer the Angular platform and the Angular CDK. Every third-party dependency needs a reason in the PR description.

### 1.1 Angular best practices (rules for the AI)

**Structure and components**

- Standalone components only. No NgModules, except where a third-party library requires one.
- Components use `ChangeDetectionStrategy.OnPush`.
- Features are organized by domain, not by type: `features/library`, `features/playlists`, `features/play-rules`, `features/settings`. No `shared/utils` dumping ground; shared code lives in `core/` (app-wide services) or `shared/` (presentational building blocks only).
- Smart components (routes, data loading) and presentational components (inputs and outputs only, no HTTP) are kept separate.
- Lazy-loaded routes for every feature page. The router preloads all lazy chunks in the background after the first render (`withPreloading(PreloadAllModules)`), so navigation stays fast if the panel is later served from a remote host. Heavy parts inside a page that are not needed for the first view (for example, editors opened on demand) use `@defer`.
- Public API of a feature is its routes file. Other features import from `core` or `shared`, not from each other's internals.

**State and reactivity**

- Use signals for component and service state. Use `computed` for derived values. Use RxJS for streams (WebSocket messages, HTTP calls with cancellation, debounced input).
- No manual `subscribe` without teardown. Use `takeUntilDestroyed()` or the `async` pipe, or `toSignal` for one-shot streams.
- No global mutable state outside the services in `core/`. Services are `providedIn: 'root'` only when they are truly app-wide.
- HTTP calls are cancelled when the user leaves the page (`takeUntilDestroyed`), so late responses cannot overwrite a newer view.

**Forms**

- Reactive forms only. Template-driven forms are not used.
- A form's validators mirror the backend's DTO rules (ranges, required fields, time format). A helper maps backend `errors[].field` paths (for example `elements[2].fixed_minute`) to the matching `FormControl`.
- The Save button is disabled while the form has errors (§6.2).

**Errors shown to the user**

- Every HTTP error is an RFC 9457 problem object. One HTTP interceptor converts it into a typed `ApiProblem` and rethrows it. Components never parse raw HTTP errors.
- Field errors go next to the field. Business refusals (for example, "type is in use") show the list of blocking entities from `used_by`.
- Errors at ERROR level from the backend arrive as `error.alert` WebSocket events and are shown as a popup with the error text (§6, §10.1). Open outages are a persistent banner, not a popup.

**Style, tooling, and quality**

- `strict` TypeScript (`strict`, `noImplicitOverride`, `noPropertyAccessFromIndexSignature`, `noImplicitReturns`). No `any`; `unknown` plus narrowing when the type is truly unknown.
- ESLint with `angular-eslint` and `typescript-eslint`, Prettier for formatting. Both run in CI and fail the build.
- Template type checking in strict mode (`strictTemplates`).
- Accessibility: every control has a label, every icon-only button has `aria-label`, focus is visible, dialogs trap focus. Target WCAG 2.1 AA for contrast and keyboard use.
- File names follow the Angular style guide (kebab-case, `*.component.ts`, `*.service.ts`, `*.routes.ts`).
- Tests: unit tests next to the code, run with the Angular unit test runner (DEFAULT, see 9.1). Tests use the Angular testing utilities and `HttpTestingController`; no real HTTP and no real WebSocket in unit tests.
- Comments explain why, not what.

### 1.2 Node and build conventions

- Node LTS pinned in `.nvmrc` and in `package.json` `engines`. The lockfile (`package-lock.json`) is committed and CI uses `npm ci`.
- Exact versions in `package.json` for direct dependencies (no `^` or `~` for the Angular packages and the type generation tooling), so a build does not change without a commit.
- The Angular major version is the latest stable at project creation, recorded in the first PR description (see 9.1).
- `npm audit` runs in CI. Known high-severity findings block the release.

### 1.3 Languages

- The default language is English (`en`). The UI language can be changed at runtime. Changing or adding a language does not need a code change or a rebuild.
- Every visible string comes from a translation key, for example `clocks.title` or `filler.dialog.shortfall`. Templates use the translate pipe, and TypeScript uses the same translation service. Keys are dotted paths in nested JSON objects.
- Translation files: `src/assets/i18n/<lang>.json`. The list of available languages is `src/assets/i18n/languages.json` (entries `{ "code": "en", "name": "English" }`). The files are loaded over HTTP when the panel starts.
- To add a language: copy `en.json` to `<code>.json`, translate the values, add one entry to `languages.json`, and copy the help files (F4) into `assets/help/<code>/`. Nothing else changes.
- A missing key in the active language falls back to the English value. In development, each missing key is logged once as a warning, so gaps are visible.
- The active language is chosen in the header and remembered in the browser (`localStorage`, wrapped in try/catch; default `en`).
- Dates, times, and numbers are formatted with the active language's locale (`Intl`), and the time zone still comes from settings (F3).
- Backend errors carry a stable `code` in the problem object (see Section 9.6, item 4). The panel translates by `code`. If no translation exists, it shows the backend's `detail` text as returned.

## 2. Repository layout

```
radio-atlantida-frontend/
  .github/workflows/ci.yml          # lint, typecheck, unit tests, build (every PR)
  .github/workflows/release.yml     # builds and pushes the image on v* tags
  api/
    openapi.json                    # snapshot of the backend specification for the current tag (see 9.2)
  docs/                           # context for the AI (copied from the Claude project)
    base.md
    tech-design.md
    frontend-init-plan.md
  docker/
    Dockerfile                      # multi-stage: Node build -> unprivileged nginx
    nginx.conf                      # static files, SPA fallback, /api and WebSocket proxy
  public/
    favicon.ico
  scripts/
    sync-api.mjs                    # copies the backend specification into api/ (see 9.2)
  src/
    app/
      core/
        api/                        # generated types (git-ignored), typed request helper, error interceptor
        realtime/                   # WebSocket service, typed event handlers, reconnect and catch-up
        operations/                 # operation tracking (signals), operation status
        alerts/                     # error popups and the open-outage banner
        settings/                   # settings and station timezone (signals)
        time/                       # timezone-aware date formatting (IANA name from settings)
        player/                     # single shared track preview player (§6.6)
        help/                       # help content loader (per language, fallback to en) and typed page IDs (§6.1)
        i18n/                       # runtime translation service, language list, language switch (1.3)
        shell/                      # app layout: navigation, header with help button
      shared/
        ui/                         # presentational components: dialogs, field hint, help panel, empty state
        forms/                      # validator helpers, server-error mapping, duration and time inputs
        pickers/                    # track picker, playlist picker, play-rule picker (with play buttons)
      features/
        library/                    # tracks list, track form, preview buttons
        artists/
        playlists/                  # playlists and their tracks
        playlist-types/
        play-rules/                 # play rules and their targets
        separation-rules/
        settings/                   # station, stream output, Liquidsoap, rotation, filler, outages, retention
      app.routes.ts                 # lazy routes, only for implemented pages
      app.config.ts                 # providers: router, HTTP client with interceptors, error handler
    assets/
      help/                         # help JSON files: help/en/, help/<lang>/, one per page ID (see F4)
      i18n/                         # en.json (default), <lang>.json files, languages.json (see 1.3)
    styles.scss                     # global tokens, theme, density
  .editorconfig                     # LF line endings, 2 spaces
  .gitattributes                    # * text=auto eol=lf
  .gitignore
  .nvmrc
  angular.json
  eslint.config.mjs
  package.json
  package-lock.json
  proxy.conf.json                   # dev server proxy to the backend on 127.0.0.1:8090
  tsconfig.json
  README.md
```

`features/` folders are created only when their phase starts. Empty folders are not committed.

## 3. Phase F1 — Skeleton

**Goal:** an Angular application that builds, lints, tests, starts in development against the backend, and runs as a container.

Tasks:

1. Create the Angular project in the existing repository (the repo currently contains only `.gitignore` and `README.md`). Standalone components, routing, SCSS, strict TypeScript, no SSR (the panel is a local admin tool, DEFAULT).
2. `.editorconfig`, `.gitattributes` (`* text=auto eol=lf`), `.nvmrc`, `engines` in `package.json`. Development is on macOS and runtime is on Windows (design §9.1), so line endings are checked in CI.
3. ESLint (`angular-eslint`, `typescript-eslint`) and Prettier. `npm run lint` and `npm run format:check` pass.
4. Unit test runner set up with one passing smoke test.
5. `app.config.ts`: router, `HttpClient` with interceptors, global error handler, translation loader (1.3). No feature routes yet. The language switch is added to the header with the shell.
6. Application shell (`core/shell`): a header with the station name placeholder, a side navigation listing only the pages whose phase is done, and a content area. The layout works at desktop widths; narrow widths are supported but not optimized.
7. Dev proxy: `proxy.conf.json` forwards `/api` (including the WebSocket path `/api/ws`) to `http://127.0.0.1:8090`. The app uses relative URLs (`/api/...`), so the same code works in development, in the Docker stack, and in production.
8. `docker/Dockerfile`: multi-stage. Build stage on the pinned Node LTS image (`npm ci`, build). Runtime stage on an unprivileged nginx image, serving the static build on port 8080 with SPA fallback to `index.html`. `HEALTHCHECK` on `/`.
9. `docker/nginx.conf`: serves static files, proxies `/api/` to `http://backend:8090` (the Compose service name), including the WebSocket upgrade headers for `/api/ws`. Security headers: `X-Content-Type-Options`, `Referrer-Policy`, and a `Content-Security-Policy` that allows self-hosted assets and `connect-src 'self'`.
10. npm scripts as the entry point: `dev`, `lint`, `format:check`, `test`, `build`, `api:sync`, `api:generate` (see 9.5).
11. `.github/workflows/ci.yml`: on every PR, `npm ci`, lint, format check, typecheck, unit tests, production build, `npm audit --audit-level=high`.
12. `CLAUDE.md` in the repository root, so every later session works with the same context and conventions:
    - **Project context**: a short summary (10 to 15 lines) of `docs/base.md`: a radio automation panel (library, playlists, 60-minute clocks, grid, rotation, filler, play rules, live voice, outages and missed items), one operator, no authentication, Docker on Windows, development on macOS.
    - **Required reading** at the start of every session: `docs/base.md` (goal), `docs/tech-design.md` (authority), the current phase of this plan.
    - The ground rules of Section 1, including 1.1 (Angular) and 1.2 (Node and build).
    - The layout of Section 2 and the npm scripts.
    - "If the code, the design, and the requirements disagree, stop and ask."

**Done when:** `npm run dev` serves the shell; `npm run lint`, `npm run test`, and `npm run build` pass; `docker build` produces a container that serves the shell on port 8080 and returns 200 on `/`; CI is green on a PR.

## 4. Phase F2 — API client and contract pipeline

**Goal:** typed requests built on Angular `HttpClient`, with types generated from the backend's OpenAPI specification (design §6.4), and a single place where HTTP errors become typed problems.

Tasks:

1. `scripts/sync-api.mjs` and `npm run api:sync`: copies the backend specification into `api/openapi.json` for the chosen release tag. The source is the backend release artifact, or a local backend checkout during development: by default `../radio-atlantida-backend/api/openapi.json` (see 9.2). The file is committed, so the frontend build is reproducible without network access to the backend.
2. `npm run api:generate`: generates TypeScript types from `api/openapi.json` into `src/app/core/api/generated/` with `openapi-typescript`. The generated folder is git-ignored and is produced by `prebuild` and `pretest` hooks, so `npm run build` and `npm run test` always start from fresh types. No runtime client is generated (see 9.2).
3. A typed request helper in `core/api`, built on `HttpClient` (no `openapi-fetch`, see 9.2):
   - a base URL of `/api` (relative);
   - generic method signatures keyed by the generated `paths` type, so a wrong path, method, parameter, or body is a compile error, and the response type comes from the same definition;
   - one HTTP interceptor that converts RFC 9457 problem responses into `ApiProblem` (`type`, `title`, `status`, `detail`, `errors[]`, `used_by[]`, `request_id`);
   - a helper that maps `errors[].field` to a `FormGroup` path, so validation errors land on the right input.
4. Request cancellation and timeouts: requests are cancelled by unsubscribing (`takeUntilDestroyed`, `switchMap`), so a late response never overwrites a newer view. Default timeout 15 seconds with the RxJS `timeout` operator. The track audio endpoint is excluded from the timeout (§6.6).
5. Date handling: one function converts API timestamps to `Date` objects from UTC strings, and one pipe formats them for display in the timezone from settings (see F3).
6. Unit tests with `HttpTestingController`: a 422 with field errors, a business refusal with `used_by`, a 500 with a request ID, a network failure.

**Done when:** the generated types compile against the backend's `api/openapi.json` at the current tag; a request to a path or with a body that does not match the snapshot is a compile error; a DTO change in the snapshot produces a compile error in a feature that uses it; the error mapping tests pass.

## 5. Phase F3 — Realtime, operations, alerts, settings core

**Goal:** the plumbing every page uses: live events, asynchronous operations, error popups, the open-outage banner, and the station settings.

Tasks:

1. `core/realtime`: a WebSocket service on `/api/ws`:
   - parses the envelope `{ type, time, operation_id, data }` (design §6.5);
   - dispatches each event type to a typed handler; the event types and payloads come from the generated types;
   - reconnects with exponential backoff (1 s up to 30 s) and shows the connection state in the header;
   - on reconnect, calls `GET /api/operations?since=` to catch up on operations that finished while the socket was down (§6.5, "Operation tracking").
   - The panel never polls for live state (§6). The catch-up call above is the only exception.
2. `core/operations`: a signal-based store of operations by ID (`accepted`, `running`, `completed`, `failed`). Helper: `runOperation(startRequest)` returns an observable of the operation's terminal event, with a timeout fallback that reads `GET /api/operations/{id}`.
3. `core/alerts`:
   - `error.alert` events open a popup dialog with the error text and the UTC time converted to the panel timezone (§10.1);
   - `broadcast_outage.started` opens a persistent banner that stays until `broadcast_outage.ended` (§10.1). The banner is not a popup and cannot be dismissed while the outage is open.
4. `core/settings`: loads `GET /api/settings` once and exposes typed signals for the values the panel needs, starting with the station timezone (default `Asia/Yerevan`). Settings update through `PUT /api/settings/{key}`; the response shows the apply mode (`immediate` or `reconnect`), and the panel shows a notice when a change needs a reconnect.
5. `core/time`: timezone-aware display pipe and a timezone select populated from the IANA list (never typed, §6.2).
6. Unit tests: event dispatch by type, reconnect with backoff (fake timers), catch-up call after reconnect, operation terminal event handling, banner open and close.

**Done when:** a test operation started by the backend shows its terminal event in the UI and is readable after a forced socket reconnect; an `error.alert` shows a popup; an outage event shows and clears the banner.

## 6. Phase F4 — Shared UI: help, validation, pickers, player

**Goal:** the building blocks the pages share, so every page behaves the same.

Tasks:

1. **Help (§6.1).**
   - `core/help`: a typed list of page IDs (`help.library`, `help.playlists`, `help.playlist-types`, `help.clocks`, `help.grid`, `help.play-rules`, `help.separation-rules`, `help.played-tracks`, `help.track-plan`, `help.filler-reminders`, `help.missed-items`, `help.logs`, `help.settings`). A type error if a page uses an ID without a help file.
   - `assets/help/en/<page-id>.json` (and one folder per further language, 1.3) with the sections defined in §6.1: what the page is, what its entities mean, how to use them, typical steps, common mistakes, one worked example. Per-operation notes (create, edit, delete) and field hints are keyed inside the same file.
   - A help button in every page header opens the help side panel (`shared/ui`), which can be closed with Escape.
   - Field hints (`shared/ui`) show a short tooltip and link to the page help.
   - Help follows the active UI language: `assets/help/<lang>/`, falling back to `en` for a missing file (1.3).
   - Writing style: plain language, one short worked example per page.
   - A unit test checks that every help file has the required sections and that every page ID in the type has a file.
2. **Validation (§6.2).**
   - Shared validators: range with `min`/`max`/`step`, time format `HH:MM`, weekday set (1..7), window both-or-none, "at least one constraint" for play rules.
   - Shared input components with HTML5 types: number inputs with `min`, `max`, `step`; time inputs; date inputs; checkboxes or multi-select for weekdays; a select for filler mode, the playlist type (from `GET /api/playlist-types`), and the timezone.
   - Error messages are plain language next to the field (for example, "Enter a number between 1 and 3600").
   - Server errors from F2 are mapped to the same controls.
3. **Pickers.**
   - Track picker: searchable, shows title, artist, and duration, with a play button on each row (§6.6).
   - Playlist picker: multi-select of playlists of all types (a clock element may combine types, §4).
   - Play rule picker: multi-select with the number of uses.
   - A missed-item target picker is built in the clock phase, not here.
4. **Track preview player (§6.6).**
   - `core/player`: one shared `HTMLAudioElement` wrapper. Starting a track stops the previous one. Shows title, artist, a progress bar with seek, and volume.
   - Source: `GET /api/tracks/{id}/audio` (relative URL). The client never sends a file path.
   - Error states: a browser that cannot play the format shows a short message; a 404 shows an error popup (§6, §10.1).
   - The player is mounted once in the shell, so it survives navigation.
   - No preview state is sent to the backend; playback is browser-only.
5. **Dialogs.**
   - A generic confirm dialog for deletes. Delete refusals from the backend show the `used_by` list.
   - The blocking filler dialog (§6.0, used in the clock phase) is built to the rules of §6.2: it cannot be closed by clicking outside. It is only closed by choosing a mode or by the explicit "save incomplete" action. The component is created in this phase so that the clock phase only wires it.
6. Unit tests for pickers, the player (state transitions with a fake audio element), and dialogs (`disableClose` for the filler dialog).

**Done when:** every page built later can use the help button, the field hints, the pickers, and the player without new code; the help file checks pass.

## 7. Phase F5 — Settings and library pages

**Goal:** the manager can configure the station and build the library in the panel. Endpoints follow design §6.3, §6.4, and §6.6; the backend side is in its Phases 4 and 5.

Tasks:

1. **Settings pages (§6.3).** One page with sections, in this order: Station (timezone, name), Stream output (Icecast host, port, mount, codec, bitrate, sample rate, channels, loudness target, metadata, HLS), Liquidsoap (music gain, fade out 2000 to 3000 ms, harbor port, control host and port), Rotation (horizons, lookahead, tolerance defaults, default filler mode), Filler (reminder deadline, fallback mode), Outage detection (heartbeat, Icecast check interval, failures), Retention (play log days, log days), Emergency playlist.
   - Each field shows its default, whether it is the default (`is_default`), and its apply mode. A change that needs a reconnect shows a notice before saving.
   - Secrets section: shows only `{ name, is_set }` from `GET /api/settings/secrets`. No secret value is ever shown, and no input for secrets exists in the panel (§6.3).
   - Unsaved changes are detected; leaving the page with unsaved changes asks for confirmation.
2. **Playlist types (§4, §6.4).** A list with usage counts, add, rename, and delete for custom types. System types cannot be deleted; a type in use is refused with the list of playlists and tracks from `used_by`. The `code` is shown read-only after creation.
3. **Playlists.** List with type filter (`GET /api/playlists?type_id=`), create, edit (type is required), delete (refused if used by clock elements; the error names the clocks), and the track membership editor (`PUT /api/playlists/{id}/tracks`). The order of tracks is not shown or stored: membership is a set (§4, `base.md` Content Playlists).
4. **Artists.** Basic CRUD. Needed for artist separation.
5. **Library (tracks).** List with search and filters (playlist, type, quality flag). Create and edit the metadata and `file_path` (relative to `MEDIA_ROOT`; the form rejects absolute paths and `..` before sending, and the backend rejects them again). Play button on every row. Playlist membership and play rules on the track form (`PUT /api/tracks/{id}/play-rules`). The quality flag and format are read-only in this phase (analysis is a later phase).
6. **Play rules (§7.3).** List with usage counts. Create and edit: name, time window (both or none, may cross midnight), weekdays, minimum interval in minutes, plays per hour, notes. Validation: at least one constraint. Targets editor: tracks and playlists (`PUT /api/play-rules/{id}/targets`). Delete refused if in use, with the list from `used_by`.
7. **Separation rules.** List and edit `min_interval_hours` and notes. Values come from the table, not from code (§4).
8. **Route registration.** A page's route is registered only in the phase that builds it. The navigation shows only registered pages (task 6 of F1).
9. Tests: form validation for every rule in §6.2, delete refusal rendering, play rule constraint validation, settings save with the reconnect notice, secret rendering (only `is_set`).

**Done when:** the full library flow works in the panel against the backend's Phase 5 (create playlist type, create playlist, add track, set play rule, preview the track, delete refusal shows the blocking entity); the settings save and reload with defaults shown correctly.

## 8. Later phases (outline only, separate plans)

6. Clocks and grid: clock editor with elements (`playlist_ids` multi-select, placement `flow/start/end/fixed`, tolerances), the two-step save with the dry check and the filler dialog (§6.0, §7.2), the 60-minute visual layout with segments, the weekly grid up to 30 days ahead.
7. Rotation views: track plan (rolling 24 to 48 hours), filler requests and reminders, warnings from the engine.
8. Live control: on/off, music gain, live voice from the browser (WebRTC) with microphone capture and level meter.
9. Outages and missed items: played-tracks list with "Not aired" labels, missed-item panel with reschedule (placement and target hour) and dismiss.
10. Import: file upload, analysis results, quality warnings, transcoding.
11. Logs: file list, filters by level and component, timezone conversion (§10.1).
12. CI/CD: `release.yml` builds and pushes `ghcr.io/astronin/radio-atlantida-frontend:<tag>` on `v*` tags, using the same tag as the backend (§9.2).

## 9. Decisions and open points

### 9.1 Angular version, UI kit, and test runner

- **Angular version — DEFAULT.** Latest stable major at project creation, pinned exactly. Recorded in the first PR description.
- **UI kit — DECIDED.** **Angular Material with the Angular CDK** for tables, dialogs, menus, tooltips, and form fields. It is the standard choice for admin panels, supports accessibility out of the box, and matches the Angular version. The alternative (no UI kit) was not chosen.
- **Unit test runner — DEFAULT.** The Angular default runner for the chosen version. End-to-end tests (Playwright) are added in a later phase, not in this plan.
- **Change detection — DEFAULT.** `OnPush` everywhere. Zoneless mode is adopted only if it is stable in the chosen version; otherwise zone-based with `OnPush`.

### 9.2 API client generation and the specification snapshot

- **Generator — DECIDED.** **openapi-typescript** generates the types only. Requests are made with Angular `HttpClient` through the typed helper (F2). **openapi-fetch** is not used for requests. A runtime client library may be added only for a case that `HttpClient` cannot cover, and only after the decision is recorded in this section.
- **Specification source — DEFAULT.** The frontend commits a snapshot `api/openapi.json` for the release tag it targets. `npm run api:sync` copies it from the backend's release artifact or from a local backend checkout. During development the local checkout is the default: `../radio-atlantida-backend/api/openapi.json` (a sibling folder of this repository). Another path can be given as an argument: `npm run api:sync -- <path-to-openapi.json>`. The build then never needs network access to the backend, and the frontend and backend tags always match (design §6.4, §9.2).
- **Backend side — DECIDED.** The backend generates the specification from its code with `make openapi` (the `backend openapi` command). The file is git-ignored in the backend and is never edited by hand. The backend CI job `openapi` validates it with Redocly and uploads it as the artifact `openapi`. Before syncing, run `make openapi` in the backend, or `make openapi-lint` to also validate it. The stable error codes (9.6, item 4) are enum values in the same document.
- **Update workflow — DECIDED.** After a DTO or endpoint change in the backend: run `make openapi` in the backend; in the frontend run `npm run api:sync`, then `npm run api:generate`; commit the changed `api/openapi.json` together with the frontend change that uses it. The Angular build then shows every place that must change.
- **Generated code is not committed.** It is produced from the snapshot before `build` and `test`. Git-ignored under `src/app/core/api/generated/`.

### 9.3 Help content and language

- **Help content — DEFAULT.** Static JSON files under `src/assets/help/<lang>/`, typed page IDs, shipped with the release (§6.1). No help is loaded from the backend or from a CMS.
- **UI language — DECIDED.** English (`en`) is the default. The language is a runtime setting, not a build setting (1.3). Translation files are `src/assets/i18n/<lang>.json`, and the list of languages is `src/assets/i18n/languages.json`. A new language is added by a new JSON file and one entry in the list, without a code change. The runtime translation service is written in-house (`core/i18n`, a few hundred lines with signals); `@angular/localize` is not used, because it compiles translations into the build and would require a rebuild for each language.

### 9.4 Dev stack and proxying

- **Development proxy — DEFAULT.** `proxy.conf.json` forwards `/api` (including `/api/ws`) to `127.0.0.1:8090`, which is where `make run` starts the backend (backend plan, Phase 1, task 9). The developer does not change any URL in code.
- **Production-like run — DEFAULT.** The frontend container's nginx proxies `/api` to the `backend` service on the internal Compose network (Section 3, task 9). The browser only ever talks to one origin, so no CORS configuration is needed.

### 9.5 Tooling entry point — DEFAULT

- npm scripts are the single entry point (`npm run dev|lint|test|build|api:sync|api:generate`). A Makefile is not added unless the team asks for one.

### 9.6 Items to confirm with the backend plan

1. **Docs folder name — DECIDED.** The context files live in `docs/` in both repositories, the same as in the backend plan. The Claude project keeps its copies under `claude/`; that is only the project's naming, not the repository layout.
2. **Event payloads.** The WebSocket event schemas are part of the backend's OpenAPI document (design §6.5). If a schema is missing when Phase F3 starts, stop and ask the backend side. The frontend does not invent payloads.
3. **Filler dialog timing.** The blocking filler dialog is built in Phase F4 and wired in the clock phase. If the clock phase starts before the backend's `save-with-filler` endpoint exists, stop and ask.

4. **Stable error codes — DECIDED.** Problem responses carry a stable `code` (for example `playlist_type_in_use`), in addition to the English `title` and `detail`. The panel uses the code to show the message in the active language (1.3). The backend implements this in `internal/httpapi/errcodes` and publishes the codes as an enum in `api/openapi.json`. Codes are never renamed once released.

## 10. Prompt for the first Claude Code session

Before the session, copy `base.md`, `tech-design.md`, and `frontend-init-plan.md` into `docs/` of the repository.

> You are starting the frontend of a radio automation system.
>
> 1. Read `docs/base.md` first. It describes what the station needs: the overall goal of the product. Keep it in mind for every decision.
> 2. Read `docs/tech-design.md`. It is the authority on how the system is built. Sections 6 (API, settings, help, validation, track preview), 6.4 (client generation), and 10 (time and logging) matter most for the panel.
> 3. Read `docs/frontend-init-plan.md`. It is the task list.
>
> Implement Phase F1 of `docs/frontend-init-plan.md`. Follow Section 1 (ground rules, including 1.1 Angular and 1.2 Node and build) and Section 2 (layout). Write `CLAUDE.md` as described in task 12, including the project context summary of `docs/base.md`.
>
> Apply the DEFAULT items of Section 9. For ASK items, use the proposals unless told otherwise, and list in your final message which ones you applied, the Angular version you pinned, and the Node LTS version. If the requirements, the design, and the plan disagree, stop and ask. Do not start Phase F2. Finish with `npm run lint`, `npm run test`, and `npm run build` passing, and a short summary of what was created.
