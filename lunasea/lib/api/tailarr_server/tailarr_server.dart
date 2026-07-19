/// Dart client for the Tailarr Server JSON API — the Podman/tailnet homelab
/// controller (github.com/scs32/tailarr-server).
///
/// The server has no authentication: it is reachable only over the tailnet,
/// so the host should be an `https://*.ts.net` URL routed through the app's
/// embedded Tailscale node.
library tailarr_server;

import 'package:dio/dio.dart';
import 'package:lunasea/api/tailarr_server/models.dart';

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
