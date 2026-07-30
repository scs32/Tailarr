import 'package:webview_flutter/webview_flutter.dart';

import 'package:lunasea/api/seerr/models.dart';

/// Pure mapping from the broker's [SeerrCookie] + portal URL to the platform
/// [WebViewCookie] the app pre-sets before loading the portal, so the member
/// lands already signed in. Kept side-effect-free and separate from the widget
/// so it is directly unit-testable.
///
/// The broker sends no `domain` (see `_seerr_cookie` server-side); the cookie
/// is scoped to the portal URL's own host — the tailnet MagicDNS name.
///
/// Defense-in-depth on the (server-provided, but still validated) handout so a
/// session value is never planted for the wrong origin or over cleartext:
///   * the portal URL must be absolute **https** with a host and NO userinfo,
///   * only the expected `connect.sid` session cookie is ever injected.
/// Returns null on any mismatch, so a malformed/hostile handout produces no
/// cookie insert (the caller then surfaces an "unusable session" state).
WebViewCookie? seerrWebViewCookie(String url, SeerrCookie? cookie) {
  if (cookie == null || !cookie.isValid) return null;
  if (cookie.name != 'connect.sid') return null;
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return WebViewCookie(
    name: cookie.name,
    value: cookie.value,
    domain: uri.host,
    path: cookie.path.isEmpty ? '/' : cookie.path,
  );
}
