import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/server_config.dart';
import 'ssh_service.dart';

/// SFTP 目录项
class SftpEntry {
  const SftpEntry({
    required this.name,
    required this.path,
    required this.size,
    required this.isDirectory,
    this.modified,
  });

  final String name;
  final String path;
  final int size;
  final bool isDirectory;
  final DateTime? modified;
}

/// 隐形文件传输（方案文档 §6.3.4）。
///
/// 两类能力：
/// 1. **SFTP 浏览/上传/下载**：手机 ↔ 工作站的小文件管理（dartssh2 内置 SFTP）；
/// 2. **远程 rsync 任务**：工作站 ↔ NAS/其他目录的大文件同步，命令自动包裹
///    `nice -n 19 ionice -c3 rsync --bwlimit=NM`，通过任务舱提交（跑在 tmux 里，
///    断线不中断，限速不抢渲染带宽）。
class TransferService {
  TransferService(this._ssh);

  final SSHService _ssh;

  Future<SftpClient> get _sftp => _ssh.sftp();

  /// SFTP 默认根目录即用户家目录
  Future<String> home() async {
    final sftp = await _sftp;
    return sftp.absolute('.');
  }

  Future<List<SftpEntry>> list(String dir) async {
    final sftp = await _sftp;
    final names = await sftp.listdir(dir);
    final entries = <SftpEntry>[];
    for (final n in names) {
      final name = n.filename;
      if (name == '.' || name == '..') continue;
      final attr = n.attr;
      final mtime = attr.modifyTime;
      entries.add(SftpEntry(
        name: name,
        path: _join(dir, name),
        size: attr.size ?? 0,
        isDirectory: attr.type == SftpFileType.directory,
        modified: mtime == null || mtime <= 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(mtime * 1000),
      ));
    }
    // 目录在前，各自按名称排序
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// 下载远端文件到手机本地，回调进度 (已接收字节, 总字节)。
  Future<void> download(
    String remotePath,
    String localPath, {
    void Function(int received, int total)? onProgress,
  }) async {
    final sftp = await _sftp;
    final attr = await sftp.stat(remotePath);
    final total = attr.size ?? 0;
    final sink = File(localPath).openWrite();

    await sftp.download(
      remotePath,
      sink,
      closeDestination: true,
      onProgress: (bytesRead) => onProgress?.call(bytesRead, total),
    );
    onProgress?.call(total, total);
  }

  /// 上传手机本地文件到远端目录。
  Future<void> upload(
    String localPath,
    String remotePath, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final sftp = await _sftp;
    final local = File(localPath);
    final total = await local.length();

    final remote = await sftp.open(
      remotePath,
      mode: SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    try {
      final writer = remote.write(
        local.openRead().map((chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk)),
        onProgress: (sent) => onProgress?.call(sent, total),
      );
      await writer.done;
    } finally {
      await remote.close();
    }
    onProgress?.call(total, total);
  }

  /// 构造隐形 rsync 命令（交给任务舱在 tmux 中限速运行）。
  ///
  /// stealth=true: `rsync -a --partial --info=progress2 --bwlimit=8M src dst`
  ///   （任务舱外层还会包 nice -n 19 + ionice -c3 + systemd-run）
  /// stealth=false: 去掉 bwlimit 全速传输（文档 §6.3.4 无感模式开关）
  static String buildRsyncCommand({
    required String source,
    required String dest,
    required ServerConfig config,
    bool? stealthOverride,
  }) {
    final stealth = stealthOverride ?? config.stealthMode;
    final limit = stealth ? ' --bwlimit=${config.bandwidthLimitMBs}M' : '';
    final src = _shellQuote(source);
    final dst = _shellQuote(dest);
    return 'rsync -a --partial --info=progress2$limit $src $dst';
  }

  static String _shellQuote(String path) {
    final escaped = path.replaceAll("'", "'\\''");
    return "'$escaped'";
  }

  static String _join(String dir, String name) {
    if (dir.endsWith('/')) return '$dir$name';
    return '$dir/$name';
  }
}
