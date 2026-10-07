import 'package:flutter_test/flutter_test.dart';
import 'package:ghostpanel/models/server_config.dart';
import 'package:ghostpanel/services/monitor_service.dart';
import 'package:ghostpanel/services/ssh_service.dart';
import 'package:ghostpanel/services/task_runner.dart';
import 'package:ghostpanel/services/transfer_service.dart';

/// 监控数据解析测试（§6.3.1 数据源格式）+ rsync 命令构造（§6.3.4）。
void main() {
  // 模拟 MonitorService.probeCommand 在真实 Ubuntu 上的输出
  const sample = '''
@@CPU@@
top - 14:23:01 up 3 days,  4:12,  2 users,  load average: 2.31, 1.98, 1.75
Tasks: 312 total,   1 running, 311 sleeping,   0 stopped,   0 zombie
%Cpu(s): 12.3 us,  3.2 sy,  0.0 ni, 83.5 id,  0.8 wa,  0.0 hi,  0.2 si,  0.0 st
MiB Mem :  31942.6 total,   2103.4 free,  18234.7 used,  11604.5 buff/cache
@@LOAD@@
2.31 1.98 1.75 3/1234 56789
@@MEM@@
              total        used        free      shared  buff/cache   available
Mem:     33493241856 19117244416  2205941760   524288000 12170055680 13499891712
Swap:     2147483648           0  2147483648
@@GPU@@
0, NVIDIA GeForce RTX 4090, 97, 21345, 24564, 71, 312.45
@@PROC@@
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         123  0.0  0.1 169412 13452 ?        Ssl  Sep25   0:12 /usr/sbin/dockerd
alice       4521 87.3 12.4 98231234 4123456 ?    Rl   13:02  72:31 /usr/bin/blender --background scene.blend -o //render/frame_ -f 120
alice       4899  9.1  2.2 1234567 234567 pts/3  Sl+  13:55   2:14 ffmpeg -i in.mp4 -c:v libx264 out.mp4
bob         5001  1.0  0.5  234567  34567 ?        S    14:01   0:03 /usr/bin/gnome-shell
@@DISK@@
Filesystem         1B-blocks        Used   Available Use% Mounted on
/dev/nvme0n1p2 1000203088896 412345678900 536838148096  44% /
/dev/sda1       4000676847616 2100344567808 1696178409472  55% /mnt/nas
@@NET@@
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 12345678    9876    0    0    0     0          0         0 12345678    9876    0    0    0     0       0          0
enp5s0: 98765432100  654321    0    0    0     0          0         0 12345678900  123456    0    0    0     0       0          0
@@UP@@
267123.45 0.123456
@@HOST@@
renderstation
6.8.0-45-generic
@@END@@
''';

  late MonitorService monitor;

  setUp(() {
    // 仅提供构造依赖，parse() 不触网
    monitor = MonitorService(
      SSHService(ServerConfig(id: 't', name: 't', host: '127.0.0.1', username: 'u')),
    );
  });

  test('CPU 使用率 = 100 - idle', () {
    final snap = monitor.parse(sample);
    expect(snap.cpuUsage, closeTo(16.5, 0.01));
  });

  test('负载解析', () {
    final snap = monitor.parse(sample);
    expect(snap.loadAvg, [2.31, 1.98, 1.75]);
  });

  test('内存解析（available 为最后一列）', () {
    final snap = monitor.parse(sample);
    expect(snap.memory.totalBytes, 33493241856);
    expect(snap.memory.availableBytes, 13499891712);
    expect(snap.memory.usedBytes, 33493241856 - 13499891712);
    expect(snap.memory.usedPercent, greaterThan(50));
    expect(snap.memory.swapTotalBytes, 2147483648);
    expect(snap.memory.swapUsedBytes, 0);
  });

  test('GPU CSV 解析', () {
    final snap = monitor.parse(sample);
    expect(snap.gpus, hasLength(1));
    final g = snap.gpus.first;
    expect(g.index, 0);
    expect(g.name, 'NVIDIA GeForce RTX 4090');
    expect(g.utilization, 97);
    expect(g.memoryUsedMB, 21345);
    expect(g.memoryTotalMB, 24564);
    expect(g.temperature, 71);
    expect(g.powerWatts, closeTo(312.45, 0.001));
    expect(g.memoryPercent, greaterThan(85));
  });

  test('无 GPU 时优雅降级', () {
    final snap = monitor.parse(sample.replaceAll('0, NVIDIA GeForce RTX 4090, 97, 21345, 24564, 71, 312.45', 'NONE'));
    expect(snap.gpus, isEmpty);
  });

  test('进程解析 + 渲染进程高亮', () {
    final snap = monitor.parse(sample);
    expect(snap.processes, hasLength(4));
    final blender = snap.processes.firstWhere((p) => p.command.contains('blender'));
    expect(blender.isHeavyTask, isTrue);
    expect(blender.cpuPercent, 87.3);
    final ffmpeg = snap.processes.firstWhere((p) => p.command.contains('ffmpeg'));
    expect(ffmpeg.isHeavyTask, isTrue);
    final shell = snap.processes.firstWhere((p) => p.command.contains('gnome-shell'));
    expect(shell.isHeavyTask, isFalse);
  });

  test('磁盘解析（跳过表头）', () {
    final snap = monitor.parse(sample);
    expect(snap.disks, hasLength(2));
    expect(snap.disks[0].mount, '/');
    // 注意：实现按 used/total 计算（41.2%），与 df 的 Use% 列（44%，扣除 root 保留块）略有差异
    expect(snap.disks[0].usedPercent, closeTo(41.2, 0.5));
    expect(snap.disks[1].mount, '/mnt/nas');
  });

  test('网络排除 lo；首次采样速率为 0', () {
    final snap = monitor.parse(sample);
    expect(snap.netRxBytesPerSec, 0);
    expect(snap.netTxBytesPerSec, 0);
  });

  test('主机信息与运行时长', () {
    final snap = monitor.parse(sample);
    expect(snap.hostName, 'renderstation');
    expect(snap.kernel, '6.8.0-45-generic');
    expect(snap.uptimeSeconds, closeTo(267123.45, 0.01));
  });

  group('TransferService.buildRsyncCommand（§6.3.4）', () {
    ServerConfig cfg({bool stealth = true, int bw = 8}) => ServerConfig(
          id: 's',
          name: 's',
          host: 'h',
          username: 'u',
          stealthMode: stealth,
          bandwidthLimitMBs: bw,
        );

    test('无感模式：带 bwlimit', () {
      final cmd = TransferService.buildRsyncCommand(
        source: '/home/alice/data/',
        dest: '/mnt/nas/backup/',
        config: cfg(),
      );
      expect(cmd, contains('--bwlimit=8M'));
      expect(cmd, startsWith('rsync -a --partial --info=progress2'));
      expect(cmd, contains("'/home/alice/data/'"));
    });

    test('全速模式：无 bwlimit', () {
      final cmd = TransferService.buildRsyncCommand(
        source: '/a/',
        dest: '/b/',
        config: cfg(),
        stealthOverride: false,
      );
      expect(cmd, isNot(contains('--bwlimit')));
    });

    test('路径中的单引号被安全转义', () {
      final cmd = TransferService.buildRsyncCommand(
        source: "/home/alice/it's data/",
        dest: '/mnt/nas/',
        config: cfg(),
      );
      expect(cmd, contains(r"""'/home/alice/it'\''s data/'"""));
    });
  });

  group('TaskRunner 会话命名约定', () {
    test('会话前缀符合 tmux 命名限制', () {
      expect(TaskRunner.sessionPrefix, 'ghost_task_');
      expect(TaskRunner.sessionPrefix, isNot(contains('.')));
      expect(TaskRunner.sessionPrefix, isNot(contains(':')));
    });
  });
}
