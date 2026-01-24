#!/bin/sh
set -eu

XSB_DIR="/etc/xsb"
SB_DIR="/etc/sing-box"
XR_DIR="/etc/xray"
SB_CFG="$SB_DIR/config.json"
XR_CFG="$XR_DIR/config.json"

SB_IN_DIR="$XSB_DIR/singbox_inbounds.d"
XR_IN_DIR="$XSB_DIR/xray_inbounds.d"

msg(){ echo "[xsb-openwrt] $*"; }

rand_hex(){
  n="$1"
  hexdump -vn "$n" -e '/1 "%02x"' /dev/urandom 2>/dev/null || echo "deadbeef"
}

rand_uuid(){
  cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000"
}

need_pkg(){
  pkg="$1"
  opkg list-installed 2>/dev/null | grep -q "^$pkg " && return 0
  msg "安装依赖：$pkg"
  opkg update >/dev/null 2>&1 || true
  opkg install "$pkg" >/dev/null 2>&1 || true
}

ensure_dirs(){
  mkdir -p "$XSB_DIR" "$SB_DIR" "$XR_DIR" "$SB_IN_DIR" "$XR_IN_DIR"
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
    msg "未发现 /etc/init.d/sing-box（建议 opkg 安装 sing-box-tiny）"
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

# ✅ 写临时文件 -> check 通过才覆盖，避免 sing-box crash loop
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
      msg "错误详情："
      sing-box check -c "$tmp" 2>&1 | sed 's/^/[sing-box-check] /' || true
      msg "你可以查看临时文件：$tmp"
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

is_private_ip(){
  ip="$1"
  echo "$ip" | grep -Eq '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' && return 0
  return 1
}

guess_ip(){
  ip="$(uci get network.wan.ipaddr 2>/dev/null || true)"
  [ -n "$ip" ] && echo "$ip" && return 0
  ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)"
  [ -n "$ip" ] && echo "$ip" && return 0
  echo "YOUR_IP"
}

check_udp_listen(){
  port="$1"
  ensure_ss >/dev/null 2>&1 || return 0
  if command -v ss >/dev/null 2>&1; then
    ss -lunp 2>/dev/null | grep ":$port " >/dev/null 2>&1 && msg "✅ UDP 端口已监听：$port" || msg "⚠️ UDP 端口未监听：$port"
  fi
}

check_tcp_listen(){
  port="$1"
  ensure_ss >/dev/null 2>&1 || return 0
  if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | grep ":$port " >/dev/null 2>&1 && msg "✅ TCP 端口已监听：$port" || msg "⚠️ TCP 端口未监听：$port"
  fi
}

# ✅ 分享链接构造（自签默认 allow_insecure/insecure=1）
make_hy2_link(){
  name="$1"; pw="$2"; port="$3"
  ip="$(guess_ip)"
  sni="xsb-openwrt"
  echo "hysteria2://$pw@$ip:$port/?insecure=1&sni=$sni#$name"
  if is_private_ip "$ip"; then
    msg "⚠️ HY2 检测到内网 IP：$ip（外网需端口转发/改公网域名）"
  fi
}

make_tuic_link(){
  name="$1"; uuid="$2"; pw="$3"; port="$4"
  ip="$(guess_ip)"
  sni="xsb-openwrt"
  # 常见 tuic 分享格式（多数客户端可识别）；自签证书建议 allow_insecure=1
  echo "tuic://$uuid:$pw@$ip:$port?congestion_control=bbr&alpn=h3&sni=$sni&allow_insecure=1#$name"
  if is_private_ip "$ip"; then
    msg "⚠️ TUIC 检测到内网 IP：$ip（外网需端口转发/改公网域名）"
  fi
}

add_sb_tuic(){
  ensure_dirs
  read -p "备注名(如 tuic-sg): " name; [ -n "$name" ] || name="tuic-$(date +%m%d%H%M)"
  read -p "监听端口(回车随机): " port; [ -n "$port" ] || port=$((20000 + (RANDOM % 30000)))
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
    svc_sb restart
    msg "✅ TUIC 已添加：$name 端口 $port"
    msg "客户端参数：uuid=$uuid  password=$pw  (自签证书请开启 allow_insecure/insecure)"
    msg "链接：$(make_tuic_link "$name" "$uuid" "$pw" "$port")"
    check_udp_listen "$port"
  else
    msg "❌ TUIC 已写入碎片，但 wrapper 配置校验失败（请检查碎片 JSON）"
  fi
}

add_sb_hy2(){
  ensure_dirs
  read -p "备注名(如 hy2-sg): " name; [ -n "$name" ] || name="hy2-$(date +%m%d%H%M)"
  read -p "监听端口(回车随机): " port; [ -n "$port" ] || port=$((20000 + (RANDOM % 30000)))
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
    svc_sb restart
    msg "✅ HY2 已添加：$name 端口 $port"
    msg "客户端参数：password=$pw  (自签证书请开启 allow_insecure/insecure)"
    msg "链接：$(make_hy2_link "$name" "$pw" "$port")"
    check_udp_listen "$port"
  else
    msg "❌ HY2 已写入碎片，但 wrapper 配置校验失败（请检查碎片 JSON）"
  fi
}

