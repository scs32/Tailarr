/// Dart client for the Tailarr Server JSON API — the Podman/tailnet homelab
/// controller (github.com/scs32/tailarr-server).
///
/// Reached over the tailnet (`https://*.ts.net`, routed through the app's
/// embedded node). Server v0.77.0+ requires an admin bearer on `/api/*` (reads
/// included as of v0.82.0); the token is minted via Quick Connect self-config
/// and set as `Authorization: Bearer`. A `401`/`403` means the device isn't
/// connected (or the token was revoked) — surfaced as [ServerAuthRequiredException]
/// so screens can offer "Connect this device".
library tailarr_server;

import 'package:dio/dio.dart';
import 'package:lunasea/system/network/tailscale_retry.dart';
import 'package:lunasea/api/tailarr_server/models.dart';

/// Thrown (via a Dio interceptor) when the controller rejects a call for lack
/// of a valid admin bearer — the cue to run Quick Connect self-config.
class ServerAuthRequiredException implements Exception {
  const ServerAuthRequiredException();
}

/// Whether [error] (typically a FutureBuilder/snapshot error) is a controller
/// auth rejection — i.e. show the "Connect this device" gate, not a raw error.
bool isServerAuthRequired(Object? error) =>
    error is ServerAuthRequiredException ||
    (error is DioException && error.error is ServerAuthRequiredException);

class TailarrServerAPI {
  /// Lifecycle actions can block while run.sh/stop.sh execute (the server
  /// caps them at 600s); backups/restores stop + tar + start the pod.
  static const _longOperation = Duration(minutes: 12);

  final Dio httpClient;

  TailarrServerAPI._internal({required this.httpClient});

