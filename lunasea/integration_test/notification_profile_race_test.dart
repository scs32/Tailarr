// L5: a notification that lands the instant the user switches profiles must be
// filed under the profile its STREAM belongs to, not whatever profile is active
// when the message is stored. NtfySync.storeMessages now pins to a caller-
// supplied profile (captured at stream-connect), mirroring the dismissal-race
// fix. This locks that a stream message for server A is never mis-filed under a
// now-active server B:
//   flutter test integration_test/notification_profile_race_test.dart -d <udid>
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:lunasea/api/ntfy/models.dart';
import 'package:lunasea/database/box.dart';
import 'package:lunasea/database/models/notification.dart';
import 'package:lunasea/database/tables/lunasea.dart';
import 'package:lunasea/main.dart';
import 'package:lunasea/system/notifications/platform/ntfy_io.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a stream message is filed under its own profile, not the '
      'newly-active one', (tester) async {
    await bootstrap();
    await LunaBox.notifications.clear();

    // Stream was opened for server A; the user has since switched to server B.
    LunaSeaDatabase.ENABLED_PROFILE.update('ServerB');

    final message = NtfyMessage(
      id: 'race-1',
      time: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      event: 'message',
      topic: 'tlr-media-sonarr',
      title: 'Episode Downloaded',
      message: 'landed mid-switch',
    );

    // Pinned to the stream's profile (ServerA) — the L5 fix.
    await NtfySync.storeMessages([message], profile: 'ServerA');

    expect(
      LunaBox.notifications.contains(LunaNotification.boxKey('ServerA', 'race-1')),
      isTrue,
      reason: 'filed under the stream owner (ServerA)',
    );
    expect(
      LunaBox.notifications.contains(LunaNotification.boxKey('ServerB', 'race-1')),
      isFalse,
      reason: 'never mis-filed under the newly-active ServerB',
    );
    final stored = LunaBox.notifications.data
        .firstWhere((n) => n.id == 'race-1');
    expect(stored.profile, 'ServerA');

    await LunaBox.notifications.clear();
  });

  testWidgets('falls back to the active profile when the caller pins none',
      (tester) async {
    await bootstrap();
    await LunaBox.notifications.clear();
    LunaSeaDatabase.ENABLED_PROFILE.update('ServerB');

    final message = NtfyMessage(
      id: 'fallback-1',
      time: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      event: 'message',
      topic: 'tlr-ops',
      message: 'no pin',
    );
    await NtfySync.storeMessages([message]);

    expect(
      LunaBox.notifications
          .contains(LunaNotification.boxKey('ServerB', 'fallback-1')),
      isTrue,
    );

    await LunaBox.notifications.clear();
  });
}
