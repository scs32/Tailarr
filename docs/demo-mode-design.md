# Demo Mode — Design (2026-07-25)

**Status:** design only, not built.

**Why:** the product direction is **non-server = Pro** — the free tier is
server-driven only (join a Tailarr Server via invite), and *any* manual /
BYO-service configuration is a paid Pro feature. That leaves a serverless
first-timer (and, critically, an App Review reviewer) with no self-serve
function on first open, which risks an **App Store Guideline 4.2 (minimum
functionality)** rejection: an app that appears to do nothing without an
account/server.

**The resolution:** a bundled, read-only **demo mode** — not a demo *server*.
If the demo data is canned anyway, hosting a server to serve canned data is
pure overhead (a box to keep alive, a Funnel to maintain, a thing that fails a
review at 2am when it's down). Ship the sample data *inside the app*. It works
offline, instantly, every time; clears 4.2 (the app is fully functional on
open); is honest (obviously a preview, not a real library); and adds no
infrastructure. It also softens the serverless first-run wall for *every*
curious user, not just the reviewer — which is its real product value.

This keeps the monetization line intact: **Free = talk to a Tailarr Server
(yours via invite, or the in-app demo). Pro = point the app at services
yourself, no server.** The demo is server-driven-shaped, so it doesn't dilute
"non-server is Pro."

---

## 1. Entry model — a throwaway "demo profile," not a global flag

Reuse the per-profile machinery. A demo profile makes every module render as
**configured/enabled** (server-driven-shaped — no manual editors), consistent
with the free-tier model.

```dart
// LunaProfile: new HiveField 53
@HiveField(53, defaultValue: false)
bool demo;   // like serverOwned: name-locked, hidden from switcher/rename/
             // delete, never counts toward Pro gating
```

```dart
class DemoMode {
  static const profileName = 'Demo';
  static const host = 'https://demo.tailarr';   // sentinel the adapter intercepts

  static bool get active => LunaProfile.current.demo;

  static Future<void> enter() async {
    await LunaBox.profiles.update(profileName, LunaProfile(
      demo: true,
      // gateway-managed → screens show "Server Managed" (locked, browsable)
      gatewayManagedModules: ['sonarr', 'radarr', 'sabnzbd', 'tautulli'],
      sonarrEnabled: true,   sonarrHost: host,   sonarrKey: 'demo',
      radarrEnabled: true,   radarrHost: host,   radarrKey: 'demo',
      sabnzbdEnabled: true,  sabnzbdHost: host,  sabnzbdKey: 'demo',
      tautulliEnabled: true, tautulliHost: host, tautulliKey: 'demo',
    ));
    LunaProfileTools().changeTo(profileName, showSnackbar: false);
  }

  static Future<void> leave() async {
    // switch back to a real profile (or the empty landing), then delete Demo.
  }
}
```

## 2. The data — bundled fixtures, shaped exactly like the real API

Ship JSON under `assets/demo/` (add to `pubspec.yaml`). Use **Blender open
movies** as content: real, license-clean, and unmistakably "not your library,"
which keeps the demo honest.

`assets/demo/sonarr/series.json` (Sonarr v3 `/api/v3/series`):
```json
[
  {"id":1,"title":"Sintel","status":"ended","seasonCount":1,"network":"Blender",
   "monitored":true,"year":2010,
   "statistics":{"episodeFileCount":12,"episodeCount":12,"sizeOnDisk":48210000000,"percentOfEpisodes":100.0},
   "images":[{"coverType":"poster","remoteUrl":"asset:sintel_poster"}]},
  {"id":2,"title":"Tears of Steel","status":"continuing","seasonCount":2,"network":"Blender",
   "monitored":true,"year":2012,
   "statistics":{"episodeFileCount":18,"episodeCount":24,"sizeOnDisk":72000000000,"percentOfEpisodes":75.0},
   "images":[{"coverType":"poster","remoteUrl":"asset:tos_poster"}]}
]
```

`assets/demo/radarr/movies.json` (Radarr v3 `/api/v3/movie`):
```json
[
  {"id":1,"title":"Big Buck Bunny","year":2008,"hasFile":true,"monitored":true,"runtime":10,
   "sizeOnDisk":1400000000,"images":[{"coverType":"poster","remoteUrl":"asset:bbb_poster"}]},
  {"id":2,"title":"Elephants Dream","year":2006,"hasFile":false,"monitored":true,"runtime":11,
   "images":[{"coverType":"poster","remoteUrl":"asset:ed_poster"}]}
]
```

Plus the small ones the dashboards call on load: `system/status.json`,
`queue.json` (a couple of "downloading" items with progress so the queue looks
alive), `history.json`, `sabnzbd/queue.json`, `tautulli/activity.json` (one or
two "now playing" sessions). Posters ship as small bundled images referenced by
an `asset:` sentinel so nothing hits the network.

## 3. The plumbing — one adapter, swapped in when demo is active

Reuse the per-module Dio hook point already present in every `XxxAPI` factory
(added alongside `attachTailscaleConnectRetry(dio)` in `a6560b6f`). One extra
line per factory:

```dart
// in each XxxAPI factory, right after Dio is built:
if (DemoMode.active) dio.httpClientAdapter = DemoAdapter();
attachTailscaleConnectRetry(dio);
```

```dart
class DemoAdapter implements HttpClientAdapter {
  static const _routes = {
    '/api/v3/series':        'assets/demo/sonarr/series.json',
    '/api/v3/movie':         'assets/demo/radarr/movies.json',
    '/api/v3/queue':         'assets/demo/sonarr/queue.json',
    '/api/v3/system/status': 'assets/demo/sonarr/status.json',
    // ...tautulli, sabnzbd
  };

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? _, Future? __) async {
    final asset = _routes.entries.firstWhere(
      (e) => o.path.contains(e.key), orElse: () => const MapEntry('', '')).value;
    final body = asset.isEmpty ? '[]' : await rootBundle.loadString(asset);
    return ResponseBody.fromString(body, 200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}
```

No module screen changes — the existing state / `FutureBuilder` chain renders
the fixtures unmodified. This is the exact fake-adapter pattern already proven
in `test/tailscale_retry_test.dart`.

## 4. The toggle (UI)

- **First-run / empty landing** (the serverless one): `Join with invite`
  (primary) · **`Try the demo`** → `DemoMode.enter()` → Dashboard ·
  `Unlock Pro` (manual, later).
- A persistent **"Demo — Exit" banner** while active — never mistaken for real
  data, and always a way out (same "don't trap the user" rule as the Basic
  shell's Leave Server).
- Demo profile is **name-locked and hidden** from the switcher / rename /
  delete — reuse the `serverOwned` guards, keyed on `demo`.
- Keep `Try the demo` reachable from **Settings too**, so it's always available
  for marketing screenshots, not just at first run.

## Why this shape

- **Zero hosting** — nothing to keep alive, nothing to fail a review.
- **Offline & instant** — reviewer always sees a working app; 4.2 cleared.
- **Honest** — Blender titles + an ever-present "Demo" banner; a preview, not a
  fake server.
- **Tiny diff** — 1 adapter, 1 `DemoMode` helper, 1 `demo` field + its guards,
  6 one-line factory hooks, a fixture folder. No module-screen changes.
- **Read-only by nature** — writes (add/delete/search) just return the canned
  state, so nothing pretends to act. The adapter can grow later if genuine
  interactivity is ever wanted, but it isn't needed for review or marketing.

## Open choices (when building)

1. **Which modules to populate** — recommend **Sonarr + Radarr + Tautulli**
   (the visual, screenshot-worthy ones); keep the download clients minimal.
2. **First manual connection: hard-gated vs. free trial** — hard-gated is
   cleaner for "non-server is Pro"; a trial softens conversion but muddies the
   line. (This is the paired Pro-gate decision, tracked with the non-server=Pro
   backlog item.)

## Dependencies / relationship to other backlog items

- Pairs with **non-server = Pro**: demo mode is what makes fully gating manual
  config reviewable. Without it, gating manual = a functionless first run = 4.2
  risk.
- Reuses the per-module Dio hook from the cold-load retry fix (`a6560b6f`).
- The empty-state landing (`Join / Try demo / Unlock Pro`) is shared with the
  Pro-gate work.
