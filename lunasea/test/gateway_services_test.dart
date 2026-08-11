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
  List<String>? log,
}) {
  return GatewayServicesReconciler.reconcile(
    profile: profile,
    externalModules: externals,
    services: response.services!,
    createExternal: (_) {},
    log: log == null ? null : log.add,
  );
}

/// A profile with every managed native module lit up — the shape a working
/// install carries, and the thing an empty handout used to wipe.
LunaProfile fullyManagedProfile() => LunaProfile(
      sonarrEnabled: true,
      sonarrHost: 'https://sonarr.x.ts.net',
      sonarrKey: 'abc123',
      radarrEnabled: true,
      radarrHost: 'https://radarr.x.ts.net',
      radarrKey: 'def456',
      tailarrServerEnabled: true,
      tailarrServerHost: 'https://tailarr.x.ts.net',
      gatewayManagedModules: ['radarr', 'sonarr', 'tailarr'],
    );

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

    test('APP-7: "Unknown user." refusal is account-gone, not unassigned', () {
      final response = parse('{"ok": false, "error": "Unknown user."}');
      expect(response.isAccountGone, isTrue);
      // Distinct from an unassigned/not-yet-assigned device (recoverable) and
      // never a version-skew "unavailable".
      expect(response.isUnassigned, isFalse);
      expect(response.isUnavailable, isTrue); // no services payload
    });

    test('APP-7: an unassigned device is NOT account-gone', () {
      final response = parse(
        '{"ok": false, "error": "this device is not assigned to a user"}',
      );
      expect(response.isAccountGone, isFalse);
      expect(response.isUnassigned, isTrue);
    });

    test('APP-7: a healthy services payload is never account-gone', () {
      final response = parse(CONTRACT_FIXTURE);
      expect(response.isAccountGone, isFalse);
    });

    test(
        'APP-7: a transient 503 "roster unavailable" is NOT account-gone '
        '(fail-closed — must never trigger the destructive demo-drop)', () {
      final response = parse(
        '{"ok": false, "error": "Roster temporarily unavailable — retry.", '
        '"unavailable": true}',
        statusCode: 503,
      );
      expect(response.unavailable, isTrue);
      expect(response.isAccountGone, isFalse);
      expect(response.isUnassigned, isFalse);
    });

    test(
        'APP-7: even a 503 that echoes "unknown user" stays transient '
        '(unavailable flag / 503 status wins over the error string)', () {
      final response = parse(
        '{"ok": false, "error": "Unknown user.", "unavailable": true}',
        statusCode: 503,
      );
      expect(response.isAccountGone, isFalse);
    });

    test('no ui object → full experience (default people, older servers)', () {
      final response = parse(CONTRACT_FIXTURE);
      expect(response.ui.basic, isFalse);
    });

    test('ui.basic true → Basic preset', () {
      final response = parse(
        '{"ok": true, "kind": "services", "ui": {"basic": true}, '
        '"services": [{"type": "overseerr", "name": "jellyseerr", '
        '"url": "https://j.x.ts.net", "auth": {"api_key": "k"}}]}',
      );
      expect(response.ui.basic, isTrue);
      // UX policy never changes the handed-out service set.
      expect(response.services, hasLength(1));
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

    group('APP-1: admin token vs. server-driven address change', () {
      String tailarrPayload(String url) => '''
{
  "ok": true, "error": null, "kind": "services",
  "services": [ {"type": "tailarr", "name": "server", "url": "$url", "auth": null} ]
}
''';

      test('drops the admin token when the controller host is swapped', () {
        // A hijacked gateway handing a NEW controller address must not receive
        // the real admin bearer — the token is dropped so the next call
        // re-verifies identity via Quick Connect.
        final profile = LunaProfile(
          tailarrServerEnabled: true,
          tailarrServerHost: 'https://tailarr.tailXXXX.ts.net',
          serverAdminToken: 'secret-admin-token',
        );
        reconcile(
          profile: profile,
          externals: [],
          response: parse(tailarrPayload('https://evil.attacker.ts.net')),
        );
        expect(profile.tailarrServerHost, 'https://evil.attacker.ts.net');
        expect(profile.serverAdminToken, isEmpty);
      });

      test('keeps the token when the host is unchanged', () {
        final profile = LunaProfile(
          tailarrServerEnabled: true,
          tailarrServerHost: 'https://tailarr.tailXXXX.ts.net',
          serverAdminToken: 'secret-admin-token',
        );
        reconcile(
          profile: profile,
          externals: [],
          response: parse(tailarrPayload('https://tailarr.tailXXXX.ts.net')),
        );
        expect(profile.serverAdminToken, 'secret-admin-token');
      });

      test('keeps the token across a scheme/port/path-only change (same host)',
          () {
        final profile = LunaProfile(
          tailarrServerEnabled: true,
          tailarrServerHost: 'https://tailarr.tailXXXX.ts.net',
          serverAdminToken: 'secret-admin-token',
        );
        reconcile(
          profile: profile,
          externals: [],
          response: parse(tailarrPayload('https://tailarr.tailXXXX.ts.net:8443/')),
        );
        expect(profile.serverAdminToken, 'secret-admin-token');
      });

      test('does not touch the token on first configuration (no prior host)',
          () {
        final profile = LunaProfile(serverAdminToken: 'pre-existing');
        reconcile(
          profile: profile,
          externals: [],
          response: parse(tailarrPayload('https://tailarr.tailXXXX.ts.net')),
        );
        // previous host was empty → not a "swap", token untouched.
        expect(profile.serverAdminToken, 'pre-existing');
      });
    });

    test('a server-granted service overrides hand-entered config', () {
      // Server-owned means server-owned: a suite server that grants Sonarr
      // takes over even a previously hand-entered config, and locks it.
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
      expect(profile.sonarrHost, 'https://sonarr.tailXXXX.ts.net');
      expect(profile.sonarrKey, 'abc123');
      expect(profile.gatewayManagedModules, contains('sonarr'));
      expect(result.configured, contains('sonarr'));
    });

    test('a service the server does not grant is left alone', () {
      // Standalone module with no matching grant stays manual, untouched.
      final profile = LunaProfile(
        sonarrEnabled: true,
        sonarrHost: 'https://my-own-sonarr.local',
        sonarrKey: 'my-own-key',
      );
      reconcile(
        profile: profile,
        externals: [],
        response: parse('{"ok": true, "kind": "services", "services": ['
            '{"type": "radarr", "name": "radarr", '
            '"url": "https://radarr.x.ts.net", "auth": {"api_key": "r"}}]}'),
      );
      expect(profile.sonarrHost, 'https://my-own-sonarr.local');
      expect(profile.sonarrKey, 'my-own-key');
      expect(profile.gatewayManagedModules, isNot(contains('sonarr')));
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
      // Revocation drops provenance so the connection screen offers
      // "Request Access" rather than a stale managed card; a re-grant
      // re-adopts it.
      expect(profile.gatewayManagedModules, isNot(contains('radarr')));
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

    group('APP-9: an empty listing is unusable input, not "no services"', () {
      // The shipped bug. `{"ok":true,"kind":"services","services":[]}` passes
      // `!response.ok || !response.isSupported` (fromJson maps `[]` to an
      // EMPTY LIST, not null, so isSupported is true) and then the revocation
      // loop disabled every managed module — re-armed on every iOS foreground.
      test('does NOT disable managed modules', () {
        final profile = fullyManagedProfile();
        final response =
            parse('{"ok": true, "kind": "services", "services": []}');

        // The guard the reconciler used to be behind still lets this through —
        // which is exactly why the reconciler itself has to refuse it.
        expect(response.ok, isTrue);
        expect(response.isSupported, isTrue);

        final result =
            reconcile(profile: profile, externals: [], response: response);

        expect(result.skipped, isTrue);
        expect(result.disabled, isEmpty);
        expect(profile.sonarrEnabled, isTrue);
        expect(profile.radarrEnabled, isTrue);
        expect(profile.tailarrServerEnabled, isTrue);
        // Provenance survives too — dropping it would show "Request Access"
        // on a module the server never revoked.
        expect(profile.gatewayManagedModules,
            containsAll(['radarr', 'sonarr', 'tailarr']));
      });

      test('a listing of only unnamed entries is unusable the same way', () {
        // Entries with an empty name are skipped by the configure loop, so
        // such a listing degenerates into the same mass-revoke.
        final profile = fullyManagedProfile();
        final result = reconcile(
          profile: profile,
          externals: [],
          response: parse(
            '{"ok": true, "kind": "services", "services": ['
            '{"type": "sonarr", "name": "", "url": "https://s.x.ts.net", '
            '"auth": null}]}',
          ),
        );
        expect(result.skipped, isTrue);
        expect(profile.sonarrEnabled, isTrue);
        expect(profile.radarrEnabled, isTrue);
      });

      test('an empty listing does not mark managed bookmarks revoked', () {
        final bookmark = LunaExternalModule(
          displayName: 'jellyfin',
          host: 'https://jellyfin.x.ts.net',
          gatewayName: 'jellyfin',
        );
        final result = reconcile(
          profile: fullyManagedProfile(),
          externals: [bookmark],
          response: parse('{"ok": true, "kind": "services", "services": []}'),
        );
        expect(result.skipped, isTrue);
        expect(bookmark.displayName, 'jellyfin');
      });

      // THE CONTROL. Without this, "never revoke" would pass every test
      // above. A known-good handout that names services and genuinely omits
      // a managed module must STILL disable it.
      test('CONTROL: a genuine revocation still disables the module', () {
        final profile = fullyManagedProfile();
        final result = reconcile(
          profile: profile,
          externals: [],
          response: parse(
            '{"ok": true, "kind": "services", "services": ['
            '{"type": "sonarr", "name": "sonarr", '
            '"url": "https://sonarr.x.ts.net", "auth": {"api_key": "abc123"}},'
            '{"type": "tailarr", "name": "server", '
            '"url": "https://tailarr.x.ts.net", "auth": null}]}',
          ),
        );
        expect(result.skipped, isFalse);
        expect(result.disabled, ['radarr']);
        expect(profile.radarrEnabled, isFalse);
        expect(profile.gatewayManagedModules, isNot(contains('radarr')));
        // …and the services that ARE present stay up.
        expect(profile.sonarrEnabled, isTrue);
        expect(profile.tailarrServerEnabled, isTrue);
      });
    });

    group('APP-9: diagnostic logging on the transitions that matter', () {
      test('logs the skip, naming it as unusable input', () {
        final log = <String>[];
        reconcile(
          profile: fullyManagedProfile(),
          externals: [],
          response: parse('{"ok": true, "kind": "services", "services": []}'),
          log: log,
        );
        expect(log, hasLength(1));
        expect(log.single, contains('SKIPPED'));
        expect(log.single, contains('unusable'));
      });

      test('logs WHICH module was disabled and what it decided from', () {
        final log = <String>[];
        reconcile(
          profile: fullyManagedProfile(),
          externals: [],
          response: parse(
            '{"ok": true, "kind": "services", "services": ['
            '{"type": "sonarr", "name": "sonarr", '
            '"url": "https://sonarr.x.ts.net", "auth": {"api_key": "abc123"}}]}',
          ),
          log: log,
        );
        final disabled = log.where((l) => l.contains('DISABLED')).toList();
        expect(disabled, hasLength(2)); // radarr + tailarr
        expect(disabled.any((l) => l.contains('radarr')), isTrue);
        expect(disabled.any((l) => l.contains('tailarr')), isTrue);
        // The evidence it decided from — the handout it actually saw.
        expect(disabled.first, contains('sonarr'));
      });

      test('logs the admin-token wipe with the before/after host', () {
        final log = <String>[];
        final profile = LunaProfile(
          tailarrServerEnabled: true,
          tailarrServerHost: 'https://old.x.ts.net',
          serverAdminToken: 'secret-token',
          gatewayManagedModules: ['tailarr'],
        );
        reconcile(
          profile: profile,
          externals: [],
          response: parse(
            '{"ok": true, "kind": "services", "services": ['
            '{"type": "tailarr", "name": "server", '
            '"url": "https://new.x.ts.net", "auth": null}]}',
          ),
          log: log,
        );
        expect(profile.serverAdminToken, isEmpty);
        final wipe = log.singleWhere((l) => l.contains('WIPED'));
        expect(wipe, contains('server'));
        expect(wipe, contains('old.x.ts.net'));
        expect(wipe, contains('new.x.ts.net'));
        // The token itself is never logged.
        expect(wipe, isNot(contains('secret-token')));
      });
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
      // APP-9: driven by a handout that NAMES a service and genuinely omits
      // jellyfin. This pass used to use `services: []`, which is the defect
      // input — an empty listing is now (correctly) a no-op, see the APP-9
      // group. Bookmark revocation itself is unchanged and still asserted.
      reconcile(
        profile: LunaProfile(),
        externals: externals,
        response: parse(
          '{"ok": true, "kind": "services", "services": ['
          '{"type": "sonarr", "name": "sonarr", '
          '"url": "https://sonarr.tailXXXX.ts.net", '
          '"auth": {"api_key": "abc123"}}]}',
        ),
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
