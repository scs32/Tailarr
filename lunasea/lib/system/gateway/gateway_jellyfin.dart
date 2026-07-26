/// Jellyfin self-service availability via the tailarr-gate node (server
/// release 2+): the same whois-authenticated gateway as /self/services and
/// /self/notifications answers "does this device's person have a Jellyfin
/// account". A person granted the Jellyfin badge gets their OWN provisioned,
/// library-scoped, passwordless Jellyfin user — the app never sees the admin
/// token.
///
/// This probe keeps the persisted [LunaProfile.jellyfinEnabled] flag honest so
/// the module list can decide visibility synchronously: a granted badge lights
/// the module up on the next foreground; a revoked badge (or an old server)
/// hides it. It never flips the flag on a transport error — a briefly-down
/// embedded node must not hide a working module.
library gateway_jellyfin;

import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/system/gateway/gateway_host.dart';
import 'package:lunasea/system/logger.dart';

class GatewayJellyfinSync {
  GatewayJellyfinSync._();

  /// In-process failure throttle for the opportunistic path — a dead gateway
  /// must not add a dial timeout to every foreground.
  static DateTime? _lastAttempt;
  static const _REFRESH_INTERVAL = Duration(minutes: 15);

  /// Probe the gateway and reconcile [LunaProfile.jellyfinEnabled]/
  /// [LunaProfile.jellyfinUrl] on the current profile. Runs only on
  /// server-attached profiles (invite-joined or with a Tailarr Server
  /// configured), throttled, and silent on failure — the stored state keeps
  /// working. Returns the resolved availability.
  static Future<void> refresh() async {
    final profile = LunaProfile.current;
    final hasServer = profile.serverOwned ||
        (profile.tailarrServerEnabled && profile.tailarrServerHost.isNotEmpty);
    // A device that already believes it has Jellyfin must keep re-probing so a
    // revocation is picked up even if the server module was later disabled.
    if (!hasServer && !profile.jellyfinEnabled) return;

    final last = _lastAttempt;
    if (last != null && DateTime.now().difference(last) < _REFRESH_INTERVAL) {
      return;
    }
    _lastAttempt = DateTime.now();

    try {
      final self = await (await gatewayClient()).selfJellyfin();
      LunaLogger().debug(
        'gateway jellyfin → HTTP ${self.statusCode} ok=${self.ok} '
        'error=${self.error} url=${self.url.isEmpty ? '(stopped)' : 'set'} '
        'libraries=${self.libraries.length}',
      );

      final current = LunaProfile.current;
      final wasEnabled = current.jellyfinEnabled;
      current.jellyfinEnabled = self.isAvailable;
      // Empty url = pod stopped: keep the last known value.
      if (self.isAvailable && self.url.isNotEmpty) {
        current.jellyfinUrl = self.url;
      }
      if (current.jellyfinEnabled != wasEnabled ||
          (self.isAvailable && self.url.isNotEmpty)) {
        if (current.isInBox) current.save();
      }
    } catch (_) {
      // Gateway unreachable — keep the stored state.
    }
  }
}
