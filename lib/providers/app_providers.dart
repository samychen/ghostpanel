import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/server_config.dart';
import '../models/system_stats.dart';
import '../models/task_info.dart';
import '../services/command_guard.dart';
import '../services/monitor_service.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../services/task_runner.dart';
import '../services/transfer_service.dart';

// ---------------------------------------------------------------- 前台/后台

/// App 是否处于前台。仪表盘刷新策略（方案文档 §6.3.1）：
/// 前台每 3 秒，后台每 30 秒 —— 由 HomeScreen 的 WidgetsBindingObserver 维护。
final foregroundProvider = StateProvider<bool>((ref) => true);

// ---------------------------------------------------------------- 服务器列表

class ServersNotifier extends Notifier<List<ServerConfig>> {
  @override
  List<ServerConfig> build() => ref.read(storageProvider).loadServers();

  void upsert(ServerConfig config) {
    final list = [...state];
    final idx = list.indexWhere((s) => s.id == config.id);
    if (idx >= 0) {
      list[idx] = config;
    } else {
      list.add(config);
    }
    state = list;
    _persist();
  }

  void remove(String id) {
    state = state.where((s) => s.id != id).toList();
    _persist();
  }

  ServerConfig? byId(String id) {
    for (final s in state) {
      if (s.id == id) return s;
    }
    return null;
  }

  void _persist() => ref.read(storageProvider).saveServers(state);
}

final serversProvider =
    NotifierProvider<ServersNotifier, List<ServerConfig>>(ServersNotifier.new);

// ---------------------------------------------------------------- SSH 连接

/// 当前活动连接（MVP 为单连接模型）。
class AppConnection {
  const AppConnection({
    this.server,
    this.service,
    this.link = LinkState.disconnected,
    this.error,
  });

  final ServerConfig? server;
  final SSHService? service;
  final LinkState link;
  final String? error;

  bool get isConnected => link == LinkState.connected && service != null;

  AppConnection copyWith({
    ServerConfig? server,
    SSHService? service,
    LinkState? link,
    String? error,
  }) =>
      AppConnection(
        server: server ?? this.server,
        service: service ?? this.service,
        link: link ?? this.link,
        error: error,
      );
}

class ConnectionNotifier extends Notifier<AppConnection> {
  StreamSubscription<LinkState>? _sub;

  @override
  AppConnection build() {
    ref.onDispose(_teardown);
    return const AppConnection();
  }

  /// 连接目标服务器；成功返回 true。会先断开旧连接。
  Future<bool> connect(ServerConfig config) async {
    await disconnect();

    final service = SSHService(config);
    state = AppConnection(
      server: config,
      service: service,
      link: LinkState.connecting,
    );
    _sub = service.stateStream.listen((link) {
      state = AppConnection(
        server: config,
        service: service,
        link: link,
        error: service.lastError,
      );
    });

    try {
      await service.connect();
      return true;
    } catch (e) {
      state = AppConnection(
        server: config,
        service: null,
        link: LinkState.disconnected,
        error: '$e',
      );
      _teardown();
      await service.dispose();
      return false;
    }
  }

  Future<void> disconnect() async {
    final old = state.service;
    _teardown();
    state = const AppConnection();
    if (old != null) await old.dispose();
  }

  void _teardown() {
    _sub?.cancel();
    _sub = null;
  }
}

final connectionProvider =
    NotifierProvider<ConnectionNotifier, AppConnection>(ConnectionNotifier.new);

// ---------------------------------------------------------------- 监控流

/// 仪表盘数据流：前台 3s / 后台 30s 轮询（方案文档 §6.3.1 刷新策略）。
final monitorProvider = StreamProvider.autoDispose<SystemSnapshot>((ref) async* {
  final conn = ref.watch(connectionProvider);
  final service = conn.service;
  if (service == null || !conn.isConnected) return;

  final monitor = MonitorService(service);
  while (true) {
    try {
      yield await monitor.fetch();
    } catch (_) {
      // 单次采集失败（网络抖动/重连中）不打断流，静默等下一轮
    }
    final foreground = ref.read(foregroundProvider);
    await Future<void>.delayed(Duration(seconds: foreground ? 3 : 30));
  }
});

/// 仪表盘历史曲线数据（CPU/内存/网速），最多保留 60 个点。
class HistoryNotifier extends AutoDisposeNotifier<List<SystemSnapshot>> {
  @override
  List<SystemSnapshot> build() {
    ref.listen(monitorProvider, (prev, next) {
      final snap = next.valueOrNull;
      if (snap == null) return;
      final list = [...state, snap];
      state = list.length > 60 ? list.sublist(list.length - 60) : list;
    });
    return const [];
  }

  void clear() => state = const [];
}

final historyProvider =
    NotifierProvider.autoDispose<HistoryNotifier, List<SystemSnapshot>>(
        HistoryNotifier.new);

// ---------------------------------------------------------------- 任务舱

class TasksNotifier extends AutoDisposeAsyncNotifier<List<GhostTask>> {
  Timer? _poll;

