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
SB_UI_DIR="/etc/sing-box/ui"
CONV_API="https://api.v1.mk/sub?target=singbox&url=" 

# 面板默认密码
UI_SECRET="123456"

ensure_dirs(){
  mkdir -p "$GW_DIR" /etc/sing-box "$SB_UI_DIR" >/dev/null 2>&1 || true
  [ -f "$GW_MODE_FILE" ] || echo "A" > "$GW_MODE_FILE"
  [ -f "$GW_SUB_URL_FILE" ] || touch "$GW_SUB_URL_FILE"
}

# 获取本机局域网 IP
get_lan_ip(){
  ip="$(uci get network.lan.ipaddr 2>/dev/null || ip addr show br-lan | grep -Po 'inet \K[\d.]+' | head -1)"
  echo "${ip:-<路由器IP>}"
}

# ==============================
# 0. 智能依赖与内核检测
# ==============================
check_and_install_deps(){
  # 1. 检查基础工具
  if ! command -v python3 >/dev/null 2>&1; then
    msg "❌ 缺少 python3 (用于生成配置)。"
    printf "是否自动安装? (y/N): "
    read yn
    case "$yn" in y|Y) opkg update && opkg install python3-light python3-json ;; *) return 1 ;; esac
  fi
  
  if ! command -v curl >/dev/null 2>&1; then
    msg "❌ 缺少 curl (用于下载)。"
    opkg update && opkg install curl
  fi

  if ! command -v unzip >/dev/null 2>&1; then
    # 下载UI需要解压
    opkg update && opkg install unzip
  fi

  # 2. 检查 Sing-box 内核
  if ! command -v sing-box >/dev/null 2>&1; then
    msg "❌ 未检测到 Sing-box 内核！"
    printf "是否自动安装 (opkg)? (y/N): "
    read yn
    case "$yn" in 
      y|Y) 
        msg "🔄 正在安装 Sing-box..."
        opkg update && opkg install sing-box
        if ! command -v sing-box >/dev/null 2>&1; then
           msg "❌ 安装失败，请尝试手动安装或更换软件源。"
           return 1
        fi
        msg "✅ Sing-box 安装成功！"
        ;;
      *) 
        msg "已取消，无法启动。"
        return 1 
        ;; 
    esac
  fi
  return 0
}

