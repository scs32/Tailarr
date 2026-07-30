// API-client-layer verification for the hand-written dio gateway client
// (NtfyGatewayClient) and the ntfy feed client (NtfyClient).
//
// The migration regenerated every dio client; these tests pin the request
// SHAPING (path, method, body, query, auth header) and response PARSING of the
// self-service endpoints that jellyfin_test does not already cover —
// self/notifications, self/services, self/push-token, and the ntfy poll feed —
// driven with a fake Dio adapter (no gateway, no Tailscale, no Hive).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/api/ntfy/models.dart';
import 'package:lunasea/api/ntfy/ntfy.dart';

/// Records the last request and replies with a canned body + status.
class _CaptureAdapter implements HttpClientAdapter {
  _CaptureAdapter({required this.body, this.status = 200, this.json = true});

  final String body;
  final int status;
  final bool json;

  String? lastPath;
  String? lastMethod;
  Map<String, dynamic>? lastQuery;
  Map<String, dynamic>? lastBody;
  Map<String, List<String>> lastHeaders = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    lastMethod = options.method;
    lastQuery = Map<String, dynamic>.from(options.queryParameters);
    lastHeaders = options.headers.map(
      (k, v) => MapEntry(k, [v.toString()]),
    );
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

NtfyGatewayClient _gatewayWith(_CaptureAdapter adapter) {
  final client = NtfyGatewayClient(host: 'tailarr-gate.taila06ea9.ts.net');
  client.httpClient.httpClientAdapter = adapter;
  return client;
}

NtfyClient _feedWith(_CaptureAdapter adapter, NtfySubscription sub) {
  final client = NtfyClient(sub);
  client.httpClient.httpClientAdapter = adapter;
  return client;
}

void main() {
  group('NtfyGatewayClient.selfNotifications', () {
    test('GETs self/notifications and parses credentials', () async {
      final adapter = _CaptureAdapter(
        body: json.encode({
          'ok': true,
          'url': 'https://ntfy.ts.net/',
          'user': 'alice',
          'password': 'pw',
          'token': 'tk_abc',
          'topics': ['tlr-ops', 'tlr-media-sonarr'],
        }),
      );
      final creds = await _gatewayWith(adapter).selfNotifications();

      expect(adapter.lastMethod, 'GET');
      expect(adapter.lastPath, 'self/notifications');
      expect(creds.ok, isTrue);
      expect(creds.token, 'tk_abc');
      // Trailing slash on the url is normalized away.
      expect(creds.url, 'https://ntfy.ts.net');
      expect(creds.topics, ['tlr-ops', 'tlr-media-sonarr']);
      expect(creds.statusCode, 200);
    });

    test('a whois refusal is parsed as unassigned, not thrown', () async {
      final adapter = _CaptureAdapter(
        body: json.encode({'ok': false, 'error': 'Device not assigned.'}),
        status: 400,
      );
      final creds = await _gatewayWith(adapter).selfNotifications();
      expect(creds.ok, isFalse);
      expect(creds.isUnassigned, isTrue);
    });
  });

  group('NtfyGatewayClient.selfServices', () {
    test('GETs self/services and parses the services payload', () async {
      final adapter = _CaptureAdapter(
        body: json.encode({
          'ok': true,
          'kind': 'services',
          'services': [
            {
              'type': 'sonarr',
              'name': 'sonarr',
              'url': 'https://sonarr.ts.net',
              'auth': {'api_key': 'k'},
            },
          ],
        }),
      );
      final res = await _gatewayWith(adapter).selfServices();

      expect(adapter.lastMethod, 'GET');
      expect(adapter.lastPath, 'self/services');
      expect(res.isSupported, isTrue);
      expect(res.services, hasLength(1));
      expect(res.services!.first.apiKey, 'k');
      expect(res.isUnavailable, isFalse);
    });
  });

  group('NtfyGatewayClient.selfPushToken', () {
    test('POSTs self/push-token with a register body', () async {
      final adapter = _CaptureAdapter(
        body: json.encode({'ok': true, 'registered': true, 'count': 2}),
      );
      final res = await _gatewayWith(adapter).selfPushToken(
        token: 'APNS_TOKEN',
        sandbox: true,
      );

      expect(adapter.lastMethod, 'POST');
      expect(adapter.lastPath, 'self/push-token');
      expect(adapter.lastBody, {
        'token': 'APNS_TOKEN',
        'sandbox': true,
        'do': 'register',
      });
      expect(res.ok, isTrue);
      expect(res.registered, isTrue);
      expect(res.count, 2);
    });

    test('register:false shapes an unregister body', () async {
      final adapter = _CaptureAdapter(
        body: json.encode({'ok': true, 'registered': false, 'count': 0}),
      );
      await _gatewayWith(adapter).selfPushToken(
        token: 'APNS_TOKEN',
        sandbox: false,
        register: false,
      );
      expect(adapter.lastBody, {
        'token': 'APNS_TOKEN',
        'sandbox': false,
        'do': 'unregister',
      });
    });

    test('a pre-0.26.0 gateway non-JSON 404 reads as unavailable, not a throw',
        () async {
      final adapter = _CaptureAdapter(
        body: '<html>Not Found</html>',
        status: 404,
        json: false,
      );
      final res = await _gatewayWith(adapter).selfPushToken(
        token: 't',
        sandbox: true,
      );
      expect(res.ok, isFalse);
      expect(res.isUnavailable, isTrue);
    });
  });

  group('NtfyClient.poll', () {
    final sub = NtfySubscription(
      url: 'https://ntfy.ts.net',
      token: 'tk_secret',
      topics: const ['tlr-ops', 'tlr-media-sonarr'],
    );

    test('shapes the comma-joined topic feed request with poll+since',
        () async {
      final adapter = _CaptureAdapter(body: '', json: false);
      await _feedWith(adapter, sub).poll(since: 'all');

      expect(adapter.lastMethod, 'GET');
      expect(adapter.lastPath, 'tlr-ops,tlr-media-sonarr/json');
      expect(adapter.lastQuery, {'poll': '1', 'since': 'all'});
      // The subscription token rides as a bearer credential.
      final auth = adapter.lastHeaders['Authorization']?.first ?? '';
      expect(auth, 'Bearer tk_secret');
    });

    test('returns only message events, dropping keepalive/open lines',
        () async {
      final feed = [
        json.encode({'id': '1', 'event': 'open', 'topic': 'tlr-ops'}),
        json.encode({
          'id': '2',
          'event': 'message',
          'topic': 'tlr-media-sonarr',
          'time': 100,
          'message': 'Grabbed',
        }),
        json.encode({'id': '3', 'event': 'keepalive', 'topic': 'tlr-ops'}),
        '', // blank line
        'not json', // broken line
      ].join('\n');
      final adapter = _CaptureAdapter(body: feed, json: false);

      final messages = await _feedWith(adapter, sub).poll();
      expect(messages, hasLength(1));
      expect(messages.single.id, '2');
      expect(messages.single.message, 'Grabbed');
    });
  });
}
