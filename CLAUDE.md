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

- **Share-config flow polish**: Stephen found the import flow "a bit
  wonky" on device (2026-07-19) — revisit UX after TestFlight feedback.
  (Feature itself SHIPPED in build 6 — see 2026-07-19 session log.)

- **Share-config: second share crashed on device (UNRESOLVED,
  2026-07-19)**: Stephen shared Sonarr config to another build-7 user →
  worked. Radarr share, same method, minutes later → "didn't work" AND
  an iOS app crash (whose phone crashed — sender or recipient — is
  UNKNOWN; ask first). Investigated same day: Sonarr/Radarr share +
  import code paths are identical; full double-share (sender) and
  double-import-while-warm (recipient) reproduced CLEAN on simulator
  (debug build, tailarr:/// scheme) — no crash either direction. So it's
  environmental: prime suspects are (a) a release-only native crash, or
  (b) iOS opening the SECOND universal link in Safari instead of the app
  (looks like "didn't work"; recipient may have a remembered
  open-in-Safari preference). NEXT STEP — get the crash log: on the
  phone that crashed, Settings > Privacy & Security > Analytics &
  Improvements > Analytics Data → newest `Tailarr-2026-07-19-*.ips`,
  AirDrop it over; or pull TestFlight crash reports via the ASC API key
  on this Mac (they lag ~a day). Also ask the recipient what the second
  link tap actually did (Safari / nothing / app-then-crash).

- **Tailarr Server module v2 remainder**: controller self-upgrade screen,
  catalog/install wizard, pod busy auto-refresh, diagnose viewer, Kuma
  monitoring, shares management.

- **tailscale_embed remainder** (bumped to 39b8afd 2026-07-20 — short-name
  routing + zone-pinning fixes; identities/onKeyConsumed adopted earlier):
  - ~~Surface plugin `status()` in Settings > Network~~ DONE 2026-07-22
    (e5742d62): Tailscale Status page — connection state, node card,
    health warnings, peers list. FakeTailscaleBackend integration test.
  - **Magicsock suspend/resume bug — carry to embed session** (found
    2026-07-22 via the new status page on Stephen's phone): after iOS
    suspend/resume the node shows health warning "MagicSock function
    ReceiveIPv4 is not running" (tailscale#10976 class); traffic still
    works but silently degrades to DERP; node stop/start clears it.
    Fix belongs in the plugin's resume path: rebind magicsock (the
    official iOS client calls magicsock Rebind() on wake) alongside
    EnsureProxy's proxy-listener rebind, then re-check health.
  - Adopt the new additive plugin API when useful: restart(),
    isEnrolled(identity), TailscaleSettingsPanel/Store,
    FakeTailscaleBackend (deliberately NOT adopted in build 8 to keep
    the bug-fix diff minimal).
  - ~~Framework distribution before next bump~~ DONE 2026-07-20: plugin
    history rewritten (filter-repo, binaries purged — ALL pre-rewrite
    hashes incl. efc0e02 are dead; never pin them). xcframework now
    downloads from the plugin's GitHub Releases (framework-v1.92.5,
    SHA-256-pinned via ios/Framework.lock) at pod-install time —
    transparent to Tailarr; verified locally and in CI (build 8).
  - Plugin's own live E2E (two identities, live switch, rollback, key
    consumption) still pending a real key in the embed session.

- **Live E2E is re-pointed nowhere** (2026-07-19): the test server on this
  Mac was re-bootstrapped (tailarr-server v0.10.1 OAuth-first flow) onto a
  NEW tailnet `taila06ea9` as hostname `tailarr` — the reusable tailde95ff
  key can NO LONGER reach it. To run `integration_test/e2e_test.dart`
  again, get a key for taila06ea9 that can reach the controller (mind the
  ACL fences: a minted tag:tailarr-user key may not see the controller
  API), and update SERVER_HOST to https://tailarr.taila06ea9.ts.net.

