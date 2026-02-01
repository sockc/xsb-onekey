#!/bin/sh
set -eu

XSB_DIR="/etc/xsb"
SB_DIR="/etc/sing-box"
XR_DIR="/etc/xray"
SB_CFG="$SB_DIR/config.json"
XR_CFG="$XR_DIR/config.json"

SB_IN_DIR="$XSB_DIR/singbox_inbounds.d"
XR_IN_DIR="$XSB_DIR/xray_inbounds.d"
LINK_DIR="$XSB_DIR/links"

msg(){ echo "[xsb-openwrt] $*" >&2; }

# ===== Modules (persistent preferred) =====
MOD_DIR="/etc/xsb/modules"
MOD_TMP="/tmp/xsb/modules"
MOD_BASE_URL="https://raw.githubusercontent.com/${REPO:-sockc/1234xsb-onekey-}/${REF:-main}/extras"

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

ensure_mod_dir(){
  mkdir -p "$MOD_DIR" >/dev/null 2>&1 || true
  [ -w "$MOD_DIR" ] || { mkdir -p "$MOD_TMP" >/dev/null 2>&1 || true; MOD_DIR="$MOD_TMP"; }
}

mod_fetch(){
  f="$1"
  ensure_mod_dir
  dst="$MOD_DIR/$f"
  [ -f "$dst" ] && return 0
  url="$MOD_BASE_URL/$f"
  msg "下载模块：$f"
  dl "$url" "$dst" || { msg "❌ 模块下载失败：$url"; return 1; }
  chmod +x "$dst" >/dev/null 2>&1 || true
  return 0
}

mod_load(){
  mod="$1"

  repo="${REPO:-sockc/1234xsb-onekey-}"
  ref="${REF:-main}"
  base="https://raw.githubusercontent.com/${repo}/${ref}/extras"
  url="$base/$mod"

  mkdir -p /etc/xsb/modules /tmp/xsb/modules >/dev/null 2>&1 || true
  local_file="/etc/xsb/modules/$mod"
  tmp_file="/tmp/xsb/modules/$mod"

  # 已缓存直接 source
  if [ -f "$local_file" ]; then
    . "$local_file" || return 1
    return 0
  fi

  # 缺 CA 会导致 https 下载失败
  opkg list-installed 2>/dev/null | grep -q "^ca-bundle " || {
    opkg update >/dev/null 2>&1 || true
    opkg install ca-bundle >/dev/null 2>&1 || true
  }

  msg "mod_load: $mod"
  msg "URL: $url"

  dl_ok=0
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp_file" "$url" 2>/tmp/xsb_mod_err.log && dl_ok=1 || dl_ok=0
  fi
  if [ "$dl_ok" -eq 0 ] && command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tmp_file" 2>/tmp/xsb_mod_err.log && dl_ok=1 || dl_ok=0
  fi

  if [ "$dl_ok" -eq 0 ]; then
    msg "❌ 下载失败：$url"
    [ -s /tmp/xsb_mod_err.log ] && sed 's/^/[xsb-openwrt] /' /tmp/xsb_mod_err.log
    return 1
  fi

  cp -a "$tmp_file" "$local_file" 2>/dev/null || true
  chmod +x "$local_file" 2>/dev/null || true

  # 关键：source 进当前 shell，失败要打印行号
  if ! . "$local_file" 2>/tmp/xsb_mod_source_err.log; then
    msg "❌ source 模块失败：$local_file"
    [ -s /tmp/xsb_mod_source_err.log ] && sed 's/^/[xsb-openwrt] /' /tmp/xsb_mod_source_err.log
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
rand_port(){ echo $((20000 + (RANDOM % 30000))); }

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
  mkdir -p "$XSB_DIR" "$SB_DIR" "$XR_DIR" "$SB_IN_DIR" "$XR_IN_DIR" "$LINK_DIR"
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
  # OpenWrt 推荐：coreutils-base64
  need_pkg "coreutils-base64" || true
  command -v base64 >/dev/null 2>&1 && return 0
  return 1
}

