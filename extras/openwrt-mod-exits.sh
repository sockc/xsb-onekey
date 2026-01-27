#!/bin/sh
set -eu

msg(){ echo "[xsb-openwrt] $*" >&2; }

GW_DIR="/etc/xsb/gateway"
GW_NODES_DIR="$GW_DIR/nodes.d"
GW_SLOTS_FILE="$GW_DIR/slots.conf"         # slot bindings: SLOT_HK=nodeTag,nodeTag2
GW_DEFAULT_SLOT_FILE="$GW_DIR/default_slot" # e.g. HK
GW_IMPORTED_FILE="$GW_DIR/imported_links.txt"

ensure_gateway_dirs(){
  mkdir -p "$GW_DIR" "$GW_NODES_DIR" >/dev/null 2>&1 || true
  [ -f "$GW_SLOTS_FILE" ] || touch "$GW_SLOTS_FILE"
  [ -f "$GW_IMPORTED_FILE" ] || touch "$GW_IMPORTED_FILE"
}

# dependencies
need_pkg(){
  pkg="$1"
  opkg list-installed 2>/dev/null | grep -q "^$pkg " && return 0
  msg "安装依赖：$pkg"
  opkg update >/dev/null 2>&1 || true
  opkg install "$pkg" >/dev/null 2>&1 || true
}

ensure_base64(){
  command -v base64 >/dev/null 2>&1 && return 0
  need_pkg "coreutils-base64"
  command -v base64 >/dev/null 2>&1 && return 0
  msg "⚠️ 未找到 base64（vmess 导入不可用）"
  return 1
}

rand_hex(){
  n="$1"
  hexdump -vn "$n" -e '/1 "%02x"' /dev/urandom 2>/dev/null || echo "deadbeef"
}
rand_uuid(){
  cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000"
}

# ---------- slots ----------
slot_list_default(){
  echo "HK TW JP US UK DE NL SG"
}

slot_key(){
  echo "SLOT_$1"
}

slot_get_line(){
  s="$1"
  key="$(slot_key "$s")"
  grep -E "^$key=" "$GW_SLOTS_FILE" 2>/dev/null | tail -n1 || true
}

slot_get_nodes(){
  s="$1"
  line="$(slot_get_line "$s")"
  echo "$line" | sed -E 's/^[^=]+=//'
}

slot_set_nodes(){
  s="$1"
  nodes="$2"  # comma separated
  key="$(slot_key "$s")"
  # remove old
  grep -v -E "^$key=" "$GW_SLOTS_FILE" 2>/dev/null > /tmp/xsb-slots.tmp || true
  echo "$key=$nodes" >> /tmp/xsb-slots.tmp
  mv /tmp/xsb-slots.tmp "$GW_SLOTS_FILE"
}

slot_add_node(){
  s="$1"; node="$2"
  cur="$(slot_get_nodes "$s")"
  if [ -z "$cur" ]; then
    slot_set_nodes "$s" "$node"
  else
    # avoid dup
    echo "$cur" | tr ',' '\n' | grep -qx "$node" && return 0
    slot_set_nodes "$s" "$cur,$node"
  fi
}

slot_remove_node(){
  s="$1"; node="$2"
  cur="$(slot_get_nodes "$s")"
  [ -n "$cur" ] || return 0
  new="$(echo "$cur" | tr ',' '\n' | grep -vx "$node" | paste -sd',' - 2>/dev/null || true)"
  slot_set_nodes "$s" "$new"
}

default_slot_get(){
  if [ -f "$GW_DEFAULT_SLOT_FILE" ]; then
    cat "$GW_DEFAULT_SLOT_FILE" 2>/dev/null | tr -d '\r\n' || true
  fi
}
default_slot_set(){
  ensure_gateway_dirs
  echo "$1" > "$GW_DEFAULT_SLOT_FILE"
  msg "✅ 已设置默认出口槽位：$1"
}

# ---------- nodes store ----------
node_path(){
  echo "$GW_NODES_DIR/$1.json"
}

node_exists(){
  [ -f "$(node_path "$1")" ]
}

node_list(){
  ls -1 "$GW_NODES_DIR" 2>/dev/null | sed 's/\.json$//' || true
}

