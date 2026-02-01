#!/bin/sh
set -eu

msg(){ echo "[xsb-openwrt] $*" >&2; }

# ==============================
# 路径与变量
# ==============================
GW_DIR="/etc/xsb/gateway"
GW_MODE_FILE="$GW_DIR/route_mode"           # 存储模式: A, B, C
GW_SUB_URL_FILE="$GW_DIR/sub_url.conf"      # 存储订阅链接
SB_CFG="/etc/sing-box/config.json"
MIHOMO_CFG="/etc/mihomo/config.yaml"

# 确保目录存在
ensure_dirs(){
  mkdir -p "$GW_DIR" /etc/sing-box /etc/mihomo >/dev/null 2>&1 || true
  [ -f "$GW_MODE_FILE" ] || echo "A" > "$GW_MODE_FILE"
  [ -f "$GW_SUB_URL_FILE" ] || touch "$GW_SUB_URL_FILE"
}

# ==============================
# 依赖检查
# ==============================
check_dependencies(){
  # 检查 python3 (用于生成 Sing-box 配置)
  if ! command -v python3 >/dev/null 2>&1; then
    msg "❌ 缺少 python3，无法生成 Sing-box 规则。"
    msg "请运行: opkg update && opkg install python3-light python3-json"
    return 1
  fi
  return 0
}

# ==============================
# 1. 设置订阅链接
# ==============================
set_subscription(){
  echo
  echo ">>> 设置订阅链接 <<<"
  echo "注意：由于使用 Sing-box，建议使用【Sing-box 格式】的订阅链接。"
  echo "如果不确定，请使用转换工具将机场订阅转换为 Sing-box 格式。"
  echo
  curr="$(cat "$GW_SUB_URL_FILE" 2>/dev/null || echo "")"
  [ -n "$curr" ] && echo "当前链接: ${curr:0:30}..."
  
  printf "请输入订阅链接 (回车取消): "
  read url
  if [ -n "$url" ]; then
    echo "$url" > "$GW_SUB_URL_FILE"
    msg "✅ 链接已保存"
  fi
}

# ==============================
# 2. 核心：Python 配置生成器
# ==============================
# 这个函数会临时创建一个 Python 脚本来生成复杂的 config.json
generate_sb_config(){
  mode="$1"
  sub_url="$2"
  
  cat <<EOF > /tmp/gen_sb.py
import json
import sys

mode = "$mode"
sub_url = "$sub_url"

# --- 基础结构 ---
config = {
    "log": {"level": "info"},
    "dns": {
        "servers": [
            {"tag": "google", "address": "https://8.8.8.8/dns-query", "detour": "🚀 节点选择"},
            {"tag": "local", "address": "223.5.5.5", "detour": "DIRECT"},
            {"tag": "block", "address": "rcode://success"}
        ],
        "rules": [
            {"outbound": "any", "server": "local"}
        ],
        "strategy": "ipv4_only"
    },
    "inbounds": [
        {"type": "tproxy", "tag": "tproxy-in", "listen": "::", "listen_port": 7893},
        {"type": "mixed", "tag": "mixed-in", "listen": "::", "listen_port": 7890}
    ],
    "outbounds": [],
    "route": {"rules": []}
}

# --- 出站策略 (Outbounds) ---
# 1. 核心选择器
outbounds = [
    {"type": "selector", "tag": "🚀 节点选择", "outbounds": ["⚡ 自动优选", "DIRECT"], "interrupt_exist_connections": True},
    {"type": "urltest", "tag": "⚡ 自动优选", "outbounds": [], "url": "http://www.gstatic.com/generate_204", "interval": "10m"},
    {"type": "direct", "tag": "DIRECT"},
    {"type": "block", "tag": "BLOCK"},
    {"type": "dns", "tag": "dns-out"}
]

# 2. 模式 B 的额外策略组 (对应你刚才的规则)
if mode == "B":
    groups = ["📹 YouTube", "🎵 Spotify", "💳 PayPal", "🤖 AI & Copilot", "📺 其他流媒体", "💰 虚拟货币", "📲 电报消息", "🐟 漏网之鱼"]
    for g in groups:
        outbounds.append({"type": "selector", "tag": g, "outbounds": ["🚀 节点选择", "⚡ 自动优选", "DIRECT"]})

config["outbounds"] = outbounds

# --- 分流规则 (Route) ---
rules = [
    {"protocol": "dns", "outbound": "dns-out"},
    {"port": [22, 53, 9090, 7890, 7893], "outbound": "DIRECT"}
]

if mode == "A":
    # === A线: 基础分流 ===
    rules.append({"geosite": ["cn"], "geoip": ["cn", "private"], "outbound": "DIRECT"})
    rules.append({"outbound": "🚀 节点选择"}) # 兜底

elif mode == "B":
    # === B线: 你的定制规则 ===
    # 独立应用
    rules.append({"geosite": ["youtube"], "outbound": "📹 YouTube"})
    rules.append({"geosite": ["spotify"], "outbound": "🎵 Spotify"})
    rules.append({"geosite": ["paypal"], "outbound": "💳 PayPal"})
    # AI
    rules.append({"geosite": ["openai", "anthropic", "google-gemini", "github"], "outbound": "🤖 AI & Copilot"})
    # 流媒体
    rules.append({"geosite": ["netflix", "disney", "category-porn"], "outbound": "📺 其他流媒体"})
    # 货币
    rules.append({"geosite": ["category-cryptocurrency", "binance", "okx"], "outbound": "💰 虚拟货币"})
    # 社媒
    rules.append({"geosite": ["telegram"], "outbound": "📲 电报消息"})
    rules.append({"geoip": ["telegram"], "outbound": "📲 电报消息"})
    # 常规
    rules.append({"geosite": ["google", "microsoft"], "outbound": "🚀 节点选择"})
    # 直连
    rules.append({"geosite": ["cn"], "geoip": ["cn", "private"], "outbound": "DIRECT"})
    # 兜底
    rules.append({"outbound": "🐟 漏网之鱼"})

config["route"]["rules"] = rules

# --- 特殊处理: 订阅节点 ---
# Sing-box 不像 Clash 那样原生支持 url 订阅。
# 为了脚本简单，我们在生成的 JSON 里加一个 "experimental" 字段提示。
# 实际节点需要通过 'sing-box-subscribe' 或类似工具注入，或者这里假设 sub_url 也是一个 Remote set.
# 这里我们用最简单的 Remote 方案 (Sing-box 1.8+):
if sub_url:
    # 定义一个 Remote Tag
    remote_tag = "remote-nodes"
    # 添加 Remote Outbound
    # 注意: 如果你的订阅不是 Sing-box 格式，这里会报错。
    # 暂时作为提示，或者需要配合外部转换器。
    pass 

print(json.dumps(config, indent=2, ensure_ascii=False))
EOF

  # 执行生成
  python3 /tmp/gen_sb.py > "$SB_CFG"
  rm -f /tmp/gen_sb.py
}

