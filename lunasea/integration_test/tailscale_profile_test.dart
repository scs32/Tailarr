// Per-profile Tailscale: the global→profile migration and the identity
// generator. Runs on-device/simulator (real Hive), no network needed:
//   flutter test integration_test/tailscale_profile_test.dart -d <sim-udid>
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/database/database.dart';
import 'package:lunasea/main.dart';
import 'package:lunasea/utils/profile_tools.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('global tailscale settings migrate onto the enabled profile',
      (tester) async {
    await bootstrap();

    // Seed the pre-per-profile layout: settings in the global table.
    LunaSeaDatabase.TAILSCALE_ENABLED.update(true);
    LunaSeaDatabase.TAILSCALE_AUTH_KEY.update('tskey-auth-legacy');

    LunaDatabase().migrateGlobalTailscaleToProfile();

    final profile = LunaProfile.current;
    expect(profile.tailscaleEnabled, isTrue);
    expect(profile.tailscaleAuthKey, 'tskey-auth-legacy');
    // 'default' is where tailscale_embed migrates the legacy node state,
    // so the migrated profile must own exactly that identity.
    expect(profile.tailscaleIdentity, 'default');

    // Globals are cleared so the migration can never run twice.
    expect(LunaSeaDatabase.TAILSCALE_ENABLED.read(), isFalse);
    expect(LunaSeaDatabase.TAILSCALE_AUTH_KEY.read(), isEmpty);

    // Second run is a no-op — the profile keeps its values.
    profile.tailscaleAuthKey = 'tskey-auth-newer';
    profile.save();
    LunaDatabase().migrateGlobalTailscaleToProfile();
    expect(LunaProfile.current.tailscaleAuthKey, 'tskey-auth-newer');
    expect(LunaProfile.current.tailscaleIdentity, 'default');
  });

  testWidgets('identity generator emits valid, unique names',
      (tester) async {
    final pattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
    for (final name in [
      'default',
      'Home Server!',
      '   ',
      '!!!',
      'ünïcödé',
      'a-very-long-profile-name-that-goes-on-and-on-forever',
    ]) {
      final identity = LunaProfileTools.generateTailscaleIdentity(name);
      expect(pattern.hasMatch(identity), isTrue,
          reason: '"$name" -> "$identity"');
    }

    // The random suffix keeps identical profile names distinct.
    final a = LunaProfileTools.generateTailscaleIdentity('Test');
    final b = LunaProfileTools.generateTailscaleIdentity('Test');
    expect(a, isNot(b));
  });
}
