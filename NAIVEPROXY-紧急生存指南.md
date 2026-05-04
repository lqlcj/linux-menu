# NaiveProxy 紧急生存指南

> **写给 leyili 的兜底备用线路文档**
> 当主线 VLESS+Reality 被精准识别时，这是最后一道保险。
> 适用范围：从服务端从零部署 → 客户端接入 → 验证排错。
> 假设你完全没用过 Caddy 和 NaiveProxy，零基础也能跟着做。

---

## 0. 一分钟搞清楚这是什么

**NaiveProxy** 是直接把 Chromium（Chrome 浏览器的内核）的网络栈搬过来发代理流量。
**Caddy** 是一个开源 Web 服务器，配上一个特殊插件 `forwardproxy` 就能给 NaiveProxy 当服务端。

为什么这套组合最隐蔽：

| 维度 | 工作机制 |
|---|---|
| **TLS 指纹** | 直接用 Chrome 那套代码发包，**和你 Chrome 访问 HTTPS 完全一样**——不是模仿，是真用 |
| **抗主动探测** | 服务端就是一个**真实的 Caddy 网站**，没认证的流量被甩到伪装页面，GFW 探测看到的是个普通 HTTPS 站 |
| **抗流量分析** | HTTP/2 多路复用，包大小/时序和真 HTTPS 没区别 |
| **历史战绩** | 2022 年 10 月那次大封锁，**只有 NaiveProxy 幸免**（Trojan/V2Ray/VLESS/gRPC 全军覆没） |

**代价：**
- ❌ 不能用 NAT VPS（要独占 80、443 端口申请证书）
- ❌ 必须有合法域名 + 真实证书（自签会暴露）
- ⚠️  比 Hysteria2 慢一点点，但稳

---

## 1. 准备工作（约 10 分钟）

### 1.1 你需要这几样东西

