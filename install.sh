#!/usr/bin/env bash
# =========================================================
# XSB Professional Installer
# - 支持：branch / tag(version) / mirror / force / uninstall
# - 标准目录：
#   - 入口命令：/usr/local/sbin/xsb
#   - 脚本本体：/usr/local/share/xsb/xsb-menu.sh
# - 依赖：curl（必须），bash（系统自带）
# =========================================================

set -euo pipefail

# ---------------------------
#
# ---------------------------
DEFAULT_REPO="vinchi008/xsb-onekey"  
DEFAULT_BRANCH="main"               

# ---------------------------
# 默认安装路径（可通过参数覆盖）
# ---------------------------
INSTALL_BIN="${INSTALL_BIN:-/usr/local/sbin/xsb}"
SCRIPT_DIR="${SCRIPT_DIR:-/usr/local/share/xsb}"
SCRIPT_PATH="${SCRIPT_PATH:-${SCRIPT_DIR}/xsb-menu.sh}"
META_DIR="${META_DIR:-/var/lib/xsb-installer}"
META_FILE="${META_FILE:-${META_DIR}/install.meta}"

# ---------------------------
# 可选：镜像加速（适合多国 VPS）
# raw: 直连 raw.githubusercontent.com
# ghproxy: https://ghproxy.com/
# jsdelivr: https://cdn.jsdelivr.net/gh/
# ---------------------------
MIRROR="${MIRROR:-raw}" # raw | ghproxy | jsdelivr

# ---------------------------
# 安装源控制：
#   --branch main  （默认）
#   --version v1.0.0  （使用 tag）
# ---------------------------
REPO="${REPO:-$DEFAULT_REPO}"
BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
VERSION="${VERSION:-}"  # tag，例如 v1.0.0
FORCE="${FORCE:-0}"
UNINSTALL="${UNINSTALL:-0}"

# ---------------------------
# 输出颜色
# ---------------------------
RED="\033[31m"; GRN="\033[32m"; YLW="\033[33m"; CYA="\033[36m"; RST="\033[0m"
ok(){ echo -e "${GRN}✅ $*${RST}"; }
info(){ echo -e "${CYA}ℹ️  $*${RST}"; }
warn(){ echo -e "${YLW}⚠️  $*${RST}"; }
err(){ echo -e "${RED}❌ $*${RST}"; }

usage() {
  cat <<EOF
XSB Installer

用法:
  bash <(curl -fsSL <RAW_URL>/install.sh) [options]

选项:
  --repo <user/repo>        指定仓库（默认: ${DEFAULT_REPO})
  --branch <name>           指定分支（默认: ${DEFAULT_BRANCH})
  --version <tag>           指定 tag 版本（例如 v1.0.0）。指定后会忽略 --branch
  --mirror <raw|ghproxy|jsdelivr>  选择镜像（默认: raw）
  --bin <path>              入口命令路径（默认: ${INSTALL_BIN})
  --dir <path>              脚本目录（默认: ${SCRIPT_DIR})
  --force                   强制覆盖更新
  --uninstall               卸载 xsb（不会动 /etc/xray /etc/sing-box /var/lib/xsb 数据）
  -h, --help                显示帮助

示例:
  # 默认安装（main 分支）
  bash <(curl -fsSL https://raw.githubusercontent.com/${DEFAULT_REPO}/${DEFAULT_BRANCH}/install.sh)

  # 使用 ghproxy 加速
  MIRROR=ghproxy bash <(curl -fsSL https://raw.githubusercontent.com/${DEFAULT_REPO}/${DEFAULT_BRANCH}/install.sh)

  # 安装指定 tag
  bash <(curl -fsSL https://raw.githubusercontent.com/${DEFAULT_REPO}/${DEFAULT_BRANCH}/install.sh) --version v1.0.0

EOF
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "请用 root 执行：sudo -i"
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "缺少依赖：$1"
    exit 1
  }
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) REPO="$2"; shift 2 ;;
      --branch) BRANCH="$2"; shift 2 ;;
      --version) VERSION="$2"; shift 2 ;;
      --mirror) MIRROR="$2"; shift 2 ;;
      --bin) INSTALL_BIN="$2"; shift 2 ;;
      --dir)
        SCRIPT_DIR="$2"
        SCRIPT_PATH="${SCRIPT_DIR}/xsb-menu.sh"
        shift 2
        ;;
      --force) FORCE="1"; shift ;;
      --uninstall) UNINSTALL="1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *)
        warn "未知参数：$1"
        usage
        exit 1
        ;;
    esac
  done
}

