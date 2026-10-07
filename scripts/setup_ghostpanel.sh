#!/usr/bin/env bash
# ============================================================================
# setup_ghostpanel.sh — GhostPanel Ubuntu 工作站端一次性环境配置
# 对应《零打扰远程工作站操作方案》§7.4
#
# 用法:
#   bash setup_ghostpanel.sh              # 自动检测当前用户
#   bash setup_ghostpanel.sh alice        # 指定被管理用户
#   bash setup_ghostpanel.sh alice --mosh # 同时安装并放行 Mosh
#
# 做的事:
#   1. 安装必要工具 (tmux/htop/nvtop/rsync/xvfb)
#   2. 配置最小化 sudo 免密（仅只读/服务管理类命令，visudo 校验后安装）
#   3. 防火墙放行 SSH（可选放行 Mosh UDP 60000-61000）
#   4. 创建低优先级 cgroup 切片（cgroup v2 时）
#   5. 打印 SSH 安全加固建议（不自动修改 sshd_config）
# ============================================================================
set -euo pipefail

TARGET_USER=""
WITH_MOSH=0
for arg in "$@"; do
  case "$arg" in
    --mosh) WITH_MOSH=1 ;;
    -*)     echo "未知参数: $arg" >&2; exit 1 ;;
    *)      TARGET_USER="$arg" ;;
  esac
done
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$USER}}"

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "❌ 用户 $TARGET_USER 不存在" >&2
  exit 1
fi

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "❌ 请用 sudo 运行本脚本（涉及 apt/sudoers/防火墙配置）" >&2
    exit 1
  fi
}

echo "==> GhostPanel 环境配置 | 目标用户: $TARGET_USER"
need_root

# ---------------------------------------------------------------- 1. 工具安装
echo "==> [1/5] 安装必要工具..."
PACKAGES=(tmux htop rsync xvfb)
# nvtop 在部分源中缺失，失败不阻塞
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq "${PACKAGES[@]}" || {
  echo "⚠️ 部分包安装失败，请检查软件源" >&2
}
apt-get install -y -qq nvtop 2>/dev/null || echo "⚠️ nvtop 不可用（跳过，不影响核心功能）"

if [[ "$WITH_MOSH" == "1" ]]; then
  apt-get install -y -qq mosh || echo "⚠️ mosh 安装失败"
fi

# ---------------------------------------------------------------- 2. sudo 免密
echo "==> [2/5] 配置最小化 sudo 免密..."
SUDOERS_TMP="$(mktemp)"
cat > "$SUDOERS_TMP" <<EOF
# GhostPanel 远程管理免密清单（方案文档 §4.1）
# 原则：只放行只读查询与明确列举的服务管理命令，绝不写 NOPASSWD: ALL
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl status *
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart nginx
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart docker
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/journalctl
EOF

if visudo -cf "$SUDOERS_TMP" >/dev/null; then
  install -m 440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/ghostpanel
  echo "    已安装 /etc/sudoers.d/ghostpanel（语法校验通过）"
else
  echo "❌ sudoers 语法校验失败，已放弃安装（不影响其余步骤）" >&2
fi
rm -f "$SUDOERS_TMP"

# ---------------------------------------------------------------- 3. 防火墙
echo "==> [3/5] 防火墙配置..."
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 22/tcp >/dev/null && echo "    已放行 SSH (22/tcp)"
  if [[ "$WITH_MOSH" == "1" ]]; then
    ufw allow 60000:61000/udp >/dev/null && echo "    已放行 Mosh (60000-61000/udp)"
  fi
else
  echo "    ufw 未启用，跳过（如使用其他防火墙请手动放行 22/tcp）"
fi

# ---------------------------------------------------------------- 4. cgroup 切片
echo "==> [4/5] 创建低优先级 cgroup 切片..."
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  # cgroup v2
  SLICE=/sys/fs/cgroup/system.slice/ghost-low.slice
  mkdir -p "$SLICE"
  echo "30000 100000" > "$SLICE/cpu.max" 2>/dev/null \
    && echo "    已创建 ghost-low.slice（CPU 封顶 30%）" \
    || echo "    ⚠️ cpu.max 写入失败（可能需要 systemd 管理，跳过）"
else
  echo "    非 cgroup v2 或无权限，跳过（任务舱将使用 systemd-run/nice 兜底）"
fi

# ---------------------------------------------------------------- 5. 安全建议
echo "==> [5/5] SSH 安全加固建议（不自动修改，请人工确认后编辑 /etc/ssh/sshd_config）:"
cat <<'EOF'
    ┌────────────────────────────────────────────────┐
    │ PasswordAuthentication no    # 仅密钥登录       │
    │ PermitRootLogin no           # 禁止 root 直登   │
    │ MaxAuthTries 3               # 限制尝试次数     │
    │ AllowUsers <你的用户名>       # 白名单用户       │
    └────────────────────────────────────────────────┘
    修改后执行: sudo systemctl restart ssh
    公网环境强烈建议再装 fail2ban: sudo apt install fail2ban
EOF

echo ""
echo "✅ GhostPanel 环境配置完成。"
echo "   手机端打开 GhostPanel → 添加工作站 → 填入本机 IP（$(hostname -I 2>/dev/null | awk '{print $1}')）与用户名 $TARGET_USER 即可。"
