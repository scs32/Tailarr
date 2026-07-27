import 'package:flutter/material.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/router/router.dart';
import 'package:lunasea/router/routes.dart';
import 'package:lunasea/utils/profile_tools.dart';

/// First-run landing (shown while nothing is configured — no server joined, no
/// demo). Two branches: **Join Tailarr Server** (paste an invite link → the
/// import flow) and **Start Demo Mode** (bundled, read-only sample library).
class FirstRunLandingRoute extends StatefulWidget {
  static const String path = '/landing';

  const FirstRunLandingRoute({Key? key}) : super(key: key);

  @override
  State<FirstRunLandingRoute> createState() => _State();
}

class _State extends State<FirstRunLandingRoute> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      module: null,
      appBar: null,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Image.asset(
                LunaAssets.brandingLogo,
                height: 96,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.hub_rounded, size: 96, color: LunaColours.accent),
              ),
              const SizedBox(height: 24),
              const Text(
                'Welcome to Tailarr',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: LunaUI.FONT_WEIGHT_BOLD,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Control your media server privately over your tailnet. '
                'Join a Tailarr Server with an invite, or explore a read-only '
                'demo first.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.white.withOpacity(0.70),
                ),
              ),
              const SizedBox(height: 40),
              LunaButton.text(
                text: 'Join Tailarr Server',
                icon: Icons.qr_code_scanner_rounded,
                backgroundColor: LunaColours.accent,
                color: Colors.white,
                onTap: _busy ? null : _join,
              ),
              const SizedBox(height: 12),
              LunaButton.text(
                text: _busy ? 'Starting…' : 'Start Demo Mode',
                icon: Icons.play_circle_outline_rounded,
                backgroundColor: LunaColours.primary,
                onTap: _busy ? null : _startDemo,
              ),
              const SizedBox(height: 24),
              Text(
                'The demo uses Blender open movies (Big Buck Bunny, Sintel). '
                'It never touches a network.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withOpacity(0.45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _join() async {
    final result = await LunaDialogs().editText(
      context,
      'Join Tailarr Server',
      extraText: const [
        TextSpan(
          text: 'Paste the invite link your server admin shared with you '
              '(or open it directly from your messages).',
        ),
      ],
    );
    if (!result.item1) return;
    final raw = result.item2.trim();
    if (raw.isEmpty) return;

    // Accept a full tailarr.com/import#<payload> or tailarr://…#<payload>
    // link, a ?c= fallback, or a bare payload.
    final uri = Uri.tryParse(raw);
    final payload = (uri != null && uri.fragment.isNotEmpty)
        ? uri.fragment
        : (uri?.queryParameters['c']?.isNotEmpty ?? false)
            ? uri!.queryParameters['c']!
            : raw;
    LunaRouter.router.go(Uri(path: '/import', fragment: payload).toString());
  }

  Future<void> _startDemo() async {
    setState(() => _busy = true);
    await LunaProfileTools().enterDemo();
    if (!mounted) return;
    setState(() => _busy = false);
    LunaRouter.router.go(LunaRoutes.initialLocation);
  }
}
