// The Notifications inbox rendered against seeded Hive data — populated
// list (topic labels, priority tints, mark-as-read) and the two empty
// states. No network needed:
//   flutter test integration_test/notifications_inbox_test.dart -d <sim-udid>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:lunasea/database/box.dart';
import 'package:lunasea/database/models/notification.dart';
import 'package:lunasea/database/tables/notifications.dart';
import 'package:lunasea/main.dart';
import 'package:lunasea/modules/notifications/routes/notifications/route.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpInbox(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: NotificationsRoute()));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> disposePage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('renders seeded messages with topic labels and marks them read',
      (tester) async {
    await bootstrap();
    await LunaBox.notifications.clear();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await LunaBox.notifications.update(
      'msg-ops',
      LunaNotification(
        id: 'msg-ops',
        time: now - 60,
        topic: 'tlr-ops',
        title: 'Update Available',
        body: 'sonarr has a new image available',
        priority: 4,
      ),
    );
    await LunaBox.notifications.update(
      'msg-sonarr',
      LunaNotification(
        id: 'msg-sonarr',
        time: now - 3600,
        topic: 'tlr-media-sonarr',
        title: 'Episode Downloaded',
        body: 'Severance S02E01',
      ),
    );
    await LunaBox.notifications.update(
      'msg-untitled',
      LunaNotification(
        id: 'msg-untitled',
        time: now - 7200,
        topic: 'tlr-media-radarr',
        body: 'Dune Part Two imported',
      ),
    );

    await pumpInbox(tester);

    expect(find.text('Update Available', findRichText: true), findsOneWidget);
    expect(find.text('sonarr has a new image available', findRichText: true),
        findsOneWidget);
    // The topic label shares one RichText line with the bullet + age.
    expect(
        find.textContaining('Server', findRichText: true), findsOneWidget);
    expect(
        find.text('Episode Downloaded', findRichText: true), findsOneWidget);
    expect(
        find.textContaining('Sonarr', findRichText: true), findsOneWidget);
    // A message with no title falls back to its topic label — Radarr shows
    // as the tile title AND inside the body line.
    expect(find.textContaining('Radarr', findRichText: true), findsWidgets);

    // Opening the inbox marks everything read.
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      LunaBox.notifications.data.every((n) => n.read),
      isTrue,
    );

    await disposePage(tester);
    await LunaBox.notifications.clear();
  });

  testWidgets('renders the unconfigured empty state', (tester) async {
    await LunaBox.notifications.clear();
    NotificationsDatabase.URL.update('');

    await pumpInbox(tester);
    expect(
      find.text('Notifications Are Not Set Up', findRichText: true),
      findsOneWidget,
    );
    // The empty state links to the setup surface — as "Set Up
    // Notifications", or "Automatic Setup Failed" if the opportunistic
    // gateway attempt already ran (no gateway in the test environment).
    final linksToSetup = find
            .text('Set Up Notifications', findRichText: true)
            .evaluate()
            .isNotEmpty ||
        find
            .text('Automatic Setup Failed', findRichText: true)
            .evaluate()
            .isNotEmpty;
    expect(linksToSetup, isTrue);

    await disposePage(tester);
  });

  testWidgets('renders the configured-but-empty state', (tester) async {
    await LunaBox.notifications.clear();
    NotificationsDatabase.URL.update('https://ntfy.example.ts.net');

    await pumpInbox(tester);
    expect(find.text('No Notifications', findRichText: true), findsOneWidget);

    NotificationsDatabase.URL.update('');
    await disposePage(tester);
  });
}
