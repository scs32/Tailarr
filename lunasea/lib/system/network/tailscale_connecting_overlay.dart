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