add_xr_vless_reality(){
  ensure_dirs
  read -p "备注名(如 reality-sg): " name; [ -n "$name" ] || name="reality-$(date +%m%d%H%M)"
  read -p "监听端口(回车随机): " port; [ -n "$port" ] || port=$((20000 + (RANDOM % 30000)))
  read -p "SNI(默认 www.cloudflare.com): " sni; [ -n "$sni" ] || sni="www.cloudflare.com"
  sid="$(rand_hex 8)"
  uuid="$(rand_uuid)"

  priv=""
  pub=""

  if command -v sing-box >/dev/null 2>&1; then
    kout="$(sing-box generate reality-keypair 2>/dev/null || true)"
    priv="$(echo "$kout" | grep -E '^PrivateKey:' | head -n1 | sed 's/^PrivateKey:[[:space:]]*//')"
    pub="$(echo "$kout"  | grep -E '^PublicKey:'  | head -n1 | sed 's/^PublicKey:[[:space:]]*//')"
  fi

  if [ -z "$priv" ] || [ -z "$pub" ]; then
    if ! command -v xray >/dev/null 2>&1; then
      msg "⚠️ 未检测到 xray，建议先安装：xray-core"
      read -p "是否现在安装 xray-core？(y/N): " yn
      case "$yn" in y|Y) install_xray || true ;; esac
    fi
    if command -v xray >/dev/null 2>&1; then
      xout="$(xray x25519 2>/dev/null || true)"
      priv="$(echo "$xout" | grep -Ei 'private[ _-]*key' | head -n1 | sed 's/.*:[[:space:]]*//')"
      pub="$(echo "$xout"  | grep -Ei 'public[ _-]*key'  | head -n1 | sed 's/.*:[[:space:]]*//')"
    fi
  fi

  if [ -z "$priv" ] || [ -z "$pub" ]; then
    msg "❌ 获取 Reality Keypair 失败（priv/pub 为空）"
    msg "建议安装 sing-box-tiny 后再试：sing-box generate reality-keypair"
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
  svc_xr restart

  ip="$(guess_ip)"
  msg "✅ Reality 已添加：$name 端口 $port"
  msg "PublicKey(pbk)=$pub"
  msg "链接：vless://$uuid@$ip:$port?encryption=none&security=reality&sni=$sni&fp=chrome&pbk=$pub&sid=$sid&type=tcp&flow=xtls-rprx-vision#$name"

  if is_private_ip "$ip"; then
    msg "⚠️ 当前检测到的是内网地址：$ip"
    msg "   如需外网连接：请填公网IP/域名，并在上级路由/光猫做端口转发到 $ip:$port"
  fi

  check_tcp_listen "$port"
}

remove_inbound(){
  kind="$1" # sb|xr
  dir="$SB_IN_DIR"
  [ "$kind" = "xr" ] && dir="$XR_IN_DIR"

  msg "当前入站："
  ls -1 "$dir" 2>/dev/null | sed 's/\.json$//' || true
  echo
  read -p "输入要删除的备注名: " name
  [ -n "$name" ] || return 0
  rm -f "$dir/$name.json" 2>/dev/null || true

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
  echo "1) TUIC (sing-box)"
  echo "2) Hysteria2 / HY2 (sing-box)"
  echo "3) VLESS + Reality (xray) [Auto pbk]"
  echo "4) 删除 sing-box 入站"
  echo "5) 删除 xray 入站"
  echo "0) 返回"
  printf "选择: "
  read c
  case "$c" in
    1) add_sb_tuic ;;
    2) add_sb_hy2 ;;
    3) add_xr_vless_reality ;;
    4) remove_inbound sb ;;
    5) remove_inbound xr ;;
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

  read -p "是否同时清理配置目录（/etc/sing-box /etc/xray /etc/xsb）？(y/N): " clean
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
      rm -f /etc/init.d/xray 2>/dev/null || true
      msg "✅ xray 已卸载"
      ;;
    3)
      svc_sb stop; svc_xr stop
      opkg remove sing-box sing-box-tiny xray-core xray >/dev/null 2>&1 || true
      rm -f /etc/init.d/sing-box /etc/init.d/xray 2>/dev/null || true
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
  msg "进入 OpenWrt Tiny 模式（最小化）"
  while true; do
    echo
    echo "=============================="
    echo " XSB OpenWrt Tiny Menu"
    echo "=============================="
    echo "1) 安装 sing-box / xray"
    echo "2) 添加入站（TUIC/HY2/Reality）"
    echo "3) 重启服务"
    echo "4) 查看状态"
    echo "5) 卸载"
    echo "0) 退出"
    printf "选择: "
    read c
    case "$c" in
      1) install_menu ;;
      2) inbound_menu ;;
      3) svc_sb restart; svc_xr restart; msg "✅ 已重启" ;;
      4) status_all ;;
      5) uninstall_menu ;;
      0) exit 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

main
