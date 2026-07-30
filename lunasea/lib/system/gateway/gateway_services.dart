/// Services self-config via the tailarr-gate node (server v0.23.0+): the
/// gateway identifies this device by its tailnet address and returns every
/// service the owner is badged for — Sonarr/Radarr/Lidarr materialize as
/// native modules, the app's own server module configures itself, and
/// everything else becomes an External Module bookmark.
library gateway_services;

import 'package:flutter/foundation.dart';
import 'package:lunasea/api/ntfy/models.dart';
import 'package:lunasea/database/box.dart';
import 'package:lunasea/database/models/external_module.dart';
import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/database/tables/notifications.dart';
import 'package:lunasea/system/gateway/gateway_host.dart';
import 'package:lunasea/system/logger.dart';
import 'package:lunasea/utils/profile_tools.dart';

/// What one reconcile pass actually changed — feeds the setup snackbar.
class GatewayServicesResult {
  /// Native module types that were configured or refreshed.
  final List<String> configured;

  /// Managed native types whose badge was revoked — disabled, not deleted.
  final List<String> disabled;

  /// External bookmark names that were created or refreshed.
  final List<String> bookmarked;

  /// Native services configured without a credential (auth was null) — the
  /// user only has to fill in that one field.
  final List<String> missingAuth;

  const GatewayServicesResult({
    this.configured = const [],
    this.disabled = const [],
    this.bookmarked = const [],
    this.missingAuth = const [],
  });

  bool get isEmpty =>
      configured.isEmpty && disabled.isEmpty && bookmarked.isEmpty;
}

/// The gateway response paired with what was applied — null [result] means
/// the payload was not consumed (refusal, or server too old).
class GatewayServicesOutcome {
  final GatewayServicesResponse response;
  final GatewayServicesResult? result;

  const GatewayServicesOutcome({required this.response, this.result});
}

/// Pure reconciliation — mutates the given profile/bookmarks in place and
/// reports what changed; persistence stays with the caller so this is
/// directly unit-testable.
class GatewayServicesReconciler {
  GatewayServicesReconciler._();

  /// Native connection modules this app version can materialize (server
  /// v0.24.0 hands out the full set). `overseerr` is deliberately absent —
  /// the app's Overseerr module is feature-flagged off, so those entries
  /// (including Jellyseerr, which shares the type) fall through to external
  /// bookmarks like any unknown type. Nothing shared is ever invisible.
  static const NATIVE_TYPES = [
    'sonarr',
    'radarr',
    'lidarr',
    'sabnzbd',
    'nzbget',
    'tautulli',
    'tailarr',
  ];

  static const REVOKED_SUFFIX = ' (Revoked)';

