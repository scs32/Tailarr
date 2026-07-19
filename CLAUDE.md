# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Tailarr** (fork of LunaSea) is a self-hosted controller for managing media services (Sonarr, Radarr, Lidarr, SABnzbd, NZBGet, Tautulli). This is a monorepo containing:

- **lunasea/** - Main Flutter application (multi-platform: iOS, Android, macOS, Windows, Linux, Web)
- **lunasea-cloud-functions/** - Firebase Cloud Functions (Node.js/TypeScript)
- **lunasea-notification-service/** - Webhook notification service (Express/TypeScript)
- **lunasea-docs/** - User documentation (GitBook)

**GitHub:** https://github.com/scs32/Tailarr (private)

**Note:** Forked from the archived LunaSea project for personal development.

## Backlog

- **Share Module Configuration** (added 2026-07-19): export a module's
  connection details from one phone, send by text, tap-to-import on the
  recipient's Tailarr. Sketch:
  - *Transport/launch*: universal link on tailarr.com
    (`https://tailarr.com/import#<base64url-json-payload>`) — opens the app
    directly on devices with Tailarr (needs Associated Domains entitlement,
    fine on the paid team, + an `apple-app-site-association` file served
    from the tailarr-site Cloudflare Pages repo), and falls back to a
    friendly "get Tailarr" web page for everyone else. Payload in the URL
    *fragment* so the secret never reaches the server logs. A custom
    `tailarr://` scheme is the simpler fallback if AASA is a hassle.
  - *Format*: versioned JSON `{v, modules: {sonarr: {host, key, headers}}}`
    base64url-encoded. Carrying API keys in a text is inherently
    sender's-choice; nothing Apple-special is required. Optional hardening
    later: passphrase-encrypt the payload and share the passphrase out of
    band.
  - *Overwrite safeguard*: import screen previews exactly what's inside
    (module, host, key obfuscated) and flags per-module conflicts —
    "Sonarr is already configured on profile 'default': Overwrite /
    Import into new profile / Skip". Never silently replaces.
  - Suite tie-in: the Tailarr Server module's Users flow already shares an
    enrollment key; a combined "invite" (tailnet key + module config in one
    link) is the dream version.

- **Tailarr Server module v2 remainder**: controller self-upgrade screen,
  catalog/install wizard, pod busy auto-refresh, diagnose viewer, Kuma
  monitoring, shares management.

- **tailscale_embed upgrade** (planned 2026-07-19; plugin main is at
  e0d598e, Tailarr pins f11d76e — the initial extraction): nothing breaks
  (the `TailscaleBackend.start(TailscaleConfig)` breaking change only hits
  custom backends; new config fields optional; findProxy still
  tailnet-selective). Plan:
  1. `flutter pub upgrade tailscale_embed` — free wins: rollback start
     (bad key no longer kills the working tunnel), redirect relaying,
     direct dial for non-tailnet destinations.
  2. Adopt `onKeyConsumed` in `network_io.dart` → delete
     `TAILSCALE_AUTH_KEY` from Hive once the identity persists (spent
     plaintext key currently sits in storage forever); Settings key field
     should read "consumed — identity saved".
  3. `acceptRoutes` now defaults true: LAN IPs behind peer-advertised
     subnet routes dial through the tailnet (correct remotely, hairpins
     at home). Take the default; toggle only if hairpin complaints.
  4. Optional: surface plugin `status()` (hostname/IPs/peers/state) in
     Settings > Network — answers "am I connected?".
  5. Verify: analyzer → live E2E vs test server → in-place phone install.
  Coordination flag → SEQUENCE DECIDED (2026-07-19): the plugin should
  land its framework-distribution change (xcframework → GitHub Releases +
  CocoaPods script_phase download, checksum-pinned) BEFORE Tailarr bumps —
  each bump otherwise bakes another ~180MB of binaries into git history
  (GitHub already warning on push; 100MB hard limit is close). Order:
  1) plugin ships Releases-based distribution, 2) plugin live-verifies
  multi-identity with the reusable tailde95ff key, 3) single Tailarr bump
  adopts everything (identities, onKeyConsumed(identity), status UI).
  Verify Tailarr CI's pod install fetches the framework fine (needs
  network at pod-install time — it has it).

- **Share-config flow polish**: Stephen found the import flow "a bit
  wonky" on device (2026-07-19) — revisit UX after TestFlight feedback.

- **Per-profile Tailscale** (decided direction 2026-07-19): today
  TAILSCALE_ENABLED/AUTH_KEY are global (LunaSeaDatabase) and the embedded
  node has ONE identity. Move to per-profile in two stages:
  1. App-only: enabled + auth key become LunaProfile HiveFields (migrate
     existing global values into the current profile).
  2. Per-profile node identity/tailnet: plugin support SHIPPED
     (tailscale_embed efc0e02, 2026-07-19): `identity` on TailscaleConfig,
     legacy state auto-migrates to identities/default (no re-enroll),
     ensure() restarts on identity change (serialized; guard covers gap),
     rollback restores the PREVIOUS identity (error carries
     activeIdentity), status().identity, listIdentities()/deleteIdentity()
     (IDENTITY_ACTIVE guards the running one). BREAKING in same rev:
     onKeyConsumed is now `void Function(String identity)`.
     Tailarr adoption notes:
     - Identity names must match [A-Za-z0-9][A-Za-z0-9._-]{0,63} and
       profile names are free-form: do NOT derive by slugification
       (collisions). Generate once when a profile first enables Tailscale
       (slug + short random suffix) and STORE on the profile as a new
       HiveField; profile rename then can't orphan/collide node state.
     - Profile delete should offer deleteIdentity() cleanup.
     - Adopt onKeyConsumed(identity) → clear that profile's auth key.
     - Kills the juggle-two-installs problem: profile "test" on tailde95ff
       vs profile "home" on the real tailnet.
     Plugin's live E2E (two identities, switch, rollback, onKeyConsumed)
     is pending a real auth key — the reusable tailde95ff key works; run
     it before or with the Tailarr bump.

## Build Commands

### Flutter App (from `lunasea/` directory)

```bash
# Install dependencies
flutter pub get

# Run code generation (REQUIRED before building)
npm run generate

# Individual generators
npm run generate:environment    # Environment config
npm run generate:assets         # Spider asset generation
npm run generate:build_runner   # Hive, Retrofit, JSON serializable
npm run generate:localization   # i18n strings

# Build for specific platform
npm run build:android
npm run build:ios
npm run build:macos
npm run build:windows
npm run build:linux
npm run build:web

# Run in profile mode
npm run profile

# Fix CocoaPods issues (iOS/macOS)
npm run cocoapods:nuke
```

### Cloud Functions (from `lunasea-cloud-functions/functions/`)

```bash
npm install
npm run build      # Compile TypeScript
npm run serve      # Local Firebase emulator
npm run deploy     # Deploy to Firebase
npm run lint
```

### Notification Service (from `lunasea-notification-service/`)

```bash
npm install
npm run build      # Compile TypeScript
npm start          # Dev with nodemon
npm run serve      # Production
```

## Architecture

### State Management
- **Provider** with ChangeNotifier pattern
- Module-based state classes extending `LunaModuleState`
- Each feature module has its own state class (e.g., `RadarrState`, `SonarrState`)

### Networking
- **Dio** HTTP client with **Retrofit** for API generation
- Platform-specific implementations via conditional imports (`network_io.dart`, `network_html.dart`)
- Custom `HttpOverrides` for TLS validation and Tailscale integration
- Go-based Tailscale integration (`lunasea/Go/`) compiled to xcframework for iOS

### Local Storage
- **Hive** encrypted NoSQL database
- Code-generated models with `@HiveType`/`@HiveField` annotations
- Boxes: profiles, indexers, logs, alerts, externalModules, lunasea

### Routing
- **Go Router** for declarative navigation with deep linking support

### Code Generation
All generated files use `.g.dart` suffix. Run `npm run generate` after modifying:
- Hive models (`@HiveType`)
- API clients (`@RestApi`)
- JSON models (`@JsonSerializable`)

### Module Structure
Each service integration follows this pattern:
```
lib/modules/{service}/
├── api/           # Retrofit API client
├── core/          # State, types, constants
├── routes/        # Screen widgets
└── widgets/       # UI components
```

## Linting

- Dart: `flutter_lints` with custom rules in `analysis_options.yaml`
- **Required:** `always_use_package_imports: true` - use `package:lunasea/...` imports
- Generated files (`*.g.dart`) and tests are excluded from analysis

## Git Conventions

- Conventional commits enforced via Commitlint
- Use `npm run commit` for interactive commit (Commitizen)
- Commit types: chore, docs, feat, fix, refactor, release

## Platform-Specific Code

Platform-specific implementations use stub pattern:
```
lib/system/{feature}/platform/
├── {feature}_stub.dart   # Default stub
├── {feature}_io.dart     # Mobile/Desktop (dart:io)
└── {feature}_html.dart   # Web (dart:html)
```

Conditional imports in main file select appropriate implementation.

## Tailscale Integration (WORKING on iOS — now via the `tailscale_embed` plugin)

### Current State
**Working end-to-end since 2026-07-04; extracted into a reusable Flutter plugin on 2026-07-18.** The app embeds a Tailscale node via tsnet and routes tailnet traffic (`*.ts.net`, `100.64.0.0/10`, `fd7a:115c:a1e0::/48`) through it — no system-wide VPN needed on the phone.

The whole stack (Go tsnet proxy, Swift MethodChannel bridge, findProxy/HttpOverrides routing, TailscaleGuard lifecycle widget, auth-key validation/friendly errors) now lives in **github.com/scs32/tailscale_embed** (public, GPL-3.0), consumed as a git dependency in `lunasea/pubspec.yaml`. The prebuilt `TailscaleEmbed.xcframework` is checked into that repo, so neither local builds nor CI need a Go toolchain anymore.

### What remains in this repo
- `lib/system/network/platform/network_io.dart` — thin `IO` facade over `TailscaleEmbed.instance`; configures the plugin with a `TailscaleConfig` provider reading Hive (`TAILSCALE_ENABLED`/`TAILSCALE_AUTH_KEY`, hostname `tailarr`) and adds Tailarr-specific client config (TLS validation toggle, user agent) via `TailscaleHttpOverrides.install(configureClient: …)`.
- `lib/main.dart` — mounts the plugin's `TailscaleGuard` in the MaterialApp builder.
- Settings toggle in Settings > General > Network (uses `TailscaleAuthKeys.typeError`/`friendlyError` from the plugin). Auth key needed exactly once (node identity persists in Application Support/tailscale); single-use keys are fine.

### Gotchas (now documented in the plugin repo too)
- **gvisor must match tailscale's own go.mod pin** — a newer gvisor breaks `gomobile bind`. Rebuild recipe: `go/build.sh` in the plugin repo.
- To bump tailscale: update the plugin repo's `go/go.mod`, run `go/build.sh`, commit the new xcframework there, then `flutter pub upgrade tailscale_embed` here.

## iOS Development Notes

### Code Signing for Personal Team
- Personal (free) Apple accounts can't use "Access Wi-Fi Information" or "Associated Domains" capabilities
- Remove these from `Runner/Runner.entitlements` for local testing
- Change bundle ID to something unique (e.g., `com.yourname.lunasea.dev`)
- Settings are in `Runner.xcodeproj/project.pbxproj`

### Deployment Target
- Minimum iOS version set to 14.0 in both `Podfile` and project settings
- Update `IPHONEOS_DEPLOYMENT_TARGET` in project.pbxproj if needed

### Common Build Fixes
- Disable user script sandboxing: `ENABLE_USER_SCRIPT_SANDBOXING = NO`
- Clean pods: `rm -rf Pods Podfile.lock && pod install`
- Developer Mode required on device: Settings > Privacy & Security > Developer Mode

## Session Commands

- **"break time"** - Update this CLAUDE.md file with any new context learned during the session, then provide a summary of what was accomplished/discussed.

---

## Session Log — 2026-07-04 (Resurrection + Rebrand + TestFlight)

Went from "shelved / Tailscale fundamentally broken" to shipping. State now:

### Tailscale integration: WORKING on iOS
- Root cause of the old block was fixed upstream (tsnet os.Executable on iOS,
  PR #15379, in v1.92.5 which the repo already pinned). See the "Tailscale
  Integration" section above (rewritten to WORKING).
- Lifecycle: persistent node (`Ephemeral: false`), blocking `server.Up(ctx)`,
  `EnsureProxy()` rebinds the listener iOS reclaims on suspend, `TailscaleGuard`
  widget shows a blocking "Connecting…" overlay on launch/foreground.
- Routing: `findProxy` sends `*.ts.net` + Tailscale IPs (100.64.0.0/10,
  fd7a:115c:a1e0::/48) to the proxy. Go proxy resolves `*.ts.net` FQDNs from the
  peer list (no system MagicDNS on-device). Bare short names NOT supported
  (indistinguishable from LAN hosts). Node registers as hostname `tailarr`.
- Human-readable auth errors; rejects `tskey-api-`/`tskey-client-` keys.

### Rebrand: LunaSea → Tailarr
- Tier 1 strings done (display names, titles, localization, iOS perms, web).
- Full visual identity from the user's Claude Design project (mesh-tail mark,
  Signal Cyan #22D3EE on App Ink #32323E, Space Grotesk). Vector sources in
  `branding/tailarr-src/`, drop-ins in `branding/replacements/`. All platform
  icons/splash/favicons regenerated. Root README is Tailarr-branded.
- Bundle ID changed to `com.stephenspeicher.tailarr` (was `.lunasea.dev`).
  Internal identifiers (package `lunasea`, `Luna*` classes, Hive paths)
  deliberately UNCHANGED — Tier 3, no user benefit, would wipe settings.
- iOS caches launch-screen per bundle ID (survives reboots); new bundle ID or
  app delete is the only reliable way to refresh the splash.

### TestFlight: live pipeline
- `.github/workflows/testflight.yml` — tag `v*` or manual dispatch → builds Go
  xcframework + Flutter, cloud-signs, uploads. Working after fixing: gobind
  install, gitignored codegen (run the 4 dart generate cmds), ASC key needs
  cloud-managed-cert permission, runner needs newest Xcode.
- ASC secrets set (ASC_KEY_ID=C9NUZL9HZF, ASC_ISSUER_ID, ASC_KEY_P8). App record
  "Tailarr" sku=tailarr-001. Public link testflight.apple.com/join/m3eyPfSr,
  button on README. Build 5 submitted, WAITING_FOR_REVIEW (Apple's clock).
- ASC API helper pattern in scratchpad (PyJWT ES256) — see memory.

### Paid Apple account confirmed (team 857ZZSY5ZQ, 1-year profiles).

### Pending / next
- Repo still PRIVATE — user will make public soon after TestFlight goes live
  (GPL distribution obligation; keep source-on-request in mind meanwhile).
- Email LunaSea author (Jagandeep Brar) re: App Store distribution exception.
- Future projects (SEPARATE sessions/repos): Swiftfin + Tailscale, and a
  garage-controller rewrite to Swift + Tailscale — both use **TailscaleKit**
  (native Swift), NOT this gomobile/tsnet approach. Handoff artifacts written:
  `~/projects/tailscale-embedding-playbook.md` (cross-project patterns) and
  `~/projects/swiftfin/KICKOFF.md` (Swiftfin-specific brief + first prompt).
- Jellyfin clean-library batch transcode script (hevc_videotoolbox ~5Mbps).

---

## Session Log — 2026-07-18/19 (Tailarr Server module, tailscale_embed extraction, live E2E)

### Shipped (all pushed to master)
- **Tailarr Server module v1** — first-class module (enum `TAILARR_SERVER`,
  display "Tailarr Server", profile HiveFields 44-46: enabled/host/headers,
  NO api key — server is tailnet-only). Screens: pods list (+fleet
  start/restart bar), pod detail (start/stop/update, tailnet URL, logs,
  backups create/restore/delete), image updates. Hand-built Dio client in
  `lib/api/tailarr_server/` matched to the Flask handlers. Connection page
  warns on non-ts.net hosts and when Tailscale toggle is off; Test
  Connection requires server `api_version >= 1` (added in tailarr-server
  v0.9.8, released + tagged this session).
- **tailscale_embed extraction** — the whole embedded-Tailscale stack now
  lives in github.com/scs32/tailscale_embed (public, GPL-3.0, local
  `~/projects/tailscale_embed`), consumed as a git dep. Prebuilt
  xcframework COMMITTED in that repo → CI needs no Go. Tailarr keeps only a
  thin facade (`lib/system/network/platform/network_io.dart`) + the
  settings toggle. App node hostname renamed `tailarr` → **`tailarr-app`**
  (avoids collision with the server controller node). Kickoff doc for new
  consumer projects: `~/projects/tailscale-embed-kickoff.md`.
- **Live E2E test** (`integration_test/e2e_test.dart`) — enrolls a REAL
  tsnet node on a simulator, hits the live test server through the tunnel,
  walks all module screens. Run:
  `flutter test integration_test/e2e_test.dart -d <sim-udid>
  --dart-define=TS_AUTHKEY=<reusable tskey-auth for tailde95ff>
  --dart-define=SERVER_HOST=https://tailarr-server.tailde95ff.ts.net`
  v1 flow PASSED end-to-end (and caught a real Future-in-setState bug).
- **Module v2 (users + funnel)**: users list (15s poll, gate screen when
  server tsapi unconfigured), Add User (mints single-use 24h key, copy/
  share sheet), Adopt-by-ID, user detail with per-service access switches;
  Public Access (Funnel) toggle on pod detail (confirm-on-enable,
  "funnel refused" surfaces output). Analyzer-clean, committed — but the
  extended E2E run **died of disk-full and is UNVERIFIED**. Rerun the
  command above after freeing space (create sim first:
  `xcrun simctl create e2e-iphone com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-26-5`).

### Test infrastructure (old tailnet tailde95ff = TEST net)
- **Test server**: apple/container Debian guest named `tailarr-server` on
  this Mac → tailarr-server v0.9.8 at
  `https://tailarr-server.tailde95ff.ts.net` with one `uptime-kuma` pod.
  **After reboot it does NOT autostart**: `container system start &&
  container start tailarr-server && container exec tailarr-server bash -c
  'cd /root/tailarr && ./bootstrap-tailarr.sh && cd /root/Pods/uptime-kuma && sh run.sh'`
  (bootstrap reuses saved identity; no key needed).
- Stephen has a **reusable tskey-auth for tailde95ff** (in this session's
  chat; ask him — NEVER write it into this public repo). Server tsapi is
  NOT configured → users features show the gate screen; full users E2E
  needs a Tailscale API token saved via the server web UI Settings.
- **Phone**: dev build installed, enrolled on tailde95ff as `tailarr-app`,
  full v1 verified by Stephen by hand. His TestFlight install + live
  services are on a NEWER separate tailnet (untouched). GOTCHA:
  `flutter install` uninstalls first, wiping node identity + settings —
  use `flutter run` / `devicectl device install app` to keep them.

### Pending / next
- Disk: Claude Desktop vm_bundles (7G) deleted + Cowork scheduled tasks
  disabled at session end → 7.4G free. User is rebooting to install the
  staged macOS update and continue cleanup. Remaining known candidates:
  Downloads old tars (~1.8G), Edge (1.5G).
- **Rerun v2 E2E** (users gate + funnel round-trip — command above; create
  a sim device first) → then install the v2 build on the phone
  (in-place, not `flutter install`).
- Full users-flow E2E once tsapi is configured on the test server.
- v2 remainder (user's order): controller upgrade screen, install wizard,
  busy auto-refresh, diagnose, monitoring, shares.
- Backlog: **Share Module Configuration** (see Backlog section above).
- New project consuming tailscale_embed — kickoff prompt ready at
  `~/projects/tailscale-embed-kickoff.md`.

---

## Session Log — 2026-07-13 (Beta approved, repo public, tailarr.com live)

### TestFlight: APPROVED and public
- Build 5 externalBuildState=BETA_APPROVED. Public link works:
  testflight.apple.com/join/m3eyPfSr (verified installed on user's phone).
  Gotcha: the link's "View in TestFlight" button fails on devices without
  TestFlight installed — use the Redeem code `m3eyPfSr` path instead.
- ASC API access from this Mac: key `~/.appstoreconnect/private_keys/AuthKey_C9NUZL9HZF.p8`,
  KEY_ID=C9NUZL9HZF, ISSUER_ID=aec2db68-0505-4886-832b-c6e1dcd4e0e0,
  PyJWT ES256 pattern (scripts were in session scratchpad; trivially rewritable).

### Repo is PUBLIC
- `gh repo edit scs32/Tailarr --visibility public` done (GPL obligation met
  now that binaries ship). Actions secrets unaffected.

### tailarr.com is LIVE (new repo: scs32/tailarr-site, PRIVATE)
- Marketing site for the SUITE — **both** halves: `scs32/tailarr-server`
  (public; ex-"podscale"; Podman pods where every service is its own
  tailnet device w/ MagicDNS+HTTPS+ACL identity) and this iOS app.
  User insists the COMBO is the product — keep site copy suite-first.
- Site: pure static under `public/`, NO build step. Split hero
  (server card ⇄ animated WireGuard mesh ⇄ phone mockup), duo section,
  how-it-works, features, security (nmap art), sharing, FAQ, CTA.
  Local checkout: `~/projects/tailarr-site`.
- Hosting: Cloudflare Pages project `tailarr-site` (account
  7b8f91a9a2659b940db927227c638e6c), custom domains tailarr.com +
  www.tailarr.com active. Deploys are DIRECT UPLOAD from this Mac
  (dashboard Git-connect was never completed):
  `npx wrangler pages deploy public --project-name tailarr-site --branch master`
  (branch≠master ⇒ preview URL, e.g. hero-site.tailarr-site.pages.dev).
- wrangler OAuth is logged in on this Mac (`wrangler login` done); its token
  CANNOT edit DNS (no DNS scope) — user adds DNS records in dashboard.
- Headless-browser gotcha: Chromium/Edge clamps windows to ~500px min width;
  "mobile" screenshots at 390 are silently 492 — don't chase phantom overflow.

### Cloudflare account facts
- Zones: tailarr.com, onegrooveoff.com, montyandstevebuildavan.com (all
  registered AT Cloudflare) + nest.haus (registrar: Squarespace, transfer
  lock on, expires 2027-03-03 — candidate to transfer; verify .haus support).

### Pending / next
- Site revision pass (user: "not perfect, publish anyway"): real app
  screenshots into the phone mockup, copy tuning, proper 1200×630 og-image.
- Repo-public follow-up: email LunaSea author re: App Store exception.
- Remote background agents stalled twice building the site (agent wrote
  great HTML, never finished CSS/JS; finished by hand) — prefer inline
  builds or babysit agents for this kind of work.
