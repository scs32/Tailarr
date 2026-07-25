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

Bugs, features, and cleanups. Monetization/tier work lives in **Pro Backlog**
below. (Pruned 2026-07-25 — removed items now shipped or superseded:
per-profile notification isolation, legacy server-profile migration detection,
the Users PEOPLE model, ntfy notifications stage 1, the second-share crash
[sharing was replaced by gateway auto-config], share-config UX polish, and
stale live-E2E test-infra notes. Session logs retain the detail.)

- **Request-Access connection UX — DONE 2026-07-25** (TestFlight feedback:
  "gray out connection details when it's request only"): across all 6 native
  module connection screens, the parent route now HIDES the "Connection
  Details" row when `shouldRequestAccess(type)` (only the Request Access card
  shows), and the connection-details page drops Test Connection on
  `isManaged` (re-sync is the job) and the whole bottom bar on request-access
  (no host to test/share). Also: the Tailscale Status page now shows a
  transient "isn't responding — reconnecting, refreshes automatically" message
  instead of a hard "An Error Has Occurred" when `status()` throws (embedded
  node briefly down).

- **Build-18 profile-delete lockup (UNRESOLVED, 2026-07-24)**: app locked up
  with a Delete Profile dialog open on server-owned profiles (screenshot
  `~/projects/build18-lockup-profiles-delete.jpg`). Not root-caused; suspects:
  (a) profile-switch churn restarting the embedded node per profile across
  tailnets (TailscaleGuard overlay blocks input); (b) the per-profile
  `onConfigChanged()` in `_changeTo` under multi-profile load. NEXT: a repro
  (which action locked it) or an `.ips` hang log; consider debouncing node
  restarts across rapid profile switches.

- **No in-app way to revoke a device for a user (2026-07-24)**: the
  person-detail Devices list is READ-ONLY — an admin can't remove/revoke a
  specific device without the Tailscale admin console. Add a per-device revoke
  action (Users → person → Devices → device → remove) wired to a new
  tailarr-server route that deauthorizes/removes the node + drops its person
  binding.

- **Service-module cold-load retry — DONE for connection + proxy-502 errors
  (build 25/26), watch for gaps**: `attachTailscaleConnectRetry` now retries
  connection-class failures AND the embedded-proxy "Proxy failed to establish
  tunnel (502)" during the connect window. If a NEW cold-load error shape slips
  past `isTailscaleConnectFailure` on device, add its signature there.

- **Tailarr Server module v2 remainder**: controller self-upgrade screen,
  catalog/install wizard, pod busy auto-refresh, diagnose viewer, Kuma
  monitoring, shares management.

- **tailscale_embed remainder** (pinned v0.3.3 / 39b8afd):
  - **Magicsock warning survives refresh — real-device FAILURE confirmed
    (2026-07-24 TestFlight)**: v0.3.3's watchdog restart isn't clearing the
    "MagicSock ReceiveIPv4 is not running" health flag while all peers work.
    Belongs to the embed session (github.com/scs32/tailscale_embed), NOT this
    repo — carry it there. Field screenshots `~/projects/magicsock-*.jpg`.
  - Adopt the additive plugin API when useful: `restart()`,
    `isEnrolled(identity)`, `TailscaleSettingsPanel/Store`,
    `FakeTailscaleBackend`.
  - Plugin's own live E2E (two identities, live switch, rollback, key
    consumption) pending a real key in the embed session.

- **App Store submission** (active): GO decision. **Zagreus** (GPL LunaSea
  fork, live since 2025-09-25 with paid IAP) is the low-risk precedent — copy
  their disclaimer pattern ("remote control app, requires your own server") +
  17+. Exception email sent to Jagandeep Brar (non-blocking goodwill).
  Remaining: listing copy (lead with tailnet-privacy, say "open source",
  tailarr.com support URL), per-device-class screenshots, privacy
  questionnaire ("Data Not Collected"), export compliance (WireGuard/TLS →
  exempt), review notes (demo mode + optional reviewer invite). OPEN: debut as
  "1.0" vs the 11.0.0 lineage string — verify ASC accepts a lower version
  string after 11.0.0 TestFlight builds BEFORE promising it.

- **Security audit — DONE 2026-07-25, full report in
  `docs/security-audit-2026-07-25.md`**. Four-reviewer read-only sweep.
  **Pre-App-Store batch LANDED** (not yet built): H1 invite consent gate,
  H2 error-dialog/clipboard redaction (`LogRedactor.scrub` at the preview
  boundary), M1 `openLink` scheme allowlist, H3 transport floor
  (`NETWORKING_TLS_VALIDATION` now defaults TRUE; iOS ATS
  `NSAllowsArbitraryLoads`→`NSAllowsLocalNetworking`), M6 dropped the iOS
  "Always" location over-ask, M4 Android `allowBackup=false`, corrected the
  false "encrypted Hive" doc claim.
  **Quick-wins batch LANDED 2026-07-25** (not yet built): M3 backup now strips
  `tailscaleAuthKey` from every profile; L3 `LogRedactor` closed (auth-header +
  JSON-value rules + tests); L7 dropped the legacy Android storage perms +
  deduped POST_NOTIFICATIONS.
  **Hardening fast-follow (OPEN)**: M2 encrypt Hive at rest (`HiveAesCipher`
  + secure-storage key; migration — the load-bearing fix; would also let L1's
  ntfy token be Keychain-backed, so L1 rides M2 rather than a native
  exclude-from-backup flag); M3-full (encrypt the whole backup, not just strip
  the key); M5 Test-Connection SSRF guard; L2 secret copies use the
  general/synced pasteboard (no expiry — needs a native `UIPasteboard` channel);
  L5 stale security deps (dio/go_router/share_plus/retrofit/
  flutter_local_notifications; Hive 2.x). Android `usesCleartextTraffic` left ON (LAN-HTTP support) —
  revisit once non-server=Pro makes the free tier tailnet-only. L6 (committed
  `aps-environment=development`) is FINE — the distribution profile overrides
  it to production (push verified live).
  **Server-side audit DONE 2026-07-25 → `docs/security-audit-server-2026-07-25.md`**
  (four reviewers over `~/projects/podscale`). Server is defensively solid (no
  `shell=True`, excellent secret-at-rest, correct whois model). Fixes are a
  SERVER-SESSION job: H1 API bearer OFF by default (unauth `op_exec`/`op_install`
  — only the tailnet ACL gates it); H2 catalog-install name skips `NAME_RE` →
  path traversal + ACL grant injection (`dst:["*"]` escapes the fences); M1 gate
  compromise harvests all users' creds (controller trusts caller-supplied `ip`);
  M2 key reissue doesn't revoke the old key; M3 NFS `host_path` export injection;
  L1-L6 hardening.

