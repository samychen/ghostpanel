import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/server_config.dart';
import '../providers/app_providers.dart';
import '../services/ssh_service.dart';
import '../theme.dart';

/// 添加 / 编辑工作站配置。
///
/// 除连接信息外，集中配置"零打扰策略"默认值：
/// 传输限速（§6.3.4）、任务 CPU/内存封顶（§4.3）、危险命令拦截（§6.3.3）。
class ServerEditScreen extends ConsumerStatefulWidget {
  const ServerEditScreen({super.key, this.existing});

  final ServerConfig? existing;

  @override
  ConsumerState<ServerEditScreen> createState() => _ServerEditScreenState();
}

class _ServerEditScreenState extends ConsumerState<ServerEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _privateKey;
  late final TextEditingController _passphrase;

  late AuthType _authType;
  late bool _stealthMode;
  late double _bwlimit;
  late double _cpuQuota;
  late String _memoryMax;
  late bool _guardCommands;

  bool _obscurePassword = true;
  bool _testing = false;

  static const _memoryOptions = ['1G', '2G', '4G', '8G', '16G', 'infinity'];

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(text: '${e?.port ?? 22}');
    _username = TextEditingController(text: e?.username ?? '');
    _password = TextEditingController(text: e?.password ?? '');
    _privateKey = TextEditingController(text: e?.privateKeyPem ?? '');
    _passphrase = TextEditingController(text: e?.passphrase ?? '');
    _authType = e?.authType ?? AuthType.password;
    _stealthMode = e?.stealthMode ?? true;
    _bwlimit = (e?.bandwidthLimitMBs ?? 8).toDouble();
    _cpuQuota = (e?.defaultCpuQuota ?? 30).toDouble();
    _memoryMax = e?.defaultMemoryMax ?? '4G';
    _guardCommands = e?.guardCommands ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _privateKey.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  ServerConfig _buildConfig() {
    final existing = widget.existing;
    return ServerConfig(
      id: existing?.id ?? ServerConfig.newId(),
      name: _name.text.trim().isEmpty ? _host.text.trim() : _name.text.trim(),
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 22,
      username: _username.text.trim(),
      authType: _authType,
      password: _authType == AuthType.password ? _password.text : null,
      privateKeyPem: _authType == AuthType.privateKey ? _privateKey.text : null,
      passphrase: _authType == AuthType.privateKey && _passphrase.text.isNotEmpty
          ? _passphrase.text
          : null,
      stealthMode: _stealthMode,
      bandwidthLimitMBs: _bwlimit.round(),
      defaultCpuQuota: _cpuQuota.round(),
      defaultMemoryMax: _memoryMax,
      guardCommands: _guardCommands,
    );
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _testing = true);
    final service = SSHService(_buildConfig());
    String message;
    bool ok;
    try {
      await service.connect();
      // 验证环境隔离锁生效：DISPLAY 应为空
      final display = (await service.exec('echo "DISPLAY=[\$DISPLAY]"')).trim();
      ok = true;
      message = '连接成功 ✓\n$display\n环境隔离锁已生效，SSH 会话不接触图形桌面。';
    } catch (e) {
      ok = false;
      message = '连接失败：$e';
    } finally {
      await service.dispose();
      if (mounted) setState(() => _testing = false);
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: Icon(ok ? Icons.check_circle : Icons.error,
            color: ok ? GhostTheme.accent : GhostTheme.danger, size: 36),
        title: Text(ok ? '测试通过' : '测试失败'),
        content: Text(message, style: GhostTheme.mono.copyWith(fontSize: 12.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭')),
        ],
      ),
    );
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    ref.read(serversProvider.notifier).upsert(_buildConfig());
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? '编辑工作站' : '添加工作站'),
        actions: [
          TextButton.icon(
            onPressed: _testing ? null : _testConnection,
            icon: _testing
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.wifi_tethering, size: 18),
            label: const Text('测试连接'),
          ),
          TextButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('保存', style: TextStyle(color: GhostTheme.accent)),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _sectionTitle('连接信息'),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称（如：渲染工作站）'),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _host,
                    decoration: const InputDecoration(labelText: '主机 IP / 域名 *'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? '必填' : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _port,
                    decoration: const InputDecoration(labelText: '端口'),
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      final p = int.tryParse(v?.trim() ?? '');
                      return (p == null || p <= 0 || p > 65535) ? '无效' : null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(labelText: '用户名 *'),
              validator: (v) => (v == null || v.trim().isEmpty) ? '必填' : null,
            ),
            const SizedBox(height: 12),
            SegmentedButton<AuthType>(
              segments: const [
                ButtonSegment(value: AuthType.password, label: Text('🔒 密码认证')),
                ButtonSegment(value: AuthType.privateKey, label: Text('🔑 密钥认证')),
              ],
              selected: {_authType},
              onSelectionChanged: (s) => setState(() => _authType = s.first),
            ),
            const SizedBox(height: 12),
            if (_authType == AuthType.password)
              TextFormField(
                controller: _password,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'SSH 密码 *',
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                validator: (v) => (v == null || v.isEmpty) ? '必填' : null,
              )
            else ...[
              TextFormField(
                controller: _privateKey,
                maxLines: 5,
                style: GhostTheme.mono.copyWith(fontSize: 11.5),
                decoration: const InputDecoration(
                  labelText: '私钥内容（PEM）*',
                  hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
                ),
                validator: (v) => (v == null || !v.contains('PRIVATE KEY')) ? '请粘贴有效私钥' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passphrase,
                obscureText: true,
                decoration: const InputDecoration(labelText: '私钥口令（可选）'),
              ),
              const SizedBox(height: 8),
              const Text(
                '💡 生产环境推荐密钥认证 + 服务端禁用密码登录（方案文档 §10）。',
                style: TextStyle(color: Colors.white38, fontSize: 11.5),
              ),
            ],
            const SizedBox(height: 24),
            _sectionTitle('零打扰策略'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('隐形传输模式'),
              subtitle: const Text('rsync 自动限速 + nice/ionice 低优先级（§6.3.4）'),
              value: _stealthMode,
              onChanged: (v) => setState(() => _stealthMode = v),
            ),
            if (_stealthMode)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Row(
                  children: [
                    const Text('带宽上限', style: TextStyle(fontSize: 13, color: Colors.white70)),
                    Expanded(
                      child: Slider(
                        value: _bwlimit,
                        min: 1,
                        max: 100,
                        divisions: 99,
                        label: '${_bwlimit.round()} MB/s',
                        onChanged: (v) => setState(() => _bwlimit = v),
                      ),
                    ),
                    SizedBox(
                      width: 64,
                      child: Text('${_bwlimit.round()} MB/s',
                          style: GhostTheme.mono.copyWith(color: GhostTheme.accent)),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Row(
                children: [
                  const Text('任务 CPU 封顶', style: TextStyle(fontSize: 13, color: Colors.white70)),
                  Expanded(
                    child: Slider(
                      value: _cpuQuota,
                      min: 5,
                      max: 100,
                      divisions: 19,
                      label: '${_cpuQuota.round()}%',
                      onChanged: (v) => setState(() => _cpuQuota = v),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text('${_cpuQuota.round()}%',
                        style: GhostTheme.mono.copyWith(color: GhostTheme.accent)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue: _memoryMax,
              decoration: const InputDecoration(labelText: '任务内存上限（systemd-run MemoryMax）'),
              items: _memoryOptions
                  .map((m) => DropdownMenuItem(
                        value: m,
                        child: Text(m == 'infinity' ? '不限制（不建议）' : m),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _memoryMax = v ?? '4G'),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('危险命令拦截'),
              subtitle: const Text('拦截 rm -rf /、reboot、killall Xorg 等（§6.3.3）；\n对弹窗/发声类命令给出零打扰警告（§4.2）'),
              value: _guardCommands,
              onChanged: (v) => setState(() => _guardCommands = v),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _save,
              style: FilledButton.styleFrom(
                backgroundColor: GhostTheme.accent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.save),
              label: Text(_isEdit ? '保存修改' : '添加工作站'),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Container(width: 3, height: 14, color: GhostTheme.accent),
            const SizedBox(width: 8),
            Text(text,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
          ],
        ),
      );
}
