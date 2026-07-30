/// Models for the ntfy (ntfy.sh) publish-subscribe protocol, as served by
/// the Tailarr Server ntfy system pod.
library ntfy_models;

import 'dart:convert';

/// A subscription handed out by the server: where the ntfy pod lives, the
/// access token to read with, and which topics to follow. This is the exact
/// shape the server's future QR / deep-link handout delivers:
/// `{"url": "https://…", "token": "tk_…", "topics": ["tlr-ops", …]}`.
class NtfySubscription {
  final String url;
  final String token;
  final List<String> topics;

  const NtfySubscription({
    required this.url,
    required this.token,
    required this.topics,
  });

  bool get isValid => url.isNotEmpty && topics.isNotEmpty;

  factory NtfySubscription.fromJson(Map<String, dynamic> json) {
    return NtfySubscription(
      url: (json['url'] as String? ?? '').trim().replaceAll(RegExp(r'/+$'), ''),
      token: (json['token'] as String? ?? '').trim(),
      topics: (json['topics'] as List? ?? [])
          .map((t) => t.toString().trim())
          .where((t) => t.isNotEmpty)
          .toList(),
    );
  }

  /// Parses a `tailarr://ntfy?url=…&token=…&topics=a,b` deep link, or the
  /// same parameters carried by any URI (the future QR payload).
  factory NtfySubscription.fromUri(Uri uri) {
    return NtfySubscription.fromJson({
      'url': uri.queryParameters['url'] ?? '',
      'token': uri.queryParameters['token'] ?? '',
      'topics': (uri.queryParameters['topics'] ?? '').split(','),
    });
  }

  /// Accepts either the JSON handout or a deep-link/QR URI as pasted text.
  /// Returns null if the input parses but contains no usable subscription.
  static NtfySubscription? parse(String input) {
    final text = input.trim();
    NtfySubscription? result;
    if (text.startsWith('{')) {
      try {
        result = NtfySubscription.fromJson(json.decode(text));
      } catch (_) {
        return null;
      }
    } else {
      final uri = Uri.tryParse(text);
      if (uri == null) return null;
      result = NtfySubscription.fromUri(uri);
    }
    return result.isValid ? result : null;
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'token': token,
        'topics': topics,
      };
}

/// `GET http://tailarr-gate/self/notifications` (tailarr-server v0.21.0+).
/// The gateway whois-authenticates the caller by tailnet source address and
/// returns THAT person's ntfy credentials — no auth material in the request.
class NtfyGatewayCredentials {
  final bool ok;
  final String? error;
  final String url;
  final String user;
  final String password;
  final String token;
  final List<String> topics;

  /// HTTP status of the gateway response — surfaced in the FAILED state so
  /// debugging is never blind to what actually came back.
  final int? statusCode;

  const NtfyGatewayCredentials({
    required this.ok,
    required this.error,
    required this.url,
    required this.user,
    required this.password,
    required this.token,
    required this.topics,
    this.statusCode,
  });

  /// The gateway's "this machine isn't attached to any person" refusal —
  /// the fix is an admin action (assign the device), not a retry.
  bool get isUnassigned =>
      !ok && (error ?? '').toLowerCase().contains('not assigned');

  NtfySubscription get subscription =>
      NtfySubscription(url: url, token: token, topics: topics);

  factory NtfyGatewayCredentials.fromJson(
    Map<String, dynamic> json, {
    int? statusCode,
  }) {
    final error = json['error'];
    return NtfyGatewayCredentials(
      ok: json['ok'] == true,
      statusCode: statusCode,
      error: error == null ? null : error.toString(),
      url: (json['url'] as String? ?? '')
          .trim()
          .replaceAll(RegExp(r'/+$'), ''),
      user: json['user'] as String? ?? '',
      password: json['password'] as String? ?? '',
      token: json['token'] as String? ?? '',
      topics:
          (json['topics'] as List? ?? []).map((t) => t.toString()).toList(),
    );
  }
}

/// One service the calling person is badged for, as handed out by
/// `GET http://tailarr-gate/self/services` (tailarr-server v0.23.0+).
class GatewayService {
  /// `sonarr` | `radarr` | `lidarr` map to native connection modules;
  /// `tailarr` is the app's own server module (auth is always null);
  /// `external` — and any type this app version does not recognize — renders
  /// as an External Module bookmark so nothing shared is ever invisible.
  final String type;

  /// Pod/service name — the stable identifier for reconciliation.
  final String name;

  /// HTTPS tailnet URL. May be empty while the service is stopped (the
  /// MagicDNS name lives in its sidecar) — keep the previously stored value.
  final String url;

