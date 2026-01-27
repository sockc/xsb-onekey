#!/usr/bin/env bash
set -euo pipefail

REPO_DEFAULT="sockc/xsb-onekey"
BRANCH="main"
VERSION=""
MIRROR="raw"          # raw | ghproxy
BIN="/usr/local/sbin/xsb"
SCRIPT="/usr/local/share/xsb/xsb-menu.sh"
FORCE=0
AUTO_MENU=0

usage(){
  cat <<'EOF'
XSB OneKey Installer

Usage:
  install.sh [--force] [--menu] [--branch main] [--version <tag>] [--mirror raw|ghproxy]

Options:
  --force              overwrite existing installed files
  --menu               auto launch menu after install (interactive only)
  --branch <name>      branch to install from (default: main)
  --version <tag>      install from a git tag (overrides branch)
  --mirror raw|ghproxy raw.githubusercontent.com or ghproxy
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift;;
    --menu) AUTO_MENU=1; shift;;
    --branch) BRANCH="${2:-main}"; shift 2;;
    --version) VERSION="${2:-}"; shift 2;;
    --mirror) MIRROR="${2:-raw}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) shift;;
  esac
done

ref="${BRANCH}"
[[ -n "${VERSION}" ]] && ref="${VERSION}"

raw_base(){
  local path="$1"
  case "$MIRROR" in
    ghproxy)
      # ghproxy 会代理 raw
      echo "https://ghproxy.com/https://raw.githubusercontent.com/${REPO_DEFAULT}/${ref}/${path}"
      ;;
    *)
      echo "https://raw.githubusercontent.com/${REPO_DEFAULT}/${ref}/${path}"
      ;;
  esac
}

need_root(){
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "请使用 root 运行" >&2
    exit 1
  fi
}

detect_os(){
  # OpenWrt
  if [[ -f /etc/openwrt_release ]] || grep -qi 'openwrt' /etc/os-release 2>/dev/null; then
    echo "openwrt"
    return 0
  fi
  # Alpine
  if grep -qi '^ID=alpine' /etc/os-release 2>/dev/null; then
    echo "alpine"
    return 0
  fi
  echo "linux"
}

main(){
  need_root
  local os
  os="$(detect_os)"

  echo "ℹ️  安装参数："
  echo "  REPO   = ${REPO_DEFAULT}"
  echo "  REF    = ${ref}"
  echo "  MIRROR = ${MIRROR}"
  echo "  FORCE  = ${FORCE}"
  echo "  MENU   = ${AUTO_MENU}"
  echo "  OS     = ${os}"
  echo

  # OpenWrt Tiny 分支
  if [[ "$os" == "openwrt" ]]; then
    echo "🧩 检测到 OpenWrt → 使用 Tiny 安装器"
    local url; url="$(raw_base "extras/openwrt-tiny.sh")"
    sh -c "umask 022; mkdir -p /tmp/xsb && cd /tmp/xsb && wget -qO openwrt-tiny.sh '$url' || curl -fsSL '$url' -o openwrt-tiny.sh"
    chmod +x /tmp/xsb/openwrt-tiny.sh
    exec /tmp/xsb/openwrt-tiny.sh
  fi

  # Alpine Lite 分支
  if [[ "$os" == "alpine" ]]; then
    echo "🧩 检测到 Alpine → 使用 Lite 安装器（最小化 + OpenRC）"
    local url; url="$(raw_base "extras/alpine-lite.sh")"
    sh -c "umask 022; mkdir -p /tmp/xsb && cd /tmp/xsb && wget -qO alpine-lite.sh '$url' || curl -fsSL '$url' -o alpine-lite.sh"
    chmod +x /tmp/xsb/alpine-lite.sh
    exec /tmp/xsb/alpine-lite.sh
  fi

  # 其他 Linux：Full 安装（保持你现有逻辑）
  mkdir -p "$(dirname "$SCRIPT")"
  mkdir -p "$(dirname "$BIN")"

  local menu_url; menu_url="$(raw_base "xsb-menu.sh")"
  echo "ℹ️  下载：$menu_url"

  if [[ -f "$SCRIPT" && "$FORCE" -ne 1 ]]; then
    echo "✅ 已存在：$SCRIPT（未使用 --force，不覆盖）"
  else
    curl -fsSL "$menu_url" -o "$SCRIPT"
    chmod +x "$SCRIPT"
    echo "✅ 脚本已就位：$SCRIPT"
  fi

  # 安装 xsb launcher
  cat > "$BIN" <<EOF
#!/usr/bin/env bash
exec bash "$SCRIPT"
EOF
  chmod +x "$BIN"

  echo "✅ 安装完成！现在运行：xsb"
  echo

  # Auto launch menu
  if [[ "$AUTO_MENU" == "1" ]] && [[ -t 0 && -t 1 ]]; then
    exec "$BIN"
  fi
}

main "$@"
