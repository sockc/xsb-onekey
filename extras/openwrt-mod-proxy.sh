#!/bin/sh
set -eu

msg(){ echo "[xsb-openwrt] $*" >&2; }

# ==============================
# 路径与变量
# ==============================
GW_DIR="/etc/xsb/gateway"
GW_MODE_FILE="$GW_DIR/route_mode"           # 存储模式: A, B, C
GW_SUB_URL_FILE="$GW_DIR/sub_url.conf"      # 存储订阅链接
SB_NODES_FILE="$GW_DIR/sb_nodes.json"       # 存储转换后的节点数据
SB_CFG="/etc/sing-box/config.json"
CONV_API="https://api.v1.mk/sub?target=singbox&url=" # 使用肥羊/通用转换API

ensure_dirs(){
  mkdir -p "$GW_DIR" /etc/sing-box /etc/mihomo >/dev/null 2>&1 || true
  [ -f "$GW_MODE_FILE" ] || echo "A" > "$GW_MODE_FILE"
  [ -f "$GW_SUB_URL_FILE" ] || touch "$GW_SUB_URL_FILE"
}

check_dependencies(){
  if ! command -v python3 >/dev/null 2>&1; then
    msg "❌ 缺少 python3，无法处理节点数据。"
    msg "请运行: opkg update && opkg install python3-light python3-json"
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    msg "❌ 缺少 curl，无法下载订阅。"
    msg "请运行: opkg update && opkg install curl"
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
  echo "脚本已内置转换功能，支持 Clash / V2ray / SSR 等各种链接。"
  echo
  curr="$(cat "$GW_SUB_URL_FILE" 2>/dev/null || echo "")"
  [ -n "$curr" ] && echo "当前链接: ${curr:0:30}..."
  
  printf "请输入订阅链接 (回车取消): "
  read url
  if [ -n "$url" ]; then
    echo "$url" > "$GW_SUB_URL_FILE"
    msg "✅ 链接已保存"
    # 立即尝试下载转换
    download_and_convert "$url"
  fi
}

# 下载并转换订阅为 Sing-box 格式
download_and_convert(){
  url="$1"
  msg "🔄 正在下载并转换节点 (需联网)..."
  
  # 对 URL 进行简单的 URL Encode (防止 & 符号截断)
  safe_url="$(echo "$url" | sed 's/:/%3A/g; s/\//%2F/g; s/?/%3F/g; s/&/%26/g; s/=/%3D/g')"
  
  # 调用 API 转换
  full_api="${CONV_API}${safe_url}"
  
  if curl -k -sL "$full_api" -o "$SB_NODES_FILE"; then
    # 简单校验是否为 JSON
    if grep -q "outbounds" "$SB_NODES_FILE"; then
      msg "✅ 节点获取成功！"
    else
      msg "❌ 转换失败：返回内容不是有效的 Sing-box 配置。"
      cat "$SB_NODES_FILE" | head -n 5
    fi
  else
    msg "❌ 下载失败，请检查网络。"
  fi
}

# ==============================
# 2. Python 配置生成器 (集成节点注入)
# ==============================
generate_sb_config(){
  mode="$1"
  
  cat <<EOF > /tmp/gen_sb.py
import json
import sys
import os

mode = "$mode"
nodes_file = "$SB_NODES_FILE"

# --- 1. 读取下载好的节点文件 ---
node_outbounds = []
node_tags = []

if os.path.exists(nodes_file):
    try:
        with open(nodes_file, 'r', encoding='utf-8') as f:
            data = json.load(f)
            # 提取里面的 outbounds，排除 direct/block 等内置类型
            for out in data.get('outbounds', []):
                if out.get('type') not in ['selector', 'urltest', 'direct', 'block', 'dns']:
                    node_outbounds.append(out)
                    node_tags.append(out['tag'])
    except Exception as e:
        sys.stderr.write(f"Error loading nodes: {e}\n")

# 如果没有节点，加一个假的防止报错
if not node_tags:
    node_tags = ["DIRECT"]

# --- 2. 基础结构 ---
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
    # 开启 Clash API 以便使用 Web 面板选节点
    "experimental": {
        "clash_api": {
            "external_controller": "0.0.0.0:9090",
            "external_ui": "ui",
            "secret": "123456"  # 面板密码
        }
    },
    "outbounds": [],
    "route": {"rules": []}
}

# --- 3. 组装出站 (Outbounds) ---

# [自动优选]
auto_group = {
    "type": "urltest", 
    "tag": "⚡ 自动优选", 
    "outbounds": node_tags, 
    "url": "http://www.gstatic.com/generate_204", 
    "interval": "10m"
}

# [节点选择] - 这里是关键，把所有下载的节点加进去
proxy_select_group = {
    "type": "selector", 
    "tag": "🚀 节点选择", 
    "outbounds": ["⚡ 自动优选"] + node_tags + ["DIRECT"], 
    "interrupt_exist_connections": True
}

# 基础 Outbounds
final_outbounds = [
    proxy_select_group,
    auto_group,
    {"type": "direct", "tag": "DIRECT"},
    {"type": "block", "tag": "BLOCK"},
    {"type": "dns", "tag": "dns-out"}
] + node_outbounds  # 把下载的实际节点追加到最后

