// The demo Exit path. Locks the bug this fixes: leaveDemo() must remove the
// demo profile and return the app to the first-run state (so the router / the
// explicit banner nav sends to /landing) — EVEN when the node/ntfy side-effects
// throw, which they do in this harness. Previously `_changeTo`'s channel calls
// threw after switching but before the demo profile was removed, stranding it
// so the landing never showed on exit.
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

  testWidgets('exit demo returns the app to the first-run state',
      (tester) async {
    await bootstrap();

    // Clean slate: only a pristine default (a genuine fresh install).
    for (final k in LunaBox.profiles.keys.toList()) {
      await LunaBox.profiles.delete(k);
    }
    await LunaBox.profiles.update(LunaProfile.DEFAULT_PROFILE, LunaProfile());
    LunaSeaDatabase.ENABLED_PROFILE.update(LunaProfile.DEFAULT_PROFILE);
    expect(LunaProfileTools.isFirstRun(), isTrue, reason: 'fresh → landing');

    // Enter demo (direct box write, matching enterDemo without the channels).
    await LunaBox.profiles.update(DemoMode.profileName, DemoMode.build());
    LunaSeaDatabase.ENABLED_PROFILE.update(DemoMode.profileName);
    expect(DemoMode.active, isTrue);
    expect(LunaProfileTools.isFirstRun(), isFalse, reason: 'demo configured');

    // Exit — the fix: demo profile removed unconditionally, side-effects
    // best-effort, so isFirstRun flips back to true and the app returns to the
    // landing.
    await LunaProfileTools().leaveDemo();
    expect(DemoMode.active, isFalse);
    expect(LunaBox.profiles.keys, isNot(contains(DemoMode.profileName)),
        reason: 'demo profile deleted');
    expect(LunaProfileTools.isFirstRun(), isTrue,
        reason: 'back to first-run → /landing');
  });
}
