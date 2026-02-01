#!/bin/sh
set -eu

# ==============================
# Paths
# ==============================
XSB_DIR="/etc/xsb"
SB_DIR="/etc/sing-box"
XR_DIR="/etc/xray"
SB_CFG="$SB_DIR/config.json"
XR_CFG="$XR_DIR/config.json"

SB_IN_DIR="$XSB_DIR/singbox_inbounds.d"
XR_IN_DIR="$XSB_DIR/xray_inbounds.d"
LINK_DIR="$XSB_DIR/links"

MOD_CACHE_DIR="/etc/xsb/modules"
MOD_TMP_DIR="/tmp/xsb/modules"

msg(){ echo "[xsb-openwrt] $*" >&2; }

# ==============================
# UI helpers
# ==============================
safe_call(){
  fn="$1"
  if command -v "$fn" >/dev/null 2>&1; then
    "$fn"
  else
    printf "?"
  fi
}

screen_top(){
  # clear + home
  printf "\033[2J\033[H"
}

pause(){
  printf "回车返回菜单..."
  read _ || true
}

# ==============================
# Status badges
# ==============================
sb_status_badge(){
  if command -v sing-box >/dev/null 2>&1; then
    if [ -x /etc/init.d/sing-box ] && /etc/init.d/sing-box status 2>/dev/null | grep -qi running; then
      printf "✅"
    else
      printf "⚠️"
    fi
  else
    printf "❌"
  fi
}

xr_status_badge(){
  if command -v xray >/dev/null 2>&1; then
    if [ -x /etc/init.d/xray ] && /etc/init.d/xray status 2>/dev/null | grep -qi running; then
      printf "✅"
    elif [ -x /etc/init.d/xray-core ] && /etc/init.d/xray-core status 2>/dev/null | grep -qi running; then
      printf "✅"
    else
      printf "⚠️"
    fi
  else
    printf "❌"
  fi
}

gw_status_badge(){
  if [ -x /etc/init.d/xsb-gw ]; then
    if /etc/init.d/xsb-gw status 2>/dev/null | grep -qi running; then
      route="A"; mode="redirect"
      [ -f /etc/xsb/gateway/route_mode ] && route="$(tr -d '\r\n' </etc/xsb/gateway/route_mode 2>/dev/null || echo A)"
      [ -f /etc/xsb/gateway/mode ] && mode="$(tr -d '\r\n' </etc/xsb/gateway/mode 2>/dev/null || echo redirect)"
      upmode="$(echo "$mode" | tr '[:lower:]' '[:upper:]')"
      printf "✅(路线%s/%s)" "$route" "$upmode"
    else
      printf "⚠️(已安装/未运行)"
    fi
  else
    printf "❌(未启用)"
  fi
}

# ==============================
# Repo / module loader
# ==============================
REPO="${REPO:-sockc/1234xsb-onekey-}"
REF="${REF:-main}"
MIRROR="${MIRROR:-raw}"

MOD_BASE_URL="https://raw.githubusercontent.com/${REPO}/${REF}/extras"

dl(){
  url="$1"; out="$2"
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url" && return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out" && return 0
  fi
  return 1
}

ensure_mod_dirs(){
  mkdir -p "$MOD_CACHE_DIR" "$MOD_TMP_DIR" >/dev/null 2>&1 || true
}

mod_load(){
  mod="$1"
  ensure_mod_dirs

  repo="${REPO:-sockc/1234xsb-onekey-}"
  ref="${REF:-main}"
  url="https://raw.githubusercontent.com/${repo}/${ref}/extras/$mod"

  local_file="$MOD_CACHE_DIR/$mod"
  tmp_file="$MOD_TMP_DIR/$mod"

  # cache exists
  if [ -f "$local_file" ]; then
    . "$local_file" || return 1
    return 0
  fi

  # ensure ca for https (best-effort)
  opkg list-installed 2>/dev/null | grep -q "^ca-bundle " || {
    opkg update >/dev/null 2>&1 || true
    opkg install ca-bundle >/dev/null 2>&1 || true
  }

  msg "mod_load: $mod"
  msg "URL: $url"

  if ! dl "$url" "$tmp_file" 2>/tmp/xsb_mod_dl_err.log; then
    msg "❌ 下载失败：$url"
    [ -s /tmp/xsb_mod_dl_err.log ] && sed 's/^/[xsb-openwrt] /' /tmp/xsb_mod_dl_err.log >&2
    return 1
  fi

  cp -a "$tmp_file" "$local_file" 2>/dev/null || true
  chmod +x "$local_file" 2>/dev/null || true

  if ! . "$local_file" 2>/tmp/xsb_mod_source_err.log; then
    msg "❌ source 模块失败：$local_file"
    [ -s /tmp/xsb_mod_source_err.log ] && sed 's/^/[xsb-openwrt] /' /tmp/xsb_mod_source_err.log >&2
    return 1
  fi

  return 0
}

# ==============================
# Random utils
# ==============================
rand_hex(){
  n="$1"
  hexdump -vn "$n" -e '/1 "%02x"' /dev/urandom 2>/dev/null || echo "deadbeef"
}
rand_uuid(){
  cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000"
}
rand_port(){
  echo $((20000 + (RANDOM % 30000)))
}

# ==============================
# Package / dirs
# ==============================
need_pkg(){
  pkg="$1"
  opkg list-installed 2>/dev/null | grep -q "^$pkg " && return 0
  msg "安装依赖：$pkg"
  opkg update >/dev/null 2>&1 || true
  opkg install "$pkg" >/dev/null 2>&1 || true
}