- **Notifications via ntfy** (plan agreed 2026-07-22, free path): LunaSea's
  push pipeline is dead (v11 fork stripped Firebase; notify.lunasea.app
  gone — vestiges: lib/system/webhooks.dart + per-module
  LunaWebhooks.handle()). Revive with ntfy (ntfy.sh) instead:
  1. Zero-code first: document native ntfy Connect in Sonarr v4/Radarr/
     Prowlarr (paste topic); Tautulli via its webhook agent.
  2. The differentiator: a Notifications setup screen that mints an
     unguessable ntfy topic and AUTO-PROVISIONS the connection into each
     configured service via the API clients Tailarr already has.
  3. Suite angle: ntfy as a tailarr-server catalog pod — webhooks stay
     on the tailnet; self-hosted ntfy needs `upstream-base-url: ntfy.sh`
     for iOS APNs wake. ntfy click-URL can deep link `tailarr://`.
  - Trade-off accepted: users install the ntfy app; notifications wear
    ntfy's icon. Eventual "branded 1.0" upgrade path: own Firebase +
    revive lunasea-notification-service as a pod ($0 in money, real
    engineering) — topic-provisioning work carries over.
  - Rejected: Gotify (no iOS app), Pushover (paid), Notifiarr (same
    centralized-hosted-service model that died with LunaSea).

- **Suite invite** (dream feature): tailnet enrollment key + module config
  in ONE link. Share-config payload is versioned with room for an
  `enroll: {control_url?, key}` field. Pairs with sovereign mode
  (tailarr-server docs/sovereign-mode-design.md).

- **Sovereign mode** (design only): embedded headscale in tailarr-server —
  full writeup in that repo's docs/sovereign-mode-design.md (2026-07-19).

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

The whole stack (Go tsnet proxy, Swift MethodChannel bridge, findProxy/HttpOverrides routing, TailscaleGuard lifecycle widget, auth-key validation/friendly errors) now lives in **github.com/scs32/tailscale_embed** (public, GPL-3.0), consumed as a git dependency in `lunasea/pubspec.yaml`. The prebuilt `TailscaleEmbed.xcframework` is downloaded from that repo's GitHub Releases during `pod install` (SHA-256-pinned via `ios/Framework.lock`, cached in the pub-cache checkout) — no Go toolchain needed locally or in CI. It is NOT in the plugin's git history anymore (purged 2026-07-20).

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
  (indistinguishable from LAN hosts) — **STALE: fixed in the plugin as of
  2026-07-20 (build 8); dotless hosts now route to the proxy, peer-list
  first with system-DNS fallback**. Node registers as hostname `tailarr`.
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

---

## Session Log — 2026-07-19 (share-config, per-profile Tailscale, TestFlight builds 6+7)

Massive shipping day. Everything below is pushed; **builds 6 and 7 are LIVE
on TestFlight** (same version string 11.0.0 → instant external availability,
no review wait; ASC flow: betaAppReviewSubmissions POST + add build to
Public Beta group 9d6bdfdb-…, both scripted via the ASC API key on this Mac).

### Shipped in the app (scs32/Tailarr master)
- **Add User OAuth gate** (e5a82054): Add User checks `tsapi.mode` from
  /api/info (model now parses `tsapi`); non-oauth → warning dialog
  directing to server Settings. Distinct message for static-token mode.
- **Share Module Configuration** (d2562fd3 + 8b9a8b2e): per-module Share
  button on all 7 connection screens → `https://tailarr.com/import#<b64url>`
  link (payload in FRAGMENT, never hits servers) via share sheet. Deep
  link (universal link via new `applinks:tailarr.com` entitlement +
  `tailarr://` scheme, FlutterDeepLinkingEnabled) lands on a dedicated
  import screen: values shown (key obfuscated), **Test Connection runs
  against the UNSAVED payload only**, Save warns before replacing an
  existing config. Tailscale keys structurally unshareable.
  - Site side (tailarr-site repo): `/.well-known/apple-app-site-association`
    (+ `_headers` for content-type) + branded `/import` fallback page —
    LIVE on tailarr.com. ASSOCIATED_DOMAINS capability enabled on App ID
    PZ6595TXN6 via ASC API.
  - GOTCHAS found: `tailarr://` links are NOT tappable in iMessage (only
    https linkifies) — universal link is mandatory for text-message UX.
    share_plus on current iOS THROWS without `sharePositionOrigin` (was
    iPad-only) and async tap handlers swallow it in release — the fix
    derives the anchor rect from the widget's render box
    (`SharedModuleConfiguration.shareOriginOf`). Same latent bug fixed in
    the users-route key share. Also fixed: LidarrAPI.from() read
    LunaProfile.current headers instead of the passed profile's.
