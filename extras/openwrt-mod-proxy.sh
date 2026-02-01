#!/bin/sh
# V3.4 网络修复版：多API备选 + 手动导入模式

msg(){ echo "[xsb-openwrt] $*" >&2; }

# ==============================
# 0. 基础设置与快捷命令
# ==============================
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
GW_MODE_FILE="$GW_DIR/route_mode"           
GW_SUB_URL_FILE="$GW_DIR/sub_url.conf"      
SB_NODES_FILE="$GW_DIR/sb_nodes.json"       
SB_CFG="/etc/sing-box/config.json"
SB_UI_DIR="/etc/sing-box/ui"

# --- 多重备选 API 列表 ---
# 格式: 只写 API 的前半部分
API_1="https://api.v1.mk/sub?target=singbox&url="      # 肥羊 (默认)
API_2="https://sub.xeton.dev/sub?target=singbox&url="  # 备用1
API_3="https://api.dler.io/sub?target=singbox&url="    # 备用2

UI_SECRET="123456"

ensure_dirs(){
  mkdir -p "$GW_DIR" /etc/sing-box "$SB_UI_DIR" >/dev/null 2>&1 || true
  [ -f "$GW_MODE_FILE" ] || echo "A" > "$GW_MODE_FILE"
  [ -f "$GW_SUB_URL_FILE" ] || touch "$GW_SUB_URL_FILE"
}

get_lan_ip(){
  ip="$(uci get network.lan.ipaddr 2>/dev/null || ip addr show br-lan | grep -Po 'inet \K[\d.]+' | head -1)"
  echo "${ip:-<路由器IP>}"
}

# ==============================
# 1. 核心修复：自动生成服务脚本
# ==============================
ensure_init_script(){
  if [ ! -f "/etc/init.d/sing-box" ]; then
    msg "⚙️ 检测到服务脚本缺失，正在自动修复..."
    bin_path="/usr/bin/sing-box"
    [ ! -x "$bin_path" ] && bin_path="$(command -v sing-box)"
    
    if [ -z "$bin_path" ]; then
      msg "❌ 严重错误：找不到 sing-box 二进制文件！"
      return 1
    fi

    cat > /etc/init.d/sing-box <<EOF
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10
PROG="$bin_path"
CONF="/etc/sing-box/config.json"

start_service() {
	procd_open_instance
	procd_set_param command "\$PROG" run -c "\$CONF"
	procd_set_param user root
	procd_set_param limits core="unlimited"
	procd_set_param respawn
	procd_close_instance
}
EOF
    chmod +x /etc/init.d/sing-box
    msg "✅ 服务脚本已重建"
  fi
}

# ==============================
# 2. 智能依赖检测
# ==============================
check_and_install_deps(){
  if ! command -v python3 >/dev/null 2>&1; then
    msg "❌ 缺少 python3。"
    printf "是否安装? (y/N): "
    read yn
    case "$yn" in y|Y) opkg update && opkg install python3-light python3-json ;; *) return 1 ;; esac
  fi
  
  if ! command -v curl >/dev/null 2>&1; then opkg update && opkg install curl; fi
  if ! command -v unzip >/dev/null 2>&1; then opkg update && opkg install unzip; fi

  if ! command -v sing-box >/dev/null 2>&1; then
    msg "❌ 未检测到 Sing-box 内核！"
    printf "是否自动安装? (y/N): "
    read yn
    case "$yn" in 
      y|Y) 
        msg "🔄 正在安装 Sing-box..."
        opkg update && opkg install sing-box || true
        if ! command -v sing-box >/dev/null 2>&1; then
           msg "❌ 安装失败，请手动安装。"
           return 1
        fi
        msg "✅ 安装成功！"
        ;;
      *) return 1 ;; 
    esac
  fi
  ensure_init_script
  return 0
}