ensure_dirs(){
  mkdir -p "$XSB_DIR" "$SB_DIR" "$XR_DIR" "$SB_IN_DIR" "$XR_IN_DIR" "$LINK_DIR" >/dev/null 2>&1 || true
}

ensure_ss(){
  command -v ss >/dev/null 2>&1 && return 0
  msg "检测到缺少 ss（用于查看端口监听），尝试安装 ip-full..."
  need_pkg "ip-full"
  command -v ss >/dev/null 2>&1 && return 0
  msg "ip-full 未提供 ss，尝试安装 iproute2..."
  need_pkg "iproute2"
  command -v ss >/dev/null 2>&1 && return 0
  msg "⚠️ 仍然没有 ss，可用 netstat：opkg install net-tools"
  return 1
}

ensure_openssl(){
  command -v openssl >/dev/null 2>&1 && return 0
  need_pkg "openssl-util" || need_pkg "openssl" || true
}

ensure_base64(){
  command -v base64 >/dev/null 2>&1 && return 0
  need_pkg "coreutils-base64" || true
  command -v base64 >/dev/null 2>&1 && return 0
  return 1
}

# ==============================
# Firewall allow ports (UCI)
# ==============================
fw_rule_exists(){
  rname="$1"
  uci -q show firewall 2>/dev/null | grep -q "name='$rname'" && return 0
  return 1
}

fw_allow_tcp(){
  port="$1"
  rname="Allow-XSB-TCP-$port"
  fw_rule_exists "$rname" && { msg "ℹ️ 防火墙规则已存在：$rname"; return 0; }

  uci -q add firewall rule >/dev/null
  sec="$(uci -q show firewall | awk -F= '/=rule/{print $1}' | tail -n1)"
  uci -q set "${sec}.name=$rname"
  uci -q set "${sec}.src=wan"
  uci -q set "${sec}.proto=tcp"
  uci -q set "${sec}.dest_port=$port"
  uci -q set "${sec}.target=ACCEPT"
  uci -q commit firewall
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
  msg "✅ 已放行 TCP 端口：$port"
}

fw_allow_udp(){
  port="$1"
  rname="Allow-XSB-UDP-$port"
  fw_rule_exists "$rname" && { msg "ℹ️ 防火墙规则已存在：$rname"; return 0; }

  uci -q add firewall rule >/dev/null
  sec="$(uci -q show firewall | awk -F= '/=rule/{print $1}' | tail -n1)"
  uci -q set "${sec}.name=$rname"
  uci -q set "${sec}.src=wan"
  uci -q set "${sec}.proto=udp"
  uci -q set "${sec}.dest_port=$port"
  uci -q set "${sec}.target=ACCEPT"
  uci -q commit firewall
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
  msg "✅ 已放行 UDP 端口：$port"
}

fw_show_rules(){
  echo
  echo "=============================="
  echo " XSB 放行规则（firewall）"
  echo "=============================="
  uci -q show firewall 2>/dev/null | grep -E "name='Allow-XSB-(TCP|UDP)-" || echo "（暂无）"
  echo
}

# ==============================
# Services (procd init scripts)
# ==============================
ensure_xray_service(){
  if command -v xray >/dev/null 2>&1; then
    if [ ! -x /etc/init.d/xray ] && [ ! -x /etc/init.d/xray-core ]; then
      msg "检测到已安装 xray（二进制存在），但缺少 /etc/init.d/xray，正在自动创建..."
      cat > /etc/init.d/xray <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10
start_service() {
  procd_open_instance
  procd_set_param command /usr/bin/xray run -config /etc/xray/config.json
  procd_set_param respawn 3600 5 5
  procd_close_instance
}
EOF
      chmod +x /etc/init.d/xray
      /etc/init.d/xray enable >/dev/null 2>&1 || true
      msg "✅ 已创建并启用 /etc/init.d/xray"
    fi
  fi
}

ensure_singbox_service(){
  if command -v sing-box >/dev/null 2>&1; then
    if [ ! -x /etc/init.d/sing-box ]; then
      msg "检测到已安装 sing-box（二进制存在），但缺少 /etc/init.d/sing-box，正在自动创建..."
      cat > /etc/init.d/sing-box <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10
start_service() {
  procd_open_instance
  procd_set_param command /usr/bin/sing-box run -c /etc/sing-box/config.json
  procd_set_param respawn 3600 5 5
  procd_close_instance
}
EOF
      chmod +x /etc/init.d/sing-box
      /etc/init.d/sing-box enable >/dev/null 2>&1 || true
      msg "✅ 已创建并启用 /etc/init.d/sing-box"
    fi
  fi
}

svc_sb(){
  ensure_singbox_service
  if [ -x /etc/init.d/sing-box ]; then
    /etc/init.d/sing-box "$1" >/dev/null 2>&1 || true
  else
    msg "未发现 /etc/init.d/sing-box（建议 opkg 安装 sing-box / sing-box-tiny）"
  fi
}

svc_xr(){
  ensure_xray_service
  if [ -x /etc/init.d/xray ]; then
    /etc/init.d/xray "$1" >/dev/null 2>&1 || true
  elif [ -x /etc/init.d/xray-core ]; then
    /etc/init.d/xray-core "$1" >/dev/null 2>&1 || true
  else
    msg "未发现 /etc/init.d/xray（已装 xray-core 也可能缺脚本）"
  fi
}

