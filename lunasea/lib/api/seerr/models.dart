/// Models for the per-person request-portal (Seerr / Jellyseerr) self-service
/// contract, served by the tailarr-gate node exactly like /self/jellyfin: the
/// gateway whois-authenticates the caller by tailnet source address and scopes
/// every call to THAT person's own portal account. No admin key, no credential
/// ever travels in the request — the member stays password-free.
///
/// Two ops back the app's Request-portal module:
///   * `GET  self/seerr`        (want:"seerr")        — cheap status snapshot,
///     no session minted. Drives module VISIBILITY (like `self/jellyfin`).
///   * `POST self/seerr/signin` (want:"seerr-signin") — the app-brokered
///     sign-in. Replays the member's stored Jellyfin password into Seerr
///     server-side and hands back a `connect.sid` session cookie + portal URL,
///     so the portal opens already signed in.
///
/// Build against these shapes now — the gate routes go live when the server
/// deploy lands. Until then a pre-support gate 404s and the module hides
/// cleanly (mirrors how the Jellyfin module shipped ahead of "server release
/// 2"). See ~/projects/tailarr-ops/handoff/app-seerr-portal-followup.md.
library seerr_models;

/// The Seerr session cookie the broker hands back, in the exact shape the app
/// injects into the portal webview. Only `connect.sid` is ever returned. The
/// server sends no `domain` — the app scopes the cookie to the portal `url`
/// host itself (the tailnet MagicDNS name).
class SeerrCookie {
  final String name;
  final String value;

  /// Absolute expiry as UNIX seconds; 0 means a session cookie (cleared when
  /// the webview's cookie store is torn down).
  final int expires;
  final String path;

  const SeerrCookie({
    required this.name,
    required this.value,
    required this.expires,
    required this.path,
  });

  bool get isValid => name.isNotEmpty && value.isNotEmpty;

  factory SeerrCookie.fromJson(Map<String, dynamic> json) {
    return SeerrCookie(
      name: (json['name'] as String? ?? '').trim(),
      value: (json['value'] as String? ?? '').trim(),
      expires: _asInt(json['expires']),
      path: (json['path'] as String? ?? '/').trim().isEmpty
          ? '/'
          : (json['path'] as String).trim(),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }
}

/// Shared refusal-classification over the `{ok, error}` envelope, so the status
/// snapshot and the sign-in result read the server's graceful-degradation
/// strings identically. Matched narrowly (as the Jellyfin module does) so an
/// incidental substring can never authoritatively disable a working module — an
/// unrecognized refusal falls through to "preserve stored state".
mixin SeerrEnvelope {
  bool get ok;
  String? get error;
  int? get statusCode;

  String get _err => (error ?? '').toLowerCase();

  /// The server predates the /self/seerr gate routes (deploy not landed yet):
  /// a clean 404 or the gateway's "unknown request" refusal. The module hides
  /// and treats Requests as "not available yet".
  bool get isUnavailable =>
      statusCode == 404 || _err.contains('unknown request');

  /// This person has no request-portal access — no `seerr` badge, or the pod
  /// isn't deployed. The module hides.
  bool get hasNoAccess =>
      !ok &&
      !isUnavailable &&
      (_err.contains('no request-portal access') ||
          _err.contains('request-portal access'));

  /// The person holds `seerr` but has no Jellyfin identity to sign in with —
  /// the server couples them. Show a soft "ask your admin for Jellyfin access"
  /// state, not an error.
  bool get needsJellyfin =>
      !ok &&
      (_err.contains('no jellyfin identity') ||
          _err.contains('grant jellyfin access'));

  /// The portal account exists in principle but isn't provisioned/enabled yet
  /// (import still settling, or "not ready"). Show a soft "being set up" state
  /// with a retry — transient, not a hard error.
  bool get isNotReady =>
      !ok &&
      !needsJellyfin &&
      (_err.contains('not ready') ||
          _err.contains('not active') ||
          _err.contains('being set up'));

  /// The gateway's "this machine isn't attached to any person" refusal — the
  /// fix is an admin action (assign the device), not a retry.
  bool get isUnassigned => !ok && _err.contains('not assigned');
}

/// `GET self/seerr` (want:"seerr") — a cheap read-only snapshot of the person's
/// request-portal availability, minting NO Seerr session. Drives whether the
/// Requests module entry is shown, exactly like [JellyfinSelf] does for
/// Jellyfin. Mirrors op_person_jellyfin's read-only shape.
class SeerrSelf with SeerrEnvelope {
  @override
  final bool ok;
  @override
  final String? error;
  @override
  final int? statusCode;

  /// The portal pod name (e.g. "seerr").
  final String pod;

  /// The person's portal base URL (https MagicDNS). Empty while the pod is
  /// stopped — callers keep the previously known value rather than clearing it.
  final String url;

  const SeerrSelf({
    required this.ok,
    required this.error,
    required this.pod,
    required this.url,
    this.statusCode,
  });

  /// Whether this device's person currently has a usable request portal. Only a
  /// clean `ok:true` counts; every refusal reads as "hide the module".
  bool get isAvailable => ok;

  factory SeerrSelf.fromJson(
    Map<String, dynamic> json, {
    int? statusCode,
  }) {
    final error = json['error'];
    return SeerrSelf(
      ok: json['ok'] == true,
      statusCode: statusCode,
      error: error == null ? null : error.toString(),
      pod: (json['pod'] as String? ?? '').trim(),
      url: (json['url'] as String? ?? '').trim().replaceAll(RegExp(r'/+$'), ''),
    );
  }
}

/// `POST self/seerr/signin` (want:"seerr-signin") — the app-brokered sign-in.
/// On `ok` it carries the portal `url` + the `connect.sid` [cookie] the app
/// pre-sets in the webview so the member lands already signed in. Refusals
/// classify via [SeerrEnvelope] (not-ready / needs-Jellyfin / no-access /
/// unavailable / transient).
class SeerrSignin with SeerrEnvelope {
  @override
  final bool ok;
  @override
  final String? error;
  @override
  final int? statusCode;

  final String pod;
  final String url;
  final SeerrCookie? cookie;

  const SeerrSignin({
    required this.ok,
    required this.error,
    required this.pod,
    required this.url,
    required this.cookie,
    this.statusCode,
  });

  /// A fully brokered, openable session: ok, a portal URL, and a valid cookie.
  bool get isReady =>
      ok && url.isNotEmpty && cookie != null && cookie!.isValid;

  /// A transient sign-in failure (HTTP error, no session returned, or a
  /// classified refusal we didn't recognize) — offer a retry.
  bool get isTransient =>
      !ok &&
      !isUnavailable &&
      !hasNoAccess &&
      !needsJellyfin &&
      !isNotReady &&
      !isUnassigned;

  factory SeerrSignin.fromJson(
    Map<String, dynamic> json, {
    int? statusCode,
  }) {
    final error = json['error'];
    final cookie = json['cookie'];
    return SeerrSignin(
      ok: json['ok'] == true,
      statusCode: statusCode,
      error: error == null ? null : error.toString(),
      pod: (json['pod'] as String? ?? '').trim(),
      url: (json['url'] as String? ?? '').trim().replaceAll(RegExp(r'/+$'), ''),
      cookie: cookie is Map<String, dynamic>
          ? SeerrCookie.fromJson(cookie)
          : null,
    );
  }
}
