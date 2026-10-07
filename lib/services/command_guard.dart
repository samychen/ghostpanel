/// 危险命令拦截（方案文档 §6.3.3）+ 零打扰违规提示（方案文档 §4.2）。
///
/// 两个级别：
/// - [GuardLevel.danger]：可能中断渲染任务 / 破坏系统 / 关闭桌面会话 —— 默认拦截，需显式确认；
/// - [GuardLevel.notice]：会在桌面弹窗、发声或操作键鼠剪贴板，违反"零打扰"原则 —— 放行但警告。
library;

enum GuardLevel { ok, notice, danger }

class GuardVerdict {
  const GuardVerdict(this.level, {this.reason = '', this.advice = ''});

  final GuardLevel level;
  final String reason;
  final String advice;

  bool get isOk => level == GuardLevel.ok;
  bool get isNotice => level == GuardLevel.notice;
  bool get isDanger => level == GuardLevel.danger;

  static const ok = GuardVerdict(GuardLevel.ok);
}

class _Rule {
  const _Rule(this.pattern, this.reason, this.advice);
  final RegExp pattern;
  final String reason;
  final String advice;
}

class CommandGuard {
  CommandGuard._();

  /// 危险命令黑名单（对应文档：reboot/shutdown、killall Xorg、rm -rf /、dd of=/dev/sda、mkfs、systemctl stop gdm / isolate）
  static final List<_Rule> _dangerRules = [
    _Rule(
      RegExp(r'(^|[\s;&|(])(sudo\s+)?(reboot|shutdown|halt|poweroff)(\s|$)'),
      '关机 / 重启命令',
      '工作站可能正在渲染或训练，重启将直接中断所有任务。',
    ),
    _Rule(
      RegExp(r'(^|[\s;&|(])(sudo\s+)?init\s+[06](\s|$)'),
      '切换运行级别（init 0/6 等效关机/重启）',
      '请使用 systemctl 精细控制单个服务，而不是切换整机运行级别。',
    ),
    _Rule(
      RegExp(r'(^|[\s;&|])(sudo\s+)?dd\b[^|;&]*\bof=/dev/'),
      'dd 直写块设备',
      '会不可逆地覆盖磁盘数据。',
    ),
    _Rule(
      RegExp(r'(^|[\s;&|])(sudo\s+)?mkfs(\.\w+)?\b'),
      '格式化文件系统（mkfs）',
      '会清空目标分区全部数据。',
    ),
    _Rule(
      RegExp(r'\b(wipefs|sgdisk\s+--zap-all|shred\b[^|;&]*\s/dev/)'),
      '磁盘擦除类命令',
      '会不可逆地销毁数据。',
    ),
    _Rule(
      RegExp(
          r'\b(killall|pkill)\s+(-\S+\s+)*(-\S+\s+)*(Xorg|Xwayland|gnome-shell|gnome-session|mutter|kwin\w*|gdm3?|sddm|lightdm|plasmashell)\b'),
      '终止桌面/显示服务器进程',
      '会导致正在使用的桌面会话崩溃，未保存的工作全部丢失。',
    ),
    _Rule(
      RegExp(r'\bsystemctl\s+(stop|kill|mask|disable)\s+(gdm3?|sddm|lightdm|display-manager)\b'),
      '停止显示管理器',
      '桌面会被强制登出，前台渲染任务可能一并终止。',
    ),
    _Rule(
      RegExp(r'\bsystemctl\s+isolate\b'),
      '切换 systemd target（isolate）',
      '等效于整机运行级别切换，图形会话将被终止。',
    ),
    _Rule(
      RegExp(r'\bloginctl\s+(terminate|kill)\b'),
      '终止登录会话',
      '会把桌面用户强制登出。',
    ),
    _Rule(
      RegExp(r'\b(chmod|chown)\s+(-\w*R|--recursive)\b[^|;&]*\s/(etc|usr|bin|sbin|boot|lib|var)(/|\s|$)'),
      '对系统目录递归改权限',
      '极易破坏系统，且难以回滚。',
    ),
    _Rule(
      RegExp(r':\(\s*\)\s*\{\s*:\|'),
      'Fork 炸弹',
      '会耗尽全部 CPU/进程资源，直接拖死渲染任务。',
    ),
    _Rule(
      RegExp(r'\bsystemd-run\b[^|;&]*--property[=\s]CPUQuota=100%'),
      '以 100% CPU 配额提交任务',
      '违反"不抢资源"铁律，会与前台渲染争抢 CPU。',
    ),
  ];

