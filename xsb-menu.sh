#!/usr/bin/env bash
# =========================================================
# XSB OneKey Manager (Xray + sing-box)
# 标准目录版：/usr/local/bin, /etc, /var/lib
# 协议池：
#   - VLESS + Reality (Xray)
#   - VMess + WS (noTLS) (Xray)
#   - VMess + TCP + HTTP (Xray)
#   - TUIC (sing-box)
#   - Hysteria2 (sing-box)
#
# 功能：
#   1) 一键安装/重置（自动识别系统/架构 amd64/arm64）
#   2) 模板部署（通用/UDP受限/纯IPv6）+ 高级自定义
#   3) 添加/删除/启用/停用 入站
#   4) 导出：分享链接/订阅(简版)/二维码
#   5) 节点体检（监听/防火墙/服务状态）
#   6) 延迟检测（本机握手/连接耗时，轻量不耗流量）
#   7) 更新核心（可选 xray / sing-box）
#   8) 备份/恢复/迁移
#
# 注意：
#   - TUIC / Hy2 需要 TLS。脚本默认生成自签证书（客户端需 allow_insecure）。
#   - 你不需要“安全加固一条龙”，这里不会动 SSH / fail2ban 等。
# =========================================================

set -euo pipefail

# --------- 基本路径（标准目录） ----------
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

# --------- 系统识别 ----------
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

  if [[ "$OS_FAMILY" == "unknown" ]]; then
    warn "未识别系统，继续尝试运行（可能需要你手动装依赖）"
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
    *)
      ARCH="$m"
      warn "未识别架构：$m，可能无法自动下载预编译二进制"
      ;;
  esac
}

# --------- 依赖 ----------
install_deps(){
  detect_os
  local common=(curl jq openssl tar)
  # qrencode 可选
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
    warn "跳过自动安装依赖（未知系统）。请确保存在：curl jq openssl tar"
  fi
  ok "依赖检查完成"
}

# --------- GitHub Release 下载 ----------
gh_latest_asset_url(){
  # $1 = repo like "XTLS/Xray-core"
  # $2 = grep key like "linux-64.zip"
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
    *) err "不支持的架构：$ARCH"; return 1 ;;
  esac

  local url
  url="$(gh_latest_asset_url "XTLS/Xray-core" "$key")"
  [[ -n "$url" ]] || { err "获取 Xray 下载链接失败"; return 1; }

  local tmp="/tmp/xray.zip"
  curl -fL "$url" -o "$tmp"
  have unzip || { [[ "$PKG" == "apt" ]] && apt-get install -y unzip || $PKG install -y unzip; }
  rm -rf /tmp/xray_unz && mkdir -p /tmp/xray_unz
  unzip -qo "$tmp" -d /tmp/xray_unz
  install -m 755 /tmp/xray_unz/xray "$XRAY_BIN"
  ok "Xray 安装完成：$XRAY_BIN"
}

download_and_install_singbox(){
  detect_arch
  info "下载 sing-box 最新版（$ARCH）..."
  # sing-box release 名称经常变化，这里用通用匹配：
  # 例：sing-box-1.10.0-linux-amd64.tar.gz
  local key=""
  case "$ARCH" in
    amd64) key="linux-amd64.tar.gz" ;;
    arm64) key="linux-arm64.tar.gz" ;;
    armv7) key="linux-armv7.tar.gz" ;;
    *) err "不支持的架构：$ARCH"; return 1 ;;
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
    err "当前系统没有 systemd（systemctl 不存在）。该脚本优先支持 systemd 系统。"
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

reload_systemd(){
  systemctl daemon-reload
}

svc_enable_start(){
  systemctl enable --now "$1" >/dev/null 2>&1 || true
  systemctl restart "$1" >/dev/null 2>&1 || true
}

svc_restart(){
  systemctl restart "$1" >/dev/null 2>&1 || true
}

svc_status(){
  systemctl is-active "$1" >/dev/null 2>&1 && echo "active" || echo "inactive"
}

# --------- 防火墙放行（最小化，只开你选的端口） ----------
open_port(){
  # $1=port, $2=proto tcp/udp
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
  # iptables fallback
  if have iptables; then
    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 \
      || iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
    # 尝试持久化（不同系统不同）
    if have netfilter-persistent; then netfilter-persistent save >/dev/null 2>&1 || true; fi
    if have service; then service iptables save >/dev/null 2>&1 || true; fi
    return 0
  fi
  warn "未检测到 ufw/firewalld/iptables，跳过放行端口：$port/$proto（请确认云安全组）"
}