node_show(){
  tag="$1"
  f="$(node_path "$tag")"
  [ -f "$f" ] || { msg "不存在节点：$tag"; return 1; }
  echo "----- $tag -----"
  cat "$f"
  echo "---------------"
}

node_delete(){
  tag="$1"
  rm -f "$(node_path "$tag")" 2>/dev/null || true
  # remove from all slots
  for s in $(slot_list_default); do
    slot_remove_node "$s" "$tag" || true
  done
  msg "✅ 已删除节点：$tag"
}

# ---------- link parsing helpers ----------
urldecode_min(){
  # minimal: convert %2F etc not implemented fully, keep as-is
  echo "$1"
}

get_qparam(){
  # $1=fullquery (k=v&k2=v2)  $2=key
  q="$1"; k="$2"
  echo "$q" | tr '&' '\n' | awk -F= -v kk="$k" '$1==kk {print $2; exit}'
}

strip_fragment(){
  echo "$1" | sed 's/#.*$//'
}
get_fragment(){
  echo "$1" | awk -F'#' 'NF>1{print $2}'
}

save_imported(){
  echo "$1" >> "$GW_IMPORTED_FILE" 2>/dev/null || true
}

# ---------- build outbound json ----------
save_outbound(){
  tag="$1"
  json="$2"
  ensure_gateway_dirs
  echo "$json" > "$(node_path "$tag")"
  msg "✅ 已保存节点：$tag"
}

# vless://uuid@host:port?encryption=none&security=reality&sni=xx&pbk=xx&sid=xx&type=tcp&flow=xx#name
import_vless(){
  link="$1"
  core="$(strip_fragment "$link")"
  name="$(get_fragment "$link")"
  name="${name:-vless-$(date +%m%d%H%M)}"

  core="${core#vless://}"
  cred="${core%%@*}"
  rest="${core#*@}"
  hostport="${rest%%\?*}"
  query=""
  echo "$rest" | grep -q '\?' && query="${rest#*\?}"

  uuid="$cred"
  host="${hostport%:*}"
  port="${hostport##*:}"

  sec="$(get_qparam "$query" security)"
  sni="$(get_qparam "$query" sni)"
  pbk="$(get_qparam "$query" pbk)"
  sid="$(get_qparam "$query" sid)"
  flow="$(get_qparam "$query" flow)"
  fp="$(get_qparam "$query" fp)"
  [ -n "$fp" ] || fp="chrome"

  # tag sanitize
  tag="$(echo "$name" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')"
  [ -n "$tag" ] || tag="vless-$(date +%m%d%H%M)"

  if [ "$sec" = "reality" ]; then
    # sing-box vless + reality outbound
    json="$(cat <<EOF
{
  "type": "vless",
  "tag": "$tag",
  "server": "$host",
  "server_port": $port,
  "uuid": "$uuid",
  "flow": "${flow:-xtls-rprx-vision}",
  "tls": {
    "enabled": true,
    "server_name": "${sni:-www.cloudflare.com}",
    "utls": { "enabled": true, "fingerprint": "$fp" },
    "reality": { "enabled": true, "public_key": "$pbk", "short_id": "$sid" }
  }
}
EOF
)"
  else
    # non-reality vless (basic)
    json="$(cat <<EOF
{
  "type": "vless",
  "tag": "$tag",
  "server": "$host",
  "server_port": $port,
  "uuid": "$uuid",
  "tls": { "enabled": false }
}
EOF
)"
  fi

  save_outbound "$tag" "$json"
  save_imported "$link"
  echo "$tag"
}

# hysteria2://pw@host:port/?insecure=1&sni=xx#name
import_hy2(){
  link="$1"
  core="$(strip_fragment "$link")"
  name="$(get_fragment "$link")"
  name="${name:-hy2-$(date +%m%d%H%M)}"

  core="${core#hysteria2://}"
  cred="${core%%@*}"
  rest="${core#*@}"
  hostport="${rest%%\?*}"
  query=""
  echo "$rest" | grep -q '\?' && query="${rest#*\?}"

  pw="$cred"
  host="${hostport%:*}"
  port="${hostport##*:}"
  sni="$(get_qparam "$query" sni)"
  insecure="$(get_qparam "$query" insecure)"
  [ -n "$insecure" ] || insecure="1"

  tag="$(echo "$name" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')"
  [ -n "$tag" ] || tag="hy2-$(date +%m%d%H%M)"

  json="$(cat <<EOF
{
  "type": "hysteria2",
  "tag": "$tag",
  "server": "$host",
  "server_port": $port,
  "password": "$pw",
  "tls": {
    "enabled": true,
    "server_name": "${sni:-$host}",
    "insecure": $( [ "$insecure" = "1" ] && echo true || echo false )
  }
}
EOF
)"
  save_outbound "$tag" "$json"
  save_imported "$link"
  echo "$tag"
}