install_singbox(){
  opkg update >/dev/null 2>&1 || true
  opkg install sing-box >/dev/null 2>&1 || opkg install sing-box-tiny >/dev/null 2>&1 || true
  if command -v sing-box >/dev/null 2>&1; then
    ensure_singbox_service
    msg "✅ sing-box 安装完成"
    return 0
  fi
  msg "❌ sing-box 安装失败：未找到 sing-box 命令"
  return 1
}

install_xray(){
  opkg update >/dev/null 2>&1 || true
  opkg install xray-core >/dev/null 2>&1 || opkg install xray >/dev/null 2>&1 || true
  if command -v xray >/dev/null 2>&1; then
    ensure_xray_service
    msg "✅ xray 安装完成"
    return 0
  fi
  msg "❌ xray 安装失败：未找到 xray 命令"
  return 1
}

# ==============================
# xsb shortcut
# ==============================
ensure_xsb_cmd(){
  if [ -x /usr/bin/xsb ]; then return 0; fi
  cat > /usr/bin/xsb <<'EOF'
#!/bin/sh
if [ -f /etc/xsb/openwrt-tiny.sh ]; then
  sh /etc/xsb/openwrt-tiny.sh
  exit $?
fi
echo "[xsb-openwrt] 未找到 /etc/xsb/openwrt-tiny.sh"
exit 1
EOF
  chmod +x /usr/bin/xsb
  msg "✅ 已创建快捷命令：xsb"
}

# ==============================
# Links store/show
# ==============================
save_link(){
  name="$1"; link="$2"
  [ -n "${name:-}" ] || return 0
  [ -n "${link:-}" ] || return 0
  mkdir -p "$LINK_DIR" >/dev/null 2>&1 || true
  printf '%s\n' "$link" > "$LINK_DIR/$name.link"
}

