
> 整理时间：2026-04-25
> 适用版本：sing-box 1.11+
> 用途：离线环境下完整重建代理节点的参考文档，配合本地大模型使用
> ⚠️ 实际生产配置以官方文档和当前版本变更记录为准，配置前务必执行 `sing-box check`

---

## 目录

1. 概念
2. 密钥与凭据生成
3. 安装
4. 配置：VLESS + Reality 详解（含 4.0 操作流程总览）
5. 配置：其他协议
6. 链式代理（中转架构）
7. 防火墙与端口放行
8. 常用命令
9. 客户端对照
10. 故障排查
11. 参考链接

---

## 1. 概念

### 1.1 sing-box 是什么

**sing-box 是一个通用代理平台**，可作为客户端、服务端或透明代理组件使用。通过统一的 JSON 配置描述入站、出站、DNS、路由、证书等模块。

常见使用场景：

- **客户端代理**：本地开启 SOCKS/HTTP/Mixed/TUN 入站，通过远端代理出站访问网络
- **服务端代理**：监听 VLESS、Hysteria2、TUIC、Trojan、Shadowsocks 等协议入站
- **透明代理/网关**：通过 TUN、Redirect、TProxy 接管系统或局域网流量
- **规则路由**：按域名、IP、协议、规则集等条件选择 `direct`、`block` 或代理节点

### 1.2 配置模型

sing-box 使用 **JSON** 格式，顶层结构如下：

```json
{
  "log": {},
  "dns": {},
  "ntp": {},
  "certificate": {},
  "inbounds": [],
  "outbounds": [],
  "route": {},
  "experimental": {}
}
```

| 字段           | 说明                                                        |
| -------------- | ----------------------------------------------------------- |
| `log`          | 日志级别与输出位置                                          |
| `dns`          | DNS 服务器、DNS 规则、FakeIP 等                             |
| `inbounds`     | 监听入口，如 `mixed`、`tun`、`vless`、`hysteria2`           |
| `outbounds`    | 流量出口，如 `direct`、`block`、`vless`、`tuic`、`selector` |
| `route`        | 路由规则与规则集                                            |
| `experimental` | Clash API、缓存文件等实验性功能                             |

### 1.3 协议概览

| 协议                 | 类型     | 抗检测  | 速度    | 特点                          |
| -------------------- | -------- | ------- | ------- | ----------------------------- |
| **VLESS + Reality**  | TCP      | ★★★★★ | ★★★★  | 当前最强抗检测，无需域名证书  |
| **Hysteria2**        | UDP/QUIC | ★★★★  | ★★★★★ | 弱网丢包环境下速度最强        |
| **TUIC v5**          | UDP/QUIC | ★★★★  | ★★★★  | 类似 Hy2，支持 0-RTT          |
| **Trojan**           | TCP      | ★★★★  | ★★★★  | 伪装 HTTPS，配置简单          |
| **VMess + WS + TLS** | TCP      | ★★★   | ★★★   | 老牌协议，可套 CDN            |
| **Shadowsocks2022**  | TCP/UDP  | ★★★   | ★★★★★ | 速度极快，抗检测一般          |
| **NaiveProxy**       | TCP      | ★★★★  | ★★★   | 伪装 Chrome H2 流量，配置复杂 |

---

## 2. 密钥与凭据生成

> ⚠️ 离线重建节点时最关键的一步，所有命令均使用 sing-box 自带工具，无需联网。

### 2.1 Reality 密钥对

```bash
# 生成 Reality 公私钥对
sing-box generate reality-keypair

# 输出示例：
# PrivateKey: ABCdef123...（填入服务端 private_key）
# PublicKey:  XYZabc456...（填入客户端 public_key）
```

> ⚠️ **PrivateKey 只放服务端，PublicKey 只放客户端。两者绝对不能对调，对调后连接必然失败且不会有明显报错提示。**

### 2.2 UUID

```bash
sing-box generate uuid
# 输出示例：110b6b4e-f8c3-4c9a-a9b2-3f2d9c6e7a1d
```

UUID 格式为 8-4-4-4-12 的十六进制字符串，服务端和客户端必须完全一致，包括大小写。

### 2.3 short_id

```bash
# 生成 8 位 hex short_id（推荐长度）
sing-box generate rand --hex 8
# 输出示例：a1b2c3d4

# 也可以更短
sing-box generate rand --hex 4
```

short_id 的规则：

- 只能包含**十六进制字符**（0-9, a-f），不能出现其他字符
- 服务端配置为**数组**，可以填多个允许的 short_id
- 客户端配置为**字符串**，只填一个，且必须是服务端数组中存在的值
- 客户端填的 short_id 不在服务端数组里，连接会被静默拒绝，不会有明显报错

### 2.4 自签证书（离线环境，用于 Hysteria2 / TUIC）

断网后无法使用 Let's Encrypt，Hysteria2 和 TUIC 强制要求 TLS，需要自签：

```bash
openssl req -x509 -newkey rsa:4096 -keyout privkey.pem \
  -out fullchain.pem -sha256 -days 3650 -nodes \
  -subj "/CN=example.com"
```

客户端对应配置加 `"insecure": true`，跳过证书验证：

```json
"tls": {
  "enabled": true,
  "server_name": "example.com",
  "insecure": true
}
```

