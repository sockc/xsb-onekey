#!/usr/bin/env bash
# =========================================================
# XSB OneKey Manager (Xray + sing-box) - Full Fix Pack
# Protocols:
#   - VLESS + Reality (Xray)
#   - VMess + WS (noTLS) (Xray)
#   - VMess + TCP + HTTP (Xray)
#   - TUIC (sing-box)
#   - Hysteria2 (sing-box)
#
# Fixes in v1.0.2:
#   1) jq 兼容性：不再使用三元+对象字面量导致 compile error
#   2) Reality privateKey 为空导致 xray 崩溃：改为稳健解析 + 空值校验
#   3) Reality dest 改成 SNI:443
#   4) HY2 输出标准 hysteria2:// 链接 + QR
#   5) TUIC 输出 sing-box JSON(必可用) + tuic:// 分享链接(部分客户端可用)
# =========================================================

set -euo pipefail
trap 'echo -e "\n❌ 脚本出错：第 $LINENO 行（退出码=$?）\n    你可以把这一屏发给我定位\n" >&2' ERR
safe_run(){ "$@" || return 1; }

VERSION="1.0.2"

# --------- Paths ----------
XRAY_BIN="/usr/local/bin/xray"
SB_BIN="/usr/local/bin/sing-box"
XRAY_CFG="/etc/xray/config.json"
SB_CFG="/etc/sing-box/config.json"

META_DIR="/var/lib/xsb"
META_JSON="$META_DIR/meta.json"

CERT_DIR="/etc/ssl/xsb"
TUIC_CRT="$CERT_DIR/tuic.crt"
TUIC_KEY="$CERT_DIR/tuic.key"
HY2_CRT="$CERT_DIR/hy2.crt"
HY2_KEY="$CERT_DIR/hy2.key"

# --------- UI ----------
RED="\033[31m"; GRN="\033[32m"; YLW="\033[33m"; BLU="\033[34m"; CYA="\033[36m"; RST="\033[0m"
ok(){ echo -e "${GRN}✅ $*${RST}"; }
warn(){ echo -e "${YLW}⚠️  $*${RST}"; }
err(){ echo -e "${RED}❌ $*${RST}"; }
info(){ echo -e "${CYA}ℹ️  $*${RST}"; }

need_root(){
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "请使用 root 运行：sudo -i"
    exit 1
  fi
}

have(){ command -v "$1" >/dev/null 2>&1; }

rand_hex(){ openssl rand -hex "${1:-8}"; }
rand_uuid(){
  if have uuidgen; then uuidgen; else
    python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
  fi
}

# --------- OS/ARCH ----------
OS_FAMILY=""
PKG=""
detect_os(){
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    local id="${ID:-}"
    local like="${ID_LIKE:-}"
    if [[ "$id" =~ (debian|ubuntu) ]] || [[ "$like" =~ (debian|ubuntu) ]]; then
      OS_FAMILY="debian"
      PKG="apt"
    elif [[ "$id" =~ (centos|rhel|rocky|almalinux|fedora) ]] || [[ "$like" =~ (rhel|fedora|centos) ]]; then
      OS_FAMILY="rhel"
      if have dnf; then PKG="dnf"; else PKG="yum"; fi
    else
      OS_FAMILY="unknown"
    fi
  fi
}

ARCH=""
detect_arch(){
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv7) ARCH="armv7" ;;
    *) ARCH="$m"; warn "未识别架构：$m" ;;
  esac
}

# --------- Deps ----------
install_deps(){
  detect_os
  local common=(curl jq openssl tar unzip)
  if [[ "$PKG" == "apt" ]]; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${common[@]}" ca-certificates coreutils
    apt-get install -y uuid-runtime >/dev/null 2>&1 || true
    apt-get install -y qrencode >/dev/null 2>&1 || true
    apt-get install -y netcat-openbsd >/dev/null 2>&1 || true
  elif [[ "$PKG" == "yum" || "$PKG" == "dnf" ]]; then
    $PKG install -y "${common[@]}" ca-certificates coreutils
    $PKG install -y util-linux >/dev/null 2>&1 || true
    $PKG install -y qrencode >/dev/null 2>&1 || true
    $PKG install -y nc >/dev/null 2>&1 || true
  else
    warn "未知系统，跳过自动装依赖。请确保存在：curl jq openssl tar unzip"
  fi
  ok "依赖检查完成"
}

# --------- GitHub Release helper ----------
gh_latest_asset_url(){
  local repo="$1"
  local key="$2"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | jq -r --arg k "$key" '.assets[] | select(.name|test($k)) | .browser_download_url' \
    | head -n1
}

download_and_install_xray(){
  detect_arch
  info "下载 Xray 最新版（$ARCH）..."
  local key=""
  case "$ARCH" in
    amd64) key="linux-64.zip" ;;
    arm64) key="linux-arm64-v8a.zip" ;;
    armv7) key="linux-arm32-v7a.zip" ;;
    *) err "不支持架构：$ARCH"; return 1 ;;
  esac

  local url
  url="$(gh_latest_asset_url "XTLS/Xray-core" "$key")"
  [[ -n "$url" ]] || { err "获取 Xray 下载链接失败"; return 1; }

  local tmp="/tmp/xray.zip"
  curl -fL "$url" -o "$tmp"
  rm -rf /tmp/xray_unz && mkdir -p /tmp/xray_unz
  unzip -qo "$tmp" -d /tmp/xray_unz
  install -m 755 /tmp/xray_unz/xray "$XRAY_BIN"
  ok "Xray 安装完成：$XRAY_BIN"
}

download_and_install_singbox(){
  detect_arch
  info "下载 sing-box 最新版（$ARCH）..."
  local key=""
  case "$ARCH" in
    amd64) key="linux-amd64.tar.gz" ;;
    arm64) key="linux-arm64.tar.gz" ;;
    armv7) key="linux-armv7.tar.gz" ;;
    *) err "不支持架构：$ARCH"; return 1 ;;
  esac

  local url
  url="$(gh_latest_asset_url "SagerNet/sing-box" "$key")"
  [[ -n "$url" ]] || { err "获取 sing-box 下载链接失败"; return 1; }

  local tmp="/tmp/singbox.tgz"
  curl -fL "$url" -o "$tmp"
  rm -rf /tmp/sb_unz && mkdir -p /tmp/sb_unz
  tar -xzf "$tmp" -C /tmp/sb_unz
  local bin
  bin="$(find /tmp/sb_unz -type f -name sing-box | head -n1)"
  [[ -n "$bin" ]] || { err "解压后未找到 sing-box"; return 1; }
  install -m 755 "$bin" "$SB_BIN"
  ok "sing-box 安装完成：$SB_BIN"
}

# --------- systemd ----------
ensure_systemd(){
  if ! have systemctl; then
    err "系统没有 systemd（systemctl 不存在）"
    exit 1
  fi
}

write_systemd_xray(){
  cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service (XSB Manager)
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${XRAY_CFG}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

write_systemd_singbox(){
  cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Service (XSB Manager)
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${SB_BIN} run -c ${SB_CFG}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

reload_systemd(){ systemctl daemon-reload; }
svc_enable_start(){ systemctl enable --now "$1" >/dev/null 2>&1 || true; systemctl restart "$1" >/dev/null 2>&1 || true; }
svc_restart(){ systemctl restart "$1" >/dev/null 2>&1 || true; }
svc_status(){ systemctl is-active "$1" >/dev/null 2>&1 && echo "active" || echo "inactive"; }

# --------- Ports ----------
open_port(){
  local port="$1" proto="$2"
  if have ufw; then
    ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
    return 0
  fi
  if have firewall-cmd; then
    firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    return 0
  fi
  if have iptables; then
    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 \
      || iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
    if have netfilter-persistent; then netfilter-persistent save >/dev/null 2>&1 || true; fi
    return 0
  fi
  warn "未检测到 ufw/firewalld/iptables（请确认云安全组已放行 ${port}/${proto}）"
}

# =========================
# Firewall (UFW) - XSB Suite
# =========================

fw_install_ufw(){
  if command -v ufw >/dev/null 2>&1; then return 0; fi
  info "正在安装 UFW..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y ufw >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ufw >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ufw >/dev/null 2>&1
  else
    err "无法自动安装 ufw（请手动安装）"
    return 1
  fi
  ok "UFW 已安装"
}

detect_ssh_port(){
  local p=""
  if [[ -f /etc/ssh/sshd_config ]]; then
    p="$(grep -E '^\s*Port\s+' /etc/ssh/sshd_config | tail -n1 | awk '{print $2}' | tr -d '\r')"
  fi
  if [[ -z "$p" ]]; then
    p="$(ss -lntp 2>/dev/null | awk '/sshd/ {print $4}' | tail -n1 | awk -F: '{print $NF}' | tr -d '\r')"
  fi
  [[ -n "$p" ]] || p="22"
  echo "$p"
}

fw_is_enabled(){
  command -v ufw >/dev/null 2>&1 || return 1
  ufw status 2>/dev/null | head -n1 | grep -qi "Status: active"
}

fw_enable(){
  fw_install_ufw || return 1
  info "启用 UFW..."
  ufw --force enable >/dev/null 2>&1 || true
  ok "UFW 已启用 ✅"
}

fw_disable(){
  if ! command -v ufw >/dev/null 2>&1; then
    warn "未安装 ufw"
    return 0
  fi
  info "关闭 UFW..."
  ufw --force disable >/dev/null 2>&1 || true
  ok "UFW 已关闭 ✅"
}

fw_reset_safe(){
  fw_install_ufw || return 1
  local ssh_port
  ssh_port="$(detect_ssh_port)"

  warn "将重置 UFW 规则（reset）"
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true

  # 永远先放行 SSH，避免锁门外
  ufw allow "${ssh_port}/tcp" >/dev/null 2>&1 || true
  ok "已重置并放行 SSH：${ssh_port}/tcp"
}

fw_allow(){
  local port="$1" proto="$2"
  [[ -n "$port" && -n "$proto" ]] || return 1
  ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
  ok "已放行：${port}/${proto}"
}

fw_deny(){
  local port="$1" proto="$2"
  [[ -n "$port" && -n "$proto" ]] || return 1
  # deny 会新增拒绝规则；delete allow 才是真正删
  ufw deny "${port}/${proto}" >/dev/null 2>&1 || true
  ok "已拒绝：${port}/${proto}"
}

fw_delete_rule(){
  # 删除规则更“干净”，不叠加 deny
  local port="$1" proto="$2" action="${3:-allow}"
  [[ -n "$port" && -n "$proto" ]] || return 1
  ufw --force delete "$action" "${port}/${proto}" >/dev/null 2>&1 || true
  ok "已删除规则：delete ${action} ${port}/${proto}"
}

fw_list_allowed_ports(){
  if ! command -v ufw >/dev/null 2>&1; then
    warn "未安装 ufw"
    return 0
  fi

  echo -e "${BLU}--- 当前已放行（简表）---${RST}"
  # 解析示例：27352/tcp ALLOW IN Anywhere
  ufw status numbered 2>/dev/null \
    | sed -n 's/^\[\([0-9]\+\)\][[:space:]]\+\([^ ]\+\)[[:space:]]\+ALLOW IN.*$/\1) \2/p' \
    | sort -V || true
  echo
  echo -e "${CYA}提示：想看全部细节用 “详细状态”${RST}"
}

fw_status_verbose(){
  if ! command -v ufw >/dev/null 2>&1; then
    warn "未安装 ufw"
    return 0
  fi
  ufw status verbose || true
}

fw_sync_from_meta(){
  fw_install_ufw || return 1
  init_meta

  # 不强制 reset：只做“增量放行”
  local ssh_port
  ssh_port="$(detect_ssh_port)"

  # 如果 UFW 还没启用，先设置默认策略并启用
  if ! fw_is_enabled; then
    info "UFW 未启用，设置默认策略并启用"
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true
  fi

  # 保底：放行 SSH
  ufw allow "${ssh_port}/tcp" >/dev/null 2>&1 || true

  info "同步放行 Xray 入站端口（TCP）..."
  jq -r '.xray_inbounds[]? | "\(.port)\t\(.proto)\t\(.name)"' "$META_JSON" 2>/dev/null \
  | while IFS=$'\t' read -r port proto name; do
      ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    done

  info "同步放行 sing-box 入站端口（按协议）..."
  jq -r '.singbox_inbounds[]? | "\(.port)\t\(.proto)\t\(.name)"' "$META_JSON" 2>/dev/null \
  | while IFS=$'\t' read -r port proto name; do
      case "$proto" in
        tuic|hy2) ufw allow "${port}/udp" >/dev/null 2>&1 || true ;;
        *)        ufw allow "${port}/tcp" >/dev/null 2>&1 || true ;;
      esac
    done

  ok "已同步放行：SSH + 所有节点端口 ✅"
}

