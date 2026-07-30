import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/api/seerr/models.dart';
import 'package:lunasea/extensions/string/links.dart';
import 'package:lunasea/modules/requests/core/webview_cookie.dart';
import 'package:lunasea/system/gateway/gateway_host.dart';

/// The member's request-portal (Seerr) view. Opening this screen calls the
/// app-brokered sign-in (want:"seerr-signin"): the server replays the member's
/// stored Jellyfin password into Seerr and hands back a session cookie + portal
/// URL, which the app pre-sets into an in-app webview so the portal opens
/// already signed in. No admin key, no password is ever typed — the member only
/// ever holds the opaque, session-lifetime `connect.sid` cookie, and it is
/// injected into the webview cookie store (never persisted, never logged).
///
/// Decision (documented in the ops follow-up spec): an **in-app webview** is
/// used, not the system browser, because it is the only surface where the
/// brokered cookie can be pre-set for the portal origin before the first load —
/// exactly what the server's cookie-shaped handout is designed for, and the
/// spec's recommended option. On platforms without a webview implementation
/// (desktop/web) the module degrades to opening the portal externally
/// (best-effort; the cookie cannot be injected there) so the app still builds
/// and runs everywhere.
class RequestsRoute extends StatefulWidget {
  const RequestsRoute({Key? key}) : super(key: key);

  @override
  State<RequestsRoute> createState() => _State();
}

enum _Phase { loading, ready, notReady, needsJellyfin, unavailable, error }

class _State extends State<RequestsRoute> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// In-app webview is only available on mobile; elsewhere we fall back to an
  /// external open (no cookie injection possible).
  static bool get _webviewSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  _Phase _phase = _Phase.loading;
  String _message = '';
  SeerrSignin? _signin;
  WebViewController? _controller;

  /// Bounds the automatic re-broker on a webview 401/403 so an endlessly
  /// unauthenticated portal can't loop forever.
  int _rebrokerAttempts = 0;
  static const _maxRebroker = 1;

  @override
  void initState() {
    super.initState();
    _broker();
  }

  /// Calls the sign-in broker and drives the state machine. The cookie value is
  /// NEVER logged — only its presence.
  Future<void> _broker() async {
    if (mounted) setState(() => _phase = _Phase.loading);
    try {
      final signin = await (await gatewayClient()).selfSeerrSignin();
      LunaLogger().debug(
        'gateway seerr-signin → HTTP ${signin.statusCode} ok=${signin.ok} '
        'error=${signin.error} url=${signin.url.isEmpty ? '(stopped)' : 'set'} '
        'cookie=${signin.cookie != null && signin.cookie!.isValid}',
      );
      if (!mounted) return;

      if (signin.isReady) {
        await _openPortal(signin);
        return;
      }
      _classifyRefusal(signin);
    } catch (error, stack) {
      LunaLogger().error('Failed to broker request-portal sign-in', error,
          stack);
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _message =
            'The request portal isn\'t responding right now — it may be '
            'reconnecting.';
      });
    }
  }

  void _classifyRefusal(SeerrSignin signin) {
    if (signin.needsJellyfin) {
      setState(() {
        _phase = _Phase.needsJellyfin;
        _message = 'The request portal needs a Jellyfin account to sign you '
            'in. Ask your server admin to grant Jellyfin access, then try '
            'again.';
      });
    } else if (signin.isNotReady) {
      setState(() {
        _phase = _Phase.notReady;
        _message = 'Your request portal is still being set up. This usually '
            'takes a moment — try again shortly.';
      });
    } else if (signin.isUnavailable || signin.hasNoAccess) {
      setState(() {
        _phase = _Phase.unavailable;
        _message =
            'You don\'t have request-portal access on this server. Ask your '
            'server admin to grant it, then try again.';
      });
    } else {
      setState(() {
        _phase = _Phase.error;
        _message = signin.error ?? 'Request-portal sign-in failed.';
      });
    }
  }

  /// Builds the signed-in webview: set the brokered cookie for the portal
  /// origin, then load the URL. On mobile only; elsewhere fall back to an
  /// external open.
  Future<void> _openPortal(SeerrSignin signin) async {
    if (!_webviewSupported) {
      setState(() {
        _phase = _Phase.error;
        _message = 'Open the request portal in your browser to continue.';
        _signin = signin;
      });
      return;
    }

    final cookie = seerrWebViewCookie(signin.url, signin.cookie);
    if (cookie == null) {
      setState(() {
        _phase = _Phase.error;
        _message = 'Request-portal sign-in returned an unusable session.';
      });
      return;
    }

    // Pre-set the session cookie for the portal origin BEFORE the first load —
    // the whole point of the broker. Session cookies (expires:0) live only in
    // the webview cookie store and are cleared when it is torn down; we never
    // write the cookie to Hive or secure storage.
    await WebViewCookieManager().setCookie(cookie);

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onHttpError: (error) {
            final status = error.response?.statusCode;
            // A 401/403 on the main document means the session lapsed — re-
            // broker a fresh cookie and reload once, then give up gracefully.
            if ((status == 401 || status == 403) &&
                _rebrokerAttempts < _maxRebroker) {
              _rebrokerAttempts++;
              LunaLogger().debug(
                'request-portal webview HTTP $status → re-brokering session',
              );
              _broker();
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(signin.url));

    setState(() {
      _controller = controller;
      _signin = signin;
      _phase = _Phase.ready;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      module: LunaModule.REQUESTS,
      appBar: _appBar() as PreferredSizeWidget?,
      drawer: LunaDrawer(page: LunaModule.REQUESTS.key),
      body: _body(),
    );
  }

  Widget _appBar() {
    return LunaAppBar(
      useDrawer: true,
      title: 'Requests',
      actions: [
        if (_phase == _Phase.ready)
          LunaIconButton(
            icon: Icons.refresh_rounded,
            onPressed: () {
              _rebrokerAttempts = 0;
              _broker();
            },
          ),
      ],
    );
  }

  Widget _body() {
    switch (_phase) {
      case _Phase.loading:
        return const LunaLoader();
      case _Phase.ready:
        final controller = _controller;
        if (controller != null) return WebViewWidget(controller: controller);
        // Fallback path (unsupported platform): offer an external open.
        return LunaMessage(
          text: _message.isEmpty
              ? 'Open the request portal in your browser to continue.'
              : _message,
          buttonText: 'Open Portal',
          onTap: () => _signin?.url.openLink(),
        );
      case _Phase.needsJellyfin:
      case _Phase.notReady:
      case _Phase.unavailable:
        return LunaMessage(
          text: _message,
          buttonText: 'Try Again',
          onTap: _broker,
        );
      case _Phase.error:
        // If we have a URL (unsupported-platform fallback), let them open it.
        final url = _signin?.url ?? '';
        if (!_webviewSupported && url.isNotEmpty) {
          return LunaMessage(
            text: _message,
            buttonText: 'Open Portal',
            onTap: () => url.openLink(),
          );
        }
        return LunaMessage(
          text: _message,
          buttonText: 'Retry',
          onTap: () {
            _rebrokerAttempts = 0;
            _broker();
          },
        );
    }
  }
}
