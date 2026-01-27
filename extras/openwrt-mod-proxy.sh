#!/bin/sh
# ==========================================
# XSB OpenWrt Module: Transparent Proxy Gateway (Base)
# - Base profile: DNS hijack + TCP redirect (REDIRECT)
# - CN direct via lightweight domain list (no geo db required)
# - Uses a separate service: /etc/init.d/xsb-gw
# - Rollback supported
#
# IMPORTANT:
# - This file is SOURCED by openwrt-tiny.sh (". file"),
#   so DO NOT use: set -e / set -u here (will污染主脚本环境)
# ==========================================

# 如果主脚本已经有 msg()，就不要覆盖
if ! command -v msg >/dev/null 2>&1; then
  msg(){ echo "[xsb-openwrt] $*" >&2; }
fi

GW_DIR="/etc/xsb/gateway"
GW_CFG="$GW_DIR/proxy.json"
GW_BAK_DIR="$GW_DIR/backup"
GW_MARK_BEGIN="# XSB-GW-BEGIN"
GW_MARK_END="# XSB-GW-END"
GW_INIT="/etc/init.d/xsb-gw"
GW_MODE_FILE="$GW_DIR/mode"          # redirect|tproxy (base implements redirect)
GW_UPSTREAM_FILE="$GW_DIR/upstream"  # socks host:port
GW_ROUTE_FILE="$GW_DIR/route_mode"   # A|B

SB_BIN="/usr/bin/sing-box"
DNS_PORT="1053"
REDIR_PORT="7892"

has_cmd(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || { msg "请用 root 运行"; return 1; }; }

ensure_gateway_dirs(){
  mkdir -p "$GW_DIR" "$GW_BAK_DIR" >/dev/null 2>&1 || true
}

# ---------- backup / rollback ----------
gw_backup(){
  ensure_gateway_dirs
  ts="$(date +%F-%H%M%S)"
  b="$GW_BAK_DIR/$ts"
  mkdir -p "$b" >/dev/null 2>&1 || true

  [ -f /etc/firewall.user ] && cp -a /etc/firewall.user "$b/firewall.user" 2>/dev/null || true
  [ -f /etc/config/firewall ] && cp -a /etc/config/firewall "$b/firewall" 2>/dev/null || true
  [ -f /etc/config/dhcp ] && cp -a /etc/config/dhcp "$b/dhcp" 2>/dev/null || true
  [ -f "$GW_CFG" ] && cp -a "$GW_CFG" "$b/proxy.json" 2>/dev/null || true
  [ -f "$GW_MODE_FILE" ] && cp -a "$GW_MODE_FILE" "$b/mode" 2>/dev/null || true
  [ -f "$GW_UPSTREAM_FILE" ] && cp -a "$GW_UPSTREAM_FILE" "$b/upstream" 2>/dev/null || true
  [ -f "$GW_INIT" ] && cp -a "$GW_INIT" "$b/xsb-gw.init" 2>/dev/null || true

  msg "✅ 已备份到：$b"
}

gw_rollback_latest(){
  ensure_gateway_dirs
  latest="$(ls -1 "$GW_BAK_DIR" 2>/dev/null | sort | tail -n1 || true)"
  [ -n "$latest" ] || { msg "⚠️ 没有可用备份"; return 1; }
  b="$GW_BAK_DIR/$latest"

  [ -f "$b/firewall.user" ] && cp -a "$b/firewall.user" /etc/firewall.user 2>/dev/null || true
  [ -f "$b/firewall" ] && cp -a "$b/firewall" /etc/config/firewall 2>/dev/null || true
  [ -f "$b/dhcp" ] && cp -a "$b/dhcp" /etc/config/dhcp 2>/dev/null || true
  [ -f "$b/proxy.json" ] && cp -a "$b/proxy.json" "$GW_CFG" 2>/dev/null || true
  [ -f "$b/mode" ] && cp -a "$b/mode" "$GW_MODE_FILE" 2>/dev/null || true
  [ -f "$b/upstream" ] && cp -a "$b/upstream" "$GW_UPSTREAM_FILE" 2>/dev/null || true

  if [ -f "$b/xsb-gw.init" ]; then
    cp -a "$b/xsb-gw.init" "$GW_INIT" 2>/dev/null || true
    chmod +x "$GW_INIT" 2>/dev/null || true
  fi

  /etc/init.d/firewall restart >/dev/null 2>&1 || true
  /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
  msg "✅ 已回滚到：$latest"
}

# ---------- upstream (base) ----------
gw_read_upstream(){
  if [ -f "$GW_UPSTREAM_FILE" ]; then
    cat "$GW_UPSTREAM_FILE" 2>/dev/null || true
  else
    echo "127.0.0.1:7890"
  fi
}