# Mode B 的策略组
if mode == "B":
    groups = ["📹 YouTube", "🎵 Spotify", "💳 PayPal", "🤖 AI & Copilot", "📺 其他流媒体", "💰 虚拟货币", "📲 电报消息", "🐟 漏网之鱼"]
    for g in groups:
        # 每个策略组都可以选：手动选好的节点、自动优选、或直连
        final_outbounds.insert(2, {
            "type": "selector", 
            "tag": g, 
            "outbounds": ["🚀 节点选择", "⚡ 自动优选", "DIRECT"]
        })

config["outbounds"] = final_outbounds

# --- 4. 分流规则 (Route) ---
rules = [
    {"protocol": "dns", "outbound": "dns-out"},
    {"port": [22, 53, 9090, 7890, 7893], "outbound": "DIRECT"},
    {"clash_mode": "Direct", "outbound": "DIRECT"},
    {"clash_mode": "Global", "outbound": "🚀 节点选择"}
]

if mode == "A":
    rules.append({"geosite": ["cn"], "geoip": ["cn", "private"], "outbound": "DIRECT"})
    rules.append({"outbound": "🚀 节点选择"})

elif mode == "B":
    rules.append({"geosite": ["youtube"], "outbound": "📹 YouTube"})
    rules.append({"geosite": ["spotify"], "outbound": "🎵 Spotify"})
    rules.append({"geosite": ["paypal"], "outbound": "💳 PayPal"})
    rules.append({"geosite": ["openai", "anthropic", "google-gemini", "github"], "outbound": "🤖 AI & Copilot"})
    rules.append({"geosite": ["netflix", "disney", "category-porn"], "outbound": "📺 其他流媒体"})
    rules.append({"geosite": ["category-cryptocurrency", "binance", "okx"], "outbound": "💰 虚拟货币"})
    rules.append({"geosite": ["telegram"], "outbound": "📲 电报消息"})
    rules.append({"geoip": ["telegram"], "outbound": "📲 电报消息"})
    rules.append({"geosite": ["google", "microsoft"], "outbound": "🚀 节点选择"})
    rules.append({"geosite": ["cn"], "geoip": ["cn", "private"], "outbound": "DIRECT"})
    rules.append({"outbound": "🐟 漏网之鱼"})

config["route"]["rules"] = rules

print(json.dumps(config, indent=2, ensure_ascii=False))
EOF

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
  
  [ -x /etc/init.d/sing-box ] && /etc/init.d/sing-box stop >/dev/null 2>&1
  [ -x /etc/init.d/mihomo ] && /etc/init.d/mihomo stop >/dev/null 2>&1
  
  case "$mode" in
    A|B)
      msg "   - 内核: Sing-box"
      if [ -z "$sub_url" ]; then
        msg "⚠️ 警告：未设置订阅链接！"
      elif [ ! -f "$SB_NODES_FILE" ]; then
        msg "⚠️ 节点文件不存在，尝试下载..."
        download_and_convert "$sub_url"
      fi
      
      msg "   - 生成配置文件..."
      generate_sb_config "$mode"
      
      msg "   - 启动 Sing-box..."
      if [ -x /etc/init.d/sing-box ]; then
        /etc/init.d/sing-box start
        msg "✅ Sing-box 已启动"
        echo
        echo "========================================"
        echo "🎉 节点选择请访问 Web 面板："
        echo "   http://<路由器IP>:9090/ui"
        echo "   密码: 123456"
        echo "========================================"
      else
        msg "❌ 未安装 sing-box 服务！"
      fi
      ;;
      
    C)
      msg "   - C线闲置中..."
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
  echo "   [逻辑] 国内直连，其他走代理。"
  echo "B) 进阶分流 (Sing-box)"
  echo "   [逻辑] YouTube/AI/PayPal 等独立分流。"
  echo "C) 维护模式 (Mihomo)"
  echo "------------------------------"
  printf "请选择 [A/B/C]: "
  read m
  m="$(echo "$m" | tr '[:lower:]' '[:upper:]')"
  case "$m" in
    A|B|C)
      echo "$m" > "$GW_MODE_FILE"
      msg "✅ 模式已切换为 $m"
      printf "是否立即应用? (y/N): "
      read yn
      case "$yn" in y|Y) gw_rebuild_all ;; esac
      ;;
    *) msg "❌ 无效输入" ;;
  esac
}

proxy_gateway_menu(){
  ensure_dirs
  while true; do
    curr="$(cat "$GW_MODE_FILE" 2>/dev/null || echo "A")"
    echo
    echo "=============================="
    echo " 网关管理中心 (当前: $curr线)"
    echo "=============================="
    echo "1) 切换模式 (A/B/C)"
    echo "2) 设置订阅链接 (自动转换)"
    echo "3) 更新节点/应用配置"
    echo "0) 返回"
    printf "选择: "
    read c
    case "$c" in
      1) set_route_mode ;;
      2) set_subscription ;;
      3) download_and_convert "$(cat "$GW_SUB_URL_FILE" 2>/dev/null)" && gw_rebuild_all ;;
      0) return 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}
