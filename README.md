# 👻 GhostPanel（幽灵面板）

> **在手机上掌控你的 Linux 工作站，而桌面毫无察觉。**

GhostPanel 是《零打扰远程工作站操作方案》的产品化实现：一个 Flutter 手机 App，
通过 SSH 对正在运行重度任务（PR/DaVinci 渲染、Blender、AI 训练、编译）的 Ubuntu
工作站进行监控与管理，全程遵守方案的**三条铁律**：

1. **不碰图形界面** —— 不设置 DISPLAY、不运行 GUI 命令、不触发 polkit 弹窗；
2. **不抢资源** —— 所有重任务自动包裹 `systemd-run`（CPU/内存封顶）+ `nice -n 19` + `ionice -c3`，传输自动 `--bwlimit` 限速；
3. **不丢任务** —— 所有长任务跑在 `tmux` 会话里，手机断网/锁屏/切网均不中断。

---

## 功能总览（对照方案文档）

| 模块 | 方案章节 | 实现状态 |
| --- | --- | --- |
| 🔌 连接管理：多服务器、密码/私钥认证、断线自动重连（指数退避） | §6.2 / §3.1 | ✅ Phase 1 |
| 🖥️ 智能终端：PTY 全功能终端（xterm 渲染）| §6.3.3 | ✅ Phase 1 |
| 🔒 环境变量隔离锁：shell 建立即 `unset DISPLAY/WAYLAND_DISPLAY`，每次 exec 自动前置 | §4.2 解决方案三 | ✅ Phase 1 |
| 🔑 Sudo 密码安全舱：监听输出中的 sudo 提示 → 手机端弹窗 → stdin 回传（走 TTY 认证，不触发桌面 polkit 弹窗），支持会话内记忆 | §4.1 / §6.3.3 | ✅ Phase 1 |
| 🛡️ 危险命令拦截：`rm -rf /`、`reboot`、`killall Xorg`、`dd of=/dev/*`、`mkfs`、`systemctl stop gdm`、`isolate` 等默认拦截；`notify-send`/`xdg-open`/`gedit`/`xdotool` 等"打扰桌面"命令给出零打扰警告 | §6.3.3 黑名单 / §4.2 | ✅ Phase 1 |
| 💾 服务器配置/任务历史/Snippets 本地持久化 | §6.2 | ✅ Phase 1 |
| 🚀 无感任务舱：命令 → 自动包裹 `tmux + systemd-run(CPUQuota/MemoryMax) + nice/ionice`，systemd-run 不可用时自动降级；状态轮询、日志查看、远程终止、记录清理 | §6.3.2 | ✅ Phase 2 |
| 📊 仪表盘：GPU（占用/显存/温度/功耗仪表盘）、CPU 曲线、内存、负载、网速、磁盘、Top 进程（渲染/编译/训练进程自动高亮）；单次 SSH exec 批量采集，前台 3s / 后台 30s 刷新 | §6.3.1 | ✅ Phase 2 |
| 📁 隐形文件传输：SFTP 图形化浏览/上传/下载（带进度）；「隐形 rsync」把工作站↔NAS 同步作为限速任务提交任务舱（tmux 保活 + `--bwlimit` 开关） | §6.3.4 | ✅ Phase 3 |
| ⚡ Snippets 快捷命令：终端页一键执行、长按管理 | §3.1.3 | ✅ Phase 3 |
| 📡 Mosh（UDP 无缝漫游） | §5.2 | ⬜ 未实现（见「已知限制」） |
| 🔔 告警通知（GPU 过温/任务完成推送） | Phase 4 | ⬜ 路线图 |

## 架构