fw_custom_allow_menu(){
  fw_install_ufw || return 1
  read -rp "输入端口（例如 443 或 10000:20000）： " port
  [[ -n "$port" ]] || { warn "未输入端口"; return 0; }

  echo "选择协议："
  echo "1) TCP"
  echo "2) UDP"
  echo "3) TCP+UDP"
  read -rp "选择 [1-3]: " p
  case "$p" in
    1) fw_allow "$port" "tcp" ;;
    2) fw_allow "$port" "udp" ;;
    3) fw_allow "$port" "tcp"; fw_allow "$port" "udp" ;;
    *) warn "无效选择" ;;
  esac
}

fw_custom_close_menu(){
  fw_install_ufw || return 1
  read -rp "输入端口（例如 443 或 10000:20000）： " port
  [[ -n "$port" ]] || { warn "未输入端口"; return 0; }

  echo "怎么关闭："
  echo "1) 删除 allow 规则（推荐）"
  echo "2) 添加 deny 规则（不推荐，规则会叠加）"
  read -rp "选择 [1-2]: " how

  echo "选择协议："
  echo "1) TCP"
  echo "2) UDP"
  echo "3) TCP+UDP"
  read -rp "选择 [1-3]: " p

  if [[ "$how" == "1" ]]; then
    case "$p" in
      1) fw_delete_rule "$port" "tcp" "allow" ;;
      2) fw_delete_rule "$port" "udp" "allow" ;;
      3) fw_delete_rule "$port" "tcp" "allow"; fw_delete_rule "$port" "udp" "allow" ;;
      *) warn "无效选择" ;;
    esac
  else
    case "$p" in
      1) fw_deny "$port" "tcp" ;;
      2) fw_deny "$port" "udp" ;;
      3) fw_deny "$port" "tcp"; fw_deny "$port" "udp" ;;
      *) warn "无效选择" ;;
    esac
  fi
}
# =========================
# Dokodemo-door Manager (Xray)
# =========================
doko_list(){
  echo -e "${BLU}--- dokodemo-door 转发规则 ---${RST}"
  jq -r '
    .doko_rules[]? |
    "\(.tag)\t\(.enabled)\t\(.listen):\(.listen_port)\t->\t\(.target_addr):\(.target_port)\t\(.network)\tout=\(.outbound)"
  ' "$META_JSON" 2>/dev/null || true
}

doko_show_one(){
  local tag="$1"
  jq -r --arg t "$tag" '.doko_rules[]? | select(.tag==$t)' "$META_JSON" | jq . || true
}

doko_meta_set_enabled(){
  local tag="$1" val="$2"
  tmp="$(mktemp)"
  jq --arg t "$tag" --argjson v "$val" '
    .doko_rules |= map(if .tag==$t then .enabled=$v else . end)
  ' "$META_JSON" >"$tmp" && mv "$tmp" "$META_JSON"
}

doko_meta_remove(){
  local tag="$1"
  tmp="$(mktemp)"
  jq --arg t "$tag" '
    .doko_rules |= map(select(.tag != $t))
  ' "$META_JSON" >"$tmp" && mv "$tmp" "$META_JSON"
}

doko_add_wizard(){
  ensure_xray_routing

  local name listen lport addr dport net outbound shost sport tag
  read -rp "规则备注（例如 doko-10065，可空自动生成）: " name
  read -rp "监听地址（默认 0.0.0.0；强烈建议内网用 127.0.0.1）: " listen
  listen="${listen:-0.0.0.0}"

  read -rp "监听端口（例如 12345）: " lport
  [[ -n "$lport" ]] || { warn "未输入监听端口"; return 1; }

  read -rp "目标地址（例如 12.34.56.789）: " addr
  [[ -n "$addr" ]] || { warn "未输入目标地址"; return 1; }

  read -rp "目标端口（例如 12345）: " dport
  [[ -n "$dport" ]] || { warn "未输入目标端口"; return 1; }

  echo "网络："
  echo "1) tcp"
  echo "2) udp"
  echo "3) tcp+udp"
  read -rp "选择 [1-3]（默认3）: " c
  case "${c:-3}" in
    1) net="tcp" ;;
    2) net="udp" ;;
    *) net="tcp,udp" ;;
  esac

  echo "转发出站："
  echo "1) direct（直连转发）"
  echo "2) socks5（走本机 SOCKS5 上游，比如 mihomo 127.0.0.1:7890）"
  read -rp "选择 [1-2]（默认1）: " o
  case "${o:-1}" in
    2)
      outbound="doko-socks"
      read -rp "SOCKS5 地址（默认 127.0.0.1）: " shost
      shost="${shost:-127.0.0.1}"
      read -rp "SOCKS5 端口（默认 7890）: " sport
      sport="${sport:-7890}"
      ;;
    *)
      outbound="direct"
      shost=""
      sport=""
      ;;
  esac

  # tag：固定用 dokodemo inbound tag
  if [[ -n "$name" ]]; then
    tag="$(echo "$name" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')"
  fi
  [[ -n "$tag" ]] || tag="doko-${lport}"

  # meta 写入
  tmp="$(mktemp)"
  jq --arg tag "$tag" \
     --arg listen "$listen" \
     --argjson lp "$lport" \
     --arg addr "$addr" \
     --argjson dp "$dport" \
     --arg net "$net" \
     --arg out "$outbound" \
     --arg sh "$shost" \
     --argjson sp "${sport:-0}" \
  '
    .doko_rules += [{
      "tag":$tag,
      "enabled":true,
      "listen":$listen,
      "listen_port":$lp,
      "target_addr":$addr,
      "target_port":$dp,
      "network":$net,
      "outbound":$out,
      "socks_host": (if $out=="doko-socks" then $sh else null end),
      "socks_port": (if $out=="doko-socks" then (if ($sp|tostring)=="0" then 7890 else $sp end) else null end)
    }]
  ' "$META_JSON" >"$tmp" && mv "$tmp" "$META_JSON"

  # 启用写入 xray cfg
  doko_apply_enable "$tag" || {
    warn "启用失败：已写入 meta，你可以在菜单里再启用一次"
    doko_meta_set_enabled "$tag" false || true
    return 1
  }

  # 防火墙放行（按 network）
  read -rp "是否一键放行端口到防火墙？(y/N): " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    if [[ "$net" == "tcp" ]]; then open_port "$lport" "tcp"
    elif [[ "$net" == "udp" ]]; then open_port "$lport" "udp"
    else open_port "$lport" "tcp"; open_port "$lport" "udp"
    fi
    ok "已尝试放行端口（注意云安全组也要放行）"
  fi

  ok "新增完成：$tag"
}

doko_delete(){
  doko_list
  echo
  read -rp "输入要删除的规则 tag： " tag
  [[ -n "$tag" ]] || return 0

  # 先从 xray cfg 移除
  doko_apply_disable "$tag" || true

  # 再从 meta 删除
  doko_meta_remove "$tag"
  ok "已删除规则：$tag"
}