---

## 3. 安装

### 3.1 Linux：APT 仓库（Debian / Ubuntu）

```bash
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
sudo chmod a+r /etc/apt/keyrings/sagernet.asc
sudo tee /etc/apt/sources.list.d/sagernet.sources >/dev/null <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
sudo apt-get update
sudo apt-get install sing-box
```

### 3.2 Linux：DNF（Red Hat / Fedora）

DNF 5：

```bash
sudo dnf config-manager addrepo --from-repofile=https://sing-box.app/sing-box.repo
sudo dnf install sing-box
```

DNF 4：

```bash
sudo dnf config-manager --add-repo https://sing-box.app/sing-box.repo
sudo dnf -y install dnf-plugins-core
sudo dnf install sing-box
```

### 3.3 脚本安装

> ⚠️ 只在可信环境中执行远程脚本，建议先阅读脚本内容。

```bash
# 正式版
curl -fsSL https://sing-box.app/install.sh | sh

# beta 版
curl -fsSL https://sing-box.app/install.sh | sh -s -- --beta

# 指定版本
curl -fsSL https://sing-box.app/install.sh | sh -s -- --version <version>
```

### 3.4 包管理器

```bash
brew install sing-box       # macOS
scoop install sing-box      # Windows Scoop
choco install sing-box      # Windows Chocolatey
winget install sing-box     # Windows WinGet
pkg add sing-box            # FreeBSD
```

### 3.5 Docker

单命令：

```bash
docker run -d \
  -v /etc/sing-box:/etc/sing-box/ \
  --name=sing-box \
  --restart=always \
  ghcr.io/sagernet/sing-box \
  -D /var/lib/sing-box \
  -C /etc/sing-box/ run
```

Docker Compose：

```yaml
version: "3.8"
services:
  sing-box:
    image: ghcr.io/sagernet/sing-box
    container_name: sing-box
    restart: always
    volumes:
      - /etc/sing-box:/etc/sing-box/
    command: -D /var/lib/sing-box -C /etc/sing-box/ run
```

### 3.6 源码构建

要求 Go 1.23.1 或更高版本（sing-box 1.11+）：

```bash
git clone https://github.com/SagerNet/sing-box.git
cd sing-box
make

# 安装到 $GOBIN
make install

# 自定义 build tags（需要 QUIC 支持时必须带 with_quic）
TAGS="with_quic with_grpc with_dhcp with_wireguard with_utls with_acme" make
```

### 3.7 systemd 配置路径

包管理器安装后常见路径：

```text
配置文件：  /etc/sing-box/config.json
工作目录：  /var/lib/sing-box/
```

---

## 4. 配置：VLESS + Reality 详解

> 本章是核心章节。Reality 协议细节多，容易配错，逐项展开说明，本地模型生成配置时可以作为校验依据。

### 4.0 操作流程总览（必读）

> ⚠️ **配置文件不是新建的，是修改已有的文件。** 包管理器安装 sing-box 后配置文件已经存在于 `/etc/sing-box/config.json`，操作流程是：备份 → 编辑 → 检查 → 重启，而不是创建新文件。

**完整操作步骤（每次配置节点都按此顺序）：**

**第一步：确认配置文件存在**

```bash
ls -la /etc/sing-box/config.json
cat /etc/sing-box/config.json
```

如果文件不存在（极少数情况，如手动安装），再创建：

```bash
sudo mkdir -p /etc/sing-box
sudo touch /etc/sing-box/config.json
```

**第二步：备份原配置（修改前必做）**

```bash
sudo cp /etc/sing-box/config.json /etc/sing-box/config.json.bak
```

恢复备份的命令（改坏了用这个回滚）：

```bash
sudo cp /etc/sing-box/config.json.bak /etc/sing-box/config.json
```

**第三步：编辑配置文件**

```bash
# 用 nano 编辑（操作简单，推荐新手）
sudo nano /etc/sing-box/config.json

# 用 vim 编辑
sudo vim /etc/sing-box/config.json
```

nano 操作提示：
- 方向键移动光标，直接输入修改内容
- `Ctrl+O` 保存，`Ctrl+X` 退出

**第四步：语法检查（保存后立即执行，有报错不要重启）**

```bash
sing-box check -c /etc/sing-box/config.json
```

- 输出为空 = 语法正确，可以继续
- 有报错 = 根据提示回去修改，最常见错误是 JSON 尾随逗号

**第五步：重启服务使配置生效**

```bash
sudo systemctl restart sing-box
```

**第六步：验证服务正常运行**

```bash
# 查看服务状态
sudo systemctl status sing-box

# 查看启动日志，确认无报错
sudo journalctl -u sing-box --output cat -e

# 确认端口在监听
ss -tlnp | grep sing-box
```

---

### 4.1 Reality 工作原理

Reality 是一种 **TLS 伪装技术**，核心思路是让代理服务器在握手阶段伪装成一个真实的目标网站（称为 camouflage 或 handshake 目标）。

工作流程：

1. 客户端发起 TLS 握手，SNI 填写目标网站域名（如 `www.ucla.edu`）
2. 服务端持有真实目标网站的 TLS 证书指纹，回复一个与真实网站几乎一致的 TLS 握手
3. **合法客户端**（持有正确 public_key 和 short_id）识别出这是 Reality 节点并继续代理
4. **GFW 或探测器**看到的是合法 TLS 握手，无法区分真实流量与代理流量

