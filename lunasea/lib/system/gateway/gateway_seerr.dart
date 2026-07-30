/// Request-portal (Seerr) availability via the tailarr-gate node: the same
/// whois-authenticated gateway as /self/services and /self/jellyfin answers
/// "does this device's person have a request portal". A person granted the
/// `seerr` badge gets a per-person-provisioned portal account they reach
/// password-free through the app-brokered sign-in — the app never sees the
/// Jellyfin password or a Seerr admin key.
///
/// This probe uses the READ-ONLY `self/seerr` status op (mints no Seerr
/// session) purely to keep [LunaProfile.seerrEnabled] honest so the module list
/// can decide visibility synchronously: a granted badge lights the Requests
/// module up on the next foreground; a revoked badge (or a server that hasn't
/// deployed the seerr gate routes yet) hides it. It NEVER flips the flag on a
/// transport error — a briefly-down embedded node must not hide a working
/// module. Mirrors [GatewayJellyfinSync] exactly.
library gateway_seerr;

import 'package:flutter/foundation.dart';
import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/system/gateway/gateway_host.dart';
import 'package:lunasea/system/logger.dart';

class GatewaySeerrSync {
  GatewaySeerrSync._();

  /// Last time the gate ANSWERED (any HTTP response) — arms the long throttle.
  static DateTime? _lastReached;

  /// Last time the dial THREW (node not up yet). Only a short cooldown, so a
  /// cold-launch race retries across the connect window.
  static DateTime? _lastFailure;
  static const _REFRESH_INTERVAL = Duration(minutes: 15);
  static const _FAILURE_COOLDOWN = Duration(seconds: 30);

  @visibleForTesting
  static void resetThrottle() {
    _lastReached = null;
    _lastFailure = null;
  }

  /// Probe the gateway and reconcile [LunaProfile.seerrEnabled]/
  /// [LunaProfile.seerrUrl] on the current profile. Runs only on
  /// server-attached profiles (invite-joined or with a Tailarr Server
  /// configured), throttled, and silent on failure — the stored state keeps
  /// working. [force] bypasses the throttle for a server-pushed config-changed
  /// signal.
  static Future<void> refresh({bool force = false}) async {
    final profile = LunaProfile.current;
    final hasServer = profile.serverOwned ||
        (profile.tailarrServerEnabled && profile.tailarrServerHost.isNotEmpty);
    // A device that already believes it has a portal must keep re-probing so a
    // revocation is picked up even if the server module was later disabled.
    if (!hasServer && !profile.seerrEnabled) return;

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
      final self = await (await gatewayClient()).selfSeerr();
      // Reached the gate — arm the long throttle only now, not before the call.
      _lastReached = DateTime.now();
      LunaLogger().debug(
        'gateway seerr → HTTP ${self.statusCode} ok=${self.ok} '
        'error=${self.error} url=${self.url.isEmpty ? '(stopped)' : 'set'}',
      );

      final current = LunaProfile.current;
      final wasEnabled = current.seerrEnabled;

      // Mutate availability only on an AUTHORITATIVE outcome (same discipline as
      // GatewayJellyfinSync): enable on ok; disable only on a definite "no such
      // module" (server without the seerr routes) or a definite "no request-
      // portal access"; preserve the stored state on everything else
      // (unassigned / transient / malformed / not-ready).
      bool? authoritative;
      if (self.isAvailable) {
        authoritative = true;
      } else if (self.isUnavailable || self.hasNoAccess) {
        authoritative = false;
      }
      if (authoritative != null) current.seerrEnabled = authoritative;

      // Empty url = pod stopped: keep the last known value.
      if (self.isAvailable && self.url.isNotEmpty) {
        current.seerrUrl = self.url;
      }
      if (current.seerrEnabled != wasEnabled ||
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
