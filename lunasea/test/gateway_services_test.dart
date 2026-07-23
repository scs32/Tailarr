// The /self/services contract (tailarr-server v0.23.0) and the module
// reconciler. Pure Dart — models are parsed from the frozen contract
// fixture and the reconciler mutates in-memory objects, no Hive needed.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/api/ntfy/models.dart';
import 'package:lunasea/database/models/external_module.dart';
import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/system/gateway/gateway_services.dart';

/// The exact success payload from the server handoff (v0.24.0) — the
/// frozen contract.
const CONTRACT_FIXTURE = '''
{
  "ok": true,
  "error": null,
  "kind": "services",
  "services": [
    {"type": "sonarr",   "name": "sonarr",    "url": "https://sonarr.tailXXXX.ts.net",     "auth": {"api_key": "abc123"}},
    {"type": "radarr",   "name": "radarr",    "url": "https://radarr.tailXXXX.ts.net",     "auth": {"api_key": "def456"}},
    {"type": "nzbget",   "name": "nzbget",    "url": "https://nzbget.tailXXXX.ts.net",     "auth": {"user": "nzbget", "password": "hunter2"}},
    {"type": "overseerr","name": "jellyseerr","url": "https://jellyseerr.tailXXXX.ts.net", "auth": {"api_key": "ovr789"}},
    {"type": "tailarr",  "name": "server",    "url": "https://tailarr.tailXXXX.ts.net",    "auth": null},
    {"type": "external", "name": "jellyfin",  "url": "https://jellyfin.tailXXXX.ts.net",   "auth": null}
  ]
}
''';

GatewayServicesResponse parse(String body, {int statusCode = 200}) {
  return GatewayServicesResponse.fromJson(
    json.decode(body) as Map<String, dynamic>,
    statusCode: statusCode,
  );
}

GatewayServicesResult reconcile({
  required LunaProfile profile,
  required List<LunaExternalModule> externals,
  required GatewayServicesResponse response,
}) {
  return GatewayServicesReconciler.reconcile(
    profile: profile,
    externalModules: externals,
    services: response.services!,
    createExternal: (_) {},
  );
}

