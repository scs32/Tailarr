import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/api/tailarr_server/models.dart';

// Fixtures captured verbatim from a live tailarr-server v0.20.0
// (2026-07-22) — the shapes the people-model UI codes against.
const _v20WithPerson =
    '{"configured": true, "error": null, "users": [{"id": "ncELdc4di521CNTRL", '
    '"hostname": "tailarr-app-Apple-Container-b8tb9c", "nickname": "", '
    '"os": "iOS", "last_seen": "2026-07-22T00:58:48Z", "ip": "100.87.160.64", '
    '"can": ["server"]}], "people": [{"id": "907e201a", '
    '"name": "Claude Renamed", "badges": ["heresphere"], '
    '"created": 1784763276, "devices": []}], '
    '"services": ["heresphere", "server"], "ntfy": false}';

// Pre-0.19.0 servers: flat machine list, no `people` key at all.
const _legacy =
    '{"configured": true, "error": null, "users": [{"id": "ncELdc4di521CNTRL", '
    '"hostname": "tailarr-app-Apple-Container-b8tb9c", "nickname": "", '
    '"os": "iOS", "last_seen": "2026-07-22T00:58:48Z", "ip": "100.87.160.64", '
    '"can": ["server"]}], "services": ["heresphere", "server"]}';

void main() {
  group('TailarrServerUsers v0.20 people model', () {
    test('parses people, unassigned machines, services, ntfy', () {
      final users = TailarrServerUsers.fromJson(json.decode(_v20WithPerson));
      expect(users.hasPeople, isTrue);
      expect(users.configured, isTrue);
      expect(users.ntfy, isFalse);
      expect(users.services, ['heresphere', 'server']);

      expect(users.people, hasLength(1));
      final person = users.people.first;
      expect(person.id, '907e201a');
      expect(person.name, 'Claude Renamed');
      expect(person.badges, ['heresphere']);
      expect(person.devices, isEmpty);
      expect(person.createdAt, isNotNull);
      expect(person.createdAt!.year, greaterThanOrEqualTo(2026));

      // The old flat list is now the unassigned bucket.
      expect(users.users, hasLength(1));
      expect(users.users.first.hostname,
          'tailarr-app-Apple-Container-b8tb9c');
      expect(users.users.first.can, ['server']);
    });

    test('detects the legacy model by the ABSENCE of the people key', () {
      final users = TailarrServerUsers.fromJson(json.decode(_legacy));
      expect(users.hasPeople, isFalse);
      expect(users.people, isEmpty);
      expect(users.users, hasLength(1));
      expect(users.ntfy, isFalse);
    });
  });

  group('people action results', () {
    test('add/reissue key payload', () {
      final result = TailarrServerPersonKey.fromJson(json.decode(
          '{"ok": true, "id": "907e201a", '
          '"key": "tskey-auth-kuHhJo3cUt11CNTRL-cUJyET8Mu6", "error": null}'));
      expect(result.ok, isTrue);
      expect(result.id, '907e201a');
      expect(result.key, startsWith('tskey-auth-'));
      expect(result.error, isNull);
    });

    test('notification credentials round into the app subscription config',
        () {
      final creds = TailarrServerNotificationCredentials.fromJson(json.decode(
          '{"ok": true, "error": null, "url": "https://ntfy.example.ts.net", '
          '"user": "dave", "password": "hunter2", "token": "tk_abc", '
          '"topics": ["tlr-media-sonarr", "tlr-media-heresphere"]}'));
      expect(creds.ok, isTrue);
      expect(creds.user, 'dave');
      expect(creds.password, 'hunter2');
      // The share payload must be importable by the Notifications module.
      final parsed = json.decode(creds.subscriptionJson);
      expect(parsed['url'], 'https://ntfy.example.ts.net');
      expect(parsed['token'], 'tk_abc');
      expect(parsed['topics'], ['tlr-media-sonarr', 'tlr-media-heresphere']);
    });
  });
}