  static GatewayServicesResult reconcile({
    required LunaProfile profile,
    required List<LunaExternalModule> externalModules,
    required List<GatewayService> services,
    required void Function(LunaExternalModule) createExternal,
    void Function(LunaExternalModule)? deleteExternal,
  }) {
    final managed = Set<String>.of(profile.gatewayManagedModules);
    final seenNative = <String>{};
    final presentNames = <String>{};
    final configured = <String>[];
    final disabled = <String>[];
    final bookmarked = <String>[];
    final missingAuth = <String>[];

    for (final service in services) {
      if (service.name.isEmpty) continue;
      presentNames.add(service.name);

      // First entry of each native type owns the native slot; duplicates
      // and unknown/external types become bookmarks.
      final native =
          NATIVE_TYPES.contains(service.type) && seenNative.add(service.type);
      if (native) {
        // A name that jumped external→native across a server upgrade
        // absorbs its old managed bookmark into the real module.
        externalModules.removeWhere((module) {
          if (module.gatewayName != service.name) return false;
          deleteExternal?.call(module);
          return true;
        });

        // Server-granted services are server-owned, full stop: adopt and
        // lock even a hand-entered config (the server is the source of
        // truth on a suite). Standalone modules the server doesn't grant
        // are never touched — they never reach this branch.

        // Empty url = service stopped: keep the stored value.
        if (service.url.isNotEmpty) {
          // APP-1: a server-driven address change must not silently reuse the
          // admin bearer against a NEW controller identity. A hijacked gateway
          // handing a fresh URL would otherwise receive the real admin token.
          // When the controller's HOST changes (the tailnet MagicDNS name is
          // the stable identity anchor), drop the stored token so the next
          // call re-verifies the server via Quick Connect (the identity-proven
          // pairing handshake) before a token is minted again — matching the
          // existing "dropped on a stale 401 and re-minted" policy.
          if (service.type == 'tailarr' &&
              profile.serverAdminToken.isNotEmpty) {
            final previous = _host(profile, service.type);
            if (previous.isNotEmpty &&
                !_sameServerHost(previous, service.url)) {
              profile.serverAdminToken = '';
            }
          }
          _setHost(profile, service.type, service.url);
        }
        // auth: null = keep the module, keep any stored credential, and
        // flag the gap instead of dropping the entry. NZBGet carries
        // user/password (user may legitimately be empty); the rest carry
        // an api_key.
        if (service.type == 'nzbget') {
          if (service.auth != null) {
            profile.nzbgetUser = service.authUser;
            profile.nzbgetPass = service.authPassword;
          }
        } else if (service.type != 'tailarr' && service.apiKey.isNotEmpty) {
          _setKey(profile, service.type, service.apiKey);
        }
        managed.add(service.type);
        // Only light the module up once it has somewhere to point.
        if (_host(profile, service.type).isNotEmpty) {
          _setEnabled(profile, service.type, true);
          configured.add(service.type);
          final credentialMissing = service.type == 'nzbget'
              ? service.auth == null &&
                  profile.nzbgetUser.isEmpty &&
                  profile.nzbgetPass.isEmpty
              : service.type != 'tailarr' &&
                  _key(profile, service.type).isEmpty;
          if (credentialMissing) missingAuth.add(service.name);
        }
        continue;
      }

      LunaExternalModule? existing;
      for (final module in externalModules) {
        if (module.gatewayName == service.name) {
          existing = module;
          break;
        }
      }
      if (existing != null) {
        if (service.url.isNotEmpty) existing.host = service.url;
        existing.displayName = service.name;
        bookmarked.add(service.name);
      } else if (service.url.isNotEmpty) {
        final module = LunaExternalModule(
          displayName: service.name,
          host: service.url,
          gatewayName: service.name,
        );
        createExternal(module);
        externalModules.add(module);
        bookmarked.add(service.name);
      }
    }

    // Revocations: a managed native type missing from the listing is
    // disabled AND un-managed (host/key kept for reference, but provenance
    // dropped so the connection screen shows "Request Access" rather than a
    // stale managed card; a re-grant re-adopts it). Bookmarks are marked,
    // never silently deleted.
    for (final type in managed.toList()) {
      if (!NATIVE_TYPES.contains(type)) continue;
      if (seenNative.contains(type)) continue;
      if (_enabled(profile, type)) {
        _setEnabled(profile, type, false);
        disabled.add(type);
      }
      managed.remove(type);
    }
    for (final module in externalModules) {
      if (module.gatewayName.isEmpty) continue;
      if (presentNames.contains(module.gatewayName)) continue;
      if (!module.displayName.endsWith(REVOKED_SUFFIX)) {
        module.displayName = '${module.gatewayName}$REVOKED_SUFFIX';
      }
    }

    profile.gatewayManagedModules = managed.toList()..sort();
    return GatewayServicesResult(
      configured: configured,
      disabled: disabled,
      bookmarked: bookmarked,
      missingAuth: missingAuth,
    );
  }

  static String _host(LunaProfile profile, String type) {
    switch (type) {
      case 'sonarr':
        return profile.sonarrHost;
      case 'radarr':
        return profile.radarrHost;
      case 'lidarr':
        return profile.lidarrHost;
      case 'sabnzbd':
        return profile.sabnzbdHost;
      case 'nzbget':
        return profile.nzbgetHost;
      case 'tautulli':
        return profile.tautulliHost;
      case 'tailarr':
        return profile.tailarrServerHost;
    }
    return '';
  }

