import 'package:lunasea/database/models/profile.dart';

/// The bundled, read-only **demo mode**: a throwaway `Demo` profile whose
/// modules are configured against the [host] sentinel and served entirely from
/// on-device fixtures by `DemoAdapter` — no backend, no tailnet, offline and
/// instant. Entered from the first-run landing ("Start Demo Mode") and always
/// exitable via the persistent Demo banner.
///
/// Content is deliberately Blender open-movie titles (Big Buck Bunny, Sintel,
/// …) so the preview is obviously "not your library" and 100% license-clean.
class DemoMode {
  DemoMode._();

  /// Name-locked profile key (hidden from the switcher / rename / delete, like
  /// a server-owned profile).
  static const String profileName = 'Demo';

  /// Sentinel base URL every demo module points at; `DemoAdapter` intercepts
  /// any request to it and answers from `assets/demo/`.
  static const String host = 'https://demo.tailarr';

  /// True while the active profile is the demo profile.
  static bool get active => LunaProfile.current.demo;

  /// The demo profile: every showcase module enabled + gateway-managed (so the
  /// screens render server-driven-shaped, no manual editors) against [host].
  /// Sonarr + Radarr + Tautulli are the visual, screenshot-worthy modules.
  static LunaProfile build() => LunaProfile(
        demo: true,
        gatewayManagedModules: const ['sonarr', 'radarr', 'tautulli'],
        sonarrEnabled: true,
        sonarrHost: host,
        sonarrKey: 'demo',
        radarrEnabled: true,
        radarrHost: host,
        radarrKey: 'demo',
        tautulliEnabled: true,
        tautulliHost: host,
        tautulliKey: 'demo',
      );
}
