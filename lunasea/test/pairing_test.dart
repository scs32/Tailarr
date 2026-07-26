// Locks the frozen Quick Connect pairing contract (app-quick-connect-design §5)
// at the transport layer: methods, paths, request bodies, the `poll_id` field,
// the token-only-on-status rule, and — critically — that /pair/approve lands on
// the PAIRING base, never the serve base.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/api/pairing/pairing.dart';

class _CaptureAdapter implements HttpClientAdapter {
  _CaptureAdapter(this.body, {this.status = 200});

  final String body;
  final int status;

  int calls = 0;
  String? lastPath;
  String? lastMethod;
  Map<String, dynamic>? lastQuery;
  Map<String, dynamic>? lastBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    lastPath = options.path;
    lastMethod = options.method;
    lastQuery = options.queryParameters;
    if (requestStream != null) {
      final bytes =
          (await requestStream.toList()).expand((c) => c).toList();
      if (bytes.isNotEmpty) {
        lastBody = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      }
    }
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

PairingClient _client(_CaptureAdapter serve, _CaptureAdapter pair) {
  final c = PairingClient(
    serveBaseUrl: 'https://ts.tail600657.ts.net',
    pairBaseUrl: 'http://ts.tail600657.ts.net:8089',
  );
  c.debugSetAdapters(serve: serve, pair: pair);
  return c;
}

void main() {
  group('PairingClient contract', () {
    test('pairStart POSTs {device} to the SERVE base and reads poll_id', () async {
      final serve = _CaptureAdapter('{"code":"ABCD-1234","poll_id":"p-1"}');
      final pair = _CaptureAdapter('{}');
      final res = await _client(serve, pair).pairStart(device: 'Chrome on Mac');

      expect(serve.lastMethod, 'POST');
      expect(serve.lastPath, 'api/pair/start');
      expect(serve.lastBody, {'device': 'Chrome on Mac'});
      expect(pair.calls, 0, reason: 'start must not touch the pairing leg');
      expect(res.code, 'ABCD-1234');
      expect(res.pollId, 'p-1'); // frozen: poll_id, not poll
      expect(res.isValid, isTrue);
    });

    test('pairStatus GETs the SERVE base with ?id and surfaces the once-token',
        () async {
      final serve = _CaptureAdapter(
          '{"status":"approved","token":"tailarr-tok-abc"}');
      final pair = _CaptureAdapter('{}');
      final res = await _client(serve, pair).pairStatus('p-1');

      expect(serve.lastMethod, 'GET');
      expect(serve.lastPath, 'api/pair/status');
      expect(serve.lastQuery, {'id': 'p-1'});
      expect(res.isApproved, isTrue);
      expect(res.isSettled, isTrue);
      expect(res.token, 'tailarr-tok-abc');
    });

    test('pairApprove POSTs {code} to the PAIRING base and never yields a token',
        () async {
      final serve = _CaptureAdapter('{}');
      final pair = _CaptureAdapter('{"ok":true,"person":"5a74ff15"}');
      final res = await _client(serve, pair).pairApprove('ABCD-1234');

      // Identity-proven leg: MUST be the pairing base, not serve.
      expect(pair.lastMethod, 'POST');
      expect(pair.lastPath, 'pair/approve');
      expect(pair.lastBody, {'code': 'ABCD-1234'});
      expect(serve.calls, 0, reason: 'approve must land on the pairing port');
      expect(res.ok, isTrue);
      expect(res.person, '5a74ff15');
      // Contract A: approve carries no token — the token lives only on status.
    });

    test('a badge/peer refusal (4xx {ok:false,error}) parses, not throws',
        () async {
      final serve = _CaptureAdapter('{}');
      final pair = _CaptureAdapter(
          '{"ok":false,"error":"no server badge"}', status: 403);
      final res = await _client(serve, pair).pairApprove('ABCD-1234');

      expect(res.ok, isFalse);
      expect(res.error, 'no server badge');
      expect(res.statusCode, 403);
    });

    test('pending / denied / expired classify correctly', () {
      expect(PairStatus.fromJson({'status': 'pending'}).isPending, isTrue);
      expect(PairStatus.fromJson({'status': 'pending'}).isSettled, isFalse);
      expect(PairStatus.fromJson({'status': 'denied'}).isDenied, isTrue);
      expect(PairStatus.fromJson({'status': 'expired'}).isExpired, isTrue);
      // Empty/absent token never surfaces as a value.
      expect(PairStatus.fromJson({'status': 'approved', 'token': ''}).token,
          isNull);
    });

    test('self-config sequence: start(serve) → approve(pair) → status(serve,token)',
        () async {
      // One serve adapter answers both start and status; script by call count.
      final serve = _SequenceAdapter([
        '{"code":"WXYZ-9999","poll_id":"p-9"}', // start
        '{"status":"approved","token":"tailarr-tok-self"}', // status
      ]);
      final pair = _CaptureAdapter('{"ok":true,"person":"5a74ff15"}');
      final client = _clientSeq(serve, pair);

      final started = await client.pairStart(device: 'Stephen’s iPhone');
      final approve = await client.pairApprove(started.code);
      final status = await client.pairStatus(started.pollId);

      expect(started.pollId, 'p-9');
      expect(approve.ok, isTrue);
      // The self-config device gets its token from STATUS, not approve.
      expect(status.token, 'tailarr-tok-self');
      expect(pair.lastPath, 'pair/approve');
    });
  });
}

/// A serve adapter that returns scripted bodies in call order.
class _SequenceAdapter implements HttpClientAdapter {
  _SequenceAdapter(this.bodies);
  final List<String> bodies;
  int _i = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (requestStream != null) await requestStream.toList();
    final body = bodies[_i.clamp(0, bodies.length - 1)];
    _i++;
    return ResponseBody.fromString(body, 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

PairingClient _clientSeq(_SequenceAdapter serve, _CaptureAdapter pair) {
  final c = PairingClient(
    serveBaseUrl: 'https://ts.tail600657.ts.net',
    pairBaseUrl: 'http://ts.tail600657.ts.net:8089',
  );
  c.debugSetAdapters(serve: serve, pair: pair);
  return c;
}
