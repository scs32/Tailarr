// Request-only module UX: a server-driven auto-config member WITHOUT the
// server badge must not see raw service-admin affordances. The connection
// screens already hide host/API-key/connection-details via
// ServerDrivenConnection (see server_driven_connection_test.dart); this locks
// the remaining leak — the arr modules' global-settings menu still offered
// "View Web GUI" (SonarrGlobalSettingsType.WEB_GUI / RadarrGlobalSettingsType
// .WEB_GUI) to badge-less members. TestFlight 2026-07-24: "I don't have server
// creds for this app so I should see 'request'" (on the Sonarr module screen).
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/modules/sonarr/core/dialogs.dart';
import 'package:lunasea/modules/sonarr/core/types/settings_global.dart';
import 'package:lunasea/modules/radarr/core/dialogs.dart';
import 'package:lunasea/modules/radarr/core/types/settings_global.dart';

void main() {
  group('SonarrDialogs.globalSettingsOptions', () {
    test('badge-less server member → "View Web GUI" is hidden', () {
      final options =
          SonarrDialogs.globalSettingsOptions(hidesRawServiceAdmin: true);
      expect(options.contains(SonarrGlobalSettingsType.WEB_GUI), isFalse);
      // The non-admin actions remain available.
      expect(options.contains(SonarrGlobalSettingsType.SEARCH_ALL_MISSING),
          isTrue);
    });

    test('admin / standalone → "View Web GUI" is shown', () {
      final options =
          SonarrDialogs.globalSettingsOptions(hidesRawServiceAdmin: false);
      expect(options, equals(SonarrGlobalSettingsType.values));
      expect(options.contains(SonarrGlobalSettingsType.WEB_GUI), isTrue);
    });
  });

  group('RadarrDialogs.globalSettingsOptions', () {
    test('badge-less server member → "View Web GUI" is hidden', () {
      final options =
          RadarrDialogs.globalSettingsOptions(hidesRawServiceAdmin: true);
      expect(options.contains(RadarrGlobalSettingsType.WEB_GUI), isFalse);
    });

    test('admin / standalone → "View Web GUI" is shown', () {
      final options =
          RadarrDialogs.globalSettingsOptions(hidesRawServiceAdmin: false);
      expect(options, equals(RadarrGlobalSettingsType.values));
      expect(options.contains(RadarrGlobalSettingsType.WEB_GUI), isTrue);
    });
  });
}
