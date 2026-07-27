import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Serves the bundled demo fixtures (`assets/demo/`) in place of a real
/// backend. Installed on a module's Dio (right beside
/// `attachTailscaleConnectRetry`) only when [DemoMode.active]. The entire
/// model → state → UI chain runs unmodified against on-device JSON — no
/// network, no tailnet, no crash.
///
/// Radarr and Sonarr both use `/api/v3/…`; the paths that overlap
/// (qualityprofile / tag / rootfolder) share one fixture, which is correct for
/// both. Tautulli funnels every command through `/api/v2/` distinguished by the
/// `?cmd=` query, so it is matched on `cmd`, not path.
class DemoAdapter implements HttpClientAdapter {
  /// *arr endpoints keyed by exact `uri.path` (query stripped).
  static const Map<String, String> _byPath = {
    // Radarr
    '/api/v3/movie': 'assets/demo/radarr/movies.json',
    '/api/v3/queue': 'assets/demo/arr/page_empty.json',
    '/api/v3/language': 'assets/demo/arr/language.json',
    // Sonarr
    '/api/v3/series': 'assets/demo/sonarr/series.json',
    '/api/v3/wanted/missing': 'assets/demo/arr/page_empty.json',
    '/api/v3/calendar': 'assets/demo/arr/empty.json',
    '/api/v3/languageprofile': 'assets/demo/arr/languageprofile.json',
    // Shared (Radarr + Sonarr)
    '/api/v3/qualityprofile': 'assets/demo/arr/qualityprofile.json',
    '/api/v3/qualitydefinition': 'assets/demo/arr/empty.json',
    '/api/v3/tag': 'assets/demo/arr/empty.json',
    '/api/v3/rootfolder': 'assets/demo/arr/rootfolder.json',
  };

  /// Tautulli commands keyed by the `?cmd=` query value.
  static const Map<String, String> _byCmd = {
    'get_activity': 'assets/demo/tautulli/activity.json',
    'get_server_identity': 'assets/demo/tautulli/server_identity.json',
    'get_users_table': 'assets/demo/tautulli/users_table.json',
    'get_history': 'assets/demo/tautulli/history.json',
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    final asset = _assetFor(options);
    // Unmapped requests (details, writes) get a benign empty array — demo is
    // read-only, so nothing needs to pretend to act.
    final body = asset == null ? '[]' : await _load(asset);
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  String? _assetFor(RequestOptions options) =>
      assetFor(options.uri.path, options.uri.queryParameters['cmd']);

  /// Pure fixture resolver (path + optional Tautulli `cmd`) → asset, or null
  /// when unmapped. Extracted so the routing table is directly unit-testable.
  static String? assetFor(String path, String? cmd) {
    if (path.contains('/api/v2')) {
      return cmd == null ? null : _byCmd[cmd];
    }
    return _byPath[path];
  }

  Future<String> _load(String asset) async {
    try {
      return await rootBundle.loadString(asset);
    } catch (_) {
      return '[]';
    }
  }

  @override
  void close({bool force = false}) {}
}