# tuic://uuid:pw@host:port?congestion_control=bbr&alpn=h3&sni=xx&allow_insecure=1#name
import_tuic(){
  link="$1"
  core="$(strip_fragment "$link")"
  name="$(get_fragment "$link")"
  name="${name:-tuic-$(date +%m%d%H%M)}"

  core="${core#tuic://}"
  cred="${core%%@*}"
  rest="${core#*@}"
  hostport="${rest%%\?*}"
  query=""
  echo "$rest" | grep -q '\?' && query="${rest#*\?}"

  uuid="${cred%%:*}"
  pw="${cred#*:}"
  host="${hostport%:*}"
  port="${hostport##*:}"

  sni="$(get_qparam "$query" sni)"
  allow_insecure="$(get_qparam "$query" allow_insecure)"
  [ -n "$allow_insecure" ] || allow_insecure="1"
  cc="$(get_qparam "$query" congestion_control)"; [ -n "$cc" ] || cc="bbr"

  tag="$(echo "$name" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')"
  [ -n "$tag" ] || tag="tuic-$(date +%m%d%H%M)"

  json="$(cat <<EOF
{
  "type": "tuic",
  "tag": "$tag",
  "server": "$host",
  "server_port": $port,
  "uuid": "$uuid",
  "password": "$pw",
  "congestion_control": "$cc",
  "tls": {
    "enabled": true,
    "server_name": "${sni:-$host}",
    "insecure": $( [ "$allow_insecure" = "1" ] && echo true || echo false )
  }
}
EOF
)"
  save_outbound "$tag" "$json"
  save_imported "$link"
  echo "$tag"
}

# vmess://base64(json)
import_vmess(){
  link="$1"
  ensure_base64 || return 1

  payload="${link#vmess://}"
  json_raw="$(echo "$payload" | base64 -d 2>/dev/null || true)"
  [ -n "$json_raw" ] || { msg "❌ vmess 解码失败"; return 1; }

  # very light parse using sed/grep (no jq)
  ps="$(echo "$json_raw" | sed -n 's/.*"ps"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  add="$(echo "$json_raw" | sed -n 's/.*"add"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  port="$(echo "$json_raw" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)".*/\1/p' | head -n1)"
  id="$(echo "$json_raw" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  net="$(echo "$json_raw" | sed -n 's/.*"net"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  host="$(echo "$json_raw" | sed -n 's/.*"host"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  path="$(echo "$json_raw" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  tls="$(echo "$json_raw" | sed -n 's/.*"tls"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"

  [ -n "$ps" ] || ps="vmess-$(date +%m%d%H%M)"
  tag="$(echo "$ps" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')"
  [ -n "$tag" ] || tag="vmess-$(date +%m%d%H%M)"

  # only implement ws/tcp no-tls for now
  if [ "$net" = "ws" ]; then
    json="$(cat <<EOF
{
  "type": "vmess",
  "tag": "$tag",
  "server": "$add",
  "server_port": ${port:-443},
  "uuid": "$id",
  "security": "auto",
  "transport": {
    "type": "ws",
    "path": "${path:-/}",
    "headers": { "Host": "${host:-}" }
  },
  "tls": { "enabled": false }
}
EOF
)"
  else
    json="$(cat <<EOF
{
  "type": "vmess",
  "tag": "$tag",
  "server": "$add",
  "server_port": ${port:-443},
  "uuid": "$id",
  "security": "auto",
  "tls": { "enabled": false }
}
EOF
)"
  fi

  save_outbound "$tag" "$json"
  save_imported "$link"
  echo "$tag"
}

import_link_any(){
  link="$1"
  case "$link" in
    vless://*) import_vless "$link" ;;
    hysteria2://*) import_hy2 "$link" ;;
    tuic://*) import_tuic "$link" ;;
    vmess://*) import_vmess "$link" ;;
    *) msg "❌ 不支持的链接格式：${link%%:*}"; return 1 ;;
  esac
}

