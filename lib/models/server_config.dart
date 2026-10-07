import 'dart:math';

/// 认证方式（方案文档 §6.2 连接管理）
enum AuthType {
  password('密码'),
  privateKey('私钥');

  const AuthType(this.label);
  final String label;

  static AuthType fromName(String? name) => AuthType.values.firstWhere(
        (t) => t.name == name,
        orElse: () => AuthType.password,
      );
}

/// 一台受管 Ubuntu 工作站的完整配置。
///
/// 除连接信息外，还携带"零打扰策略"参数（方案文档 §4.3 资源限制、§6.3.4 隐形传输）：
/// - [stealthMode]/[bandwidthLimitMBs]：rsync 限速开关与带宽上限
/// - [defaultCpuQuota]/[defaultMemoryMax]：任务舱默认的 systemd-run 资源封顶
/// - [guardCommands]：危险命令拦截开关（方案文档 §6.3.3）
class ServerConfig {
  ServerConfig({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.authType = AuthType.password,
    this.password,
    this.privateKeyPem,
    this.passphrase,
    this.stealthMode = true,
    this.bandwidthLimitMBs = 8,
    this.defaultCpuQuota = 30,
    this.defaultMemoryMax = '4G',
    this.guardCommands = true,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;

  final AuthType authType;
  final String? password;
  final String? privateKeyPem;
  final String? passphrase;

  // ---- 零打扰策略 ----
  final bool stealthMode;
  final int bandwidthLimitMBs;
  final int defaultCpuQuota; // 百分比，5~100
  final String defaultMemoryMax; // 如 '2G' / '4G' / 'infinity'
  final bool guardCommands;

  String get display => '$username@$host:$port';

  static String newId() =>
      'srv-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(1 << 20)}';

  ServerConfig copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    AuthType? authType,
    String? password,
    String? privateKeyPem,
    String? passphrase,
    bool? stealthMode,
    int? bandwidthLimitMBs,
    int? defaultCpuQuota,
    String? defaultMemoryMax,
    bool? guardCommands,
  }) {
    return ServerConfig(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authType: authType ?? this.authType,
      password: password ?? this.password,
      privateKeyPem: privateKeyPem ?? this.privateKeyPem,
      passphrase: passphrase ?? this.passphrase,
      stealthMode: stealthMode ?? this.stealthMode,
      bandwidthLimitMBs: bandwidthLimitMBs ?? this.bandwidthLimitMBs,
      defaultCpuQuota: defaultCpuQuota ?? this.defaultCpuQuota,
      defaultMemoryMax: defaultMemoryMax ?? this.defaultMemoryMax,
      guardCommands: guardCommands ?? this.guardCommands,
    );
  }

  // 注意：凭据以明文存于 SharedPreferences，MVP 阶段可接受；
  // 生产环境应替换为 flutter_secure_storage（见 README「安全注意事项」）。
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'authType': authType.name,
        'password': password,
        'privateKeyPem': privateKeyPem,
        'passphrase': passphrase,
        'stealthMode': stealthMode,
        'bandwidthLimitMBs': bandwidthLimitMBs,
        'defaultCpuQuota': defaultCpuQuota,
        'defaultMemoryMax': defaultMemoryMax,
        'guardCommands': guardCommands,
      };

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
        id: json['id'] as String,
        name: json['name'] as String? ?? '未命名工作站',
        host: json['host'] as String,
        port: (json['port'] as num?)?.toInt() ?? 22,
        username: json['username'] as String,
        authType: AuthType.fromName(json['authType'] as String?),
        password: json['password'] as String?,
        privateKeyPem: json['privateKeyPem'] as String?,
        passphrase: json['passphrase'] as String?,
        stealthMode: json['stealthMode'] as bool? ?? true,
        bandwidthLimitMBs: (json['bandwidthLimitMBs'] as num?)?.toInt() ?? 8,
        defaultCpuQuota: (json['defaultCpuQuota'] as num?)?.toInt() ?? 30,
        defaultMemoryMax: json['defaultMemoryMax'] as String? ?? '4G',
        guardCommands: json['guardCommands'] as bool? ?? true,
      );
}
