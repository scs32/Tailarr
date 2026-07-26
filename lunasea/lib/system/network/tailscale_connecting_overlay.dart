import 'dart:async';

import 'package:flutter/material.dart';

/// The TailscaleGuard connecting overlay, kept invisible for the first
/// [delay] so fast (re)connects on launch/resume don't flash a frame of
/// spinner. Input stays blocked the whole time (the guard's AbsorbPointer
/// wraps this widget) — only the visual is deferred.
class TailscaleConnectingOverlay extends StatefulWidget {
  static const delay = Duration(milliseconds: 400);

  const TailscaleConnectingOverlay({
    Key? key,
  }) : super(key: key);

  @override
  State<TailscaleConnectingOverlay> createState() => _State();
}

class _State extends State<TailscaleConnectingOverlay> {
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(TailscaleConnectingOverlay.delay, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 200),
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
    );
  }
}

/// Tailarr-worded "connection stuck" notice (TailscaleGuard v0.3.6+
/// [stuckNoticeBuilder]). Non-blocking — input stays free — shown when the
/// connect hits the guard's hard timeout, i.e. the embedded node's serialized
/// op queue may be wedged. Names the honest recovery: reopen the app.
class TailscaleStuckNotice extends StatelessWidget {
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  const TailscaleStuckNotice({
    Key? key,
    required this.onRetry,
    required this.onDismiss,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            color: const Color(0xFF3A2E1A), // amber-tinted dark card
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          color: Color(0xFFFFC24B), size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "Tailscale isn't responding",
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Anything that needs it may not work. If Tailarr becomes '
                    'unresponsive, reopen the app to recover.',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: onDismiss,
                        child: const Text('Dismiss',
                            style: TextStyle(color: Colors.white70)),
                      ),
                      TextButton(
                        onPressed: onRetry,
                        child: const Text('Retry',
                            style: TextStyle(color: Color(0xFFFFC24B))),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