# --------- 元数据 ----------
init_meta(){
  mkdir -p "$META_DIR"
  if [[ ! -f "$META_JSON" ]]; then
    cat >"$META_JSON" <<'JSON'
{
  "bind_mode": "dual",
  "xray_inbounds": [],
  "singbox_inbounds": []
}
JSON
  fi
}

meta_get_bind_mode(){
  jq -r '.bind_mode' "$META_JSON"
}

meta_set_bind_mode(){
  local mode="$1"
  tmp="$(mktemp)"
  jq --arg m "$mode" '.bind_mode=$m' "$META_JSON" >"$tmp"
  mv "$tmp" "$META_JSON"
}

# --------- 监听地址选择 ----------
listen_addrs(){
  # return JSON array for xray listen / sing-box listen
  local mode
  mode="$(meta_get_bind_mode)"
  case "$mode" in
    v4) echo '["0.0.0.0"]' ;;
    v6) echo '["::"]' ;;
    dual) echo '["0.0.0.0","::"]' ;;
    *) echo '["0.0.0.0","::"]' ;;
  esac
}

# --------- 默认配置初始化 ----------
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

# --------- 证书（自签） ----------
gen_self_signed(){
  # $1=crt $2=key $3=CN
  local crt="$1" key="$2" cn="${3:-example.com}"
  mkdir -p "$CERT_DIR"
  if [[ -f "$crt" && -f "$key" ]]; then
    return 0
  fi
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -subj "/CN=${cn}" \
    -keyout "$key" -out "$crt" >/dev/null 2>&1
}

# --------- 工具：JSON 追加/删除 ----------
json_append_inbound_xray(){
  # $1 = inbound object json
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

# --------- 添加入站：Xray ----------
add_vless_reality(){
  local name port sni sid flow
  read -rp "入站备注名（例如 US-Reality）: " name
  [[ -n "$name" ]] || name="Reality-$(date +%m%d%H%M)"
  read -rp "监听端口（回车随机 20000-50000）: " port
  if [[ -z "$port" ]]; then port="$((20000 + RANDOM % 30000))"; fi
  read -rp "Reality SNI（默认 www.cloudflare.com）: " sni
  [[ -n "$sni" ]] || sni="www.cloudflare.com"
  read -rp "shortId（回车随机 8字节hex）: " sid
  [[ -n "$sid" ]] || sid="$(rand_hex 8)"
  read -rp "flow（默认 xtls-rprx-vision，可空）: " flow
  [[ -n "$flow" ]] || flow="xtls-rprx-vision"

  local uuid
  uuid="$(rand_uuid)"

  # keypair
  local xout priv pub
  xout="$($XRAY_BIN x25519 2>/dev/null || true)"
  if [[ -z "$xout" ]]; then
    err "生成 Reality keypair 失败：xray x25519 不可用"
    return 1
  fi
  priv="$(echo "$xout" | awk '/Private key/ {print $NF}')"
  pub="$(echo "$xout" | awk '/Public key/ {print $NF}')"

  local addrs
  addrs="$(listen_addrs)"

  local tag="xray-${name// /_}-reality-${port}"

  # Xray inbound obj
  local inbound
  inbound="$(jq -nc \
    --arg tag "$tag" \
    --arg uuid "$uuid" \
    --arg sni "$sni" \
    --arg sid "$sid" \
    --arg priv "$priv" \
    --argjson addrs "$addrs" \
    --arg flow "$flow" \
    --argjson port "$port" \
'{
  "tag": $tag,
  "listen": $addrs[0],
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
      "dest": "443",
      "xver": 0,
      "serverNames": [ $sni ],
      "privateKey": $priv,
      "shortIds": [ $sid ]
    }
  },
  "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
}')"

  # 注意：Xray 只支持单 listen，这里如果 dual/v6，需要用多个 inbound。
  # 为了不爆炸：如果 bind_mode=dual，就默认 0.0.0.0（更兼容），纯v6模式才监听 ::
  local mode
  mode="$(meta_get_bind_mode)"
  if [[ "$mode" == "v6" ]]; then
    inbound="$(echo "$inbound" | jq '.listen="::"')"
  else
    inbound="$(echo "$inbound" | jq '.listen="0.0.0.0"')"
  fi

  json_append_inbound_xray "$inbound"
  open_port "$port" "tcp"

  # 记录元数据
  tmp="$(mktemp)"
  jq --arg tag "$tag" --arg name "$name" --arg proto "vless-reality" --arg uuid "$uuid" \
     --arg port "$port" --arg sni "$sni" --arg sid "$sid" --arg pbk "$pub" --arg flow "$flow" \
     '.xray_inbounds += [{
        "tag":$tag,"name":$name,"proto":$proto,"uuid":$uuid,
        "port":($port|tonumber),"sni":$sni,"sid":$sid,"pbk":$pbk,"flow":$flow
      }]' "$META_JSON" >"$tmp"
  mv "$tmp" "$META_JSON"

  svc_restart xray
  ok "已添加 VLESS+Reality：$name 端口 $port"
  export_links_one "$tag"
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

  local inbound
  inbound="$(jq -nc \
    --arg tag "$tag" \
    --arg uuid "$uuid" \
    --arg path "$path" \
    --arg host "$host" \
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
      "headers": (if ($host|length) > 0 then {"Host": $host} else {} end)
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

  # Xray 的 tcp + http header 伪装
  local inbound
  inbound="$(jq -nc \
    --arg tag "$tag" \
    --arg uuid "$uuid" \
    --arg path "$path" \
    --arg host "$host" \
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
          "headers": (if ($host|length) > 0 then
            {"Host":[ $host ],"User-Agent":["Mozilla/5.0"],"Accept-Encoding":["gzip, deflate"],"Connection":["keep-alive"],"Pragma":"no-cache"}
          else
            {"User-Agent":["Mozilla/5.0"],"Accept-Encoding":["gzip, deflate"],"Connection":["keep-alive"],"Pragma":"no-cache"}
          end)
          )
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

