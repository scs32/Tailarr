import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/router/router.dart';
import 'package:tailscale_embed/tailscale_embed.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// An in-app browser for tailnet-only destinations.
///
/// ## Why this exists
///
/// A tailnet host (`sonarr.tail95fc29.ts.net`) resolves ONLY through the
/// embedded userspace node. The app's own HTTP traffic reaches it because
/// `TailscaleHttpOverrides` rewrites `findProxy` to the node's local CONNECT
/// proxy — but `HttpOverrides` captures `dart:io HttpClient` **inside this
/// isolate only**. `url_launcher` hands the URL to Safari, a *different
/// process*, and the device has no system-wide MagicDNS. Safari therefore
/// fails to resolve the name — while `launchUrl` reports success, because
/// opening Safari genuinely succeeded.
///
/// A plain `WKWebView` would fail identically: it uses the system network
/// stack. The fix is `WKWebsiteDataStore.proxyConfigurations`
/// (`ProxyConfiguration(httpCONNECTProxy:)`, **iOS 17+**), which
/// `package:tailscale_embed` exposes as `installWebViewProxy(port)`. The
/// node's proxy dials tailnet destinations through tsnet and everything else
/// directly, so pointing a webview at it wholesale is safe.
class TailnetBrowserPage extends StatefulWidget {
  final String url;

  const TailnetBrowserPage({super.key, required this.url});

  /// Present this page for [url] on the root navigator. Returns false when
  /// there is no navigator to present on — the caller then falls back and
  /// says so, rather than reporting a success nobody can see.
  static Future<bool> open(String url) async {
    final navigator = LunaRouter.navigator.currentState;
    if (navigator == null) return false;
    unawaited(navigator.push(
      MaterialPageRoute(builder: (_) => TailnetBrowserPage(url: url)),
    ));
    return true;
  }

  @override
  State<TailnetBrowserPage> createState() => _TailnetBrowserPageState();
}

class _TailnetBrowserPageState extends State<TailnetBrowserPage> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  WebViewController? _controller;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  /// Bring the node up and point the webview's data store at its proxy
  /// BEFORE the first load. `TailscaleEmbed.configure(webViewProxy: true)`
  /// already does this on every start/rebind, but it swallows failures by
  /// design (a webview problem must not fail a node start). This page
  /// *requires* the proxy, so it installs it again and surfaces the error.
  Future<void> _prepare() async {
    final embed = TailscaleEmbed.instance;
    try {
      if (!embed.isSupported) {
        return _fail(
          'In-app tailnet browsing is not available on this platform.',
        );
      }
      final port = await embed.ensure();
      await embed.backend.installWebViewProxy(port);
    } on PlatformException catch (error, stack) {
      LunaLogger().error('Tailnet browser proxy setup failed', error, stack);
      if (error.code == 'UNSUPPORTED') {
        return _fail(
          'Opening tailnet services in-app requires iOS 17 or newer.\n\n'
          '${error.message ?? ''}'.trim(),
        );
      }
      return _fail(
        'Could not reach the Tailscale node.\n\n${error.message ?? error.code}',
      );
    } catch (error, stack) {
      LunaLogger().error('Tailnet browser proxy setup failed', error, stack);
      return _fail('Could not reach the Tailscale node.\n\n$error');
    }

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        onWebResourceError: (error) {
          // Subresource failures are noise; only a main-frame failure means
          // the page did not load.
          if (error.isForMainFrame == false) return;
          LunaLogger().warning(
            'Tailnet page failed to load: ${error.errorCode} '
            '${error.description}',
            'TailnetBrowserPage',
            'onWebResourceError',
          );
          _fail(
            'Could not load ${widget.url}\n\n'
            '${error.description}\n\n'
            'This address only exists on your tailnet. Check that Tailscale '
            'is connected and that the service is shared with this device.',
          );
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
    if (!mounted) return;
    setState(() => _controller = controller);
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _loading = false;
    });
  }

  Future<void> _openExternally() async {
    try {
      await launchUrlString(widget.url, mode: LaunchMode.platformDefault);
    } catch (error, stack) {
      LunaLogger().error('Unable to open URL externally', error, stack);
    }
  }

  String get _title {
    final host = Uri.tryParse(widget.url)?.host ?? '';
    return host.isEmpty ? widget.url : host;
  }

  @override
  Widget build(BuildContext context) {
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      appBar: LunaAppBar(
        title: _title,
        useDrawer: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_browser_rounded),
            onPressed: _openExternally,
          ),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final error = _error;
    if (error != null) {
      return LunaMessage(
        text: error,
        buttonText: 'Open Externally',
        onTap: _openExternally,
      );
    }
    final controller = _controller;
    if (controller == null || _loading) {
      return Stack(
        children: [
          if (controller != null) WebViewWidget(controller: controller),
          const LunaLoader(),
        ],
      );
    }
    return WebViewWidget(controller: controller);
  }
}
