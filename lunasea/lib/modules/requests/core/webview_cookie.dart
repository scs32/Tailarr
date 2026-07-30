import 'package:webview_flutter/webview_flutter.dart';

import 'package:lunasea/api/seerr/models.dart';

/// Pure mapping from the broker's [SeerrCookie] + portal URL to the platform
/// [WebViewCookie] the app pre-sets before loading the portal, so the member
/// lands already signed in. Kept side-effect-free and separate from the widget
/// so it is directly unit-testable.
///
/// The broker sends no `domain` (see `_seerr_cookie` server-side); the cookie
/// is scoped to the portal URL's own host — the tailnet MagicDNS name. Returns
/// null when the URL has no host or the cookie is empty, so a malformed handout
/// can never produce a bad cookie insert.
WebViewCookie? seerrWebViewCookie(String url, SeerrCookie? cookie) {
  if (cookie == null || !cookie.isValid) return null;
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.isEmpty) return null;
  return WebViewCookie(
    name: cookie.name,
    value: cookie.value,
    domain: host,
    path: cookie.path.isEmpty ? '/' : cookie.path,
  );
}