  factory TailarrServerAPI({
    required String host,
    Map<String, dynamic>? headers,
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: host.endsWith('/') ? host : '$host/',
        contentType: Headers.jsonContentType,
        responseType: ResponseType.json,
        headers: headers,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
        // Failed actions come back as 400/409 with the same result dict —
        // surface them as parsed results, not exceptions.
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    attachTailscaleConnectRetry(dio);
    // Tolerate a TRANSIENT controller 401/403, then surface a sustained one as a
    // typed auth error so screens can offer "Connect this device".
    dio.interceptors.add(TailarrServerAuthInterceptor(dio));
    return TailarrServerAPI._internal(httpClient: dio);
  }

  Future<TailarrServerInfo> getInfo() async {
    final response = await httpClient.get('api/info');
    return TailarrServerInfo.fromJson(response.data);
  }

  Future<List<TailarrServerPod>> getPods() async {
    final response = await httpClient.get('api/pods');
    return (response.data['pods'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(TailarrServerPod.fromJson)
        .toList();
  }

  Future<List<TailarrServerNetworkEntry>> getNetwork() async {
    final response = await httpClient.get('api/network');
    return (response.data['network'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(TailarrServerNetworkEntry.fromJson)
        .toList();
  }

  /// The last 100 log lines are in `result.output`.
  Future<TailarrServerActionResult> getLogs(String pod) async {
    final response = await httpClient.get('api/pods/$pod/logs');
    return TailarrServerActionResult.fromJson(response.data);
  }

  Future<List<TailarrServerBackup>> getBackups(String pod) async {
    final response = await httpClient.get('api/pods/$pod/backups');
    return (response.data['backups'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(TailarrServerBackup.fromJson)
        .toList();
  }

  /// `action` is one of: start, stop, update, remove.
  Future<TailarrServerActionResult> podAction(
    String pod,
    String action,
  ) async {
    final response = await httpClient.post(
      'api/pods/$pod/action',
      data: {'do': action},
      options: Options(receiveTimeout: _longOperation),
    );
    return TailarrServerActionResult.fromJson(response.data);
  }

  Future<TailarrServerActionResult> createBackup(
    String pod, {
    String reason = '',
  }) async {
    final response = await httpClient.post(
      'api/pods/$pod/backups',
      data: {'reason': reason},
      options: Options(receiveTimeout: _longOperation),
    );
    return TailarrServerActionResult.fromJson(response.data);
  }

  Future<TailarrServerActionResult> restoreBackup(
    String pod,
    String ts,
  ) async {
    final response = await httpClient.post(
      'api/pods/$pod/backups/restore',
      data: {'ts': ts},
      options: Options(receiveTimeout: _longOperation),
    );
    return TailarrServerActionResult.fromJson(response.data);
  }

  Future<TailarrServerActionResult> deleteBackup(
    String pod,
    String ts,
  ) async {
    final response = await httpClient.post(
      'api/pods/$pod/backups/delete',
      data: {'ts': ts},
    );
    return TailarrServerActionResult.fromJson(response.data);
  }

  Future<TailarrServerUpdates> getUpdates() async {
    final response = await httpClient.get('api/updates');
    return TailarrServerUpdates.fromJson(response.data);
  }

  Future<void> refreshUpdates() async {
    await httpClient.post('api/updates/refresh');
  }

  ////////////
  /// USERS ///
  ////////////

  Future<TailarrServerUsers> getUsers() async {
    final response = await httpClient.get('api/users');
    return TailarrServerUsers.fromJson(response.data);
  }

  /// Mint a single-use, preauthorized, 24h enrollment key tagged
  /// `tag:tailarr-user`.
  Future<TailarrServerUserKey> createUserKey() async {
    final response = await httpClient.post('api/users/keys', data: {});
    return TailarrServerUserKey.fromJson(response.data);
  }

  Future<TailarrServerAdoptResult> adoptUser(String nodeId) async {
    final response = await httpClient.post(
      'api/users/adopt',
      data: {'id': nodeId},
    );
    return TailarrServerAdoptResult.fromJson(response.data);
  }

  /// Empty [nickname] clears it; the server truncates to 40 chars.
  Future<void> setUserNickname(String nodeId, String nickname) async {
    await httpClient.post('api/users/$nodeId', data: {'nickname': nickname});
  }

  /// Revoke a single device: deauthorize its tailnet node and drop its person
  /// binding. Contract (pending server support — see issue #1): the route
  /// 404s until the server ships it, so a revoke is inert (surfaces "unknown
  /// request") rather than harmful meanwhile. NEVER call this for the caller's
  /// own device — the app guards that in the UI (leave via Settings instead).
  Future<TailarrServerActionResult> revokeDevice(String nodeId) async {
    final response = await httpClient.post(
      'api/users/$nodeId/device',
      data: {'do': 'revoke'},
    );
    return TailarrServerActionResult.fromJson(response.data);
  }

  /// Grant/revoke a service by flipping `tag:tailarr-can-<service>` —
  /// effective in seconds, no pod restart.
  Future<TailarrServerActionResult> setUserAccess(
    String nodeId,
    String service,
    bool allow,
  ) async {
    final response = await httpClient.post(
      'api/users/$nodeId/access',
      data: {'service': service, 'allow': allow},
    );
    return TailarrServerActionResult.fromJson(response.data);
  }

  //////////////
  /// PEOPLE ///
  //////////////
  // Server v0.19.0+ first-class users. Detect support by
  // TailarrServerUsers.hasPeople, NOT api_version (still 1).

  /// Create a person and mint their first enrollment key — the device that
  /// enrolls with it is born owned by them.
  Future<TailarrServerPersonKey> addPerson(String name) async {
    final response = await httpClient.post(
      'api/people',
      data: {'do': 'add', 'name': name},
    );
    return TailarrServerPersonKey.fromJson(response.data);
  }

  /// Mint a fresh single-use key for an existing person — the new device
  /// automatically belongs to them and inherits their access.
  Future<TailarrServerPersonKey> reissuePersonKey(String id) async {
    final response = await httpClient.post(
      'api/people',
      data: {'do': 'reissue', 'id': id},
    );
    return TailarrServerPersonKey.fromJson(response.data);
  }

  Future<TailarrServerActionResult> renamePerson(
    String id,
    String name,
  ) async {
    final response = await httpClient.post(
      'api/people',
      data: {'do': 'rename', 'id': id, 'name': name},
    );
    return TailarrServerActionResult.fromJson(response.data);
  }

  /// Their devices stay enrolled but lose all access.
  Future<TailarrServerActionResult> deletePerson(String id) async {
    final response = await httpClient.post(
      'api/people',
      data: {'do': 'delete', 'id': id},
    );
    return TailarrServerActionResult.fromJson(response.data);
  }

  /// Attach an unassigned machine ([nodeId]) to person [id].
  Future<TailarrServerActionResult> assignDevice(
    String id,
    String nodeId,
  ) async {
    final response = await httpClient.post(
      'api/people',
      data: {'do': 'assign', 'id': id, 'node': nodeId},
    );
    return TailarrServerActionResult.fromJson(response.data);
  }

  /// Grant/revoke a service for a PERSON — applies to all their devices.
  Future<TailarrServerActionResult> setPersonAccess(
    String id,
    String service,
    bool allow,
  ) async {
    final response = await httpClient.post(
      'api/people/$id/access',
      data: {'service': service, 'allow': allow},
    );
    return TailarrServerActionResult.fromJson(response.data);
  }

  /// Issue/fetch the person's ntfy credentials (server v0.20.0+; gated on
  /// TailarrServerUsers.ntfy). Topics mirror their access badges.
  Future<TailarrServerNotificationCredentials> getPersonNotifications(
    String id,
  ) async {
    final response = await httpClient.post(
      'api/people/$id/notifications',
      data: {},
    );
    return TailarrServerNotificationCredentials.fromJson(response.data);
  }

  /// Expose a pod publicly via Tailscale Funnel (or make it private again).
  /// Live flip — rewrites the sidecar's serve config, no pod restart.
  Future<TailarrServerActionResult> setFunnel(
    String pod,
    bool enabled,
  ) async {
    final response = await httpClient.post(
      'api/network/$pod',
      data: {'funnel': enabled},
      options: Options(receiveTimeout: _longOperation),
    );
    return TailarrServerActionResult.fromJson(response.data);
  }

  /// `action` is one of: start, stop, restart, rerender. Never touches the
  /// controller pod.
  Future<TailarrServerFleetResult> fleetAction(String action) async {
    final response = await httpClient.post(
      'api/fleet',
      data: {'do': action},
      options: Options(receiveTimeout: _longOperation),
    );
    return TailarrServerFleetResult.fromJson(response.data);
  }
}

/// Tolerates a TRANSIENT controller 401/403 on the connected-check reads before
/// concluding the device is unenrolled (B26).
///
/// The embedded `tailscale serve` proxy can briefly drop the admin bearer from
/// a `GET api/pods` / `api/network` during its settling window, so a genuinely
/// enrolled device sees a lone 401 that a retry always clears. Without this a
/// single transient miss reverted the whole Tailarr Server module to its
/// enrollment gate AND minted a duplicate admin token on the reconnect — a pile
/// of them accumulated in the server's `.tokens.json`.
///
/// So a 401/403 on an idempotent GET is retried a small, bounded number of times
/// with short backoff. Only a SUSTAINED failure — N consecutive definitive 401s
/// — or a 401 on a mutating POST surfaces as [ServerAuthRequiredException], so
/// the genuinely-unenrolled / revoked path still shows "Connect This Device".
class TailarrServerAuthInterceptor extends Interceptor {
  TailarrServerAuthInterceptor(
    this._dio, {
    this.maxRetries = 3,
    this.backoff = const Duration(milliseconds: 300),
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? Future<void>.delayed;

  final Dio _dio;
  final int maxRetries;
  final Duration backoff;
  final Future<void> Function(Duration) _sleep;

  /// Per-request retry counter, carried on the request's own extras so the
  /// re-dispatch through the interceptor chain can't loop forever.
  static const _extraKey = 'tailarr_auth_retries';

  @override
  Future<void> onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    final code = response.statusCode;
    if (code != 401 && code != 403) return handler.next(response);

    final options = response.requestOptions;
    final isGet = options.method.toUpperCase() == 'GET';
    final attempts = (options.extra[_extraKey] as int?) ?? 0;

    if (isGet && attempts < maxRetries) {
      await _sleep(backoff * (attempts + 1));
      options.extra[_extraKey] = attempts + 1;
      try {
        return handler.resolve(await _dio.fetch(options));
      } on DioException catch (e) {
        // The retry itself failed (another transient 401 exhausted the budget,
        // or a genuine network error) — propagate that outcome unchanged.
        return handler.reject(e, true);
      }
    }

    // Definitive: no bearer, or a genuinely revoked/stale one.
    return handler.reject(
      DioException(
        requestOptions: options,
        response: response,
        type: DioExceptionType.badResponse,
        error: const ServerAuthRequiredException(),
      ),
    );
  }
}