show_links(){
  ensure_dirs
  echo
  echo "=============================="
  echo " XSB 分享链接列表"
  echo "=============================="
  if ! ls "$LINK_DIR"/*.link >/dev/null 2>&1; then
    echo "暂无分享链接（请先添加入站）"
    return 0
  fi
  for f in "$LINK_DIR"/*.link; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .link)"
    echo
    echo "[$n]"
    cat "$f"
  done
  echo
  echo "提示：长按复制即可"
}

# ==============================
# Cert for sing-box
# ==============================
gen_cert(){
  ensure_openssl
  mkdir -p "$XSB_DIR/certs" >/dev/null 2>&1 || true
  crt="$XSB_DIR/certs/server.crt"
  key="$XSB_DIR/certs/server.key"
  if [ -f "$crt" ] && [ -f "$key" ]; then
    echo "$crt|$key"; return 0
  fi
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -subj "/CN=xsb-openwrt" \
    -keyout "$key" -out "$crt" >/dev/null 2>&1
  echo "$crt|$key"
}

# ==============================
# Safe write configs
# ==============================
write_sb_config(){
  tmp="/tmp/sing-box-config.json"
  bak="$SB_CFG.bak.$(date +%F-%H%M%S)"
  {
    echo '{'
    echo '  "log": {"level":"info"},'
    echo '  "inbounds": ['
    first=1
    for f in "$SB_IN_DIR"/*.json; do
      [ -f "$f" ] || continue
      [ "$first" -eq 1 ] && first=0 || echo ','
      cat "$f"
    done
    echo '  ],'
    echo '  "outbounds": [{"type":"direct","tag":"direct"}]'
    echo '}'
  } > "$tmp"

  mkdir -p "$SB_DIR" >/dev/null 2>&1 || true

  if command -v sing-box >/dev/null 2>&1; then
    if ! sing-box check -c "$tmp" >/dev/null 2>&1; then
      msg "❌ sing-box 配置校验失败，已阻止覆盖 $SB_CFG（避免崩溃循环）"
      sing-box check -c "$tmp" 2>&1 | sed 's/^/[sing-box-check] /' >&2 || true
      msg "临时文件：$tmp"
      return 1
    fi
  else
    msg "⚠️ 未安装 sing-box，已生成配置但未校验：$tmp"
  fi

  [ -f "$SB_CFG" ] && cp -a "$SB_CFG" "$bak" 2>/dev/null || true
  mv "$tmp" "$SB_CFG"
  msg "✅ 已写入 $SB_CFG"
  return 0
}

write_xr_config(){
  tmp="/tmp/xray-config.json"
  {
    echo '{'
    echo '  "log": {"loglevel": "warning"},'
    echo '  "inbounds": ['
    first=1
    for f in "$XR_IN_DIR"/*.json; do
      [ -f "$f" ] || continue
      [ "$first" -eq 1 ] && first=0 || echo ','
      cat "$f"
    done
    echo '  ],'
    echo '  "outbounds": [{"protocol":"freedom","tag":"direct"}]'
    echo '}'
  } > "$tmp"

  mkdir -p "$XR_DIR" >/dev/null 2>&1 || true
  mv "$tmp" "$XR_CFG"
  msg "✅ 已写入 $XR_CFG"
}

# ==============================
# Public endpoint prefer IPv6
# ==============================
format_host(){
  h="$1"
  echo "$h" | grep -q ":" && echo "[$h]" || echo "$h"
}
get_public_v6(){ wget -qO- -6 https://api64.ipify.org 2>/dev/null || true; }
get_public_v4(){ wget -qO- https://api.ipify.org 2>/dev/null || true; }

guess_ip(){
  ip6="$(get_public_v6)"
  [ -n "${ip6:-}" ] && { echo "$ip6"; return 0; }
  ip4="$(get_public_v4)"
  [ -n "${ip4:-}" ] && { echo "$ip4"; return 0; }
  ip="$(uci get network.wan.ipaddr 2>/dev/null || true)"
  [ -n "${ip:-}" ] && { echo "$ip"; return 0; }
  ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)"
  [ -n "${ip:-}" ] && { echo "$ip"; return 0; }
  echo "YOUR_IP"
}

# ==============================
# Listener check
# ==============================
check_udp_listen(){
  port="$1"
  ensure_ss >/dev/null 2>&1 || return 0
  ss -lunp 2>/dev/null | grep ":$port " >/dev/null 2>&1 && msg "✅ UDP 端口已监听：$port" || msg "⚠️ UDP 端口未监听：$port"
}
check_tcp_listen(){
  port="$1"
  ensure_ss >/dev/null 2>&1 || return 0
  ss -lntp 2>/dev/null | grep ":$port " >/dev/null 2>&1 && msg "✅ TCP 端口已监听：$port" || msg "⚠️ TCP 端口未监听：$port"
}

# ==============================
# Share links builders
# ==============================
make_hy2_link(){
  name="$1"; pw="$2"; port="$3"
  ip="$(guess_ip)"; host="$(format_host "$ip")"
  sni="xsb-openwrt"
  echo "hysteria2://$pw@$host:$port/?insecure=1&sni=$sni#$name"
}
make_tuic_link(){
  name="$1"; uuid="$2"; pw="$3"; port="$4"
  ip="$(guess_ip)"; host="$(format_host "$ip")"
  sni="xsb-openwrt"
  echo "tuic://$uuid:$pw@$host:$port?congestion_control=bbr&alpn=h3&sni=$sni&allow_insecure=1#$name"
}

b64(){
  s="$1"
  if command -v base64 >/dev/null 2>&1; then
    printf '%s' "$s" | base64 | tr -d '\n'
    return 0
  fi
  ensure_base64 || true
  if command -v base64 >/dev/null 2>&1; then
    printf '%s' "$s" | base64 | tr -d '\n'
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    printf '%s' "$s" | openssl base64 -A 2>/dev/null | tr -d '\n'
    return 0
  fi
  msg "❌ 缺少 base64/openssl，无法生成 vmess 链接"
  echo ""
}

make_vmess_ws_link(){
  name="$1"; host="$2"; port="$3"; uuid="$4"; path="$5"; hosthdr="$6"
  j="{\"v\":\"2\",\"ps\":\"$name\",\"add\":\"$host\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$hosthdr\",\"path\":\"$path\",\"tls\":\"\"}"
  echo "vmess://$(b64 "$j")"
}
make_vmess_tcp_http_link(){
  name="$1"; host="$2"; port="$3"; uuid="$4"; path="$5"; hosthdr="$6"
  j="{\"v\":\"2\",\"ps\":\"$name\",\"add\":\"$host\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"net\":\"tcp\",\"type\":\"http\",\"host\":\"$hosthdr\",\"path\":\"$path\",\"tls\":\"\"}"
  echo "vmess://$(b64 "$j")"
}

# ==============================
# Path/Host helpers
# ==============================
pick_ws_path_host(){
  path=""; hosthdr=""
  echo
  echo "Path/Host 输入方式："
  echo "1) 随机生成（推荐）"
  echo "2) 自定义"
  printf "选择: "
  read ph || true
  case "${ph:-1}" in
    2)
      printf "WS path（可空，回车随机，如 /abc123）: "
      read path || true
      [ -n "${path:-}" ] || path="/$(rand_hex 6)"
      printf "Host（伪装域名，可空）: "
      read hosthdr || true
      ;;
    *)
      path="/$(rand_hex 6)"
      hosthdr=""
      msg "✅ 已随机：path=$path host=（空）"
      ;;
  esac
}

pick_http_path_host(){
  path=""; hosthdr=""
  echo
  echo "Path/Host 输入方式："
  echo "1) 默认（path=/，host空）"
  echo "2) 自定义"
  printf "选择: "
  read ph || true
  case "${ph:-1}" in
    2)
      printf "HTTP path（可空，回车默认 /）: "
      read path || true
      [ -n "${path:-}" ] || path="/"
      printf "Host（伪装域名，可空）: "
      read hosthdr || true
      ;;
    *)
      path="/"
      hosthdr=""
      msg "✅ 已默认：path=/ host=（空）"
      ;;
  esac
}

# ==============================
# Add inbounds: sing-box
# ==============================
add_sb_tuic(){
  ensure_dirs
  if ! command -v sing-box >/dev/null 2>&1; then
    msg "⚠️ 未检测到 sing-box，TUIC 需要 sing-box"
    printf "是否现在安装 sing-box？(y/N): "
    read yn || true
    case "${yn:-N}" in y|Y) install_singbox || true ;; *) return 1 ;; esac
  fi

  printf "备注名(如 tuic-sg): "
  read name || true
  [ -n "${name:-}" ] || name="tuic-$(date +%m%d%H%M)"
  printf "监听端口(回车随机): "
  read port || true
  [ -n "${port:-}" ] || port="$(rand_port)"
  uuid="$(rand_uuid)"
  pw="$(rand_hex 16)"

  certpair="$(gen_cert)"
  crt="$(echo "$certpair" | cut -d'|' -f1)"
  key="$(echo "$certpair" | cut -d'|' -f2)"

  f="$SB_IN_DIR/$name.json"
  cat > "$f" <<EOF
{
  "type": "tuic",
  "tag": "$name",
  "listen": "0.0.0.0",
  "listen_port": $port,
  "users": [{
    "uuid": "$uuid",
    "password": "$pw"
  }],
  "congestion_control": "bbr",
  "tls": {
    "enabled": true,
    "server_name": "xsb-openwrt",
    "certificate_path": "$crt",
    "key_path": "$key"
  }
}
EOF

  if write_sb_config; then
    fw_allow_udp "$port"
    svc_sb restart
    link="$(make_tuic_link "$name" "$uuid" "$pw" "$port")"
    save_link "$name" "$link"
    msg "✅ TUIC 已添加：$name 端口 $port"
    msg "链接：$link"
    check_udp_listen "$port"
  else
    msg "❌ TUIC 已写入碎片，但 wrapper 配置校验失败"
  fi
}

add_sb_hy2(){
  ensure_dirs
  if ! command -v sing-box >/dev/null 2>&1; then
    msg "⚠️ 未检测到 sing-box，HY2 需要 sing-box"
    printf "是否现在安装 sing-box？(y/N): "
    read yn || true
    case "${yn:-N}" in y|Y) install_singbox || true ;; *) return 1 ;; esac
  fi

  printf "备注名(如 hy2-sg): "
  read name || true
  [ -n "${name:-}" ] || name="hy2-$(date +%m%d%H%M)"
  printf "监听端口(回车随机): "
  read port || true
  [ -n "${port:-}" ] || port="$(rand_port)"
  pw="$(rand_hex 16)"

  certpair="$(gen_cert)"
  crt="$(echo "$certpair" | cut -d'|' -f1)"
  key="$(echo "$certpair" | cut -d'|' -f2)"

  f="$SB_IN_DIR/$name.json"
  cat > "$f" <<EOF
{
  "type": "hysteria2",
  "tag": "$name",
  "listen": "0.0.0.0",
  "listen_port": $port,
  "users": [{
    "password": "$pw"
  }],
  "tls": {
    "enabled": true,
    "server_name": "xsb-openwrt",
    "certificate_path": "$crt",
    "key_path": "$key"
  }
}
EOF

  if write_sb_config; then
    fw_allow_udp "$port"
    svc_sb restart
    link="$(make_hy2_link "$name" "$pw" "$port")"
    save_link "$name" "$link"
    msg "✅ HY2 已添加：$name 端口 $port"
    msg "链接：$link"
    check_udp_listen "$port"
  else
    msg "❌ HY2 已写入碎片，但 wrapper 配置校验失败"
  fi
}

# ==============================
# Add inbounds: xray
# ==============================
add_xr_vless_reality(){
  ensure_dirs

  if ! command -v xray >/dev/null 2>&1; then
    msg "⚠️ 未检测到 xray，Reality 需要 xray-core"
    printf "是否现在安装 xray-core？(y/N): "
    read yn || true
    case "${yn:-N}" in y|Y) install_xray || true ;; *) return 1 ;; esac
  fi

  printf "备注名(如 reality-sg): "
  read name || true
  [ -n "${name:-}" ] || name="reality-$(date +%m%d%H%M)"
  printf "监听端口(回车随机): "
  read port || true
  [ -n "${port:-}" ] || port="$(rand_port)"
  printf "SNI(默认 www.cloudflare.com): "
  read sni || true
  [ -n "${sni:-}" ] || sni="www.cloudflare.com"

  sid="$(rand_hex 8)"
  uuid="$(rand_uuid)"

  priv=""; pub=""; xout=""

  # Prefer xray x25519; OpenWrt 版本可能用 Password 当 pub
  xout="$(xray x25519 2>/dev/null || true)"
  priv="$(echo "$xout" | grep -Ei 'private[ _-]*key' | head -n1 | sed 's/.*:[[:space:]]*//' | tr -d '\r')"
  pub="$(echo "$xout"  | grep -Ei 'public[ _-]*key|^password' | head -n1 | sed 's/.*:[[:space:]]*//' | tr -d '\r')"

  # fallback: sing-box generate reality-keypair (可选)
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    if command -v sing-box >/dev/null 2>&1; then
      kout="$(sing-box generate reality-keypair 2>/dev/null || true)"
      priv="$(echo "$kout" | grep -E '^PrivateKey:' | head -n1 | sed 's/^PrivateKey:[[:space:]]*//' | tr -d '\r')"
      pub="$(echo "$kout"  | grep -E '^PublicKey:'  | head -n1 | sed 's/^PublicKey:[[:space:]]*//' | tr -d '\r')"
    fi
  fi

  if [ -z "$priv" ] || [ -z "$pub" ]; then
    msg "❌ 获取 Reality Keypair 失败（priv/pub 为空）"
    msg "---- xray x25519 原始输出 ----"
    echo "${xout:-<empty>}" >&2
    msg "-----------------------------"
    msg "请确认：xray-core 已安装且支持：xray x25519"
    return 1
  fi

  f="$XR_IN_DIR/$name.json"
  cat > "$f" <<EOF
{
  "tag": "$name",
  "listen": "0.0.0.0",
  "port": $port,
  "protocol": "vless",
  "settings": {
    "clients": [{ "id": "$uuid", "flow": "xtls-rprx-vision" }],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "$sni:443",
      "xver": 0,
      "serverNames": ["$sni"],
      "privateKey": "$priv",
      "shortIds": ["$sid"]
    }
  }
}
EOF

  write_xr_config
  fw_allow_tcp "$port"
  svc_xr restart

  ip="$(guess_ip)"; host="$(format_host "$ip")"
  link="vless://$uuid@$host:$port?encryption=none&security=reality&sni=$sni&fp=chrome&pbk=$pub&sid=$sid&type=tcp&flow=xtls-rprx-vision#$name"
  save_link "$name" "$link"

  msg "✅ Reality 已添加：$name 端口 $port"
  msg "PublicKey(pbk)=$pub"
  msg "链接：$link"
  check_tcp_listen "$port"
}