gw_set_upstream(){
  ensure_gateway_dirs
  cur="$(gw_read_upstream)"
  echo
  echo "设置上游代理（基础档：使用 SOCKS5 上游）"
  echo "当前：$cur"
  echo "示例：127.0.0.1:7890  或  192.168.1.2:1080"
  printf "输入新的上游(回车保持不变): "
  read v
  if [ -n "${v:-}" ]; then
    echo "$v" > "$GW_UPSTREAM_FILE"
    msg "✅ 已设置上游：$v"
  else
    msg "ℹ️ 保持不变：$cur"
  fi
}

# ---------- sing-box gateway config (base) ----------
cn_domains_json(){
  cat <<'EOF'
[
  "cn",
  "baidu.com","bdimg.com",
  "qq.com","qpic.cn","weixin.qq.com","wechat.com",
  "taobao.com","tmall.com","alicdn.com","aliyun.com","alibaba.com",
  "jd.com","360.com",
  "bilibili.com","bilivideo.com",
  "douyin.com","byteimg.com","bytedance.com",
  "mi.com","xiaomi.com",
  "huawei.com",
  "csdn.net"
]
EOF
}

write_gw_config_redirect(){
  ensure_gateway_dirs
  upstream="$(gw_read_upstream)"
  up_host="${upstream%:*}"
  up_port="${upstream##*:}"

  tmp="/tmp/xsb-gw-proxy.json"
  cn_list="$(cn_domains_json)"

  cat > "$tmp" <<EOF
{
  "log": { "level": "info" },

  "dns": {
    "servers": [
      { "tag": "cn", "address": "223.5.5.5", "detour": "direct" },
      { "tag": "proxy", "address": "https://1.1.1.1/dns-query", "detour": "proxy" }
    ],
    "rules": [
      { "domain_suffix": $cn_list, "server": "cn" }
    ],
    "final": "proxy",
    "listen": "0.0.0.0",
    "listen_port": $DNS_PORT,
    "strategy": "prefer_ipv4",
    "disable_cache": false
  },

  "inbounds": [
    {
      "type": "redirect",
      "tag": "redir-in",
      "listen": "0.0.0.0",
      "listen_port": $REDIR_PORT,
      "sniff": true
    }
  ],

  "outbounds": [
    { "type": "direct", "tag": "direct" },
    {
      "type": "socks",
      "tag": "proxy",
      "server": "$up_host",
      "server_port": $up_port,
      "version": "5"
    }
  ],

  "route": {
    "rules": [
      { "domain_suffix": $cn_list, "outbound": "direct" },
      { "ip_is_private": true, "outbound": "direct" }
    ],
    "final": "proxy",
    "auto_detect_interface": true
  }
}
EOF

  if [ -x "$SB_BIN" ]; then
    if ! "$SB_BIN" check -c "$tmp" >/dev/null 2>&1; then
      msg "❌ 网关 sing-box 配置校验失败：$tmp"
      "$SB_BIN" check -c "$tmp" 2>&1 | sed 's/^/[sing-box-check] /' >&2 || true
      return 1
    fi
  else
    msg "⚠️ 未找到 $SB_BIN，跳过配置校验（请先安装 sing-box）"
  fi

  mv "$tmp" "$GW_CFG"
  msg "✅ 已写入网关配置：$GW_CFG"
  return 0
}

