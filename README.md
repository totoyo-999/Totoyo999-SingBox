<div align="center">

# 🦊 Totoyo999-SingBox

**Sing-Box 多协议一键部署管理脚本**

[![Version](https://img.shields.io/badge/version-v5.3.0-blue?style=for-the-badge)]()
[![Nodes](https://img.shields.io/badge/节点-20%20个-green?style=for-the-badge)]()
[![Protocols](https://img.shields.io/badge/协议-10%20种-orange?style=for-the-badge)]()
[![WARP](https://img.shields.io/badge/WARP-Cloudflare-6C3FC5?style=for-the-badge)]()
[![License](https://img.shields.io/badge/license-MIT-informational?style=for-the-badge)]()

一键部署 10 种代理协议 × 直连 + WARP 双线路 = 20 个节点

</div>

---

## ✨ 功能特点

| 功能 | 说明 |
|------|------|
| 🚀 一键部署 | 自动安装 sing-box、生成证书、配置 20 个节点、注册 systemd 服务 |
| 🔄 10 种协议 | 涵盖当前主流代理协议，直连 + WARP 双通道 |
| ⚡ 节点测速 | TCP Ping 测试各节点延迟，快速定位最佳节点 |
| 📡 订阅生成 | 自动生成 Base64 订阅链接，兼容 v2rayN / Clash / NekoBox |
| 💾 配置备份 | 一键导出/恢复配置，迁移 VPS 零成本 |
| 🎨 节点图标 | 56 个预设图标 + 自定义别名/emoji，多 VPS 方便区分 |
| 📊 实时日志 | 查看运行日志，排查问题一目了然 |
| 🔧 端口管理 | 一键更换所有端口、开关单个节点、防火墙自动放行 |
| 🌐 IPv4 / IPv6 | 同时生成 IPv4 和 IPv6 分享链接 |
| 🛡️ WARP 集成 | 自动安装 Cloudflare WARP，流量经过 WARP 出口 |

---

## 📡 支持协议

### TCP 协议（7 种）

| 协议 | 说明 | 特点 |
|------|------|------|
| **VLESS-Reality** | 基于 TLS 握手指纹伪装的 VLESS | 无需证书、抗审查能力最强、伪装访问合法网站，目前最推荐的协议之一 |
| **VLESS-Reality-gRPC** | VLESS + gRPC 传输 | 多路复用、在 Reality 基础上提升性能，可伪装为正常 gRPC 流量 |
| **Trojan-Reality** | 基于 Reality 伪装的 Trojan | 伪装为 HTTPS 流量，配合 Reality 无需域名，部署简单且安全性高 |
| **Hysteria2** | 基于 QUIC 的高速协议 | 基于 UDP、速度极快、内置拥塞控制 (Brutal)，弱网环境表现优异 |
| **VMess-WebSocket** | VMess + WS 传输 | 兼容性最好、可套 CDN (Cloudflare)，适合需要隐藏 IP 的场景 |
| **Shadowsocks-2022** | SS 2022 版本（AEAD 2022） | 最新加密标准、前向安全、抗流量分析，aes-256-gcm |
| **Shadowsocks** | 经典 SS（aes-256-gcm） | 老牌协议、客户端支持最广泛 |

### UDP 协议（3 种）

| 协议 | 说明 | 特点 |
|------|------|------|
| **Hysteria2-Obfs** | Hysteria2 + Salamander 混淆 | 在 Hysteria2 基础上加流量混淆、增强隐蔽性，防 DPI 检测 |
| **TUIC v5** | 基于 QUIC 的代理协议 | UDP 原生、低延迟、原生多路复用 + BBR 拥塞控制 |
| **AnyTLS** | sing-box 独有 TLS 代理协议 | 不绑定特定代理协议、纯 TLS 伪装、指纹与正常 HTTPS 完全一致 |

### WARP 线路（10 个）

每个协议额外生成一个 WARP 节点，流量经 Cloudflare WARP 出口，获得「干净的」IP，适合：
- 🎬 解锁流媒体地域限制
- 🔒 避免 VPS IP 被风控
- 🌍 获取 Cloudflare 级别的网络质量

> 💡 **直连节点**流量直接从 VPS 出口；**WARP 节点**流量经 Cloudflare WARP 转发，出口 IP 为 Cloudflare IP。

---

## 🖥️ 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Debian 9+ / Ubuntu 18.04+ / CentOS 7+ / RHEL 7+ / Fedora / Arch / Alpine |
| 架构 | x86_64 (amd64) / ARM64 (aarch64) / ARMv7 |
| 权限 | root |
| 内存 | ≥ 256 MB |
| 磁盘 | ≥ 1 GB |
| 网络 | 需要公网 IPv4 或 IPv6 |

---

## 📦 快速开始

### 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/totoyo-999/Totoyo999-SingBox/main/sing-box-totoyo-999.sh)
```

### 手动安装

```bash
# 1. 下载脚本
wget -O sing-box-totoyo-999.sh https://raw.githubusercontent.com/totoyo-999/Totoyo999-SingBox/main/sing-box-totoyo-999.sh

# 2. 赋予执行权限
chmod +x sing-box-totoyo-999.sh

# 3. 运行脚本
./sing-box-totoyo-999.sh
```

---

## 🎮 管理菜单

运行脚本后进入交互式管理菜单：

```
=== Sing-Box-totoyo-999 管理脚本 v5.3.0 ===

  1)  安装/部署（20 节点）       一键安装 sing-box 并部署全部节点
  2)  查看分享链接（IPv4）       显示所有直连节点的分享链接
  3)  重启服务                   重启 sing-box 服务
  4)  一键更换所有端口           重新生成随机端口并更新配置
  5)  一键开启 BBR               启用 TCP BBR 拥塞控制
  6)  查看分享链接（IPv6）       显示 IPv6 地址的分享链接
  7)  节点开关管理               单独启用/禁用指定协议节点
  8)  卸载                       完全卸载 sing-box 及所有配置
  9)  节点测速                   TCP Ping 测试各节点延迟
  10) 订阅链接生成              生成 Base64 订阅（v2rayN/Clash）
  11) 配置备份                  导出配置到 tar.gz 压缩包
  12) 配置恢复                  从备份文件恢复配置
  13) 实时日志                  查看 sing-box 运行日志
  14) 设置节点图标              选择节点前缀图标（56 预设 + 自定义 emoji/别名）
  0)  退出