相较于传统 TLS 代理：

- 不需要自己买域名
- 不需要申请 SSL 证书
- 伪装效果更真实，因为 TLS 指纹来自真实网站
- 抗主动探测（active probing）能力极强

### 4.2 camouflage 域名选择原则

Reality 的 `server_name`（客户端 SNI）和服务端 `handshake.server` 必须是**同一个真实存在、支持 TLSv1.3 + H2 的域名**。

**选择标准：**

| 条件               | 说明                                             |
| ------------------ | ------------------------------------------------ |
| 支持 TLSv1.3       | Reality 依赖 TLSv1.3，目标网站必须支持          |
| 支持 HTTP/2        | H2 是标配，缺少会影响伪装质量                   |
| 境外真实服务       | 国内域名容易触发额外检测                         |
| 非 CDN 套壳        | Cloudflare 等 CDN 会替换证书，导致指纹不一致     |
| 访问量适中         | 太冷门的域名出现在流量里会显得可疑               |
| 服务器和域名同国家 | IP 归属地与域名注册地错位会显得异常             |

**推荐域名：**

- `www.microsoft.com`
- `www.apple.com`
- `addons.mozilla.org`
- `www.ucla.edu`
- `www.cloudflare.com`

**不推荐：**

- 国内域名（`.cn`、`.com.cn`）
- 个人小站、博客
- 套了 Cloudflare CDN 的普通网站（证书是 Cloudflare 的，不是网站自己的）
- 已知被大量代理用户使用的域名

**验证域名是否合适：**

```bash
# 检查是否支持 HTTP/2 和 TLSv1.3
curl -I --http2 --tlsv1.3 https://www.ucla.edu

# 检查 TLS 版本和证书信息
openssl s_client -connect www.ucla.edu:443 -tls1_3 </dev/null 2>&1 | grep -E "Protocol|Cipher"
```

返回 `HTTP/2 200` 且协议为 `TLSv1.3` 即可用。

### 4.3 字段完整说明

**服务端 inbound 每个字段的作用：**

```json
{
  "type": "vless",
  "tag": "vless-reality-in",
  "listen": "::",             // 监听所有网卡，IPv4+IPv6 均接受
  "listen_port": 8443,        // 服务监听端口，客户端连接此端口
  "users": [
    {
      "name": "user1",        // 用户名，仅日志识别用，不参与认证
      "uuid": "your-uuid",    // 认证凭据，必须与客户端一致
      "flow": "xtls-rprx-vision"  // 启用 Vision 流控，见 4.4 节说明
    }
  ],
  "tls": {
    "enabled": true,                     // 必须显式设置为 true
    "server_name": "www.ucla.edu",       // 服务端本机域名标识
    "reality": {
      "enabled": true,                   // 必须显式设置为 true
      "handshake": {
        "server": "www.ucla.edu",        // 真实握手目标域名，服务端必须能访问此域名
        "server_port": 443               // 握手目标端口，固定 443
      },
      "private_key": "your-private-key", // 服务端私钥，只在服务端填写，绝不在客户端出现
      "short_id": [                      // 允许的 short_id 列表，必须是数组
        "a1b2c3d4",
        "e5f6a7b8"                       // 可以填多个，客户端用其中任意一个即可
      ],
      "max_time_difference": "1m"        // 允许的客户端时间偏差，超出则静默拒绝
    }
  }
}
```

**客户端 outbound 每个字段的作用：**

```json
{
  "type": "vless",
  "tag": "vless-reality-out",
  "server": "1.2.3.4",           // 服务端 IP（或中转 IP）
  "server_port": 8443,            // 服务端监听端口
  "uuid": "your-uuid",            // 必须与服务端 users 中的 uuid 完全一致
  "flow": "xtls-rprx-vision",    // 必须与服务端 users 中的 flow 完全一致
  "network": "tcp",               // Reality 只走 TCP，此处不能填 udp
  "tls": {
    "enabled": true,
    "server_name": "www.ucla.edu",  // SNI，必须与服务端 handshake.server 一致
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"       // 模拟 TLS 指纹，见 4.5 节说明
    },
    "reality": {
      "enabled": true,
      "public_key": "your-public-key",  // 客户端公钥，由服务端私钥派生，只在客户端出现
      "short_id": "a1b2c3d4"            // 字符串（不是数组），必须是服务端数组中存在的值
    }
  }
}
```

### 4.4 flow（xtls-rprx-vision）详解

`flow` 字段控制 XTLS 流量控制模式，**Vision 是目前唯一推荐的值**。

- `xtls-rprx-vision`：对内层 TLS 流量（如 HTTPS）进行透传，减少二次加密开销，同时通过填充混淆内层 TLS 握手特征，提高抗指纹识别能力
- 服务端 `flow` 填了 `xtls-rprx-vision`，客户端**必须**填完全相同的值，否则连接会建立但数据传输异常
- 两端都**不填** `flow` 也能工作，但失去 Vision 的优势，不推荐
- 旧版的 `xtls-rprx-direct` 已废弃，**不要使用**

### 4.5 uTLS fingerprint（指纹）说明