# ==============================
# 1. 自动安装 Web UI 面板
# ==============================
install_ui_panel(){
  # 如果 index.html 不存在，说明没装好
  if [ ! -f "$SB_UI_DIR/index.html" ]; then
    msg "🎨 检测到 Web 面板缺失，正在自动下载..."
    
    dl_url="https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
    tmp_zip="/tmp/ui.zip"
    
    # 尝试下载
    if curl -L -k -o "$tmp_zip" "$dl_url"; then
      msg "📦 下载完成，正在解压..."
      unzip -o -q "$tmp_zip" -d /tmp/ui_extract
      cp -rf /tmp/ui_extract/*/* "$SB_UI_DIR/"
      rm -rf "$tmp_zip" /tmp/ui_extract
      msg "✅ Web 面板安装完成！"
    else
      msg "❌ 面板下载失败，请检查网络 (Github 连接问题)。"
      msg "   暂不影响代理功能，但无法使用 Web 选节点。"
    fi
  fi
}

# ==============================
# 2. 防火墙放行 (Web UI)
# ==============================
allow_firewall_ui(){
  if ! uci show firewall 2>/dev/null | grep -q "Allow-SingBox-UI"; then
    msg "🛡️ 正在放行防火墙 9090 端口..."
    uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name='Allow-SingBox-UI'
    uci set firewall.@rule[-1].src='lan'
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].dest_port='9090'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci commit firewall
    /etc/init.d/firewall restart >/dev/null 2>&1
  fi
}

# ==============================
# 3. 设置订阅链接
# ==============================
set_subscription(){
  echo
  echo ">>> 设置订阅链接 <<<"
  echo "脚本内置转换，支持 Clash / V2ray 等格式。"
  echo
  curr="$(cat "$GW_SUB_URL_FILE" 2>/dev/null || echo "")"
  [ -n "$curr" ] && echo "当前链接: ${curr:0:30}..."
  
  printf "请输入订阅链接 (回车取消): "
  read url
  if [ -n "$url" ]; then
    echo "$url" > "$GW_SUB_URL_FILE"
    msg "✅ 链接已保存"
    download_and_convert "$url"
  fi
}

download_and_convert(){
  url="$1"
  msg "🔄 正在下载并转换节点..."
  safe_url="$(echo "$url" | sed 's/:/%3A/g; s/\//%2F/g; s/?/%3F/g; s/&/%26/g; s/=/%3D/g')"
  full_api="${CONV_API}${safe_url}"
  
  if curl -k -sL "$full_api" -o "$SB_NODES_FILE"; then
    if grep -q "outbounds" "$SB_NODES_FILE"; then
      msg "✅ 节点更新成功！"
    else
      msg "❌ 转换失败，内容无效。"
    fi
  else
    msg "❌ 下载失败，请检查网络。"
  fi
}

# ==============================
# 4. Python 配置生成器
# ==============================
generate_sb_config(){
  mode="$1"
  ui_path="$SB_UI_DIR" # 使用绝对路径
  
  cat <<EOF > /tmp/gen_sb.py
import json
import sys
import os

mode = "$mode"
nodes_file = "$SB_NODES_FILE"

node_outbounds = []
node_tags = []

if os.path.exists(nodes_file):
    try:
        with open(nodes_file, 'r', encoding='utf-8') as f:
            data = json.load(f)
            for out in data.get('outbounds', []):
                if out.get('type') not in ['selector', 'urltest', 'direct', 'block', 'dns']:
                    node_outbounds.append(out)
                    node_tags.append(out['tag'])
    except:
        pass

if not node_tags:
    node_tags = ["DIRECT"]

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
    "experimental": {
        "clash_api": {
            "external_controller": "0.0.0.0:9090",
            "external_ui": "$ui_path", 
            "secret": "$UI_SECRET"
        }
    },
    "outbounds": [],
    "route": {"rules": []}
}

auto_group = {"type": "urltest", "tag": "⚡ 自动优选", "outbounds": node_tags, "url": "http://www.gstatic.com/generate_204", "interval": "10m"}
proxy_select_group = {"type": "selector", "tag": "🚀 节点选择", "outbounds": ["⚡ 自动优选"] + node_tags + ["DIRECT"], "interrupt_exist_connections": True}

final_outbounds = [proxy_select_group, auto_group, {"type": "direct", "tag": "DIRECT"}, {"type": "block", "tag": "BLOCK"}, {"type": "dns", "tag": "dns-out"}] + node_outbounds

if mode == "B":
    groups = ["📹 YouTube", "🎵 Spotify", "💳 PayPal", "🤖 AI & Copilot", "📺 其他流媒体", "💰 虚拟货币", "📲 电报消息", "🐟 漏网之鱼"]
    for g in groups:
        final_outbounds.insert(2, {"type": "selector", "tag": g, "outbounds": ["🚀 节点选择", "⚡ 自动优选", "DIRECT"]})

config["outbounds"] = final_outbounds

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
# 5. 启动/停止逻辑
# ==============================
gw_start(){
  ensure_dirs
  
  # 1. 检查内核与依赖
  check_and_install_deps || return 1
  
  # 2. 检查 UI
  install_ui_panel
  allow_firewall_ui
  
  mode="$(cat "$GW_MODE_FILE" 2>/dev/null || echo "A")"
  sub_url="$(cat "$GW_SUB_URL_FILE" 2>/dev/null || echo "")"
  
  echo
  msg "🚀 正在启动网关 (模式: $mode)..."
  
  # 停止旧服务
  gw_stop_silent
  
  case "$mode" in
    A|B)
      if [ -z "$sub_url" ]; then
        msg "⚠️ 警告：未设置订阅链接！请先设置订阅。"
        return 1
      elif [ ! -f "$SB_NODES_FILE" ]; then
        msg "⚠️ 节点文件不存在，正在下载..."
        download_and_convert "$sub_url"
      fi
      
      msg "   - 生成配置文件..."
      generate_sb_config "$mode"
      
      msg "   - 启动 Sing-box 服务..."
      if /etc/init.d/sing-box start; then
         msg "✅ 启动成功！"
         echo
         msg "🌐 Web 面板地址: http://$(get_lan_ip):9090/ui"
         msg "🔑 访问密码: $UI_SECRET"
         echo
      else
         msg "❌ 启动失败，请检查日志 (logread -e sing-box)"
      fi
      ;;
    C)
      msg "ℹ️ C线目前闲置，无动作。"
      ;;
  esac
}

gw_stop(){
  msg "🛑 正在停止网关..."
  gw_stop_silent
  msg "✅ 网关已关闭，恢复直连。"
}

gw_stop_silent(){
  [ -x /etc/init.d/sing-box ] && /etc/init.d/sing-box stop >/dev/null 2>&1
  [ -x /etc/init.d/mihomo ] && /etc/init.d/mihomo stop >/dev/null 2>&1
}

get_status_icon(){
  if pgrep sing-box >/dev/null; then
    echo "🟢 运行中"
  else
    echo "🔴 已停止"
  fi
}

# ==============================
# 6. 菜单逻辑
# ==============================
set_route_mode(){
  echo
  echo "当前模式: $(cat "$GW_MODE_FILE" 2>/dev/null || echo "Unknown")"
  echo "------------------------------"
  echo "A) 基础分流 (Sing-box) - 稳定"
  echo "B) 进阶分流 (Sing-box) - 推荐"
  echo "C) 维护模式 (Mihomo)   - 闲置"
  printf "请选择 [A/B/C]: "
  read m
  m="$(echo "$m" | tr '[:lower:]' '[:upper:]')"
  case "$m" in
    A|B|C)
      echo "$m" > "$GW_MODE_FILE"
      msg "✅ 模式已切换为 $m (需重启生效)"
      ;;
    *) msg "❌ 无效输入" ;;
  esac
}

proxy_gateway_menu(){
  ensure_dirs
  while true; do
    curr_mode="$(cat "$GW_MODE_FILE" 2>/dev/null || echo "A")"
    status="$(get_status_icon)"
    lan_ip="$(get_lan_ip)"
    
    echo
    echo "=============================================="
    echo "       🚀 网关管理中心 V3.0 (增强版)"
    echo "=============================================="
    echo " 📊 状态: $status      🛤️ 模式: $curr_mode 线"
    if [ "$status" = "🟢 运行中" ]; then
      echo " 🌍 面板: http://$lan_ip:9090/ui"
      echo " 🔑 密码: $UI_SECRET"
    fi
    echo "=============================================="
    echo " 1) 🔄 切换模式 (A/B/C)"
    echo " 2) 🔗 设置订阅 (自动转换)"
    echo " 3) ♻️ 更新节点 (重新下载)"
    echo " ------------------------"
    echo " 4) 🟢 开启 / 重启网关 (一键启动)"
    echo " 5) 🔴 停止网关 (恢复直连)"
    echo " ------------------------"
    echo " 0) 🔙 返回上一级"
    echo
    printf " 请选择操作: "
    read c
    case "$c" in
      1) set_route_mode ;;
      2) set_subscription ;;
      3) download_and_convert "$(cat "$GW_SUB_URL_FILE" 2>/dev/null)" && gw_start ;;
      4) gw_start ;;
      5) gw_stop ;;
      0) return 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}
