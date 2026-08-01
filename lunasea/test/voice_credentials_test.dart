// Verifies the runtime voice-credential acquisition that keeps the shipping
// build secret-free: the ephemeral-token broker (`POST self/ai/session`) and
// the in-app MCP-token mint (`POST self/ai {do:"token"}`), plus the
// classification/orchestration in [VoiceCredentialBroker].
//
// Driven with a path-routed fake Dio adapter (no gateway, no Tailscale, no
// Hive) — the same technique as gateway_client_request_test.dart, extended to
// answer two different endpoints on one client.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/api/ntfy/ntfy.dart';
import 'package:lunasea/modules/voice/core/voice_credentials.dart';

/// Answers each request from a per-path canned body/status map, recording the
/// method + body seen at every path (so a call that never fires is observable).
class _RouteAdapter implements HttpClientAdapter {
  _RouteAdapter(this.routes);

  /// path -> (statusCode, jsonBody | null for a non-JSON 404 page)
  final Map<String, (int, Map<String, dynamic>?)> routes;

  final List<String> hitPaths = [];
  final Map<String, Map<String, dynamic>?> bodyByPath = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    hitPaths.add(options.path);
    if (requestStream != null) {
      final chunks = await requestStream.toList();
      final bytes = chunks.expand((c) => c).toList();
      bodyByPath[options.path] = bytes.isEmpty
          ? null
          : jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    }
    final route = routes[options.path];
    if (route == null) {
      return ResponseBody.fromString('not found', 404, headers: {});
    }
    final (status, body) = route;
    if (body == null) {
      // A pre-broker gateway answering the POST with an HTML 404 page.
      return ResponseBody.fromString('<html>404</html>', status, headers: {});
    }
    return ResponseBody.fromString(
      json.encode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

NtfyGatewayClient _gatewayWith(_RouteAdapter adapter) {
  final client = NtfyGatewayClient(host: 'tailarr-gate.taila06ea9.ts.net');
  client.httpClient.httpClientAdapter = adapter;
  return client;
}

const _okSession = {
  'ok': true,
  'error': null,
  'provider': 'gemini',
  'model': 'gemini-3.1-flash-live-preview',
  'api_version': 'v1beta',
  'auth': {
    'type': 'ephemeral_token',
    'value': 'auth_tokens/EPHEM-9',
    'expires_at': '2026-08-01T00:00:00Z',
  },
  'mcp_url': 'http://tailarr-mcp.taila06ea9.ts.net:8100/mcp',
};

const _okToken = {
  'ok': true,
  'error': null,
  'id': 't1',
  'token': 'tailarr-mcp-abc123',
  'scopes': ['library.read'],
};

void main() {
  group('NtfyGatewayClient.selfAiSession request shaping + parsing', () {
    test('POSTs self/ai/session and parses the ephemeral descriptor', () async {
      final adapter = _RouteAdapter({'self/ai/session': (200, _okSession)});
      final s = await _gatewayWith(adapter).selfAiSession();

      expect(adapter.hitPaths, contains('self/ai/session'));
      expect(s.isAvailable, isTrue);
      expect(s.ephemeralToken, 'auth_tokens/EPHEM-9');
      expect(s.apiVersion, 'v1beta');
      expect(s.model, 'gemini-3.1-flash-live-preview');
      expect(s.mcpUrl, 'http://tailarr-mcp.taila06ea9.ts.net:8100/mcp');
      // The descriptor never carries a raw key field.
      expect(json.encode(_okSession).contains('api_key'), isFalse);
    });

    test('a no-badge refusal parses as hasNoAccess, not thrown', () async {
      final adapter = _RouteAdapter({
        'self/ai/session':
            (200, {'ok': false, 'error': 'Ask your admin to enable AI access for you.'}),
      });
      final s = await _gatewayWith(adapter).selfAiSession();
      expect(s.ok, isFalse);
      expect(s.hasNoAccess, isTrue);
      expect(s.isAvailable, isFalse);
    });

    test('a not-configured refusal parses as isNotConfigured', () async {
      final adapter = _RouteAdapter({
        'self/ai/session': (
          200,
          {'ok': false, 'error': 'AI is not configured on this server.'}
        ),
      });
      final s = await _gatewayWith(adapter).selfAiSession();
      expect(s.isNotConfigured, isTrue);
    });

    test('a pre-broker gateway 404 (HTML) parses as isUnavailable', () async {
      final adapter = _RouteAdapter({'self/ai/session': (404, null)});
      final s = await _gatewayWith(adapter).selfAiSession();
      expect(s.ok, isFalse);
      expect(s.isUnavailable, isTrue);
    });
  });

  group('NtfyGatewayClient.selfAiToken request shaping + parsing', () {
    test('POSTs self/ai with {do:token} and parses the bearer', () async {
      final adapter = _RouteAdapter({'self/ai': (200, _okToken)});
      final t = await _gatewayWith(adapter).selfAiToken();

      expect(adapter.bodyByPath['self/ai'], {'do': 'token'});
      expect(t.isAvailable, isTrue);
      expect(t.token, 'tailarr-mcp-abc123');
    });

    test('a no-access refusal parses as hasNoAccess', () async {
      final adapter = _RouteAdapter({
        'self/ai':
            (200, {'ok': false, 'error': "AI access isn't turned on for this server."}),
      });
      final t = await _gatewayWith(adapter).selfAiToken();
      expect(t.hasNoAccess, isTrue);
    });
  });

  group('VoiceCredentialBroker.resolve', () {
    test('happy path returns creds from both endpoints', () async {
      final adapter = _RouteAdapter({
        'self/ai/session': (200, _okSession),
        'self/ai': (200, _okToken),
      });
      final r = await VoiceCredentialBroker.resolve(
        client: _gatewayWith(adapter),
      );
      expect(r.ok, isTrue);
      expect(r.credentials!.ephemeralToken, 'auth_tokens/EPHEM-9');
      expect(r.credentials!.mcpToken, 'tailarr-mcp-abc123');
      expect(r.credentials!.mcpUrl,
          'http://tailarr-mcp.taila06ea9.ts.net:8100/mcp');
      expect(r.credentials!.model, 'gemini-3.1-flash-live-preview');
    });

    test('no AI badge -> noBadge, and the MCP mint is never attempted',
        () async {
      final adapter = _RouteAdapter({
        'self/ai/session':
            (200, {'ok': false, 'error': 'Ask your admin to enable AI access for you.'}),
        'self/ai': (200, _okToken),
      });
      final r = await VoiceCredentialBroker.resolve(
        client: _gatewayWith(adapter),
      );
      expect(r.ok, isFalse);
      expect(r.reason, VoiceUnavailableReason.noBadge);
      expect(adapter.hitPaths, isNot(contains('self/ai')));
    });

    test('server not configured -> notConfigured', () async {
      final adapter = _RouteAdapter({
        'self/ai/session': (
          200,
          {'ok': false, 'error': 'AI is not configured on this server.'}
        ),
      });
      final r = await VoiceCredentialBroker.resolve(
        client: _gatewayWith(adapter),
      );
      expect(r.reason, VoiceUnavailableReason.notConfigured);
    });

    test('pre-broker gateway (404) -> unreachable', () async {
      final adapter = _RouteAdapter({'self/ai/session': (404, null)});
      final r = await VoiceCredentialBroker.resolve(
        client: _gatewayWith(adapter),
      );
      expect(r.reason, VoiceUnavailableReason.unreachable);
    });

    test('empty mcp_url derives the endpoint from the tailnet suffix',
        () async {
      final session = Map<String, dynamic>.from(_okSession)..['mcp_url'] = '';
      final adapter = _RouteAdapter({
        'self/ai/session': (200, session),
        'self/ai': (200, _okToken),
      });
      final r = await VoiceCredentialBroker.resolve(
        client: _gatewayWith(adapter),
        suffixLookup: () async => 'taila06ea9.ts.net',
      );
      expect(r.ok, isTrue);
      expect(r.credentials!.mcpUrl,
          'http://tailarr-mcp.taila06ea9.ts.net:8100/mcp');
    });

    test('a cached MCP token is reused (no second mint call)', () async {
      final adapter = _RouteAdapter({
        'self/ai/session': (200, _okSession),
        'self/ai': (200, _okToken),
      });
      final r = await VoiceCredentialBroker.resolve(
        client: _gatewayWith(adapter),
        cachedMcpToken: 'tailarr-mcp-cached',
      );
      expect(r.ok, isTrue);
      expect(r.credentials!.mcpToken, 'tailarr-mcp-cached');
      expect(adapter.hitPaths, isNot(contains('self/ai')));
    });
  });
}
