import '../models/task_info.dart';
import 'ssh_service.dart';

/// 无感任务舱（方案文档 §6.3.2）。
///
/// 用户提交 `make -j4`，实际在远端发生的是：
///
/// ```
/// tmux new-session -d -s ghost_task_xxx /tmp/ghost_task_xxx.sh
///   └── 脚本内部:
///       systemd-run --user --scope -p CPUQuota=30% -p MemoryMax=4G \
///         nice -n 19 ionice -c3 bash -c 'make -j4' 2>&1 | tee /tmp/ghost_task_xxx.log
///       echo "[ghost] exit=$?" >> log
/// ```
///
/// - systemd-run 不可用时自动退化为 nice/ionice（保底不抢前台渲染资源）；
/// - 任务结束后 tmux 会话自动消亡 → 状态判定为 stopped/failed（依据退出码标记）；
/// - 日志保留在 /tmp，可随时 tail 查看输出。
class TaskRunner {
  TaskRunner(this._ssh);

  final SSHService _ssh;

  static const String sessionPrefix = 'ghost_task_';
  static const String _heredocMarker = 'GHOSTPANEL_SCRIPT_EOF';

  /// 提交一个静默任务，返回任务描述（状态先记为 running）。
  Future<GhostTask> submit({
    required String command,
    required String serverId,
    int cpuQuota = 30,
    String memoryMax = '4G',
    bool lowIo = true,
  }) async {
    if (command.trim().isEmpty) {
      throw StateError('命令不能为空');
    }
    final now = DateTime.now();
    final id = '$sessionPrefix${now.millisecondsSinceEpoch}';
    final logPath = '/tmp/$id.log';
    final scriptPath = '/tmp/$id.sh';

    final script = _buildScript(
      id: id,
      command: command,
      logPath: logPath,
      cpuQuota: cpuQuota,
      memoryMax: memoryMax,
      lowIo: lowIo,
    );
    if (script.contains(_heredocMarker) || command.contains(_heredocMarker)) {
      throw StateError('命令包含内部保留标记，请修改后重试');
    }

    // 1) 通过 heredoc 把脚本写到远端 /tmp（umask 077 防泄漏）
    final upload = "umask 077; cat > '$scriptPath' <<'$_heredocMarker'\n"
        '$script\n'
        '$_heredocMarker\n'
        "chmod +x '$scriptPath' && echo GHOST_UPLOAD_OK";
    final r1 = await _ssh.execFull(upload);
    if (!r1.stdout.contains('GHOST_UPLOAD_OK')) {
      throw StateError('写入任务脚本失败: ${r1.stderr.trim().isEmpty ? r1.stdout : r1.stderr}');
    }

    // 2) tmux 后台拉起（脚本结束 → 会话结束）
    final r2 = await _ssh.execFull(
      "tmux new-session -d -s $id '$scriptPath' && echo GHOST_TMUX_OK",
    );
    if (!r2.stdout.contains('GHOST_TMUX_OK')) {
      throw StateError('创建 tmux 会话失败: ${r2.stderr.trim().isEmpty ? 'tmux 是否已安装？' : r2.stderr}');
    }

    return GhostTask(
      id: id,
      serverId: serverId,
      command: command,
      logPath: logPath,
      scriptPath: scriptPath,
      cpuQuota: cpuQuota,
      memoryMax: memoryMax,
      lowIo: lowIo,
      createdAt: now,
      status: TaskStatus.running,
    );
  }

  String _buildScript({
    required String id,
    required String command,
    required String logPath,
    required int cpuQuota,
    required String memoryMax,
    required bool lowIo,
  }) {
    final escaped = command.replaceAll("'", "'\\''");
    final ioPrefix = lowIo ? 'ionice -c3 ' : '';
    final quota = cpuQuota.clamp(5, 100);
    final mem = memoryMax.trim().isEmpty ? 'infinity' : memoryMax.trim();

    return '''#!/usr/bin/env bash
# GhostPanel 无感任务 $id
# 命令: $command
# 资源封顶: CPU $quota% / 内存 $mem / nice 19${lowIo ? ' / ionice idle' : ''}
set -o pipefail
GHOST_LOG='$logPath'

ghost_run() {
  if command -v systemd-run >/dev/null 2>&1 \\
     && systemd-run --user --scope --quiet /bin/true 2>/dev/null; then
    systemd-run --user --scope --quiet \\
      -p CPUQuota=$quota% \\
      -p MemoryMax=$mem \\
      nice -n 19 ${ioPrefix}bash -c '$escaped'
  else
    # systemd-run 不可用（无用户实例等）时退化为 nice/ionice，保证不抢前台资源
    nice -n 19 ${ioPrefix}bash -c '$escaped'
  fi
}

: > "\$GHOST_LOG"
ghost_run 2>&1 | tee -a "\$GHOST_LOG"
code=\$?
echo "[ghost] exit=\$code" >> "\$GHOST_LOG"
exit \$code
''';
  }

  // ---------------------------------------------------------------- 状态

  /// 当前远端仍在运行的 ghost 任务会话名集合。
  Future<Set<String>> runningSessionNames() async {
    final r = await _ssh.execFull(
      'tmux ls -F \'#{session_name}\' 2>/dev/null || true',
    );
    return r.stdout
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.startsWith(sessionPrefix))
        .toSet();
  }

  /// 批量读取所有已结束任务的退出码标记（一次 exec，避免 N 次往返）。
  Future<Map<String, int>> finishedExitCodes() async {
    final r = await _ssh.execFull(
      'for f in /tmp/$sessionPrefix*.log; do '
      '[ -f "\$f" ] || continue; '
      'echo "@@\$f"; tail -n 2 "\$f" | grep -o "\\[ghost\\] exit=[0-9-]*" | tail -1; '
      'done 2>/dev/null || true',
    );
    final result = <String, int>{};
    String? currentFile;
    for (final line in r.stdout.split('\n')) {
      final t = line.trim();
      if (t.startsWith('@@')) {
        currentFile = t.substring(2);
      } else if (currentFile != null && t.startsWith('[ghost] exit=')) {
        final code = int.tryParse(t.substring('[ghost] exit='.length));
        if (code != null) {
          // /tmp/ghost_task_xxx.log -> ghost_task_xxx
          final id = currentFile.split('/').last.replaceAll('.log', '');
          result[id] = code;
        }
        currentFile = null;
      }
    }
    return result;
  }

  /// 读取任务日志尾部。
  Future<String> tailLog(GhostTask task, {int lines = 200}) async {
    final r = await _ssh.execFull(
      "tail -n $lines '${task.logPath}' 2>/dev/null || echo '(日志不存在或已被清理)'",
    );
    return r.stdout;
  }

  /// 终止任务（杀 tmux 会话；cgroup 内进程随 scope 一并回收）。
  Future<void> kill(GhostTask task) async {
    await _ssh.execFull("tmux kill-session -t '${task.id}' 2>/dev/null || true");
  }

  /// 清理远端脚本与日志。
  Future<void> cleanupRemote(GhostTask task) async {
    await _ssh.execFull(
      "rm -f '${task.scriptPath}' '${task.logPath}' 2>/dev/null || true",
    );
  }
}