doko_toggle(){
  doko_list
  echo
  read -rp "输入要操作的规则 tag： " tag
  [[ -n "$tag" ]] || return 0

  local enabled
  enabled="$(jq -r --arg t "$tag" '.doko_rules[]? | select(.tag==$t) | .enabled' "$META_JSON" 2>/dev/null || echo "")"
  [[ -n "$enabled" && "$enabled" != "null" ]] || { warn "未找到规则：$tag"; return 1; }

  if [[ "$enabled" == "true" ]]; then
    doko_apply_disable "$tag" || return 1
    doko_meta_set_enabled "$tag" false
  else
    doko_apply_enable "$tag" || return 1
    doko_meta_set_enabled "$tag" true
  fi
}

doko_firewall_allow(){
  doko_list
  echo
  read -rp "输入规则 tag： " tag
  [[ -n "$tag" ]] || return 0

  local lp net
  lp="$(jq -r --arg t "$tag" '.doko_rules[]? | select(.tag==$t) | .listen_port' "$META_JSON")"
  net="$(jq -r --arg t "$tag" '.doko_rules[]? | select(.tag==$t) | .network' "$META_JSON")"
  [[ -n "$lp" && "$lp" != "null" ]] || { warn "未找到规则：$tag"; return 1; }

  if [[ "$net" == "tcp" ]]; then open_port "$lp" "tcp"
  elif [[ "$net" == "udp" ]]; then open_port "$lp" "udp"
  else open_port "$lp" "tcp"; open_port "$lp" "udp"
  fi
  ok "已尝试放行：$lp ($net)（云安全组别忘了）"
}

doko_test_local(){
  doko_list
  echo
  read -rp "输入规则 tag： " tag
  [[ -n "$tag" ]] || return 0

  local addr dport
  addr="$(jq -r --arg t "$tag" '.doko_rules[]? | select(.tag==$t) | .target_addr' "$META_JSON")"
  dport="$(jq -r --arg t "$tag" '.doko_rules[]? | select(.tag==$t) | .target_port' "$META_JSON")"
  [[ -n "$addr" && "$addr" != "null" ]] || { warn "未找到规则：$tag"; return 1; }

  if have nc; then
    echo "TCP 测试：nc -vz $addr $dport"
    nc -vz "$addr" "$dport" || true
  else
    warn "未安装 nc（netcat），建议安装：apt-get install -y netcat-openbsd"
  fi
}

dokodemo_menu(){
  while true; do
    echo
    echo -e "${BLU}==============================${RST}"
    echo -e "${BLU}  端口转发（dokodemo-door）   ${RST}"
    echo -e "${BLU}==============================${RST}"
    echo "1) 新增转发规则（向导）"
    echo "2) 查看转发规则列表"
    echo "3) 查看规则详情（JSON）"
    echo "4) 删除规则"
    echo "5) 启用/禁用规则（toggle）"
    echo "6) 一键放行端口（防火墙）"
    echo "7) 测试连通性（本机->目标）"
    echo "0) 返回"
    echo
    read -rp "选择: " c
    case "$c" in
      1) doko_add_wizard ;;
      2) doko_list ;;
      3) read -rp "输入规则 tag： " t; [[ -n "$t" ]] && doko_show_one "$t" ;;
      4) doko_delete ;;
      5) doko_toggle ;;
      6) doko_firewall_allow ;;
      7) doko_test_local ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}


firewall_menu(){
  while true; do
    echo
    echo -e "${BLU}==============================${RST}"
    echo -e "${BLU}      UFW 防火墙菜单          ${RST}"
    echo -e "${BLU}==============================${RST}"
    if fw_is_enabled; then
      echo -e "状态：${GRN}已启用(active)${RST}"
    else
      echo -e "状态：${YLW}未启用(inactive)${RST}"
    fi
    echo
    echo "1) 启用 UFW"
    echo "2) 关闭 UFW"
    echo "3) 重置规则（自动放行 SSH）"
    echo "4) 同步放行（SSH + 所有节点端口）"
    echo "5) 自定义放行端口"
    echo "6) 关闭/删除端口规则"
    echo "7) 查看已放行端口（简表）"
    echo "8) 查看 UFW 详细状态"
    echo "0) 返回"
    echo
    read -rp "选择: " c
    case "$c" in
      1) fw_enable ;;
      2) fw_disable ;;
      3) fw_reset_safe ;;
      4) fw_sync_from_meta ;;
      5) fw_custom_allow_menu ;;
      6) fw_custom_close_menu ;;
      7) fw_list_allowed_ports ;;
      8) fw_status_verbose ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# --------- Meta ----------
init_meta(){
  mkdir -p "$META_DIR"
  if [[ ! -f "$META_JSON" ]]; then
    cat >"$META_JSON" <<'JSON'
{
  "bind_mode": "dual",
  "xray_inbounds": [],
  "singbox_inbounds": [],
  "doko_rules": []
}
JSON
    return 0
  fi

  # 迁移旧 meta：补齐 doko_rules
  if ! jq -e '.doko_rules' "$META_JSON" >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq '. + {"doko_rules":[]}' "$META_JSON" >"$tmp" && mv "$tmp" "$META_JSON"
  fi
}

# --------- Default configs ----------
init_xray_cfg(){
  mkdir -p /etc/xray
  if [[ ! -f "$XRAY_CFG" ]]; then
    cat >"$XRAY_CFG" <<'JSON'
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
JSON
  fi
}

init_singbox_cfg(){
  mkdir -p /etc/sing-box
  if [[ ! -f "$SB_CFG" ]]; then
    cat >"$SB_CFG" <<'JSON'
{
  "log": { "level": "warn" },
  "inbounds": [],
  "outbounds": [
    { "type": "direct" }
  ]
}
JSON
  fi
}

# --------- Self-signed cert ----------
gen_self_signed(){
  local crt="$1" key="$2" cn="${3:-example.com}"
  mkdir -p "$CERT_DIR"
  if [[ -f "$crt" && -f "$key" ]]; then return 0; fi
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -subj "/CN=${cn}" \
    -keyout "$key" -out "$crt" >/dev/null 2>&1
}

# --------- JSON ops ----------
json_append_inbound_xray(){
  local obj="$1"
  tmp="$(mktemp)"
  jq --argjson o "$obj" '.inbounds += [$o]' "$XRAY_CFG" >"$tmp"
  mv "$tmp" "$XRAY_CFG"
}
json_del_inbound_xray_by_tag(){
  local tag="$1"
  tmp="$(mktemp)"
  jq --arg t "$tag" '.inbounds |= map(select(.tag != $t))' "$XRAY_CFG" >"$tmp"
  mv "$tmp" "$XRAY_CFG"
}
json_append_inbound_sb(){
  local obj="$1"
  tmp="$(mktemp)"
  jq --argjson o "$obj" '.inbounds += [$o]' "$SB_CFG" >"$tmp"
  mv "$tmp" "$SB_CFG"
}
json_del_inbound_sb_by_tag(){
  local tag="$1"
  tmp="$(mktemp)"
  jq --arg t "$tag" '.inbounds |= map(select(.tag != $t))' "$SB_CFG" >"$tmp"
  mv "$tmp" "$SB_CFG"
}

# =========================
# Xray: ensure routing/outbound tags (for dokodemo-door)
# =========================
ensure_xray_routing(){
  init_xray_cfg
  tmp="$(mktemp)"

  # 1) 确保 outbounds[direct] 有 tag=direct
  # 2) 确保存在 routing.rules 数组
  jq '
    .outbounds |= (map(
      if (.protocol=="freedom" and (.tag|not)) then . + {"tag":"direct"} else . end
    )) |
    (if (.routing|type)!="object" then . + {"routing":{"domainStrategy":"AsIs","rules":[]}}
     else
       .routing |= (if (.rules|type)!="array" then . + {"rules":[]} else . end)
     end)
  ' "$XRAY_CFG" >"$tmp" && mv "$tmp" "$XRAY_CFG"
}

# add socks outbound if needed (for "转发走代理")
ensure_xray_socks_outbound(){
  local host="${1:-127.0.0.1}"
  local port="${2:-7890}"
  ensure_xray_routing

  if jq -e '.outbounds[]? | select(.tag=="doko-socks")' "$XRAY_CFG" >/dev/null 2>&1; then
    return 0
  fi

  tmp="$(mktemp)"
  jq --arg host "$host" --argjson port "$port" '
    .outbounds += [{
      "tag":"doko-socks",
      "protocol":"socks",
      "settings":{"servers":[{"address":$host,"port":$port}]}
    }]
  ' "$XRAY_CFG" >"$tmp" && mv "$tmp" "$XRAY_CFG"
}

# Remove routing rules by inboundTag
xray_del_rules_by_inboundTag(){
  local itag="$1"
  ensure_xray_routing
  tmp="$(mktemp)"
  jq --arg t "$itag" '
    .routing.rules |= map(select((.inboundTag|type)!="array" or (.inboundTag|index($t)|not)))
  ' "$XRAY_CFG" >"$tmp" && mv "$tmp" "$XRAY_CFG"
}

# Add routing rule for inboundTag -> outboundTag
xray_add_rule_inbound_to_outbound(){
  local itag="$1"
  local otag="$2"
  ensure_xray_routing

  tmp="$(mktemp)"
  jq --arg it "$itag" --arg ot "$otag" '
    .routing.rules += [{
      "type":"field",
      "inboundTag":[ $it ],
      "outboundTag": $ot
    }]
  ' "$XRAY_CFG" >"$tmp" && mv "$tmp" "$XRAY_CFG"
}