# ==============================
# UCI firewall allow ports
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
      echo
      echo "[xsb-openwrt] ✅ 已创建并启用 /etc/init.d/xray"
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
      echo
      echo "[xsb-openwrt] ✅ 已创建并启用 /etc/init.d/sing-box"
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
# xsb shortcut command
# ==============================
ensure_xsb_cmd(){
  if [ -x /usr/bin/xsb ]; then return 0; fi
  cat > /usr/bin/xsb <<'EOF'
#!/bin/sh
# XSB OpenWrt Tiny launcher
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
# Save/show links (no jq needed)
# ==============================
save_link(){
  name="$1"
  link="$2"
  [ -n "${name:-}" ] || return 0
  [ -n "${link:-}" ] || return 0
  mkdir -p "$LINK_DIR"
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

  # 显示所有
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
# Cert for sing-box (HY2/TUIC)
# ==============================
gen_cert(){
  ensure_openssl
  mkdir -p "$XSB_DIR/certs"
  crt="$XSB_DIR/certs/server.crt"
  key="$XSB_DIR/certs/server.key"
  if [ -f "$crt" ] && [ -f "$key" ]; then
    echo "$crt|$key"
    return 0
  fi
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -subj "/CN=xsb-openwrt" \
    -keyout "$key" -out "$crt" >/dev/null 2>&1
  echo "$crt|$key"
}

# ==============================
# Safe write sing-box config
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
      if [ "$first" -eq 1 ]; then
        first=0
      else
        echo ','
      fi
      cat "$f"
    done

    echo '  ],'
    echo '  "outbounds": [{'
    echo '    "type": "direct",'
    echo '    "tag": "direct"'
    echo '  }]'
    echo '}'
  } > "$tmp"

  mkdir -p "$SB_DIR"

  if command -v sing-box >/dev/null 2>&1; then
    if ! sing-box check -c "$tmp" >/dev/null 2>&1; then
      msg "❌ sing-box 配置校验失败，已阻止覆盖 $SB_CFG（避免崩溃循环）"
      sing-box check -c "$tmp" 2>&1 | sed 's/^/[sing-box-check] /' || true
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
      if [ "$first" -eq 1 ]; then
        first=0
      else
        echo ','
      fi
      cat "$f"
    done

    echo '  ],'
    echo '  "outbounds": [{'
    echo '    "protocol": "freedom",'
    echo '    "tag": "direct"'
    echo '  }]'
    echo '}'
  } > "$tmp"

  mkdir -p "$XR_DIR"
  mv "$tmp" "$XR_CFG"
  msg "✅ 已写入 $XR_CFG"
}

# ==============================
# Public endpoint prefer IPv6
# ==============================
is_private_ip(){
  ip="$1"
  echo "$ip" | grep -Eq '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' && return 0
  return 1
}
format_host(){
  h="$1"
  echo "$h" | grep -q ":" && echo "[$h]" || echo "$h"
}

get_public_v6(){
  wget -qO- -6 https://api64.ipify.org 2>/dev/null || true
}
get_public_v4(){
  wget -qO- https://api.ipify.org 2>/dev/null || true
}

guess_ip(){
  ip6="$(get_public_v6)"
  if [ -n "${ip6:-}" ]; then echo "$ip6"; return 0; fi

  ip4="$(get_public_v4)"
  if [ -n "${ip4:-}" ]; then echo "$ip4"; return 0; fi

  ip="$(uci get network.wan.ipaddr 2>/dev/null || true)"
  [ -n "$ip" ] && echo "$ip" && return 0

  ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)"
  [ -n "$ip" ] && echo "$ip" && return 0

  echo "YOUR_IP"
}

# ==============================
# Check listeners
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
# Share links
# ==============================
make_hy2_link(){
  name="$1"; pw="$2"; port="$3"
  ip="$(guess_ip)"
  host="$(format_host "$ip")"
  sni="xsb-openwrt"
  echo "hysteria2://$pw@$host:$port/?insecure=1&sni=$sni#$name"
}

make_tuic_link(){
  name="$1"; uuid="$2"; pw="$3"; port="$4"
  ip="$(guess_ip)"
  host="$(format_host "$ip")"
  sni="xsb-openwrt"
  echo "tuic://$uuid:$pw@$host:$port?congestion_control=bbr&alpn=h3&sni=$sni&allow_insecure=1#$name"
}

b64(){
  s="$1"
  if command -v base64 >/dev/null 2>&1; then
    printf '%s' "$s" | base64 | tr -d '\n'
    return 0
  fi

  # 尝试自动安装
  ensure_base64 || true
  if command -v base64 >/dev/null 2>&1; then
    printf '%s' "$s" | base64 | tr -d '\n'
    return 0
  fi

  # openssl fallback
  if command -v openssl >/dev/null 2>&1; then
    printf '%s' "$s" | openssl base64 -A 2>/dev/null | tr -d '\n'
    return 0
  fi

  msg "❌ 缺少 base64/openssl，无法生成 vmess 链接"
  msg "建议安装：opkg install coreutils-base64"
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
# Input helpers random/custom
# ==============================
pick_path_host_ws(){
  path=""; hosthdr=""
  echo
  echo "Path/Host 输入方式："
  echo "1) 随机生成（推荐）"
  echo "2) 自定义"
  printf "选择: "
  read ph

  case "${ph:-1}" in
    2)
      printf "WS path（可空，回车随机，如 /abc123）: "
      read path
      [ -n "${path:-}" ] || path="/$(rand_hex 6)"
      printf "Host（伪装域名，可空）: "
      read hosthdr
      ;;
    *)
      path="/$(rand_hex 6)"
      hosthdr=""
      msg "✅ 已随机：path=$path host=（空）"
      ;;
  esac
}