| 东西 | 要求 | 说明 |
|---|---|---|
| **VPS** | Debian 11+ / Ubuntu 22.04+，**非 NAT，独立 IPv4** | 内存 ≥ 256MB，CPU 1 核够 |
| **域名** | 任何后缀都行，**别用 freenom 那种免费的** | namecheap / Cloudflare Registrar / 阿里云均可 |
| **Cloudflare 账号** | 免费即可 | 用来管 DNS（也可不用 CF，自己域名商管也行） |
| **SSH 工具** | Windows 推荐 [Termius](https://termius.com/) 或自带 PowerShell | 用来连 VPS |

> **重要**：这台 VPS **不要和你主线 Reality 用同一台**。鸡蛋别放一个篮子——主线被针对时，这台才是兜底。

### 1.2 域名解析

把域名 A 记录指到 VPS 的 IPv4。

**以 Cloudflare 为例**：
1. 登录 https://dash.cloudflare.com
2. 选你的域名 → DNS → Records → Add record
3. 填写：
   - Type: `A`
   - Name: `naive`（这样最终域名是 `naive.你的域名.com`）
   - IPv4 address: 你 VPS 的 IP
   - Proxy status: **关闭橙色云朵**（必须 DNS only！开了 CDN 证书申请会失败）
4. Save

> 等待 1-2 分钟生效，然后 ping 一下确认：
> ```bash
> ping naive.example.com
> # 看到的 IP 应该就是你 VPS 的 IP
> ```

### 1.3 防火墙放行 80、443

SSH 登录到 VPS 后执行：

```bash
# 检查防火墙状态
sudo ufw status

# 如果防火墙开着，放行端口
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw reload
```

云厂商（阿里云、AWS、谷歌云）**还要去控制台安全组里放行 80 和 443**——这是新手最容易踩的坑。

---

## 2. 服务端部署

### 🟢 方案 A：一键脚本（推荐，5 分钟搞定）

社区最经过验证的脚本：[crazypeace/naive](https://github.com/crazypeace/naive)。它做的事：
1. 用官方源装基础版 Caddy
2. 下载 NaiveProxy 作者编译好的带 `forwardproxy` 插件的 Caddy
3. 替换二进制文件
4. 自动写 `Caddyfile`
5. 自动用 Let's Encrypt 申请证书

**SSH 登录 VPS（用 root 身份）然后执行：**

```bash
bash <(curl -L https://github.com/crazypeace/naive/raw/main/install.sh) naive.example.com 4 443 myuser MyPassWord123
```

把这五个参数替换成你自己的：

| 位置 | 值 | 说明 |
|---|---|---|
| `naive.example.com` | 你的域名 | 必须已经解析到这台 VPS |
| `4` | 网络栈 | `4`=IPv4 only；`6`=IPv6+WARP（VPS 只有 IPv6 时用） |
| `443` | 端口 | 强烈建议保留 443，最隐蔽 |
| `myuser` | 用户名 | **不要用冒号、@、#、/ 等特殊字符** |
| `MyPassWord123` | 密码 | 同上，建议纯字母数字 |

**生成强密码（如果你想用复杂密码）：**
```bash
cat /dev/urandom | tr -dc a-zA-Z0-9 | head -c32; echo
# 输出一串 32 位的随机字母数字，复制走
```

#### 等什么 / 看什么

脚本运行时：
- 中间会出现一段 ERROR 红字 —— **不要慌**，这是 Caddy 在尝试申请证书的正常输出
- 看到 `certificate obtained successfully` 就成功了
- 整个过程 1-3 分钟

#### 验证服务端是否就绪

**测试 1：浏览器打开 `https://naive.example.com`**
你应该看到一个普通网页（默认是 Caddy 的占位页或一个简单 hello）。
**这就是核心防御点**——任何 GFW 探测器看到的也只是这个页面。

**测试 2：SSH 里执行**
```bash
curl -I https://naive.example.com
# 应该返回 HTTP/2 200（或 301/302），且证书是 Let's Encrypt
```

**测试 3：检查 Caddy 在跑**
```bash
sudo systemctl status caddy
# 应该看到 active (running) 绿色字样
```

如果都对，**服务端完事了，跳到第 3 章接客户端**。

---

### 🟡 方案 B：手动安装（一键脚本失败时备用）

适用：一键脚本网络问题装不上、或你想完全自己控制。

#### 步骤 B1：装基础 Caddy（5 行命令）

```bash
sudo apt update
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
```

#### 步骤 B2：编译带 `forwardproxy` 插件的 Caddy

> **重要**：官方包不带这个插件，必须自己加。

```bash
# 装 Go
sudo apt install -y golang

# 用 xcaddy 编译带插件版（这是 NaiveProxy 官方 README 给的命令）
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
~/go/bin/xcaddy build --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive

# 替换原版
sudo systemctl stop caddy
sudo cp caddy /usr/bin/caddy
sudo setcap cap_net_bind_service=+ep /usr/bin/caddy

# 验证插件已装入（关键！）
caddy list-modules | grep forward_proxy
# 应该输出：http.handlers.forward_proxy
```

如果最后那条命令什么都没输出，**说明编译没成功，不要继续**，回头检查 Go 版本是否 ≥ 1.21。

#### 步骤 B3：写 `Caddyfile`

```bash
sudo nano /etc/caddy/Caddyfile
```

清空原内容，粘贴下面的（**替换 4 处**：域名、邮箱、用户名、密码）：

```caddyfile
{
  order forward_proxy before file_server
  log {
    exclude http.log.error
  }
}

:443, naive.example.com {
  tls your-email@gmail.com
  encode
  forward_proxy {
    basic_auth myuser MyPassWord123
    hide_ip
    hide_via
    probe_resistance
  }
  file_server {
    root /var/www/html
  }
}
```

**逐行解释**（小白别跳过）：

| 配置项 | 作用 |
|---|---|
| `order forward_proxy before file_server` | 让代理处理优先于静态文件，否则会报错 |
| `:443, naive.example.com` | 监听 443 端口，对外域名是这个。`:443,` **必须在域名前面** |
| `tls your-email@gmail.com` | 用这个邮箱去 Let's Encrypt 申请证书 |
| `basic_auth myuser MyPassWord123` | 这就是客户端要填的用户名密码 |
| `hide_ip` / `hide_via` | 不暴露真实 IP 和代理来源 |
| `probe_resistance` | **核心**：探测者认证失败时，悄无声息地把请求扔给伪装站，**不会有任何代理特征暴露** |
| `file_server { root /var/www/html }` | 伪装站的网页目录 |

#### 步骤 B4：放一个伪装网页 + 启动

```bash
sudo mkdir -p /var/www/html
echo "<h1>It works!</h1><p>Welcome to nginx.</p>" | sudo tee /var/www/html/index.html
sudo systemctl restart caddy
sudo systemctl status caddy
```

看到 `active (running)` 就成功了。

> 想让伪装更逼真？用 wget 镜像一个真实小博客：
> ```bash
> sudo wget -m -k -p -P /var/www/html https://example.com
> ```

---

### 服务端日常管理速查

```bash
sudo systemctl status caddy        # 看状态
sudo systemctl restart caddy       # 重启
sudo systemctl reload caddy        # 改了 Caddyfile 后用
sudo journalctl -u caddy -f        # 实时看日志
sudo nano /etc/caddy/Caddyfile     # 改配置
caddy fmt --overwrite /etc/caddy/Caddyfile  # 格式化配置
```

---

## 3. 客户端接入

### 3.0 通用：节点 URL 格式

社区标准（DuckSoft 规范，被 sing-box / NekoBox / v2rayN 等都接受）：

```
naive+https://用户名:密码@域名:端口#备注名
```

实例：
```
naive+https://myuser:MyPassWord123@naive.example.com:443#NaiveProxy-备用
```

> **强烈建议**：用户名和密码**不要包含** `:` `@` `#` `/` `?`，否则要做 URL 编码，很容易出错。

把这个 URL 留好，4 种客户端都用得上。

---

### 3.1 sing-box（PC / 路由器，你最熟的）⭐ 主推

#### 关键前提

sing-box 的 naive 出站需要带 `with_naive` 编译标签的版本。
**官方 release 默认不带**——你需要从 [sing-box releases](https://github.com/SagerNet/sing-box/releases) 下载 **glibc 或 musl 标记**的版本（比如 `sing-box-1.x.x-linux-amd64.tar.gz`）。

> Windows 上无脑用 Nekoray（见 3.2），sing-box 走 Linux/路由器更合适。

#### 配置示例

打开你 sing-box 的配置文件（一般 `/etc/sing-box/config.json`），在 `outbounds` 数组里加这一段：

```json
{
  "type": "naive",
  "tag": "naive-out",
  "network": "tcp",
  "server": "naive.example.com",
  "server_port": 443,
  "username": "myuser",
  "password": "MyPassWord123",
  "tls": {
    "enabled": true,
    "server_name": "naive.example.com"
  }
}
```

字段说明：

| 字段 | 必填 | 说明 |
|---|---|---|
| `type` | ✅ | 固定写 `naive` |
| `server` | ✅ | 你的域名 |
| `server_port` | ✅ | 服务端端口（一般 443） |
| `username` / `password` | ✅ | 和服务端 `basic_auth` 一致 |
| `tls.server_name` | ✅ | 必须和 server 域名一致（SNI） |

把 `naive-out` 加到你 selector / urltest 的 outbounds 列表里就能用了。

#### 重启 sing-box

```bash
sudo systemctl restart sing-box
sudo journalctl -u sing-box -f   # 看日志
```

---

### 3.2 NekoBox / Nekoray（Android + Windows，强烈推荐）

下载：
- **Android**：[NekoBoxForAndroid releases](https://github.com/MatsuriDayo/NekoBoxForAndroid/releases) 找最新 `.apk`
- **Windows**：[Nekoray releases](https://github.com/MatsuriDayo/nekoray/releases) 找 `nekoray-x.x.x-windows64.zip`

#### 操作步骤（图文等价）

**方式 1：从剪贴板导入（最快）**
1. 复制你的 `naive+https://...` URL 到剪贴板
2. 打开 NekoBox → 顶部菜单 → **从剪贴板导入**
3. 自动添加节点 → 长按节点 → 启动

**方式 2：手动添加**
1. 右下角 `+` 号 → 选择 **NaiveProxy**
2. 填写：
   - **配置文件名**: 随便，比如 `备用-Naive`
   - **地址**: `naive.example.com`
   - **端口**: `443`
   - **用户名**: `myuser`
   - **密码**: `MyPassWord123`
   - **SNI**: `naive.example.com`（和地址一样）
3. 保存 → 选中 → 点左上角 **启动**
4. 浏览器打开 google.com 测一下

---

### 3.3 v2rayN（Windows 5.16+）

#### 步骤

1. **下载 NaiveProxy 二进制**（不是 v2rayN 的，是 NaiveProxy 自己的客户端）：
   [klzgrad/naiveproxy releases](https://github.com/klzgrad/naiveproxy/releases) → 选 `naiveproxy-vXXX-win-x64.zip`
2. 解压，把里面的 `naive.exe` 复制到 v2rayN 同目录
3. 在 v2rayN 任意位置创建 `naive-config.json`：
   ```json
   {
       "listen": "socks://127.0.0.1:1080",
       "proxy": "https://myuser:MyPassWord123@naive.example.com:443"
   }
   ```
4. v2rayN 顶部 **服务器** → **添加自定义服务器**
5. **Core 类型** 选 `naiveproxy`
6. **配置文件路径** 选刚才的 `naive-config.json`
7. **本地 Socks 端口** 填 `1080`
8. 确定 → 选中节点 → 系统代理设为"自动配置系统代理"

---

### 3.4 Shadowrocket（iOS）

1. 节点 → 右上角 `+`
2. **类型** 选 `NaiveProxy`
3. **主机**: `naive.example.com`
4. **端口**: `443`
5. **用户**: `myuser`
6. **密码**: `MyPassWord123`
7. 保存 → 切换到这个节点 → 主页面打开开关

---

## 4. 验证 & 排错

### 4.1 联通性自检表

在客户端连上后，分别打开：
- ✅ https://www.google.com（能开 = TLS 通了）
- ✅ https://chat.openai.com（能开 = 协议没被识别拦截）
- ✅ 走 https://ipinfo.io 看 IP 是 VPS 的 IP（确认走代理）

### 4.2 常见错误对照表

| 症状 | 可能原因 | 解决 |
|---|---|---|
| Caddy 启动失败 `failed to obtain certificate` | DNS 没解析 / Cloudflare 开了 CDN / 80 端口被占 | 关 CF 橙色云朵；`sudo lsof -i :80` 看占用 |
| Caddy 提示 `unknown directive: forward_proxy` | 没装带插件版 Caddy | 重做方案 B 步骤 B2，确认 `caddy list-modules` 有 forward_proxy |
| 客户端连不上，提示 `407 Proxy Authentication Required` | 用户名或密码错 | 双方对一遍；密码是否含特殊字符 |
| 客户端连不上，提示 `tls handshake error` | SNI 不对 / 证书过期 | 客户端 SNI 必须和域名一致 |
| 浏览器访问 https://域名 报警告 | 证书没申请成功 | `sudo journalctl -u caddy --since today` 看错误 |
| 时通时断 | VPS 网络抖 | 装 BBR（见下） |

### 4.3 装 BBR 加速（可选但推荐）

```bash
echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
sudo sysctl net.ipv4.tcp_congestion_control
# 输出 bbr 就成功了
```

---

## 5. 安全 / 维护建议

| 项目 | 频率 | 命令 / 做法 |
|---|---|---|
| 更新系统 | 每月 | `sudo apt update && sudo apt upgrade -y` |
| 更新 Caddy | 每月 | 同上（apt 装的会自动跟进） |
| 换密码 | 每 3-6 月 | 改 Caddyfile → `systemctl reload caddy` → 客户端同步 |
| 看异常日志 | 每周 | `sudo journalctl -u caddy --since '1 week ago' \| grep -iE 'error\|fail'` |
| 备份 Caddyfile | 改完就备份 | `cp /etc/caddy/Caddyfile ~/Caddyfile.backup.$(date +%F)` |
| 看证书是否快到期 | Caddy 自动续，无需操作 | — |

### 安全红线

- 🚫 **绝对不要**把这台 NaiveProxy VPS 的 IP 公开发到任何地方（论坛、TG 群、issue）
- 🚫 **绝对不要**用 freenom / 临时邮箱注册的域名
- 🚫 **绝对不要**用弱密码（`123456`、`password`、用户名相同）
- ✅ 配置完后把 Caddyfile 加密备份到本地
- ✅ 把这份指南也存一份本地，墙真高了好快速重建

---

## 附录 A：完整 Caddyfile 模板（一键复制）

```caddyfile
{
  order forward_proxy before file_server
  log {
    exclude http.log.error
  }
}

:443, naive.example.com {
  tls your-email@gmail.com
  encode
  forward_proxy {
    basic_auth myuser MyPassWord123
    hide_ip
    hide_via
    probe_resistance
  }
  file_server {
    root /var/www/html
  }
}
```

> **多用户版**：把 `forward_proxy` 块复制一份，改 `basic_auth` 即可，但更推荐多个用户用不同 VPS。

---

## 附录 B：sing-box 完整 outbound 模板

```json
{
  "type": "naive",
  "tag": "naive-out",
  "network": "tcp",
  "server": "naive.example.com",
  "server_port": 443,
  "username": "myuser",
  "password": "MyPassWord123",
  "tls": {
    "enabled": true,
    "server_name": "naive.example.com",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    }
  }
}
```

> **注意**：sing-box 官方文档说 `naive` 出站用的是 Chromium 自己的网络栈，`utls` 字段对 naive 出站**实际不生效**——但写上无害，可作为兼容性保险。

---

## 附录 C：跟主线 leyili.sh 协同建议

| 场景 | 用哪个 |
|---|---|
| 日常 | 主线 VLESS+Vision+Reality（leyili.sh 部署的） |
| 主线被针对、连不上时 | 切到这台 NaiveProxy |
| 完全黑天鹅（所有协议被封） | NaiveProxy 仍是最后一线生机 |

**双 VPS 拓扑建议：**
```
郑州 → [主线 VPS, Reality, 高速] → 互联网    ← 90% 时间用这个
       ↓ 不通时
郑州 → [备用 VPS, NaiveProxy, 抗审查] → 互联网  ← 10% 兜底
```

把这两个节点都加到 sing-box 的 `selector`，墙紧了手动切就行。

---

## 参考来源

**官方权威：**
- [klzgrad/naiveproxy 官方仓库](https://github.com/klzgrad/naiveproxy)
- [klzgrad/forwardproxy（@naive 分支）](https://github.com/klzgrad/forwardproxy)
- [NaiveProxy 中文 Wiki](https://github.com/klzgrad/naiveproxy/wiki/简体中文)
- [sing-box naive 出站官方文档](https://sing-box.sagernet.org/configuration/outbound/naive/)
- [Arch Wiki NaïveProxy 条目](https://wiki.archlinux.org/title/Na%C3%AFveProxy)

**社区脚本与规范：**
- [crazypeace/naive 一键脚本](https://github.com/crazypeace/naive)
- [DuckSoft 提出的 NaiveProxy URI 规范](https://gist.github.com/DuckSoft/ca03913b0a26fc77a1da4d01cc6ab2f1)
- [RayWangQvQ/naiveproxy-docker（Docker 备选）](https://github.com/RayWangQvQ/naiveproxy-docker)

**客户端：**
- [NekoBoxForAndroid](https://github.com/MatsuriDayo/NekoBoxForAndroid/releases)
- [Nekoray (Windows)](https://github.com/MatsuriDayo/nekoray/releases)
- [v2rayN (Windows)](https://github.com/2dust/v2rayN/releases)

---

> **最后一句话：**
> 这份指南最大的价值不是教你装 NaiveProxy，而是告诉你"主线断了不至于裸奔"。
> 部署完之后，**至少跑一次客户端测试**，让备用线路保持随时可用。
> 真到了"墙加高"的那一天，你会感谢今天的自己。
