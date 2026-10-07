import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../providers/app_providers.dart';
import '../services/transfer_service.dart';
import '../theme.dart';
import '../utils/format.dart';

/// 隐形文件传输（方案文档 §6.3.4）。
///
/// - SFTP 图形化浏览 / 下载到手机 / 从手机上传；
/// - 「隐形 rsync」：把 工作站↔NAS 的大文件同步作为无感任务提交，
///   自动包裹 nice -n 19 + ionice -c3 + rsync --bwlimit=NM，跑在 tmux 中。
class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key});

  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  String? _cwd; // null = 尚未初始化（等待 home）
  List<SftpEntry> _entries = [];
  bool _loading = false;
  String? _error;

  static const _videoExts = ['.mp4', '.mkv', '.mov', '.avi', '.webm'];
  static const _imageExts = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg'];
  static const _archiveExts = ['.zip', '.tar', '.gz', '.xz', '.7z', '.rar'];
  static const _textExts = ['.log', '.txt', '.md', '.json', '.yaml', '.yml', '.conf'];
  static const _codeExts = ['.py', '.sh', '.dart', '.c', '.cpp', '.h', '.rs', '.go', '.js'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  TransferService? get _transfer => ref.read(transferServiceProvider);

  Future<void> _init() async {
    final t = _transfer;
    if (t == null) {
      if (mounted) setState(() => _error = '未连接到工作站');
      return;
    }
    try {
      final home = await t.home();
      await _navigate(home);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _navigate(String path) async {
    final t = _transfer;
    if (t == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await t.list(path);
      if (!mounted) return;
      setState(() {
        _cwd = path;
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '无法打开 $path：$e';
        });
      }
    }
  }

  void _goUp() {
    final cwd = _cwd;
    if (cwd == null || cwd == '/') return;
    final idx = cwd.lastIndexOf('/');
    final parent = idx <= 0 ? '/' : cwd.substring(0, idx);
    _navigate(parent);
  }

  // ---------------------------------------------------------------- 下载

  Future<void> _download(SftpEntry entry) async {
    final t = _transfer;
    if (t == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final ghostDir = Directory('${dir.path}/GhostPanel');
    if (!ghostDir.existsSync()) ghostDir.createSync(recursive: true);
    final localPath = '${ghostDir.path}/${entry.name}';

    final progress = ValueNotifier<_Progress>(const _Progress(0, 0));
    if (!mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProgressDialog(title: '下载 ${entry.name}', progress: progress),
    );

    try {
      await t.download(entry.path, localPath, onProgress: (r, total) {
        progress.value = _Progress(r, total);
      });
      if (!mounted) return;
      Navigator.pop(context); // 关闭进度框
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已下载到手机：$localPath'),
          action: SnackBarAction(
            label: '复制路径',
            onPressed: () => Clipboard.setData(ClipboardData(text: localPath)),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败：$e'), backgroundColor: GhostTheme.danger),
      );
    }
  }

  // ---------------------------------------------------------------- 上传

  Future<void> _upload() async {
    final t = _transfer;
    final cwd = _cwd;
    if (t == null || cwd == null) return;

    final result = await FilePicker.platform.pickFiles(allowMultiple: false);
    final path = result?.files.single.path;
    if (path == null) return;
    final name = result!.files.single.name;
    final remotePath = cwd.endsWith('/') ? '$cwd$name' : '$cwd/$name';

    final progress = ValueNotifier<_Progress>(const _Progress(0, 0));
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProgressDialog(title: '上传 $name', progress: progress),
    );

    try {
      await t.upload(path, remotePath, onProgress: (s, total) {
        progress.value = _Progress(s, total);
      });
      if (!mounted) return;
      Navigator.pop(context);
      _navigate(cwd); // 刷新列表
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('上传失败：$e'), backgroundColor: GhostTheme.danger),
      );
    }
  }

  // ---------------------------------------------------------------- 隐形 rsync

  Future<void> _showRsyncDialog() async {
    final server = ref.read(connectionProvider).server;
    if (server == null) return;
    // 在任何 await / pop 之前捕获 messenger，避免使用已卸载的对话框 context
    final messenger = ScaffoldMessenger.of(context);
    final srcCtrl = TextEditingController(text: _cwd == null ? '' : '$_cwd/');
    final dstCtrl = TextEditingController(text: '/mnt/nas/');
    var stealth = server.stealthMode;

    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: const Text('隐形 rsync 传输'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: srcCtrl,
                style: GhostTheme.mono,
                decoration: const InputDecoration(labelText: '源目录（工作站路径）'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: dstCtrl,
                style: GhostTheme.mono,
                decoration: const InputDecoration(labelText: '目标目录（如 /mnt/nas/backup/）'),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('无感模式', style: TextStyle(fontSize: 13.5)),
                subtitle: Text(
                  stealth
                      ? '限速 ${server.bandwidthLimitMBs}MB/s + nice 19 + ionice idle'
                      : '全速传输（会占用带宽/IO，可能影响渲染）',
                  style: TextStyle(
                    fontSize: 11,
                    color: stealth ? Colors.white38 : GhostTheme.warn,
                  ),
                ),
                value: stealth,
                onChanged: (v) => setLocal(() => stealth = v),
              ),
              const SizedBox(height: 4),
              Text(
                '任务将提交到任务舱，在 tmux 中运行 —— 断线不中断，进度可在任务舱查看日志。',
                style: GhostTheme.mono.copyWith(fontSize: 10.5, color: Colors.white38),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                final src = srcCtrl.text.trim();
                final dst = dstCtrl.text.trim();
                if (src.isEmpty || dst.isEmpty) return;
                Navigator.pop(c);
                final command = TransferService.buildRsyncCommand(
                  source: src,
                  dest: dst,
                  config: server,
                  stealthOverride: stealth,
                );
                try {
                  await ref.read(tasksProvider.notifier).submit(command: command);
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text('👻 rsync 任务已提交（${stealth ? '限速' : '全速'}），到任务舱查看进度'),
                      backgroundColor: const Color(0xCC143D2B),
                    ),
                  );
                } catch (e) {
                  messenger.showSnackBar(
                    SnackBar(content: Text('提交失败：$e'), backgroundColor: GhostTheme.danger),
                  );
                }
              },
              child: const Text('提交到任务舱'),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);
    if (!conn.isConnected && _cwd == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_off_outlined, size: 44, color: Colors.white12),
            const SizedBox(height: 12),
            Text(_error ?? '未连接到工作站',
                style: const TextStyle(color: Colors.white38, fontSize: 13)),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _init,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _miniFab(Icons.move_to_inbox_outlined, '隐形 rsync', _showRsyncDialog),
          const SizedBox(height: 10),
          _miniFab(Icons.upload_outlined, '上传到此处', _upload),
        ],
      ),
      body: Column(
        children: [
          _PathBar(
            path: _cwd ?? '...',
            loading: _loading,
            onUp: _goUp,
            onRefresh: () => _cwd == null ? _init() : _navigate(_cwd!),
            onEdit: () async {
              final ctrl = TextEditingController(text: _cwd);
              final input = await showDialog<String>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('跳转到路径'),
                  content: TextField(
                    controller: ctrl,
                    autofocus: true,
                    style: GhostTheme.mono,
                    decoration: const InputDecoration(hintText: '/home/user/...'),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
                    FilledButton(
                      onPressed: () => Navigator.pop(c, ctrl.text.trim()),
                      child: const Text('跳转'),
                    ),
                  ],
                ),
              );
              if (input != null && input.isNotEmpty) _navigate(input);
            },
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(_error!, style: const TextStyle(color: GhostTheme.warn, fontSize: 12)),
            ),
          Expanded(
            child: _loading && _entries.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: () async => _cwd == null ? _init() : _navigate(_cwd!),
                    child: ListView.separated(
                      padding: const EdgeInsets.only(bottom: 120),
                      itemCount: _entries.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 52, endIndent: 16),
                      itemBuilder: (_, i) => _entryTile(_entries[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _miniFab(IconData icon, String tooltip, VoidCallback onPressed) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: const Color(0xEE161B22),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(tooltip, style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 44,
          height: 44,
          child: FloatingActionButton.small(
            heroTag: tooltip,
            onPressed: onPressed,
            backgroundColor: const Color(0xFF1F2630),
            foregroundColor: GhostTheme.accent,
            child: Icon(icon, size: 20),
          ),
        ),
      ],
    );
  }

  static final _dateFmt = DateFormat('yyyy-MM-dd HH:mm');

  Widget _entryTile(SftpEntry entry) {
    return ListTile(
      dense: true,
      leading: Icon(
        entry.isDirectory ? Icons.folder : _fileIcon(entry.name),
        color: entry.isDirectory ? GhostTheme.warn.withValues(alpha: 0.8) : Colors.white30,
        size: 24,
      ),
      title: Text(entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13.5)),
      subtitle: Text(
        entry.isDirectory
            ? '目录'
            : humanBytes(entry.size) +
                (entry.modified == null
                    ? ''
                    : '  ·  ${_dateFmt.format(entry.modified!.toLocal())}'),
        style: GhostTheme.mono.copyWith(fontSize: 10.5, color: Colors.white30),
      ),
      onTap: entry.isDirectory ? () => _navigate(entry.path) : () => _fileActions(entry),
    );
  }

  IconData _fileIcon(String name) {
    final lower = name.toLowerCase();
    if (_endsWithAny(lower, _videoExts)) return Icons.movie_outlined;
    if (_endsWithAny(lower, _imageExts)) return Icons.image_outlined;
    if (_endsWithAny(lower, _archiveExts)) return Icons.folder_zip_outlined;
    if (_endsWithAny(lower, _textExts)) return Icons.description_outlined;
    if (_endsWithAny(lower, _codeExts)) return Icons.code;
    return Icons.insert_drive_file_outlined;
  }

  static bool _endsWithAny(String name, List<String> exts) {
    for (final e in exts) {
      if (name.endsWith(e)) return true;
    }
    return false;
  }

  void _fileActions(SftpEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GhostTheme.mono.copyWith(color: Colors.white70)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('下载到手机'),
              subtitle: Text(humanBytes(entry.size), style: GhostTheme.mono.copyWith(fontSize: 11)),
              onTap: () {
                Navigator.pop(c);
                _download(entry);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('复制远端路径'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: entry.path));
                Navigator.pop(c);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制路径')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.move_to_inbox_outlined),
              title: const Text('发起隐形 rsync 传输'),
              onTap: () {
                Navigator.pop(c);
                _showRsyncDialog();
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 小组件

class _Progress {
  const _Progress(this.done, this.total);
  final int done;
  final int total;
}

class _PathBar extends StatelessWidget {
  const _PathBar({
    required this.path,
    required this.loading,
    required this.onUp,
    required this.onRefresh,
    required this.onEdit,
  });

  final String path;
  final bool loading;
  final VoidCallback onUp;
  final VoidCallback onRefresh;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      color: const Color(0xFF10151C),
      child: Row(
        children: [
          IconButton(
            tooltip: '上级目录',
            onPressed: onUp,
            icon: const Icon(Icons.arrow_upward, size: 18),
            color: Colors.white54,
          ),
          Expanded(
            child: InkWell(
              onTap: onEdit,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Text(
                  path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GhostTheme.mono.copyWith(color: GhostTheme.accent, fontSize: 12),
                ),
              ),
            ),
          ),
          if (loading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            IconButton(
              tooltip: '刷新',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh, size: 18),
              color: Colors.white54,
            ),
        ],
      ),
    );
  }
}

class _ProgressDialog extends StatelessWidget {
  const _ProgressDialog({required this.title, required this.progress});

  final String title;
  final ValueNotifier<_Progress> progress;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
      content: ValueListenableBuilder<_Progress>(
        valueListenable: progress,
        builder: (_, p, __) {
          final ratio = p.total > 0 ? (p.done / p.total).clamp(0.0, 1.0) : null;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: ratio, minHeight: 6),
              const SizedBox(height: 12),
              Text(
                ratio == null
                    ? humanBytes(p.done)
                    : '${humanBytes(p.done)} / ${humanBytes(p.total)}（${(ratio * 100).toStringAsFixed(1)}%）',
                style: GhostTheme.mono.copyWith(fontSize: 11.5, color: Colors.white54),
              ),
            ],
          );
        },
      ),
    );
  }
}
