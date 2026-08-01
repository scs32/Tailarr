// Regression coverage for two TestFlight-reported app defects:
//
//   B28 — the Jellyfin module screen showed a dead back arrow (it pops nothing,
//         because top-level modules are launched via pushReplacement) instead
//         of the drawer hamburger every other module uses. The fix was
//         `useDrawer: true` on its LunaAppBar; these tests lock the app-bar
//         contract so the dead-arrow trap can't silently return.
//
//   B29 — the "Pro Mode Coming Soon" dialog's confirm button rendered the raw
//         i18n key `lunasea.OK` because the key was missing from the source
//         localization. The fix added the entry; this test asserts it resolves
//         so a future edit can't drop it again.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/widgets/ui/appbar.dart';

void main() {
  // ---- B28: Jellyfin (and every top-level module) app-bar leading ----------
  //
  // The invariant the Jellyfin fix relies on: `useDrawer: true` renders the
  // drawer menu button and NEVER an app back arrow (which would be dead on a
  // pushReplacement'd root). `useDrawer: false` still yields the back arrow for
  // genuine pushed sub-routes.
  group('B28 LunaAppBar leading', () {
    Widget host(Widget appBar) => MaterialApp(
          home: Scaffold(
            appBar: appBar as PreferredSizeWidget,
            drawer: const Drawer(),
            body: const SizedBox.shrink(),
          ),
        );

    testWidgets('useDrawer: true shows the menu button, not a back arrow',
        (tester) async {
      await tester.pumpWidget(
        host(LunaAppBar(title: 'Jellyfin', useDrawer: true)),
      );

      expect(find.byIcon(Icons.menu_rounded), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsNothing);
    });

    testWidgets('useDrawer: false shows a back arrow (pushed sub-routes)',
        (tester) async {
      await tester.pumpWidget(
        host(LunaAppBar(title: 'Detail', useDrawer: false)),
      );

      expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
      expect(find.byIcon(Icons.menu_rounded), findsNothing);
    });
  });

  // ---- B29: the general "OK" key resolves ----------------------------------
  //
  // The dialog builds its confirm button with `'lunasea.OK'.tr()`. easy_localization
  // returns the raw key when it is absent, which is exactly what the reporter
  // saw. Guard the source localization so the entry can't go missing again.
  group('B29 localization', () {
    test('lunasea.OK exists in en.json and maps to "OK"', () {
      final file = File('assets/localization/en.json');
      expect(file.existsSync(), isTrue,
          reason: 'en.json localization source must exist');

      final map = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(map['lunasea.OK'], 'OK',
          reason: 'the confirm-button key used by the Pro Mode dialog');
    });
  });
}