add_xr_vmess_ws_notls(){
  ensure_dirs
  if ! command -v xray >/dev/null 2>&1; then
    msg "⚠️ 未检测到 xray，VMess 需要 xray-core"
    printf "是否现在安装 xray-core？(y/N): "
    read yn || true
    case "${yn:-N}" in y|Y) install_xray || true ;; *) return 1 ;; esac
  fi

  printf "备注名(如 vmess-ws-sg): "
  read name || true
  [ -n "${name:-}" ] || name="vmess-ws-$(date +%m%d%H%M)"
  printf "监听端口(回车随机): "
  read port || true
  [ -n "${port:-}" ] || port="$(rand_port)"

  pick_ws_path_host
  uuid="$(rand_uuid)"
  [ -n "${path:-}" ] || path="/"

  if [ -n "${hosthdr:-}" ]; then
    hdr="{\"Host\":\"$hosthdr\"}"
  else
    hdr="{}"
  fi

  f="$XR_IN_DIR/$name.json"
  cat > "$f" <<EOF
{
  "tag": "$name",
  "listen": "0.0.0.0",
  "port": $port,
  "protocol": "vmess",
  "settings": {
    "clients": [{ "id": "$uuid", "alterId": 0 }]
  },
  "streamSettings": {
    "network": "ws",
    "security": "none",
    "wsSettings": {
      "path": "$path",
      "headers": $hdr
    }
  }
}
EOF

  write_xr_config
  fw_allow_tcp "$port"
  svc_xr restart

  ip="$(guess_ip)"
  link="$(make_vmess_ws_link "$name" "$ip" "$port" "$uuid" "$path" "${hosthdr:-}")"
  save_link "$name" "$link"

  msg "✅ VMess WS(noTLS) 已添加：$name 端口 $port"
  msg "链接：$link"
  check_tcp_listen "$port"
}

