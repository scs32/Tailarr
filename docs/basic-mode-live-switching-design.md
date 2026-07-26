# Basic Mode — live server-driven switching (design)

Status: DESIGN, 2026-07-26. Follow-up to `basic-mode-design.md` (Model A, shipped
`67affc2b`). This covers making a server-driven **basic ↔ regular** flip reshape
the app **live**, not on the next navigation/foreground.

## Problem
`ui.basic` is server-owned and already flows to the client end-to-end:

1. Admin flips `ui.basic` on a person.
2. Server publishes a config-changed signal (`op_person basic → changed:
   [services, ui]`) on `tlr-ctrl-<uid>`.
3. Client receives it, `GatewayServicesSync.refresh(force: true)` → `sync()` runs
   `profile.uiBasic = response.ui.basic; profile.save();`.

So the **data path is done and automatic, both directions.** The gap is
**rendering**: nothing reshapes the shell when `uiBasic` changes on the SAME
active profile.

- The Basic-dependent UI (`drawer_header.dart`) rebuilds off
  `LunaSeaDatabase.ENABLED_PROFILE.listenableBuilder`, which fires on a profile
  **switch/rename** — NOT on the current profile's field save. `profile.save()`
  notifies the *profiles* box, which the header doesn't watch. → the
  gear ↔ Leave-Server swap lags until the next switch/foreground.
- The Settings route guard (`basicBlocksSettingsRoute` in `router.dart`)
  evaluates per-navigation, so a user sitting IN Settings when basic turns ON is
  not ejected until they next navigate.

## Severity (why this is polish, not a hole)
Mobile re-syncs on every foreground and phones foreground constantly, so in
practice a flip lands within seconds of the next interaction even without this
work. The purely-cosmetic case (header not updating while the app sits open in
the foreground) is real but rare (admin flipping a tier during an active
session); the "stuck in Settings when demoted" case is rarer still. So: smoothness,
not correctness.

## Design — drive the reaction from the config-changed handler
Do NOT make the Basic surfaces subscribe to `LunaBox.profiles.listenableBuilder`:
gateway sync saves the profile constantly, so the header would rebuild on every
save — needless churn. Instead, react from the ONE place that already knows a
real change happened.

1. **Detect the flip.** In the config-changed force-sync path (or in
   `GatewayServicesSync.sync()` where `uiBasic` is assigned), capture the old
   value and compare: `final changed = wasBasic != profile.uiBasic;`.
2. **Signal the shell.** Add a tiny dedicated notifier the Basic surfaces watch —
   e.g. `LunaProfile.uiRevision` (`ValueNotifier<int>`), bumped only when a
   `ui.*` field actually changes. `drawer_header.dart` wraps its builder to also
   rebuild on that notifier (cheap: fires only on a genuine flip, not every
   save). This is the minimal, targeted alternative to the noisy profiles-box
   listenable.
3. **Eject from Settings if it just became Basic.** If `changed && profile.
   uiBasic` and the current location is under `/settings`, `router.go(home)` so
   an open Settings screen closes itself. (Uses the same `basicBlocksSettingsRoute`
   predicate, evaluated once on the flip.)

Net: on a real flip the shell reshapes immediately; on the (frequent) no-op
saves nothing rebuilds.

## Implementation sketch (files)
- `lib/database/models/profile.dart` — `static final ValueNotifier<int>
  uiRevision` (or a small `LunaProfileUi` notifier). Bumped from the sync path.
- `lib/system/gateway/gateway_services.dart` — in `sync()`, compare old/new
  `uiBasic` (and any future `ui.*`); on change, bump `uiRevision`.
- `lib/system/notifications/platform/ntfy_io.dart` — the config-resync callback
  already force-refreshes; after it, if the flip turned Basic ON and we're in
  `/settings`, redirect home. (Or centralize this eject in the same place that
  bumps `uiRevision`.)
- `lib/widgets/ui/drawer/drawer_header.dart` — also rebuild on `uiRevision`
  (wrap/merge with the existing `ENABLED_PROFILE` builder).

No module-screen changes.

## Sequencing
Do this AFTER device-verifying Basic itself (the shell strips correctly, Settings
is unreachable by any path, Leave Server returns cleanly). Verification will show
how laggy a live flip actually feels — if the foreground re-sync already masks it,
this may not be worth building. Implement the clean (config-handler-driven)
version only if the lag is noticeable.

## Testing
- Unit: the flip-detection predicate (old != new `uiBasic` → bump) and the
  eject-if-now-basic decision (reuse `basicBlocksSettingsRoute`).
- Widget: drawer header rebuilds gear ↔ Leave-Server when `uiRevision` bumps.
- Device: with a test person, flip `ui.basic` server-side while the app is
  foregrounded and open on the drawer → the shell reshapes within the push
  latency (~seconds) without a manual navigation.