# --------- 添加入站：sing-box ----------
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

  # bind_mode：v4 / v6 / dual
  local mode
  mode="$(meta_get_bind_mode)"
  if [[ "$mode" == "v4" ]]; then inbound="$(echo "$inbound" | jq '.listen="0.0.0.0"')"; fi
  if [[ "$mode" == "dual" ]]; then inbound="$(echo "$inbound" | jq '.listen="::"')"; fi

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

# --------- 列表/删除 ----------
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

# --------- 获取服务器 IP（简易） ----------
get_public_ip_best_effort(){
  # 不强依赖外网，尽量取本机默认出口 IP
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  echo "${ip:-YOUR_SERVER_IP}"
}

# --------- 导出链接 ----------
b64(){
  # base64 without newline
  if have base64; then base64 -w 0; else openssl base64 -A; fi
}

export_links_one(){
  local tag="$1"
  local host
  host="$(get_public_ip_best_effort)"

  echo
  echo -e "${CYA}=== 导出：$tag ===${RST}"

  # Xray reality
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

    echo -e "${YLW}TUIC 没有统一通用的“分享链接标准”。这里给你一份 sing-box 客户端片段（需 allow_insecure=true）：${RST}"
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
    return 0
  fi

  # HY2
  if jq -e --arg t "$tag" '.singbox_inbounds[]? | select(.tag==$t and .proto=="hy2")' "$META_JSON" >/dev/null 2>&1; then
    local password port sni name
    password="$(jq -r --arg t "$tag" '.singbox_inbounds[] | select(.tag==$t) | .password' "$META_JSON")"
    port="$(jq -r --arg t "$tag" '.singbox_inbounds[] | select(.tag==$t) | .port' "$META_JSON")"
    sni="$(jq -r --arg t "$tag" '.singbox_inbounds[] | select(.tag==$t) | .sni' "$META_JSON")"
    name="$(jq -r --arg t "$tag" '.singbox_inbounds[] | select(.tag==$t) | .name' "$META_JSON")"

    echo -e "${YLW}HY2 同样没有统一通用“分享链接标准”。这里给你 sing-box 客户端片段（需 allow_insecure=true）：${RST}"
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

qrcode_maybe(){
  local text="$1"
  if have qrencode; then
    echo
    qrencode -t ANSIUTF8 "$text" || true
    echo
  fi
}

# --------- 体检 ----------
health_check(){
  echo -e "${BLU}=== XSB 体检 ===${RST}"
  echo -e "Xray:     $(svc_status xray)"
  echo -e "sing-box: $(svc_status sing-box)"
  echo

  echo -e "${CYA}监听端口（TCP）:${RST}"
  ss -lntp 2>/dev/null | sed -n '1,20p' || true
  echo
  echo -e "${CYA}监听端口（UDP）:${RST}"
  ss -lnup 2>/dev/null | sed -n '1,20p' || true
  echo

  if have ufw; then
    echo -e "${CYA}UFW 状态:${RST}"
    ufw status verbose || true
    echo
  elif have firewall-cmd; then
    echo -e "${CYA}Firewalld 状态:${RST}"
    firewall-cmd --state || true
    firewall-cmd --list-ports || true
    echo
  else
    echo -e "${CYA}防火墙:${RST} 未检测到 ufw/firewalld（或你在用其他管理方式）"
    echo
  fi

  warn "如果本机监听正常但外网仍不通：优先检查云厂商安全组/ACL（入站 TCP/UDP 端口）"
}

# --------- 延迟检测（本机连接耗时，轻量） ----------
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
    # UDP 无连接语义，这里用“是否监听”作为轻量指标
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
  info "说明：这是服务器本机测试，用来判断“服务是否正常/监听是否存在”。真实客户端延迟以客户端测速为准。"
}

