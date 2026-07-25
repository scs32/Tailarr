# Tailarr Security Audit — 2026-07-25

Four read-only reviewers (crypto/secrets, dependencies/config, deep-links/input,
credential-leakage) swept `lunasea/`. Findings merged, deduped, and
severity-ranked below.

**Verdict:** no remote-code-exec or secret-exfil-without-user-action. Themes:
(A) no transport-security floor by default, (B) secrets stored & backed-up in
plaintext, (C) untrusted links cross a trust boundary with too little consent,
(D) the log redaction shipped in build 26 is asymmetric (UI paths bypass it).
Most fixes are cheap and central.

## HIGH

- **H1 — Malicious invite link silently joins the victim to an attacker's
  tailnet.** `import_configuration/route.dart:144` `_joinAndSetup`. A crafted
  `tailarr.com/import#…` with an `enroll.key` → one tap sets the auth key, joins
  the attacker's tailnet, then pulls all config/push from the *attacker's*
  gateway. No authenticity check, no prompt naming the network.
  → Consent gate naming the network/server before enrolling.
- **H2 — Error dialog + "Copy" bypass the log redactor.**
  `snackbar_error.dart:17` → `dialogs.dart` `textPreview`. `showLunaErrorSnackBar`
  renders raw `error.toString()` in a viewable dialog with a Copy-to-general-
  pasteboard button — the exact leak class the log redactor closed, on a
  screenshot-and-copy surface (~40 call sites pass raw errors).
  → `LogRedactor.scrub()` at the textPreview/copy boundary.
- **H3 — No transport-security floor by default (three compounding):**
  TLS validation defaults OFF → app-wide accept-all-certs HttpClient
  (`lunasea.dart:19` + `network_io.dart:117`); iOS `NSAllowsArbitraryLoads`;
  Android `usesCleartextTraffic="true"`. A stock install MITMs trivially on any
  non-tailnet HTTPS. Tailnet traffic is moot (WireGuard).
  → Default TLS validation on (or scope override to `*.ts.net`); remove ATS
  blanket + Android cleartext, narrow to local-networking exceptions.

## MEDIUM

- **M1 — Gateway/external-module URLs skip scheme validation**
  (`gateway_services.dart:152`, `openLink` in `links.dart:21`, no allowlist) →
  tapping a bookmark can launch arbitrary schemes (`tailarr:///import#…`
  re-injection, `tel:`, phishing). HIGH chained with H1.
  → Scheme allowlist inside `openLink`.
- **M2 — Hive DB is not encrypted** (`box.dart:65`, no `HiveAesCipher`, no
  secure-storage). All API keys, NZBGet password, ntfy + Tailscale keys in
  plaintext boxes. Mobile partially covered by OS Data Protection when locked;
  desktop isn't; docs falsely claim "encrypted."
  → `HiveAesCipher` with a key in Keychain/Keystore.
- **M3 — Plaintext config backup carries every secret incl. the Tailscale auth
  key** (`config.dart:40`, `backup_tile.dart`). User can save/share/iCloud it.
  → Encrypt the backup or strip `tailscaleAuthKey` + warn.
- **M4 — Android `allowBackup` not disabled** → `adb backup` pulls the plaintext
  DB. → `allowBackup="false"`.
- **M5 — Test Connection on an unsaved import payload = blind SSRF** into the
  victim's tailnet/LAN (distinct success/error snackbars leak reachability).
  → Constrain host to tailnet/https or warn.
- **M6 — Over-broad iOS "Always" location permission** (no matching background
  mode) — privacy over-ask + App-Review flag.
  → Drop to When-In-Use, or remove if unused.

## LOW
- **L1** ntfy token plaintext in App-Group JSON, not excluded-from-backup
  (sandboxed though).
- **L2** Secret copies (enroll key, ntfy password/token) use the general/synced
  pasteboard, no expiry.
- **L3** `LogRedactor` gaps: custom `X-Api-Key`/non-Bearer `Authorization`
  headers, bare JSON key values.
- **L4** Import "Save" only conditionally confirms the destination host.
- **L5** Stale security-sensitive deps (dio, go_router, share_plus, retrofit,
  flutter_local_notifications behind majors; Hive 2.x unmaintained) — no
  confirmed CVEs.
- **L6** Committed `aps-environment=development` — verify CI overrides for
  release.
- **L7** Unnecessary/duplicated Android storage permissions.

## Clean (verified — reassuring)
- **Share-config payload is genuinely safe**: the Tailscale auth key is
  *excluded* (not just hidden), and payloads ride the URL **fragment** only
  (never sent to tailarr.com). Service keys in it are the intended function.
- **Log write + export are properly scrubbed** (the build-26 fix holds).
- **No WebViews anywhere**; ntfy renders as plain text (no HTML/markdown
  injection); notification taps can't trigger URLs.
- No hardcoded secrets; release logging is `kDebugMode`-gated; real signing
  config; NSE inherits ATS; Tailscale auth-key lifecycle (`onKeyConsumed`) good.

## Fix plan
**Pre-App-Store batch (in progress 2026-07-25):** H1 invite consent · H2
error-dialog/clipboard redaction · M1 `openLink` scheme allowlist · H3 transport
floor (TLS default + ATS + cleartext) · M6 location trim + L6 aps-environment ·
M4 Android `allowBackup=false` · fix the false "encrypted" doc claim.

**Hardening fast-follow:** M2 encrypt Hive (migration) · M3 backup secrets ·
M5 SSRF guard · L1–L3 redactor/pasteboard/ntfy-file · L5 dep bump.