add_xr_vmess_tcp_http(){
  ensure_dirs
  if ! command -v xray >/dev/null 2>&1; then
    msg "⚠️ 未检测到 xray，VMess 需要 xray-core"
    printf "是否现在安装 xray-core？(y/N): "
    read yn || true
    case "${yn:-N}" in y|Y) install_xray || true ;; *) return 1 ;; esac
  fi

  printf "备注名(如 vmess-tcp-http-sg): "
  read name || true
  [ -n "${name:-}" ] || name="vmess-tcp-http-$(date +%m%d%H%M)"
  printf "监听端口(回车随机): "
  read port || true
  [ -n "${port:-}" ] || port="$(rand_port)"

  pick_http_path_host
  uuid="$(rand_uuid)"
  [ -n "${path:-}" ] || path="/"

  if [ -n "${hosthdr:-}" ]; then
    hh="{\"Host\":[\"$hosthdr\"]}"
  else
    hh="{}"
  fi

  f="$XR_IN_DIR/$name.json"
  cat > "$f" <<EOF
{
  "tag": "$name",
  "listen": "0.0.0.0",
  "port": $port,
  "protocol": "vmess",
  "settings": {
    "clients": [{ "id": "$uuid", "alterId": 0 }]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "none",
    "tcpSettings": {
      "header": {
        "type": "http",
        "request": {
          "path": ["$path"],
          "headers": $hh
        }
      }
    }
  }
}
EOF

  write_xr_config
  fw_allow_tcp "$port"
  svc_xr restart

  ip="$(guess_ip)"
  link="$(make_vmess_tcp_http_link "$name" "$ip" "$port" "$uuid" "$path" "${hosthdr:-}")"
  save_link "$name" "$link"

  msg "✅ VMess TCP+HTTP 已添加：$name 端口 $port"
  msg "链接：$link"
  check_tcp_listen "$port"
}