`utls.fingerprint` 控制客户端伪装的 TLS 指纹，让流量看起来像正常浏览器发出的请求。

| 值            | 伪装目标         | 推荐程度                     |
| ------------- | ---------------- | ---------------------------- |
| `chrome`      | Chrome 浏览器    | ✅ 最推荐，使用最广泛         |
| `firefox`     | Firefox 浏览器   | ✅ 可用                       |
| `safari`      | Safari 浏览器    | ✅ 可用                       |
| `edge`        | Microsoft Edge   | ✅ 可用                       |
| `ios`         | iOS Safari       | ✅ 移动端可用                 |
| `random`      | 随机选择         | ⚠️ 不稳定，可能触发检测      |
| `randomized`  | 随机化参数       | ⚠️ 不推荐                    |

> `fingerprint` 只影响 TLS 握手特征，与实际使用的应用无关。选 `chrome` 即使你用的是其他浏览器也完全没问题。

### 4.6 服务端时间同步

Reality 的 `max_time_difference` 默认 `1m`，意味着服务端和客户端的**系统时间差不能超过 1 分钟**，否则服务端静默拒绝连接，不会有任何报错提示，极难排查。

检查服务端时间：

```bash
date                                      # 查看当前时间
timedatectl status                        # 查看时间同步状态
systemctl status systemd-timesyncd        # 检查 NTP 服务状态
```

如果时间不同步：

```bash
sudo timedatectl set-ntp true             # 启用 NTP 同步
sudo systemctl restart systemd-timesyncd  # 强制重新同步
```

### 4.7 完整服务端配置示例

替换占位符后执行 `sing-box check` 即可使用：

```json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": 8443,
      "users": [
        {
          "name": "user1",
          "uuid": "替换为你的UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.ucla.edu",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.ucla.edu",
            "server_port": 443
          },
          "private_key": "替换为你的PrivateKey",
          "short_id": [
            "替换为你的short_id"
          ],
          "max_time_difference": "1m"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
```

### 4.8 完整客户端配置示例

```json
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 7890
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "proxy",
      "outbounds": [
        "vless-reality-out",
        "direct"
      ],
      "default": "vless-reality-out"
    },
    {
      "type": "vless",
      "tag": "vless-reality-out",
      "server": "替换为服务端IP",
      "server_port": 8443,
      "uuid": "替换为你的UUID",
      "flow": "xtls-rprx-vision",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "www.ucla.edu",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "替换为你的PublicKey",
          "short_id": "替换为你的short_id"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "geoip": "private",
        "outbound": "direct"
      }
    ],
    "final": "proxy"
  }
}
```

### 4.9 易错点汇总

本地模型生成配置时最容易犯的错误：

| 错误                                     | 正确做法                                     |
| ---------------------------------------- | -------------------------------------------- |
| 服务端填了 `public_key`                  | 服务端只填 `private_key`                     |
| 客户端填了 `private_key`                 | 客户端只填 `public_key`                      |
| 客户端 `short_id` 写成了数组             | 客户端 `short_id` 必须是字符串               |
| 服务端 `short_id` 写成了字符串           | 服务端 `short_id` 必须是数组                 |
| 客户端 short_id 不在服务端数组内         | 客户端值必须是服务端数组中存在的元素         |
| 两端 `flow` 不一致                       | 服务端和客户端 `flow` 必须完全相同           |
| `flow` 填了旧版 `xtls-rprx-direct`      | 改为 `xtls-rprx-vision`                     |
| `network` 填了 `udp`                     | Reality 固定 `tcp`，不支持 udp               |
| 客户端 `server_name` 与服务端握手目标不一致 | 两者必须相同                              |
| `decryption` 字段出现在配置里            | 这是 Xray 的字段，sing-box 不使用此字段      |
| `tls.enabled` 未设置或设为 false         | TLS 必须显式设置 `"enabled": true`           |
| `reality.enabled` 未设置或设为 false     | Reality 必须显式设置 `"enabled": true`       |
| handshake 目标域名服务端无法访问         | 服务端需要能正常访问该域名的 443 端口        |
| 服务端和客户端时间差超过 1 分钟          | 服务端启用 NTP 同步                          |

---

## 5. 配置：其他协议

### 5.1 Hysteria2 服务端

```json
{
  "type": "hysteria2",
  "tag": "hy2-in",
  "listen": "::",
  "listen_port": 443,
  "up_mbps": 100,
  "down_mbps": 100,
  "obfs": {
    "type": "salamander",
    "password": "your-obfs-password"
  },
  "users": [
    {
      "name": "user1",
      "password": "your-auth-password"
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "example.com",
    "certificate_path": "/etc/ssl/certs/fullchain.pem",
    "key_path": "/etc/ssl/private/privkey.pem"
  },
  "masquerade": "https://www.example.com"
}
```

> sing-box 不提供 Hysteria2 的 `userpass` 别名，直接在 `password` 字段填认证密码。

### 5.2 Hysteria2 客户端

```json
{
  "type": "hysteria2",
  "tag": "hy2-out",
  "server": "example.com",
  "server_port": 443,
  "up_mbps": 100,
  "down_mbps": 100,
  "obfs": {
    "type": "salamander",
    "password": "your-obfs-password"
  },
  "password": "your-auth-password",
  "tls": {
    "enabled": true,
    "server_name": "example.com"
  }
}
```

