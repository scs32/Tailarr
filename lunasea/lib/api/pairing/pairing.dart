import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:lunasea/api/pairing/models.dart';
import 'package:lunasea/system/network/tailscale_retry.dart';

export 'package:lunasea/api/pairing/models.dart';

/// Client for the controller's Quick Connect pairing surface (server v0.77.0+).
/// The app is an APPROVER, not an admin console — this is the entire transport.
///
/// Two base URLs, because the legs land on different ports:
///  - [serveBaseUrl] — the controller over serve/HTTPS (`<controller-dns>`), for
///    `/pair/start` + `/pair/status`. Sourced from the `{type:"tailarr"}` entry
///    in `/self/services` (== `profile.tailarrServerHost`).
///  - [pairBaseUrl] — the identity-proven PAIRING PORT (netns), for
///    `/pair/approve` only, so the controller whois-resolves the real peer IP.
///    The exact URL (direct `:81` vs a serve path) is frozen server-side later
///    (design §7-Q1); this client codes to whatever single URL is injected.
class PairingClient {
  final Dio _serve;
  final Dio _pair;

  PairingClient._(this._serve, this._pair);

  factory PairingClient({
    required String serveBaseUrl,
    required String pairBaseUrl,
  }) {
    Dio build(String base) {
      final dio = Dio(
        BaseOptions(
          baseUrl: base.endsWith('/') ? base : '$base/',
          contentType: Headers.jsonContentType,
          responseType: ResponseType.json,
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
          // {ok:false,error} refusals come back as 4xx — parse, don't throw.
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      attachTailscaleConnectRetry(dio);
      return dio;
    }

    return PairingClient._(build(serveBaseUrl), build(pairBaseUrl));
  }

  /// Inject fake adapters for the serve and pairing legs separately, so tests
  /// can assert each call lands on the correct base (approve MUST use the
  /// pairing leg).
  @visibleForTesting
  void debugSetAdapters({
    required HttpClientAdapter serve,
    required HttpClientAdapter pair,
  }) {
    _serve.httpClientAdapter = serve;
    _pair.httpClientAdapter = pair;
  }

  /// Requester leg (serve/HTTPS): begin a pairing and get the human code +
  /// poll id. On the admin's own device this is step 1 of self-config.
  Future<PairStartResponse> pairStart({required String device}) async {
    final response = await _serve.post('pair/start', data: {'device': device});
    return PairStartResponse.fromJson(
      (response.data as Map).cast<String, dynamic>(),
    );
  }

  /// Requester leg (serve/HTTPS): poll for the outcome. The token appears
  /// exactly once, on the first read after "approved" — this is how the
  /// self-config app receives its token (§5 A).
  Future<PairStatus> pairStatus(String pollId) async {
    final response =
        await _serve.get('pair/status', queryParameters: {'id': pollId});
    return PairStatus.fromJson((response.data as Map).cast<String, dynamic>());
  }

  /// Approver leg (PAIRING PORT / netns): authorize a pending code. The
  /// controller whois-resolves this call's real peer IP and requires the
  /// `server` badge + an online peer. Returns `{ok, person, error?}` — never a
  /// token.
  Future<PairApproveResult> pairApprove(String code) async {
    final response = await _pair.post('pair/approve', data: {'code': code});
    return PairApproveResult.fromJson(
      (response.data as Map).cast<String, dynamic>(),
      statusCode: response.statusCode,
    );
  }
}
