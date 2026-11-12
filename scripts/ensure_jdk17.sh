#!/usr/bin/env bash
# 确保构建用 JDK 17。
#
# 为什么必须 JDK 17：Flutter/Gradle 传给 JVM 的 `--enable-native-access=ALL-UNNAMED`
# 是 JDK 17+ 才认识的参数。若 JAVA_HOME 指向 JDK 8/11，JVM 启动即报
# "Unrecognized option: --enable-native-access" 然后构建失败。
#
# 用法：在任何构建脚本开头 `source "$(dirname ...)/ensure_jdk17.sh"`，
# 或直接 `bash scripts/ensure_jdk17.sh` 输出 JAVA_HOME。
ensure_jdk17() {
  # 1) 当前 JAVA_HOME 已是 17+ 则直接用
  if [ -n "${JAVA_HOME:-}" ] && "$JAVA_HOME/bin/java" -version 2>&1 | grep -qE 'version "1[7-9]|version "[2-9][0-9]'; then
    return 0
  fi
  # 2) macOS：用 java_home 找 17
  if command -v /usr/libexec/java_home >/dev/null 2>&1; then
    local jh
    jh="$(/usr/libexec/java_home -v 17 2>/dev/null)" || jh=""
    if [ -n "$jh" ] && [ -x "$jh/bin/java" ]; then
      export JAVA_HOME="$jh"
      return 0
    fi
  fi
  # 3) 常见 Linux 路径兜底
  for d in /usr/lib/jvm/java-17-openjdk* /usr/lib/jvm/jdk-17* /opt/java/jdk-17*; do
    if [ -x "$d/bin/java" ]; then
      export JAVA_HOME="$d"
      return 0
    fi
  done
  echo "构建失败：需要 JDK 17，但未检测到。请安装 JDK 17（如 brew install openjdk@17）后重试。" >&2
  return 1
}

ensure_jdk17 "$@"
