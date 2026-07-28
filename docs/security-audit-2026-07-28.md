# Tailarr Security Audit — 2026-07-28

Two independent adversarial reviewers swept `lunasea/` from the same
defensive-maintainer brief (harden the shipping client; treat server-driven
config, pasted deep-link payloads, ntfy content, and `*arr` responses as
untrusted): a **Fable 5** agent (ran `flutter analyze lib` = 0 errors, findings
mixed verified/by-reading) and **Codex** (`codex exec`; sandbox blocked Flutter
tooling, so all findings by-reading). Findings merged, deduped, and
severity-ranked below. Every item was re-checked against
`docs/security-audit-2026-07-25.md` — this file reports only what is still true
at HEAD, and marks NEW vs. already-tracked.

**Verdict:** no remote-code-exec, no secret-exfil without user action. The live
themes: (A) **secrets added since the M3 backup-strip leak into plaintext
exports** (Quick Connect admin bearer, ntfy/push tokens); (B) **catastrophic-loss
and un-manage-on-non-authoritative-error robustness gaps** (backup import wipes
before validating; Jellyfin disables on a parsed error envelope; profile delete
strands live notification credentials); (C) **`*arr` wire data is force-unwrapped**
in the primary list paths, so a version-skewed/hostile server greys out or
permanently poisons a module; (D) **per-profile notification isolation leaks**
across delete/rename/clear. Most fixes are cheap and central.

**Cross-reviewer note:** the two agents agreed independently on the three HIGH
items, which raises confidence. They disagreed on exactly one point — Jellyfin
disable-on-error (Fable called it safe; Codex called it a bug). **Adjudicated by
reading the code: Codex is correct** (see M2). Each agent also caught real items
the other missed; both are folded in below with attribution.

Both reviewers independently confirmed the **already-fixed / enforced properties
worth not regressing** — see the bottom section.

---

## HIGH

- **H1 — Backup import destroys the whole database *before* validating the file.**
  `database/config.dart:9-35` (`import`) calls `LunaDatabase().clear()` before
  `json.decode` / any shape check. A malformed, truncated, or wrong-shape backup
  → parse throws → **every profile, credential, indexer, module, notification,
  and setting is irreversibly gone**, and the `catch` merely bootstraps a fresh
  default DB. Precondition: user picks a bad backup file (their own truncated
  export, or a hostile one). No malicious server needed.
  → Parse + validate the complete backup into temp objects first, then commit
  transactionally; snapshot-and-restore on any write failure.
  *(NEW — Codex; by-reading. Highest-impact finding in either report.)*

- **H2 — Plaintext backups leak the Quick Connect admin bearer + ntfy/push
  tokens.** `database/config.dart:50-54`, `database/tables/notifications.dart`
  (`TOKEN`/`PUSH_TOKEN`, no `blockedFromImportExport` override). The M3 export
  strip only zeroes `tailscaleAuthKey`; it was never revisited when Quick Connect
  added `serverAdminToken` (HiveField 53), which authorizes **every mutating
  `/api/*`** on the controller, nor for the live ntfy bearer (`tk_…`, sent as
  `Authorization: Bearer`). A saved / shared / iCloud'd backup hands full server
  admin + the ntfy read token to anyone with the file and tailnet reach.
  → In `export()`, zero `serverAdminToken`, notification `TOKEN`, `PUSH_TOKEN`
  (and any custom auth headers) beside the existing key strip — all re-mint on
  restore. Fold into M3-full (encrypt the whole backup) if pursued.
  *(NEW — both reviewers, independently; by-reading. ~3 lines.)*

