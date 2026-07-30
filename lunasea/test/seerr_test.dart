// The per-person request-portal (Seerr) self-service contract: models parse
// the frozen /self/seerr + /self/seerr/signin shapes, availability/refusal
// helpers decide when the module hides or degrades, the gateway client hits the
// right paths/methods, and the webview cookie mapping scopes the brokered
// session to the portal origin.
//
// Driven with a fake Dio adapter — no gateway, no Tailscale, no Hive.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:lunasea/api/ntfy/ntfy.dart';
import 'package:lunasea/api/seerr/models.dart';
import 'package:lunasea/modules/requests/core/webview_cookie.dart';

/// Records the last request and replies with a canned JSON body + status.
class _CaptureAdapter implements HttpClientAdapter {
  _CaptureAdapter({required this.body, this.status = 200, this.json = true});

  final String body;
  final int status;
  final bool json;

  String? lastPath;
  String? lastMethod;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    lastMethod = options.method;
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
  group('SeerrSelf.fromJson (status probe)', () {
    test('parses an available portal', () {
      final self = SeerrSelf.fromJson({
        'ok': true,
        'pod': 'seerr',
        'url': 'https://seerr.taila06ea9.ts.net/',
      }, statusCode: 200);
      expect(self.isAvailable, isTrue);
      expect(self.pod, 'seerr');
      // Trailing slash trimmed like the other gateway URL fields.
      expect(self.url, 'https://seerr.taila06ea9.ts.net');
    });

    test('stopped pod: ok with empty url, still available', () {
      final self = SeerrSelf.fromJson(
        {'ok': true, 'pod': 'seerr', 'url': ''},
        statusCode: 200,
      );
      expect(self.isAvailable, isTrue);
      expect(self.url, isEmpty);
    });

    test('old server ("unknown request") reads as unavailable', () {
      final self = SeerrSelf.fromJson(
        {'ok': false, 'error': 'unknown request'},
        statusCode: 200,
      );
      expect(self.isAvailable, isFalse);
      expect(self.isUnavailable, isTrue);
      expect(self.hasNoAccess, isFalse);
    });

    test('404 reads as unavailable', () {
      final self = SeerrSelf.fromJson({'ok': false}, statusCode: 404);
      expect(self.isUnavailable, isTrue);
    });

    test('no request-portal access reads as no-access', () {
      final self = SeerrSelf.fromJson(
        {'ok': false, 'error': 'no request-portal access'},
        statusCode: 200,
      );
      expect(self.isAvailable, isFalse);
      expect(self.hasNoAccess, isTrue);
      expect(self.isUnavailable, isFalse);
    });

    test('unassigned device is distinguished from no-access', () {
      final self = SeerrSelf.fromJson(
        {'ok': false, 'error': 'device not assigned to a user'},
        statusCode: 200,
      );
      expect(self.isUnassigned, isTrue);
      expect(self.isAvailable, isFalse);
      expect(self.hasNoAccess, isFalse);
    });
  });

  group('SeerrSignin.fromJson (broker)', () {
    test('parses a fully brokered, openable session', () {
      final signin = SeerrSignin.fromJson({
        'ok': true,
        'pod': 'seerr',
        'url': 'https://seerr.taila06ea9.ts.net',
        'cookie': {
          'name': 'connect.sid',
          'value': 's:abc123',
          'expires': 0,
          'path': '/',
        },
      }, statusCode: 200);
      expect(signin.ok, isTrue);
      expect(signin.isReady, isTrue);
      expect(signin.cookie!.name, 'connect.sid');
      expect(signin.cookie!.value, 's:abc123');
      expect(signin.cookie!.expires, 0);
      expect(signin.cookie!.path, '/');
    });

    test('ok but missing cookie is NOT ready (unusable session)', () {
      final signin = SeerrSignin.fromJson({
        'ok': true,
        'pod': 'seerr',
        'url': 'https://seerr.taila06ea9.ts.net',
      }, statusCode: 200);
      expect(signin.ok, isTrue);
      expect(signin.isReady, isFalse);
    });

    test('ok but stopped pod (empty url) is NOT ready', () {
      final signin = SeerrSignin.fromJson({
        'ok': true,
        'pod': 'seerr',
        'url': '',
        'cookie': {'name': 'connect.sid', 'value': 's:x', 'path': '/'},
      }, statusCode: 200);
      expect(signin.isReady, isFalse);
    });

    test('needs-Jellyfin refusal is its own soft state', () {
      final signin = SeerrSignin.fromJson({
        'ok': false,
        'error':
            'no Jellyfin identity to sign in with — grant Jellyfin access first',
      }, statusCode: 200);
      expect(signin.needsJellyfin, isTrue);
      expect(signin.isReady, isFalse);
      expect(signin.hasNoAccess, isFalse);
      expect(signin.isTransient, isFalse);
    });

    test('not-ready refusal is a transient "being set up" state', () {
      final signin = SeerrSignin.fromJson({
        'ok': false,
        'error': 'request-portal account is not active',
      }, statusCode: 200);
      expect(signin.isNotReady, isTrue);
      expect(signin.needsJellyfin, isFalse);
      expect(signin.isReady, isFalse);
    });

    test('no-access refusal hides the module', () {
      final signin = SeerrSignin.fromJson({
        'ok': false,
        'error': 'no request-portal access',
      }, statusCode: 200);
      expect(signin.hasNoAccess, isTrue);
      expect(signin.isTransient, isFalse);
    });

    test('a transient "access" message is NOT authoritative no-access', () {
      // Must NOT flip seerrEnabled off — it falls through to "preserve state".
      final signin = SeerrSignin.fromJson({
        'ok': false,
        'error': 'could not verify request-portal access (HTTP 502)',
      }, statusCode: 200);
      expect(signin.hasNoAccess, isFalse);
      expect(signin.isTransient, isTrue);
    });

    test('cookie parses with a missing path (defaults to "/", no crash)', () {
      final signin = SeerrSignin.fromJson({
        'ok': true,
        'pod': 'seerr',
        'url': 'https://seerr.ts.net',
        'cookie': {'name': 'connect.sid', 'value': 's:p'},
      }, statusCode: 200);
      expect(signin.isReady, isTrue);
      expect(signin.cookie!.path, '/');
    });

    test('malformed non-string fields degrade to empty, never throw', () {
      final signin = SeerrSignin.fromJson({
        'ok': true,
        'pod': 123,
        'url': ['not', 'a', 'string'],
      }, statusCode: 200);
      expect(signin.pod, isEmpty);
      expect(signin.url, isEmpty);
      expect(signin.isReady, isFalse);
    });

    test('sign-in HTTP failure is transient (offer retry)', () {
      final signin = SeerrSignin.fromJson({
        'ok': false,
        'error': 'request-portal sign-in failed (HTTP 502)',
      }, statusCode: 200);
      expect(signin.isTransient, isTrue);
      expect(signin.hasNoAccess, isFalse);
      expect(signin.needsJellyfin, isFalse);
      expect(signin.isNotReady, isFalse);
    });
  });

