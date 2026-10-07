import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../services/ssh_service.dart';
import '../theme.dart';
import 'dashboard_screen.dart';
import 'files_screen.dart';
import 'tasks_screen.dart';
import 'terminal_screen.dart';

/// 面板主框架：仪表盘 / 任务舱 / 终端 / 文件 四个页签（方案文档 §6.2）。
///
/// 同时承担 App 生命周期观察：后台时把监控刷新降到 30s（§6.3.1 刷新策略）。
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with WidgetsBindingObserver {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref.read(foregroundProvider.notifier).state =
        state == AppLifecycleState.resumed;
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(
          children: [
            _LinkIndicator(link: conn.link),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    conn.server?.name ?? '未连接',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    conn.server?.display ?? '—',
                    style: GhostTheme.mono.copyWith(fontSize: 10.5, color: Colors.white38),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '断开连接',
            icon: const Icon(Icons.power_settings_new, size: 20),
            onPressed: () async {
              final navigator = Navigator.of(context);
              final confirm = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('断开连接？'),
                  content: const Text('tmux 中运行的无感任务不会中断，可随时重连查看。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                    TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('断开')),
                  ],
                ),
              );
              if (confirm == true && mounted) {
                await ref.read(connectionProvider.notifier).disconnect();
                navigator.pop();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (conn.link == LinkState.reconnecting)
            const MaterialBanner(
              backgroundColor: Color(0x33FFC65C),
              leading: Icon(Icons.cloud_sync, color: GhostTheme.warn),
              content: Text('连接中断，正在自动重连…（任务在 tmux 中继续运行）',
                  style: TextStyle(fontSize: 12.5)),
              actions: [SizedBox.shrink()],
            ),
          if (conn.link == LinkState.disconnected && conn.server != null)
            MaterialBanner(
              backgroundColor: const Color(0x33FF5A5A),
              leading: const Icon(Icons.cloud_off, color: GhostTheme.danger),
              content: Text('已断开：${conn.error ?? ''}', style: const TextStyle(fontSize: 12.5)),
              actions: [
                TextButton(
                  onPressed: () async {
                    if (conn.server != null) {
                      await ref.read(connectionProvider.notifier).connect(conn.server!);
                    }
                  },
                  child: const Text('重新连接'),
                ),
              ],
            ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: const [
                DashboardScreen(),
                TasksScreen(),
                TerminalScreen(),
                FilesScreen(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        height: 62,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.monitor_heart_outlined), selectedIcon: Icon(Icons.monitor_heart, color: GhostTheme.accent), label: '仪表盘'),
          NavigationDestination(icon: Icon(Icons.rocket_launch_outlined), selectedIcon: Icon(Icons.rocket_launch, color: GhostTheme.accent), label: '任务舱'),
          NavigationDestination(icon: Icon(Icons.terminal_outlined), selectedIcon: Icon(Icons.terminal, color: GhostTheme.accent), label: '终端'),
          NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder, color: GhostTheme.accent), label: '文件'),
        ],
      ),
    );
  }
}

class _LinkIndicator extends StatelessWidget {
  const _LinkIndicator({required this.link});

  final LinkState link;

  @override
  Widget build(BuildContext context) {
    final (color, tooltip) = switch (link) {
      LinkState.connected => (GhostTheme.accent, '已连接'),
      LinkState.connecting => (GhostTheme.warn, '连接中'),
      LinkState.reconnecting => (GhostTheme.warn, '重连中'),
      LinkState.disconnected => (GhostTheme.danger, '已断开'),
    };
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6),
          ],
        ),
      ),
    );
  }
}