> `up_mbps`/`down_mbps` 留空时自动使用 BBR 拥塞控制。自签证书时加 `"insecure": true`。

### 5.3 TUIC 服务端

```json
{
  "type": "tuic",
  "tag": "tuic-in",
  "listen": "::",
  "listen_port": 443,
  "users": [
    {
      "name": "user1",
      "uuid": "your-uuid",
      "password": "your-password"
    }
  ],
  "congestion_control": "cubic",
  "auth_timeout": "3s",
  "zero_rtt_handshake": false,
  "heartbeat": "10s",
  "tls": {
    "enabled": true,
    "server_name": "example.com",
    "certificate_path": "/etc/ssl/certs/fullchain.pem",
    "key_path": "/etc/ssl/private/privkey.pem"
  }
}
```

### 5.4 TUIC 客户端

```json
{
  "type": "tuic",
  "tag": "tuic-out",
  "server": "example.com",
  "server_port": 443,
  "uuid": "your-uuid",
  "password": "your-password",
  "congestion_control": "cubic",
  "udp_relay_mode": "native",
  "zero_rtt_handshake": false,
  "heartbeat": "10s",
  "network": "tcp",
  "tls": {
    "enabled": true,
    "server_name": "example.com"
  }
}
```

> `udp_relay_mode` 与 `udp_over_stream` 冲突，只能选其一。`zero_rtt_handshake` 有重放风险，保持 `false`。

---

## 6. 链式代理（中转架构）

### 6.1 概念与适用场景

链式代理是指流量经过**两个或多个节点**依次转发后到达目标，而不是客户端直连出口节点。

```
客户端 → 中转节点（relay）→ 出口节点（exit）→ 目标网站
```

**适用场景：**

- 客户端到出口节点延迟高或路由差（如直连美国 VPS 延迟 200ms+）
- 中转节点有优质回国线路（如联通 9929、电信 CN2），可大幅降低延迟
- 出口节点 IP 不稳定，通过中转增加一层缓冲
- 分散风险，避免单点故障

**核心要点：**

- Reality 的凭据（UUID、public_key、short_id）属于**出口节点**，中转节点只做 TCP 转发，不参与 Reality 握手
- 客户端填写**中转节点的 IP 和端口**，但 Reality 凭据仍然是出口节点的
- 验证方法：连接成功后 `curl ip.sb` 应返回**出口节点的 IP**，不是中转节点的 IP

### 6.2 方案一：iptables DNAT 中转（推荐）

在中转节点上用 iptables 将流量直接转发到出口节点，**中转节点不需要安装 sing-box**，性能最好。

**中转节点操作：**

```bash
# 第一步：开启内核转发
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p

# 第二步：添加 DNAT 规则（将中转节点的 8443 端口转发到出口节点的 8443）
iptables -t nat -A PREROUTING -p tcp --dport 8443 -j DNAT --to-destination 出口节点IP:8443
iptables -t nat -A POSTROUTING -j MASQUERADE

# 第三步：持久化（重启后规则依然生效）
apt install iptables-persistent -y
netfilter-persistent save
```

**客户端配置：** 填中转节点 IP 和中转端口，Reality 凭据填出口节点的：

```json
{
  "type": "vless",
  "tag": "vless-relay-out",
  "server": "中转节点IP",
  "server_port": 8443,
  "uuid": "出口节点的UUID",
  "flow": "xtls-rprx-vision",
  "network": "tcp",
  "tls": {
    "enabled": true,
    "server_name": "www.ucla.edu",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "出口节点的PublicKey",
      "short_id": "出口节点的short_id"
    }
  }
}
```

**出口节点：** 配置保持不变，无需修改任何内容。

### 6.3 方案二：sing-box detour 链式出站

在中转节点上运行 sing-box，用出站的方式将流量转到出口节点。**中转节点需要安装 sing-box**，适合需要在中转节点做路由分流的场景。

此方案中，中转节点和出口节点各自有**独立的 Reality 凭据**，客户端只需要知道中转节点的凭据。

**中转节点 sing-box 配置：**

```json
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "relay-in",
      "listen": "::",
      "listen_port": 8444,
      "users": [
        {
          "name": "relay-user",
          "uuid": "中转节点自己的UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.microsoft.com",
            "server_port": 443
          },
          "private_key": "中转节点自己的PrivateKey",
          "short_id": [
            "中转节点自己的short_id"
          ],
          "max_time_difference": "1m"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "exit-out",
      "server": "出口节点IP",
      "server_port": 8443,
      "uuid": "出口节点的UUID",
      "flow": "xtls-rprx-vision",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "www.ucla.edu",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "出口节点的PublicKey",
          "short_id": "出口节点的short_id"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "exit-out"
  }
}
```

**客户端配置：** 连接中转节点，填中转节点的凭据：

```json
{
  "type": "vless",
  "tag": "vless-relay-out",
  "server": "中转节点IP",
  "server_port": 8444,
  "uuid": "中转节点的UUID",
  "flow": "xtls-rprx-vision",
  "network": "tcp",
  "tls": {
    "enabled": true,
    "server_name": "www.microsoft.com",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "中转节点的PublicKey",
      "short_id": "中转节点的short_id"
    }
  }
}
```

