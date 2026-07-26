// The per-person Jellyfin self-service contract (server release 2+): models
// parse the frozen /self/jellyfin/* shapes, availability helpers decide when
// the module hides, and the gateway client hits the right paths/methods.
//
// Driven with a fake Dio adapter — no gateway, no Tailscale, no Hive.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/api/jellyfin/models.dart';
import 'package:lunasea/api/ntfy/ntfy.dart';

/// Records the last request and replies with a canned JSON body + status.
class _CaptureAdapter implements HttpClientAdapter {
  _CaptureAdapter({required this.body, this.status = 200, this.json = true});

  final String body;
  final int status;
  final bool json;

  String? lastPath;
  String? lastMethod;
  Map<String, dynamic>? lastBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    lastMethod = options.method;
    if (requestStream != null) {
      final chunks = await requestStream.toList();
      final bytes = chunks.expand((c) => c).toList();
      if (bytes.isNotEmpty) {
        lastBody = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      }
    }
    return ResponseBody.fromString(
      body,
      status,
      headers: json
          ? {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            }
          : {},
    );
  }

  @override
  void close({bool force = false}) {}
}

NtfyGatewayClient _clientWith(_CaptureAdapter adapter) {
  final client = NtfyGatewayClient(host: 'tailarr-gate.taila06ea9.ts.net');
  client.httpClient.httpClientAdapter = adapter;
  return client;
}