# --------- 更新核心 ----------
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

# --------- 备份/恢复 ----------
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

# --------- 安装/重置 ----------
choose_bind_mode(){
  echo "监听模式："
  echo "1) 双栈（0.0.0.0 + ::）推荐"
  echo "2) 仅 IPv4（0.0.0.0）"
  echo "3) 仅 IPv6（::）"
  read -rp "选择 [1-3]（默认1）: " c
  case "$c" in
    2) meta_set_bind_mode "v4" ;;
    3) meta_set_bind_mode "v6" ;;
    *) meta_set_bind_mode "dual" ;;
  esac
  ok "bind_mode=$(meta_get_bind_mode)"
}

reset_all_configs(){
  init_meta
  init_xray_cfg
  init_singbox_cfg
  # 清空入站
  tmp="$(mktemp)"
  jq '.inbounds=[]' "$XRAY_CFG" >"$tmp" && mv "$tmp" "$XRAY_CFG"
  tmp="$(mktemp)"
  jq '.inbounds=[]' "$SB_CFG" >"$tmp" && mv "$tmp" "$SB_CFG"
  # 清空 meta
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

template_deploy(){
  echo "模板部署："
  echo "1) 通用机：Reality + TUIC + HY2 + VMess TCP HTTP"
  echo "2) UDP受限：Reality + VMess TCP HTTP + VMess WS"
  echo "3) 纯IPv6：Reality(v6) + VMess TCP HTTP(v6) + 可选 TUIC/HY2"
  echo "0) 返回"
  read -rp "选择: " c
  case "$c" in
    1)
      add_vless_reality
      add_tuic
      add_hy2
      add_vmess_tcp_http
      ;;
    2)
      add_vless_reality
      add_vmess_tcp_http
      add_vmess_ws_notls
      ;;
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
    *)
      return 0
      ;;
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

# --------- 主菜单 ----------
main_menu(){
  while true; do
    echo
    echo -e "${BLU}==============================${RST}"
    echo -e "${BLU}  XSB OneKey Manager Menu     ${RST}"
    echo -e "${BLU}==============================${RST}"
    echo "1) 安装/初始化（Xray + sing-box）"
    echo "2) 重置（清空入站，保留二进制）"
    echo "3) 模板部署（通用/UDP受限/纯IPv6）"
    echo "4) 添加入站（自由选择协议）"
    echo "5) 列出入站"
    echo "6) 删除入站"
    echo "7) 导出链接/配置/二维码"
    echo "8) 节点体检（监听/防火墙/服务）"
    echo "9) 延迟检测（轻量本机测试）"
    echo "10) 查看日志"
    echo "11) 更新核心（Xray/sing-box）"
    echo "12) 备份"
    echo "13) 恢复"
    echo "0) 卸载并退出"
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
      9) latency_test ;;
      10) view_logs ;;
      11) update_core ;;
      12) backup_all ;;
      13) restore_all ;;
      0) uninstall_all; exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

need_root
init_meta
init_xray_cfg
init_singbox_cfg
main_menu
