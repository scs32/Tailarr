import 'package:flutter/foundation.dart';
import 'package:lunasea/utils/tailnet.dart';

/// Where a link must be opened.
///
/// `openLink` is the single seam every "Open web GUI" action funnels through
/// (external modules, Sonarr/Radarr/Lidarr/NZBGet/SABnzbd/Tautulli settings,
/// the Tailarr Server pod details page). The destination is decided here, in
/// one pure function, so the decision can be tested without a device.
enum LinkDestination {
  /// The system browser (`url_launcher` → Safari / SFSafariViewController).
  /// The default, and what every non-tailnet link keeps doing.
  systemBrowser,

  /// An in-app WKWebView pointed at the embedded node's local CONNECT proxy.
  /// The ONLY way a `*.ts.net` host is reachable: Safari is a different
  /// process and the device has no system-wide MagicDNS.
  tailnetBrowser,
}

/// Decide where [url] must open. Pure.
LinkDestination linkDestinationFor(String url) {
  return isTailnetUrl(url)
      ? LinkDestination.tailnetBrowser
      : LinkDestination.systemBrowser;
}

/// Opens [url] in an in-app tailnet-proxied webview. Returns false when the
/// app could not present one at all (no navigator yet).
typedef TailnetLinkOpener = Future<bool> Function(String url);

/// Opens [url] via the platform's own handler. Returns false when the
/// platform declined.
typedef SystemLinkOpener = Future<bool> Function(String url);

/// Wired at startup by the tailnet browser page; overridden in tests.
///
/// A `null` opener means the in-app browser is unavailable in this build
/// (web/desktop), and a tailnet link falls back to the system browser with
/// an explicit log — a fallback that is *known* to fail is still better than
/// pretending the link opened.
TailnetLinkOpener? tailnetLinkOpener;

/// Overridable purely so the dispatch itself is testable — in production this
/// stays null and `openLink` uses `url_launcher` directly. (Deliberately NOT
/// `@visibleForTesting`: `openLink` in `lib/` has to read it.)
SystemLinkOpener? debugSystemLinkOpener;

@visibleForTesting
void resetLinkDispatchForTesting() {
  tailnetLinkOpener = null;
  debugSystemLinkOpener = null;
}
