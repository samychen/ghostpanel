import 'package:flutter/material.dart';

/// GhostPanel 主题：深色为主（幽灵风格），强调色为终端绿。
class GhostTheme {
  GhostTheme._();

  /// 幽灵绿（终端 phosphor 风格）
  static const Color accent = Color(0xFF3DDC97);
  static const Color danger = Color(0xFFFF5A5A);
  static const Color warn = Color(0xFFFFC65C);
  static const Color info = Color(0xFF5AC8FA);

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF0D1117),
      cardColor: const Color(0xFF161B22),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0D1117),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF10151C),
        indicatorColor: accent.withValues(alpha: 0.18),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        isDense: true,
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
      listTileTheme: const ListTileThemeData(iconColor: Color(0xFF8B949E)),
      dividerTheme: const DividerThemeData(color: Color(0xFF21262D), space: 24),
    );
  }

  /// 等宽字体样式（终端 / 日志 / 进程列表）
  static const TextStyle mono = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['Menlo', 'Consolas', 'Courier New'],
    fontSize: 12.5,
    height: 1.35,
  );
}