### 6.4 两种方案对比

| 对比项                   | iptables DNAT        | sing-box detour          |
| ------------------------ | -------------------- | ------------------------ |
| 中转节点需安装 sing-box  | ❌ 不需要             | ✅ 需要                   |
| 配置复杂度               | 低，几行命令         | 中，需写配置文件         |
| 性能                     | 高，内核直接转发     | 稍低，用户态转发         |
| 中转节点可做路由分流     | ❌ 不支持             | ✅ 支持                   |
| 中转节点的伪装性         | 无，端口直接暴露     | 有，自带 Reality 伪装    |
| 客户端需要知道几套凭据   | 一套（出口节点的）   | 一套（中转节点的）       |
| 推荐场景                 | 简单中转、快速部署   | 需要在中转做分流控制     |

### 6.5 验证链式代理是否生效

```bash
# 连接成功后检查出口 IP（应该是出口节点的 IP，不是中转节点的 IP）
curl ip.sb
curl -4 ip.sb

# 更详细的信息
curl ipinfo.io
```

### 6.6 链式代理常见问题

**ip.sb 返回的是中转节点 IP，不是出口节点 IP：**

- iptables 方案：检查 `MASQUERADE` 规则是否生效；检查 `net.ipv4.ip_forward` 是否为 1
- sing-box 方案：检查中转节点配置的 `route.final` 是否指向出口节点的 outbound tag

**中转节点转发后速度很慢：**

- sing-box 中转是用户态转发，CPU 占用较高，考虑改用 iptables DNAT
- 检查中转节点自身的带宽上限

**出口节点日志显示来自中转节点 IP 的连接：**

- 这是正常的，出口节点看到中转节点 IP 是符合预期的行为

---

## 7. 防火墙与端口放行

> ⚠️ 配置好协议后必须放行对应端口，这一步经常被忽略导致连不上。

### 7.1 UFW（Debian / Ubuntu）

```bash
# TCP（VLESS / Trojan / VMess）
sudo ufw allow 8443/tcp

# UDP（Hysteria2 / TUIC 必须放行 UDP）
sudo ufw allow 443/udp

# 应用规则并查看状态
sudo ufw reload
sudo ufw status
```

### 7.2 iptables

```bash
sudo iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
sudo iptables -I INPUT -p udp --dport 443  -j ACCEPT

# 持久化（Debian/Ubuntu）
sudo apt install iptables-persistent
sudo netfilter-persistent save
```

### 7.3 确认端口监听

```bash
ss -tlnp | grep sing-box   # 查看 TCP 监听
ss -ulnp | grep sing-box   # 查看 UDP 监听（Hysteria2 / TUIC）
```

---

## 8. 常用命令

### 8.1 配置检查与格式化

```bash
# 检查配置文件语法（修改后必须先执行）
sing-box check -c /etc/sing-box/config.json

# 检查配置目录
sing-box check -D /etc/sing-box

# 格式化配置文件（原地写入）
sing-box format -w -c /etc/sing-box/config.json

# 合并多个配置文件
sing-box merge output.json -c config.json -D config_directory
```

### 8.2 运行

```bash
# 指定配置文件运行
sing-box run -c /etc/sing-box/config.json

# 指定工作目录和配置目录
sing-box -D /var/lib/sing-box -C /etc/sing-box run
```

### 8.3 systemd 服务管理

```bash
sudo systemctl enable  sing-box   # 开机自启
sudo systemctl start   sing-box   # 启动
sudo systemctl restart sing-box   # 重启（修改配置后执行）
sudo systemctl stop    sing-box   # 停止
sudo systemctl status  sing-box   # 查看状态
```

查看日志：

```bash
sudo journalctl -u sing-box --output cat -e   # 查看最新日志
sudo journalctl -u sing-box --output cat -f   # 持续跟踪新日志
```

### 8.4 Docker 管理

```bash
docker logs -f sing-box    # 查看日志
docker restart sing-box    # 重启
docker stop sing-box       # 停止
docker rm sing-box         # 删除容器
```

### 8.5 完整服务端验证流程

每次修改配置后按顺序执行：

```bash
# 1. 语法检查（有报错立即停下修改）
sing-box check -c /etc/sing-box/config.json

# 2. 重启服务
sudo systemctl restart sing-box

# 3. 确认端口监听（等 2-3 秒再执行）
ss -tlnp | grep sing-box
ss -ulnp | grep sing-box

# 4. 查看启动日志确认无报错
sudo journalctl -u sing-box --output cat -e

# 5. 确认进程正在运行
ps aux | grep sing-box
```

---

## 9. 客户端对照

### 9.1 Shadowrocket（iOS）VLESS + Reality 填写对照

| sing-box 字段            | Shadowrocket 位置 | 填写内容               |
| ------------------------ | ----------------- | ---------------------- |
| `type: vless`            | 类型              | 选 VLESS               |
| `server`                 | 服务器地址        | VPS IP 或中转 IP       |
| `server_port`            | 端口              | 如 8443                |
| `uuid`                   | UUID              | 生成的 UUID            |
| `flow`                   | Flow              | `xtls-rprx-vision`     |
| `tls.server_name`        | SNI               | 如 `www.ucla.edu`      |
| `tls.reality.public_key` | Public Key        | 客户端公钥             |
| `tls.reality.short_id`   | Short ID          | 生成的 short_id        |
| `tls.utls.fingerprint`   | Fingerprint       | `chrome`               |

