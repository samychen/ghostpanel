import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/system_stats.dart';
import '../providers/app_providers.dart';
import '../theme.dart';
import '../utils/format.dart';
import '../widgets/gauge.dart';
import '../widgets/mini_line_chart.dart';
import '../widgets/stat_card.dart';

/// 仪表盘（方案文档 §6.3.1）。
///
/// 布局自上而下：GPU 仪表盘 → CPU/内存曲线 → 网络/磁盘 → Top 进程（渲染进程高亮）。
/// 数据由 monitorProvider 轮询推送（前台 3s / 后台 30s）。
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    if (!conn.isConnected) {
      return const _NotConnectedPlaceholder();
    }

    final snapAsync = ref.watch(monitorProvider);
    final history = ref.watch(historyProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(monitorProvider),
      child: snapAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorBody(message: '$e'),
        data: (snap) => ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          children: [
            _HostHeader(snap: snap),
            if (snap.gpus.isNotEmpty) _GpuSection(gpus: snap.gpus),
            _CpuSection(snap: snap, history: history),
            _MemorySection(snap: snap, history: history),
            _NetSection(snap: snap, history: history),
            if (snap.disks.isNotEmpty) _DiskSection(snap: snap),
            _ProcessSection(processes: snap.processes),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 头部

class _HostHeader extends StatelessWidget {
  const _HostHeader({required this.snap});
  final SystemSnapshot snap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.desktop_windows, size: 16, color: Colors.white38),
          const SizedBox(width: 6),
          Text('${snap.hostName} · ${snap.kernel}',
              style: GhostTheme.mono.copyWith(color: Colors.white38, fontSize: 11.5)),
          const Spacer(),
          Text('已运行 ${humanDuration(snap.uptimeSeconds)}',
              style: const TextStyle(color: Colors.white38, fontSize: 11.5)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- GPU

class _GpuSection extends StatelessWidget {
  const _GpuSection({required this.gpus});
  final List<GpuInfo> gpus;

  @override
  Widget build(BuildContext context) {
    return StatCard(
      title: gpus.length > 1 ? 'GPU（${gpus.length} 块）' : 'GPU',
      icon: Icons.memory,
      child: Column(
        children: [
          for (final g in gpus) _GpuRow(gpu: g),
        ],
      ),
    );
  }
}

class _GpuRow extends StatelessWidget {
  const _GpuRow({required this.gpu});
  final GpuInfo gpu;

  @override
  Widget build(BuildContext context) {
    final temp = gpu.temperature;
    final tempColor = temp == null
        ? Colors.white54
        : temp >= 85
            ? GhostTheme.danger
            : temp >= 70
                ? GhostTheme.warn
                : GhostTheme.accent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          DonutGauge(
            value: gpu.utilization?.toDouble(),
            maxValue: 100,
            label: 'GPU 占用',
            sublabel: gpu.powerWatts == null ? null : '${gpu.powerWatts!.toStringAsFixed(0)} W',
          ),
          const SizedBox(width: 14),
          DonutGauge(
            value: gpu.memoryPercent,
            maxValue: 100,
            label: '显存',
            sublabel: gpu.memoryUsedMB == null
                ? null
                : '${(gpu.memoryUsedMB! / 1024).toStringAsFixed(1)}G',
            color: GhostTheme.info,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(gpu.name.isEmpty ? 'GPU ${gpu.index}' : gpu.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.thermostat, size: 16, color: tempColor),
                    const SizedBox(width: 4),
                    Text(temp == null ? '--' : '$temp°C',
                        style: GhostTheme.mono.copyWith(color: tempColor, fontSize: 15)),
                  ],
                ),
                const SizedBox(height: 6),
                if (gpu.memoryUsedMB != null && gpu.memoryTotalMB != null)
                  Text(
                    '显存 ${gpu.memoryUsedMB} / ${gpu.memoryTotalMB} MB',
                    style: GhostTheme.mono.copyWith(color: Colors.white38, fontSize: 11),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- CPU

class _CpuSection extends StatelessWidget {
  const _CpuSection({required this.snap, required this.history});
  final SystemSnapshot snap;
  final List<SystemSnapshot> history;

  @override
  Widget build(BuildContext context) {
    final load = snap.loadAvg;
    return StatCard(
      title: 'CPU',
      icon: Icons.speed,
      trailing: Text(
        '${snap.cpuUsage.toStringAsFixed(1)}%',
        style: GhostTheme.mono.copyWith(fontSize: 16, color: GhostTheme.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MiniLineChart(
            values: history.map((e) => e.cpuUsage).toList(),
            color: GhostTheme.accent,
            maxY: 100,
          ),
          const SizedBox(height: 8),
          if (load.length == 3)
            Text(
              '负载  ${load[0].toStringAsFixed(2)} / ${load[1].toStringAsFixed(2)} / ${load[2].toStringAsFixed(2)}',
              style: GhostTheme.mono.copyWith(color: Colors.white38, fontSize: 11.5),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 内存

class _MemorySection extends StatelessWidget {
  const _MemorySection({required this.snap, required this.history});
  final SystemSnapshot snap;
  final List<SystemSnapshot> history;

  @override
  Widget build(BuildContext context) {
    final m = snap.memory;
    return StatCard(
      title: '内存',
      icon: Icons.sd_card,
      trailing: Text(
        '${humanBytes(m.usedBytes)} / ${humanBytes(m.totalBytes)}',
        style: GhostTheme.mono.copyWith(fontSize: 12, color: Colors.white70),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UsageBar(percent: m.usedPercent),
          const SizedBox(height: 10),
          MiniLineChart(
            values: history
                .map((e) => e.memory.totalBytes <= 0
                    ? 0.0
                    : e.memory.usedBytes / e.memory.totalBytes * 100)
                .toList(),
            color: GhostTheme.info,
            maxY: 100,
            height: 70,
          ),
          if (m.swapTotalBytes > 0) ...[
            const SizedBox(height: 8),
            Text(
              'Swap  ${humanBytes(m.swapUsedBytes)} / ${humanBytes(m.swapTotalBytes)}',
              style: GhostTheme.mono.copyWith(color: Colors.white38, fontSize: 11.5),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 网络

class _NetSection extends StatelessWidget {
  const _NetSection({required this.snap, required this.history});
  final SystemSnapshot snap;
  final List<SystemSnapshot> history;

  @override
  Widget build(BuildContext context) {
    return StatCard(
      title: '网络（不含 lo）',
      icon: Icons.swap_vert,
      trailing: Row(
        children: [
          const Icon(Icons.arrow_downward, size: 13, color: GhostTheme.accent),
          Text(' ${humanRate(snap.netRxBytesPerSec)}   ',
              style: GhostTheme.mono.copyWith(fontSize: 11.5, color: Colors.white70)),
          const Icon(Icons.arrow_upward, size: 13, color: GhostTheme.info),
          Text(' ${humanRate(snap.netTxBytesPerSec)}',
              style: GhostTheme.mono.copyWith(fontSize: 11.5, color: Colors.white70)),
        ],
      ),
      child: MiniLineChart(
        values: history.map((e) => e.netRxBytesPerSec + e.netTxBytesPerSec).toList(),
        color: GhostTheme.accent,
        height: 60,
      ),
    );
  }
}

// ---------------------------------------------------------------- 磁盘

class _DiskSection extends StatelessWidget {
  const _DiskSection({required this.snap});
  final SystemSnapshot snap;

  @override
  Widget build(BuildContext context) {
    return StatCard(
      title: '磁盘',
      icon: Icons.storage,
      child: Column(
        children: [
          for (final d in snap.disks)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(d.mount,
                            overflow: TextOverflow.ellipsis,
                            style: GhostTheme.mono.copyWith(fontSize: 11.5, color: Colors.white70)),
                      ),
                      Text(
                        '${humanBytes(d.usedBytes)} / ${humanBytes(d.totalBytes)}（${d.usedPercent.toStringAsFixed(0)}%）',
                        style: GhostTheme.mono.copyWith(fontSize: 11, color: Colors.white38),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  UsageBar(percent: d.usedPercent, height: 6),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 进程

class _ProcessSection extends StatelessWidget {
  const _ProcessSection({required this.processes});
  final List<ProcessInfo> processes;

  @override
  Widget build(BuildContext context) {
    return StatCard(
      title: 'Top 进程（按 CPU）',
      icon: Icons.list_alt,
      trailing: Row(
        children: [
          Container(width: 8, height: 8, decoration: const BoxDecoration(color: GhostTheme.warn, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          const Text('= 渲染/编译/训练任务', style: TextStyle(fontSize: 10.5, color: Colors.white38)),
        ],
      ),
      child: Column(
        children: [
          for (final p in processes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 46,
                    child: Text(
                      '${p.cpuPercent.toStringAsFixed(1)}%',
                      style: GhostTheme.mono.copyWith(
                        fontSize: 11.5,
                        color: p.isHeavyTask ? GhostTheme.warn : Colors.white70,
                        fontWeight: p.isHeavyTask ? FontWeight.w700 : FontWeight.normal,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${p.memPercent.toStringAsFixed(1)}%',
                      style: GhostTheme.mono.copyWith(fontSize: 11.5, color: Colors.white38),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      p.command,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GhostTheme.mono.copyWith(
                        fontSize: 11.5,
                        color: p.isHeavyTask ? GhostTheme.warn : Colors.white54,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 占位

class _NotConnectedPlaceholder extends StatelessWidget {
  const _NotConnectedPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 48, color: Colors.white12),
          SizedBox(height: 12),
          Text('未连接到工作站', style: TextStyle(color: Colors.white38)),
          SizedBox(height: 4),
          Text('请先在服务器列表中建立 SSH 连接',
              style: TextStyle(color: Colors.white24, fontSize: 12)),
        ],
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 80),
        const Icon(Icons.error_outline, size: 40, color: GhostTheme.warn),
        const SizedBox(height: 12),
        Center(
          child: Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 12.5)),
        ),
      ],
    );
  }
}
