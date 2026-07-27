// Renders the per-person Jellyfin module screen against CANNED data — no
// backend, no tailnet. A fake Dio adapter serves the /self/jellyfin* JSON so
// the whole model→UI path is real; the screen just draws its populated,
// available state. Purely a visual harness (screenshot the sim while it holds):
//
//   flutter test integration_test/jellyfin_demo_test.dart -d <sim-udid>
//
// Set JELLYFIN_DEMO_STATE to pick which state to render:
//   available (default) | no_access | unavailable | stopped
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:lunasea/api/ntfy/ntfy.dart';
import 'package:lunasea/main.dart';
import 'package:lunasea/modules/jellyfin/routes/jellyfin/route.dart';
import 'package:lunasea/system/gateway/gateway_host.dart';
import 'package:lunasea/widgets/ui/theme.dart';

const _state = String.fromEnvironment('JELLYFIN_DEMO_STATE',
    defaultValue: 'available');

/// The populated happy-path account.
final Map<String, dynamic> _selfAvailable = {
  'ok': true,
  'url': 'https://jellyfin.taila06ea9.ts.net',
  'username': 'stephen',
  'has_password': true,
  'quick_connect_enabled': true,
  'libraries': [
    {'id': 'movies', 'name': 'Movies'},
    {'id': 'shows', 'name': 'TV Shows'},
    {'id': 'music', 'name': 'Music'},
  ],
};

final int _now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
final Map<String, dynamic> _devices = {
  'ok': true,
  'devices': [
    {
      'id': 'dev-appletv',
      'name': 'Living Room Apple TV',
      'client': 'Jellyfin for Apple TV',
      'last_active': _now - 2 * 3600, // 2h ago
    },
    {
      'id': 'dev-iphone',
      'name': "Stephen's iPhone",
      'client': 'Jellyfin Mobile',
      'last_active': _now - 20 * 60, // 20m ago
    },
  ],
};

Map<String, dynamic> _selfFor(String state) {
  switch (state) {
    case 'no_access':
      return {'ok': false, 'error': 'no Jellyfin access'};
    case 'unavailable':
      return {'ok': false, 'error': 'unknown request'};
    case 'stopped':
      // ok:true but a stopped pod → url empty, keeps last-known.
      return {..._selfAvailable, 'url': ''};
    case 'available':
    default:
      return _selfAvailable;
  }
}

/// Serves canned JSON for the gateway's self/jellyfin* endpoints.
class _FakeGatewayAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    final path = options.uri.path;
    Map<String, dynamic> body;
    if (path.endsWith('/self/jellyfin/devices')) {
      body = _devices;
    } else if (path.endsWith('/self/jellyfin')) {
      body = _selfFor(_state);
    } else {
      body = {'ok': true};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the Jellyfin module ($_state)', (tester) async {
    await bootstrap();

    debugGatewayClientBuilder = () async {
      final client = NtfyGatewayClient(host: 'demo.tailarr');
      client.httpClient.httpClientAdapter = _FakeGatewayAdapter();
      return client;
    };
    addTearDown(() => debugGatewayClientBuilder = null);

    await tester.pumpWidget(MaterialApp(
      theme: LunaTheme().activeTheme(),
      darkTheme: LunaTheme().activeTheme(),
      home: const JellyfinRoute(),
    ));
    await tester.pumpAndSettle();

    // Sanity: the populated state actually drew.
    if (_state == 'available' || _state == 'stopped') {
      expect(find.text('Account'), findsOneWidget);
      expect(find.text('Sign In a Device'), findsOneWidget);
    }

    // Hold the frame so the sim can be screenshotted from the shell.
    debugPrint('JELLYFIN_DEMO_READY state=$_state');
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
  });
}
