#!/bin/sh
# V3.2 修复版：移除 set -e 防止意外闪退

msg(){ echo "[xsb-openwrt] $*" >&2; }

# ==============================
# 0. 基础设置与快捷命令
# ==============================
# 自动创建快捷命令 xsb
ensure_xsb_cmd(){
  current_script="$(readlink -f "$0")"
  if [ ! -f "/usr/bin/xsb" ]; then
    cat > /usr/bin/xsb <<EOF
#!/bin/sh
sh "$current_script"
EOF
    chmod +x /usr/bin/xsb
  fi
}

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
# 1. 智能依赖与内核检测
# ==============================
check_and_install_deps(){
  # 1. 检查 python3
  if ! command -v python3 >/dev/null 2>&1; then
    msg "❌ 缺少 python3 (用于生成配置)。"
    printf "是否自动安装? (y/N): "
    read yn
    case "$yn" in y|Y) opkg update && opkg install python3-light python3-json ;; *) return 1 ;; esac
  fi
  
  # 2. 检查 curl
  if ! command -v curl >/dev/null 2>&1; then
    opkg update && opkg install curl
  fi

  # 3. 检查 unzip
  if ! command -v unzip >/dev/null 2>&1; then
    opkg update && opkg install unzip
  fi

  # 4. 检查 Sing-box 内核
  if ! command -v sing-box >/dev/null 2>&1; then
    msg "❌ 未检测到 Sing-box 内核！"
    printf "是否自动安装 (opkg)? (y/N): "
    read yn
    case "$yn" in 
      y|Y) 
        msg "🔄 正在安装 Sing-box..."
        opkg update && opkg install sing-box || true
        if ! command -v sing-box >/dev/null 2>&1; then
           msg "❌ 安装失败，请尝试手动安装。"
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
# 2. 自动安装 Web UI 面板
# ==============================
install_ui_panel(){
  if [ ! -f "$SB_UI_DIR/index.html" ]; then
    msg "🎨 检测到 Web 面板缺失，正在自动下载..."
    dl_url="https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
    tmp_zip="/tmp/ui.zip"
    
    if curl -L -k -o "$tmp_zip" "$dl_url"; then
      msg "📦 下载完成，正在解压..."
      unzip -o -q "$tmp_zip" -d /tmp/ui_extract || true
      cp -rf /tmp/ui_extract/*/* "$SB_UI_DIR/" 2>/dev/null || true
      rm -rf "$tmp_zip" /tmp/ui_extract
      msg "✅ Web 面板安装完成！"
    else
      msg "❌ 面板下载失败，请检查网络。"
    fi
  fi
}

# ==============================
# 3. 防火墙放行 (Web UI)
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
    /etc/init.d/firewall restart >/dev/null 2>&1 || true
    msg "✅ 防火墙规则已添加"
  fi
}

# ==============================
# 4. 设置订阅链接
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
  
  # 使用 -f 选项，如果 HTTP 错误则失败
  if curl -k -sL -f "$full_api" -o "$SB_NODES_FILE"; then
    if grep -q "outbounds" "$SB_NODES_FILE"; then
      msg "✅ 节点更新成功！"
    else
      msg "❌ 转换失败：内容格式无效。"
    fi
  else
    msg "❌ 下载失败，请检查网络或订阅链接是否正确。"
  fi
}

# ==============================
# 5. Python 配置生成器
# ==============================
generate_sb_config(){
  mode="$1"
  ui_path="$SB_UI_DIR"
  
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
# 6. 启动/停止逻辑
# ==============================
gw_start(){
  ensure_dirs
  
  # 1. 检查内核与依赖
  if ! check_and_install_deps; then
     msg "⚠️ 依赖检查未通过，按回车返回..."
     read _ 
     return 1
  fi
  
  # 2. 检查 UI
  install_ui_panel
  allow_firewall_ui
  
  mode="$(cat "$GW_MODE_FILE" 2>/dev/null || echo "A")"
  sub_url="$(cat "$GW_SUB_URL_FILE" 2>/dev/null || echo "")"
  # 去除空格
  mode="$(echo "$mode" | tr -d '[:space:]')" 
  
  echo
  msg "🚀 正在启动网关 (模式: $mode)..."
  
  gw_stop_silent
  
  case "$mode" in
    A|B)
      if [ -z "$sub_url" ]; then
        msg "⚠️ 警告：未设置订阅链接！请先选 2) 设置订阅。"
        printf "按回车键返回菜单..."
        read _
        return 1
      fi
      
      if [ ! -f "$SB_NODES_FILE" ]; then
        msg "📥 节点文件不存在，正在下载..."
        download_and_convert "$sub_url"
      fi
      
      msg "🔨 正在生成配置文件..."
      generate_sb_config "$mode"
      
      msg "⚡ 正在启动 Sing-box 服务..."
      if /etc/init.d/sing-box start; then
         msg "✅ 启动成功！"
         echo
         msg "🌐 Web 面板地址: http://$(get_lan_ip):9090/ui"
         msg "🔑 访问密码: $UI_SECRET"
         echo
         printf "按回车键返回菜单..."
         read _
      else
         msg "❌ 启动失败！请检查日志 (logread -e sing-box)"
         printf "按回车键返回菜单..."
         read _
      fi
      ;;
    C)
      msg "ℹ️ C线 (Mihomo) 目前闲置。"
      printf "按回车键返回..."
      read _
      ;;
  esac
}

gw_stop(){
  msg "🛑 正在停止网关..."
  gw_stop_silent
  msg "✅ 网关已关闭，恢复直连。"
  printf "按回车键返回..."
  read _
}

gw_stop_silent(){
  [ -x /etc/init.d/sing-box ] && /etc/init.d/sing-box stop >/dev/null 2>&1 || true
  [ -x /etc/init.d/mihomo ] && /etc/init.d/mihomo stop >/dev/null 2>&1 || true
}

get_status_icon(){
  if pgrep sing-box >/dev/null; then
    echo "🟢 运行中"
  else
    echo "🔴 已停止"
  fi
}

# ==============================
# 7. 菜单逻辑
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
  ensure_xsb_cmd
  
  while true; do
    clear 
    curr_mode="$(cat "$GW_MODE_FILE" 2>/dev/null || echo "A")"
    status="$(get_status_icon)"
    lan_ip="$(get_lan_ip)"
    
    echo "=============================================="
    echo "       🚀 网关管理中心 V3.2 (修复版)"
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
    echo " 4) 🟢 开启 / 重启网关"
    echo " 5) 🔴 停止网关"
    echo " ------------------------"
    echo " 0) 🔙 退出"
    echo
    printf " 请选择操作: "
    read c
    case "$c" in
      1) set_route_mode ;;
      2) set_subscription ;;
      3) download_and_convert "$(cat "$GW_SUB_URL_FILE" 2>/dev/null)" && gw_start ;;
      4) gw_start ;;
      5) gw_stop ;;
      0) exit 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

# 脚本入口
proxy_gateway_menu