# ---------- init service xsb-gw ----------
ensure_gw_service(){
  [ -x "$SB_BIN" ] || return 1
  ensure_gateway_dirs

  if [ ! -x "$GW_INIT" ]; then
    cat > "$GW_INIT" <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=96
STOP=10

CFG="/etc/xsb/gateway/proxy.json"

start_service() {
  [ -f "$CFG" ] || exit 0
  procd_open_instance
  procd_set_param command /usr/bin/sing-box run -c "$CFG"
  procd_set_param respawn 3600 5 5
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF
    chmod +x "$GW_INIT" 2>/dev/null || true
    "$GW_INIT" enable >/dev/null 2>&1 || true
    msg "✅ 已创建并启用：$GW_INIT"
  fi
  return 0
}

gw_service(){
  ensure_gw_service >/dev/null 2>&1 || true
  if [ -x "$GW_INIT" ]; then
    "$GW_INIT" "$1" >/dev/null 2>&1 || true
  else
    msg "⚠️ 未发现 $GW_INIT（sing-box 未安装？）"
  fi
}

# ---------- firewall.user injection (base redirect + DNS hijack) ----------
fwuser_clean_block(){
  [ -f /etc/firewall.user ] || touch /etc/firewall.user
  awk '
    BEGIN{inblk=0}
    $0=="'"$GW_MARK_BEGIN"'"{inblk=1; next}
    $0=="'"$GW_MARK_END"'"{inblk=0; next}
    inblk==0{print}
  ' /etc/firewall.user > /tmp/firewall.user.clean && mv /tmp/firewall.user.clean /etc/firewall.user
}

fwuser_append_block_redirect(){
  [ -f /etc/firewall.user ] || touch /etc/firewall.user

  cat >> /etc/firewall.user <<EOF

$GW_MARK_BEGIN
# XSB Gateway (Base): DNS hijack + TCP redirect to sing-box
iptables -t nat -C PREROUTING -i br-lan -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT 2>/dev/null || \
iptables -t nat -A PREROUTING -i br-lan -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT

iptables -t nat -C PREROUTING -i br-lan -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT 2>/dev/null || \
iptables -t nat -A PREROUTING -i br-lan -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT

iptables -t nat -C PREROUTING -i br-lan -p tcp -j REDIRECT --to-ports $REDIR_PORT 2>/dev/null || \
iptables -t nat -A PREROUTING -i br-lan -p tcp -j REDIRECT --to-ports $REDIR_PORT
$GW_MARK_END
EOF
}

apply_firewall_user(){
  fwuser_clean_block
  fwuser_append_block_redirect
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
  msg "✅ 已应用防火墙透明劫持（/etc/firewall.user）"
}

remove_firewall_user(){
  fwuser_clean_block
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
  msg "✅ 已移除防火墙透明劫持（/etc/firewall.user）"
}

# ---------- self-check ----------
gw_selfcheck(){
  if [ -x "$GW_INIT" ]; then
    st="$($GW_INIT status 2>/dev/null || true)"
    echo "$st" | grep -qi "running" || { msg "❌ xsb-gw 未运行"; return 1; }
  fi
  msg "✅ 自检通过（基础检查）"
  return 0
}

# ---------- mode selection (base) ----------
gw_select_mode(){
  ensure_gateway_dirs
  echo
  echo "选择透明模式："
  echo "1) REDIRECT（基础档：最稳，TCP 透明；UDP 暂不接管）"
  echo "2) TPROXY（下一阶段实现：TCP+UDP 全透明）"
  echo "0) 返回"
  printf "选择: "
  read c
  case "$c" in
    1) echo "redirect" > "$GW_MODE_FILE"; msg "✅ 已选择：REDIRECT" ;;
    2) echo "tproxy" > "$GW_MODE_FILE"; msg "✅ 已选择：TPROXY（尚未实现，先占位）" ;;
    *) return 0 ;;
  esac
}

gw_get_mode(){
  if [ -f "$GW_MODE_FILE" ]; then
    cat "$GW_MODE_FILE" 2>/dev/null || true
  else
    echo "redirect"
  fi
}

gw_get_route_mode(){
  if [ -f "$GW_ROUTE_FILE" ]; then
    cat "$GW_ROUTE_FILE" 2>/dev/null | tr -d '\r\n' || true
  fi
}

gw_set_route_mode(){
  ensure_gateway_dirs
  echo
  echo "选择网关路线："
  echo "1) 路线A：使用上游代理（mihomo/OpenClash 等 SOCKS5）【推荐稳】"
  echo "2) 路线B：XSB 自管节点 + 规则分流 + 出口池【终局形态】"
  echo "0) 取消"
  printf "选择: "
  read c
  case "$c" in
    1) echo "A" > "$GW_ROUTE_FILE"; msg "✅ 已选择：路线A（上游代理）" ;;
    2) echo "B" > "$GW_ROUTE_FILE"; msg "✅ 已选择：路线B（自管节点分流）" ;;
    *) return 1 ;;
  esac
  return 0
}

gw_ensure_route_selected(){
  m="$(gw_get_route_mode)"
  if [ "$m" = "A" ] || [ "$m" = "B" ]; then
    return 0
  fi
  msg "首次进入网关：请先选择路线（A/B）"
  gw_set_route_mode
}

# ---------- enable / disable ----------
gw_enable_onekey(){
  need_root || return 1
  ensure_gateway_dirs

  # 依赖主脚本：install_singbox
  if ! has_cmd sing-box; then
    msg "未检测到 sing-box，正在安装..."
    if command -v install_singbox >/dev/null 2>&1; then
      install_singbox || { msg "❌ sing-box 安装失败"; return 1; }
    else
      msg "❌ 未找到 install_singbox（请先更新 openwrt-tiny.sh）"
      return 1
    fi
  fi

  mode="$(gw_get_mode)"
  if [ "$mode" != "redirect" ]; then
    msg "⚠️ 当前模式=$mode，但基础档仅实现 redirect，已强制使用 redirect"
    echo "redirect" > "$GW_MODE_FILE"
  fi

  gw_backup
  msg "基础档：上游代理使用 SOCKS5（默认 127.0.0.1:7890，可改）"
  gw_set_upstream

  write_gw_config_redirect || { msg "❌ 写入网关配置失败，准备回滚"; gw_rollback_latest || true; return 1; }
  ensure_gw_service || { msg "❌ 创建网关服务失败，准备回滚"; gw_rollback_latest || true; return 1; }

  apply_firewall_user
  gw_service restart
  sleep 1

  if ! gw_selfcheck; then
    msg "❌ 自检失败：准备自动回滚"
    gw_service stop
    remove_firewall_user
    gw_rollback_latest || true
    return 1
  fi

  msg "✅ 透明代理网关已开启（基础档）"
}

