import 'package:flutter/material.dart';
import 'package:lunasea/database/tables/lunasea.dart';
import 'package:lunasea/system/logger.dart';
import 'package:lunasea/system/network/platform/network_io.dart'
    if (dart.library.html) 'package:lunasea/system/network/platform/network_html.dart';

/// Watches app lifecycle and ensures the embedded Tailscale node and its
/// local proxy are healthy whenever the app launches or returns to the
/// foreground (iOS reclaims the proxy's listener socket during suspension).
/// While (re)connecting, a blocking overlay is shown so requests aren't
/// fired into a dead proxy.
class TailscaleGuard extends StatefulWidget {
  final Widget? child;

  const TailscaleGuard({
    super.key,
    required this.child,
  });

  @override
  State<TailscaleGuard> createState() => _TailscaleGuardState();
}

class _TailscaleGuardState extends State<TailscaleGuard>
    with WidgetsBindingObserver {
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ensure();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _ensure();
  }

  Future<void> _ensure() async {
    if (!IO.isTailscaleSupported) return;
    if (!LunaSeaDatabase.TAILSCALE_ENABLED.read()) return;
    if (_connecting) return;

    setState(() => _connecting = true);
    try {
      await IO.ensureTailscale(LunaSeaDatabase.TAILSCALE_AUTH_KEY.read());
    } catch (error, stack) {
      LunaLogger().error('Failed to connect Tailscale', error, stack);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (widget.child != null) widget.child!,
        if (_connecting)
          Positioned.fill(
            child: AbsorbPointer(
              child: Material(
                color: Colors.black.withOpacity(0.65),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text(
                      'Connecting to Tailscale…',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