```
┌──────────────────────────── 手机端 (Flutter) ────────────────────────────┐
│  screens/  仪表盘 │ 任务舱 │ 智能终端 │ 文件  │ 服务器列表/编辑            │
│      │           │        │          │       │                           │
│  providers/ (Riverpod)  connection · monitor(3s/30s) · tasks(5s) · ...   │
│      │                                                                  │
│  services/  SSHService ── CommandGuard ── MonitorService                │
│             TaskRunner(tmux+systemd-run) ── TransferService(SFTP/rsync) │
│             StorageService(SharedPreferences)                            │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ SSH (TCP 22, dartssh2 纯 Dart 实现)
┌──────────────────────────────┴──────────────── Ubuntu 工作站 ─────────────┐
│  sshd ──► SSH 会话 (pts/N)   ※ 无 DISPLAY，与 :0 图形会话完全隔离          │
│    ├─ exec 探针: top/free/ps/df/procfs/nvidia-smi   (<50ms/次)            │
│    ├─ tmux 会话: ghost_task_*  (断线保活)                                  │
│    │    └─ systemd-run --user --scope -p CPUQuota -p MemoryMax            │
│    │         └─ nice -n 19 ionice -c3 bash -c '<命令>'  | tee 日志         │
│    └─ SFTP 子系统 (浏览/上传/下载)                                         │
│  物理显示会话 (:0): PR / DaVinci / Blender 正在渲染 —— 完全不受影响         │
└───────────────────────────────────────────────────────────────────────────┘
```

技术栈与方案 §7.2 一致：**Flutter (Dart 3) · dartssh2 · Riverpod · fl_chart · xterm.dart**，
本地存储用 SharedPreferences（接口已隔离在 `StorageService`，可平滑替换 Hive/SQLite）。

## 快速开始

### 1. Ubuntu 工作站端（一次性）

```bash
# 把 scripts/setup_ghostpanel.sh 拷到工作站后：
sudo bash setup_ghostpanel.sh            # 自动检测当前用户
sudo bash setup_ghostpanel.sh alice      # 指定被管理用户
sudo bash setup_ghostpanel.sh alice --mosh  # 需要 Mosh 时
```

脚本会：安装 tmux/htop/rsync/xvfb/nvtop → 写入**最小化** sudo 免密清单
（`visudo -cf` 校验通过才安装，绝无 `NOPASSWD: ALL`）→ 放行防火墙 →
创建 ghost-low.slice cgroup（v2）→ 打印 sshd 加固建议。

### 2. 手机端

```bash
cd ghostpanel
flutter pub get

# Android（需要本机 Android SDK）
flutter build apk --release     # 产物: build/app/outputs/flutter-apk/app-release.apk

# iOS（需要 macOS + Xcode，先补生成 ios/ 目录）
flutter create --platforms=ios . && flutter build ipa

# 开发调试
flutter run
```

### 3. 使用流程

1. **添加工作站**：填 IP/端口/用户名 + 密码或私钥；按需调整零打扰策略
   （限速带宽、任务 CPU/内存封顶默认值、命令拦截开关）；点「测试连接」验证
   ——成功弹窗会显示 `DISPLAY=[]`，证明环境隔离锁生效；
2. **仪表盘**：实时看 GPU/CPU/内存/进程，渲染进程自动高亮；
3. **任务舱**：提交 `make -j4`、`rsync …`、`ffmpeg …`，App 自动包裹资源限制与
   tmux 保活；随时看日志尾部、终止任务；
4. **终端**：完整 PTY 终端。输入危险命令回车时会被 Ctrl+U 清行并弹出拦截确认；
   碰到 sudo 提示时手机端弹密码框（绝不落到桌面弹窗）；
5. **文件**：SFTP 浏览/上传/下载；大目录同步用「隐形 rsync」提交为限速任务。

## 开发验证状态

| 检查 | 结果 |
| --- | --- |
| `flutter analyze` | ✅ No issues found（0 error / 0 warning / 0 info） |
| `flutter test` | ✅ 78/78 通过（命令拦截 60 例、监控解析 10 例、模型/格式化 8 例） |
| `flutter build web --release` | ✅ 全量编译通过（dart2js 完整类型检查） |
| 远端生成脚本 `bash -n` | ✅ 任务脚本/监控探针/退出码探测/引号转义 全部通过 |

测试环境：Flutter 3.47.5 · Dart 3.13.4。

## 安全注意事项（对应方案 §10）

