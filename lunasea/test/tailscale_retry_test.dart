// The Tailscale connect-window retry interceptor: on a cold start the embedded
// node comes up after the UI, so a module's first request fails with a
// connection error — the "Try Again always works" race. The interceptor waits
// for the tunnel and retries, bounded, only while Tailscale is enabled.
//
// Driven with a fake Dio adapter + injected ensure/enabled — no Tailscale, no
// Hive, no network.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/system/network/tailscale_retry.dart';

/// Fails the first [failures] fetches with a connection error, then 200s.
class _FlakyAdapter implements HttpClientAdapter {
  _FlakyAdapter({required this.failures, this.errorType = DioExceptionType.connectionError});
  final int failures;
  final DioExceptionType errorType;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    if (calls <= failures) {
      throw DioException(requestOptions: options, type: errorType);
    }
    return ResponseBody.fromString(
      '{"ok":true}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(
  _FlakyAdapter adapter, {
  required bool enabled,
  int maxRetries = 3,
  List<int>? ensureCalls,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://svc.tailnet.ts.net/'))
    ..httpClientAdapter = adapter;
  dio.interceptors.add(TailscaleConnectRetryInterceptor(
    dio,
    ensureTunnel: () async => ensureCalls?.add(1),
    tailscaleEnabled: () => enabled,
    maxRetries: maxRetries,
  ));
  return dio;
}

void main() {
  group('isTailscaleConnectFailure', () {
    DioException of(DioExceptionType t, {String? message, Object? error}) =>
        DioException(
          requestOptions: RequestOptions(path: '/'),
          type: t,
          message: message,
          error: error,
        );

    test('connection errors and timeouts are connect failures', () {
      expect(isTailscaleConnectFailure(of(DioExceptionType.connectionError)),
          isTrue);
      expect(isTailscaleConnectFailure(of(DioExceptionType.connectionTimeout)),
          isTrue);
    });

    test('a host-lookup / refused SocketException is a connect failure', () {
      expect(
        isTailscaleConnectFailure(of(DioExceptionType.unknown,
            message: 'SocketException: Failed host lookup: svc.tailnet.ts.net')),
        isTrue,
      );
      expect(
        isTailscaleConnectFailure(of(DioExceptionType.unknown,
            error: 'SocketException: Connection refused')),
        isTrue,
      );
    });

    test('an embedded-proxy 502 (tunnel not up yet) is a connect failure', () {
      expect(
        isTailscaleConnectFailure(of(DioExceptionType.unknown,
            error: 'HttpException: Proxy failed to establish tunnel '
                '(502 Bad Gateway), uri = //radarr.tail600657.ts.net:443')),
        isTrue,
      );
    });

    test('server-side and post-connect errors are NOT connect failures', () {
      expect(isTailscaleConnectFailure(of(DioExceptionType.badResponse)),
          isFalse); // 404/401 — the server answered
      expect(isTailscaleConnectFailure(of(DioExceptionType.receiveTimeout)),
          isFalse); // connected, server slow — a retry won't help
      expect(
        isTailscaleConnectFailure(of(DioExceptionType.unknown, message: 'boom')),
        isFalse,
      );
    });
  });

  group('TailscaleConnectRetryInterceptor', () {
    test('waits for the tunnel and retries a cold-start failure to success',
        () async {
      final adapter = _FlakyAdapter(failures: 2);
      final ensures = <int>[];
      final dio = _dioWith(adapter, enabled: true, ensureCalls: ensures);

      final res = await dio.get('/api/v3/series');
      expect(res.statusCode, 200);
      expect(adapter.calls, 3); // 1 initial + 2 retries
      expect(ensures.length, 2); // one tunnel-ensure per retry
    });

    test('gives up after maxRetries and surfaces the error', () async {
      final adapter = _FlakyAdapter(failures: 99);
      final ensures = <int>[];
      final dio =
          _dioWith(adapter, enabled: true, maxRetries: 2, ensureCalls: ensures);

      await expectLater(dio.get('/'), throwsA(isA<DioException>()));
      expect(adapter.calls, 3); // 1 initial + 2 retries, then stop
      expect(ensures.length, 2);
    });

    test('does not retry when Tailscale is disabled', () async {
      final adapter = _FlakyAdapter(failures: 99);
      final ensures = <int>[];
      final dio = _dioWith(adapter, enabled: false, ensureCalls: ensures);

      await expectLater(dio.get('/'), throwsA(isA<DioException>()));
      expect(adapter.calls, 1); // no retry
      expect(ensures, isEmpty); // tunnel never touched
    });

    test('does not retry a server error (bad response)', () async {
      final adapter =
          _FlakyAdapter(failures: 99, errorType: DioExceptionType.badResponse);
      final ensures = <int>[];
      final dio = _dioWith(adapter, enabled: true, ensureCalls: ensures);

      await expectLater(dio.get('/'), throwsA(isA<DioException>()));
      expect(adapter.calls, 1);
      expect(ensures, isEmpty);
    });
  });
}
