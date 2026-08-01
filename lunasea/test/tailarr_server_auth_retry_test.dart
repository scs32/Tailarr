// B26: the Tailarr Server module reverted to its enrollment gate — and minted a
// duplicate admin token — on a SINGLE transient controller 401/403 on the
// connected-check reads (GET api/pods / api/network), even though the device was
// genuinely enrolled. The embedded `tailscale serve` proxy briefly drops the
// admin bearer during its settling window; a retry always clears it.
//
// TailarrServerAuthInterceptor tolerates a bounded number of transient 401/403s
// on idempotent GETs before concluding the device is unenrolled. A sustained
// failure (N consecutive) or a 401 on a mutating POST still surfaces as
// ServerAuthRequiredException so the truly-unenrolled path shows the gate.
//
// Driven with a fake Dio adapter + injected zero-delay sleep — no network.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/api/tailarr_server/tailarr_server.dart';

/// Returns [failures] 401s, then 200s. Counts every fetch.
class _FlakyAuthAdapter implements HttpClientAdapter {
  _FlakyAuthAdapter({required this.failures});
  final int failures;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    if (calls <= failures) {
      return ResponseBody.fromString(
        '{"detail":"missing bearer"}',
        401,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      '{"pods":[{"name":"radarr"}]}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_FlakyAuthAdapter adapter, {int maxRetries = 3}) {
  final dio = Dio(BaseOptions(
    baseUrl: 'https://ctrl.tail600657.ts.net/',
    // Mirror the real client: 401/403 arrive as responses, not exceptions.
    validateStatus: (status) => status != null && status < 500,
  ))
    ..httpClientAdapter = adapter;
  dio.interceptors.add(TailarrServerAuthInterceptor(
    dio,
    maxRetries: maxRetries,
    // Zero-delay so the bounded backoff doesn't slow the suite.
    sleep: (_) async {},
  ));
  return dio;
}

void main() {
  group('TailarrServerAuthInterceptor', () {
    test('a SINGLE transient 401 on GET api/pods is retried to success — the '
        'module stays connected, no auth error surfaces', () async {
      final adapter = _FlakyAuthAdapter(failures: 1);
      final dio = _dioWith(adapter);

      final res = await dio.get('api/pods');
      expect(res.statusCode, 200);
      expect((res.data as Map)['pods'], isNotEmpty);
      expect(adapter.calls, 2); // 1 transient 401 + 1 successful retry
    });

    test('two transient 401s still recover within the retry budget', () async {
      final adapter = _FlakyAuthAdapter(failures: 2);
      final dio = _dioWith(adapter);

      final res = await dio.get('api/network');
      expect(res.statusCode, 200);
      expect(adapter.calls, 3);
    });

    test('N consecutive definitive 401s surface ServerAuthRequiredException — '
        'the genuinely-unenrolled path still shows the connect gate', () async {
      final adapter = _FlakyAuthAdapter(failures: 99);
      final dio = _dioWith(adapter, maxRetries: 3);

      await expectLater(
        dio.get('api/pods'),
        throwsA(predicate((e) => isServerAuthRequired(e))),
      );
      expect(adapter.calls, 4); // 1 initial + 3 bounded retries, then give up
    });

    test('a 401 on a mutating POST is NOT retried — surfaces immediately',
        () async {
      final adapter = _FlakyAuthAdapter(failures: 99);
      final dio = _dioWith(adapter);

      await expectLater(
        dio.post('api/pods/radarr/action', data: {'do': 'start'}),
        throwsA(predicate((e) => isServerAuthRequired(e))),
      );
      expect(adapter.calls, 1); // no retry on a non-idempotent action
    });

    test('a non-auth response passes through untouched', () async {
      final adapter = _FlakyAuthAdapter(failures: 0);
      final dio = _dioWith(adapter);

      final res = await dio.get('api/pods');
      expect(res.statusCode, 200);
      expect(adapter.calls, 1);
    });
  });
}
