# <img width="52px" src="./branding/replacements/icon_web.png" alt="Tailarr"></img>&nbsp;&nbsp;Tailarr

**The \*arr fleet, running on your tailnet.** One controller for Sonarr, Radarr,
Lidarr, SABnzbd, NZBGet and Tautulli — reachable anywhere, exposed nowhere.

<p align="center">
  <img src="./branding/replacements/branding_logo.png" alt="Tailarr" width="480">
</p>

Tailarr is a fork of the archived [LunaSea](https://github.com/JagandeepBrar/LunaSea)
project with one defining addition: **an embedded Tailscale node inside the app**.

## Tailscale integration

Tailarr embeds [tsnet](https://tailscale.com/kb/1244/tsnet) (the userspace Tailscale
client) directly in the iOS app via a Go → gomobile xcframework:

- Requests to `*.ts.net` hosts are routed through an in-app HTTP proxy that dials
  peers over your tailnet — **no system-wide VPN profile required**, and the phone's
  VPN slot stays free for anything else.
- The node authenticates **once** with a Tailscale auth key (single-use keys work);
  its identity persists like any other device on your tailnet.
- On every launch and return to foreground, the app verifies the node and its local
  proxy are healthy (iOS reclaims sockets during suspension) and reconnects behind a
  blocking "Connecting to Tailscale…" overlay before any request is sent.
- Toggle lives in **Settings → General → Network → Use Tailscale**.

Architecture: `lunasea/Go/main.go` (tsnet + HTTP CONNECT proxy) →
`GoLunaSea.xcframework` (gomobile) → Swift MethodChannel bridge
(`ios/Runner/AppDelegate.swift`) → Dart `findProxy` routing
(`lib/system/network/platform/network_io.dart`).

> The generated `GoLunaSea.xcframework` is not committed (92MB+ binaries). Rebuild it
> after cloning:
>
> ```bash
> cd lunasea/Go
> go install golang.org/x/mobile/cmd/gomobile@latest
> gomobile bind -target ios -o GoLunaSea.xcframework .
> rm -rf ../ios/GoLunaSea.xcframework && cp -R GoLunaSea.xcframework ../ios/
> (cd ../ios && pod install)
> ```

## Repository layout

| Directory | Contents |
|---|---|
| `lunasea/` | The Flutter application (iOS, Android, macOS, Windows, Linux, Web) |
| `branding/` | Tailarr brand assets — vector sources, drop-in masters, design brief |
| `lunasea-cloud-functions/` | Firebase Cloud Functions (legacy) |
| `lunasea-notification-service/` | Webhook notification service (legacy) |
| `lunasea-docs/` | Documentation (legacy, pre-fork) |

## Building

```bash
cd lunasea
flutter pub get
npm run generate        # code generation (Hive, Retrofit, i18n)
npm run build:ios       # or build:android / build:macos / ...
```

See `CLAUDE.md` for detailed build notes, iOS signing, and Tailscale gotchas.

## Releases

iOS builds ship to TestFlight via GitHub Actions (`.github/workflows/testflight.yml`)
on version tags (`v*`) or manual dispatch, signed with Apple cloud-managed
certificates through an App Store Connect API key.

## License & attribution

Tailarr is licensed under the [GNU GPL v3.0](./lunasea/LICENSE.md), the same license
as LunaSea. It is a modified fork of LunaSea by Jagandeep Brar and contributors; all
LunaSea copyright notices are preserved. The Tailarr name, logo, and branding are
specific to this fork and are not affiliated with LunaSea or with Tailscale Inc.
Tailscale integration is built on [tailscale.com](https://github.com/tailscale/tailscale)
(BSD-3-Clause).
