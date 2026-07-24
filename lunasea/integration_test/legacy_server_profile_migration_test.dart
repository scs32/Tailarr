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

  testWidgets('a custom-named legacy profile is marked owned, not renamed',
      (tester) async {
    await ensureBooted();

    // A user's meaningfully-named server profile (predating the feature and
    // the gateway-managed marker) is marked owned but keeps its name.
    await LunaBox.profiles.update(
      'Apple Container',
      LunaProfile(
        tailscaleEnabled: true,
        tailscaleIdentity: 'apple-container',
        tailarrServerEnabled: true,
        tailarrServerHost: 'https://tailarr.tail95fc29.ts.net',
      ),
    );

    LunaDatabase().migrateLegacyServerProfiles();

    expect(LunaProfile.list, contains('Apple Container'));
    expect(LunaBox.profiles.read('Apple Container')!.serverOwned, isTrue);
  });

  testWidgets('detection no longer requires the gateway-managed marker',
      (tester) async {
    await ensureBooted();

    // Older invite: server host + Tailscale enrolled, but no 'tailarr' in
    // gatewayManagedModules (that tracking came later). Still converted.
    await LunaBox.profiles.update(
      LunaProfile.DEFAULT_PROFILE,
      LunaProfile(
        tailscaleEnabled: true,
        tailscaleIdentity: 'default',
        tailarrServerEnabled: true,
        tailarrServerHost: 'https://tailarr.tail95fc29.ts.net',
      ),
    );
    LunaSeaDatabase.ENABLED_PROFILE.update(LunaProfile.DEFAULT_PROFILE);

    LunaDatabase().migrateLegacyServerProfiles();

    expect(LunaProfile.list, contains('Tailarr'));
    expect(LunaProfile.list, isNot(contains('default')));
    expect(LunaBox.profiles.read('Tailarr')!.serverOwned, isTrue);
  });
}
