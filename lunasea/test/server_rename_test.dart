// Server-driven profile rename: the pure pieces that need no Hive/files.
//   * parsing the admin-chosen name off the /self/services handout, and
//   * moving a shared-state slice when the profile it belongs to is renamed.
// The full Hive migration (profiles box + NOTIFICATIONS_*@ keys + inbox
// retag) lives in integration_test/server_rename_test.dart.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/api/ntfy/models.dart';
import 'package:lunasea/system/notifications/platform/ntfy_shared_state.dart';

GatewayServicesResponse parse(String body) => GatewayServicesResponse.fromJson(
      json.decode(body) as Map<String, dynamic>,
      statusCode: 200,
    );

void main() {
  group('GatewayServicesResponse.serverName', () {
    test('reads the admin-chosen name from server.name', () {
      final r = parse('''
        {"ok": true, "error": null, "kind": "services", "services": [],
         "server": {"name": "Living Room"}}
      ''');
      expect(r.serverName, 'Living Room');
    });

    test('trims surrounding whitespace', () {
      final r = parse('''
        {"ok": true, "kind": "services", "services": [],
         "server": {"name": "  Home Media  "}}
      ''');
      expect(r.serverName, 'Home Media');
    });

    test('is empty when the server omits the field (older server)', () {
      final r = parse(
          '{"ok": true, "kind": "services", "services": []}');
      expect(r.serverName, '');
    });

    test('is empty when server is present but nameless', () {
      final r = parse(
          '{"ok": true, "kind": "services", "services": [], "server": {}}');
      expect(r.serverName, '');
    });

    test('is empty (not a crash) when server is not an object', () {
      final r = parse(
          '{"ok": true, "kind": "services", "services": [], "server": "x"}');
      expect(r.serverName, '');
    });
  });

  group('NtfySharedState.renameProfile', () {
    NtfySharedState seeded() => NtfySharedState(
          activeProfile: 'Tailarr',
          profiles: {
            'Tailarr': NtfyProfileState(
              profile: 'Tailarr',
              url: 'https://ntfy.example.ts.net',
              token: 'tk_abc',
              topics: const ['tlr-ops'],
              since: 4242,
              bgSince: 99,
              notifiedIds: const ['m1', 'm2'],
              dismissedIds: const ['d1', 'd2'],
            ),
            'Home': NtfyProfileState(profile: 'Home', since: 7),
          },
        );

    test('moves the slice and preserves its since-markers', () {
      final s = seeded()..renameProfile('Tailarr', 'Living Room');
      expect(s.profiles.containsKey('Tailarr'), isFalse);
      final moved = s.profiles['Living Room']!;
      expect(moved.profile, 'Living Room');
      expect(moved.url, 'https://ntfy.example.ts.net');
      expect(moved.token, 'tk_abc');
      expect(moved.topics, ['tlr-ops']);
      expect(moved.since, 4242);
      expect(moved.bgSince, 99);
      expect(moved.notifiedIds, ['m1', 'm2']);
      expect(moved.dismissedIds, ['d1', 'd2']);
    });

    test('dismissedIds survive a JSON round-trip', () {
      final slice = NtfyProfileState(
        profile: 'p',
        dismissedIds: const ['a', 'b', 'c'],
      );
      final restored = NtfyProfileState.fromJson('p', slice.toJson());
      expect(restored.dismissedIds, ['a', 'b', 'c']);
    });

    test('retargets the active profile when it was the one renamed', () {
      final s = seeded()..renameProfile('Tailarr', 'Living Room');
      expect(s.activeProfile, 'Living Room');
    });

    test('leaves other slices and a non-active rename untouched', () {
      final s = seeded()..renameProfile('Home', 'House');
      expect(s.activeProfile, 'Tailarr');
      expect(s.profiles.containsKey('House'), isTrue);
      expect(s.profiles['House']!.since, 7);
      expect(s.profiles.containsKey('Tailarr'), isTrue);
    });

    test('no-ops on identical or empty target', () {
      final s = seeded()..renameProfile('Tailarr', 'Tailarr');
      expect(s.profiles.keys.toSet(), {'Tailarr', 'Home'});
      s.renameProfile('Tailarr', '');
      expect(s.profiles.keys.toSet(), {'Tailarr', 'Home'});
    });
  });
}
