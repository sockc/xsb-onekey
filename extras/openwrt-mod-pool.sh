#!/bin/sh
set -eu
msg(){ echo "[xsb-openwrt] $*" >&2; }

GW_DIR="/etc/xsb/gateway"
GW_POOL_FILE="$GW_DIR/pool.conf"  # e.g. POOL_AI=on

ensure_gateway_dirs(){
  mkdir -p "$GW_DIR" >/dev/null 2>&1 || true
  [ -f "$GW_POOL_FILE" ] || touch "$GW_POOL_FILE"
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

pool_menu(){
  ensure_gateway_dirs
  while true; do
    echo
    echo "=============================="
    echo " 路线B：出口池与自动切换"
    echo "=============================="
    echo "说明：开启后分组可使用 urltest 自动选择最快出口（需 sing-box 支持）"
    echo
    echo "1) 查看当前设置"
    echo "2) AI 分组：开启/关闭 urltest"
    echo "3) YouTube 分组：开启/关闭 urltest"
    echo "4) TikTok 分组：开启/关闭 urltest"
    echo "5) Crypto 分组：开启/关闭 urltest"
    echo "6) Spotify 分组：开启/关闭 urltest"
    echo "0) 返回"
    printf "选择: "
    read c

    case "$c" in
      1)
        echo
        for g in AI YOUTUBE TIKTOK CRYPTO SPOTIFY; do
          v="$(get_kv "$GW_POOL_FILE" "POOL_$g")"
          printf "  %-8s urltest = %s\n" "$g" "${v:-off}"
        done
        echo
        ;;
      2|3|4|5|6)
        case "$c" in
          2) g="AI" ;;
          3) g="YOUTUBE" ;;
          4) g="TIKTOK" ;;
          5) g="CRYPTO" ;;
          6) g="SPOTIFY" ;;
        esac
        cur="$(get_kv "$GW_POOL_FILE" "POOL_$g")"
        [ "$cur" = "on" ] && nv="off" || nv="on"
        set_kv "$GW_POOL_FILE" "POOL_$g" "$nv"
        msg "✅ $g urltest 已设置为：$nv"
        command -v gw_routeB_rebuild >/dev/null 2>&1 && gw_routeB_rebuild || true
        ;;
      0) return 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}