- **Suite invite** (dream feature): tailnet enrollment key + module config in
  ONE link. Share-config payload is versioned with room for an
  `enroll: {control_url?, key}` field. Pairs with sovereign mode.

- **Sovereign mode** (design only): embedded headscale in tailarr-server —
  full writeup in that repo's `docs/sovereign-mode-design.md` (2026-07-19).

## Pro Backlog

Monetization / tier work. Product direction (decided 2026-07-24, refined
2026-07-25): **Free = talk to a Tailarr Server** (your own via invite, or the
in-app demo). **Pro = point the app at services yourself, with no server**
(manual host + key entry). Multiple profiles is NOT the axis — server vs.
non-server is. GPL makes the client gate soft; accepted — the goal is
product-focus, not revenue-max (Zagreus ships paid IAP as precedent).

- **Non-server = Pro gate (core mechanic)**: today only Add Profile is gated
  ("Pro Mode Coming Soon" dialog, `profiles/route.dart`); the single default
  profile's MANUAL editors are still OPEN. To make non-server = Pro, gate the
  manual host/credential editors themselves — standalone (not `serverOwned`) +
  not-Pro → a Pro upsell instead of the editors (`ServerDrivenConnection` owns
  the manual-vs-managed decision). Keep a manual path reachable ONLY via demo
  mode / Pro unlock so the free tier is never a functionless wall (App Review
  4.2). Needs a first-run empty-state landing: **Join invite** (primary) /
  **Try demo** / **Unlock Pro**.

