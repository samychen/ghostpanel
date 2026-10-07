/// 通用格式化工具。
library;

/// 字节数人性化：1536 -> "1.5 KB"
String humanBytes(num bytes, {int decimals = 1}) {
  if (bytes.isNaN || bytes.isInfinite) return '--';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0
      ? '${value.toStringAsFixed(0)} ${units[unit]}'
      : '${value.toStringAsFixed(decimals)} ${units[unit]}';
}

/// 速率人性化：字节/秒
String humanRate(num bytesPerSec) => '${humanBytes(bytesPerSec)}/s';

/// 运行时长：秒 -> "3天4小时" / "2小时5分" / "45秒"
String humanDuration(num seconds) {
  if (seconds.isNaN || seconds < 0) return '--';
  final s = seconds.round();
  final d = s ~/ 86400;
  final h = (s % 86400) ~/ 3600;
  final m = (s % 3600) ~/ 60;
  if (d > 0) return '$d天$h小时';
  if (h > 0) return '$h小时$m分';
  if (m > 0) return '$m分${s % 60}秒';
  return '$s秒';
}

/// 百分比字符串，null 安全
String pct(num? v, {int decimals = 0}) =>
    v == null ? '--' : '${v.toStringAsFixed(decimals)}%';
