/// 一次采样得到的完整系统快照（方案文档 §6.3.1 仪表盘数据源）。
///
/// 数据来自单次 SSH exec 批量采集（<50ms 开销），由 MonitorService 解析。
class SystemSnapshot {
  const SystemSnapshot({
    required this.time,
    required this.hostName,
    required this.kernel,
    required this.cpuUsage,
    required this.loadAvg,
    required this.memory,
    required this.gpus,
    required this.processes,
    required this.disks,
    required this.netRxBytesPerSec,
    required this.netTxBytesPerSec,
    required this.uptimeSeconds,
  });

  final DateTime time;
  final String hostName;
  final String kernel;

  /// CPU 总使用率 0~100
  final double cpuUsage;

  /// [1min, 5min, 15min]
  final List<double> loadAvg;

  final MemInfo memory;
  final List<GpuInfo> gpus;
  final List<ProcessInfo> processes;
  final List<DiskInfo> disks;

  /// 全网卡（不含 lo/虚拟网桥）接收/发送速率，字节/秒
  final double netRxBytesPerSec;
  final double netTxBytesPerSec;

  final double uptimeSeconds;
}

class MemInfo {
  const MemInfo({
    required this.totalBytes,
    required this.usedBytes,
    required this.availableBytes,
    this.swapTotalBytes = 0,
    this.swapUsedBytes = 0,
  });

  final double totalBytes;
  final double usedBytes;
  final double availableBytes;
  final double swapTotalBytes;
  final double swapUsedBytes;

  double get usedPercent => totalBytes <= 0 ? 0 : usedBytes / totalBytes * 100;
}

class GpuInfo {
  const GpuInfo({
    required this.index,
    required this.name,
    required this.utilization,
    required this.memoryUsedMB,
    required this.memoryTotalMB,
    required this.temperature,
    this.powerWatts,
  });

  final int index;
  final String name;

  /// 0~100，null 表示驱动不支持
  final int? utilization;
  final int? memoryUsedMB;
  final int? memoryTotalMB;
  final int? temperature;
  final double? powerWatts;

  double get memoryPercent {
    final u = memoryUsedMB, t = memoryTotalMB;
    if (u == null || t == null || t <= 0) return 0;
    return u / t * 100;
  }
}

class ProcessInfo {
  const ProcessInfo({
    required this.pid,
    required this.user,
    required this.cpuPercent,
    required this.memPercent,
    required this.command,
    required this.isHeavyTask,
  });

  final int pid;
  final String user;
  final double cpuPercent;
  final double memPercent;
  final String command;

  /// 是否为渲染/编译/训练类重度任务进程（仪表盘中高亮，方案文档 §6.3.1）
  final bool isHeavyTask;
}

class DiskInfo {
  const DiskInfo({
    required this.mount,
    required this.totalBytes,
    required this.usedBytes,
  });

  final String mount;
  final double totalBytes;
  final double usedBytes;

  double get usedPercent => totalBytes <= 0 ? 0 : usedBytes / totalBytes * 100;
}
