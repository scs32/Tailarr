/// Models for the per-person Jellyfin self-service contract, served by the
/// tailarr-gate node exactly like /self/notifications and /self/services: the
/// gateway whois-authenticates the caller by tailnet source address and scopes
/// every call to THAT person's own Jellyfin account. No admin key, no
/// credential ever travels in the request.
///
/// Contract: server release 2 (the release after tailarr-server v0.66.0). Build
/// against these shapes now — the handlers go live when that release ships.
library jellyfin_models;

/// One Jellyfin library the admin granted this person, from
/// `GET http://tailarr-gate/self/jellyfin` (`libraries: [{id, name}]`).
class JellyfinLibrary {
  final String id;
  final String name;

  const JellyfinLibrary({required this.id, required this.name});

  factory JellyfinLibrary.fromJson(Map<String, dynamic> json) {
    return JellyfinLibrary(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] as String? ?? '').trim(),
    );
  }
}

/// `GET http://tailarr-gate/self/jellyfin` — the person's own Jellyfin account
/// snapshot (URL, username, password/Quick-Connect state, granted libraries).
class JellyfinSelf {
  final bool ok;
  final String? error;

  /// The person's Jellyfin base URL (https MagicDNS). Empty while the pod is
  /// stopped — callers keep the previously known value rather than clearing it.
  final String url;
  final String username;
  final bool hasPassword;
  final bool quickConnectEnabled;
  final List<JellyfinLibrary> libraries;

  /// HTTP status of the gateway response — surfaced so failure states are
  /// never blind to what actually came back.
  final int? statusCode;

  const JellyfinSelf({
    required this.ok,
    required this.error,
    required this.url,
    required this.username,
    required this.hasPassword,
    required this.quickConnectEnabled,
    required this.libraries,
    this.statusCode,
  });

  String get _err => (error ?? '').toLowerCase();

  /// The server predates the /self/jellyfin endpoints (older than server
  /// release 2): a clean 404 or the gateway's "unknown request" refusal. The
  /// module hides cleanly and treats Jellyfin as "not available yet".
  bool get isUnavailable => statusCode == 404 || _err.contains('unknown request');

  /// This person has no Jellyfin badge — the endpoint refuses with a
  /// "no Jellyfin access"-class error. The module hides.
  bool get hasNoAccess =>
      !ok && !isUnavailable && (_err.contains('access') || _err.contains('badge'));

  /// The gateway's "this machine isn't attached to any person" refusal — the
  /// fix is an admin action (assign the device), not a retry.
  bool get isUnassigned => !ok && _err.contains('not assigned');

  /// Whether this device's person currently has a Jellyfin account. Only a
  /// clean `ok:true` counts — every refusal (unavailable / no access /
  /// unassigned) reads as "hide the module".
  bool get isAvailable => ok;

  factory JellyfinSelf.fromJson(
    Map<String, dynamic> json, {
    int? statusCode,
  }) {
    final error = json['error'];
    final libraries = json['libraries'];
    return JellyfinSelf(
      ok: json['ok'] == true,
      statusCode: statusCode,
      error: error == null ? null : error.toString(),
      url: (json['url'] as String? ?? '').trim().replaceAll(RegExp(r'/+$'), ''),
      username: (json['username'] as String? ?? '').trim(),
      hasPassword: json['has_password'] == true,
      quickConnectEnabled: json['quick_connect_enabled'] == true,
      libraries: libraries is List
          ? libraries
              .whereType<Map<String, dynamic>>()
              .map(JellyfinLibrary.fromJson)
              .toList()
          : const [],
    );
  }
}

/// One active session/device on the person's Jellyfin account, from
/// `GET http://tailarr-gate/self/jellyfin/devices`.
class JellyfinDevice {
  final String id;
  final String name;
  final String client;

  /// Last-active time as a UNIX timestamp in SECONDS (server v0.68.0 sends a
  /// number; a numeric string is tolerated). Null when absent/unparseable.
  final int? lastActiveEpoch;

  const JellyfinDevice({
    required this.id,
    required this.name,
    required this.client,
    this.lastActiveEpoch,
  });

  /// The last-active instant (UTC), or null when the server sent no timestamp.
  DateTime? get lastActiveAt => lastActiveEpoch == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(
          lastActiveEpoch! * 1000,
          isUtc: true,
        );

  factory JellyfinDevice.fromJson(Map<String, dynamic> json) {
    return JellyfinDevice(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] as String? ?? '').trim(),
      client: (json['client'] as String? ?? '').trim(),
      lastActiveEpoch: _epochSeconds(json['last_active']),
    );
  }

  static int? _epochSeconds(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}

/// `GET http://tailarr-gate/self/jellyfin/devices` — the person's own sessions.
class JellyfinDevices {
  final bool ok;
  final String? error;
  final List<JellyfinDevice> devices;
  final int? statusCode;

  const JellyfinDevices({
    required this.ok,
    required this.error,
    required this.devices,
    this.statusCode,
  });

  factory JellyfinDevices.fromJson(
    Map<String, dynamic> json, {
    int? statusCode,
  }) {
    final error = json['error'];
    final devices = json['devices'];
    return JellyfinDevices(
      ok: json['ok'] == true,
      statusCode: statusCode,
      error: error == null ? null : error.toString(),
      devices: devices is List
          ? devices
              .whereType<Map<String, dynamic>>()
              .map(JellyfinDevice.fromJson)
              .toList()
          : const [],
    );
  }
}

/// The shared `{ok, error}` shape returned by the POST actions
/// (connect / signout / password).
class JellyfinActionResult {
  final bool ok;
  final String? error;
  final int? statusCode;

  const JellyfinActionResult({
    required this.ok,
    required this.error,
    this.statusCode,
  });

  factory JellyfinActionResult.fromJson(
    Map<String, dynamic> json, {
    int? statusCode,
  }) {
    final error = json['error'];
    return JellyfinActionResult(
      ok: json['ok'] == true,
      statusCode: statusCode,
      error: error == null ? null : error.toString(),
    );
  }
}
