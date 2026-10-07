/// 无感任务舱中的任务（方案文档 §6.3.2）。
///
/// 任务 = 远端一个 tmux 会话 + 一份日志文件 + 一层 systemd-run/nice 资源限制包裹。
enum TaskStatus {
  running('运行中'),
  stopped('已结束'),
  failed('失败'),
  unknown('未知');

  const TaskStatus(this.label);
  final String label;

  static TaskStatus fromName(String? name) => TaskStatus.values.firstWhere(
        (s) => s.name == name,
        orElse: () => TaskStatus.unknown,
      );
}

class GhostTask {
  const GhostTask({
    required this.id,
    required this.serverId,
    required this.command,
    required this.logPath,
    required this.scriptPath,
    required this.cpuQuota,
    required this.memoryMax,
    required this.lowIo,
    required this.createdAt,
    this.status = TaskStatus.unknown,
    this.exitCode,
  });

  /// 即 tmux 会话名，形如 `ghost_task_<epoch_ms>`
  final String id;
  final String serverId;
  final String command;
  final String logPath;
  final String scriptPath;
  final int cpuQuota;
  final String memoryMax;

  /// 是否附加 ionice -c3（IO 空闲优先级）
  final bool lowIo;
  final DateTime createdAt;
  final TaskStatus status;
  final int? exitCode;

  GhostTask copyWith({TaskStatus? status, int? exitCode}) => GhostTask(
        id: id,
        serverId: serverId,
        command: command,
        logPath: logPath,
        scriptPath: scriptPath,
        cpuQuota: cpuQuota,
        memoryMax: memoryMax,
        lowIo: lowIo,
        createdAt: createdAt,
        status: status ?? this.status,
        exitCode: exitCode ?? this.exitCode,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'serverId': serverId,
        'command': command,
        'logPath': logPath,
        'scriptPath': scriptPath,
        'cpuQuota': cpuQuota,
        'memoryMax': memoryMax,
        'lowIo': lowIo,
        'createdAt': createdAt.toIso8601String(),
        'status': status.name,
        'exitCode': exitCode,
      };

  factory GhostTask.fromJson(Map<String, dynamic> json) => GhostTask(
        id: json['id'] as String,
        serverId: json['serverId'] as String? ?? '',
        command: json['command'] as String? ?? '',
        logPath: json['logPath'] as String? ?? '',
        scriptPath: json['scriptPath'] as String? ?? '',
        cpuQuota: (json['cpuQuota'] as num?)?.toInt() ?? 30,
        memoryMax: json['memoryMax'] as String? ?? '4G',
        lowIo: json['lowIo'] as bool? ?? true,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        status: TaskStatus.fromName(json['status'] as String?),
        exitCode: (json['exitCode'] as num?)?.toInt(),
      );
}
