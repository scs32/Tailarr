// Renders the Radarr catalogue in DEMO mode against the bundled fixtures — no
// backend. Proves the DemoAdapter + assets/demo/* drive the real module UI.
// Visual harness (screenshot the sim while it holds):
//   flutter test integration_test/demo_mode_test.dart -d <sim-udid>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:lunasea/database/box.dart';
import 'package:lunasea/database/tables/lunasea.dart';
import 'package:lunasea/main.dart';
import 'package:lunasea/modules/radarr/routes/radarr/route.dart';
import 'package:lunasea/router/router.dart';
import 'package:lunasea/system/demo/demo.dart';
import 'package:lunasea/system/state.dart';
import 'package:lunasea/widgets/ui/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Radarr catalogue renders demo fixtures', (tester) async {
    await bootstrap();
    LunaRouter().initialize();

    // Activate the demo profile directly (skip the channel-driven changeTo).
    await LunaBox.profiles.update(DemoMode.profileName, DemoMode.build());
    LunaSeaDatabase.ENABLED_PROFILE.update(DemoMode.profileName);
    expect(DemoMode.active, isTrue);

    await tester.pumpWidget(
      LunaState.providers(
        child: MaterialApp(
          theme: LunaTheme().activeTheme(),
          darkTheme: LunaTheme().activeTheme(),
          home: const RadarrRoute(),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The Blender open-movie titles from assets/demo/radarr/movies.json.
    expect(find.text('Big Buck Bunny', findRichText: true), findsWidgets);

    debugPrint('DEMO_RADARR_READY');
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
  });
}
