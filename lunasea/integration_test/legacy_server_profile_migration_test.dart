// The one-time migration that converts pre-feature invite profiles into
// named, server-owned profiles. Real Hive on a simulator:
//   flutter test integration_test/legacy_server_profile_migration_test.dart -d <sim-udid>
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/database/database.dart';
import 'package:lunasea/database/tables/lunasea.dart';
import 'package:lunasea/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Hive adapters can only register once per process, so bootstrap once;
  // every test then starts from an empty profiles box.
  var booted = false;
  Future<void> ensureBooted() async {
    if (!booted) {
      await bootstrap();
      booted = true;
    }
    await LunaBox.profiles.clear();
  }

  testWidgets('legacy invite profile is renamed and marked server-owned',
      (tester) async {
    await ensureBooted();

    // Seed the pre-feature layout: an invite wrote server-driven config
    // onto 'default' without marking it owned or renaming it.
    final legacy = LunaProfile(
      tailscaleEnabled: true,
      tailscaleIdentity: 'default',
      tailarrServerEnabled: true,
      tailarrServerHost: 'https://tailarr.tail95fc29.ts.net',
      gatewayManagedModules: ['tailarr'],
    );
    await LunaBox.profiles.update(LunaProfile.DEFAULT_PROFILE, legacy);
    LunaSeaDatabase.ENABLED_PROFILE.update(LunaProfile.DEFAULT_PROFILE);

    LunaDatabase().migrateLegacyServerProfiles();

    // Renamed to the server-derived name and now active.
    expect(LunaProfile.list, contains('Tailarr'));
    expect(LunaProfile.list, isNot(contains('default')));
    expect(LunaSeaDatabase.ENABLED_PROFILE.read(), 'Tailarr');

    final migrated = LunaBox.profiles.read('Tailarr')!;
    expect(migrated.serverOwned, isTrue);
    // Config + node identity carried over untouched.
    expect(migrated.tailarrServerHost, 'https://tailarr.tail95fc29.ts.net');
    expect(migrated.tailscaleIdentity, 'default');
    expect(migrated.gatewayManagedModules, contains('tailarr'));

    // Idempotent: a second pass is a no-op.
    LunaDatabase().migrateLegacyServerProfiles();
    expect(LunaProfile.list.where((n) => n == 'Tailarr').length, 1);
  });

  testWidgets('a plain profile with no server is left untouched',
      (tester) async {
    await ensureBooted();

    final mine = LunaProfile(
      sonarrEnabled: true,
      sonarrHost: 'https://my-sonarr.local',
      sonarrKey: 'k',
    );
    await LunaBox.profiles.update('My Setup', mine);

    LunaDatabase().migrateLegacyServerProfiles();

    expect(LunaProfile.list, contains('My Setup'));
    expect(LunaBox.profiles.read('My Setup')!.serverOwned, isFalse);
  });

  testWidgets('a profile already named after its server flips in place',
      (tester) async {
    await ensureBooted();

    // A legacy profile that happens to already carry the server's name is
    // just marked owned — never renamed to a deduped variant.
    await LunaBox.profiles.update(
      'Tailarr',
      LunaProfile(
        tailarrServerEnabled: true,
        tailarrServerHost: 'https://tailarr.tail95fc29.ts.net',
        gatewayManagedModules: ['tailarr'],
      ),
    );

    LunaDatabase().migrateLegacyServerProfiles();

    expect(LunaProfile.list, ['Tailarr']);
    expect(LunaBox.profiles.read('Tailarr')!.serverOwned, isTrue);
  });

  testWidgets('a second distinct server coexists with a deduped name',
      (tester) async {
    await ensureBooted();

    // One server already owns "Tailarr"; a legacy profile for a DIFFERENT
    // server is renamed to a distinct deduped name and marked owned.
    await LunaBox.profiles.update(
      'Tailarr',
      LunaProfile(
        serverOwned: true,
        tailarrServerHost: 'https://tailarr.tail95fc29.ts.net',
      ),
    );
    await LunaBox.profiles.update(
      'legacy',
      LunaProfile(
        tailarrServerEnabled: true,
        tailarrServerHost: 'https://tailarr.taila06ea9.ts.net',
        gatewayManagedModules: ['tailarr'],
      ),
    );

    LunaDatabase().migrateLegacyServerProfiles();

    expect(LunaProfile.list, isNot(contains('legacy')));
    expect(LunaProfile.list, contains('Tailarr (taila06ea9)'));
    expect(
      LunaBox.profiles.read('Tailarr (taila06ea9)')!.serverOwned,
      isTrue,
    );
  });
}
