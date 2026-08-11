/// Tailnet address classification.
///
/// The device has NO system-wide MagicDNS — that is the entire point of the
/// embedded userspace node. A tailnet destination therefore resolves only
/// inside the app (via `package:tailscale_embed`'s local CONNECT proxy), and
/// anything that leaves the process — Safari, `UIApplication.open`,
/// SFSafariViewController — cannot reach it. This file decides which URLs
/// are in that category.
///
/// Deliberately pure and dependency-free so the routing decision is unit
/// testable without a device, a node, or a webview.
library;

/// Tailscale's assigned address ranges. Mirrors the plugin's own
/// `tailnetCGNAT` / `tailnetULA` (go/main.go) — a destination inside either
/// only exists on the tailnet.
const int _cgnatFirstOctet = 100;
const int _cgnatSecondLow = 64; // 100.64.0.0/10 → second octet 64..127
const int _cgnatSecondHigh = 127;
const String _ulaPrefix = 'fd7a:115c:a1e0';

/// MagicDNS names always live under this suffix.
const String _magicDnsSuffix = '.ts.net';

/// Whether [host] is a `*.ts.net` MagicDNS name.
///
/// Tolerates a trailing root dot and any case. A bare `ts.net` is NOT a
/// tailnet host (it is the public apex), and neither is a suffix match that
/// isn't on a label boundary (`evilts.net`) — the leading `.` handles both.
bool isTailnetHostname(String host) {
  var h = host.trim().toLowerCase();
  while (h.endsWith('.')) {
    h = h.substring(0, h.length - 1);
  }
  return h.endsWith(_magicDnsSuffix);
}

/// Whether [host] is a literal IP inside a Tailscale-assigned range.
bool isTailnetIpLiteral(String host) {
  var h = host.trim().toLowerCase();
  // Uri.host keeps IPv6 literals bracketed.
  if (h.startsWith('[') && h.endsWith(']')) {
    h = h.substring(1, h.length - 1);
  }
  if (h.startsWith(_ulaPrefix)) {
    // Only a full label match, so `fd7a:115c:a1e00::` can't sneak through.
    final rest = h.substring(_ulaPrefix.length);
    if (rest.isEmpty || rest.startsWith(':')) return true;
  }
  final parts = h.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final p in parts) {
    final v = int.tryParse(p);
    if (v == null || v < 0 || v > 255 || p != v.toString()) return false;
    octets.add(v);
  }
  return octets[0] == _cgnatFirstOctet &&
      octets[1] >= _cgnatSecondLow &&
      octets[1] <= _cgnatSecondHigh;
}

/// Whether [url] names a destination that only the embedded Tailscale node
/// can reach.
///
/// ⚠️ Returns FALSE for everything else — documentation links, github,
/// tailarr.com, TMDB and friends must keep opening in the system browser.
/// Over-matching here would drag every outbound link through the tailnet
/// proxy and into an in-app webview.
bool isTailnetUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;
  final host = uri.host;
  if (host.isEmpty) return false;
  return isTailnetHostname(host) || isTailnetIpLiteral(host);
}
