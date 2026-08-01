import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:lunasea/core.dart';

/// The idle/listening/speaking face of the Tailarr voice-assistant dashboard:
/// a sphere **woven from a soft fabric-like mesh that gently undulates**, a
/// playful reference to the tailnet mesh the app runs on.
///
/// Rendering is a procedural **fragment shader** (`shaders/orb_mesh.frag`): a
/// lit sphere whose surface is an interlaced warp/weft lattice displaced by
/// layered value-noise (fbm) for the cloth-in-a-breeze drift. The shader is
/// loaded asynchronously and, if it is unavailable (e.g. an environment without
/// Impeller such as the widget-test harness), the widget falls back to a cheap
/// CPU lat/long mesh painted with [Canvas] — so it always renders an animated
/// mesh orb, never a blank box or a spinner.
///
/// Cost-capped for the always-visible home surface: a single
/// [AnimationController], one [RepaintBoundary], all painting in one painter.
///
/// Public API is intentionally stable (the voice audio lane drives it): the
/// [intensity] input maps the session state machine — idle (0.0, slow
/// breathing) → listening/thinking → speaking (1.0, faster, brighter, wider
/// undulation) — onto the animation. Extend additively only.
class AssistantOrb extends StatefulWidget {
  const AssistantOrb({
    super.key,
    this.size = 200.0,
    this.intensity = 0.0,
    this.label,
  });

  /// Diameter of the orb in logical pixels.
  final double size;

  /// 0 = calm idle breathing, 1 = actively listening/speaking (faster, wider
  /// mesh undulation + brighter). Values in-between interpolate.
  final double intensity;

  /// Optional caption rendered under the orb (e.g. "Thinking…").
  final String? label;

  @override
  State<AssistantOrb> createState() => _AssistantOrbState();
}

class _AssistantOrbState extends State<AssistantOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// Loaded lazily; null until (and unless) the shader compiles. When it stays
  /// null we render the CPU mesh fallback.
  ui.FragmentShader? _shader;

  /// Monotonic seconds for continuous (non-looping) noise. The controller loops
  /// 0..1 over a long period so `value * _period` is elapsed seconds with only a
  /// single, unnoticeable wrap every few minutes.
  static const double _period = 600.0;
  double get _seconds => _controller.value * _period;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 600), // == _period
    )..repeat();
    _loadShader();
  }

  Future<void> _loadShader() async {
    try {
      final program =
          await ui.FragmentProgram.fromAsset('shaders/orb_mesh.frag');
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
    } catch (_) {
      // No Impeller/shader support (e.g. widget tests) — keep the CPU fallback.
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
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
              painter: _shader != null
                  ? _MeshShaderPainter(
                      shader: _shader!,
                      seconds: _seconds,
                      intensity: intensity,
                    )
                  : _MeshFallbackPainter(
                      t: _controller.value,
                      intensity: intensity,
                    ),
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

/// Primary renderer: draws the full canvas through the fabric-mesh fragment
/// shader (which masks itself to the sphere + glow).
class _MeshShaderPainter extends CustomPainter {
  _MeshShaderPainter({
    required this.shader,
    required this.seconds,
    required this.intensity,
  });

  final ui.FragmentShader shader;
  final double seconds;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, seconds)
      ..setFloat(3, intensity);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _MeshShaderPainter old) =>
      old.seconds != seconds || old.intensity != intensity;
}

/// CPU fallback: a lat/long wireframe sphere whose vertices wobble with cheap
/// pseudo-noise, drawn as soft mint strokes over a breathing dark core. Reads
/// as an undulating mesh (not a spinner) wherever the shader can't run.
class _MeshFallbackPainter extends CustomPainter {
  _MeshFallbackPainter({required this.t, required this.intensity});

  /// Looping animation value 0..1.
  final double t;
  final double intensity;

  static const double _tau = 2 * math.pi;
  static const int _lats = 7; // latitude rings
  static const int _lons = 12; // longitude meridians
  static const int _seg = 24; // samples per line

  // Cheap value-noise-ish wobble so threads don't move in lockstep.
  double _wave(double a, double b, double phase) =>
      math.sin(a * 1.7 + phase) * math.cos(b * 2.3 - phase * 0.7);

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double r = size.width / 2;
    final double breath = 1.0 + (0.02 + 0.03 * intensity) * math.sin(t * _tau);
    final double orbR = r * 0.82 * breath;
    final double phase = t * _tau;
    final double amp = orbR * (0.02 + 0.05 * intensity);

    // Breathing dark core so the mesh reads against a body, not the page.
    canvas.drawCircle(
      center,
      orbR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            LunaColours.accent.withValues(alpha: 0.22),
            LunaColours.primary,
          ],
        ).createShader(Rect.fromCircle(center: center, radius: orbR)),
    );

    // Soft outer glow.
    final double glow = orbR * 1.18;
    canvas.drawCircle(
      center,
      glow,
      Paint()
        ..shader = RadialGradient(
          colors: [
            LunaColours.accent.withValues(alpha: 0.12 + 0.10 * intensity),
            LunaColours.accent.withValues(alpha: 0.0),
          ],
          stops: const [0.6, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: glow)),
    );

    // Project a sphere point (lat, lon in radians) to 2D, with noise wobble,
    // dropping back-facing points for a light "front hemisphere" weave.
    Offset? project(double lat, double lon) {
      final double wob = 1.0 +
          amp / orbR * _wave(lat * 3.0, lon * 3.0, phase);
      final double x = math.cos(lat) * math.sin(lon);
      final double y = math.sin(lat);
      final double z = math.cos(lat) * math.cos(lon);
      if (z < -0.15) return null; // cull far back face
      return center + Offset(x, -y) * orbR * wob;
    }

    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round
      ..color = LunaColours.accent.withValues(alpha: 0.34 + 0.30 * intensity)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.6);

    // Latitude rings.
    for (int i = 1; i < _lats; i++) {
      final double lat = -math.pi / 2 + math.pi * i / _lats;
      final ui.Path path = ui.Path();
      bool started = false;
      for (int s = 0; s <= _seg; s++) {
        final double lon = -math.pi + _tau * s / _seg;
        final Offset? p = project(lat, lon);
        if (p == null) {
          started = false;
          continue;
        }
        if (!started) {
          path.moveTo(p.dx, p.dy);
          started = true;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path, stroke);
    }

    // Longitude meridians.
    for (int j = 0; j < _lons; j++) {
      final double lon = -math.pi + _tau * j / _lons;
      final ui.Path path = ui.Path();
      bool started = false;
      for (int s = 0; s <= _seg; s++) {
        final double lat = -math.pi / 2 + math.pi * s / _seg;
        final Offset? p = project(lat, lon);
        if (p == null) {
          started = false;
          continue;
        }
        if (!started) {
          path.moveTo(p.dx, p.dy);
          started = true;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path, stroke);
    }

    // Rim highlight.
    canvas.drawCircle(
      center,
      orbR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = LunaColours.white.withValues(alpha: 0.10 + 0.10 * intensity),
    );
  }

  @override
  bool shouldRepaint(covariant _MeshFallbackPainter old) =>
      old.t != t || old.intensity != intensity;
}