pick_path_host_http(){
  path=""; hosthdr=""
  echo
  echo "Path/Host 输入方式："
  echo "1) 默认（path=/，host空）"
  echo "2) 自定义"
  printf "选择: "
  read ph

  case "${ph:-1}" in
    2)
      printf "HTTP path（可空，回车默认 /）: "
      read path
      [ -n "${path:-}" ] || path="/"
      printf "Host（伪装域名，可空）: "
      read hosthdr
      ;;
    *)
      path="/"
      hosthdr=""
      msg "✅ 已默认：path=/ host=（空）"
      ;;
  esac
}

# ==============================
# sing-box inbounds(profiling disabled)
# ==============================
add_sb_tuic(){
  ensure_dirs
  if ! command -v sing-box >/dev/null 2>&1; then
    msg "⚠️ 未检测到 sing-box，TUIC 需要 sing-box"
    printf "是否现在安装 sing-box？(y/N): "
    read yn
    case "$yn" in y|Y) install_singbox || true ;; *) return 1 ;; esac
  fi

  printf "备注名(如 tuic-sg): "
  read name
  [ -n "${name:-}" ] || name="tuic-$(date +%m%d%H%M)"
  printf "监听端口(回车随机): "
  read port
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
    msg "❌ TUIC 已写入碎片，但 wrapper 配置校验失败（请检查碎片 JSON）"
  fi
}

add_sb_hy2(){
  ensure_dirs
  if ! command -v sing-box >/dev/null 2>&1; then
    msg "⚠️ 未检测到 sing-box，HY2 需要 sing-box"
    printf "是否现在安装 sing-box？(y/N): "
    read yn
    case "$yn" in y|Y) install_singbox || true ;; *) return 1 ;; esac
  fi

  printf "备注名(如 hy2-sg): "
  read name
  [ -n "${name:-}" ] || name="hy2-$(date +%m%d%H%M)"
  printf "监听端口(回车随机): "
  read port
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
    msg "❌ HY2 已写入碎片，但 wrapper 配置校验失败（请检查碎片 JSON）"
  fi
}

# ==============================
# xray inbounds
# ==============================
add_xr_vless_reality(){
  ensure_dirs

  if ! command -v xray >/dev/null 2>&1; then
    msg "⚠️ 未检测到 xray，Reality 需要 xray-core"
    printf "是否现在安装 xray-core？(y/N): "
    read yn
    case "$yn" in y|Y) install_xray || true ;; *) return 1 ;; esac
  fi

  printf "备注名(如 reality-sg): "
  read name
  [ -n "${name:-}" ] || name="reality-$(date +%m%d%H%M)"
  printf "监听端口(回车随机): "
  read port
  [ -n "${port:-}" ] || port="$(rand_port)"
  printf "SNI(默认 www.cloudflare.com): "
  read sni
  [ -n "${sni:-}" ] || sni="www.cloudflare.com"

  sid="$(rand_hex 8)"
  uuid="$(rand_uuid)"

  priv=""
  pub=""

  # Optional: sing-box generate reality-keypair
  if command -v sing-box >/dev/null 2>&1; then
    kout="$(sing-box generate reality-keypair 2>/dev/null || true)"
    priv="$(echo "$kout" | grep -E '^PrivateKey:' | head -n1 | sed 's/^PrivateKey:[[:space:]]*//' | tr -d '\r')"
    pub="$(echo "$kout"  | grep -E '^PublicKey:'  | head -n1 | sed 's/^PublicKey:[[:space:]]*//' | tr -d '\r')"
  fi

  # Prefer xray x25519 (OpenWrt 新版可能用 Password 表示 pbk)
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    xout="$(xray x25519 2>/dev/null || true)"
    priv="$(echo "$xout" | grep -Ei 'private[ _-]*key' | head -n1 | sed 's/.*:[[:space:]]*//' | tr -d '\r')"
    pub="$(echo "$xout"  | grep -Ei 'public[ _-]*key|^password' | head -n1 | sed 's/.*:[[:space:]]*//' | tr -d '\r')"
  fi

  if [ -z "$priv" ] || [ -z "$pub" ]; then
    msg "❌ 获取 Reality Keypair 失败（priv/pub 为空）"
    msg "---- xray x25519 原始输出 ----"
    echo "${xout:-<empty>}"
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

  ip="$(guess_ip)"
  host="$(format_host "$ip")"
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
    read yn
    case "$yn" in y|Y) install_xray || true ;; *) return 1 ;; esac
  fi

  printf "备注名(如 vmess-ws-sg): "
  read name
  [ -n "${name:-}" ] || name="vmess-ws-$(date +%m%d%H%M)"
  printf "监听端口(回车随机): "
  read port
  [ -n "${port:-}" ] || port="$(rand_port)"

  pick_path_host_ws
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
    read yn
    case "$yn" in y|Y) install_xray || true ;; *) return 1 ;; esac
  fi

  printf "备注名(如 vmess-tcp-http-sg): "
  read name
  [ -n "${name:-}" ] || name="vmess-tcp-http-$(date +%m%d%H%M)"
  printf "监听端口(回车随机): "
  read port
  [ -n "${port:-}" ] || port="$(rand_port)"

  pick_path_host_http
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
# Remove inbound fragments + link file
# ==============================
remove_inbound(){
  kind="$1" # sb|xr
  dir="$SB_IN_DIR"
  [ "$kind" = "xr" ] && dir="$XR_IN_DIR"

  msg "当前入站："
  ls -1 "$dir" 2>/dev/null | sed 's/\.json$//' || true
  echo
  printf "输入要删除的备注名: "
  read name
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
    echo
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
  read c
  case "$c" in
    1) install_singbox ;;
    2) install_xray ;;
    3) install_singbox || true; install_xray || true ;;
    *) return 0 ;;
  esac
}