### 9.2 其他客户端

| 平台    | 推荐客户端   | 地址                                             |
| ------- | ------------ | ------------------------------------------------ |
| iOS     | Shadowrocket | App Store                                        |
| Android | NekoBox      | https://github.com/MatsuriDayo/NekoBoxForAndroid |
| Windows | v2rayN       | https://github.com/2dust/v2rayN                  |
| 全平台  | Hiddify      | https://hiddify.com                              |

### 9.3 客户端 VLESS 链接拼接

VLESS 分享链接用于导入 Shadowrocket、v2rayN、v2rayNG、NekoBox、Hiddify 等客户端。**链接里的参数必须与 sing-box 客户端 outbound 和服务端 inbound 完全一致**，尤其是 UUID、SNI、Public Key、Short ID 和 Flow。

**基础格式：**

```
vless://<uuid>@<server>:<port>?encryption=none&type=tcp&security=reality&sni=<sni>&fp=<fingerprint>&pbk=<public_key>&sid=<short_id>&flow=xtls-rprx-vision#<remark>
```

**字段来源对照：**

| 链接字段        | 含义               | 对应 sing-box 字段                                           | 示例                                   |
| --------------- | ------------------ | ------------------------------------------------------------ | -------------------------------------- |
| `<uuid>`        | 用户 UUID          | 服务端 `users[].uuid` / 客户端 `uuid`                        | `110b6b4e-f8c3-4c9a-a9b2-3f2d9c6e7a1d` |
| `<server>`      | 客户端实际连接地址 | 客户端 `server`                                              | `1.2.3.4` 或 `example.com`             |
| `<port>`        | 客户端实际连接端口 | 服务端 `listen_port` / 客户端 `server_port`                  | `8443`                                 |
| `encryption`    | VLESS 加密字段     | 固定为 `none`                                                | `none`                                 |
| `type`          | 传输类型           | 客户端 `network`                                             | `tcp`                                  |
| `security`      | 安全层类型         | `tls.reality.enabled: true`                                  | `reality`                              |
| `<sni>`         | Reality SNI        | 客户端 `tls.server_name`，通常等于服务端 `tls.reality.handshake.server` | `www.ucla.edu`                         |
| `<fingerprint>` | uTLS 指纹          | 客户端 `tls.utls.fingerprint`                                | `chrome`                               |
| `<public_key>`  | Reality 公钥       | 客户端 `tls.reality.public_key`                              | `your-public-key`                      |
| `<short_id>`    | Reality Short ID   | 客户端 `tls.reality.short_id`，必须在服务端 `short_id` 数组内 | `a1b2c3d4`                             |
| `flow`          | Vision 流控        | 服务端 `users[].flow` / 客户端 `flow`                        | `xtls-rprx-vision`                     |
| `<remark>`      | 客户端显示名称     | 链接片段，不进 sing-box 配置                                 | `VLESS-Reality`                        |

**示例链接：**

```
vless://110b6b4e-f8c3-4c9a-a9b2-3f2d9c6e7a1d@1.2.3.4:8443?encryption=none&type=tcp&security=reality&sni=www.ucla.edu&fp=chrome&pbk=YOUR_PUBLIC_KEY&sid=a1b2c3d4&flow=xtls-rprx-vision#VLESS-Reality
```

**IPv6 地址写法：**

```
vless://110b6b4e-f8c3-4c9a-a9b2-3f2d9c6e7a1d@[2001:db8::1]:8443?encryption=none&type=tcp&security=reality&sni=www.ucla.edu&fp=chrome&pbk=YOUR_PUBLIC_KEY&sid=a1b2c3d4&flow=xtls-rprx-vision#VLESS-Reality
```

**拼接步骤：**

1. 从服务端 `users[].uuid` 取 UUID，放到 `vless://` 后面。
2. 在 `@` 后填写客户端实际连接的 IP、域名或中转地址，再接 `:<port>`。
3. 查询参数固定包含 `encryption=none&type=tcp&security=reality`。
4. `sni` 填客户端 `tls.server_name`，也就是 Reality 伪装域名。
5. `fp` 填 `tls.utls.fingerprint`，常用 `chrome`。
6. `pbk` 填 **PublicKey**，不要填服务端 `private_key`。
7. `sid` 填客户端 `short_id`，必须是服务端允许列表中的一个。
8. `flow` 填 `xtls-rprx-vision`，两端必须一致。
9. `#` 后面是客户端显示名称，中文或空格建议 URL 编码。

**注意事项：**

- **服务端私钥 `private_key` 永远不要放进链接**，客户端链接只使用 `public_key`。
- 如果 short_id 为空，可以写成 `sid=`，也可以在部分客户端中省略；为兼容性建议保留 `sid=`。
- 如果备注、SNI 或其他参数里出现空格、`#`、`&`、`?` 等特殊字符，必须 URL 编码。
- 参数顺序通常不影响解析，但建议保持模板顺序，便于人工核对。
- 如果客户端导入后显示字段缺失，优先检查 `pbk`、`sid`、`sni`、`fp` 这些 Reality 专用参数。

------

---

## 10. 故障排查

