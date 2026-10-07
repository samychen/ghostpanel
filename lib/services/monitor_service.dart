import '../models/system_stats.dart';
import 'ssh_service.dart';

/// 仪表盘数据采集（方案文档 §6.3.1）。
///
/// 设计要点：
/// - **一次 SSH exec 批量采集全部指标**，避免多次往返，单次开销 <50ms；
/// - 全部走纯文本命令（top/free/ps/df/procfs/nvidia-smi），不触碰图形会话；
/// - nvidia-smi 不存在时优雅降级（gpus 为空列表）；
/// - 网络速率由相邻两次采样的 /proc/net/dev 差值计算（实例内保存上次样本）。
class MonitorService {
  MonitorService(this._ssh);

  final SSHService _ssh;

  // 上一次网络计数样本（计算速率用）
  double? _lastRxBytes;
  double? _lastTxBytes;
  DateTime? _lastNetTime;

  /// 批量探针命令。所有子命令都容错（|| true / 2>/dev/null），任何一项失败不影响整体。
  static const String probeCommand = r'''
echo '@@CPU@@'; LC_ALL=C top -bn1 2>/dev/null | head -5
echo '@@LOAD@@'; cat /proc/loadavg 2>/dev/null || true
echo '@@MEM@@'; free -b 2>/dev/null | head -3 || true
echo '@@GPU@@'; if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null || echo 'ERR'; else echo 'NONE'; fi
echo '@@PROC@@'; ps aux --sort=-%cpu 2>/dev/null | head -11 || true
echo '@@DISK@@'; df -B1 -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | head -8 || true
echo '@@NET@@'; cat /proc/net/dev 2>/dev/null || true
echo '@@UP@@'; cat /proc/uptime 2>/dev/null || true
echo '@@HOST@@'; hostname 2>/dev/null; uname -r 2>/dev/null
echo '@@END@@'
''';

  /// 重度任务进程特征：渲染 / 转码 / 编译 / AI 训练（仪表盘高亮，文档 §6.3.1）
  static final RegExp _heavyPattern = RegExp(
    r'blender|ffmpeg|ffprobe|davinci|resolve|premiere|afterfx|handbrake|'
    r'nvcc|cc1plus|cicc|ptxas|/gcc|/g\+\+|/clang|\bmake\b|ninja|cargo|go build|'
    r'train\.py|torchrun|deepspeed|comfyui|ollama|llama|stable-diffusion|python[0-9.]* .*--epoch',
    caseSensitive: false,
  );

  Future<SystemSnapshot> fetch() async {
    final result = await _ssh.execFull(
      probeCommand,
      isolateEnv: false, // 探针命令与图形环境无关，无需前缀，省几毫秒
      timeout: const Duration(seconds: 15),
    );
    if (!result.ok && result.stdout.isEmpty) {
      throw StateError(result.stderr.isEmpty ? '监控探针执行失败' : result.stderr);
    }
    return parse(result.stdout);
  }

  // ---------------------------------------------------------------- 解析

  SystemSnapshot parse(String raw) {
    final sections = _splitSections(raw);

    final cpu = _parseCpu(sections['CPU'] ?? '');
    final load = _parseLoad(sections['LOAD'] ?? '');
    final mem = _parseMem(sections['MEM'] ?? '');
    final gpus = _parseGpu(sections['GPU'] ?? '');
    final procs = _parseProcs(sections['PROC'] ?? '');
    final disks = _parseDisk(sections['DISK'] ?? '');
    final (rx, tx) = _parseNet(sections['NET'] ?? '');
    final uptime = _parseFirstNumber(sections['UP'] ?? '') ?? 0;
    final hostLines = (sections['HOST'] ?? '').trim().split('\n');

    return SystemSnapshot(
      time: DateTime.now(),
      hostName: hostLines.isNotEmpty ? hostLines[0].trim() : 'unknown',
      kernel: hostLines.length > 1 ? hostLines[1].trim() : '',
      cpuUsage: cpu,
      loadAvg: load,
      memory: mem,
      gpus: gpus,
      processes: procs,
      disks: disks,
      netRxBytesPerSec: rx,
      netTxBytesPerSec: tx,
      uptimeSeconds: uptime,
    );
  }

  Map<String, String> _splitSections(String raw) {
    final result = <String, String>{};
    final pattern = RegExp(r'^@@(\w+)@@\s*$', multiLine: true);
    final matches = pattern.allMatches(raw).toList();
    for (var i = 0; i < matches.length; i++) {
      final name = matches[i].group(1)!;
      final start = matches[i].end;
      final end = i + 1 < matches.length ? matches[i + 1].start : raw.length;
      result[name] = raw.substring(start, end);
    }
    return result;
  }

  double _parseCpu(String section) {
    // 形如: %Cpu(s):  3.2 us,  1.1 sy,  0.0 ni, 95.4 id,  0.2 wa, ...
    final m = RegExp(r'([\d.]+)\s*id').firstMatch(section);
    if (m != null) {
      final idle = double.tryParse(m.group(1)!) ?? 0;
      return (100 - idle).clamp(0, 100).toDouble();
    }
    return 0;
  }