void main() {
  group('contract parsing', () {
    test('parses the frozen success payload', () {
      final response = parse(CONTRACT_FIXTURE);
      expect(response.ok, isTrue);
      expect(response.isSupported, isTrue);
      expect(response.isUnavailable, isFalse);
      expect(response.services, hasLength(6));

      final sonarr = response.services![0];
      expect(sonarr.type, 'sonarr');
      expect(sonarr.url, 'https://sonarr.tailXXXX.ts.net');
      expect(sonarr.apiKey, 'abc123');

      final nzbget = response.services![2];
      expect(nzbget.authUser, 'nzbget');
      expect(nzbget.authPassword, 'hunter2');
      expect(nzbget.apiKey, isEmpty);

      // Jellyseerr hands out as type overseerr — name stays distinguishable.
      final jellyseerr = response.services![3];
      expect(jellyseerr.type, 'overseerr');
      expect(jellyseerr.name, 'jellyseerr');

      final tailarr = response.services![4];
      expect(tailarr.auth, isNull);
      expect(tailarr.apiKey, isEmpty);
    });

    test('old controller answering the notifications payload is unavailable',
        () {
      // No `services` key, no `kind: services` — must read as "server too
      // old", never as an error and never consumed.
      final response = parse(
        '{"ok": true, "error": null, "url": "https://ntfy.x.ts.net", '
        '"token": "tk_abc", "topics": ["tlr-ops"]}',
      );
      expect(response.isSupported, isFalse);
      expect(response.isUnavailable, isTrue);
      expect(response.isUnassigned, isFalse);
    });

    test('old gateway 404 is unavailable', () {
      final response = parse(
        '{"ok": false, "error": "not found"}',
        statusCode: 404,
      );
      expect(response.isSupported, isFalse);
      expect(response.isUnavailable, isTrue);
      expect(response.isUnassigned, isFalse);
    });

    test('un-personed device refusal is unassigned, not unavailable', () {
      final response = parse(
        '{"ok": false, "error": "this device is not assigned to a user"}',
      );
      expect(response.isUnassigned, isTrue);
      expect(response.isUnavailable, isFalse);
    });

    test('unknown future types parse and read as non-native', () {
      final response = parse(
        '{"ok": true, "kind": "services", "services": ['
        '{"type": "jellystat", "name": "jellystat", '
        '"url": "https://j.x.ts.net", "auth": null}]}',
      );
      expect(response.services!.single.type, 'jellystat');
      expect(
        GatewayServicesReconciler.NATIVE_TYPES,
        isNot(contains('jellystat')),
      );
      // Overseerr is native server-side but feature-flagged off in-app, so
      // it must stay on the external-fallback path.
      expect(
        GatewayServicesReconciler.NATIVE_TYPES,
        isNot(contains('overseerr')),
      );
    });
  });

  group('reconcile', () {
    test('fresh profile materializes natives, server module, and bookmark',
        () {
      final profile = LunaProfile();
      final externals = <LunaExternalModule>[];
      final created = <LunaExternalModule>[];
      final result = GatewayServicesReconciler.reconcile(
        profile: profile,
        externalModules: externals,
        services: parse(CONTRACT_FIXTURE).services!,
        createExternal: created.add,
      );

      expect(profile.sonarrEnabled, isTrue);
      expect(profile.sonarrHost, 'https://sonarr.tailXXXX.ts.net');
      expect(profile.sonarrKey, 'abc123');
      expect(profile.radarrEnabled, isTrue);
      expect(profile.radarrKey, 'def456');
      expect(profile.nzbgetEnabled, isTrue);
      expect(profile.nzbgetUser, 'nzbget');
      expect(profile.nzbgetPass, 'hunter2');
      expect(profile.tailarrServerEnabled, isTrue);
      expect(profile.tailarrServerHost, 'https://tailarr.tailXXXX.ts.net');
      expect(
        profile.gatewayManagedModules,
        ['nzbget', 'radarr', 'sonarr', 'tailarr'],
      );

      // Overseerr is feature-flagged off, so jellyseerr books alongside
      // the plain external entry.
      expect(profile.overseerrEnabled, isFalse);
      expect(created.map((m) => m.displayName), ['jellyseerr', 'jellyfin']);
      expect(created.map((m) => m.gatewayName), ['jellyseerr', 'jellyfin']);
      expect(created.last.host, 'https://jellyfin.tailXXXX.ts.net');

      expect(result.configured, ['sonarr', 'radarr', 'nzbget', 'tailarr']);
      expect(result.bookmarked, ['jellyseerr', 'jellyfin']);
      expect(result.missingAuth, isEmpty);
    });

    test('hand-entered config is never clobbered', () {
      final profile = LunaProfile(
        sonarrEnabled: true,
        sonarrHost: 'https://my-own-sonarr.local',
        sonarrKey: 'my-own-key',
      );
      final result = reconcile(
        profile: profile,
        externals: [],
        response: parse(CONTRACT_FIXTURE),
      );
      expect(profile.sonarrHost, 'https://my-own-sonarr.local');
      expect(profile.sonarrKey, 'my-own-key');
      expect(profile.gatewayManagedModules, isNot(contains('sonarr')));
      // The other slots were unconfigured, so they were adopted.
      expect(result.configured, ['radarr', 'nzbget', 'tailarr']);
    });

    test('empty url keeps the stored value, never deconfigures', () {
      final profile = LunaProfile(
        sonarrEnabled: true,
        sonarrHost: 'https://sonarr.tailXXXX.ts.net',
        sonarrKey: 'abc123',
        gatewayManagedModules: ['sonarr'],
      );
      reconcile(
        profile: profile,
        externals: [],
        response: parse(
          '{"ok": true, "kind": "services", "services": ['
          '{"type": "sonarr", "name": "sonarr", "url": "", '
          '"auth": {"api_key": "abc123"}}]}',
        ),
      );
      expect(profile.sonarrHost, 'https://sonarr.tailXXXX.ts.net');
      expect(profile.sonarrEnabled, isTrue);
    });

    test('auth null keeps the module and flags the missing credential', () {
      final profile = LunaProfile();
      final result = reconcile(
        profile: profile,
        externals: [],
        response: parse(
          '{"ok": true, "kind": "services", "services": ['
          '{"type": "sonarr", "name": "sonarr", '
          '"url": "https://sonarr.x.ts.net", "auth": null}]}',
        ),
      );
      expect(profile.sonarrEnabled, isTrue);
      expect(profile.sonarrHost, 'https://sonarr.x.ts.net');
      expect(profile.sonarrKey, isEmpty);
      expect(result.missingAuth, ['sonarr']);

      // A later sync that carries the key completes the module in place.
      profile.sonarrKey = '';
      final second = reconcile(
        profile: profile,
        externals: [],
        response: parse(
          '{"ok": true, "kind": "services", "services": ['
          '{"type": "sonarr", "name": "sonarr", '
          '"url": "https://sonarr.x.ts.net", "auth": {"api_key": "late"}}]}',
        ),
      );
      expect(profile.sonarrKey, 'late');
      expect(second.missingAuth, isEmpty);
    });

    test('revoked badge disables the managed module but keeps its config',
        () {
      final profile = LunaProfile(
        sonarrEnabled: true,
        sonarrHost: 'https://sonarr.x.ts.net',
        sonarrKey: 'abc123',
        radarrEnabled: true,
        radarrHost: 'https://radarr.x.ts.net',
        radarrKey: 'def456',
        gatewayManagedModules: ['radarr', 'sonarr'],
      );
      final result = reconcile(
        profile: profile,
        externals: [],
        response: parse(
          '{"ok": true, "kind": "services", "services": ['
          '{"type": "sonarr", "name": "sonarr", '
          '"url": "https://sonarr.x.ts.net", "auth": {"api_key": "abc123"}}]}',
        ),
      );
      expect(profile.radarrEnabled, isFalse);
      expect(profile.radarrHost, 'https://radarr.x.ts.net');
      expect(profile.radarrKey, 'def456');
      // Provenance survives revocation so a re-grant re-enables in place.
      expect(profile.gatewayManagedModules, contains('radarr'));
      expect(result.disabled, ['radarr']);

      final regrant = reconcile(
        profile: profile,
        externals: [],
        response: parse(CONTRACT_FIXTURE),
      );
      expect(profile.radarrEnabled, isTrue);
      expect(regrant.configured, contains('radarr'));
    });

    test('unmanaged disabled modules are untouched by revocation', () {
      final profile = LunaProfile(
        sonarrHost: 'https://my-own.local',
        sonarrKey: 'k',
      );
      final result = reconcile(
        profile: profile,
        externals: [],
        response: parse('{"ok": true, "kind": "services", "services": []}'),
      );
      expect(profile.sonarrHost, 'https://my-own.local');
      expect(result.isEmpty, isTrue);
    });

    test('unknown future type falls through to an external bookmark', () {
      final created = <LunaExternalModule>[];
      GatewayServicesReconciler.reconcile(
        profile: LunaProfile(),
        externalModules: [],
        services: parse(
          '{"ok": true, "kind": "services", "services": ['
          '{"type": "jellystat", "name": "jellystat", '
          '"url": "https://j.x.ts.net", "auth": null}]}',
        ).services!,
        createExternal: created.add,
      );
      expect(created, hasLength(1));
      expect(created.single.displayName, 'jellystat');
      expect(created.single.host, 'https://j.x.ts.net');
    });

    test('a bookmark that jumps external→native upgrades into the module',
        () {
      // Server v0.23.0 handed nzbget out as external; v0.24.0 promotes it.
      final bookmark = LunaExternalModule(
        displayName: 'nzbget',
        host: 'https://nzbget.tailXXXX.ts.net',
        gatewayName: 'nzbget',
      );
      final externals = [bookmark];
      final deleted = <LunaExternalModule>[];
      final profile = LunaProfile();
      GatewayServicesReconciler.reconcile(
        profile: profile,
        externalModules: externals,
        services: parse(
          '{"ok": true, "kind": "services", "services": ['
          '{"type": "nzbget", "name": "nzbget", '
          '"url": "https://nzbget.tailXXXX.ts.net", '
          '"auth": {"user": "", "password": "hunter2"}}]}',
        ).services!,
        createExternal: (_) {},
        deleteExternal: deleted.add,
      );
      expect(deleted, [bookmark]);
      expect(externals, isEmpty);
      expect(profile.nzbgetEnabled, isTrue);
      expect(profile.nzbgetHost, 'https://nzbget.tailXXXX.ts.net');
      expect(profile.nzbgetUser, isEmpty);
      expect(profile.nzbgetPass, 'hunter2');
    });

    test('managed bookmarks reconcile by name; revoked ones are marked', () {
      final jellyfin = LunaExternalModule(
        displayName: 'jellyfin',
        host: 'https://old-url.x.ts.net',
        gatewayName: 'jellyfin',
      );
      final userOwn = LunaExternalModule(
        displayName: 'My NAS',
        host: 'https://nas.local',
      );
      final externals = [jellyfin, userOwn];

      // Update pass: url refreshes in place, user bookmark untouched.
      reconcile(
        profile: LunaProfile(),
        externals: externals,
        response: parse(CONTRACT_FIXTURE),
      );
      expect(jellyfin.host, 'https://jellyfin.tailXXXX.ts.net');
      expect(userOwn.host, 'https://nas.local');

      // Revocation pass: marked, not deleted; user bookmark untouched.
      reconcile(
        profile: LunaProfile(),
        externals: externals,
        response: parse('{"ok": true, "kind": "services", "services": []}'),
      );
      expect(jellyfin.displayName, 'jellyfin (Revoked)');
      expect(jellyfin.host, 'https://jellyfin.tailXXXX.ts.net');
      expect(userOwn.displayName, 'My NAS');

      // Re-grant restores the display name.
      reconcile(
        profile: LunaProfile(),
        externals: externals,
        response: parse(CONTRACT_FIXTURE),
      );
      expect(jellyfin.displayName, 'jellyfin');
    });

    test('duplicate native types beyond the first become bookmarks', () {
      final profile = LunaProfile();
      final created = <LunaExternalModule>[];
      GatewayServicesReconciler.reconcile(
        profile: profile,
        externalModules: [],
        services: parse(
          '{"ok": true, "kind": "services", "services": ['
          '{"type": "sonarr", "name": "sonarr", '
          '"url": "https://s1.x.ts.net", "auth": {"api_key": "one"}},'
          '{"type": "sonarr", "name": "sonarr-4k", '
          '"url": "https://s2.x.ts.net", "auth": {"api_key": "two"}}]}',
        ).services!,
        createExternal: created.add,
      );
      expect(profile.sonarrHost, 'https://s1.x.ts.net');
      expect(created.single.displayName, 'sonarr-4k');
    });
  });

  group('manual-edit provenance', () {
    test('markManualOn removes gateway management for that module only', () {
      final profile = LunaProfile(
        gatewayManagedModules: ['radarr', 'sonarr'],
      );
      GatewayServicesSync.markManualOn(profile, 'sonarr');
      expect(profile.gatewayManagedModules, ['radarr']);
      // No-op when not managed.
      GatewayServicesSync.markManualOn(profile, 'sonarr');
      expect(profile.gatewayManagedModules, ['radarr']);
    });
  });
}