- **H3 — `*arr` nullable fields are force-unwrapped throughout the primary list
  paths.** Representative sinks: `modules/radarr/core/types/sorting_movies.dart`
  (`sortTitle`/`monitored`/`hasFile`), `modules/radarr/routes/catalogue/widgets/
  movie_tile.dart`, `modules/radarr/core/state.dart`,
  `modules/sonarr/core/types/sorting_series.dart`,
  `modules/sonarr/routes/catalogue/widgets/series_tile.dart`, and worst
  `modules/sonarr/core/state.dart:129` (`{for (s in series) s.id!: s}`). The API
  models leave these nullable with no `fromJson` default; catalogue
  filter/sort/render assume presence and run **inside the builder**. A
  version-skewed or hostile/broken server that returns a movie missing
  `sortTitle`/`monitored` (or `hasFile:true` with no `movieFile`) throws during
  build → grey error screen for the entire module; one id-less series poisons the
  `_series` future **permanently** (every Sonarr screen dead, retry re-crashes).
  The demo fixtures only paper over this. Tautulli's blind `data['response']
  ['data'] as Map` (~266 sites) is a notch below — it degrades to the module
  error state via catch-alls.
  → Normalize DTOs at the boundary with explicit defaults; `.where(monitored ==
  true)`; filter/`whereType` `id`-less entries before the map build; drop UI-layer
  `!` on wire values.
  *(NEW — both reviewers; by-reading. Fable rated HIGH, Codex MEDIUM — kept HIGH
  for the permanent-poison state.dart case.)*

- **H4 — Deleting a profile strands its live notification credentials.**
  `utils/profile_tools.dart:473-492` (`_remove`) deletes only the profiles-box
  entry + Tailscale identity. It leaves `NOTIFICATIONS_*@<name>` (incl. `TOKEN`/
  `PUSH_TOKEN`), the profile's inbox rows, and the `tailarr_ntfy.json` shared-state
  slice, and never calls `mirrorConfig()`. The NSE + background isolate
  deliberately fetch **every** slice, so pushes keep making the app authenticate
  to the deleted server with its (revoked) token and promote its messages. Worse:
  delete server "Tailarr", later join a *different* server that derives the same
  display name (`serverProfileName` dedupes only against *live* profiles) → the
  new profile inherits the orphaned keys; `URL@Tailarr` is non-empty so
  `_autoConfigureIfUnconfigured` early-returns (`ntfy_io.dart:60`) and the app
  shows the **old** server's inbox / polls with the **old** token until
  `refreshFromGateway` overwrites.
  → One awaited `purgeProfile(name)` in `_remove`: delete all name-keyed
  notification keys + inbox rows, remove & save the shared-state slice, then
  `mirrorConfig()`. Reuse `migrateProfileName`'s key enumeration.
  *(NEW — both reviewers; by-reading. Codex rated HIGH, Fable MEDIUM — kept HIGH
  for the cross-server credential-adoption case.)*

---

## MEDIUM

- **M1 — "Clear Inbox" wipes *every* profile's inbox; dismissals recorded to the
  wrong slice.** `modules/notifications/routes/notifications/route.dart:151-156`
  calls `LunaBox.notifications.clear()` (the whole box) while the list is filtered
  to the active profile → other profiles' notifications are destroyed, and their
  ids go through `recordDismissed` scoped to the **active** slice
  (`ntfy_io.dart:93-104`) → the other profiles **resurrect** the cleared items on
  next sync, marked unread. `_compact` (`ntfy_io.dart:580`) also evicts by global
  count across profiles.
  → Scope the clear + dismissal to `matchesProfile(active)`.
  *(NEW — Fable; by-reading.)*

- **M2 — Jellyfin module disabled by a non-authoritative error envelope.**
  `system/gateway/gateway_jellyfin.dart:77` sets `jellyfinEnabled =
  self.isAvailable`, and `isAvailable => ok` (`api/jellyfin/models.dart:75`).
  `selfJellyfin()` returns a *parsed* `{ok:false}` envelope for any non-500,
  non-transport response (401/403/404) rather than throwing. So a transient
  gateway auth/whois hiccup (`401 {"ok":false,"error":"not assigned"}`) persists
  `jellyfinEnabled=false` and hides a working module — the same
  un-manage-on-non-authoritative-error class we fixed for services, reached via a
  non-throwing envelope. The model already exposes `isUnassigned` / `hasNoAccess`
  / `isUnavailable` discriminators that `refresh()` ignores. (A 502 / thrown
  transport error IS preserved correctly — only the parsed error envelope leaks.)
  → Mutate availability only on authoritative outcomes: `ok:true`, or a narrowly
  recognized contract-defined revocation. Preserve stored state on unavailable /
  unassigned / malformed / generic-refusal envelopes.
  *(NEW — Codex; by-reading. Reviewer disagreement; adjudicated in Codex's favor
  by reading the code.)*

---

## LOW

- **L1 — USER rename orphans ntfy state.** `utils/profile_tools.dart:495-516`
  (`_rename`) clones the profile and drops the old key without calling
  `migrateProfileName` (only the *server-driven* rename does, `:184`). Non-server
  profiles can hold gateway-configured notifications, so a manual rename silently
  de-configures notifications and strands the old creds/slice (same NSE
  stale-fetch window as H4). → Call `migrateProfileName(old,new)` in `_rename`.
  *(NEW — Fable; by-reading.)*

- **L2 — Download-job passwords logged verbatim on failure.**
  `modules/nzbget/core/api/api.dart:405-423`,
  `modules/sabnzbd/core/api/api.dart:207-223,520-535`. Error messages interpolate
  the password as an unlabeled positional value — e.g. `Failed to set job
  password (42, hunter2)`. No `LogRedactor` pattern matches that bare shape, so it
  survives write-time and export-time scrubbing into `LunaBox.logs`. → Never
  interpolate the password; log only the job id. (Redactor tweaks are
  defense-in-depth but can't reliably catch an arbitrary bare secret.)
  *(NEW — Codex; by-reading.)*

- **L3 — LogRedactor misses the app's own key field names.**
  `system/log_redactor.dart:67-72` matches `token|password|secret|api_key|…` but
  not `sonarrKey` / `radarrKey` / `nzbgetPass` / `serverAdminToken`. A failed
  backup **import** logs a `FormatException` whose `toString()` embeds a ~70-char
  snippet of the backup around the parse error — which can carry
  `"sonarrKey":"<hex>"` into the persisted, exportable log. → Add
  `"[a-z]*(key|pass|token)"\s*:` (case-insensitive) to the JSON rule. Related to
  L2 but a distinct sink.
  *(NEW — Fable; by-reading. Refines the 2026-07-25 L3.)*

- **L4 — NSE control-topic filter parity gap.**
  `ios/NotificationService/NotificationService.swift:48-60,159`. The `275af0ae`
  `tlr-ctrl-` prefix filter is present, but the Dart filter *also* matches
  `tags.contains('tlr-config')` (`api/ntfy/models.dart`). A config signal on
  another topic carrying only the tag would banner raw JSON from the NSE path. →
  Parse `tags` in `fetchUnseen` and add the tag check. Cheap adjacent hardening:
  truncate title/body and cap `notifiedIds` by size (not just count) so a hostile
  ntfy server can't bloat the shared file / jetsam the NSE.
  *(NEW — Fable; by-reading.)*

- **L5 — Profile-switch race can file one server's message under another
  profile.** `utils/profile_tools.dart:453` sets `ENABLED_PROFILE` before
  `onConfigChanged` bumps the stream generation; an in-flight message from the old
  stream passes the generation check (`ntfy_io.dart:699`), then `storeMessages`
  re-reads `ENABLED_PROFILE` → stored under the *new* profile and advances its
  `since`, potentially suppressing the new server's older messages. Narrow window.
  → Capture the profile name at stream-connect time and thread it into `_store`.
  *(NEW — Fable; by-reading.)*

---

## Already-fixed / enforced properties — DO NOT regress (both reviewers confirmed)

- **Services reconciler is transport-error-safe.** `gateway_services.dart:365`
  reconciles modules only when `response.ok && response.isSupported`; 502s /
  throws / error envelopes / wrong-kind payloads never reach removal
  (`refresh()` swallows the throw into `_lastFailure`). This is exactly the class
  of bug shipped-and-fixed for services — keep the `ok`-gate. (Note: M2 above is
  the *Jellyfin* sync missing this same gate for the parsed-envelope case.)
- **Notifications refresh** changes credentials only on `ok` + a valid
  subscription; preserved on refusals/throws (`ntfy_io.dart:459-489`).
- **TailscaleGuard forever-lockup is bounded.** `pubspec.lock` pins
  `tailscale_embed` v0.3.6 / `9e2d08…`, whose guard wraps
  `embed.ensure().timeout(connectTimeout)` (default 60s) and clears the
  `AbsorbPointer` in `finally`, then shows the non-blocking stuck notice wired at
  `main.dart:83-100`. Worst case is ≤60s of blocked input, not forever. Don't
  remove `stuckNoticeBuilder` or pass a huge `connectTimeout`. (A stale
  no-timeout checkout may sit in pub-cache — harmless, not the resolved ref.)
- **`openLink` allowlist is tight** — `extensions/string/links.dart:8,27-37`:
  http/https only, scheme-checked before every launch; no `launchUrl` bypass
  elsewhere in `lib`. Untrusted gateway/import/ntfy URLs can't reach custom
  schemes.
- **Deep-link import decode is robust** — `share_configuration.dart:141-170`:
  base64 normalize + `jsonDecode` in try/catch → `_invalid()`; version +
  module-support checks; malformed/oversized/truncated can't crash (the old
  "second-share crash" is closed at the parse layer). Test-Connection runs
  `SsrfGuard.guard()` on the **unsaved** payload (`route.dart:306-365`); consent
  gates before overwrite (`:374`) and before join (`:157`).
- **Share-config payload structurally excludes identity material** —
  `fromProfile` carries only service host/key/user/pass/headers; the Tailscale key
  and `serverAdminToken` can't ride it.
- **Hive-at-rest + key hygiene** — `database/encryption.dart`: key only in
  Keychain/Keystore; migration deletes the plaintext file before reopening
  encrypted. The newer network surfaces (ntfy/gateway/jellyfin/pairing models) are
  defensively parsed (`whereType`, `is Map`/`is List`, typed defaults) — hostile
  JSON can't crash those.
- **Logging** routes through `LogRedactor` at write *and* export; the only
  persisted sink is `LunaBox.logs`; no Dio `LogInterceptor`, no release `print`,
  no Sentry/Firebase.

---

## Suggested fix order (cheapest high-impact first)

1. **H1** — backup import: stage + validate before `clear()` *(prevents total
   data loss)*.
2. **H2** — strip `serverAdminToken` / `TOKEN` / `PUSH_TOKEN` from export *(~3
   lines; closes admin-cred leak)*.
3. **H4 + L1** — `purgeProfile()` on delete and `migrateProfileName` on rename
   *(one shared helper)*.
4. **M2 + M1** — Jellyfin availability only on authoritative outcomes; scope
   clear-inbox/compact to the active profile.
5. **H3** — `*arr` null-safe boundary normalization (start Radarr/Sonarr
   catalogue).
6. **L2 / L3 / L4 / L5** — password-log removal, redactor field-name regex, NSE
   tag parity + size caps, profile-switch capture.

Nothing here blocks launch by anything but our own bar — but **H1 and H2 should
land before shipping any build a user might back up**, and H4 before broad
multi-server use.

---

## Re-review (round 2) — reviewer verdicts on the fixes + corrections

The fix commit was re-reviewed adversarially. Codex (by-reading; its sandbox
blocks Flutter tooling) returned per-fix verdicts; the two ship-blockers and
several INCOMPLETE calls were correct and have been addressed in a follow-up
commit:

- **H1 (was INCOMPLETE):** the first cut only rejected structurally-invalid
  input, so `{}` / `{"profiles":[1]}` still cleared the DB then reset to
  defaults. **Now:** `import()` snapshots the live config (`_snapshot`), applies,
  and on ANY failure — including "no usable profile" — rolls the snapshot back
  (`_restoreSnapshot`) instead of bootstrapping defaults. A restore can no longer
  destroy user data.
- **H2 (was a REGRESSION):** blocking `TOKEN`/`PUSH_TOKEN` from export is correct,
  but a normal restore clears then can't re-apply them, dropping live push/ntfy
  until re-mint. **Now:** the pre-clear snapshot carries THIS device's tokens
  forward for any surviving profile (`_restoreLocalTokens`) — they never enter
  the export, but a restore of your own backup keeps them. (Service API keys +
  custom headers deliberately remain in the export — they're user-entered config
  needed for restore and don't re-mint; the real answer is M3-full encrypt-whole-
  backup, still tracked.)
- **H3 (was INCOMPLETE):** extended past sort/filter to the render + derived-list
  + detail-nav paths — `radarr/.../movie_tile.dart`,
  `sonarr/.../series_tile.dart`, both catalogue-route search predicates,
  `radarr/core/state.dart` upcoming/missing, `sonarr/core/state.dart`
  `setSingleSeries`.
- **M1 (was INCOMPLETE):** `_compact` is now per-profile (a busy profile can't
  evict another's inbox), and `recordDismissed` takes an explicit `profile` so a
  switch mid-clear can't misfile dismissals.
- **H4/L1 (was INCOMPLETE on web):** the Hive parts (config keys + inbox) moved
  to a platform-neutral `NtfyHiveMigration` used by BOTH the io plugin and the
  web stub, so web profile delete/rename no longer strands notification state.
- **L2 (was INCOMPLETE):** SABnzbd's `value3` (job-password slot) added to the
  redactor's URL-query rule, closing the `DioException`-URI leak.
- **M2, L3:** confirmed SOLID; unchanged.

Still open (tracked, not regressions): L4 (NSE `tlr-config` tag parity), L5 (the
narrow profile-switch storage race in `storeMessages` — distinct from the
`recordDismissed` race, which is now closed), and M3-full (encrypt whole backup).