# ==============================
# 3. 安装 Web UI
# ==============================
install_ui_panel(){
  if [ ! -f "$SB_UI_DIR/index.html" ]; then
    msg "🎨 检测到面板缺失，正在下载..."
    dl_url="https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
    tmp_zip="/tmp/ui.zip"
    if curl -L -k -o "$tmp_zip" "$dl_url"; then
      unzip -o -q "$tmp_zip" -d /tmp/ui_extract || true
      cp -rf /tmp/ui_extract/*/* "$SB_UI_DIR/" 2>/dev/null || true
      rm -rf "$tmp_zip" /tmp/ui_extract
      msg "✅ 面板安装完成！"
    else
      msg "❌ 面板下载失败 (网络问题)，Web 功能受限。"
    fi
  fi
}

allow_firewall_ui(){
  if ! uci show firewall 2>/dev/null | grep -q "Allow-SingBox-UI"; then
    msg "🛡️ 放行防火墙 9090 端口..."
    uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name='Allow-SingBox-UI'
    uci set firewall.@rule[-1].src='lan'
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].dest_port='9090'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci commit firewall
    /etc/init.d/firewall restart >/dev/null 2>&1 || true
  fi
}

# ==============================
# 4. 下载与转换 (增强版)
# ==============================
set_subscription(){
  echo
  echo ">>> 设置订阅链接 <<<"
  curr="$(cat "$GW_SUB_URL_FILE" 2>/dev/null || echo "")"
  [ -n "$curr" ] && echo "当前: ${curr:0:30}..."
  printf "输入订阅链接 (回车取消): "
  read url
  if [ -n "$url" ]; then
    echo "$url" > "$GW_SUB_URL_FILE"
    msg "✅ 已保存"
    download_and_convert "$url"
  fi
}

manual_import_nodes(){
  echo
  echo "=============================================="
  echo "   📝 手动粘贴节点数据"
  echo "=============================================="
  echo "由于网络问题无法下载，请手动粘贴 Sing-box 格式的 JSON 内容。"
  echo "获取方法：在电脑浏览器打开 'https://api.v1.mk/sub?target=singbox&url=你的订阅链接'"
  echo "然后全选复制，粘贴到这里。"
  echo "----------------------------------------------"
  echo "粘贴后，请按回车，然后按 Ctrl+D 保存。"
  echo "----------------------------------------------"
  
  # 使用 cat > 录入
  cat > "$SB_NODES_FILE"
  
  if grep -q "outbounds" "$SB_NODES_FILE"; then
    msg "✅ 手动导入成功！"
    return 0
  else
    msg "❌ 内容格式错误，必须包含 'outbounds' 字段。"
    return 1
  fi
}

download_and_convert(){
  url="$1"
  msg "🔄 正在下载并转换节点 (尝试多条线路)..."
  safe_url="$(echo "$url" | sed 's/:/%3A/g; s/\//%2F/g; s/?/%3F/g; s/&/%26/g; s/=/%3D/g')"
  
  # 循环尝试 API
  success=0
  for api in "$API_1" "$API_2" "$API_3"; do
    msg "   👉 尝试 API: ${api%%/sub*}..." 
    if curl -k -sL -f --connect-timeout 10 "${api}${safe_url}" -o "$SB_NODES_FILE"; then
      # 简单校验
      if grep -q "outbounds" "$SB_NODES_FILE"; then
         msg "✅ 节点下载成功！"
         success=1
         break
      else
         msg "   ⚠️ 下载内容无效，尝试下一个..."
      fi
    else
      msg "   ⚠️ 连接超时或失败，尝试下一个..."
    fi
  done

  if [ $success -eq 0 ]; then
    msg "❌ 所有转换 API 均连接失败！"
    msg "可能原因：路由器 DNS 问题、网络不通、或 API 被墙。"
    echo
    printf "是否尝试【手动粘贴】节点内容? (y/N): "
    read yn
    case "$yn" in 
      y|Y) manual_import_nodes ;;
      *) msg "❌ 操作已取消。";;
    esac
  fi
}

# ==============================
# 5. 配置生成 (Python)
# ==============================
generate_sb_config(){
  mode="$1"
  ui_path="$SB_UI_DIR"
  cat <<EOF > /tmp/gen_sb.py
import json, sys, os

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
    except: pass

if not node_tags: node_tags = ["DIRECT"]

config = {
    "log": {"level": "info"},
    "dns": {
        "servers": [
            {"tag": "google", "address": "https://8.8.8.8/dns-query", "detour": "🚀 节点选择"},
            {"tag": "local", "address": "223.5.5.5", "detour": "DIRECT"},
            {"tag": "block", "address": "rcode://success"}
        ],
        "rules": [{"outbound": "any", "server": "local"}],
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

auto = {"type": "urltest", "tag": "⚡ 自动优选", "outbounds": node_tags, "url": "http://www.gstatic.com/generate_204", "interval": "10m"}
select = {"type": "selector", "tag": "🚀 节点选择", "outbounds": ["⚡ 自动优选"] + node_tags + ["DIRECT"], "interrupt_exist_connections": True}

final = [select, auto, {"type": "direct", "tag": "DIRECT"}, {"type": "block", "tag": "BLOCK"}, {"type": "dns", "tag": "dns-out"}] + node_outbounds

if mode == "B":
    groups = ["📹 YouTube", "🎵 Spotify", "💳 PayPal", "🤖 AI & Copilot", "📺 其他流媒体", "💰 虚拟货币", "📲 电报消息", "🐟 漏网之鱼"]
    for g in groups:
        final.insert(2, {"type": "selector", "tag": g, "outbounds": ["🚀 节点选择", "⚡ 自动优选", "DIRECT"]})

config["outbounds"] = final

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
# 6. 启动/停止
# ==============================
gw_start(){
  ensure_dirs
  if ! check_and_install_deps; then
     msg "⚠️ 依赖错误，按回车返回..."
     read _ 
     return 1
  fi
  install_ui_panel
  allow_firewall_ui
  ensure_init_script
  
  mode="$(cat "$GW_MODE_FILE" 2>/dev/null || echo "A")"
  sub_url="$(cat "$GW_SUB_URL_FILE" 2>/dev/null || echo "")"
  mode="$(echo "$mode" | tr -d '[:space:]')" 
  
  echo
  msg "🚀 正在启动 (模式: $mode)..."
  gw_stop_silent
  
  case "$mode" in
    A|B)
      if [ -z "$sub_url" ]; then
        msg "⚠️ 未设置订阅！请选 2) 设置订阅。"
        printf "按回车返回..."
        read _
        return 1
      fi
      if [ ! -f "$SB_NODES_FILE" ]; then
        msg "📥 下载节点..."
        download_and_convert "$sub_url"
      fi
      msg "🔨 生成配置..."
      generate_sb_config "$mode"
      
      msg "⚡ 启动服务..."
      if /etc/init.d/sing-box restart; then
         msg "✅ 启动成功！"
         echo
         msg "🌐 面板: http://$(get_lan_ip):9090/ui"
         msg "🔑 密码: $UI_SECRET"
         echo
         printf "按回车返回..."
         read _
      else
         msg "❌ 启动失败！日志:"
         logread | grep sing-box | tail -n 3
         printf "按回车返回..."
         read _
      fi
      ;;
    C)
      msg "ℹ️ C线闲置。"
      printf "按回车返回..."
      read _
      ;;
  esac
}

gw_stop(){
  msg "🛑 停止网关..."
  gw_stop_silent
  msg "✅ 已恢复直连。"
  printf "按回车返回..."
  read _
}

gw_stop_silent(){
  [ -f /etc/init.d/sing-box ] && /etc/init.d/sing-box stop >/dev/null 2>&1 || true
}

get_status_icon(){
  if pgrep sing-box >/dev/null; then echo "🟢 运行中"; else echo "🔴 已停止"; fi
}

# ==============================
# 7. 主菜单
# ==============================
set_route_mode(){
  echo
  echo "当前: $(cat "$GW_MODE_FILE" 2>/dev/null || echo "Unknown")"
  echo "------------------------------"
  echo "A) 基础分流 (Sing-box)"
  echo "B) 进阶分流 (Sing-box)"
  echo "C) 维护模式 (Mihomo)"
  printf "请选择: "
  read m
  m="$(echo "$m" | tr '[:lower:]' '[:upper:]')"
  case "$m" in
    A|B|C) echo "$m" > "$GW_MODE_FILE"; msg "✅ 已切换为 $m";;
    *) msg "❌ 无效";;
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
    echo "       🚀 网关管理 V3.4 (多线路API版)"
    echo "=============================================="
    echo " 📊 状态: $status      🛤️ 模式: $curr_mode 线"
    [ "$status" = "🟢 运行中" ] && echo " 🌍 http://$lan_ip:9090/ui"
    echo "=============================================="
    echo " 1) 🔄 切换模式"
    echo " 2) 🔗 设置订阅 (自动/手动)"
    echo " 3) ♻️ 更新节点"
    echo " ------------------------"
    echo " 4) 🟢 启动/重启"
    echo " 5) 🔴 停止"
    echo " ------------------------"
    echo " 0) 🔙 退出"
    echo
    printf " 请选择: "
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

proxy_gateway_menu
