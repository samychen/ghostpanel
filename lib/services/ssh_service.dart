import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';

import '../models/server_config.dart';

/// 连接生命周期状态
enum LinkState { disconnected, connecting, connected, reconnecting }

/// exec 的结构化结果
class ExecResult {
  const ExecResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
  bool get ok => exitCode == 0;
}

/// SSH 连接管理层（方案文档 §7.1 / §7.3.1）。
///
/// 职责：
/// 1. 建立/维护到 Ubuntu 工作站的 SSH 连接（密码或私钥认证）；
/// 2. **环境变量隔离锁**：所有 exec 命令自动前置
///    `unset DISPLAY; unset WAYLAND_DISPLAY`（方案文档 §4.2 解决方案三 / §6.3.3）；
/// 3. 断线自动重连（指数退避，方案文档 Phase 1「断线重连机制」）；
/// 4. 暴露 shell(PTY) / sftp 能力给终端页与文件页；
/// 5. sudo 密码会话内缓存（方案文档 §6.3.3 Sudo 密码安全舱，仅存内存，绝不落盘）。
class SSHService {
  SSHService(this.config);

  ServerConfig config;

  /// 环境隔离前缀：确保 SSH 会话中的命令永远接触不到图形会话
  static const String envIsolation =
      'unset DISPLAY WAYLAND_DISPLAY 2>/dev/null; export TERM=xterm-256color; ';

  SSHClient? _client;
  SSHSocket? _socket;

  LinkState _state = LinkState.disconnected;
  LinkState get state => _state;
  Stream<LinkState> get stateStream => _stateCtrl.stream;
  final _stateCtrl = StreamController<LinkState>.broadcast();

  String? lastError;

  /// sudo 密码的会话内缓存（仅内存；断开连接即清空）
  String? _sudoPassword;
  String? get sudoPassword => _sudoPassword;
  void cacheSudoPassword(String password) => _sudoPassword = password;
  void clearSudoPassword() => _sudoPassword = null;

  bool _disposed = false;
  bool _manualDisconnect = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;

  /// 正在进行中的连接 Future。仪表盘轮询、任务舱轮询、终端可能在同一时刻
  /// 各自触发一次连接；若无互斥会并发建立多条 TCP/握手，彼此覆盖 `_client`，
  /// 表现为界面长时间停在「连接中」。所有连接请求统一复用同一个 Future。
  Future<void>? _connectInFlight;

  static const int maxReconnectAttempts = 12;

  // ---------------------------------------------------------------- 连接

  Future<void> connect() async {
    _manualDisconnect = false;
    await _doConnect(throwOnError: true);
  }

  Future<void> _doConnect({bool throwOnError = false}) async {
    final existing = _connectInFlight;
    if (existing != null) {
      // 已有连接在进行中：复用其结果，避免重复握手。
      try {
        await existing;
      } catch (_) {
        if (!throwOnError) return;
        throw SSHServiceException(lastError ?? '连接失败');
      }
      return;
    }

    final future = _doConnectInner();
    _connectInFlight = future;
    try {
      await future;
    } on SSHServiceException catch (e) {
      if (throwOnError) rethrow;
      lastError = e.message;
    } finally {
      if (identical(_connectInFlight, future)) _connectInFlight = null;
    }
  }

