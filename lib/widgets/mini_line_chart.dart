import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// 迷你历史折线图（CPU/内存/网速曲线）。
///
/// [values] 为时间序列（旧→新），[maxY] 为纵轴上限；
/// [maxY]=null 时自适应（网速等无固定量程的场景）。
class MiniLineChart extends StatelessWidget {
  const MiniLineChart({
    super.key,
    required this.values,
    required this.color,
    this.maxY,
    this.height = 90,
    this.valueFormatter,
  });

  final List<double> values;
  final Color color;
  final double? maxY;
  final double height;
  final String Function(double)? valueFormatter;

  @override
  Widget build(BuildContext context) {
    if (values.length < 2) {
      return SizedBox(
        height: height,
        child: const Center(
          child: Text('采集中…', style: TextStyle(color: Colors.white24, fontSize: 12)),
        ),
      );
    }

    final spots = <FlSpot>[
      for (var i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i]),
    ];
    final effectiveMaxY = maxY ??
        (values.reduce((a, b) => a > b ? a : b) * 1.2).clamp(1.0, double.infinity);

    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: effectiveMaxY,
          minX: 0,
          maxX: (values.length - 1).toDouble(),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: effectiveMaxY / 4,
            getDrawingHorizontalLine: (_) =>
                const FlLine(color: Colors.white10, strokeWidth: 1),
          ),
          titlesData: const FlTitlesData(show: false),
          borderData: FlBorderData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.25,
              barWidth: 2,
              color: color,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    color.withValues(alpha: 0.28),
                    color.withValues(alpha: 0.02),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