  List<double> _parseLoad(String section) {
    final nums = _numbers(section.trim().split('\n').first);
    return [
      if (nums.isNotEmpty) nums[0],
      if (nums.length > 1) nums[1],
      if (nums.length > 2) nums[2],
    ];
  }

  MemInfo _parseMem(String section) {
    // 新版 free -b: Mem: total used free shared buff/cache available
    // 旧版 free -b: Mem: total used free shared buffers cached available
    // 两种格式下 available 都是行内最后一个数字，used 统一按 total-available 计算。
    final lines = section.trim().split('\n');
    var total = 0.0, available = 0.0, swapTotal = 0.0, swapUsed = 0.0;
    for (final line in lines) {
      final nums = _numbers(line);
      if (nums.isEmpty) continue;
      final lower = line.toLowerCase();
      if (lower.startsWith('mem')) {
        total = nums[0];
        available = nums.last;
      } else if (lower.startsWith('swap') && nums.length >= 2) {
        swapTotal = nums[0];
        swapUsed = nums[1];
      }
    }
    return MemInfo(
      totalBytes: total,
      usedBytes: (total - available).clamp(0, total.isFinite ? total : 0).toDouble(),
      availableBytes: available,
      swapTotalBytes: swapTotal,
      swapUsedBytes: swapUsed,
    );
  }

  List<GpuInfo> _parseGpu(String section) {
    final body = section.trim();
    if (body.isEmpty || body == 'NONE' || body == 'ERR') return const [];
    final gpus = <GpuInfo>[];
    for (final line in body.split('\n')) {
      final parts = line.split(',').map((e) => e.trim()).toList();
      if (parts.length < 7) continue;
      final n = parts.length;
      int? toInt(String s) => int.tryParse(s.trim());
      double? toDouble(String s) => double.tryParse(s.trim());
      gpus.add(GpuInfo(
        index: toInt(parts[0]) ?? gpus.length,
        name: parts.sublist(1, n - 5).join(' '),
        utilization: toInt(parts[n - 5]),
        memoryUsedMB: toInt(parts[n - 4]),
        memoryTotalMB: toInt(parts[n - 3]),
        temperature: toInt(parts[n - 2]),
        powerWatts: toDouble(parts[n - 1]),
      ));
    }
    return gpus;
  }

  List<ProcessInfo> _parseProcs(String section) {
    final lines = section.trim().split('\n');
    final result = <ProcessInfo>[];
    for (final line in lines) {
      // 跳过表头
      if (line.startsWith('USER') || line.trim().isEmpty) continue;
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length < 11) continue;
      final pid = int.tryParse(fields[1]);
      if (pid == null) continue;
      final command = fields.sublist(10).join(' ');
      result.add(ProcessInfo(
        pid: pid,
        user: fields[0],
        cpuPercent: double.tryParse(fields[2]) ?? 0,
        memPercent: double.tryParse(fields[3]) ?? 0,
        command: command,
        isHeavyTask: _heavyPattern.hasMatch(command),
      ));
    }
    return result;
  }

  List<DiskInfo> _parseDisk(String section) {
    final result = <DiskInfo>[];
    final lines = section.trim().split('\n');
    for (final line in lines.skip(1)) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length < 6) continue;
      final total = double.tryParse(fields[1]) ?? 0;
      final used = double.tryParse(fields[2]) ?? 0;
      if (total <= 0) continue;
      result.add(DiskInfo(mount: fields.last, totalBytes: total, usedBytes: used));
    }
    return result;
  }

  /// 解析 /proc/net/dev 并计算与上次采样之间的速率。
  (double, double) _parseNet(String section) {
    var rx = 0.0, tx = 0.0;
    for (final line in section.split('\n')) {
      final idx = line.indexOf(':');
      if (idx < 0) continue;
      final iface = line.substring(0, idx).trim();
      // 排除回环与虚拟网卡，只看真实流量
      if (iface == 'lo' ||
          iface.startsWith('veth') ||
          iface.startsWith('docker') ||
          iface.startsWith('br-') ||
          iface.startsWith('virbr')) {
        continue;
      }
      final nums = _numbers(line.substring(idx + 1));
      if (nums.length >= 9) {
        rx += nums[0];
        tx += nums[8];
      }
    }

    final now = DateTime.now();
    var rxRate = 0.0, txRate = 0.0;
    if (_lastRxBytes != null && _lastNetTime != null) {
      final dt = now.difference(_lastNetTime!).inMicroseconds / 1e6;
      if (dt > 0.2) {
        rxRate = ((rx - _lastRxBytes!) / dt).clamp(0, double.infinity).toDouble();
        txRate = ((tx - _lastTxBytes!) / dt).clamp(0, double.infinity).toDouble();
      }
    }
    _lastRxBytes = rx;
    _lastTxBytes = tx;
    _lastNetTime = now;
    return (rxRate, txRate);
  }

  double? _parseFirstNumber(String s) {
    final nums = _numbers(s.trim().split('\n').first);
    return nums.isEmpty ? null : nums[0];
  }

  List<double> _numbers(String s) {
    return RegExp(r'-?\d+(\.\d+)?')
        .allMatches(s)
        .map((m) => double.tryParse(m.group(0)!) ?? 0)
        .toList();
  }
}
