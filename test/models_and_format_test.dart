import 'package:flutter_test/flutter_test.dart';
import 'package:ghostpanel/models/server_config.dart';
import 'package:ghostpanel/models/task_info.dart';
import 'package:ghostpanel/utils/format.dart';

void main() {
  group('humanBytes', () {
    test('基础单位', () {
      expect(humanBytes(0), '0 B');
      expect(humanBytes(512), '512 B');
      expect(humanBytes(1536), '1.5 KB');
      expect(humanBytes(1048576), '1.0 MB');
      expect(humanBytes(1073741824), '1.0 GB');
    });
  });

  group('humanDuration', () {
    test('各量级', () {
      expect(humanDuration(45), '45秒');
      expect(humanDuration(125), '2分5秒');
      expect(humanDuration(7500), '2小时5分');
      expect(humanDuration(267123), '3天2小时');
    });
  });

  group('ServerConfig JSON 往返', () {
    test('序列化/反序列化保持一致', () {
      final cfg = ServerConfig(
        id: 'srv-1',
        name: '渲染工作站',
        host: '192.168.1.50',
        port: 2222,
        username: 'alice',
        authType: AuthType.privateKey,
        privateKeyPem: '-----BEGIN OPENSSH PRIVATE KEY-----\nXXX\n',
        passphrase: 'pp',
        stealthMode: true,
        bandwidthLimitMBs: 12,
        defaultCpuQuota: 40,
        defaultMemoryMax: '8G',
        guardCommands: false,
      );
      final back = ServerConfig.fromJson(cfg.toJson());
      expect(back.id, cfg.id);
      expect(back.name, cfg.name);
      expect(back.port, 2222);
      expect(back.authType, AuthType.privateKey);
      expect(back.privateKeyPem, cfg.privateKeyPem);
      expect(back.bandwidthLimitMBs, 12);
      expect(back.defaultCpuQuota, 40);
      expect(back.defaultMemoryMax, '8G');
      expect(back.guardCommands, isFalse);
    });

    test('copyWith 局部覆盖', () {
      final cfg = ServerConfig(id: 'a', name: 'n', host: 'h', username: 'u');
      final c2 = cfg.copyWith(bandwidthLimitMBs: 20, stealthMode: false);
      expect(c2.bandwidthLimitMBs, 20);
      expect(c2.stealthMode, isFalse);
      expect(c2.host, 'h');
      expect(c2.id, cfg.id);
    });
  });

  group('GhostTask JSON 往返', () {
    test('状态与退出码保留', () {
      final t = GhostTask(
        id: 'ghost_task_123',
        serverId: 'srv-1',
        command: 'make -j4',
        logPath: '/tmp/ghost_task_123.log',
        scriptPath: '/tmp/ghost_task_123.sh',
        cpuQuota: 30,
        memoryMax: '4G',
        lowIo: true,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        status: TaskStatus.failed,
        exitCode: 2,
      );
      final back = GhostTask.fromJson(t.toJson());
      expect(back.id, t.id);
      expect(back.status, TaskStatus.failed);
      expect(back.exitCode, 2);
      expect(back.createdAt, t.createdAt);
      expect(back.lowIo, isTrue);
    });

    test('未知状态回退为 unknown', () {
      final t = GhostTask.fromJson({'id': 'x', 'status': 'nonexistent'});
      expect(t.status, TaskStatus.unknown);
    });
  });
}