  /// 零打扰违规提示（GUI 弹窗 / 声音 / 键鼠剪贴板 / DISPLAY 注入）
  static final List<_Rule> _noticeRules = [
    _Rule(
      RegExp(r'\b(notify-send|zenity|kdialog|yad|xmessage)\b'),
      '会在桌面弹出通知/对话框',
      '违反零打扰原则。纯输出请用 echo（方案文档 §4.2）。',
    ),
    _Rule(
      RegExp(r'\bxdg-open\b'),
      '会用桌面默认应用打开文件（弹窗）',
      '查看内容请改用 cat / less。',
    ),
    _Rule(
      RegExp(
          r'\b(gedit|gnome-text-editor|kate|leafpad|mousepad|nautilus|dolphin|thunar|nemo|pcmanfm|evince|eog|gedit)\b'),
      '会启动 GUI 应用并在桌面弹出窗口',
      '文本用 cat/vim，目录用 ls（方案文档 §4.2）。',
    ),
    _Rule(
      RegExp(r'\b(xdotool|xte|wmctrl|xrandr|xset|xdpyinfo)\b'),
      '会操作桌面的键盘/鼠标/显示设置',
      'SSH 会话不应触碰图形会话的输入设备。',
    ),
    _Rule(
      RegExp(r'\b(xclip|xsel|wl-copy|wl-paste)\b'),
      '会读写桌面剪贴板',
      '可能覆盖用户正在复制的内容。',
    ),
    _Rule(
      RegExp(r'\b(DISPLAY|WAYLAND_DISPLAY)\s*=\s*\S'),
      '向命令注入图形环境变量',
      'SSH 会话必须保持无 DISPLAY（方案文档 §4.2 解决方案三）。确需 GUI 请用 xvfb-run。',
    ),
    _Rule(
      RegExp(r'\b(paplay|aplay|ffplay|mpv|vlc)\b|\bffmpeg\b[^|;&]*-f\s+(alsa|pulse|sdl)'),
      '可能通过桌面声卡发声',
      '会打扰正在使用桌面的人。',
    ),
    _Rule(
      RegExp(r'(^|[\s;&|])(sudo\s+)?wall\b'),
      'wall 会向所有 TTY 广播消息（含桌面终端）',
      '改用 echo 输出到当前会话。',
    ),
  ];

  /// 检查一行命令。先剥离前缀 sudo 再匹配，保证 `sudo rm -rf /` 同样被拦截。
  static GuardVerdict check(String input) {
    final line = input.trim();
    if (line.isEmpty) return GuardVerdict.ok;

    final bare = line
        .replaceAll(RegExp(r'(^|[\s;&|])sudo(\s+-\S+)*\s+'), ' ')
        .trim();

    // rm -rf / 需要结构化判断（flag 组合 + 目标路径）
    if (_isRecursiveForceDeleteRoot(bare)) {
      return const GuardVerdict(
        GuardLevel.danger,
        reason: 'rm -rf 指向根目录/家目录',
        advice: '会不可逆地删除整个文件系统，已拦截。',
      );
    }

    for (final rule in _dangerRules) {
      if (rule.pattern.hasMatch(line) || rule.pattern.hasMatch(bare)) {
        return GuardVerdict(GuardLevel.danger, reason: rule.reason, advice: rule.advice);
      }
    }
    for (final rule in _noticeRules) {
      if (rule.pattern.hasMatch(line) || rule.pattern.hasMatch(bare)) {
        return GuardVerdict(GuardLevel.notice, reason: rule.reason, advice: rule.advice);
      }
    }
    return GuardVerdict.ok;
  }

  /// 判断是否为 `rm -rf /`、`rm -fr /*`、`rm -r -f ~` 一类的灭顶操作。
  static bool _isRecursiveForceDeleteRoot(String cmd) {
    final matches = RegExp(r'(^|[\s;&|])rm\s+([^;&|]*)').allMatches(cmd);
    for (final m in matches) {
      final args = m.group(2) ?? '';
      final hasR = RegExp(r'(^|\s)-\w*r').hasMatch(args) || args.contains('--recursive');
      final hasF = RegExp(r'(^|\s)-\w*f').hasMatch(args) || args.contains('--force');
      final targetsRoot = RegExp(r'(^|\s)(/|/\*|~|~/\*|\$HOME/?\*?)(\s|$)').hasMatch(args) ||
          args.contains('--no-preserve-root');
      if (hasR && hasF && targetsRoot) return true;
    }
    return false;
  }
}