gw_disable_and_rollback(){
  need_root || return 1
  msg "关闭透明代理网关：停止 xsb-gw + 移除劫持 + 回滚备份"
  gw_service stop
  remove_firewall_user
  gw_rollback_latest || true
}

# ---------- status ----------
gw_status(){
  mode="$(gw_get_mode)"
  upstream="$(gw_read_upstream)"

  echo
  echo "=============================="
  echo " XSB 透明代理网关状态（基础档）"
  echo "=============================="
  echo "模式：$mode"
  echo "上游 SOCKS5：$upstream"
  echo "网关配置：$GW_CFG"
  echo

  if [ -x "$GW_INIT" ]; then
    echo "[xsb-gw] $($GW_INIT status 2>/dev/null || echo unknown)"
  else
    echo "[xsb-gw] 未安装（未创建 /etc/init.d/xsb-gw）"
  fi

  echo
  echo "[防火墙标记] /etc/firewall.user："
  grep -n "XSB-GW" -n /etc/firewall.user 2>/dev/null || echo "（未发现）"
  echo
}

call_module_func(){
  _mod="$1"
  _fn="$2"

  if ! mod_load "$_mod"; then
    msg "❌ 加载失败：$_mod"
    return 1
  fi

  if ! type "$_fn" >/dev/null 2>&1; then
    msg "❌ 模块 $_mod 已加载，但缺少入口函数：$_fn()"
    return 1
  fi

  "$_fn"
}

# ---------- public entry ----------
proxy_gateway_menu(){
  need_root || return 1
  ensure_gateway_dirs
  gw_ensure_route_selected || true

  while true; do
    route="$(gw_get_route_mode)"
    [ "$route" = "A" ] || [ "$route" = "B" ] || route="A"

    echo
    echo "=============================="
    if [ "$route" = "A" ]; then
      echo " XSB 透明代理网关（OpenWrt）[路线A：上游代理]"
    else
      echo " XSB 透明代理网关（OpenWrt）[路线B：自管节点分流]"
    fi
    echo "=============================="
    echo

    if [ "$route" = "A" ]; then
      echo "1) 一键开启（基础档：国内直连/国外代理）"
      echo "2) 选择透明模式（REDIRECT/TPROXY）"
      echo "3) 设置上游代理（SOCKS5）"
      echo "4) 状态查看"
      echo "5) 一键关闭并回滚（救命按钮）"
      echo "6) 切换路线（A/B）"
      echo "0) 返回"
      printf "选择: "
      read c

      case "$c" in
        1) gw_enable_onekey ;;
        2) gw_select_mode ;;
        3) gw_set_upstream ;;
        4) gw_status ;;
        5) gw_disable_and_rollback ;;
        6) gw_set_route_mode || true ;;
        0) return 0 ;;
        *) echo "无效选项" ;;
      esac
    else
      echo "1) 一键开启（基础分流模板）"
      echo "2) 导入节点/出口槽位（粘贴链接）[TODO]"
      echo "3) 规则分流（AI/TikTok/Crypto/Spotify/Google/YouTube…）[TODO]"
      echo "4) 出口池与自动切换（健康检查/失败回退）[TODO]"
      echo "5) 模式与DNS（TPROXY/REDIRECT/FakeIP）"
      echo "6) 状态与诊断"
      echo "7) 备份与回滚（救命按钮）"
      echo "8) 切换路线（A/B）"
      echo "0) 返回"
      printf "选择: "
      read c

      case "$c" in
        1) gw_enable_onekey ;;
        2) call_module_func openwrt-mod-exits.sh exits_menu ;;
        3) call_module_func openwrt-mod-rules.sh rules_menu ;;
        4) call_module_func openwrt-mod-pool.sh pool_menu ;;
        5) gw_select_mode ;;
        6) gw_status ;;
        7) gw_disable_and_rollback ;;
        8) gw_set_route_mode || true ;;
        0) return 0 ;;
        *) echo "无效选项" ;;
      esac
    fi
  done
}
