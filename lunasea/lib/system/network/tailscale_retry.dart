import 'package:dio/dio.dart';

import 'package:lunasea/database/models/profile.dart';
// ignore: always_use_package_imports
import 'package:lunasea/system/network/platform/network_stub.dart'
    if (dart.library.io) 'package:lunasea/system/network/platform/network_io.dart'
    if (dart.library.html) 'package:lunasea/system/network/platform/network_html.dart';

/// Attaches the Tailscale connect-window retry interceptor to [dio].
///
/// On a cold app start the embedded Tailscale node comes up a few seconds
/// AFTER the UI does, so a module's first request can fire before the tunnel
/// exists and fail with a connection / "Failed host lookup" error. That is the
/// "An Error Has Occurred → Try Again" that always works on the second tap:
/// by then the node is up. Rather than surface that transient failure, the
/// interceptor waits for the node (ensure() brings the listener up) and retries,
/// bounded — only while Tailscale is enabled. A genuine service outage still
/// fails after the bounded attempts, and non-connection errors (auth, 404, bad
/// response) are never retried.
///
/// No-op where Tailscale isn't supported (web), so module API clients can call
/// it unconditionally.
void attachTailscaleConnectRetry(Dio dio) {
  if (!IO.isTailscaleSupported) return;
  dio.interceptors.add(TailscaleConnectRetryInterceptor(dio));
}

/// True when [e] looks like the tunnel simply wasn't up yet — a connection
/// failure, not a server saying "no". Pure so it can be unit-tested; kept
/// web-safe (no dart:io) by matching on type and message text.
bool isTailscaleConnectFailure(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionError:
    case DioExceptionType.connectionTimeout:
      return true;
    case DioExceptionType.unknown:
      final text = '${e.message ?? ''} ${e.error ?? ''}';
      return text.contains('Failed host lookup') ||
          text.contains('Connection refused') ||
          text.contains('SocketException') ||
          text.contains('Network is unreachable') ||
          // The embedded Tailscale proxy couldn't dial the service yet — its
          // CONNECT tunnel fails with a 502 while the netmap/peer route is
          // still settling during the connect window. Same race, different
          // surface: "Proxy failed to establish tunnel (502 Bad Gateway)".
          text.contains('Proxy failed to establish tunnel');
    default:
      return false;
  }
}

class TailscaleConnectRetryInterceptor extends Interceptor {
  TailscaleConnectRetryInterceptor(
    this._dio, {
    Future<void> Function()? ensureTunnel,
    bool Function()? tailscaleEnabled,
    this.maxRetries = 3,
    this.ensureTimeout = const Duration(seconds: 8),
  })  : _ensureTunnel = ensureTunnel ?? (() => IO.ensureTailscale('')),
        _tailscaleEnabled =
            tailscaleEnabled ?? (() => LunaProfile.current.tailscaleEnabled);

  final Dio _dio;
  final Future<void> Function() _ensureTunnel;
  final bool Function() _tailscaleEnabled;
  final int maxRetries;
  final Duration ensureTimeout;

  /// Per-request retry counter, carried on the request's own extras so a
  /// re-dispatch through the interceptor chain can't loop forever.
  static const _extraKey = 'ts_connect_retries';

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final attempts = (err.requestOptions.extra[_extraKey] as int?) ?? 0;
    if (!isTailscaleConnectFailure(err) ||
        attempts >= maxRetries ||
        !_tailscaleEnabled()) {
      return handler.next(err);
    }

    try {
      // Bring the node/listener up (or confirm it is). Bounded so a genuinely
      // down tunnel can't hang the request forever — on timeout, surface the
      // original error.
      await _ensureTunnel().timeout(ensureTimeout);
    } catch (_) {
      return handler.next(err);
    }

    final options = err.requestOptions..extra[_extraKey] = attempts + 1;
    try {
      handler.resolve(await _dio.fetch(options));
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}