- **Demo mode (in-app, read-only) — DESIGN in `docs/demo-mode-design.md`
  (2026-07-25)**: the reviewability + curiosity mechanism that makes fully
  gating manual config safe for App Review (a serverless first-run otherwise =
  4.2 risk). Bundled, offline fixtures — NOT a demo server (hosting canned data
  is pure overhead). Throwaway `demo` profile (new HiveField 53) with modules
  pre-configured against a `https://demo.tailarr` sentinel; a `DemoAdapter`
  (Dio `HttpClientAdapter`, same fake-adapter pattern as
  `test/tailscale_retry_test.dart`) serves `assets/demo/*.json` (Blender open
  movies — Sintel/Big Buck Bunny — so it's honest), swapped in per-module
  beside `attachTailscaleConnectRetry(dio)`. Entry: "Try the demo" on the
  landing + persistent "Demo — Exit" banner. Tiny diff, no module-screen
  changes. Full plan + code sketch in the design doc.

- **First manual connection: hard-gated vs. free trial (OPEN decision)**:
  hard-gated is cleaner for "non-server is Pro"; a trial softens conversion but
  muddies the line.

- **Pro unlock mechanism (not built)**: one-time StoreKit IAP unlock. Pairs
  with the gate above — the unlock flips the "not-Pro" check the manual editors
  and Add Profile read.

## Release Ops (standing)

TestFlight release flow (per build): trigger `testflight.yml` → CI builds +
uploads → run **`scripts/asc_release.py --skip <prev-build-id> --notes-file
<notes> --revoke-cert`** (polls VALID skipping the previous build's id →
betaAppReviewSubmission → Public Beta group `9d6bdfdb-…` → whatsNew → cert
cleanup). Same 11.0.0 version string → beta review auto-APPROVES fast. The
script **retries transient Apple 5xx** on the mutating steps — the Public Beta
**group-add hit a spurious 500 on build 29** and without a retry the build
would silently never reach testers (it exits non-zero if the group-add truly
fails). It also skips the group-add if already a member. Steps handled:

- **Cert-cap policy (net-flat) — ALWAYS run after a build goes live:**
  `python3 scripts/revoke_oldest_cert.py --revoke`. Each CI build mints one
  "Created via API" dev cert (`-allowProvisioningUpdates`); Apple caps them
  (~11) and Archive then fails. The script revokes exactly the OLDEST orphan
  while keeping the local `FL7LS84W49` and the NEWEST (in-use) cert — so the
  count stays flat and the cap is never hit again. Run it only AFTER the build
  is live (nothing signing then). Replaces the old reactive bulk-revoke.
  (Adopted 2026-07-25 after build 28; first steady-state revoke done then.)

- **Notify Stephen of a live build via Tailarr push:** `scripts` (or the
  session helper) publishes to the `tlr-ops` ntfy topic through the controller
  (`ssh tailarr` → read publisher creds from `/root/Pods/.ntfy.json` → POST to
  the ntfy public_url). This rides the real APNs push pipeline (fixed
  2026-07-25 — see the push-relay session log).

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
- **Hive** NoSQL database (NOT encrypted — see the M2 finding in
  `docs/security-audit-2026-07-25.md`; encrypting at rest is a hardening
  fast-follow. On iOS/Android the OS file-protection partially covers it at
  rest; desktop builds do not.)
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

## Session Log — 2026-07-25 (marathon: builds 24→29, push fixed, audits, M2, magicsock outage fix)

Enormous continuous session. Everything below is on master + pushed;
**TestFlight builds 24 through 29 are all LIVE** (same 11.0.0 fast path). The
earlier "(later: builds 24-26…)" log below has fuller detail on the first half;
this entry is the resumable summary of the whole day.

### PUSH NOTIFICATIONS — FIXED (was never actually pushing)
Stephen: "notifications seem slow / not sure they're push." Root cause was NOT
the app or the podscale server — both innocent. The hosted APNs relay
`push.tailarr.com` had a **Sandbox-only APNs auth key** (`2ZSZ3JB589`), so every
TestFlight (production) wake got `apns 403 BadEnvironmentKeyInToken` → nothing
delivered → devices fell back to slow iOS background poll. Stephen created a
**Production-capable key `ZZN87K3868`**; I installed it on the relay, repointed
`APNS_KEY_ID`/`APNS_KEY_FILE`, restarted, verified prod now returns
`BadDeviceToken` (healthy), real push landed. Old sandbox key to be revoked in
the Apple portal (no ASC API for APNs keys). **INFRA ACCESS (durable):**
`ssh relay` = push.tailarr.com (service `tailarr-relay.service`, Go binary,
config `/etc/tailarr-relay/env` + `AuthKey_*.p8`). `ssh tailarr` = the
controller (Oracle box 141.148.178.154; pods `tailarr`/`ntfy`/`tailarr-gate`).
Relay probe: `curl -sX POST -d '{"token":"<64hex>","sandbox":false,
"kind":"alert"}' https://push.tailarr.com/wake` → healthy=`BadDeviceToken`.

### magicsock outage — ROOT-CAUSED + FIXED (embed session), shipped build 29
TestFlight feedback showed Users/Radarr/**Tailscale Status page** all throwing
"An Error Has Occurred / Try Again" in clusters, "Try Again didn't work". Both
sides proved: the **v0.3.3 watchdog full-restart** = a ~45s app-wide tailnet
OUTAGE (node down while `Up()` runs; `status()` throws; dial falls back to
direct; all `*.ts.net`/100.x fail). The "ReceiveIPv4 not running" warning ITSELF
is benign (traffic flows over DERP). Decision: **Option A** — embed session
shipped **v0.3.5** (rebind-only, auto-restart removed; keeps v0.3.4 telemetry).
App side: pinned **v0.3.5** (framework-v1.92.5-6, SHA cba3bae6…), added a
**Self-Heal Telemetry card** to the Status page (rebinds/restarts + timestamps),
and softened the Status error to "reconnecting, refreshes automatically".
**SOAK PENDING:** Stephen roams WiFi↔cellular, sees the warning, screenshots the
telemetry card while showing AND cleared — clean proof = **restarts=0, rebinds
increments**. That's the last confirmation the embed session needs.

### Security audits (client + server) — `docs/security-audit-*.md`
Two 4-reviewer read-only audits. **Client batch SHIPPED (build 27)**: invite
consent gate (H1), error-dialog/clipboard redaction (H2), `openLink` scheme
allowlist (M1), transport floor (H3: TLS-validate default TRUE + iOS ATS→
NSAllowsLocalNetworking), Android allowBackup=false (M4), location trim (M6),
backup strips the Tailscale key (M3), LogRedactor header/JSON rules (L3), Android
perm cleanup (L7). **Server audit → SERVER-SESSION prompt handed off** (they're
working it): H1 API bearer off-by-default (unauth `op_exec`/`op_install`), H2
catalog-install NAME_RE gap → ACL grant injection, M1 gate cred-harvest, M2
key-reissue-doesn't-revoke, M3 NFS host_path injection. Server is otherwise
defensively solid (no shell=True, good secret-at-rest, correct whois model).

### M2 — Hive encryption at rest, SHIPPED build 28, device-verified
Every box now opens with a `HiveAesCipher`; key in the iOS Keychain via
`flutter_secure_storage`. One-time plaintext→encrypted migration on first launch.
**Device-verified on the sim** (the gotcha: Hive encrypts VALUES not keys — box
keys stay readable; verify via absence of value strings + high-entropy value
bytes). Migration data-loss-on-crash risk ACCEPTED: no real users yet + state is
server-driven (self-heals on rejoin). `lib/database/encryption.dart`.

### Smaller fixes shipped this session
- **Server-driven profile rename** (build 24): profile follows `server.name` from
  /self/services live; renames "Tailarr"→"Oracle Tailarr". Migrates name-keyed
  notification/inbox/shared-state.
- **Cold-load retry** (build 25/26): `attachTailscaleConnectRetry` Dio
  interceptor on all module clients — retries connection + proxy-502 failures
  during the connect window.
- **Inbox delete-resurrects** (build 29): `NtfyProfileState.dismissedIds` — a
  poll no longer re-adds a deleted notification.
- **Request-Access UX** (build 29): parent screens hide the Connection Details
  row when `shouldRequestAccess`; connection-details page drops Test Connection
  on managed and the whole bar on request-access.

### Release ops — now scripted + documented (see "## Release Ops (standing)")
- **`scripts/asc_release.py`** — full ASC release with **retry-on-transient 5xx**
  (the Public Beta group-add hit a spurious 500 on build 29 that would've
  silently dropped it) + optional `--revoke-cert`.
- **`scripts/revoke_oldest_cert.py --revoke`** — net-flat cert-cap policy, run
  after each build goes live (keeps local `FL7LS84W49` + newest; revokes oldest
  orphan). No more cap failures.
- **Build-live push** to Stephen via `ssh tailarr` → publish to the `tlr-ops`
  ntfy topic with the publisher creds (rides the now-fixed push pipeline).

### Next (nothing running)
- **magicsock soak screenshots** (Stephen's action → embed session).
- **App Store submission** (the next big strategic item — listing copy,
  screenshots, privacy/export questionnaires; I offered to draft the copy).
- non-server=Pro + demo mode (design done, `docs/demo-mode-design.md`; decision
  pending). Device revoke; Server module v2 remainder; profile-delete lockup.
- Revoke the old sandbox APNs key `2ZSZ3JB589` in the Apple portal.

---

## Session Log — 2026-07-25 (later: builds 24-26, security audit, PUSH RELAY FIXED)

Huge session. Highlights, newest concern first:

### Push notifications were silently NOT push — root-caused to the relay's APNs key
Stephen: "notifications seem slow / not sure they're push." Traced the whole
pipeline: app registers APNs token → controller `_push_waker_loop` streams every
ntfy topic (admin acct) → on each message hits the hosted relay
`push.tailarr.com/wake` → APNs → NSE. All app/controller pieces were HEALTHY.
Probed the relay directly (`POST /wake` with a fake token): **production APNs
returned `apns 403 {"reason":"BadEnvironmentKeyInToken"}`; sandbox returned
`BadDeviceToken` (healthy).** Root cause: the relay's APNs auth key
`2ZSZ3JB589` ("Tailarr Push Relay") was created **Sandbox-only**. TestFlight =
production APNs → every wake rejected → nothing delivered → devices fell back to
iOS background poll = "slow." **App and podscale server were both innocent.**
- **FIX (done, live):** Stephen created a Production-capable APNs key
  **`ZZN87K3868`** (Team scoped / Sandbox & Production) — APNs key environment is
  immutable, so a NEW key was required, not an edit. I have **SSH access to the
  relay** (`ssh relay`, ubuntu@; service `tailarr-relay.service`, Go binary
  `/usr/local/bin/tailarr-relay`, config `/etc/tailarr-relay/env` +
  `AuthKey_*.p8`, both 0600 owned by `tailarr-relay`). Installed the new .p8,
  repointed `APNS_KEY_ID`/`APNS_KEY_FILE`, restarted, verified production now
  returns `BadDeviceToken` (auth OK). Real test push (via
  `POST https://tailarr.tail600657.ts.net/api/ntfy/test`) LANDED on Stephen's
  phone. Fixed for ALL TestFlight users; no build/resubmit needed (key isn't
  build-bound). Old sandbox key `2ZSZ3JB589` to be REVOKED in the Apple portal
  (no ASC API for APNs keys — portal click only); its dead .p8 removed from the
  relay. `env.bak.<ts>` backup left on the relay.
- Relay probe cheatsheet: `curl -sX POST -d '{"token":"<64hex>","sandbox":false,
  "kind":"alert"}' https://push.tailarr.com/wake` → healthy = `BadDeviceToken`,
  broken-auth = `BadEnvironmentKeyInToken`/`InvalidProviderToken`.

### Security audit (client + server) — full reports in docs/
- `docs/security-audit-2026-07-25.md` (client, 4 reviewers) → **pre-store batch
  SHIPPED to master** (`47128cf5`): H1 invite consent gate, H2 error-dialog/
  clipboard redaction, M1 `openLink` scheme allowlist, H3 transport floor
  (TLS-validate default TRUE + iOS ATS→NSAllowsLocalNetworking), M4 Android
  allowBackup=false, M6 location trim. **Quick-wins** (`2415a12b`): M3 backup
  strips the Tailscale auth key, L3 LogRedactor header/JSON rules, L7 Android
  perm cleanup. OPEN: **M2 encrypt Hive at rest** (load-bearing; needs migration
  + device verify — deliberately NOT rushed), M5 SSRF guard, L2 pasteboard, L5
  deps.
- `docs/security-audit-server-2026-07-25.md` (podscale, 4 reviewers) — server is
  defensively solid (no `shell=True`, great secret-at-rest, correct whois model).
  Fixes are a SERVER-SESSION job (prompt drafted): H1 API bearer off-by-default
  (unauth `op_exec`/`op_install`, ACL is the only gate), H2 catalog-install name
  skips `NAME_RE` → path traversal + ACL grant injection, M1 gate-compromise
  cred harvest, M2 key-reissue-doesn't-revoke, M3 NFS host_path injection.

### Builds + features shipped this session (all on master, TestFlight live)
- **Build 24**: notifications field-naming diagnostic (`cea6b9fa`) + server-driven
  profile rename (`90815c3d` — follows `server.name` on /self/services;
  server v0.49.0 ships it; profile auto-renames "Tailarr"→"Oracle Tailarr").
- **Build 25**: cold-load connect-window retry (`a6560b6f` — Dio interceptor on
  all 6 module clients; retries connection failures while the tunnel comes up).
- **Build 26**: proxy-502 added to the retry classifier (`d0f60020`) + **log
  credential redaction** (`73f1722d` — `LogRedactor` scrubs apikey/token/NZBGet-
  password/tskey/Bearer at write + export). Then the security batch above.
- Cert cap did NOT recur (24/25/26 all clean).
- Backlog pruned + split into **Backlog** / **Pro Backlog** (`75dab9e8`);
  **demo-mode design** doc `docs/demo-mode-design.md` (in-app read-only demo,
  the App-Review-4.2 answer for non-server=Pro — NOT a hosted demo server).

### Still open / next
- Client build 27 to ship the security batch (device-verify the consent dialog +
  TLS-default-on first; add self-signed-cert caveat to What-to-Test).
- Server-session security prompt (H1/H2/M1-M3).
- M2 Hive encryption (deliberate, device-verified).
- magicsock health-warning bug — in the tailscale_embed session (prompt sent).

---

## Session Log — 2026-07-25 (self-config root cause: gate dialed by bare short name → build 23)

Stephen filed **two TestFlight bugs to be looked at together** (build 22,
04:23/04:24): (1) Tailscale Status "connected, 4/4 peers online incl.
sonarr + tailarr-gate, but it's not self configured"; (2) Sonarr showing
the plain manual editor (Enable toggle off + Connection Details), NOT
"Server Managed" / "Request Access". Diagnosed as ONE bug and fixed;
**build 23 is LIVE-pending on TestFlight** (WAITING_FOR_REVIEW, same
11.0.0 fast path; id `71f17df4-00c0-473e-8f3f-de4de5b76ceb`).

### Root cause — the gate is dialed by a BARE MagicDNS short name
Everything the app pulls from the server — `/self/services` (self-config)
AND `/self/notifications` — goes through `http://tailarr-gate/`, a bare
short name (`NtfyGatewayClient.DEFAULT_HOST`). That resolves UNRELIABLY
through the embedded proxy; on device it fails outright ("Failed host
lookup: tailarr-gate" — the same string in the build-21/22 notifications
feedback). The controller works only because it's reached by its FULL
name (`tailarr.tail600657.ts.net`), which is exactly why the Status page
looks perfectly healthy while nothing configures. **Peer-visible ≠
short-name-resolvable.** The reconcile trigger fires every launch and the
reconcile logic is correct — it just never got a response.

### Shipped (commit `ea7a2a30`)
- **Dial the gate by FQDN** — new `lib/system/gateway/gateway_host.dart`:
  `gatewayClient()` reads the live MagicDNS suffix (`IO.tailscaleStatus()
  .magicDnsSuffix`) and dials `tailarr-gate.<suffix>.ts.net`, falling back
  to the bare name only when the node isn't up / on web. All FIVE gateway
  call sites routed through it (services sync, foreground + refresh
  selfNotifications, 2× push-token). This is the actual "self config isn't
  working" fix AND fixes the notifications "Not Connected" the same way.
- **`hasServerGrantList()`** (`server_driven_connection.dart`) — dropped
  the `tailarrServerEnabled && tailarrServerHost` precondition an
  invite-joined profile never satisfies (it reaches the server via the
  hidden gate, not a user-entered host, so it's legitimately `serverOwned`
  with the module DISABLED). Now `serverOwned` alone counts →
  ungranted services correctly show "Request Access", not a manual editor.
  **This is ALSO the fix for the build-22 "SABnzbd — I should see request"
  feedback** (same gating leak). Extracted pure `hasServerGrantListFor()`
  for unit testing.
- **`GatewayServicesSync.refresh()`** — added `serverOwned` as a re-sync
  trigger so existing installs SELF-HEAL on next foreground (no re-join).
- **test/server_driven_connection_test.dart** — 5 cases locking the
  invite-joined-profile grant-list recognition. analyzer clean; 24/24
  gateway+grantlist tests green.

### Why it self-heals Stephen's existing install
`refresh()` runs from the ntfy loop at every launch; his profile passes
the guard (serverOwned + gatewayManagedModules `['tailarr']`) → dials the
FQDN gate → succeeds → reconcile adopts the badged `sonarr` (flips to
"Server Managed") and sets `tailarrServerEnabled`/host along the way.
Verified at DATA/unit layer only — NOT device-confirmed (needs Stephen's
production tailnet). **NEXT: Stephen verifies build 23 on device** —
Sonarr auto-adopts, notifications connect; the Notifications status card
now shows exactly which host was dialed if it still fails (→ then it's a
tailscale_embed short-name-vs-FQDN resolution finding, not app).

### Release-ops (build 23)
- First CI attempt (run 30144414080) FAILED at Archive on the **recurring
  cert cap** ("account has reached the maximum number of certificates";
  11 certs = 10 "Created via API" orphans + local `FL7LS84W49`). The
  NotificationService/Runner "No profiles found" errors were downstream of
  the cert failure, NOT a separate App-Group problem (that's registered).
- **Revoked all 10 orphan API certs via ASC API** (`scratchpad/revoke.py`;
  DELETE /v1/certificates/{id}, kept FL7LS84W49) → `gh run rerun --failed`
  → clean. `-allowProvisioningUpdates` regenerated cert + profiles on its
  own; **no dashboard step needed** this time. Cap recurs ~every 11 builds
  → backlog: persist a CI signing identity to stop it.
- ASC post-upload driven by `scratchpad/asc_release23.py` (poll VALID
  skipping the prior build id `300fdfa1`=build22 → betaAppReviewSubmission
  201 → Public Beta group 204 → whatsNew 200).

### Still open after build 23 (unchanged by this session)
- magicsock warning survives refresh (embed session);
  service-module COLD-load "Try Again" race ("try again always works but
  shouldn't" — notifications race was fixed but the individual service
  modules still cold-load before the tunnel is up, no auto-retry);
  profile-delete lockup; `/api/info.name` v0.27 (server) for the drawer
  "Tailarr (tail600657)" disambig.

---

## Session Log — 2026-07-24 (later: TestFlight feedback triage + localization rebrand landmine)

Short session. Reviewed TestFlight feedback via the ASC API, triaged it
against the backlog with full-res screenshots, and fixed a real rebrand
bug + its root cause. One commit (`ed214089`), NOT yet built/shipped.

### TestFlight state (ASC API pull)
- **17 testers** (all anonymous public-link, unchanged). **0 crash
  submissions.** 15 screenshot feedback items.
- **14 of the 15 are Stephen's own dogfooding** (device `iPhone16_1`,
  iOS 27.0) from the build 13-22 session — they map 1:1 to known backlog
  items. The only genuinely-external one is the OLD 2026-07-18 "when's it
  hitting the App Store?" note (iPhone13_1, iOS 18.7.8) — no new outside
  feedback since.
- Screenshots archived in this session's scratchpad `shots/` (ASC image
  assets; pull script pattern: GET /v1/apps/{id}/betaFeedbackScreenshot
  Submissions, download `attributes.screenshots[].url`).

### Feedback → backlog mapping (from the screenshots)
- **"Magic socks" ×4** incl. "tried refreshing, still around" → Tailscale
  Status page shows Connection **Running (orange)** + Health Warning
  "MagicSock ReceiveIPv4 is not running" **while 8/8 peers are online and
  working**, survives repeated refreshes. **This is the CONFIRMED
  real-device FAILURE of v0.3.3** — per the backlog's own test criterion
  (warning surviving repeated refreshes = new finding). Verdict is no
  longer "pending"; carry to the tailscale_embed session: either the
  watchdog restart isn't clearing the health flag or the warning is
  cosmetic while traffic works.
- **"Try again always works but shouldn't"** → Sonarr module "An Error Has
  Occurred / Try Again" on COLD load. Same Tailscale-startup race as
  notifications, but `2614f283` only fixed the notifications auto-config
  path — the individual SERVICE MODULES still cold-load before the tunnel
  is up and don't auto-retry. Open. (Notifications "Not Connected: Failed
  host lookup tailarr-gate" screenshot = same race, inbox-connection side.)
- **SABnzbd "I should see request"** → SABnzbd showed the normal manual
  editor (Enable toggle + Connection Details), NOT a Request Access /
  Server-Managed card → the `hasServerGrantList()` gating is still leaking
  on an ungranted service. Verify against build 22 / re-check the
  SERVICES_LAST_SYNC fragility.
- **"Locked up… migration"** → the Delete Profile dialog listing "Apple
  Container" + "Mini VM" with the tap ripple ON "Mini VM". NEW CLUE: the
  lockup fires when DELETING a server-owned profile (node-forget/cleanup
  churn), matching backlog suspect (a). Still not root-caused.
- **"picked up name from server"** → drawer shows "Tailarr" +
  "Tailarr (tail600657)" (host-derived disambig). Expected until the
  server ships **`/api/info.name` (v0.27)**; app side already falls back.
- **"Notifications Is Not Enabled" / "no request for Annan"** → early-build
  (11:31) empty states + leftover `default` profile; both addressed by
  later build-22 commits (always-on notifications, leftover-default
  removal). Verify gone on 22.

### SHIPPED (commit `ed214089`) — localization rebrand landmine FIXED
- **Root cause found**: the Tier-1 rebrand (2026-07-04) branded only the
  **bundled** `assets/localization/*.json`, never the per-module **source**
  `localization/*/*.json`. But CI regenerates bundles FROM source at build
  time (`generate_localization.dart`, testflight.yml line 65 — also part of
  `npm run generate`). So **every build silently reverted the branding to
  "LunaSea"** — that's why build 22 showed "LunaSea" on the Profiles card
  despite the committed bundle saying "Tailarr". The committed branded
  bundles were a lie; they never shipped.
- **Fix (source is now the source of truth)**: naive `LunaSea→Tailarr`
  across all 15 source files (**179 occurrences**) + added the missing
  **`lunasea.OK`** key to `localization/lunasea/en.json` (the Pro Mode
  dialog's OK button was rendering the raw key `lunasea.OK` — the key
  existed nowhere; code at `profiles/route.dart:67` already calls
  `'lunasea.OK'.tr()`, no code change needed). Regenerated bundles.
- **Provably safe**: after branding sources + regen, the ONLY diff to the
  committed shipping bundles is `en.json +1` (the new key). Every
  non-English bundle came out byte-identical to what was committed —
  proving the committed bundles were exactly a naive replace of source all
  along. Now regeneration is stable for ALL languages, not just English.
- Verified at DATA layer only (key resolves in loaded bundle, all JSON
  valid, 0 "LunaSea" left in source or bundles). NOT sim/device-rendered.
- Side note (untouched): the dead `settings.Account*`/cloud-backup string
  family (stripped feature in the v11 fork) now reads "Tailarr Account" —
  harmless if those screens are unreachable; pull if desired.

### NEXT
- **Build 23 not yet cut.** Only content since build 22 is this l10n fix
  (low-risk, user-visible). No blocking reason to build; caveats: (a) it
  ships ONLY the cosmetic fixes, none of the meatier open items above;
  (b) cert cap recurs ~every 11 builds (hit at 13) → ~build 24, keep the
  orphan-revoke step ready; (c) fix verified at data layer only — a quick
  sim build would confirm the two strings render before a TestFlight cycle.
- Open bugs still unfixed: magicsock-survives-refresh (embed session),
  profile-delete lockup, SABnzbd request-access gating, service-module
  cold-load retry race, `/api/info.name` (server side).

---

## Session Log — 2026-07-24 (server-driven everything: services self-config, invite, per-profile isolation, push, Pro/Basic tiers, builds 13→22)

Enormous shipping day. Everything pushed to master; **TestFlight builds 13
through 22 all LIVE** (same 11.0.0 fast path). Ledger of features, all
server-driven-first, in commit order:

### Gateway services self-config (`/self/services`, server v0.23→0.26)
- `NtfyGatewayClient.selfServices()` + `GatewayServicesReconciler`
  (`lib/system/gateway/gateway_services.dart`): the tailarr-gate hands out
  every service the device's PERSON is badged for; the app materializes
  them — sonarr/radarr/lidarr/sabnzbd/nzbget/tautulli configure natively,
  `tailarr` = the server module, everything else (incl. overseerr, which is
  feature-flagged off) → External Module bookmark. Provenance tracked per
  module (`LunaProfile.gatewayManagedModules`, HiveField 50;
  `LunaExternalModule.gatewayName`, HiveField 2). Contract rules all
  implemented + unit-locked (`test/gateway_services_test.dart`): empty url
  keeps stored value, auth:null keeps module + flags missing credential,
  revoked badge disables AND un-manages (→ Request Access), external→native
  jump absorbs the bookmark, unknown types → bookmarks, version skew (old
  404 / notifications payload) degrades silent. **Server-wins**: a granted
  service overrides even hand-entered config.
- Test server `podhost` self-upgraded 0.20→0.26 this session via POST
  /api/controller/upgrade. **GOTCHA relayed to server session**: a bare
  (no body) upgrade call on v0.22.2 DOWNGRADED to 0.20 (stale "latest");
  always pass `{"version":"X.Y.Z"}`.

### QR suite invite (one-tap join)
- Share-config payload gained `enroll:{key,name?}`. Reissue Key / Add User
  present the invite as a QR (native camera scans it) + a
  tailarr.com/import link. Import screen's **Join & Set Up**: enroll node →
  gateway configures notifications + materializes services. Live-verified
  clean-slate on sim against v0.24/0.26.

### tailscale_embed magicsock saga → v0.3.3
- Bumped v0.1.0→0.3.1→0.3.2→0.3.3 chasing the "MagicSock ReceiveIPv4 not
  running" health warning. v0.3.1 (resume rebind) and v0.3.2 (path-change
  rebind + status watchdog) BOTH failed on real devices (field reports).
  v0.3.3 (commit 0136b69, framework-v1.92.5-4) is the fix: source review
  proved Rebind() is a no-op once the receive goroutine has exited; only a
  full tsnet server restart respawns it, so the watchdog now escalates to
  an in-place server restart. **OPEN: real-device verdict still pending** —
  Stephen must roam WiFi↔cellular with the Status page open ~60-90s; a
  warning that survives repeated refreshes = a NEW finding. 3 field
  screenshots archived at `~/projects/magicsock-*.jpg`.

### Notifications — always-on, per-profile, real push (server v0.26)
- Stripped ALL user knobs (build ~notifications route is a status surface;
  no enable toggle / topics / manual entry). Always-on module.
- **Real APNs push (stage 3)**: NSE target (`ios/NotificationService/`),
  App Group `group.com.stephenspeicher.tailarr`, AppDelegate platform
  channel, `POST /self/push-token`. **Push VERIFIED end-to-end on device**
  (real content from the user's own server via the NSE). Sandbox flag
  follows aps-environment (embedded profile), NOT kDebugMode.
- **Complete per-profile isolation**: NotificationsDatabase keys namespaced
  `NOTIFICATIONS_<field>@<profile>`; inbox tagged + box-keyed by profile;
  shared-state file (App Group) is a per-profile map; NSE + BG isolate
  fetch across all profile slices. Profile switch re-scopes everything.
- **Startup-race fix** (build 21): auto-config raced the Tailscale node
  coming up → "Not Connected: Failed host lookup: tailarr-gate" stuck for
  an hour. Now retries across the connect window + on foreground; throttle
  1h→2min.

### Server-owned profiles (THE isolation keystone)
- Invite join creates/reuses a profile OWNED by the server (`serverOwned`
  HiveField 51), named after it, NAME-LOCKED (excluded from Rename +
  `_rename` throws `ServerOwnedProfileException`; reuse/isolation keyed by
  HOST not name). All server config lands there — user's own profiles never
  touched. Migration converts legacy server-attached profiles (detection:
  `tailarrServerEnabled && host && tailscaleEnabled`; keeps custom names,
  renames only `default`); also re-runs after a config restore. Leftover
  empty `default` removed on join. Multi-server: distinct/deduped names
  (`Tailarr`, `Tailarr (taila06ea9)`), same-display-name handled — proven
  in `integration_test/multi_server_profile_test.dart`.
- **Server display name** (contract for server session): `/api/info.name`
  (v0.27) → embedded in invite `enroll.name` → profile named after it.
  App side DONE + forward-compatible (falls back to host-derived).

### Server-driven modules (no user config)
- Managed service → locked "Server Managed" card; ungranted (on a server
  profile) → "Request Access" (shares an admin request); standalone → manual
  editors. Auto-adopt (no "Use Server Config" button). Enable toggle
  gated the same way. `hasServerGrantList()` = serverOwned OR
  gatewayManagedModules OR SERVICES_LAST_SYNC>0 (the SABnzbd fix — timestamp
  alone was too fragile). Notification detail sheet drops raw topic/priority.

### PRODUCT DIRECTION — tiers (decided this session)
- **Pro** (paid, later): manual/BYO-server profiles. Gated in ONE place —
  Add Profile → "Pro Mode Coming Soon" dialog. Free = server-driven only.
  Rationale: make the Suite feel like a product, not a collection of tools;
  monetize the escape hatch. GPL makes the client gate soft — that's fine
  for a product-focus (not revenue-max) goal. One-time unlock when built.
- **Basic** (free, server-tagged): admin marks a person Basic → `ui:{basic:
  true}` on /self/services (server SHIPPED on branch full-library-stack;
  UX-only, never gates access). App consumes it (commit db75230f):
  `LunaProfile.uiBasic` HiveField 52, resolves defaults→preset→(future)
  overrides via `uiHidesSettings`/`uiShowsDrawer`. **First behavior: hides
  Settings gear + profile switcher.** NOT yet live-verified (server flag on
  a branch, test box runs a release). Contract shape: `ui` object rides
  /self/services, `basic` preset + future explicit `hide_settings`/`landing`
  /`show_drawer` overrides so the server can re-shape the app without a
  client release.

### Release-ops notes (this session)
- **Cert cap hit** (build 13 first try): 11 orphaned "Created via API" dev
  certs → Archive failed. Revoked orphans via ASC API (kept the local
  `FL7LS84W49`), reran. Recurs ~every 11 builds — backlog: persist a CI
  signing identity.
- **App Group provisioning**: registering `group.com.stephenspeicher.tailarr`
  in the portal + assigning to both App IDs was the ONLY step with no ASC
  API — Stephen did it in the dashboard; then I minted dev profiles via the
  API (`asc_make_profiles.py` pattern) after the assignment landed.
- Release script polls builds **by version number** now (immune to the
  ordering/timezone traps that bit builds 10/13). Resilient watcher
  (retry-tolerant poll loop, not `gh run watch` which dies on transient
  network errors).
- **DISK**: hit 100% full twice (dozens of sim builds). Clear
  `~/Library/Developer/Xcode/DerivedData/*` + `CoreSimulator/Caches/*` +
  scratchpad images. Watch it — builds fail cryptically ("No space") when
  full.
- Sim harness: AppleScript `click at` is FLAKY on Flutter widgets (taps
  often don't register); deep links + shared-state-file inspection are more
  reliable for verification. `flutter test` output needs `tr '\r' '\n'`.

### Handoffs drafted (both ready to paste)
1. **App session** (scs32/tailarr): finish the Basic shell (drawerless via
   `uiShowsDrawer`, landing into granted module, **Leave Server** escape
   hatch — REQUIRED before Basic ships or users are trapped), + build the
   **native Overseerr module** (currently feature-flagged off; un-gate,
   build against Overseerr API, support Jellyseerr `type:overseerr`) — the
   real payoff a Basic user lands in.
2. **Server session**: `/api/info.name` field (v0.27) for profile naming.

### Build ledger (all LIVE): 13,14,15 (push infra),16,17,18,19,20,21,22.
Build 22 (300fdfa1) = leftover-default fix + Pro gate + Basic groundwork.

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

## Session Log — 2026-07-22/23 (notifications stage 1 → builds 10-12, people model, gateway)

Massive shipping session. Everything pushed to master; **builds 10, 11, 12
all LIVE on TestFlight** (same 11.0.0 fast path; ASC scripting per usual).
Stephen confirmed "all seems to be working" on device at session end.

### Shipped (chronological)
- **Build 10** (7e6a8533): Notifications module stage 1 — full detail in
  the Backlog's ntfy entry. Key architecture: `lib/api/ntfy/` standalone
  client (stage-3 push wake-up will reuse it), Hive typeId 30 inbox box
  keyed by message id, NtfyStreamManager (app's first lifecycle observer),
  workmanager BGAppRefresh + flutter_local_notifications, bg isolate is
  Hive-free (shared JSON file `tailarr_ntfy.json`, split since-markers).
  Plus the overlay-flash fix + version tile that were waiting on master.
- **Build 11** (277c19c0 + b497e3c1): person-centric Users (people model,
  server v0.19/20) + gateway self-config (v0.21) — details in Backlog.
- **Build 12** (f87bd0be): provisioning made visible after Stephen's UX
  report — persisted SETUP_STATE machine + always-on status card + inbox
  links + queried-host/legacy-banner debug surfaces on Users. Users-screen
  field report proven app-innocent via live-payload repro test.
- **Post-build-12, riding build 13** (1f4f71fe + 3104625c): inbox
  swipe-to-dismiss, tap-for-detail sheet, All/Media/Server filter;
  "Updateing"/"Stoping" progress-label fix (String.asProgressLabel()).

### Release-ops notes (learned this session)
- ASC release script pattern lives in session scratchpads — REWRITE NOTE:
  poll /v1/builds sorted by uploadedDate but SKIP the previous build's id
  (the API shows the old build as newest right after CI upload; build 10's
  script fired early and briefly overwrote build 9's notes).
- Use **/usr/bin/python3** (system) for PyJWT — homebrew python3 lacks it.
- Apple's exportArchive endpoint 502'd once (build 12 first attempt) —
  `gh run rerun <id> --failed` fixed it; `gh run watch` SURVIVES a rerun
  of the same run id (the build-12 watcher rode through and completed the
  ASC chain itself).
- Build ids: 10=6420d12f…, 11=ab9f17f8…, 12=85623fc0….
- Flutter nags to upgrade — do NOT (3.38.6 pin, see toolchain warning).

### Test infrastructure (current state)
- Test server guest `podhost` runs **v0.22.2** (I upgraded 0.16→0.20→
  0.21→0.22.2 via POST /api/controller/upgrade), ntfy pod + Funnel +
  tailarr-gate all deployed and healthy on taila06ea9.
- Person "Gate E2E" (id 7ed3a78d, badges heresphere+server) exists with
  the sim node `tailarr-app-gate-e2e` attached — reusable E2E fixture;
  person keys are SINGLE-USE, mint fresh via {do:"reissue"}.
- Integration tests added: notifications_inbox_test, gateway_e2e_test
  (needs fresh key + SERVER_HOST), users_people_render_test (in-process
  HttpServer fixture — no tailnet needed), tailarr_server_people_test +
  ntfy_models_test (pure unit).
- Sim harness gotcha: pumping module routes needs the FULL LunaBIOS shell
  (LunaButton dereferences LunaRouter.navigator.currentContext).

### Pending / next
- **Build 13** when desired (inbox polish + label fix are on master).
- On-device over days: BG refresh cadence, gateway re-sync after admin
  badge flips, second-share crash (old backlog item, still open).
- Deep-link route for tailarr://ntfy (parser done, TODO in router).
- Stage 2/3 notifications (per-user ACLs server-side; APNs push relay).
- Relay to server session: controller pods upgraded from pre-config-file
  installs lack .config.json → gateway deploy fails ("controller tailnet
  IP unknown"); I hand-wrote one on the test box.

## Session Log — 2026-07-22 (status screen, build 9, App Store decision)

### Shipped (all pushed to master)
- **Tailscale Status screen** (e5742d62): Settings > General > Network >
  "Tailscale Status" → live page (5s auto-refresh + pull-to-refresh):
  color-coded connection state, node card (identity/hostname/MagicDNS/
  IPs/DNS suffix/proxy port), health-warnings card, peers list
  (online-first, subnet routes). Files: pages/tailscale_status.dart,
  route CONFIGURATION_GENERAL_TAILSCALE_STATUS, IO.tailscaleStatus()
  facade + web stub. Verified: sim (stopped state) + NEW
  integration_test/tailscale_status_page_test.dart rendering connected/
  health/stopped against the plugin's FakeTailscaleBackend (first
  adoption; all passing). GOTCHA: LunaBlock body lines are RichText —
  widget-test finders need `find.text(..., findRichText: true)`.
- **Build 9 LIVE on TestFlight**: CI run 29941163795 → build id
  ff1a9d27-dbe1-4e7e-a75a-e2d4358bfa94, VALID → review APPROVED
  (same-version fast path), Public Beta group, What to Test notes ask
  testers to report magicsock-warning sightings.
- **Post-build-9 (ride build 10)**: connecting-overlay flash fix
  (4c66ac2a — TailscaleGuard overlayBuilder now defers visibility 400ms,
  input still blocked from frame one; Stephen saw the blip on launch) and
  **version tile** in Settings > System (fb63c64a — "Tailarr 11.0.0 (N)"
  + "flavor · commit", tap to copy; first version display in the v11
  codebase; CI stamps beta·sha via env vars, local builds show
  edge·master by design).

### ⚠️ Toolchain: local Flutter must stay 3.38.6 (CI pin)
Something upgraded local Flutter in place to 3.44.7 on 2026-07-20 10:58
(reflog in /opt/homebrew/Caskroom/flutter/3.38.6/flutter) — breaks the
build (simple_icons 14.x extends now-final IconData; google_fonts 6.2.1
const-eval error). Ran `flutter downgrade` back to 3.38.6 + reverted the
3.44 migrator churn in ios/ project files. To EVER upgrade Flutter:
bump google_fonts→8.x, simple_icons→16.x, update CI FLUTTER_VERSION,
one PR.

### TestFlight stats (ASC API, first pull)
17 public-link testers (anonymous by design), 207 sessions/30d
(123 = Stephen; 3 engaged testers at 21/16/16), ZERO crash submissions,
1 screenshot feedback (2026-07-18) asking when the App Store version
lands. API notes: metrics endpoint needs `groupBy=betaTesters`;
feedback via /v1/apps/{id}/betaFeedbackScreenshotSubmissions;
GET /v1/builds/{id}/betaGroups is 403 for this key (write is fine).

### Decisions / findings (details in Backlog)
- Build 8 short-name smoke test PASSED on device (backlog updated).
- Magicsock ReceiveIPv4 suspend/resume finding — full handoff note in
  backlog; Stephen carries to embed session with the smoke-test pass +
  FYI that FakeTailscaleBackend now has a consumer.
- ntfy notification plan added to backlog (ed1bf8ca).
- App Store: GO decision. Zagreus precedent found; exception email
  SENT to Jagandeep (me@jagandeepbrar.io, from git history). Backlog
  has the full submission checklist + open V1-version question.
- Phone state: side-loaded dev build (in-place installs via devicectl
  preserved node identity all day); will show "edge · master" in the
  new version tile until TestFlight build 10.

### Pending / next
- **Build 10** when ready (overlay fix + version tile are waiting on
  master); then update phone via TestFlight to rejoin the release train.
- Jagandeep reply (goodwill artifact, non-blocking).
- App Store checklist: listing copy, screenshots, privacy/export
  questionnaires, review notes (optional Funnel demo), V1 decision.
- Embed session handoff (magicsock rebind + short-name pass).

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
- ~~Bare short-name smoke test~~ **PASSED 2026-07-22** (Stephen, real
  device): short names resolve over the tailnet. Relay to the embed
  session together with the magicsock suspend/resume finding above.

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
