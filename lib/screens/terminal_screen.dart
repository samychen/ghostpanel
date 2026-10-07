import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../providers/app_providers.dart';
import '../services/command_guard.dart';
import '../theme.dart';

/// 智能终端（方案文档 §6.3.3）。
///
/// 三项核心防护：
/// 1. **环境变量隔离锁**：shell 建立后自动 `unset DISPLAY; unset WAYLAND_DISPLAY`；
/// 2. **Sudo 密码安全舱**：监听输出中的 sudo 提示 → 手机端弹窗输入 → 经 stdin 回传，
///    走 TTY 认证，绝不触发桌面 polkit 弹窗（§4.1）；
/// 3. **危险命令拦截**：本地维护行缓冲，回车前过 CommandGuard；
///    danger 级命令先发送 Ctrl+U 清掉远端行缓冲再弹确认框。
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  final Terminal _terminal = Terminal(maxLines: 5000);
  final FocusNode _focusNode = FocusNode();
  final ScrollController _snippetScroll = ScrollController();

  SSHSession? _session;
  bool _connecting = false;
  String? _connectError;

  /// 当前输入行缓冲（用于回车时的危险命令检查）
  String _pendingLine = '';

  /// sudo 弹窗去重标记
  bool _sudoDialogOpen = false;

  /// 上次同步给远端 PTY 的行列数
  int _lastPtyWidth = 0;
  int _lastPtyHeight = 0;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = _onUserInput;
    WidgetsBinding.instance.addPostFrameCallback((_) => _openShell());
  }

  @override
  void dispose() {
    _closeSession();
    _focusNode.dispose();
    _snippetScroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 会话

  Future<void> _openShell() async {
    if (_session != null || _connecting) return;
    final conn = ref.read(connectionProvider);
    if (!conn.isConnected) {
      setState(() => _connectError = '未连接到工作站');
      return;
    }
    setState(() {
      _connecting = true;
      _connectError = null;
    });
    try {
      final session = await conn.service!.openShell(width: 100, height: 32);
      _session = session;

      // 输出 → 终端渲染（含 sudo 提示检测）
      const decoder = Utf8Decoder(allowMalformed: true);
      final sub1 = session.stdout.listen(
        (bytes) {
          final text = decoder.convert(bytes);
          _terminal.write(text);
          _detectSudoPrompt(text);
        },
        onDone: _onSessionDone,
        onError: (_) => _onSessionDone(),
        cancelOnError: false,
      );
      final sub2 = session.stderr.listen(
        (bytes) => _terminal.write(decoder.convert(bytes)),
        onError: (_) {},
        cancelOnError: false,
      );

      session.done.then((_) {
        sub1.cancel();
        sub2.cancel();
        _onSessionDone();
      });

      // 环境变量隔离锁（§4.2 解决方案三 / §6.3.3）
      _write('unset DISPLAY WAYLAND_DISPLAY 2>/dev/null; '
          'export TERM=xterm-256color; '
          'echo "👻 GhostPanel 安全终端 | DISPLAY=[\$DISPLAY] | 环境隔离已启用"; clear\n');

      setState(() => _connecting = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connectError = '$e';
        });
      }
    }
  }

  void _onSessionDone() {
    if (!mounted) return;
    setState(() {
      _session = null;
      _pendingLine = '';
    });
    _terminal.write('\r\n\x1b[90m[会话已结束]\x1b[0m\r\n');
  }

  void _closeSession() {
    try {
      _session?.stdin.close();
    } catch (_) {}
    _session = null;
  }

  void _write(String data) {
    _session?.stdin.add(utf8.encode(data));
  }

  /// 将 xterm 视图的行列数同步到远端 PTY（保证 vim/htop 等全屏程序排版正确）。
  void _syncPtySize() {
    final session = _session;
    if (session == null) return;
    final w = _terminal.viewWidth;
    final h = _terminal.viewHeight;
    if (w <= 0 || h <= 0) return;
    if (w == _lastPtyWidth && h == _lastPtyHeight) return;
    _lastPtyWidth = w;
    _lastPtyHeight = h;
    try {
      session.resizeTerminal(w, h);
    } catch (_) {}
  }

  // ---------------------------------------------------------------- 输入与拦截

  /// xterm 的用户输入回调：先过命令拦截，再写入远端 PTY。
  void _onUserInput(String data) {
    final session = _session;
    if (session == null || data.isEmpty) return;

    final guardEnabled =
        ref.read(connectionProvider).server?.guardCommands ?? true;

    // 多字符输入（粘贴）：整体过一次拦截
    if (data.length > 1) {
      if (guardEnabled) {
        final verdict = CommandGuard.check(data.split('\n').join(' ; '));
        if (verdict.isDanger) {
          _showDangerDialog(verdict, data, isPaste: true);
          return;
        }
        if (verdict.isNotice) _showNotice(verdict);
      }
      _write(data);
      // 更新行缓冲为粘贴内容中最后一个换行之后的残留
      final parts = data.split(RegExp(r'[\r\n]'));
      _pendingLine = parts.last;
      return;
    }

    final ch = data.codeUnitAt(0);

    // 回车：提交前检查行缓冲
    if (ch == 0x0d || ch == 0x0a) {
      if (guardEnabled && _pendingLine.trim().isNotEmpty) {
        final verdict = CommandGuard.check(_pendingLine);
        if (verdict.isDanger) {
          final line = _pendingLine;
          // 先发 Ctrl+U 清掉远端已回显的整行，避免误执行
          _write('\x15');
          _pendingLine = '';
          _terminal.write('\r\n');
          _showDangerDialog(verdict, line, isPaste: false);
          return;
        }
        if (verdict.isNotice) _showNotice(verdict);
      }
      _pendingLine = '';
      _write('\r');
      return;
    }

    // 退格：维护行缓冲
    if (ch == 0x7f || ch == 0x08) {
      if (_pendingLine.isNotEmpty) {
        _pendingLine = _pendingLine.substring(0, _pendingLine.length - 1);
      }
      _write(data);
      return;
    }

    // Ctrl+C / Ctrl+U：清空行缓冲
    if (ch == 0x03 || ch == 0x15) {
      _pendingLine = '';
      _write(data);
      return;
    }

    // 其他控制字符（Tab、方向键等）直接透传，并认为行缓冲可能被编辑而失效
    if (ch < 0x20 || ch == 0x1b) {
      _write(data);
      return;
    }

    // 可打印字符：累积 + 透传（远端 PTY 负责回显）
    _pendingLine += data;
    _write(data);
  }

  void _showDangerDialog(GuardVerdict verdict, String line, {required bool isPaste}) {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.gpp_bad, color: GhostTheme.danger, size: 40),
        title: const Text('危险命令已拦截'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('原因：${verdict.reason}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(verdict.advice,
                style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.5)),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black38,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(line,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: GhostTheme.mono.copyWith(color: GhostTheme.danger)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          TextButton(
            onPressed: () {
              Navigator.pop(c);
              if (isPaste) {
                _write(line);
              } else {
                // 重新输入被 Ctrl+U 清掉的整行并执行
                _write('$line\r');
              }
            },
            child: const Text('我了解风险，仍要执行',
                style: TextStyle(color: GhostTheme.danger)),
          ),
        ],
      ),
    );
  }

  void _showNotice(GuardVerdict verdict) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('⚠️ 零打扰警告：${verdict.reason}。${verdict.advice}'),
        backgroundColor: const Color(0xCC4A3B10),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // ---------------------------------------------------------------- Sudo 密码安全舱

  static final RegExp _sudoPrompt = RegExp(
    r'(\[sudo\][^\r\n]{0,60}(password|密码))|(Password:\s*$)|(的密码[：:]\s*$)',
    caseSensitive: false,
  );

  void _detectSudoPrompt(String text) {
    if (_sudoDialogOpen) return;
    final tail = text.length > 300 ? text.substring(text.length - 300) : text;
    if (_sudoPrompt.hasMatch(tail)) {
      _sudoDialogOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showSudoDialog());
    }
  }

  void _showSudoDialog() {
    if (!mounted) {
      _sudoDialogOpen = false;
      return;
    }
    final controller = TextEditingController(
      text: ref.read(connectionProvider).service?.sudoPassword ?? '',
    );
    var remember = controller.text.isNotEmpty;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.shield_outlined, color: GhostTheme.accent, size: 36),
        title: const Text('需要 sudo 密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '密码将通过 SSH 在 TTY 中认证，不会触发桌面 polkit 弹窗（方案文档 §4.1）。',
              style: TextStyle(color: Colors.white60, fontSize: 12.5, height: 1.5),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'sudo 密码'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('本次连接内记住（仅存内存）', style: TextStyle(fontSize: 12.5)),
              value: remember,
              onChanged: (v) => setState(() => remember = v ?? false),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(c);
              _sudoDialogOpen = false;
              _write('\x03'); // 取消 sudo
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final pw = controller.text;
              Navigator.pop(c);
              _sudoDialogOpen = false;
              final service = ref.read(connectionProvider).service;
              if (remember && service != null) {
                service.cacheSudoPassword(pw);
              } else {
                service?.clearSudoPassword();
              }
              _write('$pw\r');
            },
            child: const Text('提交'),
          ),
        ],
      ),
    ).then((_) => _sudoDialogOpen = false);
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);
    final snippets = ref.watch(snippetsProvider);

    if (!conn.isConnected && _session == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.terminal, size: 44, color: Colors.white12),
            const SizedBox(height: 12),
            Text(_connectError ?? '未连接到工作站',
                style: const TextStyle(color: Colors.white38, fontSize: 13)),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _openShell,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Snippets 快捷命令条（方案文档 §3.1.3 / Phase 3）
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            controller: _snippetScroll,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            children: [
              for (var i = 0; i < snippets.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GestureDetector(
                    onLongPress: _manageSnippets,
                    child: ActionChip(
                      label: Text(snippets[i],
                          style: GhostTheme.mono.copyWith(fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _runSnippet(snippets[i]),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  avatar: const Icon(Icons.add, size: 14),
                  label: const Text('管理', style: TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                  onPressed: _manageSnippets,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // 终端主体
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 布局完成后把最新行列数同步给远端 PTY（窗口大小/横竖屏变化）
              WidgetsBinding.instance.addPostFrameCallback((_) => _syncPtySize());
              return Container(
                color: const Color(0xFF0A0E14),
                child: _connecting
                    ? const Center(child: CircularProgressIndicator())
                    : TerminalView(
                        _terminal,
                        focusNode: _focusNode,
                        autofocus: false,
                        padding: const EdgeInsets.all(8),
                        textStyle: const TerminalStyle(
                          fontSize: 12.5,
                          fontFamily: 'monospace',
                        ),
                        cursorType: TerminalCursorType.block,
                        alwaysShowCursor: true,
                        keyboardAppearance: Brightness.dark,
                      ),
              );
            },
          ),
        ),
        const Divider(height: 1),
        // 控制键工具条
        SizedBox(
          height: 44,
          child: Row(
            children: [
              _keyBtn('ESC', '\x1b'),
              _keyBtn('Tab', '\t'),
              _keyBtn('Ctrl+C', '\x03'),
              _keyBtn('Ctrl+D', '\x04'),
              _keyBtn('Ctrl+L', '\x0c'),
              _keyBtn('↑', '\x1b[A'),
              _keyBtn('↓', '\x1b[B'),
              const Spacer(),
              if (_session != null)
                IconButton(
                  tooltip: '重开 shell',
                  icon: const Icon(Icons.restart_alt, size: 18, color: Colors.white38),
                  onPressed: () {
                    _closeSession();
                    _terminal.write('\x1b[2J\x1b[3J\x1b[H'); // 清屏（含回滚缓冲）
                    _openShell();
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _keyBtn(String label, String data) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: const Size(0, 32),
            foregroundColor: Colors.white54,
            textStyle: GhostTheme.mono.copyWith(fontSize: 11),
          ),
          onPressed: () => _write(data),
          child: Text(label),
        ),
      );

  void _runSnippet(String snippet) {
    if (ref.read(connectionProvider).server?.guardCommands ?? true) {
      final verdict = CommandGuard.check(snippet);
      if (verdict.isDanger) {
        _showDangerDialog(verdict, snippet, isPaste: true);
        return;
      }
      if (verdict.isNotice) _showNotice(verdict);
    }
    _write('$snippet\r');
  }

  void _manageSnippets() {
    final snippets = ref.read(snippetsProvider);
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Snippets 快捷命令'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (var i = 0; i < snippets.length; i++)
                      ListTile(
                        dense: true,
                        title: Text(snippets[i], style: GhostTheme.mono.copyWith(fontSize: 12)),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 16, color: Colors.white38),
                          onPressed: () {
                            ref.read(snippetsProvider.notifier).removeAt(i);
                            Navigator.pop(c);
                            _manageSnippets(); // 刷新列表
                          },
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                style: GhostTheme.mono,
                decoration: const InputDecoration(
                  labelText: '新命令',
                  hintText: 'watch -n 2 nvidia-smi',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭')),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                ref.read(snippetsProvider.notifier).add(controller.text);
              }
              Navigator.pop(c);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }
}
