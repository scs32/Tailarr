// Regression repro for the "Users screen ignores the people model" report:
// serve the EXACT payload captured from the live v0.22.x controller (plus
// unknown extra keys newer servers may add) from an in-process HTTP server,
// point the real module at it, and pump the real UsersRoute. If the decoder
// or fallback detection were too strict, this renders the empty legacy list
// the bug report describes.
//   flutter test integration_test/users_people_render_test.dart -d <sim>
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/main.dart';
import 'package:lunasea/router/router.dart';

// Captured from https://tailarr.tail95fc29.ts.net (server v0.22.x),
// trimmed to the reported entries; "gateway"/"schema_hint" simulate keys
// added after build 11's contract — decoding must tolerate them.
const _livePayload = '''
{
  "configured": true,
  "error": null,
  "ntfy": true,
  "gateway": true,
  "schema_hint": {"future": ["unknown", "keys"]},
  "people": [
    {"id": "aa11", "name": "Keith", "badges": ["radarr", "sonarr"],
     "created": 1784000000, "devices": []},
    {"id": "bb22", "name": "Lindsay", "badges": ["sonarr"],
     "created": 1784000001, "devices": [
       {"id": "nLIND1", "hostname": "tailarr-app", "nickname": "",
        "os": "iOS", "last_seen": "2026-07-22T20:00:00Z",
        "ip": "100.101.102.103", "can": ["sonarr"]}]},
    {"id": "cc33", "name": "Stephen",
     "badges": ["jellyfin", "nzbget", "plex", "radarr", "server", "sonarr"],
     "created": 1784000002, "devices": [
       {"id": "nSTEV1", "hostname": "tailarr-app-Mini-VM-r03c3u",
        "nickname": "", "os": "iOS", "last_seen": "",
        "ip": "", "can": ["jellyfin", "nzbget", "plex", "radarr",
                          "server", "sonarr"]}]}
  ],
  "users": [],
  "services": ["jellyfin", "nzbget", "plex", "radarr", "sonarr", "server"]
}
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('live v0.22 payload renders three person cards',
      (tester) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        request.uri.path == '/api/users' ? _livePayload : '{}',
      );
      await request.response.close();
    });

    await bootstrap();
    final profile = LunaProfile.current;
    profile.tailscaleEnabled = false;
    profile.tailarrServerEnabled = true;
    profile.tailarrServerHost = 'http://127.0.0.1:${server.port}';
    await LunaBox.profiles.update(LunaProfile.DEFAULT_PROFILE, profile);

    // Full app shell — LunaButton and the routes need the real router.
    await tester.pumpWidget(const LunaBIOS());
    await tester.pump(const Duration(seconds: 1));
    LunaRouter.router.go('/tailarr_server/users');
    // Let the fetch + render settle.
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.text('Keith', findRichText: true).evaluate().isNotEmpty) break;
    }

    // The person-centric view — NOT the legacy list, NOT an empty state.
    expect(find.text('Keith', findRichText: true), findsOneWidget);
    expect(find.text('Lindsay', findRichText: true), findsOneWidget);
    expect(find.text('Stephen', findRichText: true), findsOneWidget);
    expect(find.textContaining('radarr', findRichText: true), findsWidgets);
    expect(find.text('No User Devices Found'), findsNothing);
    expect(find.text('No Users Found'), findsNothing);
    // users:[] and people present → no unassigned section.
    expect(find.text('Unassigned Devices', findRichText: true), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await server.close(force: true);
  });
}