build_url() {
  # 构造 xsb-menu.sh 下载地址（支持镜像）
  # 优先版本 tag，其次分支 branch
  local ref
  if [[ -n "$VERSION" ]]; then ref="$VERSION"; else ref="$BRANCH"; fi

  case "$MIRROR" in
    raw)
      echo "https://raw.githubusercontent.com/${REPO}/${ref}/xsb-menu.sh"
      ;;
    ghproxy)
      echo "https://ghproxy.com/https://raw.githubusercontent.com/${REPO}/${ref}/xsb-menu.sh"
      ;;
    jsdelivr)
      # jsdelivr 走 /gh/user/repo@ref/path
      echo "https://cdn.jsdelivr.net/gh/${REPO}@${ref}/xsb-menu.sh"
      ;;
    *)
      err "不支持的 mirror：$MIRROR（raw/ghproxy/jsdelivr）"
      exit 1
      ;;
  esac
}

safe_mkdir() {
  mkdir -p "$1"
}

write_wrapper() {
  safe_mkdir "$(dirname "$INSTALL_BIN")"
  cat >"$INSTALL_BIN" <<EOF
#!/usr/bin/env bash
exec bash "${SCRIPT_PATH}" "\$@"
EOF
  chmod +x "$INSTALL_BIN"
}

save_meta() {
  safe_mkdir "$META_DIR"
  cat >"$META_FILE" <<EOF
REPO=${REPO}
BRANCH=${BRANCH}
VERSION=${VERSION}
MIRROR=${MIRROR}
INSTALL_BIN=${INSTALL_BIN}
SCRIPT_PATH=${SCRIPT_PATH}
EOF
}

read_script_version() {
  # 从 xsb-menu.sh 里读 VERSION=...（如果你还没加也没关系）
  if [[ -f "$SCRIPT_PATH" ]]; then
    local v
    v="$(grep -E '^[[:space:]]*VERSION=' "$SCRIPT_PATH" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
    echo "${v:-unknown}"
  else
    echo "none"
  fi
}

do_uninstall() {
  info "卸载 xsb 入口与脚本本体（不删除节点配置数据）..."
  rm -f "$INSTALL_BIN" || true
  rm -rf "$SCRIPT_DIR" || true
  rm -rf "$META_DIR" || true
  ok "卸载完成"
  echo
  echo "保留数据目录（未删除）："
  echo "  - /etc/xray"
  echo "  - /etc/sing-box"
  echo "  - /var/lib/xsb"
}

download_script() {
  local url
  url="$(build_url)"
  info "下载：$url"
  safe_mkdir "$SCRIPT_DIR"

  # 下载到临时文件，成功后原子替换
  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL "$url" -o "$tmp"; then
    err "下载失败：$url"
    echo "排查建议："
    echo "  1) 仓库是否 Public？"
    echo "  2) xsb-menu.sh 是否存在于对应分支/tag？"
    echo "  3) mirror 是否可用：--mirror raw/ghproxy/jsdelivr"
    exit 1
  fi

  chmod +x "$tmp"

  # 如果已有脚本且非 force，则提示并退出（避免误覆盖）
  if [[ -f "$SCRIPT_PATH" && "$FORCE" != "1" ]]; then
    warn "检测到已安装：$SCRIPT_PATH"
    echo "当前版本：$(read_script_version)"
    echo "如需覆盖更新请加 --force"
    rm -f "$tmp"
    return 0
  fi

  mv "$tmp" "$SCRIPT_PATH"
  ok "脚本已就位：$SCRIPT_PATH"
}

main() {
  parse_args "$@"
  need_root
  need_cmd curl
  need_cmd bash

  if [[ "$UNINSTALL" == "1" ]]; then
    do_uninstall
    exit 0
  fi

  info "安装参数："
  echo "  REPO   = $REPO"
  echo "  BRANCH = $BRANCH"
  echo "  VERSION= ${VERSION:-<none>}"
  echo "  MIRROR = $MIRROR"
  echo "  BIN    = $INSTALL_BIN"
  echo "  SCRIPT = $SCRIPT_PATH"
  echo

  download_script
  write_wrapper
  save_meta

  ok "安装完成！现在运行：xsb"
  echo "（如提示找不到 xsb，请重新打开终端或执行：hash -r）"
  echo
  info "已安装脚本版本：$(read_script_version)"
}

main "$@"