# Build dokodemo inbound JSON
xray_build_dokodemo_inbound(){
  local tag="$1" listen="$2" listen_port="$3" target_addr="$4" target_port="$5" net="$6"
  jq -nc \
    --arg tag "$tag" \
    --arg listen "$listen" \
    --argjson lport "$listen_port" \
    --arg addr "$target_addr" \
    --argjson dport "$target_port" \
    --arg net "$net" \
'{
  "tag": $tag,
  "listen": $listen,
  "port": $lport,
  "protocol": "dokodemo-door",
  "settings": {
    "address": $addr,
    "port": $dport,
    "network": $net
  },
  "sniffing": {"enabled": false}
}'
}

# Apply: enable a dokodemo rule (from meta -> xray cfg)
doko_apply_enable(){
  local tag="$1"
  ensure_xray_routing

  # 从 meta 取
  local listen lport addr dport net outbound
  listen="$(jq -r --arg t "$tag" '.doko_rules[] | select(.tag==$t) | .listen' "$META_JSON")"
  lport="$(jq -r --arg t "$tag" '.doko_rules[] | select(.tag==$t) | .listen_port' "$META_JSON")"
  addr="$(jq -r --arg t "$tag" '.doko_rules[] | select(.tag==$t) | .target_addr' "$META_JSON")"
  dport="$(jq -r --arg t "$tag" '.doko_rules[] | select(.tag==$t) | .target_port' "$META_JSON")"
  net="$(jq -r --arg t "$tag" '.doko_rules[] | select(.tag==$t) | .network' "$META_JSON")"
  outbound="$(jq -r --arg t "$tag" '.doko_rules[] | select(.tag==$t) | .outbound' "$META_JSON")"

  [[ -n "$listen" && -n "$lport" && -n "$addr" && -n "$dport" && -n "$net" ]] || {
    err "meta 信息不完整，无法启用：$tag"
    return 1
  }

  # outbound: direct | doko-socks
  if [[ "$outbound" == "doko-socks" ]]; then
    local shost sport
    shost="$(jq -r --arg t "$tag" '.doko_rules[] | select(.tag==$t) | .socks_host' "$META_JSON")"
    sport="$(jq -r --arg t "$tag" '.doko_rules[] | select(.tag==$t) | .socks_port' "$META_JSON")"
    [[ -n "$shost" && "$shost" != "null" ]] || shost="127.0.0.1"
    [[ -n "$sport" && "$sport" != "null" ]] || sport="7890"
    ensure_xray_socks_outbound "$shost" "$sport"
  else
    outbound="direct"
  fi

  # 清掉旧的同 tag inbound/rule，避免重复
  json_del_inbound_xray_by_tag "$tag" || true
  xray_del_rules_by_inboundTag "$tag" || true

  local inbound
  inbound="$(xray_build_dokodemo_inbound "$tag" "$listen" "$lport" "$addr" "$dport" "$net")"
  json_append_inbound_xray "$inbound"
  xray_add_rule_inbound_to_outbound "$tag" "$outbound"

  # 配置测试 + 重启
  $XRAY_BIN run -test -config "$XRAY_CFG" >/dev/null 2>&1 || {
    err "Xray 配置测试失败，已阻止启用：$tag"
    return 1
  }
  svc_restart xray

  ok "已启用转发规则：$tag  (${listen}:${lport} -> ${addr}:${dport} / ${net} / outbound=${outbound})"
}

# Apply: disable a dokodemo rule (remove from xray cfg but keep meta)
doko_apply_disable(){
  local tag="$1"
  json_del_inbound_xray_by_tag "$tag" || true
  xray_del_rules_by_inboundTag "$tag" || true

  $XRAY_BIN run -test -config "$XRAY_CFG" >/dev/null 2>&1 || {
    warn "禁用后配置测试失败？我建议你把 /etc/xray/config.json 发我看看"
    return 1
  }
  svc_restart xray
  ok "已禁用转发规则：$tag（meta 保留）"
}

# --------- Public IP ----------
get_public_ip_best_effort(){
  # 1) 如果用户手动指定了 PUBLIC_HOST，则永远用它（域名/公网IP都行）
  if [[ -n "${PUBLIC_HOST:-}" ]]; then
    echo "$PUBLIC_HOST"
    return 0
  fi

  # 2) 优先从公网服务获取 IPv4（最准确）
  local ip=""
  ip="$(curl -fsS4m 2 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -fsS4m 2 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\n' || true)"
  [[ -n "$ip" ]] || ip="$(curl -fsS4m 2 https://ifconfig.me/ip 2>/dev/null | tr -d '\n' || true)"
  if [[ -n "$ip" ]]; then
    echo "$ip"
    return 0
  fi

  # 3) 拿不到 IPv4 再拿 IPv6（纯 v6 机器会用到）
  ip="$(curl -fsS6m 2 https://api64.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -fsS6m 2 https://ipv6.icanhazip.com 2>/dev/null | tr -d '\n' || true)"
  if [[ -n "$ip" ]]; then
    echo "$ip"
    return 0
  fi

  # 4) 最后兜底：本机IP（可能是内网）
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo "${ip:-YOUR_SERVER_IP}"
}

# --------- QR / Base64 ----------
qrcode_maybe(){
  local text="$1"
  if have qrencode; then
    echo
    qrencode -t ANSIUTF8 "$text" || true
    echo
  fi
}
b64(){ if have base64; then base64 -w 0; else openssl base64 -A; fi; }

# --------- Export one ----------
export_links_one(){
  local tag="$1"
  local host
  host="$(get_public_ip_best_effort)"

  echo
  echo -e "${CYA}=== 导出：$tag ===${RST}"

  # Reality
  if jq -e --arg t "$tag" '.xray_inbounds[]? | select(.tag==$t and .proto=="vless-reality")' "$META_JSON" >/dev/null 2>&1; then
    local uuid port sni sid pbk flow name
    uuid="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .uuid' "$META_JSON")"
    port="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .port' "$META_JSON")"
    sni="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .sni' "$META_JSON")"
    sid="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .sid' "$META_JSON")"
    pbk="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .pbk' "$META_JSON")"
    flow="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .flow' "$META_JSON")"
    name="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .name' "$META_JSON")"

    local link
    link="vless://${uuid}@${host}:${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp&flow=${flow}#${name}"
    echo -e "${GRN}${link}${RST}"
    qrcode_maybe "$link"
    return 0
  fi

  # VMess WS noTLS
  if jq -e --arg t "$tag" '.xray_inbounds[]? | select(.tag==$t and .proto=="vmess-ws-notls")' "$META_JSON" >/dev/null 2>&1; then
    local uuid port path hosth name
    uuid="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .uuid' "$META_JSON")"
    port="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .port' "$META_JSON")"
    path="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .path' "$META_JSON")"
    hosth="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .host' "$META_JSON")"
    name="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .name' "$META_JSON")"

    local json vm
    json="$(jq -nc --arg v "2" --arg ps "$name" --arg add "$host" --arg port "$port" \
                --arg id "$uuid" --arg aid "0" --arg net "ws" --arg type "none" \
                --arg hosth "$hosth" --arg path "$path" --arg tls "" \
'{
  v:$v, ps:$ps, add:$add, port:$port, id:$id, aid:$aid, net:$net,
  type:$type, host:$hosth, path:$path, tls:$tls
}')"
    vm="vmess://$(printf '%s' "$json" | b64)"
    echo -e "${GRN}${vm}${RST}"
    qrcode_maybe "$vm"
    return 0
  fi

  # VMess TCP HTTP
  if jq -e --arg t "$tag" '.xray_inbounds[]? | select(.tag==$t and .proto=="vmess-tcp-http")' "$META_JSON" >/dev/null 2>&1; then
    local uuid port path hosth name
    uuid="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .uuid' "$META_JSON")"
    port="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .port' "$META_JSON")"
    path="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .path' "$META_JSON")"
    hosth="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .host' "$META_JSON")"
    name="$(jq -r --arg t "$tag" '.xray_inbounds[] | select(.tag==$t) | .name' "$META_JSON")"

    local json vm
    json="$(jq -nc --arg v "2" --arg ps "$name" --arg add "$host" --arg port "$port" \
                --arg id "$uuid" --arg aid "0" --arg net "tcp" --arg type "http" \
                --arg hosth "$hosth" --arg path "$path" --arg tls "" \
'{
  v:$v, ps:$ps, add:$add, port:$port, id:$id, aid:$aid, net:$net,
  type:$type, host:$hosth, path:$path, tls:$tls
}')"
    vm="vmess://$(printf '%s' "$json" | b64)"
    echo -e "${GRN}${vm}${RST}"
    qrcode_maybe "$vm"
    return 0
  fi

  # TUIC
  if jq -e --arg t "$tag" '.singbox_inbounds[]? | select(.tag==$t and .proto=="tuic")' "$META_JSON" >/dev/null 2>&1; then
    local uuid password port sni name
    uuid="$(jq -r --arg t "$tag" '.singbox_inbounds[] | select(.tag==$t) | .uuid' "$META_JSON")"
    password="$(jq -r --arg t "$tag" '.singbox_inbounds[] | select(.tag==$t) | .password' "$META_JSON")"
    port="$(jq -r --arg t "$tag" '.singbox_inbounds[] | select(.tag==$t) | .port' "$META_JSON")"
    sni="$(jq -r --arg t "$tag" '.singbox_inbounds[] | select(.tag==$t) | .sni' "$META_JSON")"
    name="$(jq -r --arg t "$tag" '.singbox_inbounds[] | select(.tag==$t) | .name' "$META_JSON")"

    echo -e "${YLW}TUIC：优先给 sing-box JSON（自签证书需 insecure=true）${RST}"
    jq -nc --arg tag "$name" --arg server "$host" --argjson port "$port" \
          --arg uuid "$uuid" --arg password "$password" --arg sni "$sni" \