  /// Whether two controller URLs point at the SAME server identity. The tailnet
  /// MagicDNS host is the stable anchor: a scheme/port/path change on the same
  /// host is the same box, while a different host is a different (possibly
  /// hijacked) controller. Unparseable input is treated as a change (fail safe
  /// — drop the token rather than risk leaking it). Used by APP-1.
  static bool _sameServerHost(String a, String b) {
    final ha = _hostOf(a);
    final hb = _hostOf(b);
    if (ha == null || hb == null) return false;
    return ha == hb;
  }

  /// The lowercased host of [url], tolerating a bare `host` / `host:port` with
  /// no scheme. Null when no host can be resolved.
  static String? _hostOf(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;
    var uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) {
      uri = Uri.tryParse('http://$trimmed');
    }
    final host = uri?.host.toLowerCase();
    return (host == null || host.isEmpty) ? null : host;
  }

  static void _setHost(LunaProfile profile, String type, String host) {
    switch (type) {
      case 'sonarr':
        profile.sonarrHost = host;
        break;
      case 'radarr':
        profile.radarrHost = host;
        break;
      case 'lidarr':
        profile.lidarrHost = host;
        break;
      case 'sabnzbd':
        profile.sabnzbdHost = host;
        break;
      case 'nzbget':
        profile.nzbgetHost = host;
        break;
      case 'tautulli':
        profile.tautulliHost = host;
        break;
      case 'tailarr':
        profile.tailarrServerHost = host;
        break;
    }
  }

  static String _key(LunaProfile profile, String type) {
    switch (type) {
      case 'sonarr':
        return profile.sonarrKey;
      case 'radarr':
        return profile.radarrKey;
      case 'lidarr':
        return profile.lidarrKey;
      case 'sabnzbd':
        return profile.sabnzbdKey;
      case 'tautulli':
        return profile.tautulliKey;
    }
    return '';
  }

  static void _setKey(LunaProfile profile, String type, String key) {
    switch (type) {
      case 'sonarr':
        profile.sonarrKey = key;
        break;
      case 'radarr':
        profile.radarrKey = key;
        break;
      case 'lidarr':
        profile.lidarrKey = key;
        break;
      case 'sabnzbd':
        profile.sabnzbdKey = key;
        break;
      case 'tautulli':
        profile.tautulliKey = key;
        break;
    }
  }

  static bool _enabled(LunaProfile profile, String type) {
    switch (type) {
      case 'sonarr':
        return profile.sonarrEnabled;
      case 'radarr':
        return profile.radarrEnabled;
      case 'lidarr':
        return profile.lidarrEnabled;
      case 'sabnzbd':
        return profile.sabnzbdEnabled;
      case 'nzbget':
        return profile.nzbgetEnabled;
      case 'tautulli':
        return profile.tautulliEnabled;
      case 'tailarr':
        return profile.tailarrServerEnabled;
    }
    return false;
  }

  static void _setEnabled(LunaProfile profile, String type, bool enabled) {
    switch (type) {
      case 'sonarr':
        profile.sonarrEnabled = enabled;
        break;
      case 'radarr':
        profile.radarrEnabled = enabled;
        break;
      case 'lidarr':
        profile.lidarrEnabled = enabled;
        break;
      case 'sabnzbd':
        profile.sabnzbdEnabled = enabled;
        break;
      case 'nzbget':
        profile.nzbgetEnabled = enabled;
        break;
      case 'tautulli':
        profile.tautulliEnabled = enabled;
        break;
      case 'tailarr':
        profile.tailarrServerEnabled = enabled;
        break;
    }
  }
}

/// Orchestration around the reconciler: dial the gateway, apply to the
/// current profile + external-modules box, keep provenance honest.
class GatewayServicesSync {
  GatewayServicesSync._();

  /// Last time the gate actually ANSWERED (any HTTP response) — arms the long
  /// throttle so a healthy config isn't re-fetched every foreground.
  static DateTime? _lastReached;