void main() {
  group('JellyfinSelf.fromJson', () {
    test('parses the full available payload', () {
      final self = JellyfinSelf.fromJson({
        'ok': true,
        'url': 'https://jellyfin.taila06ea9.ts.net/',
        'username': 'stephen',
        'has_password': true,
        'quick_connect_enabled': true,
        'libraries': [
          {'id': 'movies', 'name': 'Movies'},
          {'id': 'shows', 'name': 'TV Shows'},
        ],
      }, statusCode: 200);

      expect(self.ok, isTrue);
      expect(self.isAvailable, isTrue);
      // Trailing slash trimmed like the other gateway URL fields.
      expect(self.url, 'https://jellyfin.taila06ea9.ts.net');
      expect(self.username, 'stephen');
      expect(self.hasPassword, isTrue);
      expect(self.quickConnectEnabled, isTrue);
      expect(self.libraries.map((l) => l.name), ['Movies', 'TV Shows']);
      expect(self.libraries.first.id, 'movies');
    });

    test('stopped pod: ok with empty url, still available', () {
      final self = JellyfinSelf.fromJson(
        {'ok': true, 'url': '', 'username': 'stephen'},
        statusCode: 200,
      );
      expect(self.isAvailable, isTrue);
      expect(self.url, isEmpty);
    });

    test('old server ("unknown request") reads as unavailable', () {
      final self = JellyfinSelf.fromJson(
        {'ok': false, 'error': 'unknown request'},
        statusCode: 200,
      );
      expect(self.isAvailable, isFalse);
      expect(self.isUnavailable, isTrue);
      expect(self.hasNoAccess, isFalse);
    });

    test('404 reads as unavailable', () {
      final self = JellyfinSelf.fromJson({'ok': false}, statusCode: 404);
      expect(self.isUnavailable, isTrue);
    });

    test('no Jellyfin badge reads as no-access', () {
      final self = JellyfinSelf.fromJson(
        {'ok': false, 'error': 'no Jellyfin access'},
        statusCode: 200,
      );
      expect(self.isAvailable, isFalse);
      expect(self.hasNoAccess, isTrue);
      expect(self.isUnavailable, isFalse);
    });

    test('unassigned device is distinguished from no-access', () {
      final self = JellyfinSelf.fromJson(
        {'ok': false, 'error': 'device not assigned to a user'},
        statusCode: 200,
      );
      expect(self.isUnassigned, isTrue);
      expect(self.isAvailable, isFalse);
    });
  });

  group('JellyfinDevices.fromJson', () {
    test('parses the devices list with a unix-timestamp last_active', () {
      final devices = JellyfinDevices.fromJson({
        'ok': true,
        'devices': [
          {
            'id': 'd1',
            'name': 'Living Room TV',
            'client': 'Jellyfin Android TV',
            'last_active': 1753437600,
          },
        ],
      }, statusCode: 200);
      expect(devices.ok, isTrue);
      expect(devices.devices, hasLength(1));
      final device = devices.devices.first;
      expect(device.name, 'Living Room TV');
      expect(device.client, 'Jellyfin Android TV');
      expect(device.lastActiveEpoch, 1753437600);
      expect(device.lastActiveAt,
          DateTime.fromMillisecondsSinceEpoch(1753437600 * 1000, isUtc: true));
    });

    test('tolerates a numeric-string last_active and omits it when absent', () {
      final devices = JellyfinDevices.fromJson({
        'ok': true,
        'devices': [
          {'id': 'd1', 'last_active': '1753437600'},
          {'id': 'd2'},
        ],
      }, statusCode: 200);
      expect(devices.devices[0].lastActiveEpoch, 1753437600);
      expect(devices.devices[1].lastActiveEpoch, isNull);
      expect(devices.devices[1].lastActiveAt, isNull);
    });

    test('tolerates a missing devices key', () {
      final devices = JellyfinDevices.fromJson({'ok': true}, statusCode: 200);
      expect(devices.devices, isEmpty);
    });
  });

  group('NtfyGatewayClient jellyfin endpoints', () {
    test('selfJellyfin GETs self/jellyfin and parses', () async {
      final adapter = _CaptureAdapter(
        body: '{"ok":true,"url":"https://jf.ts.net","username":"s",'
            '"has_password":false,"quick_connect_enabled":true,"libraries":[]}',
      );
      final self = await _clientWith(adapter).selfJellyfin();
      expect(adapter.lastMethod, 'GET');
      expect(adapter.lastPath, contains('self/jellyfin'));
      expect(self.isAvailable, isTrue);
      expect(self.username, 's');
    });

    test('selfJellyfin maps a non-JSON 404 to "unknown request"', () async {
      final adapter = _CaptureAdapter(
        body: '<html>not found</html>',
        status: 404,
        json: false,
      );
      final self = await _clientWith(adapter).selfJellyfin();
      expect(self.isUnavailable, isTrue);
      expect(self.error, 'unknown request');
    });

    test('selfJellyfinConnect POSTs the code', () async {
      final adapter = _CaptureAdapter(body: '{"ok":true}');
      final result =
          await _clientWith(adapter).selfJellyfinConnect('ABC123');
      expect(adapter.lastMethod, 'POST');
      expect(adapter.lastPath, contains('self/jellyfin/connect'));
      expect(adapter.lastBody, {'code': 'ABC123'});
      expect(result.ok, isTrue);
    });

    test('selfJellyfinSignout POSTs the device_id', () async {
      final adapter = _CaptureAdapter(body: '{"ok":true}');
      final result = await _clientWith(adapter).selfJellyfinSignout('d1');
      expect(adapter.lastPath, contains('self/jellyfin/signout'));
      expect(adapter.lastBody, {'device_id': 'd1'});
      expect(result.ok, isTrue);
    });

    test('selfJellyfinPassword POSTs the password (empty clears)', () async {
      final adapter = _CaptureAdapter(body: '{"ok":true}');
      await _clientWith(adapter).selfJellyfinPassword('');
      expect(adapter.lastPath, contains('self/jellyfin/password'));
      expect(adapter.lastBody, {'password': ''});
    });

    test('a {ok:false,error} refusal is parsed, not thrown', () async {
      final adapter = _CaptureAdapter(
        body: '{"ok":false,"error":"no Jellyfin access"}',
        status: 403,
      );
      final result = await _clientWith(adapter).selfJellyfinConnect('X');
      expect(result.ok, isFalse);
      expect(result.error, 'no Jellyfin access');
    });
  });
}
