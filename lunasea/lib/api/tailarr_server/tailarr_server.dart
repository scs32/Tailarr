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
    // Surface a controller auth rejection as a typed error so screens can offer
    // "Connect this device" instead of rendering empty data / a raw failure.
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          final code = response.statusCode;
          if (code == 401 || code == 403) {
            return handler.reject(
              DioException(
                requestOptions: response.requestOptions,
                response: response,
                type: DioExceptionType.badResponse,
                error: const ServerAuthRequiredException(),
              ),
            );
          }
          handler.next(response);
        },
      ),
    );
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

  ////////////////////////
  /// AI PROVIDER CONFIG ///
  ////////////////////////
  // Admin-gated voice-AI provider key (server: `op_ai_config_set/clear`). The
  // raw key is write-only — `GET /api/ai` returns only provider/model/key_set,
  // never the key itself.

  /// Current AI-provider config. NEVER carries the raw key — only whether one
  /// is set. A 401/403 surfaces as [ServerAuthRequiredException] (not admin /
  /// not connected), same as every other `/api/*` read.
  Future<TailarrServerAIConfig> getAIConfig() async {
    final response = await httpClient.get('api/ai');
    return TailarrServerAIConfig.fromJson(response.data);
  }

  /// Set the AI provider + raw key (stored 0600 server-side, never echoed). The
  /// key is sent write-only and is not retained in the app.
  Future<TailarrServerAIConfigResult> setAIConfig({
    required String provider,
    required String apiKey,
    required String model,
  }) async {
    final response = await httpClient.post(
      'api/ai',
      data: {
        'do': 'set',
        'provider': provider,
        'api_key': apiKey,
        'model': model,
      },
    );
    return TailarrServerAIConfigResult.fromJson(response.data);
  }

  /// Forget the AI provider config (removes the stored key).
  Future<TailarrServerAIConfigResult> clearAIConfig() async {
    final response = await httpClient.post(
      'api/ai',
      data: {'do': 'clear'},
    );
    return TailarrServerAIConfigResult.fromJson(response.data);
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
