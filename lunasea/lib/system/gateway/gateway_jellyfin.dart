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

import 'package:flutter/foundation.dart';
import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/system/gateway/gateway_host.dart';
import 'package:lunasea/system/logger.dart';

class GatewayJellyfinSync {
  GatewayJellyfinSync._();

  /// Last time the gate ANSWERED (any HTTP response) — arms the long throttle.
  static DateTime? _lastReached;

  /// Last time the dial THREW (node not up yet). Only a short cooldown, so a
  /// cold-launch race retries across the connect window. Arming the long
  /// throttle BEFORE the network call (the old behaviour) meant a single
  /// transient failure hid a granted module for up to 15 min.
  static DateTime? _lastFailure;
  static const _REFRESH_INTERVAL = Duration(minutes: 15);
  static const _FAILURE_COOLDOWN = Duration(seconds: 30);

  @visibleForTesting
  static void resetThrottle() {
    _lastReached = null;
    _lastFailure = null;
  }

  /// Probe the gateway and reconcile [LunaProfile.jellyfinEnabled]/
  /// [LunaProfile.jellyfinUrl] on the current profile. Runs only on
  /// server-attached profiles (invite-joined or with a Tailarr Server
  /// configured), throttled, and silent on failure — the stored state keeps
  /// working. Returns the resolved availability.
  /// [force] bypasses the throttle for a server-pushed config-changed signal.
  static Future<void> refresh({bool force = false}) async {
    final profile = LunaProfile.current;
    final hasServer = profile.serverOwned ||
        (profile.tailarrServerEnabled && profile.tailarrServerHost.isNotEmpty);
    // A device that already believes it has Jellyfin must keep re-probing so a
    // revocation is picked up even if the server module was later disabled.
    if (!hasServer && !profile.jellyfinEnabled) return;

    if (!force &&
        gatewaySyncThrottled(
          lastReached: _lastReached,
          lastFailure: _lastFailure,
          now: DateTime.now(),
          reached: _REFRESH_INTERVAL,
          cooled: _FAILURE_COOLDOWN,
        )) {
      return;
    }

    try {
      final self = await (await gatewayClient()).selfJellyfin();
      // Reached the gate — arm the long throttle only now, not before the call.
      _lastReached = DateTime.now();
      LunaLogger().debug(
        'gateway jellyfin → HTTP ${self.statusCode} ok=${self.ok} '
        'error=${self.error} url=${self.url.isEmpty ? '(stopped)' : 'set'} '
        'libraries=${self.libraries.length}',
      );

      final current = LunaProfile.current;
      final wasEnabled = current.jellyfinEnabled;

      // Mutate availability only on an AUTHORITATIVE outcome. The gateway
      // parses every <500 response into an envelope, so a bare `ok:false` is
      // NOT proof the module is gone — a transient 4xx, an unassigned-device
      // whois race, or a malformed body would otherwise disable a working
      // module. Enable on ok; disable only on a definite "no such module"
      // (old server / endpoint gone) or a definite "no Jellyfin badge";
      // preserve the stored state on everything else (unassigned / generic
      // refusal / malformed). See docs/security-audit-2026-07-28.md (M2).
      bool? authoritative;
      if (self.isAvailable) {
        authoritative = true;
      } else if (self.isUnavailable || self.hasNoAccess) {
        authoritative = false;
      }
      if (authoritative != null) current.jellyfinEnabled = authoritative;

      // Empty url = pod stopped: keep the last known value.
      if (self.isAvailable && self.url.isNotEmpty) {
        current.jellyfinUrl = self.url;
      }
      if (current.jellyfinEnabled != wasEnabled ||
          (self.isAvailable && self.url.isNotEmpty)) {
        if (current.isInBox) current.save();
      }
    } catch (_) {
      // Node not up yet — short cooldown, not the long throttle, so a
      // cold-launch race recovers on the next trigger.
      _lastFailure = DateTime.now();
    }
  }
}
