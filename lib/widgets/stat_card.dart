import 'package:flutter/material.dart';

/// 仪表盘统一卡片容器。
class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.title,
    this.icon,
    this.trailing,
    required this.child,
  });

  final String title;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 15, color: Colors.white38),
                  const SizedBox(width: 6),
                ],
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Colors.white54,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

/// 水平占比条（内存/磁盘）
class UsageBar extends StatelessWidget {
  const UsageBar({
    super.key,
    required this.percent,
    this.color,
    this.height = 8,
  });

  final double percent; // 0~100
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = percent.clamp(0, 100) / 100;
    final c = color ??
        (p >= 0.9
            ? const Color(0xFFFF5A5A)
            : p >= 0.7
                ? const Color(0xFFFFC65C)
                : const Color(0xFF3DDC97));
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: LinearProgressIndicator(
        value: p,
        minHeight: height,
        backgroundColor: Colors.white10,
        valueColor: AlwaysStoppedAnimation(c),
      ),
    );
  }
}