# ==============================
# Inbound management (delete/rename/port/open/list)
# ==============================
list_inbounds(){
  kind="$1" # xr|sb
  dir="$XR_IN_DIR"; [ "$kind" = "sb" ] && dir="$SB_IN_DIR"
  echo
  echo "=============================="
  echo " 入站列表：$kind"
  echo "=============================="
  if ! ls "$dir"/*.json >/dev/null 2>&1; then
    echo "（暂无）"
    return 0
  fi
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .json)"
    # 尝试抽 port
    p="$(grep -E '"port"[[:space:]]*:' "$f" 2>/dev/null | head -n1 | sed -E 's/.*"port"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/' || true)"
    [ -z "${p:-}" ] && p="$(grep -E '"listen_port"[[:space:]]*:' "$f" 2>/dev/null | head -n1 | sed -E 's/.*"listen_port"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/' || true)"
    printf "%s  (port=%s)\n" "$n" "${p:-?}"
  done
}

delete_inbound(){
  kind="$1" # xr|sb
  dir="$XR_IN_DIR"; [ "$kind" = "sb" ] && dir="$SB_IN_DIR"

  list_inbounds "$kind"
  echo
  printf "输入要删除的备注名: "
  read name || true
  [ -n "${name:-}" ] || return 0
  rm -f "$dir/$name.json" 2>/dev/null || true
  rm -f "$LINK_DIR/$name.link" 2>/dev/null || true

  if [ "$kind" = "sb" ]; then
    write_sb_config && svc_sb restart
  else
    write_xr_config && svc_xr restart
  fi
  msg "✅ 已删除：$name"
}

rename_inbound(){
  kind="$1" # xr|sb
  dir="$XR_IN_DIR"; [ "$kind" = "sb" ] && dir="$SB_IN_DIR"

  list_inbounds "$kind"
  echo
  printf "输入要改名的旧备注名: "
  read old || true
  [ -n "${old:-}" ] || return 0
  [ -f "$dir/$old.json" ] || { msg "❌ 不存在：$old"; return 1; }

  printf "输入新备注名: "
  read new || true
  [ -n "${new:-}" ] || { msg "❌ 新备注名为空"; return 1; }

  mv "$dir/$old.json" "$dir/$new.json" 2>/dev/null || true
  [ -f "$LINK_DIR/$old.link" ] && mv "$LINK_DIR/$old.link" "$LINK_DIR/$new.link" 2>/dev/null || true

  # 重新生成 wrapper config
  if [ "$kind" = "sb" ]; then
    write_sb_config && svc_sb restart
  else
    write_xr_config && svc_xr restart
  fi

  msg "✅ 已改名：$old -> $new"
}

allow_port_for_inbound(){
  kind="$1" # xr|sb
  dir="$XR_IN_DIR"; [ "$kind" = "sb" ] && dir="$SB_IN_DIR"

  list_inbounds "$kind"
  echo
  printf "输入备注名（自动读取端口并放行）: "
  read name || true
  [ -n "${name:-}" ] || return 0
  f="$dir/$name.json"
  [ -f "$f" ] || { msg "❌ 不存在：$name"; return 1; }

  p="$(grep -E '"port"[[:space:]]*:' "$f" 2>/dev/null | head -n1 | sed -E 's/.*"port"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/' || true)"
  [ -z "${p:-}" ] && p="$(grep -E '"listen_port"[[:space:]]*:' "$f" 2>/dev/null | head -n1 | sed -E 's/.*"listen_port"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/' || true)"
  [ -n "${p:-}" ] || { msg "❌ 读取端口失败"; return 1; }

  # sb: tuic/hy2 are UDP; xr: ws/http/reality are TCP
  if [ "$kind" = "sb" ]; then
    fw_allow_udp "$p"
  else
    fw_allow_tcp "$p"
  fi
  msg "✅ 已按入站放行端口：$p"
}

inbound_manage_menu(){
  while true; do
    echo
    echo "=============================="
    echo " 入站管理"
    echo "=============================="
    echo "1) 查看 Xray 入站列表"
    echo "2) 查看 sing-box 入站列表"
    echo "3) 删除 Xray 入站"
    echo "4) 删除 sing-box 入站"
    echo "5) 改名 Xray 入站"
    echo "6) 改名 sing-box 入站"
    echo "7) 一键放行端口（按 Xray 入站）"
    echo "8) 一键放行端口（按 sing-box 入站）"
    echo "9) 查看已放行的 XSB 端口规则"
    echo "0) 返回"
    printf "选择: "
    read c || true
    case "${c:-}" in
      1) list_inbounds xr; pause ;;
      2) list_inbounds sb; pause ;;
      3) delete_inbound xr; pause ;;
      4) delete_inbound sb; pause ;;
      5) rename_inbound xr; pause ;;
      6) rename_inbound sb; pause ;;
      7) allow_port_for_inbound xr; pause ;;
      8) allow_port_for_inbound sb; pause ;;
      9) fw_show_rules; pause ;;
      0) return 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

# ==============================
# Status
# ==============================
status_all(){
  echo
  msg "=== sing-box ==="
  if [ -x /etc/init.d/sing-box ]; then
    /etc/init.d/sing-box status || true
  elif command -v sing-box >/dev/null 2>&1; then
    echo "已安装（检测到 /usr/bin/sing-box，但缺少 /etc/init.d/sing-box）"
  else
    echo "未安装"
  fi

  msg "=== xray ==="
  if [ -x /etc/init.d/xray ] || [ -x /etc/init.d/xray-core ]; then
    /etc/init.d/xray status 2>/dev/null || /etc/init.d/xray-core status 2>/dev/null || true
  elif command -v xray >/dev/null 2>&1; then
    echo "已安装（检测到 /usr/bin/xray，但缺少 /etc/init.d/xray 服务脚本）"
  else
    echo "未安装"
  fi

  echo
  ensure_ss >/dev/null 2>&1 || true
  if command -v ss >/dev/null 2>&1; then
    msg "=== 端口监听（ss）==="
    ss -lntup 2>/dev/null | grep -E 'xray|sing-box' || true
  else
    msg "=== 端口监听 ==="
    netstat -lntup 2>/dev/null | grep -E 'xray|sing-box' || true
  fi
  echo
}
# ==============================
# Uninstall logic
# ==============================
uninstall_service() {
  echo
  echo "--- 卸载中心 ---"
  echo "1) 卸载 sing-box"
  echo "2) 卸载 xray"
  echo "3) 全部卸载 (SB + XR + 网关)"
  echo "0) 取消"
  printf "选择: "
  read c || true

  [ "${c:-0}" -eq 0 ] && return 0

  printf "是否同时清理所有配置、证书和链接文件？(y/N): "
  read clean || true
  
  case "$c" in
    1)
      svc_sb stop
      opkg remove sing-box sing-box-tiny >/dev/null 2>&1 || true
      rm -f /etc/init.d/sing-box 2>/dev/null || true
      msg "✅ sing-box 程序已卸载"
      ;;
    2)
      svc_xr stop
      opkg remove xray-core xray >/dev/null 2>&1 || true
      rm -f /etc/init.d/xray /etc/init.d/xray-core 2>/dev/null || true
      msg "✅ xray 程序已卸载"
      ;;
    3)
      svc_sb stop; svc_xr restart
      [ -x /etc/init.d/xsb-gw ] && /etc/init.d/xsb-gw stop 2>/dev/null || true
      opkg remove sing-box sing-box-tiny xray-core xray >/dev/null 2>&1 || true
      rm -f /etc/init.d/sing-box /etc/init.d/xray /etc/init.d/xray-core /etc/init.d/xsb-gw 2>/dev/null || true
      msg "✅ 所有程序已卸载"
      ;;
  esac

  if [ "$clean" = "y" ] || [ "$clean" = "Y" ]; then
    rm -rf "$XSB_DIR" "$SB_DIR" "$XR_DIR" "$MOD_CACHE_DIR" 2>/dev/null || true
    rm -f /usr/bin/xsb 2>/dev/null || true
    msg "🔥 所有配置文件及快捷命令已清理"
  else
    msg "ℹ️ 已保留配置目录，方便下次重装"
  fi
}

# ==============================
# Menus
# ==============================
install_menu(){
  echo
  echo "OpenWrt Tiny 安装："
  echo "1) 安装 sing-box"
  echo "2) 安装 xray"
  echo "3) 都安装"
  echo "0) 返回"
  printf "选择: "
  read c || true
  case "${c:-}" in
    1) install_singbox ;;
    2) install_xray ;;
    3) install_singbox || true; install_xray || true ;;
    *) return 0 ;;
  esac
}

inbound_menu(){
  while true; do
    echo
    echo "=============================="
    echo " 添加入站"
    echo "=============================="
    echo
    echo "[Xray 入站]"
    echo "1) VLESS + Reality"
    echo "2) VMess + WS (noTLS)"
    echo "3) VMess + TCP + HTTP"
    echo
    echo "[sing-box 入站]"
    echo "4) TUIC"
    echo "5) Hysteria2 / HY2"
    echo
    echo "0) 返回"
    printf "选择: "
    read c || true
    case "${c:-}" in
      1) add_xr_vless_reality; pause ;;
      2) add_xr_vmess_ws_notls; pause ;;
      3) add_xr_vmess_tcp_http; pause ;;
      4) add_sb_tuic; pause ;;
      5) add_sb_hy2; pause ;;
      0) return 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

gateway_menu(){
  # 不强依赖模块：没有就提示
  if mod_load "openwrt-mod-proxy.sh"; then
    if command -v proxy_gateway_menu >/dev/null 2>&1; then
      proxy_gateway_menu
      return 0
    fi
    msg "⚠️ 网关模块已加载，但未导出 proxy_gateway_menu"
    pause
    return 1
  fi
  msg "❌ 加载网关模块失败：openwrt-mod-proxy.sh"
  msg "请确认：REPO=$REPO  REF=$REF  文件路径 extras/openwrt-mod-proxy.sh 存在"
  pause
  return 1
}

render_main_menu(){
  screen_top
  echo "=============================="
  echo " XSB OpenWrt Tiny"
  echo "=============================="
  echo "入站(Server):  sing-box  $(safe_call sb_status_badge)   xray  $(safe_call xr_status_badge)"
  echo "出站(GW):      $(safe_call gw_status_badge)"
  echo "------------------------------"
  echo "[入站 · 节点服务器]"
  echo "1) 添加入站（Xray/sing-box）"
  echo "2) 分享链接中心（查看）"
  echo "3) 入站管理（删除/改名/查看端口/一键放行）"
  echo
  echo "[出站 · 透明网关]"
  echo "6) 透明代理网关（路线A/B）"
  echo
  echo "[系统]"
  echo "4) 安装/更新（sing-box / xray）"
  echo "5) 重启服务"
  echo "7) 查看状态"
  echo "8) 查看防火墙放行规则"
  echo "9) 卸载功能"
  echo "------------------------------"
  echo "0) 退出   r) 刷新   (回车=刷新)"
  printf "选择: "
}

main(){
  ensure_dirs
  ensure_xsb_cmd
  msg "进入 OpenWrt Tiny 模式（最小化）"

  while true; do
    render_main_menu
    read c || true
    case "${c:-}" in
      r|"") : ;;
      1) inbound_menu ;;
      2) show_links; pause ;;
      3) inbound_manage_menu ;;
      4) install_menu; pause ;;
      5) svc_sb restart; svc_xr restart; msg "✅ 已重启"; pause ;;
      6) gateway_menu ;;
      7) status_all; pause ;;
      8) fw_show_rules; pause ;;
      9) uninstall_service; pause ;;
      0) exit 0 ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

main
