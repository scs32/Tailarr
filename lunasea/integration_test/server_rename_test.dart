// Server-driven profile rename: the full Hive migration. When the server's
// admin-chosen name (server.name on /self/services) changes, the server-owned
// profile is renamed in place AND its name-keyed per-profile state moves with
// it — the profiles box entry, the NOTIFICATIONS_*@<name> config keys, and the
// inbox entries (box key + profile tag). Needs real boxes, so it runs on a sim:
//   flutter test integration_test/server_rename_test.dart -d <sim-udid>
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/database/models/notification.dart';
import 'package:lunasea/main.dart';
import 'package:lunasea/utils/profile_tools.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  var booted = false;
  Future<void> reset() async {
    if (!booted) {
      await bootstrap();
      booted = true;
    }
    await LunaBox.profiles.clear();
    await LunaBox.notifications.clear();
  }

  // Seed a server-owned profile with a full slice of per-profile state, as an
  // invite join + a notification sync would have left it.
  Future<void> seed(String name, String host, {bool active = true}) async {
    await LunaBox.profiles.update(
      name,
      LunaProfile(serverOwned: true, tailarrServerHost: host),
    );
    if (active) LunaSeaDatabase.ENABLED_PROFILE.update(name);
    await LunaBox.lunasea.update(
        'NOTIFICATIONS_URL@$name', 'https://ntfy.example.ts.net');
    await LunaBox.lunasea.update('NOTIFICATIONS_TOPICS@$name', ['tlr-ops']);
    await LunaBox.lunasea.update('NOTIFICATIONS_ENABLED@$name', true);
    await LunaBox.notifications.update(
      LunaNotification.boxKey(name, 'abc'),
      LunaNotification(id: 'abc', time: 1, topic: 'tlr-ops', profile: name),
    );
  }

  testWidgets('rename moves the profile and all its name-keyed state',
      (t) async {
    await reset();
    const host = 'https://tailarr.tail95fc29.ts.net';
    await seed('Tailarr', host);

    final target = await LunaProfileTools()
        .renameServerOwnedProfile(LunaProfile.get('Tailarr'), 'Living Room');
    expect(target, 'Living Room');

    // Profiles box: entry moved to the new key, server ownership intact.
    expect(LunaBox.profiles.contains('Tailarr'), isFalse);
    final moved = LunaBox.profiles.read('Living Room');
    expect(moved, isNotNull);
    expect(moved!.serverOwned, isTrue);
    expect(moved.tailarrServerHost, host);

    // Active selection followed the rename.
    expect(LunaSeaDatabase.ENABLED_PROFILE.read(), 'Living Room');

    // Notification config keys migrated suffix.
    expect(LunaBox.lunasea.contains('NOTIFICATIONS_URL@Tailarr'), isFalse);
    expect(LunaBox.lunasea.read('NOTIFICATIONS_URL@Living Room'),
        'https://ntfy.example.ts.net');
    expect(LunaBox.lunasea.read('NOTIFICATIONS_TOPICS@Living Room'),
        ['tlr-ops']);

    // Inbox entry re-keyed and re-tagged.
    expect(
        LunaBox.notifications.contains(
            LunaNotification.boxKey('Tailarr', 'abc')),
        isFalse);
    final alert = LunaBox.notifications
        .read(LunaNotification.boxKey('Living Room', 'abc'));
    expect(alert, isNotNull);
    expect(alert!.profile, 'Living Room');
  });

  testWidgets('rename de-duplicates against a different existing profile',
      (t) async {
    await reset();
    const host = 'https://tailarr.tail95fc29.ts.net';
    // A user's own (non-server) profile already holds the target name.
    await LunaBox.profiles.update('Living Room', LunaProfile());
    await seed('Tailarr', host);

    final target = await LunaProfileTools()
        .renameServerOwnedProfile(LunaProfile.get('Tailarr'), 'Living Room');
    // Escalates to the tailnet-disambiguated name rather than clobbering.
    expect(target, 'Living Room (tail95fc29)');
    expect(LunaBox.profiles.contains('Living Room'), isTrue);
    expect(LunaBox.profiles.read('Living Room')!.serverOwned, isFalse);
    expect(LunaBox.profiles.contains('Living Room (tail95fc29)'), isTrue);
  });

  testWidgets('rename is a no-op when the name already matches', (t) async {
    await reset();
    const host = 'https://tailarr.tail95fc29.ts.net';
    await seed('Living Room', host);

    final target = await LunaProfileTools().renameServerOwnedProfile(
        LunaProfile.get('Living Room'), 'Living Room');
    expect(target, isNull);
    expect(LunaBox.profiles.contains('Living Room'), isTrue);
  });

  testWidgets('a non-server-owned profile is never renamed', (t) async {
    await reset();
    await LunaBox.profiles.update('Mine', LunaProfile()); // serverOwned=false
    LunaSeaDatabase.ENABLED_PROFILE.update('Mine');

    final target = await LunaProfileTools()
        .renameServerOwnedProfile(LunaProfile.get('Mine'), 'Renamed');
    expect(target, isNull);
    expect(LunaBox.profiles.contains('Mine'), isTrue);
    expect(LunaBox.profiles.contains('Renamed'), isFalse);
  });
}