  TaskRunner _runner() {
    final service = ref.read(connectionProvider).service;
    if (service == null) throw StateError('未连接到工作站');
    return TaskRunner(service);
  }

  @override
  FutureOr<List<GhostTask>> build() async {
    final storage = ref.read(storageProvider);
    final conn = ref.read(connectionProvider);
    final all = storage.loadTasks();
    final tasks = conn.server == null
        ? <GhostTask>[]
        : all.where((t) => t.serverId == conn.server!.id).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    // 连接可用时后台刷新一次真实状态；随后每 5 秒轮询
    if (conn.isConnected) {
      unawaited(refreshStatuses());
      _poll = Timer.periodic(const Duration(seconds: 5), (_) {
        unawaited(refreshStatuses());
      });
      ref.onDispose(() => _poll?.cancel());
    }
    return tasks;
  }

  /// 用远端 tmux 会话 + 退出码标记刷新所有任务状态。
  Future<void> refreshStatuses() async {
    final conn = ref.read(connectionProvider);
    if (!conn.isConnected) return;
    try {
      final runner = _runner();
      final running = await runner.runningSessionNames();
      final exits = await runner.finishedExitCodes();
      final current = state.valueOrNull ?? const <GhostTask>[];
      var changed = false;
      final updated = current.map((t) {
        TaskStatus newStatus;
        int? exitCode = t.exitCode;
        if (running.contains(t.id)) {
          newStatus = TaskStatus.running;
        } else if (exits.containsKey(t.id)) {
          exitCode = exits[t.id];
          newStatus = exitCode == 0 ? TaskStatus.stopped : TaskStatus.failed;
        } else {
          newStatus = t.status == TaskStatus.running ? TaskStatus.unknown : t.status;
        }
        if (newStatus != t.status || exitCode != t.exitCode) {
          changed = true;
          return t.copyWith(status: newStatus, exitCode: exitCode);
        }
        return t;
      }).toList();
      if (changed) {
        state = AsyncData(updated);
        _persist(updated);
      }
    } catch (_) {
      // 刷新失败静默（重连中），下一轮再试
    }
  }

  /// 提交无感任务（先过危险命令拦截）。
  Future<GhostTask> submit({
    required String command,
    int? cpuQuota,
    String? memoryMax,
    bool lowIo = true,
  }) async {
    final conn = ref.read(connectionProvider);
    final server = conn.server;
    if (server == null) throw StateError('未连接到工作站');

    final verdict = CommandGuard.check(command);
    if (verdict.isDanger) {
      throw GuardBlockedException(verdict);
    }

    final task = await _runner().submit(
      command: command,
      serverId: server.id,
      cpuQuota: cpuQuota ?? server.defaultCpuQuota,
      memoryMax: memoryMax ?? server.defaultMemoryMax,
      lowIo: lowIo,
    );
    final list = <GhostTask>[task, ...(state.valueOrNull ?? const <GhostTask>[])];
    state = AsyncData(list);
    _persist(list);
    return task;
  }

  Future<void> kill(GhostTask task) async {
    await _runner().kill(task);
    final list = (state.valueOrNull ?? const <GhostTask>[])
        .map((t) => t.id == task.id ? t.copyWith(status: TaskStatus.stopped) : t)
        .toList();
    state = AsyncData(list);
    _persist(list);
  }

  /// 删除本地记录，并可选清理远端日志/脚本。
  Future<void> remove(GhostTask task, {bool cleanupRemote = true}) async {
    if (cleanupRemote) {
      try {
        await _runner().cleanupRemote(task);
      } catch (_) {}
    }
    final list = (state.valueOrNull ?? const <GhostTask>[]).where((t) => t.id != task.id).toList();
    state = AsyncData(list);
    _persist(list);
  }

  Future<String> tailLog(GhostTask task, {int lines = 200}) =>
      _runner().tailLog(task, lines: lines);

  void _persist(List<GhostTask> tasks) {
    ref.read(storageProvider).saveTasks(tasks);
  }
}

final tasksProvider =
    AsyncNotifierProvider.autoDispose<TasksNotifier, List<GhostTask>>(
        TasksNotifier.new);

/// 任务提交被危险命令拦截时抛出（UI 层弹确认框）。
class GuardBlockedException implements Exception {
  GuardBlockedException(this.verdict);
  final GuardVerdict verdict;
  @override
  String toString() => verdict.reason;
}

// ---------------------------------------------------------------- 文件传输

final transferServiceProvider = Provider<TransferService?>((ref) {
  final service = ref.watch(connectionProvider).service;
  if (service == null) return null;
  return TransferService(service);
});

// ---------------------------------------------------------------- Snippets

class SnippetsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => ref.read(storageProvider).loadSnippets();

  void add(String snippet) {
    final s = snippet.trim();
    if (s.isEmpty || state.contains(s)) return;
    state = [...state, s];
    ref.read(storageProvider).saveSnippets(state);
  }

  void removeAt(int index) {
    final list = [...state]..removeAt(index);
    state = list;
    ref.read(storageProvider).saveSnippets(list);
  }
}

final snippetsProvider =
    NotifierProvider<SnippetsNotifier, List<String>>(SnippetsNotifier.new);
