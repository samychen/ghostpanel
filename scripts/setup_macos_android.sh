#!/usr/bin/env bash
#
# GhostPanel — macOS (Apple Silicon) → Flutter Android 开发环境一键搭建
#
# 安装内容：
#   1. JDK 17 (Eclipse Temurin, aarch64)  → ~/Library/Java/JavaVirtualMachines（用户域，无需 sudo）
#   2. Flutter SDK (stable, arm64)        → ~/develop/flutter
#   3. Android SDK + cmdline-tools        → ~/Library/Android/sdk
#   4. platforms;android-36 / build-tools;36.0.0 / platform-tools
#   5. [可选] emulator + arm64 系统镜像 + AVD（SKIP_AVD=1 时跳过，改用真机调试）
#   6. 修复 android/local.properties，写入 ~/.zshrc 环境变量
#
# 幂等：已安装的步骤会自动跳过。
#
# 用法：
#   bash scripts/setup_macos_android.sh              # 完整安装
#   SKIP_AVD=1 bash scripts/setup_macos_android.sh   # 跳过模拟器，用真机调试
#   USE_OFFICIAL=1 bash scripts/setup_macos_android.sh # 走官方源而非国内镜像
#
set -euo pipefail

FLUTTER_DIR="$HOME/develop/flutter"
ANDROID_SDK="$HOME/Library/Android/sdk"
JDK_DIR="$HOME/Library/Java/JavaVirtualMachines"
API_LEVEL=36
AVD_NAME="pixel7_api${API_LEVEL}"
SKIP_AVD="${SKIP_AVD:-0}"

# --------------------------------------------------------------- 镜像配置
if [ "${USE_OFFICIAL:-0}" = "1" ]; then
  : "${FLUTTER_GIT_URL:=https://github.com/flutter/flutter.git}"
  : "${PUB_HOSTED_URL:=https://pub.dev}"
  : "${FLUTTER_STORAGE_BASE_URL:=https://storage.googleapis.com}"
else
  # 国内镜像：清华 Flutter SDK 源 + pub / storage 镜像
  : "${FLUTTER_GIT_URL:=https://mirrors.tuna.tsinghua.edu.cn/git/flutter-sdk.git}"
  : "${PUB_HOSTED_URL:=https://pub.flutter-io.cn}"
  : "${FLUTTER_STORAGE_BASE_URL:=https://storage.flutter-io.cn}"
fi
export PUB_HOSTED_URL FLUTTER_STORAGE_BASE_URL

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32m✓ %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 1. JDK 17
info "1/6 安装 JDK 17"
if /usr/libexec/java_home -v 17 >/dev/null 2>&1; then
  JAVA_HOME_17="$(/usr/libexec/java_home -v 17)"
  ok "已存在 JDK 17"