'{
  "type":"tuic",
  "tag":$tag,
  "server":$server,
  "server_port":$port,
  "uuid":$uuid,
  "password":$password,
  "congestion_control":"bbr",
  "tls":{
    "enabled":true,
    "server_name":$sni,
    "insecure":true
  }
}' | jq .

    echo
    echo -e "${YLW}TUIC：附赠分享链接（部分客户端支持）${RST}"
    local tuic_link
    tuic_link="tuic://${uuid}:${password}@${host}:${port}?sni=${sni}&allow_insecure=1#${name}"
    echo -e "${GRN}${tuic_link}${RST}"
    qrcode_maybe "$tuic_link"
    return 0
  fi

  # HY2
  if jq -e --arg t "$tag" '.singbox_inbounds[]? | select(.tag==$t and .proto=="hy2")' "$META_JSON" >/dev/null 2>&1; then
    local password port sni name
    password="$(jq -r --arg t "$tag" '.singbox_inbounds[] | select(.tag==$t) | .password' "$META_JSON")"
    port="$(jq -r --arg t "$tag" '.singbox_inbounds[] | select(.tag==$t) | .port' "$META_JSON")"
    sni="$(jq -r --arg t "$tag" '.singbox_inbounds[] | select(.tag==$t) | .sni' "$META_JSON")"
    name="$(jq -r --arg t "$tag" '.singbox_inbounds[] | select(.tag==$t) | .name' "$META_JSON")"

    echo -e "${YLW}HY2：标准 URI（自签证书 insecure=1）${RST}"
    local link
    link="hysteria2://${password}@${host}:${port}/?sni=${sni}&insecure=1#${name}"
    echo -e "${GRN}${link}${RST}"
    qrcode_maybe "$link"

    echo -e "${YLW}HY2：sing-box JSON（备用）${RST}"
    jq -nc --arg tag "$name" --arg server "$host" --argjson port "$port" \
          --arg password "$password" --arg sni "$sni" \
'{
  "type":"hysteria2",
  "tag":$tag,
  "server":$server,
  "server_port":$port,
  "password":$password,
  "tls":{
    "enabled":true,
    "server_name":$sni,
    "insecure":true
  }
}' | jq .
    return 0
  fi

  warn "没有找到该 tag 的导出逻辑：$tag"
}

# --------- List/Delete ----------
list_inbounds(){
  echo -e "${BLU}--- Xray 入站 ---${RST}"
  jq -r '.xray_inbounds[]? | "\(.tag)\t\(.proto)\t\(.port)\t\(.name)"' "$META_JSON" 2>/dev/null || true
  echo -e "${BLU}--- sing-box 入站 ---${RST}"
  jq -r '.singbox_inbounds[]? | "\(.tag)\t\(.proto)\t\(.port)\t\(.name)"' "$META_JSON" 2>/dev/null || true
}

delete_inbound(){
  list_inbounds
  echo
  read -rp "输入要删除的 tag： " tag
  [[ -n "$tag" ]] || { warn "未输入 tag"; return 0; }

  if jq -e --arg t "$tag" '.xray_inbounds[]? | select(.tag==$t)' "$META_JSON" >/dev/null 2>&1; then
    json_del_inbound_xray_by_tag "$tag"
    tmp="$(mktemp)"
    jq --arg t "$tag" '.xray_inbounds |= map(select(.tag != $t))' "$META_JSON" >"$tmp"
    mv "$tmp" "$META_JSON"
    svc_restart xray
    ok "已删除 Xray 入站：$tag"
    return 0
  fi

  if jq -e --arg t "$tag" '.singbox_inbounds[]? | select(.tag==$t)' "$META_JSON" >/dev/null 2>&1; then
    json_del_inbound_sb_by_tag "$tag"
    tmp="$(mktemp)"
    jq --arg t "$tag" '.singbox_inbounds |= map(select(.tag != $t))' "$META_JSON" >"$tmp"
    mv "$tmp" "$META_JSON"
    svc_restart sing-box
    ok "已删除 sing-box 入站：$tag"
    return 0
  fi

  warn "未找到该 tag：$tag"
}

# --------- Add inbounds (Xray) ----------
add_vless_reality(){
  set +e  # Reality 内部失败不要杀整个脚本

  local name port sni sid flow uuid
  read -rp "入站备注名（例如 US-Reality）: " name
  [[ -n "$name" ]] || name="Reality-$(date +%m%d%H%M)"

  read -rp "监听端口（回车随机 20000-50000）: " port
  [[ -n "$port" ]] || port="$((20000 + RANDOM % 30000))"

  read -rp "Reality SNI（默认 www.cloudflare.com）: " sni
  [[ -n "$sni" ]] || sni="www.cloudflare.com"

  read -rp "shortId（回车随机 8字节hex）: " sid
  [[ -n "$sid" ]] || sid="$(rand_hex 8)"

  read -rp "flow（默认 xtls-rprx-vision，可空）: " flow
  [[ -n "$flow" ]] || flow="xtls-rprx-vision"

  uuid="$(rand_uuid)"

  # ✅ 生成 Reality keypair（兼容新版 xray x25519：可能不输出 PublicKey）
  local xout priv pub
  xout="$($XRAY_BIN x25519 2>/dev/null || true)"

  priv="$(echo "$xout" | grep -Ei 'private[ _-]*key' | head -n1 | sed -E 's/.*:[[:space:]]*//' | tr -d '\r')"
  pub="$(echo "$xout"  | grep -Ei 'public[ _-]*key'  | head -n1 | sed -E 's/.*:[[:space:]]*//' | tr -d '\r')"

  # ✅ 新版没给 PublicKey：用 priv 算 pub（需要 python3-cryptography）
  if [[ -n "$priv" && -z "$pub" ]]; then
    if ! python3 -c "import cryptography" >/dev/null 2>&1; then
      warn "缺少 python3-cryptography，正在安装..."
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y python3-cryptography >/dev/null 2>&1
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3-cryptography >/dev/null 2>&1
      elif command -v yum >/dev/null 2>&1; then
        yum install -y python3-cryptography >/dev/null 2>&1
      fi
    fi

    pub="$(python3 - <<PY 2>/dev/null
import base64
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
priv_b64u="$priv"
raw = base64.urlsafe_b64decode(priv_b64u + "==")
priv = x25519.X25519PrivateKey.from_private_bytes(raw)
pub = priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
print(base64.urlsafe_b64encode(pub).decode().rstrip("="))
PY
)"
  fi

  if [[ -z "$priv" || -z "$pub" ]]; then
    err "Reality keypair 生成失败：priv/pub 为空（请确认 python3-cryptography 安装成功）"
    echo "---- xray x25519 原始输出 ----"
    echo "$xout"
    echo "-----------------------------"
    set -e
    return 1
  fi

  local tag="xray-${name// /_}-reality-${port}"

  # ✅ 先备份配置，后写入（失败可回滚）
  local bak="/etc/xray/config.json.bak.$(date +%F-%H%M%S)"
  cp -a "$XRAY_CFG" "$bak"

  # ✅ 生成 inbound JSON（dest = SNI:443）
  local inbound
  inbound="$(jq -nc \
    --arg tag "$tag" \
    --arg uuid "$uuid" \
    --arg sni "$sni" \
    --arg sid "$sid" \
    --arg priv "$priv" \
    --arg flow "$flow" \
    --argjson port "$port" \
'{
  "tag": $tag,
  "listen": "0.0.0.0",
  "port": $port,
  "protocol": "vless",
  "settings": {
    "clients": [
      { "id": $uuid, "flow": $flow }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": ($sni + ":443"),
      "xver": 0,
      "serverNames": [ $sni ],
      "privateKey": $priv,
      "shortIds": [ $sid ]
    }
  },
  "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
}')" 

  if [[ -z "$inbound" ]]; then
    err "jq 生成 Reality inbound 失败，已回滚配置"
    cp -a "$bak" "$XRAY_CFG"
    set -e
    return 1
  fi

  # ✅ IPv6/双栈监听模式
  local mode
  mode="$(meta_get_bind_mode)"
  if [[ "$mode" == "v6" ]]; then
    inbound="$(echo "$inbound" | jq '.listen="::"')"
  fi

  # ✅ 写入 Xray 配置
  local tmp="/tmp/xray_cfg_$$.json"
  jq --argjson o "$inbound" '.inbounds += [$o]' "$XRAY_CFG" >"$tmp"
  if [[ $? -ne 0 ]]; then
    err "写入 /etc/xray/config.json 失败，已回滚配置"
    cp -a "$bak" "$XRAY_CFG"
    rm -f "$tmp"
    set -e
    return 1
  fi
  mv "$tmp" "$XRAY_CFG"

  # ✅ 写完先测试配置，防止重启炸
  $XRAY_BIN run -test -config "$XRAY_CFG" >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    err "Xray 配置测试失败（已回滚），请检查参数/生成逻辑"
    cp -a "$bak" "$XRAY_CFG"
    set -e
    return 1
  fi

  open_port "$port" "tcp"
  systemctl restart xray >/dev/null 2>&1

  # ✅ 写入 meta（导出链接用）
  tmp="$(mktemp)"
  jq --arg tag "$tag" --arg name "$name" --arg proto "vless-reality" --arg uuid "$uuid" \
     --arg port "$port" --arg sni "$sni" --arg sid "$sid" --arg pbk "$pub" --arg flow "$flow" \
     '.xray_inbounds += [{
        "tag":$tag,"name":$name,"proto":$proto,"uuid":$uuid,
        "port":($port|tonumber),"sni":$sni,"sid":$sid,"pbk":$pbk,"flow":$flow
      }]' "$META_JSON" >"$tmp" && mv "$tmp" "$META_JSON"

  ok "已添加 VLESS+Reality：$name 端口 $port"
  export_links_one "$tag"

  set -e
  return 0
}

