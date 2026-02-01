#!/bin/sh
set -eu

msg(){ echo "[xsb-openwrt] $*" >&2; }

# ==============================
# Paths & Constants
# ==============================
GW_DIR="/etc/xsb/gateway"
GW_NODES_DIR="$GW_DIR/nodes.d"
GW_META_DIR="$GW_DIR/meta.d"
GW_SLOTS_FILE="$GW_DIR/slots.conf"          # SLOT_HK=tag1,tag2
GW_DEFAULT_SLOT_FILE="$GW_DIR/default_slot" # e.g. HK
GW_IMPORTED_FILE="$GW_DIR/imported_links.txt"
GW_MODE_FILE="$GW_DIR/route_mode"           # Stores: A, B, or C

# Template Paths (Based on your request)
# Assuming these are located inside /etc/xsb/ or a similar root. 
# Adjust BASE_DIR if xsb-onekey is located elsewhere.
BASE_DIR="/etc/xsb" 
TPL_A_BASIC="$BASE_DIR/xsb-onekey/config/template_basic.yaml"
TPL_B_LIGHT="$BASE_DIR/xsb-onekey/config/template_light.yaml"
TPL_C_FULL="$BASE_DIR/xsb-onekey/config/template.yaml"

ensure_gateway_dirs(){
  mkdir -p "$GW_DIR" "$GW_NODES_DIR" "$GW_META_DIR" >/dev/null 2>&1 || true
  [ -f "$GW_SLOTS_FILE" ] || : > "$GW_SLOTS_FILE"
  [ -f "$GW_IMPORTED_FILE" ] || : > "$GW_IMPORTED_FILE"
  # Default to Mode B if not set
  [ -f "$GW_MODE_FILE" ] || echo "B" > "$GW_MODE_FILE"
}

# ---------- deps ----------
need_pkg(){
  pkg="$1"
  opkg list-installed 2>/dev/null | grep -q "^$pkg " && return 0
  msg "安装依赖：$pkg"
  opkg update >/dev/null 2>&1 || true
  opkg install "$pkg" >/dev/null 2>&1 || true
}

ensure_base64(){
  command -v base64 >/dev/null 2>&1 && return 0
  need_pkg "coreutils-base64" || true
  command -v base64 >/dev/null 2>&1 && return 0
  msg "⚠️ 未找到 base64（vmess 导入不可用）"
  return 1
}

rand_hex(){
  n="$1"
  hexdump -vn "$n" -e '/1 "%02x"' /dev/urandom 2>/dev/null || echo "deadbeef"
}

safe_tag(){
  proto="$1"
  echo "${proto}-$(date +%m%d%H%M%S)-$(rand_hex 3)"
}

# ---------- slots ----------
slot_list_default(){ echo "HK TW JP US UK DE NL SG"; }
slot_key(){ echo "SLOT_$1"; }

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
  s="$1"; nodes="$2"
  key="$(slot_key "$s")"
  tmp="/tmp/xsb-slots.$$"
  grep -v -E "^$key=" "$GW_SLOTS_FILE" 2>/dev/null > "$tmp" || : > "$tmp"
  echo "$key=$nodes" >> "$tmp"
  mv "$tmp" "$GW_SLOTS_FILE"
}
slot_add_node(){
  s="$1"; node="$2"
  cur="$(slot_get_nodes "$s")"
  if [ -z "$cur" ]; then
    slot_set_nodes "$s" "$node"
  else
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
    tr -d '\r\n' < "$GW_DEFAULT_SLOT_FILE" 2>/dev/null || true
  fi
}
default_slot_set(){
  ensure_gateway_dirs
  echo "$1" > "$GW_DEFAULT_SLOT_FILE"
  msg "✅ 已设置默认出口槽位：$1"
}

# ---------- URL decode (for #name) ----------
url_decode(){
  s="$1"
  s="$(printf '%s' "$s" | tr '+' ' ' | tr -d '\r')"
  s="$(printf '%s' "$s" | sed 's/%/\\x/g')"
  printf '%b' "$s"
}
link_get_name(){
  link="$1"
  frag="${link#*#}"
  [ "$frag" = "$link" ] && frag=""
  [ -n "$frag" ] && url_decode "$frag" || printf ''
}

# ---------- multiline paste (fix slot menu not showing) ----------
read_link_paste(){
  echo
  echo "支持：vless://  tuic://  hysteria2://  vmess://"
  echo "请粘贴分享链接，可多行粘贴；粘贴完后再按一次回车提交（空行结束）"
  echo
  link=""
  while IFS= read -r line; do
    # 空行结束
    [ -z "${line:-}" ] && break
    # 去掉空白/回车，拼起来
    line="$(printf '%s' "$line" | tr -d '\r\n\t ')"
    link="${link}${line}"
  done
  printf '%s' "$link"
}

# ---------- nodes store ----------
node_path(){ echo "$GW_NODES_DIR/$1.json"; }
node_name_path(){ echo "$GW_META_DIR/$1.name"; }