```

---

## 📱 客户端推荐

| 平台 | 推荐客户端 | 支持协议 |
|------|-----------|---------|
| Windows | [v2rayN](https://github.com/2dust/v2rayN) | 全部 10 种 |
| macOS | [sing-box GUI](https://sing-box.sagernet.org/guide/installation/) | 全部 10 种 |
| Android | [sing-box (SFA)](https://sing-box.sagernet.org/guide/installation/) / [v2rayNG](https://github.com/2dust/v2rayNG) | 全部 10 种 |
| iOS | [sing-box (SFV)](https://sing-box.sagernet.org/guide/installation/) / [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118) | 全部 10 种 |
| Linux | [sing-box CLI](https://sing-box.sagernet.org/guide/installation/) | 全部 10 种 |

### 客户端导入方式

**v2rayN（Windows）：**
1. 菜单选择 `10) 订阅链接生成` → 复制订阅地址
2. v2rayN → 订阅 → 订阅设置 → 添加 → 粘贴地址 → 确定 → 更新订阅

**Clash / Clash Meta：**
1. 菜单选择 `10) 订阅链接生成` → 复制订阅地址
2. Clash 配置中添加 `proxy-providers`，类型为 `http`

**Shadowrocket / Surge / Quantumult X：**
1. 菜单选择 `2) 查看分享链接` → 复制对应协议链接
2. 在客户端中粘贴导入

---

## 🔧 高级用法

### 只启用指定协议

运行脚本后选择 `7) 节点开关管理`，可单独开关任意协议节点。

也可通过环境变量控制：

```bash
# 禁用 WARP，只保留直连节点
ENABLE_WARP=false ./sing-box-totoyo-999.sh

