import 'dart:io';

import 'package:dio/dio.dart';

/// SSRF guard for "Test Connection": a user-supplied (or shared-config) URL is
/// fetched, so it can be aimed at internal targets to probe them. Mirrors the
/// server's `_ssrf_check` / `_SSRFSafeRedirect` (podscale H-05/H-06).
///
/// Tailarr talks to services on the user's LAN and tailnet, so this must NOT
/// block private ranges — only the addresses that are never a real Tailarr
/// service. It checks the RESOLVED HOST of the URL, not the socket: the
/// embedded Tailscale proxy makes the app legitimately connect to loopback for
/// tailnet traffic, so a socket-level block would break the whole app.
class SsrfGuard {
  SsrfGuard._();

  static const int _maxHops = 5;
  static const String message =
      "That address isn't allowed — it points at this device, a link-local "
      "address, or the cloud-metadata endpoint.";

  /// An address a Tailarr service must never live at: loopback, link-local
  /// (incl. 169.254.169.254 cloud-metadata), multicast, or unspecified
  /// (0.0.0.0 / ::). LAN (RFC1918), tailnet CGNAT (100.64.0.0/10) and public
  /// are allowed on purpose. Pure — directly unit-testable.
  static bool isBlockedAddress(InternetAddress a) {
    return a.isLoopback ||
        a.isLinkLocal ||
        a.isMulticast ||
        a.address == '0.0.0.0' ||
        a.address == '::';
  }

  /// Resolve [host] and return [message] if ANY resolved address is forbidden,
  /// else null. Best-effort: an unresolvable host returns null (let the real
  /// fetch surface the failure) — don't fail closed on a DNS hiccup, or
  /// legitimately-offline services stop being testable. Matches the server.
  static Future<String?> checkHost(String host) async {
    if (host.isEmpty) return 'Invalid URL.';
    List<InternetAddress> addrs;
    try {
      addrs = await InternetAddress.lookup(host);
    } catch (_) {
      return null;
    }
    for (final a in addrs) {
      if (isBlockedAddress(a)) return message;
    }
    return null;
  }

  /// Full guard for [url]: checks the initial host AND every redirect hop — a
  /// public URL that 302s to http://169.254.169.254/ is the classic bypass, so
  /// re-checking only the first URL is near-useless. Returns a block message to
  /// abort, or null if the whole chain is safe. Redirects are walked with a
  /// throwaway client that does NOT auto-follow. Best-effort on transport
  /// errors (return null → let the real test report the failure).
  ///
  /// TOCTOU residual: the real test re-resolves/re-fetches, so a server that
  /// flips its answer between guard and test could still slip — acceptable for
  /// a manual, rate-of-one probe. The connect-IP approach (closing DNS-rebind
  /// too) is a network-layer follow-up complicated by the tailnet proxy.
  static Future<String?> guard(String url) async {
    var current = url;
    for (var hop = 0; hop <= _maxHops; hop++) {
      final host = Uri.tryParse(current)?.host;
      if (host == null || host.isEmpty) return 'Invalid URL.';
      final blocked = await checkHost(host);
      if (blocked != null) return blocked;

      final dio = Dio(BaseOptions(
        followRedirects: false,
        validateStatus: (_) => true,
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ));
      Response<dynamic> resp;
      try {
        resp = await dio.head<dynamic>(current);
      } catch (_) {
        return null; // unreachable / method not allowed — let the real test try
      } finally {
        dio.close(force: true);
      }
      final code = resp.statusCode ?? 0;
      if (code >= 300 && code < 400) {
        final loc = resp.headers.value('location');
        if (loc == null || loc.isEmpty) return null;
        current = Uri.parse(current).resolve(loc).toString();
        continue; // re-check the next hop
      }
      return null; // not a redirect → chain ends here, every hop was safe
    }
    return 'Too many redirects.';
  }
}