  group('NtfyGatewayClient seerr endpoints', () {
    test('selfSeerr GETs self/seerr and parses', () async {
      final adapter = _CaptureAdapter(
        body: '{"ok":true,"pod":"seerr","url":"https://s.ts.net"}',
      );
      final self = await _clientWith(adapter).selfSeerr();
      expect(adapter.lastMethod, 'GET');
      expect(adapter.lastPath, contains('self/seerr'));
      expect(adapter.lastPath, isNot(contains('signin')));
      expect(self.isAvailable, isTrue);
    });

    test('selfSeerr maps a non-JSON 404 to "unknown request"', () async {
      final adapter = _CaptureAdapter(
        body: '<html>not found</html>',
        status: 404,
        json: false,
      );
      final self = await _clientWith(adapter).selfSeerr();
      expect(self.isUnavailable, isTrue);
      expect(self.error, 'unknown request');
    });

    test('selfSeerrSignin POSTs self/seerr/signin', () async {
      final adapter = _CaptureAdapter(
        body: '{"ok":true,"pod":"seerr","url":"https://s.ts.net",'
            '"cookie":{"name":"connect.sid","value":"s:z","expires":0,'
            '"path":"/"}}',
      );
      final signin = await _clientWith(adapter).selfSeerrSignin();
      expect(adapter.lastMethod, 'POST');
      expect(adapter.lastPath, contains('self/seerr/signin'));
      expect(signin.isReady, isTrue);
    });

    test('a {ok:false,error} refusal is parsed, not thrown', () async {
      final adapter = _CaptureAdapter(
        body: '{"ok":false,"error":"no request-portal access"}',
        status: 403,
      );
      final signin = await _clientWith(adapter).selfSeerrSignin();
      expect(signin.ok, isFalse);
      expect(signin.hasNoAccess, isTrue);
    });
  });

  group('seerrWebViewCookie mapping', () {
    test('scopes the cookie to the portal URL host (no domain from server)', () {
      final cookie = seerrWebViewCookie(
        'https://seerr.taila06ea9.ts.net',
        const SeerrCookie(
          name: 'connect.sid',
          value: 's:abc',
          expires: 0,
          path: '/',
        ),
      );
      expect(cookie, isA<WebViewCookie>());
      expect(cookie!.name, 'connect.sid');
      expect(cookie.value, 's:abc');
      expect(cookie.domain, 'seerr.taila06ea9.ts.net');
      expect(cookie.path, '/');
    });

    test('returns null for a URL with no host', () {
      final cookie = seerrWebViewCookie(
        'not a url',
        const SeerrCookie(
          name: 'connect.sid',
          value: 's:abc',
          expires: 0,
          path: '/',
        ),
      );
      expect(cookie, isNull);
    });

    test('returns null for an empty/invalid cookie', () {
      final cookie = seerrWebViewCookie(
        'https://seerr.ts.net',
        const SeerrCookie(name: '', value: '', expires: 0, path: '/'),
      );
      expect(cookie, isNull);
    });

    test('null cookie yields null', () {
      expect(seerrWebViewCookie('https://seerr.ts.net', null), isNull);
    });

    test('rejects a non-https portal URL (no cleartext session)', () {
      final cookie = seerrWebViewCookie(
        'http://seerr.ts.net',
        const SeerrCookie(
            name: 'connect.sid', value: 's:a', expires: 0, path: '/'),
      );
      expect(cookie, isNull);
    });

    test('rejects a URL carrying userinfo', () {
      final cookie = seerrWebViewCookie(
        'https://evil@seerr.ts.net',
        const SeerrCookie(
            name: 'connect.sid', value: 's:a', expires: 0, path: '/'),
      );
      expect(cookie, isNull);
    });

    test('only injects the connect.sid session cookie', () {
      final cookie = seerrWebViewCookie(
        'https://seerr.ts.net',
        const SeerrCookie(
            name: 'other', value: 's:a', expires: 0, path: '/'),
      );
      expect(cookie, isNull);
    });
  });
}
