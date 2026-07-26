# Basic Mode — client design (Model A: Simplified Shell)

Status: DESIGN, 2026-07-26. Groundwork exists (`LunaProfile.uiBasic` HiveField
52, set from `ui.basic` on `/self/services`); today it only hides the Settings
gear + profile switcher in the drawer header (`drawer_header.dart`). This spec
turns that stub into a coherent, SAFE Basic experience.

## Principle
Basic is a **server-tagged, UX-only** simplification of the SAME app — never a
capability gate on access (the server's badges already decide access). A Basic
person uses their granted modules fully; what's removed is the **configuration
and multi-profile machinery** they neither own nor need, plus a guaranteed way
OUT. Basic is resolved server-side per person (`ui.basic`), so the server can
turn it on/off without a client release.

## What Basic changes (and what it must NOT)

### Kept — full use of granted modules
- All granted modules appear and work normally (browse, search, request,
  play/authorize, notifications inbox). Basic ≠ fewer features inside a module.
- The drawer stays (Model A): a Basic person with 3 services still switches
  between them. Degrades gracefully at 1 or N modules — no special-casing.

### Hidden / gated — the config + multi-profile surfaces
1. **Settings — genuinely locked, not just hidden.** Today only the gear button
   is hidden; the route is still reachable via deep link / other nav. Add a
   **router redirect guard**: any `settings/*` route resolves to the home route
   when `LunaProfile.current.uiHidesSettings`. (Anchor: `LunaRoutes`/`routes.dart`
   `redirect()` hook.) The gear stays hidden as today.
2. **Profile switcher + Add/Delete/Rename Profile** — hidden (switcher already
   is). Basic implies a single server-owned profile; the whole profiles surface
   is inside Settings, so gating Settings covers it — but ALSO suppress any
   deep-linked profile routes via the same guard.
3. **Manual connection editors / Pro upsell / "Add Profile → Pro" dialog** —
   unreachable for Basic (they live under Settings/Configuration → covered by
   the guard). No Pro nagging for a Basic user.
4. **Per-module Configuration pages** — already absent for server-managed
   modules; the guard removes the rest.

### Added — the escape hatch (REQUIRED before Basic ships)
A Basic person currently has **no way out** — no Settings, no switcher, no
"leave". That traps them on a server (user-hostile + App Review 4.2 risk). Add a
**Leave Server** action reachable WITHOUT Settings:
- Placement: an item in the drawer header's menu (the one surface Basic keeps),
  or a small overflow on the drawer header. Always visible in Basic.
- Copy: "Leave <ServerName>" with a confirm ("You'll disconnect from
  <ServerName> and its services. You can rejoin with a new invite.").

## Leave Server flow (the load-bearing new piece)
The active profile for a Basic user is ALWAYS the server-owned one, and
`LunaProfileTools.remove()` refuses to delete the active profile. So add a
dedicated `LunaProfileTools.leaveServer()`:

1. Capture the current (server-owned) profile + its `tailscaleIdentity`.
2. Ensure a destination profile exists to switch to:
   - If another non-server profile exists → switch to it.
   - Else create a pristine `default` (the first-run empty state target) and
     switch to it.
3. `_changeTo(destination)` — this already debounces the node reconfigure
   (2026-07-26 fix) and re-mirrors notifications.
4. Now the server-owned profile is non-active → `_remove(serverProfile)` deletes
   it + `forgetTailscaleNode(identity)` (best-effort) so the tailnet node state
   is cleaned.
5. Clear that profile's per-profile notification/inbox/push slice (reuse the
   name-keyed cleanup already used on delete/rename).
6. Land on the **first-run landing** (Join invite / Try demo / Unlock Pro — see
   the Pro backlog first-run empty-state item) since the user now has only a
   pristine profile.

Edge: if the server later re-grants (a new invite), the normal join path
recreates a server-owned profile — leaving is fully reversible.

## Client ⇄ server contract
Keep `ui.basic` as the single boolean the server sets per person (already live,
v0.27.0+). Resolve client behavior through the existing indirection so the
server can reshape Basic later WITHOUT a client release:

- `uiHidesSettings` (currently `=> uiBasic`) — drives the Settings route guard +
  gear.
- `uiShowsDrawer` (currently `=> !uiBasic`, UNUSED) — Model A keeps the drawer,
  so leave it TRUE for Basic for now; wire it later ONLY if we add the Model B
  (kiosk) opt-in.
- Reserve, but don't build yet, the server overrides floated earlier
  (`ui.{hide_settings, landing, show_drawer}`). Model A needs none of them; note
  them in the contract doc so the shape is stable. `landing`/`show_drawer` are
  the Model B (single-purpose) knobs — add when/if a server opts a person in.

Net: Model A ships on `ui.basic` alone. No server change required beyond what's
already live.

## Implementation plan (files)
- `lib/router/routes.dart` (or the settings route group) — add the redirect
  guard: `settings/*` → home when `uiHidesSettings`. Single choke point.
- `lib/utils/profile_tools.dart` — new `leaveServer()` (switch-away → remove →
  forget node → clean notif slice → land on first-run).
- `lib/widgets/ui/drawer/drawer_header.dart` — add the always-visible
  **Leave Server** affordance in Basic (menu/overflow); keep the existing
  gear/switcher hiding.
- First-run landing (Pro backlog item) — Leave Server lands here; if it isn't
  built yet, land on DASHBOARD with an empty state as an interim.
- No `modules.dart`/module-screen changes — Basic reuses every module as-is.

## Edge cases
- **Basic person with 0 granted modules** — they still get a valid control-only
  handout (subscribed for the first-grant nudge); drawer shows just Dashboard.
  Leave Server is their only meaningful action. Fine.
- **Basic toggled OFF server-side** — next `/self/services` sets `uiBasic=false`;
  Settings/switcher return automatically. No migration.
- **Deep links into settings while Basic** — the guard catches them (that's why
  it must be route-level, not button-level).
- **Leave Server mid-node-churn** — the debounced sync + best-effort
  `forgetTailscaleNode` already tolerate this; the destination switch drives the
  node to the new (or off) identity.

## Testing
- Unit: `leaveServer()` on a synthetic server-owned active profile → destination
  created/switched, server profile removed, identity forget attempted, notif
  slice cleared. (Pure-ish, mirrors existing profile_tools tests.)
- Widget: drawer header in Basic shows Leave Server + hides gear/switcher;
  Settings route guard redirects home when `uiHidesSettings`.
- Manual/device: a Basic-tagged person lands in a usable shell, can use modules,
  cannot reach Settings by any path, and can Leave Server back to first-run.

## Out of scope (future)
- Model B (kiosk / drawerless / land-in-module) as a per-person server opt-in
  via `ui.landing` + `ui.show_drawer`. Model A is the default; B is additive.
