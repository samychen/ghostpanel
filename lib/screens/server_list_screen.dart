import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/server_config.dart';
import '../providers/app_providers.dart';
import '../services/ssh_service.dart';
import '../theme.dart';
import 'home_screen.dart';
import 'server_edit_screen.dart';

/// 连接管理：多服务器列表（方案文档 §6.2 连接管理 / Phase 3「多服务器管理」）。
class ServerListScreen extends ConsumerWidget {
  const ServerListScreen({super.key});

  Future<void> _connect(BuildContext context, WidgetRef ref, ServerConfig server) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final ok = await ref.read(connectionProvider.notifier).connect(server);

    navigator.pop(); // 关闭 loading

    if (ok) {
      navigator.push(MaterialPageRoute(builder: (_) => const HomeScreen()));
    } else {
      final err = ref.read(connectionProvider).error ?? '未知错误';
      messenger.showSnackBar(
        SnackBar(content: Text('连接失败：$err'), backgroundColor: GhostTheme.danger),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(serversProvider);
    final conn = ref.watch(connectionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Text('👻', style: TextStyle(fontSize: 20)),
            SizedBox(width: 8),
            Text('GhostPanel', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(26),
          child: Padding(
            padding: EdgeInsets.only(bottom: 8, left: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '在手机上掌控你的 Linux 工作站，而桌面毫无察觉',
                style: TextStyle(color: Colors.white38, fontSize: 11.5),
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ServerEditScreen()),
        ),
        backgroundColor: GhostTheme.accent,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: const Text('添加工作站'),
      ),
      body: servers.isEmpty ? _emptyState(context) : _serverList(context, ref, servers, conn),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.dns_outlined, size: 64, color: Colors.white12),
            const SizedBox(height: 16),
            const Text('还没有配置工作站', style: TextStyle(fontSize: 16, color: Colors.white70)),
            const SizedBox(height: 8),
            const Text(
              '添加一台 Ubuntu 工作站，通过 SSH 无感管理它。\n'
              '先在工作站上运行 scripts/setup_ghostpanel.sh 完成环境准备。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 13, height: 1.6),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ServerEditScreen()),
              ),
              icon: const Icon(Icons.add),
              label: const Text('添加第一台工作站'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _serverList(
    BuildContext context,
    WidgetRef ref,
    List<ServerConfig> servers,
    AppConnection conn,
  ) {
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: servers.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
      itemBuilder: (context, i) {
        final s = servers[i];
        final isActive = conn.server?.id == s.id;
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: _statusDot(isActive ? conn.link : LinkState.disconnected),
          title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.display, style: GhostTheme.mono.copyWith(color: Colors.white38)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: [
                    _chip(s.authType == AuthType.privateKey ? '🔑 密钥' : '🔒 密码'),
                    if (s.stealthMode) _chip('👻 限速 ${s.bandwidthLimitMBs}MB/s'),
                    _chip('CPU≤${s.defaultCpuQuota}% · 内存≤${s.defaultMemoryMax}'),
                    if (s.guardCommands) _chip('🛡️ 命令拦截'),
                  ],
                ),
              ],
            ),
          ),
          trailing: PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'edit':
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ServerEditScreen(existing: s),
                  ));
                case 'delete':
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('删除工作站配置？'),
                      content: Text('「${s.name}」的连接信息将被移除。'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                        TextButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('删除', style: TextStyle(color: GhostTheme.danger)),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    if (conn.server?.id == s.id) {
                      await ref.read(connectionProvider.notifier).disconnect();
                    }
                    ref.read(serversProvider.notifier).remove(s.id);
                  }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('编辑'))),
              PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline, color: GhostTheme.danger), title: Text('删除', style: TextStyle(color: GhostTheme.danger)))),
            ],
          ),
          onTap: () async {
            if (isActive && conn.isConnected) {
              // 已连接：直接进入面板
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HomeScreen()));
              return;
            }
            await _connect(context, ref, s);
          },
        );
      },
    );
  }

  Widget _statusDot(LinkState link) {
    final (color, icon) = switch (link) {
      LinkState.connected => (GhostTheme.accent, Icons.cloud_done),
      LinkState.connecting || LinkState.reconnecting => (GhostTheme.warn, Icons.cloud_sync),
      LinkState.disconnected => (Colors.white24, Icons.cloud_off),
    };
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: color, size: 20),
    );
  }

  Widget _chip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text, style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
      );
}
