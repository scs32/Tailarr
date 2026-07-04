# Tailarr Branding Kit

This folder is a design handoff for rebranding the app from **LunaSea** to **Tailarr**.

**The deliverable:** a `replacements/` folder mirroring `originals/` exactly — same
filenames, same pixel dimensions, same format, same alpha characteristics — so every
file drops into place with zero code changes. Everything else (60+ platform icon
sizes, splash screens, favicons) is *generated* from these masters by tooling.

## About the app

Tailarr is a self-hosted media-stack controller (Sonarr, Radarr, etc.) whose defining
feature is built-in Tailscale mesh networking. The name is Tailscale + the "-arr"
suffix of the apps it controls. Branding directions that nod to either are welcome
(mesh/network motifs, a tail, the *arr fleet) but not required. The current app theme
is dark; the established background color is `#32323E` (keep it unless you propose a
full palette swap — it is referenced in build config).

## Files to replace — `originals/masters/` (7 files, the real work)

| File | Size | Alpha | Used for | Constraints |
|---|---|---|---|---|
| `icon.png` | 1024×1024 | **no** | iOS/Android app icon master — every home-screen icon size is generated from this | Full-bleed square, NO transparency (iOS rejects alpha), no rounded corners (OS applies masking) |
| `icon_adaptive.png` | 1024×1024 | yes | Android adaptive icon **foreground** layer, composited over `#32323E` | Keep all critical content inside the central ~66% safe zone; edges get cropped by launcher masks |
| `icon_linux.png` | 1024×1024 | yes | Linux desktop icon | Transparent background OK |
| `icon_web.png` | 512×512 | yes | PWA / web app icon | Transparent background OK |
| `icon_windows.png` | 1024×1024 | yes | Windows / MSIX logo | Transparent background OK |
| `branding_full.png` | 685×500 | yes | **Splash screen** image (centered on `#32323E`) and in-app hero — currently the logo mark + "LunaSea" wordmark | Must read well on `#32323E`; contains the wordmark, so this is where "Tailarr" must appear |
| `branding_logo.png` | 1432×744 | yes | In-app full logo/wordmark (about screens etc.) | Same layout role: mark + wordmark lockup |

## Files to replace — `originals/platform-manual/` (2 files, derivable)

| File | Size | Used for | Note |
|---|---|---|---|
| `macos_icon_1024.png` | 1024×1024 | macOS app icon master | Can simply be `icon.png` re-styled per macOS convention (rounded-rect on transparent, ~10% padding); smaller sizes are generated |
| `app_icon.ico` | multi-size ICO | Windows runner icon | Mechanical conversion from `icon_windows.png`; the developer can generate it — a replacement is optional |

## Rules

1. **Exact filename, dimensions, format, and alpha for every file.** A file that
   doesn't match is a file that can't drop in.
2. One coherent identity across all files — same mark everywhere, wordmark set in the
   same face in both `branding_*.png` files.
3. No "LunaSea" text or moon iconography may survive in any delivered file.
4. Vector sources (SVG/Figma) for the mark and wordmark are appreciated alongside the
   PNGs — they'll be needed for future marketing assets — but the PNGs are the
   contract.

## What happens after delivery (developer reference, not designer work)

```bash
# from lunasea/ after dropping replacements into assets/icon + assets/images
dart run flutter_launcher_icons          # regenerates all iOS/Android icon sizes
dart run flutter_native_splash:create    # regenerates all splash screens
# macOS iconset fanout from masters/platform-manual replacement:
#   sips -z <s> <s> macos_icon_1024.png --out icon_<s>.png  (16..1024)
# web favicons: sips fanout from icon_web.png; .ico via iconutil/imagemagick
```

Not in scope for design: `assets/LunaBrandIcons.ttf` (glyph font of *third-party*
service logos — Sonarr, Radarr, etc. — contains no LunaSea branding) and the
`assets/images/brands/` SVGs (also third-party marks).