inbound_menu(){
  echo
  echo "添加入站："
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
  echo "[管理]"
  echo "6) 删除 Xray 入站"
  echo "7) 删除 sing-box 入站"
  echo "0) 返回"
  printf "选择: "
  read c
  case "$c" in
    1) add_xr_vless_reality ;;
    2) add_xr_vmess_ws_notls ;;
    3) add_xr_vmess_tcp_http ;;
    4) add_sb_tuic ;;
    5) add_sb_hy2 ;;
    6) remove_inbound xr ;;
    7) remove_inbound sb ;;
    *) return 0 ;;
  esac
}

uninstall_menu(){
  echo
  echo "卸载："
  echo "1) 卸载 sing-box"
  echo "2) 卸载 xray"
  echo "3) 卸载 sing-box + xray"
  echo "0) 返回"
  printf "选择: "
  read c

  printf "是否同时清理配置目录（/etc/sing-box /etc/xray /etc/xsb）？(y/N): "
  read clean
  CLEAN=0
  case "$clean" in y|Y) CLEAN=1 ;; esac

  case "$c" in
    1)
      svc_sb stop
      opkg remove sing-box sing-box-tiny >/dev/null 2>&1 || true
      rm -f /etc/init.d/sing-box 2>/dev/null || true
      msg "✅ sing-box 已卸载"
      ;;
    2)
      svc_xr stop
      opkg remove xray-core xray >/dev/null 2>&1 || true
      rm -f /etc/init.d/xray 2>/dev/null 2>&1 || true
      msg "✅ xray 已卸载"
      ;;
    3)
      svc_sb stop; svc_xr stop
      opkg remove sing-box sing-box-tiny xray-core xray >/dev/null 2>&1 || true
      rm -f /etc/init.d/sing-box /etc/init.d/xray 2>/dev/null 2>&1 || true
      msg "✅ sing-box + xray 已卸载"
      ;;
    *)
      return 0
      ;;
  esac

  if [ "$CLEAN" -eq 1 ]; then
    rm -rf /etc/sing-box /etc/xray /etc/xsb 2>/dev/null || true
    msg "✅ 已清理配置目录"
  else
    msg "ℹ️ 已保留配置目录（方便重装复用）"
  fi
}

main(){
  ensure_dirs
  ensure_xsb_cmd

  msg "进入 OpenWrt Tiny 模式（最小化）"
  while true; do
    echo
    echo "=============================="
    echo " XSB OpenWrt Tiny Menu"
    echo "=============================="
    echo "1) 安装 sing-box / xray"
    echo "2) 添加入站（Xray/sing-box）"
    echo "3) 查看分享链接"
    echo "4) 重启服务"
    echo "5) 查看状态"
    echo "6) 透明代理网关模式（国内直连/国外代理）"
    echo "7) 卸载"
    echo "0) 退出"
    printf "选择: "
    read c
    case "$c" in
      1) install_menu ;;
      2) inbound_menu ;;
      3)
        if mod_load "openwrt-mod-links.sh"; then
          show_links
        else
          msg "❌ 加载链接模块失败"
        fi
        ;;
      4) svc_sb restart; svc_xr restart; msg "✅ 已重启" ;;
      5) status_all ;;
      6)
        if mod_load "openwrt-mod-proxy.sh"; then
          proxy_gateway_menu
        else
          msg "❌ 加载网关模块失败：openwrt-mod-proxy.sh"
        fi
        ;;
      7) uninstall_menu ;;
      0) exit 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

main
