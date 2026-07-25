/// Strips credentials from strings before they are written to — or exported
/// from — the log.
///
/// Logs are viewable on-device, exportable to a shared file, AND in practice
/// screenshotted to send to support, so any secret that reaches a log string
/// can leak. Service requests carry credentials in the URL: the Arrs, Tautulli
/// and SABnzbd put `apikey` in the query string, and NZBGet puts
/// `user:password` in the path — so a single failed-request DioException
/// (whose toString() embeds the request URI) would otherwise persist a live
/// credential. Tailscale auth keys and ntfy tokens can likewise surface in
/// error text.
///
/// Best-effort and pattern-based: it targets the secret shapes THIS app
/// actually produces, not a universal scanner. Idempotent — scrubbing an
/// already-scrubbed string is a no-op — so it is safe to apply on both the
/// write and export paths.
class LogRedactor {
  LogRedactor._();

  static const mask = '<redacted>';

  static final List<_Rule> _rules = [
    // apikey / api_key / api_token / token / password as a URL query parameter
    // (Sonarr/Radarr/Lidarr/Tautulli/SABnzbd pass apikey in the query string).
    _Rule(
      RegExp(r'''([?&](?:api[_-]?key|api[_-]?token|token|passwd|password)=)[^&\s"']+''',
          caseSensitive: false),
      (m) => '${m[1]}$mask',
    ),
    // NZBGet builds https://host:port/user:password/jsonrpc — creds in the path.
    _Rule(
      RegExp(r'/[^/\s:@]+:[^/\s:@]+/jsonrpc', caseSensitive: false),
      (_) => '/$mask/jsonrpc',
    ),
    // Standard URL userinfo: scheme://user:password@host
    _Rule(
      RegExp(r'(://[^/\s:@]+:)[^/\s@]+@'),
      (m) => '${m[1]}$mask@',
    ),
    // Tailscale auth keys: tskey-auth-…, tskey-client-…, tskey-api-…
    _Rule(
      RegExp(r'tskey-[A-Za-z0-9_-]+'),
      (_) => 'tskey-$mask',
    ),
    // ntfy access tokens.
    _Rule(
      RegExp(r'tk_[A-Za-z0-9_-]+'),
      (_) => 'tk_$mask',
    ),
    // Auth-bearing HTTP headers (any scheme) as they appear in a Dio error's
    // header-map toString or a raw header line: X-Api-Key / Authorization /
    // Proxy-Authorization / X-Auth-Token. Capture the whole value up to a
    // structural delimiter so `Authorization: Bearer <jwt>` is fully covered.
    _Rule(
      RegExp(
          '''((?:x-api-key|x-auth-token|authorization|proxy-authorization)"?\\s*[:=]\\s*"?)[^,"'}\\]\\n]+''',
          caseSensitive: false),
      (m) => '${m[1]}$mask',
    ),
    // Bare Bearer token not preceded by a header name (free text / URLs).
    _Rule(
      RegExp(r'(bearer\s+)[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      (m) => '${m[1]}$mask',
    ),
    // Secret VALUES in a JSON body/map: {"apikey":"…"}, "token":"…",
    // "password":"…" — the shape a service response or logged payload uses.
    _Rule(
      RegExp(
          r'''("(?:api[_-]?key|api[_-]?token|apitoken|token|passwd|password|secret)"\s*:\s*")[^"]*''',
          caseSensitive: false),
      (m) => '${m[1]}$mask',
    ),
  ];

  /// Returns [input] with any recognized credential replaced by [mask].
  static String scrub(String input) {
    if (input.isEmpty) return input;
    var out = input;
    for (final rule in _rules) {
      out = out.replaceAllMapped(rule.pattern, rule.replace);
    }
    return out;
  }

  /// Null-safe convenience for optional log fields.
  static String? scrubNullable(String? input) =>
      input == null ? null : scrub(input);
}

class _Rule {
  final RegExp pattern;
  final String Function(Match) replace;
  const _Rule(this.pattern, this.replace);
}