else
  if [ -d "$JDK_DIR/temurin-17.jdk" ]; then
    JAVA_HOME_17="$JDK_DIR/temurin-17.jdk/Contents/Home"
    ok "已存在 JDK 17"
  else
    TMPJDK="$(mktemp -d)"
    # 华为云 OpenJDK 镜像：Adoptium 官方源在国内实测仅 ~8KB/s，5 分钟下不完 185MB
    curl -fsSL --max-time 1800 \
      "https://repo.huaweicloud.com/openjdk/17/openjdk-17_macos-aarch64_bin.tar.gz" \
      -o "$TMPJDK/jdk17.tar.gz"
    mkdir -p "$JDK_DIR"
    tar -xzf "$TMPJDK/jdk17.tar.gz" -C "$JDK_DIR"
    xattr -r -d com.apple.quarantine "$JDK_DIR"/*.jdk 2>/dev/null || true
    rm -rf "$TMPJDK"
    JDK_ANY="$(ls -d "$JDK_DIR"/*.jdk 2>/dev/null | head -1)"
    JAVA_HOME_17="$(/usr/libexec/java_home -v 17 2>/dev/null || echo "${JDK_ANY:-$JDK_DIR/jdk-17.jdk}/Contents/Home")"
    ok "JDK 17 已安装"
  fi
fi
[ -x "$JAVA_HOME_17/bin/java" ] || { echo "JDK 安装异常: $JAVA_HOME_17" >&2; exit 1; }
export JAVA_HOME="$JAVA_HOME_17"
ok "$("$JAVA_HOME_17/bin/java" -version 2>&1 | head -1)"

# ------------------------------------------------------------ 2. Flutter SDK
info "2/6 安装 Flutter SDK (stable) → $FLUTTER_DIR"
if [ -x "$FLUTTER_DIR/bin/flutter" ]; then
  ok "已存在，跳过"
else
  mkdir -p "$(dirname "$FLUTTER_DIR")"
  git clone --depth 1 -b stable "$FLUTTER_GIT_URL" "$FLUTTER_DIR"
  # shallow clone 缺 tag，flutter 无法识别自身版本，补拉当前 stable 的 tag
  (cd "$FLUTTER_DIR" && git fetch --tags --depth=1 origin stable 2>/dev/null || true)
  ok "下载完成"
fi
export PATH="$FLUTTER_DIR/bin:$PATH"
flutter config --no-analytics >/dev/null 2>&1 || true
flutter --version | head -1

# ------------------------------------------------------------ 3. Android SDK
info "3/6 安装 Android cmdline-tools"
mkdir -p "$ANDROID_SDK"
if [ -x "$ANDROID_SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  ok "已存在，跳过"
else
  if ! [ -d /opt/homebrew/share/android-commandlinetools ]; then
    brew install --cask android-commandlinetools || true
  fi
  SRC=/opt/homebrew/share/android-commandlinetools
  mkdir -p "$ANDROID_SDK/cmdline-tools"
  rm -rf "$ANDROID_SDK/cmdline-tools/latest"
  if [ -d "$SRC/cmdline-tools/latest" ]; then
    cp -R "$SRC/cmdline-tools/latest" "$ANDROID_SDK/cmdline-tools/latest"
  else
    cp -R "$SRC" "$ANDROID_SDK/cmdline-tools/latest"
  fi
  ok "已就位"
fi
export ANDROID_SDK_ROOT="$ANDROID_SDK"
export ANDROID_HOME="$ANDROID_SDK"
export PATH="$ANDROID_SDK/cmdline-tools/latest/bin:$ANDROID_SDK/platform-tools:$PATH"

# ------------------------------------------------------------ 4. SDK 组件
info "4/6 下载 Android SDK 组件（API $API_LEVEL）"
yes | sdkmanager --licenses >/dev/null 2>&1 || true
if [ "$SKIP_AVD" = "1" ]; then
  sdkmanager --install \
    "platform-tools" \
    "platforms;android-${API_LEVEL}" \
    "build-tools;${API_LEVEL}.0.0"
  ok "SDK 组件就绪（已跳过 emulator / 系统镜像）"
else
  sdkmanager --install \
    "platform-tools" \
    "platforms;android-${API_LEVEL}" \
    "build-tools;${API_LEVEL}.0.0" \
    "emulator" \
    "system-images;android-${API_LEVEL};google_apis;arm64-v8a"
  ok "SDK 组件就绪"
fi

# --------------------------------------------------- 4.5 Gradle 国内镜像
info "4.5/6 配置 Gradle 国内镜像"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 1) Gradle 发行版：services.gradle.org 国内约 9KB/s（200MB 需数小时），换华为云约 4MB/s
WRAPPER="$REPO_ROOT/android/gradle/wrapper/gradle-wrapper.properties"
if [ -f "$WRAPPER" ] && grep -q 'services.gradle.org' "$WRAPPER"; then
  sed -i '' 's|services.gradle.org/distributions/|mirrors.huaweicloud.com/gradle/|' "$WRAPPER"
  ok "gradle-wrapper.properties → 华为云"
else
  ok "gradle-wrapper 已是镜像，跳过"
fi

# 2) 依赖仓库：Maven Central / Plugin Portal / Google Maven → 阿里云
#    写成 init script，只影响本机，不改动项目仓库配置
mkdir -p "$HOME/.gradle/init.d"
cat > "$HOME/.gradle/init.d/mirrors.gradle" <<'GRADLE_EOF'
// 国内镜像加速（仅作用于本机 Gradle 构建，不修改任何项目仓库配置）
def applyMirror = { ArtifactRepository repo ->
    if (repo instanceof MavenArtifactRepository) {
        def url = repo.url.toString()
        if (url.startsWith('https://repo1.maven.org/maven2') ||
            url.startsWith('https://repo.maven.apache.org/maven2')) {
            repo.setUrl('https://maven.aliyun.com/repository/public')
        } else if (url.startsWith('https://plugins.gradle.org/m2')) {
            repo.setUrl('https://maven.aliyun.com/repository/gradle-plugin')
        } else if (url.startsWith('https://dl.google.com/dl/android/maven2')) {
            repo.setUrl('https://maven.aliyun.com/repository/google')
        }
    }
}

settingsEvaluated { settings ->
    try {
        settings.pluginManagement.repositories.all { applyMirror(it) }
    } catch (ignored) { }
    try {
        settings.dependencyResolutionManagement.repositories.all { applyMirror(it) }
    } catch (ignored) { }
}

allprojects {
    repositories.all { applyMirror(it) }
    buildscript.repositories.all { applyMirror(it) }
}
GRADLE_EOF
ok "已写入 ~/.gradle/init.d/mirrors.gradle"

# ------------------------------------------------------------ 5. 模拟器
if [ "$SKIP_AVD" = "1" ]; then
  info "5/6 跳过 AVD（SKIP_AVD=1），使用真机调试"
else
  info "5/6 创建 AVD: $AVD_NAME"
  if emulator -list-avds 2>/dev/null | grep -qx "$AVD_NAME"; then
    ok "已存在，跳过"
  else
    echo no | avdmanager create avd \
      -n "$AVD_NAME" \
      -k "system-images;android-${API_LEVEL};google_apis;arm64-v8a" \
      -d "pixel_7" --force >/dev/null 2>&1 || true
    ok "AVD 已创建"
  fi
fi

# ------------------------------------------------------------ 6. 项目配置
info "6/6 配置项目"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# local.properties 里的 flutter.sdk 指向真实路径（该文件已在 .gitignore 中）
cat > "$REPO_ROOT/android/local.properties" <<EOF
flutter.sdk=$FLUTTER_DIR
sdk.dir=$ANDROID_SDK
EOF
ok "android/local.properties 已重写"

# 写入 shell 环境变量（幂等：先清理旧的 GhostPanel 标记块）
ZSHRC="$HOME/.zshrc"
touch "$ZSHRC"
cp "$ZSHRC" "$ZSHRC.ghostpanel.bak"
sed -i '' '/# >>> ghostpanel flutter >>>/,/# <<< ghostpanel flutter <<</d' "$ZSHRC"
cat >> "$ZSHRC" <<EOF
# >>> ghostpanel flutter >>>
export JAVA_HOME="$JAVA_HOME_17"
export ANDROID_HOME="$ANDROID_SDK"
export ANDROID_SDK_ROOT="$ANDROID_SDK"
export PUB_HOSTED_URL="$PUB_HOSTED_URL"
export FLUTTER_STORAGE_BASE_URL="$FLUTTER_STORAGE_BASE_URL"
export PATH="\$JAVA_HOME/bin:$FLUTTER_DIR/bin:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/emulator:\$PATH"
# <<< ghostpanel flutter <<<
EOF
ok "已写入 ~/.zshrc（备份于 ~/.zshrc.ghostpanel.bak）"

# 让 Flutter 记住 SDK / JDK 位置
flutter config --android-sdk "$ANDROID_SDK" --jdk-dir "$JAVA_HOME_17" >/dev/null 2>&1 || true

info "拉取 Dart 依赖 (flutter pub get)"
(cd "$REPO_ROOT" && flutter pub get)

info "环境自检"
flutter doctor -v

if [ "$SKIP_AVD" = "1" ]; then
  cat <<EOF

完成（未装模拟器）。下一步：

  source ~/.zshrc
  cd $REPO_ROOT

  # 真机：手机开启「开发者选项 → USB 调试」，用 USB 连上后
  adb devices                 # 应看到你的设备（首次需在手机上点「允许调试」）
  flutter run

  # 无线调试（Android 11+，免数据线）：
  # 手机：开发者选项 → 无线调试 → 使用配对码配对设备
  # adb pair <手机IP>:<配对端口>    然后  adb connect <手机IP>:<连接端口>

  # 需要模拟器时再补装：
  # sdkmanager "emulator" "system-images;android-${API_LEVEL};google_apis;arm64-v8a"
  # avdmanager create avd -n $AVD_NAME -k "system-images;android-${API_LEVEL};google_apis;arm64-v8a" -d pixel_7

EOF
else
  cat <<EOF

完成。下一步：

  source ~/.zshrc
  cd $REPO_ROOT
  emulator -avd $AVD_NAME &
  flutter run

EOF
fi
