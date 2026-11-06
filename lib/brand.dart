import 'package:flutter/material.dart';

/// The same C/play mark used by the Android launcher and startup screen.
class CurlymaxMark extends StatelessWidget {
  const CurlymaxMark({super.key, this.size = 48});
  final double size;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'CURLYmax app logo',
    image: true,
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _MarkPainter()),
    ),
  );
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 108, size.height / 108);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 108, 108),
        const Radius.circular(24),
      ),
      Paint()..color = const Color(0xFF11180E),
    );
    final ring = Path()
      ..moveTo(73, 29)
      ..arcToPoint(
        const Offset(73, 79),
        radius: const Radius.circular(32),
        largeArc: true,
        clockwise: false,
      )
      ..lineTo(64, 66)
      ..arcToPoint(
        const Offset(64, 42),
        radius: const Radius.circular(16),
        largeArc: true,
      )
      ..close();
    final paint = Paint()..color = const Color(0xFFCEFF5E);
    canvas.drawPath(ring, paint);
    canvas.drawPath(
      Path()
        ..moveTo(65, 42)
        ..lineTo(86, 54)
        ..lineTo(65, 66)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