add_vmess_ws_notls(){
  local name port path host
  read -rp "入站备注名（例如 JP-VMess-WS）: " name
  [[ -n "$name" ]] || name="VMessWS-$(date +%m%d%H%M)"
  read -rp "监听端口（回车随机 20000-50000）: " port
  [[ -n "$port" ]] || port="$((20000 + RANDOM % 30000))"
  read -rp "WS path（回车随机，例如 /abc123）: " path
  [[ -n "$path" ]] || path="/$(rand_hex 3)"
  read -rp "Host(伪装域名，可空): " host
  host="${host:-}"

  local uuid
  uuid="$(rand_uuid)"
  local tag="xray-${name// /_}-vmessws-${port}"

  # ✅ Fix: headers pre-gen (Host empty ok)
  local headers
  headers="$(jq -nc --arg host "$host" 'if ($host|length)>0 then {"Host":$host} else {} end')"

  local inbound
  inbound="$(jq -nc \
    --arg tag "$tag" \
    --arg uuid "$uuid" \
    --arg path "$path" \
    --argjson headers "$headers" \
    --argjson port "$port" \
'{
  "tag": $tag,
  "listen": "0.0.0.0",
  "port": $port,
  "protocol": "vmess",
  "settings": {
    "clients": [ { "id": $uuid, "alterId": 0 } ]
  },
  "streamSettings": {
    "network": "ws",
    "security": "none",
    "wsSettings": {
      "path": $path,
      "headers": $headers
    }
  },
  "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
}')"

  local mode
  mode="$(meta_get_bind_mode)"
  if [[ "$mode" == "v6" ]]; then inbound="$(echo "$inbound" | jq '.listen="::"')"; fi

  json_append_inbound_xray "$inbound"
  open_port "$port" "tcp"

  tmp="$(mktemp)"
  jq --arg tag "$tag" --arg name "$name" --arg proto "vmess-ws-notls" --arg uuid "$uuid" \
     --arg port "$port" --arg path "$path" --arg host "$host" \
     '.xray_inbounds += [{
        "tag":$tag,"name":$name,"proto":$proto,"uuid":$uuid,
        "port":($port|tonumber),"path":$path,"host":$host
      }]' "$META_JSON" >"$tmp"
  mv "$tmp" "$META_JSON"

  svc_restart xray
  ok "已添加 VMess+WS(noTLS)：$name 端口 $port path=$path"
  export_links_one "$tag"
}

add_vmess_tcp_http(){
  local name port path host
  read -rp "入站备注名（例如 SG-VMess-TCP-HTTP）: " name
  [[ -n "$name" ]] || name="VMessTCPHTTP-$(date +%m%d%H%M)"
  read -rp "监听端口（回车随机 20000-50000）: " port
  [[ -n "$port" ]] || port="$((20000 + RANDOM % 30000))"
  read -rp "HTTP伪装 path（回车随机，例如 /news）: " path
  [[ -n "$path" ]] || path="/$(rand_hex 3)"
  read -rp "Host(伪装域名，可空): " host
  host="${host:-}"

  local uuid
  uuid="$(rand_uuid)"
  local tag="xray-${name// /_}-vmess-tcp-http-${port}"

  # ✅ Fix: headers pre-gen
  local headers
  headers="$(jq -nc --arg host "$host" '
    (if ($host|length)>0 then {"Host":[ $host ]} else {} end)
    + {"User-Agent":["Mozilla/5.0"],"Accept-Encoding":["gzip, deflate"],"Connection":["keep-alive"],"Pragma":["no-cache"]}
  ')"

  local inbound
  inbound="$(jq -nc \
    --arg tag "$tag" \
    --arg uuid "$uuid" \
    --arg path "$path" \
    --argjson headers "$headers" \
    --argjson port "$port" \
'{
  "tag": $tag,
  "listen": "0.0.0.0",
  "port": $port,
  "protocol": "vmess",
  "settings": {
    "clients": [ { "id": $uuid, "alterId": 0 } ]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "none",
    "tcpSettings": {
      "header": {
        "type": "http",
        "request": {
          "version": "1.1",
          "method": "GET",
          "path": [ $path ],
          "headers": $headers
        }
      }
    }
  },
  "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
}')"

  local mode
  mode="$(meta_get_bind_mode)"
  if [[ "$mode" == "v6" ]]; then inbound="$(echo "$inbound" | jq '.listen="::"')"; fi

  json_append_inbound_xray "$inbound"
  open_port "$port" "tcp"

  tmp="$(mktemp)"
  jq --arg tag "$tag" --arg name "$name" --arg proto "vmess-tcp-http" --arg uuid "$uuid" \
     --arg port "$port" --arg path "$path" --arg host "$host" \
     '.xray_inbounds += [{
        "tag":$tag,"name":$name,"proto":$proto,"uuid":$uuid,
        "port":($port|tonumber),"path":$path,"host":$host
      }]' "$META_JSON" >"$tmp"
  mv "$tmp" "$META_JSON"

  svc_restart xray
  ok "已添加 VMess+TCP+HTTP：$name 端口 $port path=$path"
  export_links_one "$tag"
}

# --------- Add inbounds (sing-box) ----------
add_tuic(){
  local name port uuid password sni
  read -rp "入站备注名（例如 US-TUIC）: " name
  [[ -n "$name" ]] || name="TUIC-$(date +%m%d%H%M)"
  read -rp "监听端口（回车随机 20000-50000）: " port
  [[ -n "$port" ]] || port="$((20000 + RANDOM % 30000))"
  read -rp "TUIC server_name（默认 www.cloudflare.com）: " sni
  [[ -n "$sni" ]] || sni="www.cloudflare.com"

  uuid="$(rand_uuid)"
  password="$(rand_hex 12)"

  gen_self_signed "$TUIC_CRT" "$TUIC_KEY" "$sni"

  local tag="sb-${name// /_}-tuic-${port}"

  local inbound
  inbound="$(jq -nc \
    --arg tag "$tag" \
    --arg uuid "$uuid" \
    --arg password "$password" \
    --arg crt "$TUIC_CRT" \
    --arg key "$TUIC_KEY" \
    --arg sni "$sni" \
    --argjson port "$port" \
'{
  "type": "tuic",
  "tag": $tag,
  "listen": "::",
  "listen_port": $port,
  "users": [
    { "uuid": $uuid, "password": $password }
  ],
  "congestion_control": "bbr",
  "tls": {
    "enabled": true,
    "server_name": $sni,
    "certificate_path": $crt,
    "key_path": $key
  }
}')"

  local mode
  mode="$(meta_get_bind_mode)"
  if [[ "$mode" == "v4" ]]; then inbound="$(echo "$inbound" | jq '.listen="0.0.0.0"')"; fi

  json_append_inbound_sb "$inbound"
  open_port "$port" "udp"

  tmp="$(mktemp)"
  jq --arg tag "$tag" --arg name "$name" --arg proto "tuic" \
     --arg uuid "$uuid" --arg password "$password" \
     --arg port "$port" --arg sni "$sni" \
     '.singbox_inbounds += [{
        "tag":$tag,"name":$name,"proto":$proto,
        "port":($port|tonumber),"uuid":$uuid,"password":$password,"sni":$sni,
        "tls":"self-signed"
      }]' "$META_JSON" >"$tmp"
  mv "$tmp" "$META_JSON"

  svc_restart sing-box
  ok "已添加 TUIC：$name UDP端口 $port（自签证书，客户端需 allow_insecure）"
  export_links_one "$tag"
}

add_hy2(){
  local name port password sni
  read -rp "入站备注名（例如 HK-HY2）: " name
  [[ -n "$name" ]] || name="HY2-$(date +%m%d%H%M)"
  read -rp "监听端口（回车随机 20000-50000）: " port
  [[ -n "$port" ]] || port="$((20000 + RANDOM % 30000))"
  read -rp "HY2 server_name（默认 www.cloudflare.com）: " sni
  [[ -n "$sni" ]] || sni="www.cloudflare.com"

  password="$(rand_hex 16)"
  gen_self_signed "$HY2_CRT" "$HY2_KEY" "$sni"

  local tag="sb-${name// /_}-hy2-${port}"

  local inbound
  inbound="$(jq -nc \
    --arg tag "$tag" \
    --arg password "$password" \
    --arg crt "$HY2_CRT" \
    --arg key "$HY2_KEY" \
    --arg sni "$sni" \
    --argjson port "$port" \
'{
  "type": "hysteria2",
  "tag": $tag,
  "listen": "::",
  "listen_port": $port,
  "users": [
    { "password": $password }
  ],
  "tls": {
    "enabled": true,
    "server_name": $sni,
    "certificate_path": $crt,
    "key_path": $key
  }
}')"

  local mode
  mode="$(meta_get_bind_mode)"
  if [[ "$mode" == "v4" ]]; then inbound="$(echo "$inbound" | jq '.listen="0.0.0.0"')"; fi

  json_append_inbound_sb "$inbound"
  open_port "$port" "udp"

  tmp="$(mktemp)"
  jq --arg tag "$tag" --arg name "$name" --arg proto "hy2" \
     --arg port "$port" --arg password "$password" --arg sni "$sni" \
     '.singbox_inbounds += [{
        "tag":$tag,"name":$name,"proto":$proto,
        "port":($port|tonumber),"password":$password,"sni":$sni,
        "tls":"self-signed"
      }]' "$META_JSON" >"$tmp"
  mv "$tmp" "$META_JSON"

  svc_restart sing-box
  ok "已添加 Hysteria2：$name UDP端口 $port（自签证书，客户端需 allow_insecure）"
  export_links_one "$tag"
}

# --------- Export all ----------
export_all(){
  list_inbounds | sed 's/\t/  /g'
  echo
  read -rp "输入 tag 导出（回车导出全部）： " tag
  if [[ -z "$tag" ]]; then
    jq -r '.xray_inbounds[]?.tag' "$META_JSON" | while read -r t; do export_links_one "$t"; done
    jq -r '.singbox_inbounds[]?.tag' "$META_JSON" | while read -r t; do export_links_one "$t"; done
  else
    export_links_one "$tag"
  fi
}

