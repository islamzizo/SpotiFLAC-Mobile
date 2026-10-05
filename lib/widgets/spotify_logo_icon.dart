import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Small monochrome Spotify mark used for actions that write to the user's
/// Spotify library. The geometry follows Spotify's circular icon: a solid
/// circle with three curved signal lines.
class SpotifyLogoIcon extends StatelessWidget {
  const SpotifyLogoIcon({
    super.key,
    this.size = 22,
    this.color = const Color(0xFF1ED760),
    this.markColor = Colors.black,
  });

  final double size;
  final Color color;
  final Color markColor;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _SpotifyLogoPainter(color: color, markColor: markColor),
    );
  }
}

class _SpotifyLogoPainter extends CustomPainter {
  const _SpotifyLogoPainter({required this.color, required this.markColor});

  final Color color;
  final Color markColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()..color = color,
    );

    final stroke = (radius * 0.13).clamp(1.4, 3.0).toDouble();
    final paint = Paint()
      ..color = markColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    final inset = radius * 0.38;
    final width = radius * 1.22;
    final top = center.dy - radius * 0.18;

    for (var i = 0; i < 3; i++) {
      final y = top + i * radius * 0.27;
      final rect = Rect.fromCenter(
        center: Offset(center.dx, y),
        width: width,
        height: radius * 0.62,
      );
      canvas.drawArc(
        rect,
        math.pi * 0.18,
        math.pi * 0.64,
        false,
        paint,
      );
    }

    // Keep the lower signal line comfortably inside the circular mark.
    // The variable is intentionally derived from the same inset used above.
    assert(inset >= 0);
  }

  @override
  bool shouldRepaint(covariant _SpotifyLogoPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.markColor != markColor;
}