node_list(){
  ls -1 "$GW_NODES_DIR" 2>/dev/null | sed 's/\.json$//' || true
}
node_name_get(){
  t="$1"
  f="$(node_name_path "$t")"
  [ -f "$f" ] && cat "$f" 2>/dev/null || true
}
node_list_pretty(){
  for t in $(node_list); do
    n="$(node_name_get "$t")"
    [ -n "$n" ] || n="$t"
    printf "%s  |  %s\n" "$t" "$n"
  done
}

node_show(){
  tag="$1"
  f="$(node_path "$tag")"
  [ -f "$f" ] || { msg "不存在节点：$tag"; return 1; }
  echo "----- $tag -----"
  echo "name: $(node_name_get "$tag")"
  cat "$f"
  echo "---------------"
}

node_delete(){
  tag="$1"
  rm -f "$(node_path "$tag")" "$(node_name_path "$tag")" 2>/dev/null || true
  for s in $(slot_list_default); do
    slot_remove_node "$s" "$tag" || true
  done
  msg "✅ 已删除节点：$tag"
}

save_imported(){ echo "$1" >> "$GW_IMPORTED_FILE" 2>/dev/null || true; }

# ---------- parse helpers ----------
get_qparam(){
  q="$1"; k="$2"
  echo "$q" | tr '&' '\n' | awk -F= -v kk="$k" '$1==kk {print $2; exit}'
}
strip_fragment(){ echo "$1" | sed 's/#.*$//'; }
get_fragment(){ echo "$1" | awk -F'#' 'NF>1{print $2}'; }

save_outbound(){
  tag="$1"
  name="$2"
  json="$3"
  ensure_gateway_dirs
  printf '%s\n' "$json" > "$(node_path "$tag")"
  [ -n "${name:-}" ] && printf '%s\n' "$name" > "$(node_name_path "$tag")"
  msg "✅ 已保存节点：$tag"
}

# ---------- importers ----------
import_vless(){
  link="$1"
  core="$(strip_fragment "$link")"
  name="$(link_get_name "$link")"
  [ -n "$name" ] || name="vless-$(date +%m%d%H%M)"

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

  tag="$(safe_tag vless)"

  if [ "$sec" = "reality" ]; then
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

  save_outbound "$tag" "$name" "$json"
  save_imported "$link"
  echo "$tag"
}

import_hy2(){
  link="$1"
  core="$(strip_fragment "$link")"
  name="$(link_get_name "$link")"
  [ -n "$name" ] || name="hy2-$(date +%m%d%H%M)"

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

  tag="$(safe_tag hy2)"
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
  save_outbound "$tag" "$name" "$json"
  save_imported "$link"
  echo "$tag"
}

import_tuic(){
  link="$1"
  core="$(strip_fragment "$link")"
  name="$(link_get_name "$link")"
  [ -n "$name" ] || name="tuic-$(date +%m%d%H%M)"

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

  tag="$(safe_tag tuic)"
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
  save_outbound "$tag" "$name" "$json"
  save_imported "$link"
  echo "$tag"
}

import_vmess(){
  link="$1"
  ensure_base64 || return 1
  payload="${link#vmess://}"

  # 兼容 URL-safe base64（有些订阅会用 -_）
  json_raw="$(printf '%s' "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null || true)"
  [ -n "$json_raw" ] || { msg "❌ vmess 解码失败"; return 1; }

  ps="$(echo "$json_raw" | sed -n 's/.*"ps"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  add="$(echo "$json_raw" | sed -n 's/.*"add"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  port="$(echo "$json_raw" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)".*/\1/p' | head -n1)"
  id="$(echo "$json_raw" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  net="$(echo "$json_raw" | sed -n 's/.*"net"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  host="$(echo "$json_raw" | sed -n 's/.*"host"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  path="$(echo "$json_raw" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"

  name="$ps"
  [ -n "$name" ] || name="vmess-$(date +%m%d%H%M)"
  tag="$(safe_tag vmess)"

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

  save_outbound "$tag" "$name" "$json"
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
  IFS= read -r c || c=""
  case "$c" in
    1) echo "HK";;
    2) echo "TW";;
    3) echo "JP";;
    4) echo "US";;
    5) echo "UK";;
    6) echo "DE";;
    7) echo "NL";;
    8) echo "SG";;
    9) printf "输入自定义槽位名（例如 AI-US）: "; IFS= read -r x; echo "$x" ;;
    0) echo "" ;;
    *) echo "" ;;
  esac
}

# ==============================
# Mode Management (A/B/C)
# ==============================
set_route_mode(){
  echo
  echo "当前分流模式: $(cat "$GW_MODE_FILE" 2>/dev/null || echo "Unknown")"
  echo "------------------------------"
  echo "A) 基础模式 (仅国内直连 + 国外代理)"
  echo "B) 轻量分流 (精简规则集)"
  echo "C) 完整分流 (Full Rules)"
  echo "------------------------------"
  printf "请选择模式 [A/B/C]: "
  read m || m=""
  
  mode="$(echo "$m" | tr '[:lower:]' '[:upper:]')"
  case "$mode" in
    A) 
      echo "A" > "$GW_MODE_FILE"
      msg "✅ 已切换至 A线：基础模式"
      ;;
    B) 
      echo "B" > "$GW_MODE_FILE"
      msg "✅ 已切换至 B线：轻量分流"
      ;;
    C) 
      echo "C" > "$GW_MODE_FILE"
      msg "✅ 已切换至 C线：完整分流"
      ;;
    *) msg "❌ 无效输入，未变更" ;;
  esac

  # Attempt rebuild if command exists
  if command -v gw_rebuild_all >/dev/null 2>&1; then
    msg "正在应用新模式..."
    gw_rebuild_all || true
  fi
}