  /// Last time the dial THREW (transport/routing — the embedded node isn't up
  /// yet). Only a short cooldown, so a cold-launch-race failure retries across
  /// the connect window instead of being locked out for [_REFRESH_INTERVAL].
  /// Arming the long throttle on a failed attempt was the "not autoconfiguring"
  /// bug: the first launch attempt (node not up) blocked re-sync for 15 min.
  static DateTime? _lastFailure;
  static const _REFRESH_INTERVAL = Duration(minutes: 15);
  static const _FAILURE_COOLDOWN = Duration(seconds: 30);

  @visibleForTesting
  static void resetThrottle() {
    _lastReached = null;
    _lastFailure = null;
  }

  /// Explicit sync (Automatic Setup). Applies the payload when the server
  /// supports it; refusals and version skew come back unapplied on the
  /// outcome. Throws on transport errors.
  static Future<GatewayServicesOutcome> sync() async {
    final response = await (await gatewayClient()).selfServices();
    // Reached the gate (it answered, ok or refusal) — arm the long throttle.
    // A refusal is a server-version issue that won't fix by retrying in 30s.
    _lastReached = DateTime.now();
    LunaLogger().debug(
      'gateway services → HTTP ${response.statusCode} ok=${response.ok} '
      'kind=${response.kind} error=${response.error} '
      'services=${response.services?.length}',
    );
    if (!response.ok || !response.isSupported) {
      return GatewayServicesOutcome(response: response);
    }

    final profile = LunaProfile.current;
    final externals = LunaBox.externalModules.data.toList();
    final result = GatewayServicesReconciler.reconcile(
      profile: profile,
      externalModules: externals,
      services: response.services!,
      createExternal: LunaBox.externalModules.create,
      deleteExternal: (module) {
        if (module.isInBox) module.delete();
      },
    );
    // Per-person UX policy — resolved and persisted on the profile so the
    // simplified shell applies before the first gateway call each session.
    profile.uiBasic = response.ui.basic;
    if (profile.isInBox) profile.save();
    for (final module in externals) {
      if (module.isInBox) module.save();
    }
    NotificationsDatabase.SERVICES_LAST_SYNC
        .update(DateTime.now().millisecondsSinceEpoch);
    // Follow a server-driven rename: the admin-chosen server name rides the
    // handout (`server.name`). Applied last because it moves the profile's
    // Hive key (and migrates its name-keyed notification state). No-op until
    // the server ships the field, or when the name is already current.
    if (profile.serverOwned && response.serverName.isNotEmpty) {
      await LunaProfileTools()
          .renameServerOwnedProfile(profile, response.serverName);
    }
    return GatewayServicesOutcome(response: response, result: result);
  }

  /// Opportunistic re-sync on foreground/stream-reconnect. Runs whenever a
  /// Tailarr Server is configured (so granted services adopt and lock
  /// automatically — no user action) OR this device already carries
  /// gateway provenance. Throttled, silent on every failure — the stored
  /// config keeps working.
  /// [force] bypasses the throttle for a server-pushed config-changed signal —
  /// the change is real and known, so re-fetch immediately.
  static Future<void> refresh({bool force = false}) async {
    final profile = LunaProfile.current;
    // serverOwned covers invite-joined profiles whose Tailarr Server module
    // is (correctly) disabled — they still re-sync so a granted service
    // adopts and locks without any user action.
    final hasServer = profile.serverOwned ||
        (profile.tailarrServerEnabled && profile.tailarrServerHost.isNotEmpty);
    final hasManagedModules = profile.gatewayManagedModules.isNotEmpty ||
        LunaBox.externalModules.data
            .any((module) => module.gatewayName.isNotEmpty);
    if (!hasServer && !hasManagedModules) return;
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
      await sync();
    } catch (_) {
      // Node not up yet — short cooldown, not the long throttle, so a
      // cold-launch race recovers on the next trigger.
      _lastFailure = DateTime.now();
    }
  }

  /// A manual edit to a module's connection details takes it out of gateway
  /// management so re-syncs never clobber hand-entered values.
  static void markManual(String type) =>
      markManualOn(LunaProfile.current, type);

  static void markManualOn(LunaProfile profile, String type) {
    if (!profile.gatewayManagedModules.contains(type)) return;
    profile.gatewayManagedModules =
        profile.gatewayManagedModules.where((t) => t != type).toList();
    if (profile.isInBox) profile.save();
  }
}
