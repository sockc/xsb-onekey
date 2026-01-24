# XSB OneKey Manager（xsb-onekey）

一个 **面向多协议、多机器、多系统** 的一键部署工具：  
同时管理 **Xray + sing-box**，支持你自由组合协议，而不是只给固定几套模板。

> ✅ 适合：多国家 VPS、线路不稳定/需要免流、纯 IPv6、AMD/ARM 混搭部署  
> ✅ 目标：一套脚本搞定所有节点的安装、添加、导出、维护与防火墙

---

## 🚀 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vinchi008/xsb-onekey/main/install.sh) --force && xsb
```
```bash
xsb

```
✨ 支持的协议
Xray（TCP 系）

VLESS + Reality

VMess + WS（noTLS）

VMess + TCP + HTTP（支持自定义/随机 path）

sing-box（UDP 系）

TUIC

Hysteria2（HY2）

说明：

Reality 支持自定义 SNI / shortId / flow

VMess WS 支持自定义 Host / path（可免流场景使用）

TUIC / HY2 默认使用自签证书，客户端需要开启 allow_insecure / insecure

🧠 设计原则
✅ 1）自由组合协议

你可以在同一台 VPS 上同时跑 Reality / VMess / TUIC / HY2
也可以只装其中任意协议组合，不被“固定套餐”绑架。

✅ 2）标准目录 & systemd 管理

Xray 配置：/etc/xray/config.json

sing-box 配置：/etc/sing-box/config.json

元数据（节点信息/导出）：/var/lib/xsb/meta.json

服务文件：

/etc/systemd/system/xray.service

/etc/systemd/system/sing-box.service

✅ 3）兼容 AMD / ARM

自动识别架构下载最新版：

amd64

arm64

armv7

📦 功能一览（菜单能力）
安装与维护

✅ 一键安装/初始化（Xray + sing-box）

✅ 更新核心（Xray / sing-box）

✅ 备份 / 恢复配置

✅ 查看日志（systemd journal）

节点管理

✅ 自由添加入站（按协议选择）

✅ 列出/删除入站

✅ 导出链接 / 配置 / 二维码（qrencode 可用时）

✅ 节点体检：服务状态、监听端口检查

✅ 延迟检测（轻量本机测试）

防火墙（UFW）

✅ 一键启用/关闭 UFW

✅ 自动识别并放行 SSH 端口（避免锁门）

✅ 自动放行脚本创建的所有节点端口

✅ 自定义放行端口 / 关闭端口规则

✅ 查看当前已放行端口

⚠️ 注意：如果你使用云服务器，还需要同时放行云厂商安全组端口。

🛠 使用示例
添加 VLESS + Reality

进入菜单后选择：

添加入站 → VLESS + Reality

填入 SNI（可用于伪装/免流场景）

自动生成 keypair 并导出链接

添加 VMess WS（noTLS）

进入菜单后选择：

添加入站 → VMess + WS (noTLS)

支持自定义 path / Host

添加 VMess TCP + HTTP

进入菜单后选择：

添加入站 → VMess + TCP + HTTP

支持自定义 path / Host

添加 TUIC / HY2

进入菜单后选择：

添加入站 → TUIC 或 Hysteria2

自动生成自签证书与导出配置

✅ 常见问题（FAQ）
1）节点不通怎么办？

按顺序排查：

systemctl status xray --no-pager -l

systemctl status sing-box --no-pager -l

ss -lntp | grep xray / ss -lnup | grep sing-box

云安全组是否放行端口（TCP/UDP）

2）Reality 生成失败？

脚本已兼容新版 xray x25519 输出格式。
如果你的系统缺少依赖，会自动安装 python3-cryptography 用于计算 PublicKey。

3）TUIC / HY2 客户端无法连接？

默认自签证书，请在客户端开启：

allow_insecure = true

insecure = true

🔥 推荐部署策略（多 VPS 多线路）

线路好 / 稳定：Reality + TUIC

需要伪装/免流：VMess WS(noTLS) + 自定义 Host/path

纯 IPv6 机器：Reality + VMess TCP HTTP

UDP 可能不稳：主推 Reality + TCP 方案兜底

📌 免责声明

本项目仅供学习、研究与合法用途。请遵守当地法律法规，作者不对任何滥用行为负责
