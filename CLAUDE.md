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

## Tailscale Integration (Work in Progress)

### Current State
The Tailscale integration is **incomplete** - the code exists but tsnet fails on iOS with "cannot find executable path" error.

### Architecture
- **Go code** (`lunasea/Go/main.go`) - HTTP proxy server using tsnet
- **Swift bridge** (`ios/Runner/AppDelegate.swift`) - MethodChannel for start/stop/isRunning
- **Dart layer** (`lib/system/network/platform/network_io.dart`) - Uses `findProxy` to route `.ts.net` traffic
- **UI** - Toggle in Settings > General > Network with auth key popup dialog

### Known Issue
tsnet calls `os.Executable()` internally which fails on iOS. This is a fundamental limitation - tsnet was designed for server/desktop environments, not mobile. Attempted workarounds that did NOT work:
- Setting `TS_SELF_EXECUTABLE` environment variable
- Setting `HOME` and `TS_LOGS_DIR` environment variables
- Using in-memory store
- Upgrading tailscale versions

### Alternatives
1. Users can install the official Tailscale iOS app and enable system-wide VPN - LunaSea requests would route through it automatically
2. Wait for Tailscale to release an official iOS SDK (GitHub issue #7240)

### Build Commands for Go/xcframework
```bash
cd lunasea/Go
go mod tidy
export PATH="$PATH:$(go env GOPATH)/bin"
gomobile bind -target ios -o GoLunaSea.xcframework .
cp -R GoLunaSea.xcframework ../ios/
cd ../ios && pod install
```

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