choose_slot(){
  echo
  echo "选择出口槽位："
  i=1
  for s in $(slot_list_default); do
    echo "$i) $s"
    i=$((i+1))
  done
  echo "9) 自定义输入"
  echo "0) 返回"
  printf "选择: "
  read c
  case "$c" in
    1) echo "HK";;
    2) echo "TW";;
    3) echo "JP";;
    4) echo "US";;
    5) echo "UK";;
    6) echo "DE";;
    7) echo "NL";;
    8) echo "SG";;
    9) printf "输入自定义槽位名（例如 AI-US）: "; read x; echo "$x" ;;
    *) echo "" ;;
  esac
}

exits_import_menu(){
  ensure_gateway_dirs
  echo
  echo "=============================="
  echo " 路线B：导入节点（粘贴链接）"
  echo "=============================="
  echo "支持：vless://  tuic://  hysteria2://  vmess://"
  echo
  printf "粘贴分享链接（回车返回）: "
  read link
  [ -n "${link:-}" ] || return 0

  slot="$(choose_slot)"
  [ -n "$slot" ] || return 0

  tag="$(import_link_any "$link")" || return 1
  slot_add_node "$slot" "$tag"
  msg "✅ 已绑定到槽位 $slot：$tag"

  # if proxy module provides rebuild helper, call it
  if command -v gw_routeB_rebuild >/dev/null 2>&1; then
    gw_routeB_rebuild || true
  else
    msg "ℹ️ 提示：稍后在网关里执行“一键开启/应用配置”使规则生效"
  fi
}

exits_slots_menu(){
  ensure_gateway_dirs
  while true; do
    echo
    echo "=============================="
    echo " 路线B：出口槽位管理"
    echo "=============================="
    echo "当前默认槽位：$(default_slot_get)"
    echo
    echo "1) 查看所有槽位绑定"
    echo "2) 设置默认槽位（全局 PROXY）"
    echo "3) 从槽位移除某节点"
    echo "4) 删除节点"
    echo "5) 查看节点详情(JSON)"
    echo "0) 返回"
    printf "选择: "
    read c
    case "$c" in
      1)
        echo
        for s in $(slot_list_default); do
          nodes="$(slot_get_nodes "$s")"
          printf "%s = %s\n" "$s" "${nodes:-<empty>}"
        done
        echo
        ;;
      2)
        s="$(choose_slot)"; [ -n "$s" ] || continue
        default_slot_set "$s"
        command -v gw_routeB_rebuild >/dev/null 2>&1 && gw_routeB_rebuild || true
        ;;
      3)
        s="$(choose_slot)"; [ -n "$s" ] || continue
        echo "槽位 $s 当前：$(slot_get_nodes "$s")"
        printf "输入要移除的节点 tag: "
        read t
        [ -n "${t:-}" ] || continue
        slot_remove_node "$s" "$t"
        msg "✅ 已从 $s 移除：$t"
        command -v gw_routeB_rebuild >/dev/null 2>&1 && gw_routeB_rebuild || true
        ;;
      4)
        echo "当前节点："
        node_list
        printf "输入要删除的节点 tag: "
        read t
        [ -n "${t:-}" ] || continue
        node_delete "$t"
        command -v gw_routeB_rebuild >/dev/null 2>&1 && gw_routeB_rebuild || true
        ;;
      5)
        echo "当前节点："
        node_list
        printf "输入要查看的节点 tag: "
        read t
        [ -n "${t:-}" ] || continue
        node_show "$t" || true
        ;;
      0) return 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

exits_menu(){
  ensure_gateway_dirs
  while true; do
    echo
    echo "=============================="
    echo " 路线B：出口与节点"
    echo "=============================="
    echo "1) 导入节点（粘贴链接）"
    echo "2) 出口槽位管理（绑定/默认/删除）"
    echo "3) 查看已导入链接记录"
    echo "0) 返回"
    printf "选择: "
    read c
    case "$c" in
      1) exits_import_menu ;;
      2) exits_slots_menu ;;
      3) tail -n 30 "$GW_IMPORTED_FILE" 2>/dev/null || true ;;
      0) return 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}
