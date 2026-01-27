XSB OneKey（Xray + sing-box 一键部署 / 多协议自由组合）

一个面向 VPS 多国家节点 场景的轻量一键脚本：
✅ 你可以自由选择并组合协议（Reality / VMess / TUIC / HY2 等），并生成可用的客户端配置/链接。
✅ 同时兼顾 标准 Linux 与 OpenWrt Tiny 最小化模式（省空间、省依赖）。

✨ 特性
✅ 自由选择协议组合（不是固定套餐）

VLESS + Reality（Xray）

自动生成 Keypair（含 PublicKey / pbk）

支持自定义 SNI / shortId / flow

VMess + WS (noTLS)（Xray）

path 支持自定义或随机

Host 支持伪装域名（可空）

VMess + TCP + HTTP（Xray）

适合部分线路/免流/特殊环境（按需启用）

TUIC（sing-box）

自动生成自签证书（可用 allow_insecure/insecure）

自动生成分享链接

Hysteria2 / HY2（sing-box）

自动生成自签证书

自动生成分享链接

你可以只装 Xray / 只装 sing-box / 两者都装，按需启用，不强行全家桶。

⚡ 快速开始（推荐）
方式 1：强制覆盖安装 + 直接进入菜单
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sockc/xsb-onekey/main/install.sh) --force && xsb
```
方式 2：普通安装
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sockc/xsb-onekey/main/install.sh)
```
OpenWrt（Tiny 自动识别）

同一条命令即可：
```bash
sh -c "$(wget -qO- https://raw.githubusercontent.com/sockc/xsb-onekey/main/install.sh)" -- --menu
```
拉取最新
```bash
sh -c "$(wget -O- https://raw.githubusercontent.com/sockc/xsb-onekey/main/install.sh)" -- --menu

```

Alpine（Lite 自动识别）
```bash
wget -qO- https://raw.githubusercontent.com/sockc/xsb-onekey/main/install.sh | bash -s -- --force --menu
```
安装完成后运行：
```bash
xsb
```
🧩 脚本做了什么？

自动安装并管理：

xray-core（提供 Reality / VMess 等）

sing-box（提供 TUIC / HY2 等）

配置落地到系统标准目录

Xray：/etc/xray/config.json

sing-box：/etc/sing-box/config.json

XSB 管理目录：/etc/xsb/

自动生成：

Reality pbk（PublicKey）

path、UUID、密码等必要参数

分享链接（Reality / HY2 / TUIC）

🖥️ 支持系统 & 架构
Linux（推荐）

Ubuntu / Debian / CentOS / Rocky / Alma / Fedora 等（常见发行版均可）

OpenWrt（Tiny 最小化模式）

适合存储小、内存小的路由设备

尽可能少依赖，按需安装

架构

amd64 / x86_64

arm64 / aarch64

其他架构按系统源与二进制可用性为准（OpenWrt 会走 Tiny 模式）

📌 使用说明（菜单功能）

安装后运行：
```bash
xsb
```

你会看到类似的菜单入口（不同版本略有差异）：

1) 安装/重置组件

安装 xray

安装 sing-box

两者都装

2) 添加入站（自由组合）

VLESS + Reality

VMess + WS (noTLS)

VMess + TCP + HTTP

TUIC

Hysteria2 (HY2)

添加成功会输出分享链接或关键参数（Reality 会输出 pbk）

3) 服务管理

重启服务

查看状态

监听检查（如果系统支持 ss/netstat）

4) 删除入站（按备注名）

删除 sing-box 入站

删除 xray 入站

🔥 OpenWrt Tiny 模式说明

如果脚本检测到你在 OpenWrt，会自动进入 Tiny 模式，主打：
✅ 最小化安装 ✅ 少依赖 ✅ 小存储也能跑

Tiny 模式下：

可选安装 sing-box-tiny / xray-core

自动生成 /etc/init.d/xray、/etc/init.d/sing-box（若缺失）

生成配置到标准路径

支持 Reality / TUIC / HY2 的快速添加

注意：HY2 / TUIC 走 UDP，如果外网不通，优先检查 上游云防火墙/安全组是否放行 UDP 端口。

🔗 分享链接说明
Reality（VLESS）

脚本会输出类似：
```bash
vless://UUID@IP:PORT?encryption=none&security=reality&sni=xxx&fp=chrome&pbk=PUBLICKEY&sid=SHORTID&type=tcp&flow=xtls-rprx-vision#remark
```

如果出现内网 IP（如 192.168.x.x），说明机器在 NAT 后面，需要：

改成公网 IP/域名

或在上级路由/光猫做端口转发

HY2（Hysteria2）

脚本会输出类似：
```bash
hysteria2://PASSWORD@IP:PORT/?insecure=1&sni=xsb-openwrt#remark
```

✅ 自签证书必须 insecure=1
✅ HY2 属于 UDP 协议，记得放行 UDP 端口

TUIC

脚本会输出类似：
```bash
tuic://UUID:PASSWORD@IP:PORT?congestion_control=bbr&alpn=h3&sni=xsb-openwrt&allow_insecure=1#remark
```

同样属于 UDP，且自签证书需允许不安全证书。

🧱 防火墙与端口说明

不同系统防火墙不同，常见情况：

OpenWrt：使用 UCI firewall，需要放行 UDP/TCP 端口

VPS 云平台：可能还有 安全组/云防火墙，一定要同步放行

常见排障思路（HY2/TUIC 不通）

服务是否运行？

端口是否监听？

OpenWrt firewall 是否放行？

云平台安全组是否放行 UDP？

是否 NAT/内网导致外网访问不到？

🧯 常见问题（FAQ）
Q1：Reality 通，HY2 不通？

HY2 是 UDP，Reality 是 TCP。大概率是：

云防火墙/安全组没放行 UDP

OpenWrt 防火墙没放行 UDP

NAT 环境没做 UDP 转发

Q2：安装后提示找不到 xsb？

重新打开终端，或执行：

hash -r

Q3：VMess/WS 提示 deprecated？

Xray 对 VMess/WS 的确会提示弃用警告，这是上游提示，不影响当前使用。
你也可以逐步迁移到更推荐的组合（例如 Reality 或更新传输层）。

🧹 卸载

如果你在 Tiny/OpenWrt 菜单内启用了卸载功能，可直接菜单卸载。
标准 Linux 下可按需删除：

Xray 配置：/etc/xray/

sing-box 配置：/etc/sing-box/

XSB 目录：/etc/xsb/

以及 systemd 服务/二进制文件（视安装方式而定）。

📌 免责声明

本项目仅用于学习研究与合法用途，请遵守当地法律法规。
请勿用于任何非法用途或违反服务条款的场景。

⭐ Star

如果这个项目对你有帮助，欢迎点个 Star 支持一下 🙌
