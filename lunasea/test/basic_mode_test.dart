import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/router/router.dart';

/// Locks the Basic-mode Settings guard: for a Basic (server-tagged) person the
/// ENTIRE /settings surface must be unreachable — not just the drawer gear —
/// including deep-linked subroutes, while a normal person is never blocked.
void main() {
  group('basicBlocksSettingsRoute', () {
    test('non-basic person is never blocked', () {
      expect(
        basicBlocksSettingsRoute('/settings', uiHidesSettings: false),
        isFalse,
      );
      expect(
        basicBlocksSettingsRoute('/settings/configuration/general',
            uiHidesSettings: false),
        isFalse,
      );
    });

    test('basic person is blocked from the settings root', () {
      expect(
        basicBlocksSettingsRoute('/settings', uiHidesSettings: true),
        isTrue,
      );
    });

    test('basic person is blocked from a deep-linked settings subroute', () {
      // The whole point: hiding the gear is not enough — a deep link must be
      // caught too.
      expect(
        basicBlocksSettingsRoute('/settings/configuration/general',
            uiHidesSettings: true),
        isTrue,
      );
      expect(
        basicBlocksSettingsRoute('/settings/profiles', uiHidesSettings: true),
        isTrue,
      );
    });

    test('basic person is NOT blocked from non-settings routes', () {
      expect(basicBlocksSettingsRoute('/', uiHidesSettings: true), isFalse);
      expect(
        basicBlocksSettingsRoute('/sonarr', uiHidesSettings: true),
        isFalse,
      );
      // A path that merely starts with the word "settings" but isn't the
      // settings tree must not be swept up.
      expect(
        basicBlocksSettingsRoute('/settings-export', uiHidesSettings: true),
        isFalse,
      );
    });
  });
}
