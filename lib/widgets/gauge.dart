import 'dart:math';

import 'package:flutter/material.dart';

/// 环形仪表盘（GPU 占用率 / 温度等），CustomPainter 实现，零依赖。
class DonutGauge extends StatelessWidget {
  const DonutGauge({
    super.key,
    required this.value,
    required this.maxValue,
    required this.label,
    this.sublabel,
    this.color,
    this.size = 108,
  });

  /// 当前值；null 时显示 "--"
  final double? value;
  final double maxValue;
  final String label;
  final String? sublabel;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fraction = value == null
        ? 0.0
        : (value! / maxValue).clamp(0.0, 1.0);
    final baseColor = color ?? _autoColor(fraction);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _DonutPainter(fraction: fraction, color: baseColor),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value == null ? '--' : value!.toStringAsFixed(0),
                style: TextStyle(
                  fontSize: size * 0.24,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  fontFamily: 'monospace',
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: size * 0.105,
                  color: Colors.white54,
                ),
              ),
              if (sublabel != null)
                Text(
                  sublabel!,
                  style: TextStyle(
                    fontSize: size * 0.095,
                    color: Colors.white38,
                    fontFamily: 'monospace',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static Color _autoColor(double fraction) {
    if (fraction >= 0.9) return const Color(0xFFFF5A5A);
    if (fraction >= 0.7) return const Color(0xFFFFC65C);
    return const Color(0xFF3DDC97);
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({required this.fraction, required this.color});

  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.10;
    final rect = Rect.fromLTWH(stroke / 2, stroke / 2,
        size.width - stroke, size.height - stroke);

    final bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Colors.white.withValues(alpha: 0.07);
    // 270° 弧，缺口在正下方
    canvas.drawArc(rect, pi * 0.75, pi * 1.5, false, bg);

    if (fraction > 0.001) {
      final fg = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: pi * 0.75,
          endAngle: pi * 2.25,
          colors: [color.withValues(alpha: 0.55), color],
          transform: const GradientRotation(0),
        ).createShader(rect);
      canvas.drawArc(rect, pi * 0.75, pi * 1.5 * fraction, false, fg);
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.fraction != fraction || old.color != color;
}