# --------- Health check ----------
health_check(){
  echo -e "${BLU}=== XSB 体检 ===${RST}"
  echo -e "Xray:     $(svc_status xray)"
  echo -e "sing-box: $(svc_status sing-box)"
  echo

  echo -e "${CYA}监听端口（TCP）:${RST}"
  ss -lntp 2>/dev/null | head -n 40 || true
  echo
  echo -e "${CYA}监听端口（UDP）:${RST}"
  ss -lnup 2>/dev/null | head -n 40 || true
  echo

  warn "如果本机监听正常但外网不通：优先检查云安全组/ACL（入站 TCP/UDP 端口）"
}

# --------- Local latency check ----------
latency_test(){
  list_inbounds
  echo
  read -rp "输入 tag 测试（回车测试全部）： " tag

  test_one_tcp(){
    local port="$1"
    local t0 t1 ms
    t0="$(date +%s%3N)"
    timeout 1 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/$port" >/dev/null 2>&1 || true
    t1="$(date +%s%3N)"
    ms="$((t1 - t0))"
    echo "${ms}ms"
  }

  test_one_udp_listen(){
    local port="$1"
    if ss -lnup 2>/dev/null | grep -qE "[:.]${port}\b"; then
      echo "LISTEN"
    else
      echo "NO-LISTEN"
    fi
  }

  run_tag(){
    local t="$1"
    if jq -e --arg tt "$t" '.xray_inbounds[]? | select(.tag==$tt)' "$META_JSON" >/dev/null 2>&1; then
      local port proto
      port="$(jq -r --arg tt "$t" '.xray_inbounds[] | select(.tag==$tt) | .port' "$META_JSON")"
      proto="$(jq -r --arg tt "$t" '.xray_inbounds[] | select(.tag==$tt) | .proto' "$META_JSON")"
      printf "%-45s %-16s port=%-6s tcp=%s\n" "$t" "$proto" "$port" "$(test_one_tcp "$port")"
      return
    fi
    if jq -e --arg tt "$t" '.singbox_inbounds[]? | select(.tag==$tt)' "$META_JSON" >/dev/null 2>&1; then
      local port proto
      port="$(jq -r --arg tt "$t" '.singbox_inbounds[] | select(.tag==$tt) | .port' "$META_JSON")"
      proto="$(jq -r --arg tt "$t" '.singbox_inbounds[] | select(.tag==$tt) | .proto' "$META_JSON")"
      printf "%-45s %-16s port=%-6s udp=%s\n" "$t" "$proto" "$port" "$(test_one_udp_listen "$port")"
      return
    fi
    warn "未找到 tag：$t"
  }

  echo -e "${BLU}=== 本机延迟/状态（轻量） ===${RST}"
  if [[ -z "$tag" ]]; then
    jq -r '.xray_inbounds[]?.tag' "$META_JSON" | while read -r t; do run_tag "$t"; done
    jq -r '.singbox_inbounds[]?.tag' "$META_JSON" | while read -r t; do run_tag "$t"; done
  else
    run_tag "$tag"
  fi

  echo
  info "说明：这是服务器本机测试，用来判断监听/服务是否正常。真实延迟以客户端为准。"
}

# --------- Core update ----------
update_core(){
  echo "1) 更新 Xray"
  echo "2) 更新 sing-box"
  echo "0) 返回"
  read -rp "选择: " c
  case "$c" in
    1) download_and_install_xray; reload_systemd; svc_restart xray; ok "Xray 已更新" ;;
    2) download_and_install_singbox; reload_systemd; svc_restart sing-box; ok "sing-box 已更新" ;;
    *) return 0 ;;
  esac
}

# --------- Backup/restore ----------
backup_all(){
  local out="/root/xsb-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$out" \
    /etc/xray /etc/sing-box \
    "$META_DIR" \
    /etc/systemd/system/xray.service /etc/systemd/system/sing-box.service \
    "$CERT_DIR" >/dev/null 2>&1 || true
  ok "备份完成：$out"
}

restore_all(){
  read -rp "输入备份文件路径（例如 /root/xsb-backup-xxxx.tar.gz）: " f
  [[ -f "$f" ]] || { err "文件不存在：$f"; return 1; }
  tar -xzf "$f" -C / >/dev/null 2>&1 || true
  reload_systemd
  svc_restart xray
  svc_restart sing-box
  ok "恢复完成（已重启服务）"
}

# --------- Bind mode ----------
choose_bind_mode(){
  echo "监听模式："
  echo "1) 双栈（推荐）"
  echo "2) 仅 IPv4"
  echo "3) 仅 IPv6"
  read -rp "选择 [1-3]（默认1）: " c
  case "$c" in
    2) meta_set_bind_mode "v4" ;;
    3) meta_set_bind_mode "v6" ;;
    *) meta_set_bind_mode "dual" ;;
  esac
  ok "bind_mode=$(meta_get_bind_mode)"
}

# --------- Reset ----------
reset_all_configs(){
  init_meta
  init_xray_cfg
  init_singbox_cfg
  tmp="$(mktemp)"
  jq '.inbounds=[]' "$XRAY_CFG" >"$tmp" && mv "$tmp" "$XRAY_CFG"
  tmp="$(mktemp)"
  jq '.inbounds=[]' "$SB_CFG" >"$tmp" && mv "$tmp" "$SB_CFG"
  cat >"$META_JSON" <<'JSON'
{
  "bind_mode": "dual",
  "xray_inbounds": [],
  "singbox_inbounds": []
}
JSON
}

install_or_reset(){
  ensure_systemd
  install_deps
  download_and_install_xray
  download_and_install_singbox

  mkdir -p /etc/xray /etc/sing-box "$META_DIR" "$CERT_DIR"
  init_meta
  choose_bind_mode
  init_xray_cfg
  init_singbox_cfg

  write_systemd_xray
  write_systemd_singbox
  reload_systemd
  svc_enable_start xray
  svc_enable_start sing-box

  ok "安装/初始化完成"
}

# --------- Template deploy ----------
template_deploy(){
  echo "模板部署："
  echo "1) 通用机：Reality + TUIC + HY2 + VMess TCP HTTP"
  echo "2) UDP受限：Reality + VMess TCP HTTP + VMess WS"
  echo "3) 纯IPv6：Reality(v6) + VMess TCP HTTP(v6) + 可选 TUIC/HY2"
  echo "0) 返回"
  read -rp "选择: " c
  case "$c" in
    1) add_vless_reality; add_tuic; add_hy2; add_vmess_tcp_http ;;
    2) add_vless_reality; add_vmess_tcp_http; add_vmess_ws_notls ;;
    3)
      meta_set_bind_mode "v6"
      ok "已切换到 仅IPv6 监听"
      add_vless_reality
      add_vmess_tcp_http
      echo
      read -rp "是否再加 TUIC? (y/N): " yn
      [[ "$yn" =~ ^[Yy]$ ]] && add_tuic || true
      read -rp "是否再加 HY2? (y/N): " yn2
      [[ "$yn2" =~ ^[Yy]$ ]] && add_hy2 || true
      ;;
    *) return 0 ;;
  esac
}

add_inbound_menu(){
  echo "添加入站："
  echo "1) VLESS + Reality"
  echo "2) VMess + WS (noTLS)"
  echo "3) VMess + TCP + HTTP"
  echo "4) TUIC"
  echo "5) Hysteria2 (HY2)"
  echo "0) 返回"
  read -rp "选择: " c
  case "$c" in
    1) add_vless_reality ;;
    2) add_vmess_ws_notls ;;
    3) add_vmess_tcp_http ;;
    4) add_tuic ;;
    5) add_hy2 ;;
    *) return 0 ;;
  esac
}

view_logs(){
  echo "1) Xray 日志（最近200行）"
  echo "2) sing-box 日志（最近200行）"
  echo "0) 返回"
  read -rp "选择: " c
  case "$c" in
    1) journalctl -u xray --no-pager -n 200 ;;
    2) journalctl -u sing-box --no-pager -n 200 ;;
    *) return 0 ;;
  esac
}

uninstall_all(){
  read -rp "确定卸载（会删除配置和服务）? (y/N): " yn
  [[ "$yn" =~ ^[Yy]$ ]] || return 0

  systemctl stop xray >/dev/null 2>&1 || true
  systemctl stop sing-box >/dev/null 2>&1 || true
  systemctl disable xray >/dev/null 2>&1 || true
  systemctl disable sing-box >/dev/null 2>&1 || true

  rm -f /etc/systemd/system/xray.service /etc/systemd/system/sing-box.service
  reload_systemd

  rm -f "$XRAY_BIN" "$SB_BIN"
  rm -rf /etc/xray /etc/sing-box "$META_DIR" "$CERT_DIR"

  ok "卸载完成"
}

main_menu(){
  while true; do
    clear
    echo   
    echo -e "\033[1;34m =======================================\033[0m"
    echo -e "\033[1;37m      |\__/,|   (\`\ \033[0m    \033[1;33mXSB OneKey\033[0m"
    echo -e "\033[1;37m    _.|\033[1;31mo o\033[1;37m  |_   ) ) \033[0m   \033[1;32m[ Ready... ]\033[0m"
    echo -e "\033[1;32m  -(((---(((-------- \033[0m   \033[1;33mBy: sockc\033[0m"
    echo -e "\033[1;34m =======================================\033[0m"
    echo
    
    echo "1) 安装/初始化"
    echo "2) 重置"
    echo "3) 模板部署"
    echo "4) 添加入站"
    echo "5) 列出入站"
    echo "6) 删除入站"
    echo "7) 导出链接/配置/二维码"
    echo "8) 节点体检（监听/防火墙/服务）"
    echo "9) 端口转发（dokodemo-door）"
    echo "10) Xray 出站接入 mihomo 分流"
    echo "11) 更新核心（Xray/sing-box）"
    echo "12) 防火墙(UFW) 管理"
    echo "13) 查看UFW状态"
    echo "14) 查看日志"
    echo "15) 备份"
    echo "16) 恢复"
    echo "0)  退出"
    echo "99) 卸载"
    echo
    read -rp "请选择: " c
    case "$c" in
      1) install_or_reset ;;
      2) reset_all_configs; svc_restart xray; svc_restart sing-box; ok "已重置完成" ;;
      3) template_deploy ;;
      4) add_inbound_menu ;;
      5) list_inbounds ;;
      6) delete_inbound ;;
      7) export_all ;;
      8) health_check ;;
      9) dokodemo_menu ;;
      10) mihomo_menu ;;
      11) update_core ;;
      12) firewall_menu ;;
      13) fw_status ;;
      14) view_logs ;;
      15) backup_all ;;
      16) restore_all ;;
      0) return 0 ;;          
      99) uninstall_xsb ;;
      *) warn "无效选项" ;;
    esac
  done
}

