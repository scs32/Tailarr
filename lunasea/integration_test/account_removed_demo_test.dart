// APP-7: when the person a server-owned profile belongs to is removed from the
// server entirely (the gateway answers "Unknown user."), the app must fall back
// to the safe no-server DEMO preview instead of leaving a broken/stale server
// session behind. Locks fallbackToDemoOnAccountRemoved(): the dead server
// profile is removed and the demo profile becomes active — EVEN when the
// node/ntfy side-effects throw, which they do in this harness.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:lunasea/database/box.dart';
import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/database/tables/lunasea.dart';
import 'package:lunasea/main.dart';
import 'package:lunasea/system/demo/demo.dart';
import 'package:lunasea/utils/profile_tools.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('account removed → server profile drops into demo mode',
      (tester) async {
    await bootstrap();

    // Clean slate, then a single active server-owned profile (an invite-joined
    // device whose account still exists at join time).
    for (final k in LunaBox.profiles.keys.toList()) {
      await LunaBox.profiles.delete(k);
    }
    const server = 'Tailarr';
    await LunaBox.profiles.update(
      server,
      LunaProfile(serverOwned: true, tailarrServerHost: 'https://t.x.ts.net'),
    );
    LunaSeaDatabase.ENABLED_PROFILE.update(server);
    expect(LunaProfileTools.isFirstRun(), isFalse, reason: 'server configured');
    expect(DemoMode.active, isFalse);

    // The account is removed server-side → the app falls back to demo.
    final ran = await LunaProfileTools().fallbackToDemoOnAccountRemoved();
    expect(ran, isTrue);

    // The dead server profile is gone and the demo profile is active.
    expect(LunaBox.profiles.keys, isNot(contains(server)),
        reason: 'dead server profile removed');
    expect(DemoMode.active, isTrue, reason: 'now in the safe demo preview');
  });

  testWidgets('no-op when the active profile is not server-owned',
      (tester) async {
    await bootstrap();

    for (final k in LunaBox.profiles.keys.toList()) {
      await LunaBox.profiles.delete(k);
    }
    // A standalone (non-server) profile must never be dropped to demo.
    await LunaBox.profiles.update(LunaProfile.DEFAULT_PROFILE, LunaProfile());
    LunaSeaDatabase.ENABLED_PROFILE.update(LunaProfile.DEFAULT_PROFILE);

    final ran = await LunaProfileTools().fallbackToDemoOnAccountRemoved();
    expect(ran, isFalse);
    expect(DemoMode.active, isFalse);
    expect(LunaBox.profiles.keys, contains(LunaProfile.DEFAULT_PROFILE));
  });
}
