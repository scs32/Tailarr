import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:lunasea/core.dart';

/// A fun, mesh-decorated pulsing orb — the idle/listening face of the Tailarr
/// voice-assistant dashboard.
///
/// Pure Flutter, no shader assets: an animated stack of additively-blended
/// radial "mesh" blobs drifting inside a breathing core, wrapped by a soft
/// glow ring. It is deliberately alive (it reads as intentional, not as a
/// loading spinner) and cheap (single [AnimationController], a [RepaintBoundary],
/// all painting in one [CustomPainter]).
///
/// This is the increment-1 placeholder visual. A later increment can swap the
/// painter body for a fragment shader without touching callers.
class AssistantOrb extends StatefulWidget {
  const AssistantOrb({
    super.key,
    this.size = 200.0,
    this.intensity = 0.0,
    this.label,
  });

  /// Diameter of the orb in logical pixels.
  final double size;

  /// 0 = calm idle breathing, 1 = actively listening/thinking (faster, wider
  /// blob motion + brighter glow). Values in-between interpolate.
  final double intensity;

  /// Optional caption rendered under the orb (e.g. "Thinking…").
  final String? label;

  @override
  State<AssistantOrb> createState() => _AssistantOrbState();
}

class _AssistantOrbState extends State<AssistantOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double intensity = widget.intensity.clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => CustomPaint(
              size: Size.square(widget.size),
              painter: _OrbPainter(t: _controller.value, intensity: intensity),
            ),
          ),
        ),
        if (widget.label != null) ...[
          const SizedBox(height: 18.0),
          Text(
            widget.label!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: LunaColours.grey,
              fontSize: LunaUI.FONT_SIZE_H4,
              fontWeight: LunaUI.FONT_WEIGHT_BOLD,
            ),
          ),
        ],
      ],
    );
  }
}

class _Blob {
  const _Blob({
    required this.color,
    required this.phase,
    required this.orbit,
    required this.radius,
  });

  /// Blob tint.
  final Color color;

  /// Starting angle offset in turns (0..1) so the blobs don't move in lockstep.
  final double phase;

  /// Orbit radius as a fraction of the orb radius.
  final double orbit;

  /// Blob radius as a fraction of the orb radius.
  final double radius;
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.t, required this.intensity});

  /// Looping animation value 0..1.
  final double t;
  final double intensity;

  static const double _tau = 2 * math.pi;

  static const List<_Blob> _blobs = <_Blob>[
    _Blob(color: LunaColours.accent, phase: 0.00, orbit: 0.20, radius: 0.55),
    _Blob(color: LunaColours.blue, phase: 0.33, orbit: 0.24, radius: 0.50),
    _Blob(color: LunaColours.purple, phase: 0.66, orbit: 0.18, radius: 0.60),
    _Blob(color: LunaColours.accent, phase: 0.50, orbit: 0.22, radius: 0.42),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double r = size.width / 2;
    // Breathing pulse — a touch faster/wider when active.
    final double pulse = 1.0 + (0.04 + 0.03 * intensity) * math.sin(t * _tau);
    final double orbR = r * 0.72;
    final double drift = 0.55 + 0.6 * intensity;

    // --- Soft outer glow (unclipped, breathing) ---
    final double glow = orbR * (1.08 + 0.10 * math.sin(t * _tau));
    canvas.drawCircle(
      center,
      glow,
      Paint()
        ..shader = RadialGradient(
          colors: [
            LunaColours.accent.withValues(alpha: 0.14 + 0.10 * intensity),
            LunaColours.accent.withValues(alpha: 0.0),
          ],
          stops: const [0.55, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: glow)),
    );

    // --- Orb body: clip so the mesh blobs stay inside the sphere ---
    canvas.save();
    canvas.clipPath(
      ui.Path()..addOval(Rect.fromCircle(center: center, radius: orbR * pulse)),
    );

    // Base fill so blob edges blend into the dark sphere, not the page.
    canvas.drawCircle(
      center,
      orbR * pulse,
      Paint()
        ..shader = RadialGradient(
          colors: [
            LunaColours.accent.withValues(alpha: 0.30),
            LunaColours.primary,
          ],
        ).createShader(
          Rect.fromCircle(center: center, radius: orbR * pulse),
        ),
    );

    // Additive mesh blobs — drifting radial gradients that read as a living
    // mesh-gradient sphere.
    for (final _Blob b in _blobs) {
      final double angle = (t + b.phase) * _tau;
      final Offset pos = center +
          Offset(
            math.cos(angle) * r * b.orbit * drift,
            math.sin(angle * 1.3) * r * b.orbit * drift,
          );
      final double br = r * b.radius;
      canvas.drawCircle(
        pos,
        br,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(
            colors: [
              b.color.withValues(alpha: 0.45 + 0.30 * intensity),
              b.color.withValues(alpha: 0.0),
            ],
          ).createShader(Rect.fromCircle(center: pos, radius: br))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, br * 0.22),
      );
    }
    canvas.restore();

    // --- Rim highlight ---
    canvas.drawCircle(
      center,
      orbR * pulse,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = LunaColours.white.withValues(alpha: 0.10 + 0.10 * intensity),
    );
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) =>
      old.t != t || old.intensity != intensity;
}