  Future<void> _doConnectInner() async {
    _setState(_reconnectAttempt > 0 ? LinkState.reconnecting : LinkState.connecting);
    try {
      _socket = await SSHSocket.connect(
        config.host,
        config.port,
        timeout: const Duration(seconds: 10),
      );

      final identities = <SSHKeyPair>[];
      final pem = config.privateKeyPem?.trim() ?? '';
      if (pem.isNotEmpty) {
        identities.addAll(SSHKeyPair.fromPem(pem, config.passphrase));
      }

      _client = SSHClient(
        _socket!,
        username: config.username,
        identities: identities,
        onPasswordRequest: () {
          final pw = config.password ?? _sudoPassword;
          if (pw == null || pw.isEmpty) {
            throw StateError('未配置密码');
          }
          return pw;
        },
      );

      // 认证/握手必须自带超时：dartssh2 的 authenticated Future 本身不会超时，
      // 若服务端接受了 TCP 却不响应 SSH 横幅或密钥交换，UI 会永久停在「连接中」。
      await _client!.authenticated.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw SSHServiceException(
          'SSH 握手/认证超时：已建立 TCP 连接，但服务端 ${config.host}:${config.port} 未完成认证响应',
        ),
      );

      // 连接建立后立即验证一次环境隔离（同时也确认通道可用）。
      // 注意：此刻 _state 仍是 connecting，绝不能走 exec() → _ensureConnected()，
      // 否则会死等状态变成 connected，而 connected 又要等本次自检结束 —— 自我死锁。
      await _execOn(_client!, 'true', timeout: const Duration(seconds: 8));

      _reconnectAttempt = 0;
      lastError = null;
      _setState(LinkState.connected);

      // 监听底层断开
      unawaited(_client!.done.then((_) => _onLinkLost()).catchError((_) {}));
    } catch (e) {
      lastError = _humanizeError(e);
      _cleanupSocket();
      _setState(LinkState.disconnected);
      // 内层始终抛出，由外层 _doConnect 依据 throwOnError 决定吞掉还是上抛。
      throw SSHServiceException(lastError!);
    }
  }

  void _onLinkLost() {
    if (_disposed || _manualDisconnect) return;
    if (_state == LinkState.disconnected) return;
    _cleanupSocket();
    if (_reconnectAttempt < maxReconnectAttempts) {
      _setState(LinkState.reconnecting);
      _scheduleReconnect();
    } else {
      lastError = '重连 $maxReconnectAttempts 次失败，已放弃';
      _setState(LinkState.disconnected);
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final delaySec = min(30, pow(2, _reconnectAttempt).toInt());
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(seconds: delaySec), () async {
      if (_disposed || _manualDisconnect) return;
      try {
        await _doConnect();
      } catch (_) {
        if (!_disposed && !_manualDisconnect &&
            _reconnectAttempt < maxReconnectAttempts) {
          _scheduleReconnect();
        } else if (!_disposed) {
          lastError = '重连失败：$lastError';
          _setState(LinkState.disconnected);
        }
      }
    });
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _cleanupSocket();
    _sudoPassword = null;
    _setState(LinkState.disconnected);
  }

  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
    await _stateCtrl.close();
  }

  void _cleanupSocket() {
    try {
      _client?.close();
    } catch (_) {}
    _client = null;
    try {
      _socket?.destroy();
    } catch (_) {}
    _socket = null;
  }

  void _setState(LinkState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateCtrl.isClosed) _stateCtrl.add(s);
  }

  /// 若当前未连接（例如手动断开后又发起操作），先自动连接。
  Future<void> _ensureConnected() async {
    if (_client != null && _state == LinkState.connected) return;
    if (_state == LinkState.connecting || _state == LinkState.reconnecting) {
      // 等待进行中的连接收敛（最多 15s）
      for (var i = 0; i < 150; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (_state == LinkState.connected) return;
        if (_state == LinkState.disconnected) break;
      }
    }
    await _doConnect(throwOnError: true);
  }

  // ---------------------------------------------------------------- 执行

  /// 执行一条命令并取回 stdout 文本（自动环境隔离）。
  Future<String> exec(String command, {Duration? timeout}) async {
    final r = await execFull(command, timeout: timeout);
    return r.stdout;
  }

  /// 执行命令，返回 exitCode/stdout/stderr。
  ///
  /// [isolateEnv]=true 时前置 `unset DISPLAY; unset WAYLAND_DISPLAY;`，
  /// 确保任何情况下都不会把命令送进图形会话（方案文档三条铁律之一）。
  Future<ExecResult> execFull(
    String command, {
    bool isolateEnv = true,
    Duration? timeout,
  }) async {
    await _ensureConnected();
    return _execOn(_client!, command, isolateEnv: isolateEnv, timeout: timeout);
  }

  /// 在给定客户端上直接执行命令，不做任何连接状态等待。
  ///
  /// 供 [_doConnect] 的连接后自检使用：自检发生在状态仍为 connecting 时，
  /// 若复用 [execFull] 会经 `_ensureConnected` 等待「状态变为 connected」，
  /// 而该状态又要等自检通过才设置，形成永久死锁（界面卡在「连接中」）。
  Future<ExecResult> _execOn(
    SSHClient client,
    String command, {
    bool isolateEnv = true,
    Duration? timeout,
  }) async {
    final full = isolateEnv ? '$envIsolation$command' : command;

    try {
      final session = await client.execute(full);
      final stdoutF = utf8.decodeStream(session.stdout);
      final stderrF = utf8.decodeStream(session.stderr);
      if (timeout != null) {
        await session.done.timeout(timeout);
      } else {
        await session.done;
      }
      return ExecResult(
        session.exitCode ?? -1,
        await stdoutF,
        await stderrF,
      );
    } on TimeoutException {
      throw SSHServiceException('命令执行超时：${_truncate(command)}');
    } catch (e) {
      // 执行期间链路断开：交给自动重连处理，本次报错
      throw SSHServiceException('命令执行失败：${_humanizeError(e)}');
    }
  }

  // ---------------------------------------------------------------- PTY / SFTP

  /// 打开一个交互式 PTY shell（智能终端使用）。
  /// 返回的 SSHSession：stdout/stderr 为输出流，stdin 用于写入按键。
  Future<SSHSession> openShell({int width = 100, int height = 32}) async {
    await _ensureConnected();
    final session = await _client!.shell(
      pty: SSHPtyConfig(
        type: 'xterm-256color',
        width: width,
        height: height,
      ),
      environment: const {'GHOSTPANEL': '1'},
    );
    return session;
  }

  /// 获取 SFTP 客户端（隐形文件传输使用）。
  Future<SftpClient> sftp() async {
    await _ensureConnected();
    return _client!.sftp();
  }

  // ---------------------------------------------------------------- 工具

  static String _truncate(String s) => s.length > 60 ? '${s.substring(0, 60)}…' : s;

  static String _humanizeError(Object e) {
    if (e is SSHAuthFailError) return '认证失败：用户名或密码/密钥不正确';
    if (e is SSHAuthAbortError) return '认证被服务端拒绝';
    if (e is SSHSocketError) return '网络错误：无法建立 SSH 连接';
    if (e is SSHHandshakeError) return 'SSH 握手失败：${e.toString()}';
    if (e is SSHHostkeyError) return '主机密钥校验失败（谨防中间人攻击）';
    if (e is TimeoutException) return '连接超时，请检查主机与端口';
    return e.toString();
  }
}

class SSHServiceException implements Exception {
  SSHServiceException(this.message);
  final String message;
  @override
  String toString() => message;
}