# 只启用 VLESS-Reality 和 Hysteria2
ENABLE_VLESS_REALITY=true ENABLE_HYSTERIA2=true \
ENABLE_VLESS_GRPCR=false ENABLE_TROJAN_REALITY=false \
ENABLE_VMESS_WS=false ENABLE_HY2_OBFS=false \
ENABLE_SS2022=false ENABLE_SS=false \
ENABLE_TUIC=false ENABLE_ANYTLS=false \
./sing-box-totoyo-999.sh
```

### 节点图标 & 别名自定义

运行脚本后选择 `14) 设置节点图标`，支持两种方式：

**预设图标（56 个）：**

| 分类 | 图示 |
|------|------|
| 🐾 动物 | 🦊 狐狸 · 🐉 龙 · 🦁 狮子 · 🐆 豹子 · 🦅 鹰 · 🐬 海豚 · 🦈 鲨鱼 · 🐺 狼 · 🐝 蜜蜂 · 🐈 猫 · 🦉 猫头鹰 · 🐧 企鹅 ... |
| ⚡ 科技 | ⚡ 闪电 · 🔒 锁 · 🛡️ 盾牌 · 🚀 火箭 · 💎 钻石 · 🎯 靶心 · 🧊 冰块 · 📡 卫星 ... |
| 🏳️ 国旗 | 🇺🇸 美国 · 🇯🇵 日本 · 🇭🇰 香港 · 🇸🇬 新加坡 · 🇰🇷 韩国 · 🇩🇪 德国 · 🇬🇧 英国 · 🇹🇼 台湾 ... |
| ◆ 符号 | ▲ 三角 · ● 圆 · ◆ 菱形 · ★ 星 · 🔴 红圆 · 🔵 蓝圆 · 🟢 绿圆 · 🟡 黄圆 ... |

**自定义 emoji / 别名：**

也可以直接输入任意 emoji 或文字作为节点前缀，例如：

```
选择图标后，节点名称效果：
  🦊 vless-reality
  🦊 hysteria2-warp
  🦊 trojan-reality
```

多台 VPS 用不同图标，在客户端里一目了然，方便区分。

---

### 配置备份与迁移

```bash
# 在源 VPS 上：菜单 11) 配置备份
# 生成 /root/sing-box-backup-*.tar.gz

# 传输到新 VPS
scp sing-box-backup-*.tar.gz root@新VPS:/root/

# 在新 VPS 上：菜单 12) 配置恢复
# 选择备份文件即可完成迁移
```

---

## 🔧 配置文件位置

| 路径 | 说明 |
|------|------|
| `/opt/sing-box/config.json` | sing-box 主配置文件 |
| `/opt/sing-box/data/` | sing-box 运行数据目录 |
| `/opt/sing-box/creds.env` | UUID、密钥等凭据（自动生成） |
| `/opt/sing-box/ports.env` | 各协议端口配置（自动生成） |
| `/opt/sing-box/warp.env` | WARP WireGuard 参数 |
| `/opt/sing-box/icon.env` | 自定义节点图标设置 |
| `/var/lib/sing-box-plus/` | 脚本工作目录（依赖、证书等） |
| `/etc/systemd/system/sing-box.service` | systemd 服务文件 |
| `/var/www/html/sub/singbox.txt` | 订阅链接文件（HTTP 订阅） |

---

## 🗂️ 项目结构

```
Totoyo999-SingBox/
└── sing-box-totoyo-999.sh    # 主脚本（包含所有功能，纯 Bash）
```

---

## ⚠️ 注意事项

1. **Cloudflare WARP** 默认启用，需要 VPS 能访问 Cloudflare。如不需要可在「节点开关管理」中关闭
2. **Reality 协议**需要一个可访问的 TLS 站点（脚本默认使用 `www.microsoft.com`）作为伪装目标
3. **Hysteria2 / TUIC** 基于 UDP (QUIC)，请确保防火墙放行对应 UDP 端口
4. **端口随机生成**，首次部署时自动分配，如需自定义可通过「一键更换所有端口」修改
5. 建议部署后立即通过「配置备份」功能备份，方便后续迁移或恢复

---

## 📜 许可证

[MIT License](LICENSE)

---

<div align="center">

**Made with ❤️ by [totoyo-999](https://github.com/totoyo-999)**

</div>
