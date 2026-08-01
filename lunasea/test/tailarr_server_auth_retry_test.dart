// B26: the Tailarr Server module reverted to its enrollment gate — and minted a
// duplicate admin token — on transient controller 401/403s on the connected-check
// reads (GET api/pods / api/network), even though the device was genuinely
// enrolled. The embedded `tailscale serve` proxy intermittently POISONS a pooled
// connection (drops the admin bearer) during a request burst; re-fetching over
// the SAME pooled connection just hit the same poison, so a short storm blew the
// retry budget and reverted.
//
// TailarrServerAuthInterceptor now (a) fetches every 401/403 retry over a
// BRAND-NEW connection (persistentConnection=false + Connection: close, via an
// injectable freshFetch that in production spins a throwaway Dio/pool), and (b)
// uses a wider exponential-backoff budget so a multi-second storm is ridden out
// without reverting. A sustained failure (budget exhausted) or a 401 on a
// mutating POST still surfaces ServerAuthRequiredException → the connect gate.
//
// Driven with a fake freshFetch + fake adapter + injected zero-delay sleep — no
// network.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/api/tailarr_server/tailarr_server.dart';

/// The initial (pooled) request: returns 401 [initialFailures] times, else 200.
/// Retries do NOT come back through here — they go through the injected
/// freshFetch — so this only ever serves the FIRST attempt in practice.
class _InitialAdapter implements HttpClientAdapter {
  _InitialAdapter({this.status = 401});
  final int status;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    final body = status == 200 ? '{"pods":[{"name":"radarr"}]}' : '{"detail":"missing bearer"}';
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

/// A fake fresh-connection fetcher. Returns [statuses] in order (then 200), and
/// records the options it was handed so tests can assert every retry was marked
/// for a fresh, non-pooled connection.
class _FakeFreshFetch {
  _FakeFreshFetch(this.statuses);
  final List<int> statuses;
  int calls = 0;
  final List<RequestOptions> seen = [];

  Future<Response<dynamic>> call(RequestOptions options) async {
    seen.add(options);
    final status = calls < statuses.length ? statuses[calls] : 200;
    calls++;
    final data = status == 200
        ? {
            'pods': [
              {'name': 'radarr'}
            ]
          }
        : {'detail': 'missing bearer'};
    return Response<dynamic>(
      requestOptions: options,
      statusCode: status,
      data: data,
    );
  }
}

Dio _dioWith({
  required _InitialAdapter adapter,
  required _FakeFreshFetch fresh,
  int maxRetries = 5,
  List<Duration>? sleeps,
}) {
  final dio = Dio(BaseOptions(
    baseUrl: 'https://ctrl.tail600657.ts.net/',
    // Mirror the real client: 401/403 arrive as responses, not exceptions.
    validateStatus: (status) => status != null && status < 500,
  ))
    ..httpClientAdapter = adapter;
  dio.interceptors.add(TailarrServerAuthInterceptor(
    dio,
    maxRetries: maxRetries,
    sleep: (d) async => sleeps?.add(d),
    freshFetch: fresh.call,
  ));
  return dio;
}

void main() {
  group('TailarrServerAuthInterceptor — fresh-connection retry (B26)', () {
    test('a SINGLE transient 401 recovers on a fresh-connection retry — the '
        'module stays connected, no auth error surfaces', () async {
      final adapter = _InitialAdapter(status: 401);
      final fresh = _FakeFreshFetch([200]); // first retry succeeds
      final dio = _dioWith(adapter: adapter, fresh: fresh);

      final res = await dio.get('api/pods');
      expect(res.statusCode, 200);
      expect((res.data as Map)['pods'], isNotEmpty);
      expect(adapter.calls, 1); // the initial pooled attempt only
      expect(fresh.calls, 1); // one fresh-connection retry
    });

    test('a burst-storm of several consecutive 401s is ridden out and recovers '
        'without reverting', () async {
      final adapter = _InitialAdapter(status: 401);
      // Three straight poisoned retries, then the storm clears.
      final fresh = _FakeFreshFetch([401, 401, 401, 200]);
      final dio = _dioWith(adapter: adapter, fresh: fresh);

      final res = await dio.get('api/network');
      expect(res.statusCode, 200);
      expect(fresh.calls, 4);
    });

    test('EVERY retry is fetched over a fresh, non-pooled connection', () async {
      final adapter = _InitialAdapter(status: 401);
      final fresh = _FakeFreshFetch([401, 200]);
      final dio = _dioWith(adapter: adapter, fresh: fresh);

      await dio.get('api/pods');
      // The fresh fetcher is a SEPARATE transport from the module's pooled
      // client, and each retry is marked non-persistent (dart:io emits
      // Connection: close) so the poisoned pooled socket is never reused/kept.
      expect(fresh.seen, isNotEmpty);
      for (final opts in fresh.seen) {
        expect(opts.persistentConnection, isFalse,
            reason: 'retry must not use a persistent (pooled) connection');
      }
    });

    test('wider exponential backoff (capped) rides a multi-second storm',
        () async {
      final adapter = _InitialAdapter(status: 401);
      final fresh = _FakeFreshFetch([401, 401, 401, 401, 401]); // never clears
      final sleeps = <Duration>[];
      final dio =
          _dioWith(adapter: adapter, fresh: fresh, maxRetries: 5, sleeps: sleeps);

      await expectLater(
        dio.get('api/pods'),
        throwsA(predicate((e) => isServerAuthRequired(e))),
      );
      // 300, 600, 1200, 2000 (cap), 2000 (cap) — ~6.1s of retry budget.
      expect(sleeps, [
        const Duration(milliseconds: 300),
        const Duration(milliseconds: 600),
        const Duration(milliseconds: 1200),
        const Duration(seconds: 2),
        const Duration(seconds: 2),
      ]);
      final total = sleeps.fold(Duration.zero, (a, b) => a + b);
      expect(total.inSeconds, greaterThanOrEqualTo(6));
    });

    test('a SUSTAINED failure (budget exhausted) surfaces '
        'ServerAuthRequiredException — the connect gate still shows', () async {
      final adapter = _InitialAdapter(status: 401);
      final fresh = _FakeFreshFetch(List.filled(99, 401));
      final dio = _dioWith(adapter: adapter, fresh: fresh, maxRetries: 3);

      await expectLater(
        dio.get('api/pods'),
        throwsA(predicate((e) => isServerAuthRequired(e))),
      );
      expect(fresh.calls, 3); // exactly the bounded budget of fresh retries
    });

    test('a 401 on a mutating POST is NOT retried — surfaces immediately, no '
        'fresh connection attempted', () async {
      final adapter = _InitialAdapter(status: 401);
      final fresh = _FakeFreshFetch(List.filled(99, 401));
      final dio = _dioWith(adapter: adapter, fresh: fresh);

      await expectLater(
        dio.post('api/pods/radarr/action', data: {'do': 'start'}),
        throwsA(predicate((e) => isServerAuthRequired(e))),
      );
      expect(adapter.calls, 1);
      expect(fresh.calls, 0);
    });

    test('a non-auth response passes through untouched', () async {
      final adapter = _InitialAdapter(status: 200);
      final fresh = _FakeFreshFetch([]);
      final dio = _dioWith(adapter: adapter, fresh: fresh);

      final res = await dio.get('api/pods');
      expect(res.statusCode, 200);
      expect(adapter.calls, 1);
      expect(fresh.calls, 0);
    });
  });
}
