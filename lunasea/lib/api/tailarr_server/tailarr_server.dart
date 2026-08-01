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

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:lunasea/system/network/tailscale_retry.dart';
import 'package:lunasea/api/tailarr_server/models.dart';
// ignore: always_use_package_imports
import 'package:lunasea/system/network/platform/fresh_connection_stub.dart'
    if (dart.library.io) 'package:lunasea/system/network/platform/fresh_connection_io.dart'
    if (dart.library.html) 'package:lunasea/system/network/platform/fresh_connection_html.dart';

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

  /// Serializes + dedupes the module's idempotent GET reads (B26). See
  /// [_GetGate] — keeps a startup burst (pods+network+users+ai+updates) from
  /// hammering `tailscale serve` all at once, so one poisoned connection can't
  /// 401-storm the entire refresh.
  final _GetGate _gate = _GetGate();

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

  Future<TailarrServerInfo> getInfo() =>
      _gate.run('GET api/info', () async {
        final response = await httpClient.get('api/info');
        return TailarrServerInfo.fromJson(response.data);
      });

  Future<List<TailarrServerPod>> getPods() =>
      _gate.run('GET api/pods', () async {
        final response = await httpClient.get('api/pods');
        return (response.data['pods'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(TailarrServerPod.fromJson)
            .toList();
      });

  Future<List<TailarrServerNetworkEntry>> getNetwork() =>
      _gate.run('GET api/network', () async {
        final response = await httpClient.get('api/network');
        return (response.data['network'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(TailarrServerNetworkEntry.fromJson)
            .toList();
      });

  /// The last 100 log lines are in `result.output`.
  Future<TailarrServerActionResult> getLogs(String pod) =>
      _gate.run('GET api/pods/$pod/logs', () async {
        final response = await httpClient.get('api/pods/$pod/logs');
        return TailarrServerActionResult.fromJson(response.data);
      });

  Future<List<TailarrServerBackup>> getBackups(String pod) =>
      _gate.run('GET api/pods/$pod/backups', () async {
        final response = await httpClient.get('api/pods/$pod/backups');
        return (response.data['backups'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(TailarrServerBackup.fromJson)
            .toList();
      });

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

  Future<TailarrServerUpdates> getUpdates() =>
      _gate.run('GET api/updates', () async {
        final response = await httpClient.get('api/updates');
        return TailarrServerUpdates.fromJson(response.data);
      });

  Future<void> refreshUpdates() async {
    await httpClient.post('api/updates/refresh');
  }

  ////////////
  /// USERS ///
  ////////////

  Future<TailarrServerUsers> getUsers() =>
      _gate.run('GET api/users', () async {
        final response = await httpClient.get('api/users');
        return TailarrServerUsers.fromJson(response.data);
      });

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
  Future<TailarrServerAIConfig> getAIConfig() =>
      _gate.run('GET api/ai', () async {
        final response = await httpClient.get('api/ai');
        return TailarrServerAIConfig.fromJson(response.data);
      });

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
/// So a 401/403 on an idempotent GET is retried a bounded number of times with
/// exponential backoff, and CRUCIALLY each retry is fetched over a BRAND-NEW
/// connection ([freshConnectionFetch] — a throwaway Dio with its own pool, plus
/// `persistentConnection = false` so dart:io doesn't keep the socket).
/// Re-fetching through the module's shared client would just grab the same
/// poisoned pooled socket again — the connection-pool poisoning that made a
/// whole request burst 401 at once (B26). The wider budget (default 5 tries, up
/// to ~6s) rides a multi-second serve settling storm without reverting.
///
/// Only a SUSTAINED failure — the retry budget exhausted on definitive 401s — or
/// a 401 on a mutating POST surfaces as [ServerAuthRequiredException], so the
/// genuinely-unenrolled / revoked path still shows "Connect This Device".
class TailarrServerAuthInterceptor extends Interceptor {
  TailarrServerAuthInterceptor(
    Dio dio, {
    this.maxRetries = 5,
    this.backoff = const Duration(milliseconds: 300),
    this.maxBackoff = const Duration(seconds: 2),
    Future<void> Function(Duration)? sleep,
    Future<Response<dynamic>> Function(RequestOptions)? freshFetch,
  })  : _sleep = sleep ?? Future<void>.delayed,
        _freshFetch = freshFetch ?? freshConnectionFetch;

  final int maxRetries;
  final Duration backoff;
  final Duration maxBackoff;
  final Future<void> Function(Duration) _sleep;
  final Future<Response<dynamic>> Function(RequestOptions) _freshFetch;

  /// Per-request retry counter, carried on the request's own extras (diagnostic
  /// + a belt-and-braces loop guard).
  static const _extraKey = 'tailarr_auth_retries';

  /// Exponential backoff, capped at [maxBackoff]: 300ms, 600, 1200, 2000, 2000…
  Duration _delayFor(int attempt) {
    final ms = backoff.inMilliseconds * (1 << attempt);
    final capped = ms > maxBackoff.inMilliseconds ? maxBackoff.inMilliseconds : ms;
    return Duration(milliseconds: capped);
  }

  @override
  Future<void> onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    final code = response.statusCode;
    if (code != 401 && code != 403) return handler.next(response);

    final options = response.requestOptions;
    // Only idempotent GETs are safe to replay; a 401 on a mutating POST is
    // surfaced immediately.
    if (options.method.toUpperCase() != 'GET') {
      return handler.reject(_authError(options, response));
    }

    // Never reuse the poisoned pooled connection: the retry is dispatched over a
    // brand-new pool by [_freshFetch]; persistentConnection=false additionally
    // tells dart:io not to keep the socket (it emits `Connection: close`). On
    // web this field is simply inert (no dart:io pool, and `Connection` is a
    // browser-forbidden header we must not set by hand).
    options.persistentConnection = false;

    var current = response;
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      await _sleep(_delayFor(attempt));
      options.extra[_extraKey] = attempt + 1;
      try {
        current = await _freshFetch(options);
      } on DioException catch (e) {
        // A genuine network error on the retry — propagate unchanged.
        return handler.reject(e, true);
      }
      final c = current.statusCode;
      if (c != 401 && c != 403) return handler.resolve(current);
    }

    // Budget exhausted on definitive 401/403s: no bearer, or a revoked/stale one.
    return handler.reject(_authError(options, current));
  }

  DioException _authError(RequestOptions options, Response response) =>
      DioException(
        requestOptions: options,
        response: response,
        type: DioExceptionType.badResponse,
        error: const ServerAuthRequiredException(),
      );
}

/// Serializes + dedupes the Tailarr Server module's idempotent GET reads (B26).
///
/// The module opens by firing pods+network+updates (and, on their screens,
/// users+ai) — a simultaneous burst through the embedded `tailscale serve`
/// proxy. Under that burst the proxy intermittently poisons a connection
/// (dropping the bearer), and because the whole set fired at once a single
/// poisoned connection could 401-storm the ENTIRE refresh, blowing the retry
/// budget and reverting the module to its enrollment gate (re-pairing, minting
/// duplicate admin tokens).
///
/// This gate caps concurrent GETs ([maxConcurrent], default 2 — enough to keep
/// the slow `getNetwork` off the critical `getPods` path, few enough that a
/// burst can't all hit serve at once) and shares an already-in-flight GET for
/// the same key instead of re-issuing it. Mutating POSTs never go through here.
class _GetGate {
  /// Enough to keep the slow `getNetwork` off the critical `getPods` path, few
  /// enough that a startup burst can't all hit serve at once (B26).
  static const maxConcurrent = 2;

  int _active = 0;
  final _waiters = <Completer<void>>[];
  final _inFlight = <String, Future<dynamic>>{};

  Future<T> run<T>(String key, Future<T> Function() op) {
    final existing = _inFlight[key];
    if (existing != null) return existing.then((v) => v as T);
    late final Future<T> future;
    future = _guarded(op).whenComplete(() {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  Future<T> _guarded<T>(Future<T> Function() op) async {
    await _acquire();
    try {
      return await op();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    // The permit is granted by _release (which leaves _active untouched when it
    // hands off), so the waiter does NOT increment — see _release.
    return waiter.future;
  }

  void _release() {
    // Conserve the permit: hand it DIRECTLY to the next waiter without touching
    // _active. Decrementing here and letting the woken waiter re-increment would
    // briefly free the slot, so a fresh acquire() racing this release could grab
    // it too — admitting a 3rd concurrent GET past maxConcurrent (the permit
    // race codex caught). Only drop the count when nobody is waiting.
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _active--;
    }
  }
}