- **凭据存储**：MVP 将密码/私钥存于 SharedPreferences（应用沙箱内明文）。
  生产发布前应替换为 `flutter_secure_storage`（Android Keystore / iOS Keychain），
  `StorageService` 已把存储收敛到单一入口，替换成本低；
- **sudo 密码**：只在内存缓存（断开连接即清除），永不落盘；
- **服务端加固**：强烈建议按 setup 脚本打印的清单配置
  `PasswordAuthentication no` + `PermitRootLogin no` + fail2ban；
- **主机密钥**：dartssh2 默认不校验 known_hosts，首次连接存在理论 MITM 风险，
  局域网使用可接受；后续计划加入指纹确认（`onVerifyHostKey`）；
- **sudoers**：脚本只放行 `systemctl status *`、`nvidia-smi`、`journalctl` 等
  只读/列举命令，修改请保持最小化。

## 已知限制

1. **Mosh 未实现**（方案 §5.2，P2）：需要 UDP + protobuf 协议栈，dartssh2 不覆盖；
   当前以 SSH keepalive（10s）+ 指数退避自动重连 + tmux 保活兜底，切换网络时
   会话会重连但不丢任务；
2. **终端命令拦截基于行缓冲**：逐字符跟踪输入行，若用方向键回到行中间编辑历史
   命令，缓冲可能与实际命令行不一致（回车时对远端真实命令仍会执行 Ctrl+U 清行
   保护，但极端编辑场景可能漏检）；粘贴内容按整体检查；
3. **磁盘占用率**与 `df` 的 Use% 列可能相差 root 保留块部分（按 used/total 计算）；
4. **SFTP 下载**保存到应用私有文档目录（`.../GhostPanel/`），Android 上可通过
   提示条复制路径；如需保存到公共下载目录，后续接 `saf`/MediaStore；
5. **单活动连接**：MVP 一次只连一台工作站（多服务器配置管理已支持）。

## 目录结构

```
ghostpanel/
├── lib/
│   ├── main.dart                  # 入口：注入 SharedPreferences
│   ├── app.dart / theme.dart      # MaterialApp / 深色幽灵主题
│   ├── models/                    # ServerConfig · SystemSnapshot · GhostTask
│   ├── services/
│   │   ├── ssh_service.dart       # 连接/重连/exec/PTY/SFTP + 环境隔离锁
│   │   ├── command_guard.dart     # 危险命令黑名单 + 零打扰违规提示
│   │   ├── monitor_service.dart   # 单次 exec 批量探针 + 解析
│   │   ├── task_runner.dart       # tmux + systemd-run + nice/ionice 包裹
│   │   ├── transfer_service.dart  # SFTP 浏览/传输 + 隐形 rsync 构造
│   │   └── storage_service.dart   # 本地持久化
│   ├── providers/app_providers.dart  # Riverpod：连接/监控流/任务/Snippets
│   ├── screens/                   # 服务器列表/编辑 · 主框架 · 仪表盘 · 任务舱 · 终端 · 文件
│   ├── widgets/                   # DonutGauge · MiniLineChart(fl_chart) · StatCard/UsageBar
│   └── utils/format.dart          # 字节/速率/时长格式化
├── test/                          # 78 个单元/组件测试
├── scripts/setup_ghostpanel.sh    # Ubuntu 端一次性配置（方案 §7.4 加固版）
├── android/ · web/                # 平台工程（flutter create 生成）
└── pubspec.yaml
```

## 后续路线图（对应方案 Phase 4）

- [ ] 告警通知：GPU 过温 / 任务完成 / 重连失败 → 手机推送（firebase_messaging 或 ntfy.sh）
- [ ] known_hosts 主机指纹确认与固定（防 MITM）
- [ ] flutter_secure_storage 凭据加密迁移
- [ ] 命令历史与收藏、深色/浅色主题、平板适配、多语言
- [ ] Mosh 支持（或集成 Blink 类方案跳转）
- [ ] 多活动连接（同时管理多台工作站）

---

*本仓库为《零打扰远程工作站操作方案》v1.0 的配套实现。方案原文见 `uploads/零打扰远程工作站操作方案.md`。*