### 10.1 排查决策树

```
连不上？
│
├─ ping 服务器 IP 通吗？
│   ├─ 不通 → 服务器宕机 or IP 被封，联系服务商或换 IP
│   └─ 通   → 继续
│
├─ 端口通吗？（telnet <IP> <PORT>）
│   ├─ 不通 → UFW/iptables 没放行，或 sing-box 没跑起来
│   └─ 通   → 继续
│
├─ sing-box 服务状态？（systemctl status sing-box）
│   ├─ 报错 → journalctl -u sing-box -f 看具体错误
│   └─ 正常 → 继续
│
└─ 客户端参数是否与服务端完全一致？
    ├─ UUID 是否完全一致（区分大小写）？
    ├─ PublicKey 是否正确（不是 PrivateKey）？
    ├─ short_id 是否在服务端数组中存在？
    ├─ SNI 是否与服务端 handshake.server 相同？
    ├─ flow 两端是否都是 xtls-rprx-vision？
    └─ 服务端时间是否同步（误差 <1 分钟）？
```

### 10.2 VLESS + Reality 连接失败

| 症状           | 可能原因               | 解决方法                         |
| -------------- | ---------------------- | -------------------------------- |
| 立即超时       | 端口未放行             | 检查 UFW / iptables              |
| 握手失败       | public_key 填错        | 重新确认密钥对，注意服务端客户端 |
| 握手失败       | short_id 不匹配        | 确认客户端值在服务端数组中       |
| 连上但断流     | flow 不一致            | 两端统一改为 `xtls-rprx-vision`  |
| 连上但很慢     | handshake 目标域名慢   | 换延迟低的 camouflage 域名       |
| 随机断连       | 服务端时间偏差过大     | 服务端启用 NTP 同步              |
| 连接被静默拒绝 | 时间差超过 1 分钟      | 两端时间同步                     |

修改配置后生效步骤：

```bash
sing-box check -c /etc/sing-box/config.json
sudo systemctl restart sing-box
sudo journalctl -u sing-box --output cat -e
```

### 10.3 Hysteria2 能连但速度异常

- `up_mbps`/`down_mbps` 设置过高或过低
- UDP 被运营商或防火墙限速 / QoS
- 客户端和服务端 `obfs.password` 不一致
- 服务器带宽已达上限

### 10.4 TUIC 连接不稳定

- 在 `cubic`、`new_reno`、`bbr` 之间切换 `congestion_control` 测试
- `udp_relay_mode` 和 `udp_over_stream` 不能同时使用
- 不建议开启 `zero_rtt_handshake`
- 检查 UDP/QUIC 是否被网络环境干扰

### 10.5 配置无法启动

```bash
sing-box check -c /etc/sing-box/config.json
```

重点检查：

- JSON 语法是否合法，**尾随逗号**是最常见的错误
- `type`、`tag`、`listen_port`、`server_port` 是否拼写正确
- 入站端口是否被其他进程占用：`ss -tlnp | grep <PORT>`
- TLS 证书、私钥路径是否存在且可读
- 运行用户是否具备低端口（<1024）权限

### 10.6 直接复制配置注意事项

复制后**至少替换**以下内容，替换后必须执行 `sing-box check`：

- UUID、密码、Reality 密钥对、short_id
- 服务器地址、端口、SNI、证书路径
- `up_mbps`、`down_mbps`、拥塞控制参数
- 路由规则和 DNS 策略

---

## 11. 参考链接

### sing-box 官方

| 文档               | 地址                                                           |
| ------------------ | -------------------------------------------------------------- |
| 官方文档           | https://sing-box.sagernet.org                                  |
| 配置参考           | https://sing-box.sagernet.org/configuration                    |
| GitHub             | https://github.com/SagerNet/sing-box                           |
| 安装文档           | https://sing-box.sagernet.org/installation/package-manager/    |
| Docker 文档        | https://sing-box.sagernet.org/installation/docker/             |
| VLESS 入站         | https://sing-box.sagernet.org/configuration/inbound/vless/     |
| VLESS 出站         | https://sing-box.sagernet.org/configuration/outbound/vless/    |
| TLS / Reality 字段 | https://sing-box.sagernet.org/configuration/shared/tls/        |
| Hysteria2 入站     | https://sing-box.sagernet.org/configuration/inbound/hysteria2/ |
| Hysteria2 出站     | https://sing-box.sagernet.org/configuration/outbound/hysteria2/|
| TUIC 入站          | https://sing-box.sagernet.org/configuration/inbound/tuic/      |
| TUIC 出站          | https://sing-box.sagernet.org/configuration/outbound/tuic/     |

### 协议官方

| 协议           | 地址                           |
| -------------- | ------------------------------ |
| Xray / Reality | https://xtls.github.io         |
| Hysteria2      | https://v2.hysteria.network    |
| TUIC           | https://github.com/EAimTY/tuic |

### 客户端

| 客户端             | 地址                                             |
| ------------------ | ------------------------------------------------ |
| NekoBox（Android） | https://github.com/MatsuriDayo/NekoBoxForAndroid |
| Hiddify（全平台）  | https://hiddify.com                              |
| v2rayN（Windows）  | https://github.com/2dust/v2rayN                  |
| Shadowrocket（iOS）| App Store 搜索                                   |
