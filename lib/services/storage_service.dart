import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_config.dart';
import '../models/task_info.dart';

/// 在 main.dart 中通过 ProviderScope.overrides 注入。
final storageProvider = Provider<StorageService>((ref) {
  throw UnimplementedError('storageProvider 必须在 ProviderScope 中 override');
});

/// 本地持久化：服务器配置、任务历史、Snippets（快捷命令）。
///
/// 说明：MVP 使用 SharedPreferences（内部为 JSON 明文）。凭据的加密存储
/// 应在生产版本中替换为 flutter_secure_storage（README 已注明）。
class StorageService {
  StorageService(this._prefs);

  final SharedPreferences _prefs;

  static const _kServers = 'ghostpanel.servers.v1';
  static const _kTasks = 'ghostpanel.tasks.v1';
  static const _kSnippets = 'ghostpanel.snippets.v1';

  /// 任务历史保留上限，防止无限膨胀
  static const maxTaskHistory = 200;

  static const List<String> defaultSnippets = [
    'nvidia-smi',
    'htop',
    'tmux ls',
    'df -h',
    'free -h',
    'uptime',
    'ps aux --sort=-%cpu | head -10',
    'journalctl -p err -n 20 --no-pager',
  ];

  // ---- 服务器 ----

  List<ServerConfig> loadServers() {
    final raw = _prefs.getStringList(_kServers) ?? const [];
    final result = <ServerConfig>[];
    for (final item in raw) {
      try {
        result.add(ServerConfig.fromJson(jsonDecode(item) as Map<String, dynamic>));
      } catch (_) {
        // 跳过损坏条目
      }
    }
    return result;
  }

  Future<void> saveServers(List<ServerConfig> servers) => _prefs.setStringList(
        _kServers,
        servers.map((s) => jsonEncode(s.toJson())).toList(),
      );

  // ---- 任务历史 ----

  List<GhostTask> loadTasks() {
    final raw = _prefs.getStringList(_kTasks) ?? const [];
    final result = <GhostTask>[];
    for (final item in raw) {
      try {
        result.add(GhostTask.fromJson(jsonDecode(item) as Map<String, dynamic>));
      } catch (_) {}
    }
    return result;
  }

  Future<void> saveTasks(List<GhostTask> tasks) {
    final trimmed = tasks.length > maxTaskHistory
        ? tasks.sublist(tasks.length - maxTaskHistory)
        : tasks;
    return _prefs.setStringList(
      _kTasks,
      trimmed.map((t) => jsonEncode(t.toJson())).toList(),
    );
  }

  // ---- Snippets ----

  List<String> loadSnippets() => _prefs.getStringList(_kSnippets) ?? defaultSnippets;

  Future<void> saveSnippets(List<String> snippets) =>
      _prefs.setStringList(_kSnippets, snippets);
}
