import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// Fetches [options] over a BRAND-NEW connection pool so a B26 auth retry never
/// reuses a `tailscale serve` connection that has been "poisoned" — i.e. one on
/// which the proxy intermittently drops the `Authorization: Bearer` header,
/// yielding a spurious 401/403. A poisoned pooled connection stays poisoned for
/// every reused request, so re-fetching through the module's shared [Dio] would
/// just grab the same bad socket again.
///
/// A throwaway [Dio] with its own [IOHttpClientAdapter] gets its own
/// [HttpClient] and therefore its own connection pool + a fresh proxy CONNECT
/// tunnel — while still routing through the app's global Tailscale
/// `HttpOverrides` (those apply to every `HttpClient()` in the zone). The
/// caller additionally sets `persistentConnection = false` on [options], which
/// dart:io honors by emitting `Connection: close`, so this socket is neither
/// pooled nor reused afterward.
Future<Response<dynamic>> freshConnectionFetch(RequestOptions options) async {
  final dio = Dio()..httpClientAdapter = IOHttpClientAdapter();
  try {
    return await dio.fetch(options);
  } finally {
    dio.close(force: true);
  }
}
