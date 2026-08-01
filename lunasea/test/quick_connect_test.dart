import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/api/pairing/pairing.dart';
import 'package:lunasea/api/pairing/quick_connect.dart';
import 'package:lunasea/database/models/profile.dart';

/// Returns scripted bodies in call order (for the serve leg's start→status).
class _SeqAdapter implements HttpClientAdapter {
  _SeqAdapter(this.bodies);
  final List<String> bodies;
  int i = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s,
      Future<void>? c) async {
    if (s != null) await s.toList();
    final body = bodies[i.clamp(0, bodies.length - 1)];
    i++;
    return ResponseBody.fromString(body, 200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        });
  }

  @override
  void close({bool force = false}) {}
}

class _OneAdapter implements HttpClientAdapter {
  _OneAdapter(this.body, {this.status = 200});
  final String body;
  final int status;
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s,
      Future<void>? c) async {
    if (s != null) await s.toList();
    return ResponseBody.fromString(body, status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        });
  }

  @override
  void close({bool force = false}) {}
}

PairingClient _client(HttpClientAdapter serve, HttpClientAdapter pair) {
  final c = PairingClient(
    serveBaseUrl: 'https://ts.tail600657.ts.net',
    pairBaseUrl: 'http://ts.tail600657.ts.net:8089',
  );
  c.debugSetAdapters(serve: serve, pair: pair);
  return c;
}

void main() {
  LunaProfile profile({String host = ''}) =>
      LunaProfile()..tailarrServerHost = host;

  group('QuickConnect gate + base resolution', () {
    test('no controller grant → cannot approve, no client', () {
      final p = profile();
      expect(QuickConnect.canApprove(p), isFalse);
      expect(QuickConnect.serveBase(p), isNull);
      expect(QuickConnect.pairBase(p), isNull);
      expect(QuickConnect.clientFor(p), isNull);
    });

    test('a whitespace-only host is not a grant', () {
      expect(QuickConnect.canApprove(profile(host: '   ')), isFalse);
    });

    test('a server-badged profile approves and resolves both bases', () {
      final p = profile(host: 'https://ts.tail600657.ts.net');
      expect(QuickConnect.canApprove(p), isTrue);
      expect(QuickConnect.serveBase(p), 'https://ts.tail600657.ts.net');
      // approve leg = raw netns pairing port on the same controller host.
      expect(QuickConnect.pairBase(p), 'http://ts.tail600657.ts.net:8089');
      expect(QuickConnect.clientFor(p), isNotNull);
    });

    test('pairBase strips scheme/path and pins :8089', () {
      final p = profile(host: 'https://ts.example.ts.net/');
      expect(QuickConnect.pairBase(p), 'http://ts.example.ts.net:8089');
    });
  });

  group('QuickConnect.selfConfigure', () {
    test('no server grant → noBadge, no token stored', () async {
      final p = profile();
      final r = await QuickConnect.selfConfigure(p, deviceLabel: 'iPhone');
      expect(r.status, QuickConnectStatus.noBadge);
      expect(p.serverAdminToken, isEmpty);
    });

    test('start → approve → status(token): stores the minted bearer', () async {
      final p = profile(host: 'https://ts.tail600657.ts.net');
      final serve = _SeqAdapter([
        '{"code":"ABCD-1234","poll_id":"p-1"}', // start
        '{"status":"approved","token":"tailarr-tok-self"}', // status
      ]);
      final pair = _OneAdapter('{"ok":true,"person":"5a74ff15"}');
      final r = await QuickConnect.selfConfigure(
        p,
        deviceLabel: 'iPhone',
        client: _client(serve, pair),
      );
      expect(r.ok, isTrue);
      expect(p.serverAdminToken, 'tailarr-tok-self');
    });

    test('a still-valid stored bearer is REUSED, not re-minted (B26)', () async {
      // Reconnect over a working token must be inert — no duplicate token in the
      // server's .tokens.json. The serve adapter would mint 'tailarr-tok-NEW' if
      // the mint legs ran; they must not.
      final p = profile(host: 'https://ts.tail600657.ts.net')
        ..serverAdminToken = 'tailarr-tok-existing';
      final serve = _SeqAdapter([
        '{"code":"ABCD-1234","poll_id":"p-1"}',
        '{"status":"approved","token":"tailarr-tok-NEW"}',
      ]);
      final pair = _OneAdapter('{"ok":true,"person":"5a74ff15"}');
      var probed = false;
      final r = await QuickConnect.selfConfigure(
        p,
        deviceLabel: 'iPhone',
        client: _client(serve, pair),
        verifyExistingToken: () async {
          probed = true;
          return true; // the stored token still works
        },
      );
      expect(r.ok, isTrue);
      expect(probed, isTrue); // the reuse probe ran
      expect(serve.i, 0); // ...and the mint legs never fired
      expect(p.serverAdminToken, 'tailarr-tok-existing'); // unchanged, not NEW
    });

    test('a stored bearer that FAILS its probe falls through to minting a fresh '
        'one', () async {
      final p = profile(host: 'https://ts.tail600657.ts.net')
        ..serverAdminToken = 'tailarr-tok-stale';
      final serve = _SeqAdapter([
        '{"code":"ABCD-1234","poll_id":"p-1"}',
        '{"status":"approved","token":"tailarr-tok-fresh"}',
      ]);
      final pair = _OneAdapter('{"ok":true,"person":"5a74ff15"}');
      final r = await QuickConnect.selfConfigure(
        p,
        deviceLabel: 'iPhone',
        client: _client(serve, pair),
        verifyExistingToken: () async => false, // stored token no longer works
      );
      expect(r.ok, isTrue);
      expect(p.serverAdminToken, 'tailarr-tok-fresh');
    });

    test('approve refused → refused, no token stored', () async {
      final p = profile(host: 'https://ts.tail600657.ts.net');
      final serve = _SeqAdapter(['{"code":"ABCD-1234","poll_id":"p-1"}']);
      final pair = _OneAdapter(
          '{"ok":false,"error":"no server badge"}', status: 403);
      final r = await QuickConnect.selfConfigure(
        p,
        deviceLabel: 'iPhone',
        client: _client(serve, pair),
      );
      expect(r.status, QuickConnectStatus.refused);
      expect(r.error, 'no server badge');
      expect(p.serverAdminToken, isEmpty);
    });
  });
}