# =========================================================
# Xray outbound via mihomo (Clash Meta) - menu addon
# =========================================================

XRAY_CFG="${XRAY_CFG:-/etc/xray/config.json}"

port_listening() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lntup 2>/dev/null | grep -qE "[:.]${p}\b" && return 0 || return 1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lntup 2>/dev/null | grep -qE "[:.]${p}\b" && return 0 || return 1
  else
    return 1
  fi
}

mihomo_guess_port() {
  # 优先 socks-port 7891，其次 mixed/http 7890
  if port_listening 7891; then echo "7891"; return 0; fi
  if port_listening 7890; then echo "7890"; return 0; fi
  echo ""
}

mihomo_backup_cfg() {
  local bak="/etc/xray/config.json.bak.mihomo.$(date +%F-%H%M%S)"
  cp -a "$XRAY_CFG" "$bak"
  ok "已备份：$bak"
}

mihomo_status() {
  echo
  echo "=== Xray → mihomo 出站状态 ==="
  if [[ ! -f "$XRAY_CFG" ]]; then
    err "未找到 $XRAY_CFG"
    return 0
  fi

  local has_tag has_rule port proto
  has_tag="$(jq -r '.outbounds[]?.tag // empty' "$XRAY_CFG" 2>/dev/null | grep -x "proxy_via_mihomo" || true)"
  has_rule="$(jq -r '.routing.rules[]?.outboundTag // empty' "$XRAY_CFG" 2>/dev/null | grep -x "proxy_via_mihomo" || true)"
  port="$(jq -r '.outbounds[]? | select(.tag=="proxy_via_mihomo") | .settings.servers[0].port // empty' "$XRAY_CFG" 2>/dev/null || true)"
  proto="$(jq -r '.outbounds[]? | select(.tag=="proxy_via_mihomo") | .protocol // empty' "$XRAY_CFG" 2>/dev/null || true)"

  if [[ -n "$has_tag" ]]; then
    ok "已存在 outboundTag=proxy_via_mihomo（协议=$proto 端口=$port）"
  else
    warn "未配置 proxy_via_mihomo 出站"
  fi

  if [[ -n "$has_rule" ]]; then
    ok "已存在 routing 默认规则 → proxy_via_mihomo"
  else
    warn "未设置 routing 默认规则（未接管出站）"
  fi

  echo
  echo "mihomo 端口监听检测："
  if port_listening 7891; then ok "7891 (常见 SOCKS5) 正在监听"; else warn "7891 未监听"; fi
  if port_listening 7890; then ok "7890 (常见 HTTP/mixed) 正在监听"; else warn "7890 未监听"; fi
  echo
}

mihomo_enable() {
  [[ -f "$XRAY_CFG" ]] || { err "缺少 $XRAY_CFG"; return 1; }
  command -v jq >/dev/null 2>&1 || { err "缺少 jq"; return 1; }

  local auto_port port
  auto_port="$(mihomo_guess_port || true)"

  read -rp "mihomo 本地端口（回车自动检测 7891/7890）: " port
  [[ -n "$port" ]] || port="$auto_port"

  if [[ -z "$port" ]]; then
    warn "未检测到 7891/7890 正在监听，仍可写入配置，但请先确保 mihomo 已启动"
    port="7891"
  fi

  echo
  echo "选择 mihomo 代理类型："
  echo "1) SOCKS5（推荐：mihomo socks-port=7891 或 mixed-port）"
  echo "2) HTTP   （mihomo port=7890）"
  echo "0) 返回"
  read -rp "选择: " t

  local proto
  case "$t" in
    1) proto="socks" ;;
    2) proto="http" ;;
    0) return 0 ;;
    *) warn "无效，默认 SOCKS5"; proto="socks" ;;
  esac

  mihomo_backup_cfg

  # 写入/更新 outbounds + routing 默认规则
  # 逻辑：
  # - outbounds 中确保有 proxy_via_mihomo + direct
  # - routing.rules 末尾增加“默认走 proxy_via_mihomo”（放最后当兜底）
  # - 若已存在则更新端口/协议，不重复插入
  local tmp
  tmp="$(mktemp)"

  jq \
    --arg proto "$proto" \
    --argjson port "$port" \
    '
    # 1) 保证 outbounds 是数组
    .outbounds = (.outbounds // []) |

    # 2) 保证 direct 存在
    (if ([.outbounds[]?.tag] | index("direct")) == null then
       .outbounds += [{"tag":"direct","protocol":"freedom","settings":{}}]
     else . end) |

    # 3) 插入或更新 proxy_via_mihomo
    (if ([.outbounds[]?.tag] | index("proxy_via_mihomo")) == null then
       .outbounds += [{
         "tag":"proxy_via_mihomo",
         "protocol":$proto,
         "settings":{"servers":[{"address":"127.0.0.1","port":$port}]}
       }]
     else
       .outbounds |= map(
         if .tag=="proxy_via_mihomo" then
           .protocol=$proto |
           .settings.servers=[{"address":"127.0.0.1","port":$port}]
         else . end
       )
     end) |

    # 4) routing 结构保证存在
    .routing = (.routing // {}) |
    .routing.rules = (.routing.rules // []) |

    # 5) 如果没有默认走 mihomo 的兜底规则，就追加到最后
    (if ([.routing.rules[]? | select(.outboundTag?=="proxy_via_mihomo")] | length) == 0 then
       .routing.rules += [{"type":"field","network":"tcp,udp","outboundTag":"proxy_via_mihomo"}]
     else . end)
    ' "$XRAY_CFG" >"$tmp" && mv "$tmp" "$XRAY_CFG"

  ok "已写入：Xray 出站 → mihomo（$proto://127.0.0.1:$port）"

  systemctl restart xray >/dev/null 2>&1 || true
  systemctl status xray --no-pager -l | head -n 12 || true
}

mihomo_disable() {
  [[ -f "$XRAY_CFG" ]] || { err "缺少 $XRAY_CFG"; return 1; }
  command -v jq >/dev/null 2>&1 || { err "缺少 jq"; return 1; }

  mihomo_backup_cfg

  local tmp
  tmp="$(mktemp)"

  jq '
    # 删除 outbound proxy_via_mihomo
    .outbounds = (.outbounds // []) | .outbounds |= map(select(.tag!="proxy_via_mihomo")) |

    # 删除 routing 中指向 proxy_via_mihomo 的兜底规则
    .routing = (.routing // {}) |
    .routing.rules = (.routing.rules // []) |
    .routing.rules |= map(select(.outboundTag!="proxy_via_mihomo"))
  ' "$XRAY_CFG" >"$tmp" && mv "$tmp" "$XRAY_CFG"

  ok "已回滚：移除 Xray → mihomo 出站配置"

  systemctl restart xray >/dev/null 2>&1 || true
  systemctl status xray --no-pager -l | head -n 12 || true
}

mihomo_menu() {
  while true; do
    echo
    echo "=============================="
    echo " Xray 出站接入 mihomo 分流"
    echo "=============================="
    echo "1) 查看状态"
    echo "2) 启用：Xray 出站 → mihomo"
    echo "3) 回滚：恢复 Xray 原出站"
    echo "0) 返回"
    read -rp "选择: " c
    case "$c" in
      1) mihomo_status ;;
      2) mihomo_enable ;;
      3) mihomo_disable ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}
uninstall_xsb() {
  echo
  warn "即将卸载 XSB：会删除脚本、systemd 服务、配置文件"
  echo "  - /usr/local/sbin/xsb"
  echo "  - /usr/local/share/xsb/"
  echo "  - /etc/xray/ /etc/sing-box/ /var/lib/xsb/"
  echo
  read -rp "输入 YES 确认卸载： " ans
  [[ "$ans" == "YES" ]] || { warn "已取消"; return 0; }

  # 停止服务（存在就停）
  systemctl disable --now xray 2>/dev/null || true
  systemctl disable --now sing-box 2>/dev/null || true
  systemctl disable --now xsb-proxy 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

  # 删除脚本与目录
  rm -f /usr/local/sbin/xsb 2>/dev/null || true
  rm -rf /usr/local/share/xsb 2>/dev/null || true

  # 删除配置（你不想删配置的话，把这几行注释掉即可）
  rm -rf /etc/xray /etc/sing-box /var/lib/xsb 2>/dev/null || true

  ok "XSB 已卸载完成 ✅"
  exit 0
}
fw_status() {
  echo
  echo "=============================="
  echo " UFW 状态"
  echo "=============================="

  if ! command -v ufw >/dev/null 2>&1; then
    echo "❌ 未安装 ufw"
    echo "建议执行：apt-get update -y && apt-get install -y ufw"
    return 0
  fi

  echo
  echo ">>> ufw status verbose"
  ufw status verbose || true

  echo
  echo ">>> ufw status numbered"
  ufw status numbered || true
}

need_root
init_meta
init_xray_cfg
init_singbox_cfg
main_menu
