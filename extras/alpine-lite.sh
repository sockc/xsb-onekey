#!/bin/sh
set -eu

REPO="vinchi008/xsb-onekey"
REF="main"
MIRROR="raw"

BIN="/usr/local/sbin/xsb"
SCRIPT="/usr/local/share/xsb/xsb-menu.sh"

XR_BIN="/usr/local/bin/xray"
SB_BIN="/usr/local/bin/sing-box"

XR_CFG="/etc/xray/config.json"
SB_CFG="/etc/sing-box/config.json"

msg(){ echo "[xsb-alpine] $*"; }

raw_url(){
  path="$1"
  case "$MIRROR" in
    ghproxy) echo "https://ghproxy.com/https://raw.githubusercontent.com/${REPO}/${REF}/${path}" ;;
    *) echo "https://raw.githubusercontent.com/${REPO}/${REF}/${path}" ;;
  esac
}

apk_add(){
  apk add --no-cache "$@" >/dev/null 2>&1
}

ensure_deps(){
  msg "安装最小依赖..."
  apk_add bash curl jq openssl iproute2 ca-certificates
}

write_launcher(){
  mkdir -p "$(dirname "$BIN")" "$(dirname "$SCRIPT")"
  cat > "$BIN" <<EOF
#!/usr/bin/env bash
exec bash "$SCRIPT"
EOF
  chmod +x "$BIN"
}

write_openrc_service(){
  mkdir -p /etc/init.d /var/log

  # xray openrc
  cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run
name="xray"
command="/usr/local/bin/xray"
command_args="run -config /etc/xray/config.json"
command_background="yes"
output_log="/var/log/xray.log"
error_log="/var/log/xray.err.log"
pidfile="/run/xray.pid"

depend() {
  need net
}
EOF
  chmod +x /etc/init.d/xray
  rc-update add xray default >/dev/null 2>&1 || true

  # sing-box openrc
  cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
name="sing-box"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err.log"
pidfile="/run/sing-box.pid"

depend() {
  need net
}
EOF
  chmod +x /etc/init.d/sing-box
  rc-update add sing-box default >/dev/null 2>&1 || true
}

write_systemctl_shim(){
  # 只在 Alpine 安装 shim，让 full 菜单不报 systemctl missing
  cat > /usr/local/bin/systemctl <<'EOF'
#!/bin/sh
# Minimal systemctl shim for Alpine(OpenRC)
set -eu

cmd="${1:-}"; svc="${2:-}"
shift 2 || true

svc_map(){
  case "$1" in
    xray) echo "xray" ;;
    sing-box) echo "sing-box" ;;
    *) echo "$1" ;;
  esac
}

s="$(svc_map "$svc")"

case "$cmd" in
  restart) service "$s" restart >/dev/null 2>&1 || service "$s" start >/dev/null 2>&1 || true ;;
  start) service "$s" start >/dev/null 2>&1 || true ;;
  stop) service "$s" stop >/dev/null 2>&1 || true ;;
  status) service "$s" status || true ;;
  enable)
    # systemctl enable --now xxx
    if [ "${1:-}" = "--now" ]; then
      rc-update add "$s" default >/dev/null 2>&1 || true
      service "$s" start >/dev/null 2>&1 || true
    else
      rc-update add "$s" default >/dev/null 2>&1 || true
    fi
    ;;
  *) echo "systemctl shim: unsupported: $cmd $svc" ;;
esac
EOF
  chmod +x /usr/local/bin/systemctl
}

write_journalctl_shim(){
  cat > /usr/local/bin/journalctl <<'EOF'
#!/bin/sh
# Minimal journalctl shim for Alpine(OpenRC)
set -eu
# Support: journalctl -u xray --no-pager -n 120
svc=""
n="120"
while [ $# -gt 0 ]; do
  case "$1" in
    -u) svc="${2:-}"; shift 2 ;;
    -n) n="${2:-120}"; shift 2 ;;
    *) shift ;;
  esac
done

case "$svc" in
  xray) log="/var/log/xray.log" ;;
  sing-box) log="/var/log/sing-box.log" ;;
  *) log="/var/log/messages" ;;
esac

[ -f "$log" ] || { echo "no log: $log"; exit 0; }
tail -n "$n" "$log" 2>/dev/null || true
EOF
  chmod +x /usr/local/bin/journalctl
}

download_full_menu(){
  url="$(raw_url "xsb-menu.sh")"
  msg "下载 Full 菜单：$url"
  curl -fsSL "$url" -o "$SCRIPT"
  chmod +x "$SCRIPT"
}

main(){
  ensure_deps
  mkdir -p /etc/xray /etc/sing-box

  # 不强制生成 config，交给菜单去做（保持最小化）
  [ -f "$XR_CFG" ] || echo '{"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}]}' > "$XR_CFG"
  [ -f "$SB_CFG" ] || echo '{"log":{"level":"warn"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' > "$SB_CFG"

  download_full_menu
  write_launcher
  write_openrc_service
  write_systemctl_shim
  write_journalctl_shim

  msg "✅ Alpine Lite 安装完成：运行 xsb"
  exec "$BIN"
}

main