- **Per-profile Tailscale + auth key management** (e7713f8b, build 7):
  - LunaProfile HiveFields 47/48/49: tailscaleEnabled/AuthKey/Identity.
    Migration in LunaDatabase.open() moves the old GLOBAL table values
    onto the enabled profile with identity 'default' (where the plugin
    migrates legacy node state) then clears globals — verified by
    integration_test/tailscale_profile_test.dart (passing on sim) AND by
    Stephen's phone surviving the build-7 update with its node intact.
  - Identity names generated ONCE (slug + 6-char random suffix,
    LunaProfileTools.generateTailscaleIdentity) and STORED — never derived
    from renamable profile names. Non-default identities get hostname
    `tailarr-app-<identity>` (default keeps `tailarr-app`).
  - Profile switch → IO.syncTailscaleToProfile() (ensure/stop); profile
    delete → forgetTailscaleNode(identity) cleanup.
  - Settings > General: Auth Key tile (replace/remove anytime; shows
    "Consumed — node identity saved" via onKeyConsumed(identity), which
    deletes the spent plaintext key from the owning profile) + Forget
    Tailscale Node action (stop + deleteIdentity + clear key → fresh
    re-enroll). Enable toggle now starts from existing state and only
    prompts for a key when a start FAILS.
  - tailscale_embed bumped f11d76e → efc0e02 (multi-identity rev).

