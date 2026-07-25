import 'package:lunasea/system/logger.dart';
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

  Future<void> openLink() async {
    final scheme = Uri.tryParse(this)?.scheme.toLowerCase() ?? '';
    if (!_allowedLinkSchemes.contains(scheme)) {
      LunaLogger().warning(
        'Refused to open a non-http(s) link (scheme: '
        '${scheme.isEmpty ? '(none)' : scheme})',
        'StringAsLinksExtension',
        'openLink',
      );
      return;
    }
    try {
      if (await _launchUniversal(this)) return;
      await _launchDefault(this);
    } catch (error, stack) {
      LunaLogger().error(
        'Unable to open URL',
        error,
        stack,
      );
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
