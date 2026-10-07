import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/task_info.dart';
import '../providers/app_providers.dart';
import '../services/command_guard.dart';
import '../theme.dart';

/// 无感任务舱（方案文档 §6.3.2）。
///
/// 用户输入命令 → 自动包裹 tmux + systemd-run/nice/ionice → 提交；
/// 列表实时反映远端 tmux 会话状态；可随时看日志尾部或终止任务。
class TasksScreen extends ConsumerWidget {
  const TasksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    if (!conn.isConnected) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.rocket_launch_outlined, size: 44, color: Colors.white12),
            SizedBox(height: 12),
            Text('连接工作站后可提交无感任务', style: TextStyle(color: Colors.white38, fontSize: 13)),
          ],
        ),
      );
    }

    final tasksAsync = ref.watch(tasksProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: GhostTheme.accent,
        foregroundColor: Colors.black,
        onPressed: () => _showSubmitDialog(context, ref),
        icon: const Icon(Icons.add_task),
        label: const Text('提交无感任务'),
      ),
      body: tasksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e', style: const TextStyle(color: Colors.white38))),
        data: (tasks) {
          if (tasks.isEmpty) {
            return const _EmptyTasks();
          }
          return RefreshIndicator(
            onRefresh: () => ref.read(tasksProvider.notifier).refreshStatuses(),
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: 96, top: 8),
              itemCount: tasks.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
              itemBuilder: (_, i) => _TaskTile(task: tasks[i]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showSubmitDialog(BuildContext context, WidgetRef ref) async {
    final server = ref.read(connectionProvider).server!;
    final commandCtrl = TextEditingController();
    var cpuQuota = server.defaultCpuQuota.toDouble();
    var memoryMax = server.defaultMemoryMax;
    var lowIo = true;
    var submitting = false;

    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: const Row(
            children: [
              Text('👻', style: TextStyle(fontSize: 18)),
              SizedBox(width: 8),
              Text('提交无感任务'),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: commandCtrl,
                    maxLines: 3,
                    autofocus: true,
                    style: GhostTheme.mono,
                    decoration: const InputDecoration(
                      labelText: '命令 *',
                      hintText: 'make -j4\nrsync -av ~/data/ /mnt/nas/\nffmpeg -i in.mp4 out.mp4',
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text('CPU 封顶：${cpuQuota.round()}%（systemd-run CPUQuota）',
                      style: const TextStyle(fontSize: 12.5, color: Colors.white70)),
                  Slider(
                    value: cpuQuota,
                    min: 5,
                    max: 100,
                    divisions: 19,
                    label: '${cpuQuota.round()}%',
                    onChanged: (v) => setLocal(() => cpuQuota = v),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: memoryMax,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '内存封顶（MemoryMax）'),
                    items: const [
                      DropdownMenuItem(value: '1G', child: Text('1G')),
                      DropdownMenuItem(value: '2G', child: Text('2G')),
                      DropdownMenuItem(value: '4G', child: Text('4G')),
                      DropdownMenuItem(value: '8G', child: Text('8G')),
                      DropdownMenuItem(value: 'infinity', child: Text('不限制（不建议）')),
                    ],
                    onChanged: (v) => setLocal(() => memoryMax = v ?? '4G'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('IO 空闲优先级（ionice -c3）', style: TextStyle(fontSize: 13)),
                    subtitle: const Text('磁盘空闲时才读写，不与渲染抢 IO', style: TextStyle(fontSize: 11)),
                    value: lowIo,
                    onChanged: (v) => setLocal(() => lowIo = v ?? true),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black38,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '将包裹为：tmux + systemd-run(CPU ${cpuQuota.round()}% / Mem $memoryMax)'
                      ' + nice -n 19${lowIo ? ' + ionice -c3' : ''}\n'
                      '断线不中断，桌面毫无察觉。',
                      style: GhostTheme.mono.copyWith(fontSize: 10.5, color: Colors.white38),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: GhostTheme.accent,
                foregroundColor: Colors.black,
              ),
              onPressed: submitting
                  ? null
                  : () async {
                      final command = commandCtrl.text.trim();
                      if (command.isEmpty) return;

                      // 在任何 await 之前捕获 messenger，避免跨异步间隙使用 context
                      final messenger = ScaffoldMessenger.of(context);

                      // 危险命令拦截（§6.3.3）
                      final verdict = CommandGuard.check(command);
                      if (verdict.isDanger) {
                        final force = await showDialog<bool>(
                          context: c,
                          builder: (c2) => AlertDialog(
                            icon: const Icon(Icons.gpp_bad, color: GhostTheme.danger),
                            title: Text('拦截：${verdict.reason}'),
                            content: Text(verdict.advice),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
                              TextButton(
                                onPressed: () => Navigator.pop(c2, true),
                                child: const Text('仍要执行', style: TextStyle(color: GhostTheme.danger)),
                              ),
                            ],
                          ),
                        );
                        if (force != true) return;
                      }
                      if (verdict.isNotice) {
                        messenger.showSnackBar(
                          SnackBar(content: Text('⚠️ ${verdict.reason}：${verdict.advice}')),
                        );
                      }

                      setLocal(() => submitting = true);
                      try {
                        await ref.read(tasksProvider.notifier).submit(
                              command: command,
                              cpuQuota: cpuQuota.round(),
                              memoryMax: memoryMax,
                              lowIo: lowIo,
                            );
                        if (c.mounted) Navigator.pop(c);
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('👻 任务已静默提交（tmux 会话保活）'),
                            backgroundColor: Color(0xCC143D2B),
                          ),
                        );
                      } catch (e) {
                        setLocal(() => submitting = false);
                        messenger.showSnackBar(
                          SnackBar(content: Text('提交失败：$e'), backgroundColor: GhostTheme.danger),
                        );
                      }
                    },
              icon: submitting
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: const Text('提交'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 任务条目

class _TaskTile extends ConsumerWidget {
  const _TaskTile({required this.task});

  final GhostTask task;

  static final _timeFmt = DateFormat('MM-dd HH:mm');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (statusColor, statusIcon) = switch (task.status) {
      TaskStatus.running => (GhostTheme.accent, Icons.play_circle),
      TaskStatus.stopped => (Colors.white38, Icons.stop_circle_outlined),
      TaskStatus.failed => (GhostTheme.danger, Icons.error_outline),
      TaskStatus.unknown => (GhostTheme.warn, Icons.help_outline),
    };

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(statusIcon, color: statusColor, size: 26),
      title: Text(
        task.command,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GhostTheme.mono.copyWith(fontSize: 12.5, color: Colors.white),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _badge('${task.status.label}${task.exitCode != null && task.status != TaskStatus.running ? ' (exit=${task.exitCode})' : ''}', statusColor),
            _badge('CPU≤${task.cpuQuota}%', GhostTheme.info),
            _badge('Mem≤${task.memoryMax}', GhostTheme.info),
            if (task.lowIo) _badge('ionice', GhostTheme.info),
            _badge(_timeFmt.format(task.createdAt.toLocal()), Colors.white24),
          ],
        ),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          switch (v) {
            case 'log':
              await _showLog(context, ref);
            case 'kill':
              final ok = await _confirm(
                context,
                '终止任务？',
                '将 kill 掉 tmux 会话 ${task.id}，任务进程随 cgroup scope 一并回收。',
              );
              if (ok == true) {
                await ref.read(tasksProvider.notifier).kill(task);
              }
            case 'remove':
              await ref.read(tasksProvider.notifier).remove(task);
            case 'copy':
              // 复制命令（重新提交用）
              await _showSubmitWith(context, ref, task.command);
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'log', child: ListTile(dense: true, leading: Icon(Icons.article_outlined, size: 20), title: Text('查看输出'))),
          if (task.status == TaskStatus.running)
            const PopupMenuItem(value: 'kill', child: ListTile(dense: true, leading: Icon(Icons.stop, size: 20, color: GhostTheme.warn), title: Text('终止任务', style: TextStyle(color: GhostTheme.warn)))),
          const PopupMenuItem(value: 'copy', child: ListTile(dense: true, leading: Icon(Icons.replay, size: 20), title: Text('再次提交'))),
          const PopupMenuItem(value: 'remove', child: ListTile(dense: true, leading: Icon(Icons.delete_outline, size: 20, color: GhostTheme.danger), title: Text('删除记录并清理远端日志', style: TextStyle(color: GhostTheme.danger)))),
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(text, style: TextStyle(fontSize: 10, color: color, fontFamily: 'monospace')),
      );

  Future<void> _showLog(BuildContext context, WidgetRef ref) async {
    final log = await ref.read(tasksProvider.notifier).tailLog(task, lines: 300);
    if (!context.mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0A0E14),
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, scrollCtrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.article_outlined, size: 16, color: Colors.white38),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('${task.id}.log（尾部 300 行）',
                        style: GhostTheme.mono.copyWith(color: Colors.white54, fontSize: 11.5),
                        overflow: TextOverflow.ellipsis),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    icon: const Icon(Icons.refresh, size: 18, color: Colors.white54),
                    onPressed: () async {
                      final fresh = await ref.read(tasksProvider.notifier).tailLog(task, lines: 300);
                      if (c.mounted) {
                        Navigator.pop(c);
                        // 简单实现：关闭后重新打开
                        // ignore: use_build_context_synchronously
                        await _showLogText(c, fresh);
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18, color: Colors.white54),
                    onPressed: () => Navigator.pop(c),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollCtrl,
                reverse: true,
                padding: const EdgeInsets.all(12),
                child: Text(
                  log.isEmpty ? '(暂无输出)' : log,
                  style: GhostTheme.mono.copyWith(color: const Color(0xFFC9D1D9), fontSize: 11.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showLogText(BuildContext context, String log) async {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0A0E14),
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, scrollCtrl) => SingleChildScrollView(
          controller: scrollCtrl,
          reverse: true,
          padding: const EdgeInsets.all(12),
          child: Text(log.isEmpty ? '(暂无输出)' : log,
              style: GhostTheme.mono.copyWith(color: const Color(0xFFC9D1D9), fontSize: 11.5)),
        ),
      ),
    );
  }

  Future<void> _showSubmitWith(BuildContext context, WidgetRef ref, String command) async {
    // 复用提交对话框：弹出提示让用户到提交入口粘贴即可（MVP 简化）
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('再次提交请点右下角按钮，命令：$command')),
    );
  }

  Future<bool?> _confirm(BuildContext context, String title, String body) {
    return showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body, style: const TextStyle(fontSize: 13, color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确定', style: TextStyle(color: GhostTheme.danger)),
          ),
        ],
      ),
    );
  }
}

class _EmptyTasks extends StatelessWidget {
  const _EmptyTasks();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.rocket_launch, size: 52, color: Colors.white12),
            SizedBox(height: 14),
            Text('还没有无感任务', style: TextStyle(color: Colors.white54, fontSize: 15)),
            SizedBox(height: 8),
            Text(
              '提交后命令会自动包裹：\ntmux 保活 + systemd-run 资源封顶 + nice/ionice 降优先级\n断线不中断，桌面毫无察觉',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white30, fontSize: 12, height: 1.7, fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }
}