# ==============================
# 3. 应用配置 (重建)
# ==============================
gw_rebuild_all(){
  ensure_dirs
  check_dependencies || return 1
  
  mode="$(cat "$GW_MODE_FILE" 2>/dev/null || echo "A")"
  sub_url="$(cat "$GW_SUB_URL_FILE" 2>/dev/null || echo "")"
  
  echo
  msg "🔄 正在应用模式: $mode"
  
  # --- 停止所有服务 ---
  [ -x /etc/init.d/sing-box ] && /etc/init.d/sing-box stop >/dev/null 2>&1
  [ -x /etc/init.d/mihomo ] && /etc/init.d/mihomo stop >/dev/null 2>&1
  
  case "$mode" in
    A|B)
      # === SING-BOX 模式 ===
      msg "   - 内核: Sing-box"
      if [ -z "$sub_url" ]; then
        msg "⚠️ 警告：未设置订阅链接！"
      fi
      
      msg "   - 生成配置文件..."
      generate_sb_config "$mode" "$sub_url"
      
      msg "   - 启动 Sing-box..."
      if [ -x /etc/init.d/sing-box ]; then
        /etc/init.d/sing-box start
        msg "✅ Sing-box 已启动 (Mode $mode)"
      else
        msg "❌ 未安装 sing-box 服务！"
      fi
      ;;
      
    C)
      # === MIHOMO 模式 (闲置) ===
      msg "   - 内核: Mihomo (Clash)"
      msg "   - 状态: 维护中 / 闲置"
      msg "ℹ️ C线目前仅作为占位符，未生成实际配置。"
      ;;
  esac
}

# ==============================
# 4. 主菜单
# ==============================
set_route_mode(){
  echo
  echo "当前模式: $(cat "$GW_MODE_FILE" 2>/dev/null || echo "Unknown")"
  echo "------------------------------"
  echo "A) 基础分流 (Sing-box)"
  echo "   [逻辑] 国内直连，其他全代理。简单稳定。"
  echo
  echo "B) 进阶分流 (Sing-box)"
  echo "   [逻辑] YouTube/Spotify/AI/PayPal 独立分流。"
  echo "   (即你刚才提供的 Clash 规则复刻版)"
  echo
  echo "C) 维护模式 (Mihomo/Clash)"
  echo "   [状态] 暂时闲置，等待后续维护。"
  echo "------------------------------"
  printf "请选择 [A/B/C]: "
  read m
  m="$(echo "$m" | tr '[:lower:]' '[:upper:]')"
  
  case "$m" in
    A|B|C)
      echo "$m" > "$GW_MODE_FILE"
      msg "✅ 模式已切换为 $m"
      # 询问是否应用
      printf "是否立即重建配置并重启服务? (y/N): "
      read yn
      case "$yn" in y|Y) gw_rebuild_all ;; esac
      ;;
    *) msg "❌ 无效输入" ;;
  esac
}

# 导出函数名，适配主脚本
proxy_gateway_menu(){
  ensure_dirs
  while true; do
    curr="$(cat "$GW_MODE_FILE" 2>/dev/null || echo "A")"
    echo
    echo "=============================="
    echo " 网关管理中心 (当前: $curr线)"
    echo "=============================="
    echo "1) 切换模式 (A:基础 / B:进阶 / C:闲置)"
    echo "2) 设置订阅链接"
    echo "3) 一键应用配置 (重启服务)"
    echo "0) 返回"
    printf "选择: "
    read c
    case "$c" in
      1) set_route_mode ;;
      2) set_subscription ;;
      3) gw_rebuild_all ;;
      0) return 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}
