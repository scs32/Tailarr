// B26: the module opens by firing pods+network+updates (+ users/ai on their
// screens) as a simultaneous burst through `tailscale serve`. That burst is what
// poisons a connection and lets ONE bad connection 401-storm the whole refresh.
//
// TailarrServerAPI now routes idempotent GET reads through a gate that (a) caps
// concurrent GETs so the whole set can't hit serve at once, and (b) dedupes an
// already-in-flight GET for the same key instead of re-issuing it. Mutating POSTs
// are never gated.
//
// Driven with a fake adapter that records max observed in-flight concurrency and
// per-path call counts — no network.
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/api/tailarr_server/tailarr_server.dart';

/// Records concurrency + per-path counts; holds each request open until
/// [release] so overlap is observable. Returns minimal valid JSON per endpoint.
class _ConcurrencyAdapter implements HttpClientAdapter {
  int inFlight = 0;
  int maxInFlight = 0;
  final Map<String, int> callsByPath = {};
  final _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callsByPath.update(options.path, (v) => v + 1, ifAbsent: () => 1);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    await _gate.future; // hold all in-flight requests open together
    inFlight--;
    return ResponseBody.fromString(
      _bodyFor(options.path),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  String _bodyFor(String path) {
    if (path.contains('pods')) return '{"pods":[]}';
    if (path.contains('network')) return '{"network":[]}';
    if (path.contains('updates')) return '{"checking":false,"images":{}}';
    if (path.contains('users')) return '{"configured":true,"users":[]}';
    if (path.contains('ai')) return '{"configured":false,"key_set":false}';
    return '{}';
  }

  @override
  void close({bool force = false}) {}
}

/// Each request takes [delay]; records max observed concurrency. Used to
/// interleave releases with fresh arrivals so a permit-conservation bug (a woken
/// waiter double-counting a slot a fresh acquire also grabbed) would over-admit.
class _DelayAdapter implements HttpClientAdapter {
  _DelayAdapter(this.delay);
  final Duration delay;
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    await Future<void>.delayed(delay);
    inFlight--;
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

TailarrServerAPI _apiWith(_ConcurrencyAdapter adapter) => _apiWith2(adapter);

TailarrServerAPI _apiWith2(HttpClientAdapter adapter) {
  final api = TailarrServerAPI(host: 'https://ctrl.tail600657.ts.net/');
  api.httpClient.httpClientAdapter = adapter;
  return api;
}

void main() {
  group('TailarrServerAPI GET gate — serialize + dedupe (B26)', () {
    test('a 5-wide startup burst never hits serve all at once', () async {
      final adapter = _ConcurrencyAdapter();
      final api = _apiWith(adapter);

      final all = Future.wait([
        api.getPods(),
        api.getNetwork(),
        api.getUpdates(),
        api.getUsers(),
        api.getAIConfig(),
      ]);
      // Let the gate admit as many as it will before any completes.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(adapter.maxInFlight, lessThanOrEqualTo(2),
          reason: 'the burst must be throttled, not fired simultaneously');
      adapter.release();
      await all;
      // All five distinct reads still happened.
      expect(adapter.callsByPath.keys, hasLength(5));
    });

    test('duplicate concurrent GETs for the same key are deduped to one call',
        () async {
      final adapter = _ConcurrencyAdapter();
      final api = _apiWith(adapter);

      final both = Future.wait([api.getPods(), api.getPods()]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      adapter.release();
      final results = await both;

      expect(adapter.callsByPath['api/pods'], 1,
          reason: 'the second concurrent getPods should share the in-flight one');
      // Both callers still get a valid, independent result.
      expect(results, hasLength(2));
    });

    test('the concurrency cap holds under STAGGERED arrivals (permit is '
        'conserved — no over-admit when a release races a fresh acquire)',
        () async {
      final adapter = _DelayAdapter(const Duration(milliseconds: 5));
      final api = _apiWith2(adapter);
      final futures = <Future<dynamic>>[];
      // Distinct keys so nothing dedupes; stagger arrivals so releases interleave
      // with new acquires — the exact window the permit race would exploit.
      for (var i = 0; i < 12; i++) {
        futures.add(api.getLogs('pod$i'));
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await Future.wait(futures);
      expect(adapter.maxInFlight, lessThanOrEqualTo(2));
    });

    test('a fresh GET after the previous one settled is NOT deduped', () async {
      final adapter1 = _ConcurrencyAdapter();
      final api = _apiWith(adapter1);
      adapter1.release();
      await api.getPods();
      // Second call after completion re-issues (in-flight entry was cleared).
      await api.getPods();
      expect(adapter1.callsByPath['api/pods'], 2);
    });
  });
}
