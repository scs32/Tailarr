// Grant-list recognition for server-driven connection screens. The bug this
// locks: an invite-joined, server-owned profile (Tailarr Server module
// deliberately DISABLED — it reaches the server via the hidden tailarr-gate
// node, not a user-entered host) was falling through to plain manual editors
// for ungranted services, because the predicate required
// `tailarrServerEnabled && tailarrServerHost`. Pure predicate, no Hive.
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/modules/settings/core/server_driven_connection.dart';

LunaProfile _profile({
  bool serverOwned = false,
  List<String> managed = const [],
  bool serverEnabled = false,
  String serverHost = '',
}) {
  final p = LunaProfile();
  p.serverOwned = serverOwned;
  p.gatewayManagedModules = managed;
  p.tailarrServerEnabled = serverEnabled;
  p.tailarrServerHost = serverHost;
  return p;
}

void main() {
  group('hasServerGrantListFor', () {
    test('invite-joined profile is recognized even with the module disabled',
        () {
      // serverOwned, only the bootstrap 'tailarr' managed marker, NO server
      // host/enabled — exactly the invite-join state that broke.
      final p = _profile(serverOwned: true, managed: ['tailarr']);
      expect(
        ServerDrivenConnection.hasServerGrantListFor(p, servicesSynced: false),
        isTrue,
      );
    });

    test('serverOwned alone is sufficient', () {
      final p = _profile(serverOwned: true);
      expect(
        ServerDrivenConnection.hasServerGrantListFor(p, servicesSynced: false),
        isTrue,
      );
    });

    test('a completed services sync is sufficient', () {
      final p = _profile();
      expect(
        ServerDrivenConnection.hasServerGrantListFor(p, servicesSynced: true),
        isTrue,
      );
    });

    test('a configured Tailarr Server module is sufficient', () {
      final p = _profile(
        serverEnabled: true,
        serverHost: 'https://tailarr.tail600657.ts.net',
      );
      expect(
        ServerDrivenConnection.hasServerGrantListFor(p, servicesSynced: false),
        isTrue,
      );
    });

    test('a plain standalone profile is NOT a server profile', () {
      // No server signal anywhere → manual editors, never Request Access.
      final p = _profile();
      expect(
        ServerDrivenConnection.hasServerGrantListFor(p, servicesSynced: false),
        isFalse,
      );
    });
  });
}