  /// Native-type credential (`{"api_key": …}` for the Arrs). null means
  /// "create/keep the module but the credential is missing" — keep what is
  /// stored and let the user fill just that field.
  final Map<String, dynamic>? auth;

  const GatewayService({
    required this.type,
    required this.name,
    required this.url,
    this.auth,
  });

  String get apiKey => (auth?['api_key'] ?? '').toString();

  /// NZBGet-style credentials (`{"user": …, "password": …}`) — user may
  /// legitimately be empty.
  String get authUser => (auth?['user'] ?? '').toString();
  String get authPassword => (auth?['password'] ?? '').toString();

  factory GatewayService.fromJson(Map<String, dynamic> json) {
    return GatewayService(
      type: (json['type'] as String? ?? '').trim().toLowerCase(),
      name: (json['name'] as String? ?? '').trim(),
      url: (json['url'] as String? ?? '').trim().replaceAll(RegExp(r'/+$'), ''),
      auth: json['auth'] is Map<String, dynamic>
          ? json['auth'] as Map<String, dynamic>
          : null,
    );
  }
}

/// Per-person UX policy the server drives through `/self/services` (`ui`
/// object, server v0.27.0+). Absent → the full default experience. `basic`
/// is a preset the app resolves to a simplified shell; explicit overrides
/// (added later) win over it, so the server can re-shape the app without a
/// client release. UX only — it never gates access to a service.
class GatewayUiPolicy {
  final bool basic;

  const GatewayUiPolicy({this.basic = false});

  /// The default (no `ui` object) — full experience.
  static const GatewayUiPolicy full = GatewayUiPolicy();

  factory GatewayUiPolicy.fromJson(Map<String, dynamic> json) {
    return GatewayUiPolicy(basic: json['basic'] == true);
  }
}

/// `GET http://tailarr-gate/self/services` — same whois-authenticated
/// gateway as /self/notifications, answering "which services is this
/// device's person badged for".
class GatewayServicesResponse {
  final bool ok;
  final String? error;
  final String kind;

  /// null when the payload had no `services` key — an old controller
  /// (< 0.23.0) behind a new gateway answers with the notifications
  /// payload, which must read as "feature unavailable", not an error.
  final List<GatewayService>? services;

  /// Per-person UX policy — `full` when the server omits `ui`.
  final GatewayUiPolicy ui;

  /// The server's admin-chosen display name (rides `server.name`, server
  /// v0.49+). Empty when unset or on an older server — the app then keeps
  /// the host-derived profile name. Present here so a rename on the server
  /// follows onto an invite-joined profile on the next re-sync, without the
  /// device re-joining (it reaches the server through the gateway, not a
  /// user-entered host, so it never calls /api/info).
  final String serverName;
  final int? statusCode;

  const GatewayServicesResponse({
    required this.ok,
    required this.error,
    required this.kind,
    required this.services,
    this.ui = GatewayUiPolicy.full,
    this.serverName = '',
    this.statusCode,
  });

  /// The contract's version-skew check: consume only when the response is
  /// actually the services payload.
  bool get isSupported => services != null && kind == 'services';

  /// Server too old for this feature — old gateway (clean 404) or old
  /// controller (notifications payload). Degrade silently to manual config.
  bool get isUnavailable =>
      statusCode == 404 || (!isSupported && !isUnassigned);

  /// "this device is not assigned to a user" — the fix is an admin action
  /// (assign the device), not a retry.
  bool get isUnassigned =>
      !ok && (error ?? '').toLowerCase().contains('not assigned');

  /// APP-7: the account this device belonged to was removed from the server
  /// ENTIRELY. The gateway still resolves this device to a person id (its
  /// person tag hasn't been reconciled off yet), but the server no longer
  /// knows that person — it answers `{"ok": false, "error": "Unknown user."}`.
  /// This is DISTINCT from [isUnassigned]: an unassigned (or freshly-enrolled,
  /// not-yet-assigned) device carries no person id and gets "not assigned",
  /// which is recoverable by an admin assigning it — whereas an "unknown user"
  /// means the bound account is gone and the session can only recover via a
  /// fresh invite. The app uses this to drop a server-owned profile back to the
  /// safe no-server demo preview instead of a broken/stale session.
  bool get isAccountGone =>
      !ok && (error ?? '').toLowerCase().contains('unknown user');