# Helper to get current template file path (Called by config generator)
get_active_template(){
  mode="$(cat "$GW_MODE_FILE" 2>/dev/null || echo "B")"
  case "$mode" in
    A) echo "$TPL_A_BASIC" ;;
    C) echo "$TPL_C_FULL" ;;
    *) echo "$TPL_B_LIGHT" ;; # Default to B
  esac
}

# ---------- menus ----------
exits_import_menu(){
  ensure_gateway_dirs
  echo
  echo "=============================="
  echo " 导入节点（粘贴链接）"
  echo "=============================="

  link="$(read_link_paste)"
  [ -n "${link:-}" ] || return 0

  slot="$(choose_slot)"
  [ -n "$slot" ] || return 0

  tag="$(import_link_any "$link")" || return 1
  slot_add_node "$slot" "$tag"
  msg "✅ 已绑定到槽位 $slot：$tag | $(node_name_get "$tag")"

  if command -v gw_rebuild_all >/dev/null 2>&1; then
    gw_rebuild_all || true
  else
    msg "ℹ️ 提示：稍后在网关里执行“应用配置”使规则生效"
  fi
}

exits_slots_menu(){
  ensure_gateway_dirs
  while true; do
    echo
    echo "=============================="
    echo " 出口槽位管理"
    echo "=============================="
    ds="$(default_slot_get)"; [ -n "$ds" ] || ds="<unset>"
    echo "当前默认槽位：$ds"
    echo
    echo "1) 查看所有槽位绑定"
    echo "2) 设置默认槽位（全局 PROXY）"
    echo "3) 从槽位移除某节点"
    echo "4) 删除节点"
    echo "5) 查看节点详情(JSON)"
    echo "0) 返回"
    printf "选择: "
    IFS= read -r c || c=""
    case "$c" in
      1)
        echo
        for s in $(slot_list_default); do
          nodes="$(slot_get_nodes "$s")"
          if [ -z "$nodes" ]; then
            printf "%s = <empty>\n" "$s"
          else
            echo "$nodes" | tr ',' '\n' | while IFS= read -r t; do
              [ -n "$t" ] || continue
              printf "%s = %s | %s\n" "$s" "$t" "$(node_name_get "$t")"
            done
          fi
        done
        echo
        ;;
      2)
        s="$(choose_slot)"; [ -n "$s" ] || continue
        default_slot_set "$s"
        command -v gw_rebuild_all >/dev/null 2>&1 && gw_rebuild_all || true
        ;;
      3)
        s="$(choose_slot)"; [ -n "$s" ] || continue
        echo
        echo "槽位 $s 当前绑定："
        nodes="$(slot_get_nodes "$s")"
        [ -n "$nodes" ] || { echo "<empty>"; continue; }
        echo "$nodes" | tr ',' '\n' | while IFS= read -r t; do
          [ -n "$t" ] || continue
          printf " - %s | %s\n" "$t" "$(node_name_get "$t")"
        done
        echo
        printf "输入要移除的节点 tag: "
        IFS= read -r t || t=""
        [ -n "$t" ] || continue
        slot_remove_node "$s" "$t"
        msg "✅ 已从 $s 移除：$t"
        command -v gw_rebuild_all >/dev/null 2>&1 && gw_rebuild_all || true
        ;;
      4)
        echo "当前节点："
        node_list_pretty
        printf "输入要删除的节点 tag: "
        IFS= read -r t || t=""
        [ -n "$t" ] || continue
        node_delete "$t"
        command -v gw_rebuild_all >/dev/null 2>&1 && gw_rebuild_all || true
        ;;
      5)
        echo "当前节点："
        node_list_pretty
        printf "输入要查看的节点 tag: "
        IFS= read -r t || t=""
        [ -n "$t" ] || continue
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
    curr_m="$(cat "$GW_MODE_FILE" 2>/dev/null || echo "B")"
    echo
    echo "=============================="
    echo " 网关路由管理 (当前模式: $curr_m)"
    echo "=============================="
    echo "1) 切换分流模式 (A/B/C)"
    echo "2) 导入节点（粘贴链接）"
    echo "3) 出口槽位管理（绑定/默认/删除）"
    echo "4) 查看已导入链接记录(末30条)"
    echo "0) 返回"
    printf "选择: "
    IFS= read -r c || c=""
    case "$c" in
      1) set_route_mode ;;
      2) exits_import_menu ;;
      3) exits_slots_menu ;;
      4) tail -n 30 "$GW_IMPORTED_FILE" 2>/dev/null || true ;;
      0) return 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}