### tailarr-server repo (as `~/projects/podscale`)
- **Two reboot bugs fixed upstream** (d79e27b): stale podman.sock FILE
  survives reboot (non-tmpfs /run) and the `-S` check skipped starting the
  API service → probe the API instead; sidecars now set TS_AUTH_ONCE=true
  (without it containerboot re-auths each restart and MINTS A NEW NODE —
  that's how tailarr→tailarr-1 / uptime-kuma-1 drift happened).
- **Sovereign mode design doc** committed (0b091cc,
  docs/sovereign-mode-design.md): optional hidden embedded headscale
  behind a control-plane driver interface; entry fee = domain + 443 +
  HTTP-01; loses Funnel/ts.net-certs/hosted DERP; kills the tsapi wizard.
- Stephen independently shipped **v0.10.1** (OAuth-first bootstrap that
  seeds .tsapi.json, inits policy fences, mints the controller's own
  tagged key — no Settings wizard needed).

### tailscale_embed (separate session, coordinated from here)
- Multi-identity SHIPPED (efc0e02) from a prompt authored here: identity
  on TailscaleConfig, in-place legacy migration, serialized switching,
  rollback-to-previous-identity, onKeyConsumed(String identity) BREAKING,
  listIdentities/deleteIdentity, IDENTITY_ACTIVE error code.

### Environment / infra state (IMPORTANT for next session)
- **Test server moved tailnets**: re-bootstrapped on `taila06ea9` as
  `tailarr.taila06ea9.ts.net` (v0.10.1 flow, tsapi CONFIGURED, fixtures
  fake-user + tailscale-nginx — likely the embed session's). The reusable
  tailde95ff key CANNOT reach it; live E2E blocked until a taila06ea9 key
  exists (see backlog). tailde95ff is effectively retired.
- Reboot-recovery for podman-in-guest + wedged-CoreSimulator fixes are in
  auto-memory (tailarr-test-server-reboot-recovery.md).
- Sim automation notes: AppleScript `click at` is flaky near the top of
  the Simulator window; deep links (`tailarr:///settings/configuration/general`)
  are a more reliable way to navigate. `flutter test` output MUST go
  through `tee` (plain `| tail` buffers everything invisibly), and the
  runner gives builds a hard 12-min window — prebuild
  (`flutter build ios --simulator --debug` with the same dart-defines) first.
- Phone installs: release build + `xcrun devicectl device install app`
  (in-place). When entitlements change, plain `flutter build ios --release`
  fails ("No Accounts") — build once via `xcodebuild -allowProvisioningUpdates
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_C9NUZL9HZF.p8
  -authenticationKeyID C9NUZL9HZF -authenticationKeyIssuerID aec2db68-…` to
  mint the new profile; flutter builds reuse it afterwards.

---

## Session Log — 2026-07-19 (evening: second-share crash investigation)

Investigated the "first share works, second share crashes" report (see
backlog item above for full detail + next steps). Findings:
- Sonarr vs Radarr share/import code is symmetric — no module-specific bug.
- Simulator repro of BOTH flows passed clean: import Sonarr → save →
  import Radarr while warm → save (recipient side), and share Sonarr →
  share Radarr in one session (sender side). Blocked on the device crash
  log + knowing which phone crashed.
- Sim technique notes: `build/ios/iphonesimulator/Runner.app` left by a
  `flutter test integration_test` run is the TEST HARNESS — launched
  standalone it hangs on splash forever ("Timeout waiting for first frame
  when launching a URL"); rebuild with `flutter build ios --simulator
  --debug` before manual sim testing (that plain build is what's there
  now). AppleScript `click at` works reliably on the bottom action bar;
  taps INSIDE a presented share sheet (Copy icon) do NOT register —
  dismiss by tapping outside instead. simctl has no tap; deep links +
  bottom-bar clicks cover most driving.

### Pending / next (user-gated)
- **Second-share crash**: get crash log + which phone (backlog item above).
- Share-config flow polish (Stephen: "a bit wonky").
- Universal-link tap-from-Messages test between two phones (build 6+ has
  the entitlement; AASA live since ~noon 2026-07-19).
- Live E2E on the new tailnet; plugin live E2E in the embed session.
- status() UI, v2 remainder, suite invite, sovereign mode (backlog).

---

## Session Log — 2026-07-20 (build 8: tailscale_embed bug-fix bump)

### Shipped
- **tailscale_embed bumped efc0e02 → 39b8afd** (`flutter pub upgrade
  tailscale_embed`; additive, zero Dart changes). Picks up two fixes:
  1. **Bare MagicDNS short names now work** — dotless non-IP hosts (e.g.
     `truenas-ts`) route to the embedded proxy (peer-list resolution
     first, system-DNS fallback), so LAN hostnames still work. The old
     "must type the full name.tailXXXX.ts.net" caveat is DEAD — README
     addressing table updated accordingly.
  2. Zone-pinning fix in the plugin's serialized-ops chain.
  Deliberately did NOT adopt the new additive API (restart(),
  isEnrolled(), TailscaleSettingsPanel/Store, FakeTailscaleBackend) —
  separate backlog item, kept this diff bug-fix-only.
- **First build through the new framework-download path**: the plugin
  repo's history was rewritten 2026-07-20 (binaries purged; all old
  hashes dead — NEVER pin pre-rewrite refs like efc0e02). `pod install`
  now downloads TailscaleEmbed.xcframework from the plugin's GitHub
  Releases (framework-v1.92.5, SHA-256-pinned via ios/Framework.lock,
  cached in the pub-cache checkout). Verified locally (139M framework,
  tag matches lock) and sim-verified: app boots, Settings > General
  Network section (Use Tailscale toggle + Auth Key tile) renders fine.
- Docs: README addressing table gains a bare-short-name row; stale
  "checked-in xcframework" and backlog framework-distribution items
  corrected; 2026-07-04 log annotated.

### Release (build 8 is LIVE on TestFlight)
- CI run 29762623188 (workflow_dispatch on master, commit 7bbb542e) →
  upload succeeded; pod-install log confirmed the framework download.
- ASC steps scripted from this Mac (same builds-6/7 pattern): waited for
  processingState=VALID, betaAppReviewSubmission 201 (WAITING_FOR_REVIEW;
  same version 11.0.0 → instant external availability), added to Public
  Beta group 9d6bdfdb-3c09-48d5-a580-5d7115ed1b21 (204), and set the
  What to Test notes via betaBuildLocalizations (build id
  f1015a71-9a01-456f-9ae5-10c6fc74b7f6).

### Verify on device (build 8)
- **Headline smoke test**: enter a bare short name as a module host
  (e.g. `http://truenas-ts/`) and confirm it resolves over the tailnet.
  This is the FIRST real-device exercise of the short-name fix
  (plugin-side it was only sim-verified) — flagged in the build notes.
  Report the result (pass OR fail) back to the embed session — the
  system-DNS fallback half is the untested part on real hardware.
- Everything else should behave identically to build 7.

### Notes / small findings
- COSMETIC: Tailarr Server connection screen's `_isTailnetHost` only
  recognizes `.ts.net` + 100.x IPs, so a bare short name there shows the
  red "Not a Tailnet Address" warning even though it routes fine now.
  Fold into the status()/settings UI pass if desired.
- Feedback list for the tailscale_embed maintainer was drafted this
  session (version tags instead of raw-hash pins; log cache-hit case in
  pod install; scheduled CI check that release assets still download +
  match Framework.lock; README note that pub-cache repair drops the
  cached framework; relay the device short-name result). Stephen is
  carrying it to the embed session HIMSELF — not filed as an issue.
- **Plezy** (edde746/plezy, Flutter Plex+Jellyfin client) is GPL-3.0 —
  license-identical to Tailarr and tailscale_embed, so borrowing its
  code for a Plex module or forking it as an embed consumer is clean
  (keep notices, publish source; same App Store murkiness as Tailarr).
