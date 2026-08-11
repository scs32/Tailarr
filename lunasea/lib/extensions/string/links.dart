import 'package:lunasea/system/logger.dart';
import 'package:lunasea/utils/link_dispatch.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// Only these schemes may be launched. A gateway/external-module URL, an
/// imported payload, or an ntfy field is untrusted input; without this a
/// bookmark could launch `tailarr:///import#…` (re-injecting config through the
/// app's own deep-link handler), `tel:`/`sms:`, or a custom-scheme handler.
const _allowedLinkSchemes = {'http', 'https'};

extension StringAsLinksExtension on String {
  Future<bool> _launchUniversal(String uri) async {
    return await launchUrlString(
      uri,
      webOnlyWindowName: '_blank',
      mode: LaunchMode.externalNonBrowserApplication,
    );
  }

  Future<bool> _launchDefault(String uri) async {
    return await launchUrlString(
      uri,
      webOnlyWindowName: '_blank',
      mode: LaunchMode.platformDefault,
    );
  }

  Future<bool> _launchSystem(String uri) async {
    final override = debugSystemLinkOpener;
    if (override != null) return override(uri);
    if (await _launchUniversal(uri)) return true;
    return _launchDefault(uri);
  }

  /// Open this URL.
  ///
  /// A tailnet destination (`*.ts.net`, `100.64/10`, `fd7a:115c:a1e0::/48`)
  /// is opened IN-APP, through a webview pointed at the embedded node's local
  /// CONNECT proxy. It cannot be handed to the system: `url_launcher` hands
  /// the URL to Safari, which is a different process that never sees this
  /// isolate's `HttpOverrides` and has no system-wide MagicDNS — so it
  /// "succeeds" and then shows a DNS error. Everything else keeps opening in
  /// the system browser exactly as before.
  /// Logging must never be able to stop a link from opening: `LunaLogger`
  /// writes to a Hive box, and `openLink` runs from surfaces (onboarding,
  /// import, background handlers) where that box may not be open.
  void _warn(String message) {
    try {
      LunaLogger().warning(message, 'StringAsLinksExtension', 'openLink');
    } catch (_) {}
  }

  Future<void> openLink() async {
    final scheme = Uri.tryParse(this)?.scheme.toLowerCase() ?? '';
    if (!_allowedLinkSchemes.contains(scheme)) {
      _warn('Refused to open a non-http(s) link (scheme: '
          '${scheme.isEmpty ? '(none)' : scheme})');
      return;
    }
    try {
      if (linkDestinationFor(this) == LinkDestination.tailnetBrowser) {
        final opener = tailnetLinkOpener;
        if (opener != null) {
          if (await opener(this)) return;
          _warn('In-app tailnet browser could not be presented; falling back '
              'to the system browser, which cannot resolve MagicDNS and is '
              'expected to fail');
        } else {
          _warn('No in-app tailnet browser on this platform; opening a '
              'tailnet URL in the system browser, which cannot resolve '
              'MagicDNS and is expected to fail');
        }
      }
      if (await _launchSystem(this)) return;
      // url_launcher declined outright. Previously this returned silently:
      // nothing thrown, nothing logged, nothing shown.
      _warn('The platform declined to open this URL');
    } catch (error, stack) {
      try {
        LunaLogger().error('Unable to open URL', error, stack);
      } catch (_) {
        _warn('Unable to open URL: $error');
      }
    }
  }

  Future<bool> canOpenUrl() async {
    return canLaunchUrlString(this);
  }

  Future<void> openImdb() async =>
      await 'https://www.imdb.com/title/$this'.openLink();

  Future<void> openTmdbMovie() async {
    await 'https://www.themoviedb.org/movie/$this'.openLink();
  }

  Future<void> openTmdbPerson() async {
    await 'https://www.themoviedb.org/person/$this'.openLink();
  }

  Future<void> openTraktMovie() async {
    await 'https://trakt.tv/search/tmdb/$this?id_type=movie'.openLink();
  }

  Future<void> openTraktSeries() async {
    await 'http://trakt.tv/search/tvdb/$this?id_type=show'.openLink();
  }

  Future<void> openTvMaze() async {
    await 'https://www.tvmaze.com/shows/$this'.openLink();
  }

  Future<void> openTvdbSeries() async {
    await 'https://www.thetvdb.com/?id=$this&tab=series'.openLink();
  }

  Future<void> openYouTube() async {
    await 'https://www.youtube.com/watch?v=$this'.openLink();
  }
}
