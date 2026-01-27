#!/bin/sh
set -eu
msg(){ echo "[xsb-openwrt] $*" >&2; }

GW_DIR="/etc/xsb/gateway"
GW_RULES_FILE="$GW_DIR/group_map.conf"     # GROUP_AI=US
GW_CUSTOM_FILE="$GW_DIR/custom_domains.conf" # domain slot

ensure_gateway_dirs(){
  mkdir -p "$GW_DIR" >/dev/null 2>&1 || true
  [ -f "$GW_RULES_FILE" ] || touch "$GW_RULES_FILE"
  [ -f "$GW_CUSTOM_FILE" ] || touch "$GW_CUSTOM_FILE"
}

get_kv(){
  f="$1"; k="$2"
  grep -E "^$k=" "$f" 2>/dev/null | tail -n1 | sed -E "s/^$k=//" || true
}
set_kv(){
  f="$1"; k="$2"; v="$3"
  grep -v -E "^$k=" "$f" 2>/dev/null > /tmp/xsb-kv.tmp || true
  echo "$k=$v" >> /tmp/xsb-kv.tmp
  mv /tmp/xsb-kv.tmp "$f"
}

choose_slot(){
  echo
  echo "选择出口槽位：HK/TW/JP/US/UK/DE/NL/SG 或自定义"
  printf "输入槽位（回车取消）: "
  read s
  echo "$s"
}

group_list(){
  echo "GOOGLE YOUTUBE AI TIKTOK CRYPTO SPOTIFY"
}

show_groups(){
  echo
  echo "当前分组绑定："
  for g in $(group_list); do
    v="$(get_kv "$GW_RULES_FILE" "GROUP_$g")"
    printf "  %-8s -> %s\n" "$g" "${v:-<unset>}"
  done
  echo
}

bind_group(){
  g="$1"
  s="$(choose_slot)"
  [ -n "${s:-}" ] || return 0
  set_kv "$GW_RULES_FILE" "GROUP_$g" "$s"
  msg "✅ 已绑定：$g -> $s"
  command -v gw_routeB_rebuild >/dev/null 2>&1 && gw_routeB_rebuild || true
}

custom_add(){
  echo
  printf "输入域名（例如 api.openai.com 或 openai.com）: "
  read d
  [ -n "${d:-}" ] || return 0
  s="$(choose_slot)"
  [ -n "${s:-}" ] || return 0
  echo "$d $s" >> "$GW_CUSTOM_FILE"
  msg "✅ 已添加自定义域名：$d -> $s"
  command -v gw_routeB_rebuild >/dev/null 2>&1 && gw_routeB_rebuild || true
}

custom_list(){
  echo
  echo "自定义域名绑定（domain slot）："
  tail -n 50 "$GW_CUSTOM_FILE" 2>/dev/null || true
  echo
}

custom_clear(){
  : > "$GW_CUSTOM_FILE"
  msg "✅ 已清空自定义域名"
  command -v gw_routeB_rebuild >/dev/null 2>&1 && gw_routeB_rebuild || true
}

rules_menu(){
  ensure_gateway_dirs
  while true; do
    echo
    echo "=============================="
    echo " 路线B：规则分流"
    echo "=============================="
    echo "1) 查看当前分组绑定"
    echo "2) Google -> 选择出口"
    echo "3) YouTube -> 选择出口"
    echo "4) AI/LLM -> 选择出口"
    echo "5) TikTok -> 选择出口"
    echo "6) Crypto -> 选择出口"
    echo "7) Spotify -> 选择出口"
    echo "8) 自定义域名绑定 -> 选择出口"
    echo "9) 查看自定义域名"
    echo "10) 清空自定义域名"
    echo "0) 返回"
    printf "选择: "
    read c
    case "$c" in
      1) show_groups ;;
      2) bind_group GOOGLE ;;
      3) bind_group YOUTUBE ;;
      4) bind_group AI ;;
      5) bind_group TIKTOK ;;
      6) bind_group CRYPTO ;;
      7) bind_group SPOTIFY ;;
      8) custom_add ;;
      9) custom_list ;;
      10) custom_clear ;;
      0) return 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}