  factory GatewayServicesResponse.fromJson(
    Map<String, dynamic> json, {
    int? statusCode,
  }) {
    final error = json['error'];
    final services = json['services'];
    return GatewayServicesResponse(
      ok: json['ok'] == true,
      statusCode: statusCode,
      error: error == null ? null : error.toString(),
      kind: (json['kind'] as String? ?? '').trim(),
      services: services is List
          ? services
              .whereType<Map<String, dynamic>>()
              .map(GatewayService.fromJson)
              .toList()
          : null,
      ui: json['ui'] is Map<String, dynamic>
          ? GatewayUiPolicy.fromJson(json['ui'] as Map<String, dynamic>)
          : GatewayUiPolicy.full,
      serverName: json['server'] is Map
          ? ((json['server'] as Map)['name'] as String? ?? '').trim()
          : '',
    );
  }
}

/// `POST http://tailarr-gate/self/push-token` (tailarr-server v0.26.0+):
/// registers/unregisters this device's APNs token for content-free wake
/// pushes. Whois-authenticated like every /self/* route.
class GatewayPushTokenResponse {
  final bool ok;
  final String? error;
  final bool registered;

  /// How many tokens the person now has (server caps at 10, oldest drop).
  final int count;
  final int? statusCode;

  const GatewayPushTokenResponse({
    required this.ok,
    required this.error,
    required this.registered,
    required this.count,
    this.statusCode,
  });

  bool get isUnassigned =>
      !ok && (error ?? '').toLowerCase().contains('not assigned');

  /// Pre-0.26.0 gateway: no POST handler at all → clean 404. Degrade
  /// silently to polling.
  bool get isUnavailable => statusCode == 404;

  factory GatewayPushTokenResponse.fromJson(
    Map<String, dynamic> json, {
    int? statusCode,
  }) {
    final error = json['error'];
    return GatewayPushTokenResponse(
      ok: json['ok'] == true,
      statusCode: statusCode,
      error: error == null ? null : error.toString(),
      registered: json['registered'] == true,
      count: json['count'] as int? ?? 0,
    );
  }
}

/// Maps a Tailarr topic name to its display label: `tlr-ops` is the server
/// itself, `tlr-media-<service>` is the service's name.
String ntfyTopicLabel(String topic) {
  if (topic == 'tlr-ops') return 'Server';
  if (topic.startsWith('tlr-media-')) {
    final service = topic.substring('tlr-media-'.length);
    if (service.isNotEmpty) {
      return service[0].toUpperCase() + service.substring(1);
    }
  }
  return topic;
}

/// A single message from an ntfy JSON/ndjson feed. Non-"message" events
/// (open, keepalive) are still parsed — callers filter on [isMessage].
class NtfyMessage {
  final String id;
  final int time;
  final String event;
  final String topic;
  final String? title;
  final String? message;
  final int priority;
  final List<String> tags;
  final String? attachmentName;
  final String? attachmentUrl;

  const NtfyMessage({
    required this.id,
    required this.time,
    required this.event,
    required this.topic,
    this.title,
    this.message,
    this.priority = 3,
    this.tags = const [],
    this.attachmentName,
    this.attachmentUrl,
  });

  bool get isMessage => event == 'message';

  /// A silent server→client "config-changed" control signal (v0.74.0+), NOT a
  /// user-facing notification: it rides the per-person `tlr-ctrl-<uid>` topic
  /// (tagged `tlr-config`, body `{"kind":"config","changed":[...]}`). The app
  /// keeps these OUT of the inbox and uses them to force an immediate
  /// self-config re-sync. Topic prefix is the primary signal; the tag is a
  /// secondary net in case routing changes.
  bool get isConfigControl =>
      topic.startsWith('tlr-ctrl-') || tags.contains('tlr-config');

  factory NtfyMessage.fromJson(Map<String, dynamic> json) {
    final attachment = json['attachment'] as Map<String, dynamic>?;
    return NtfyMessage(
      id: json['id'] as String? ?? '',
      time: json['time'] as int? ?? 0,
      event: json['event'] as String? ?? '',
      topic: json['topic'] as String? ?? '',
      title: json['title'] as String?,
      message: json['message'] as String?,
      priority: json['priority'] as int? ?? 3,
      tags: (json['tags'] as List? ?? []).map((t) => t.toString()).toList(),
      attachmentName: attachment?['name'] as String?,
      attachmentUrl: attachment?['url'] as String?,
    );
  }

  /// Parses one line of an ndjson feed; returns null for blank/broken lines.
  static NtfyMessage? fromLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return null;
    try {
      final decoded = json.decode(text);
      if (decoded is! Map<String, dynamic>) return null;
      return NtfyMessage.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }
}
