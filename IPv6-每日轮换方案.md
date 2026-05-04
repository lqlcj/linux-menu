# IPv6 每日轮换方案：AnyIP + Privacy Extensions + DNS 轮换

> **状态**：📋 待验证 · 未在生产 VPS 上实测
> **创建日期**：2026-05-04
> **目的**：让 XXX看到的「目的 IP」和「源 IP」都在持续变化，使长期画像数据失效
> **使用前必读**：本文档所有结论需要你自己查证 RFC / Linux 官方文档 / 生产案例后再决定是否实施

---

## 0. 为什么写这份文档

普通玩法：一台 VPS = 一个 IPv6 地址。GFW 把这个地址记下来 30 天，画像就成形了。

进阶玩法：**让一台 VPS 持有整个 /64**（约 1.84×10^19 个地址），客户端每次连不同地址，配合域名 AAAA 每日轮换，配合客户端系统层的 Privacy Extensions 自动换源 IP。

→ GFW 的画像数据库 24 小时全部失效。
→ 你不换 VPS、不动 Reality 配置，地址自动变。

听起来像玄学，**但所有底层技术都是公开标准 + Linux 内核原生支持**。下面逐条列出来源，你自己查。

---

## 1. 三层架构总览

```
┌─────────────────────────────────────────────────┐
│ 层 1：VPS 端 AnyIP 路由                          │
│       一行 ip route 命令让 VPS 持有整个 /64      │
│       核心收益：目的 IP 视角无穷大               │
├─────────────────────────────────────────────────┤
│ 层 2：客户端 IPv6 Privacy Extensions             │
│       OS 默认行为，每 24h 轮换源地址             │
│       核心收益：源 IP 视角持续变化               │
├─────────────────────────────────────────────────┤
│ 层 3：DNS AAAA 记录每日轮换                       │
│       cron + Cloudflare API，60s TTL             │
│       核心收益：客户端每天拿到不同入口 IP        │
└─────────────────────────────────────────────────┘
```

---

## 2. 层 1：AnyIP 详解（核心，需重点验证）

### 2.1 什么是 AnyIP

Linux 内核支持一种叫 **local route** 的特殊路由类型。
执行：

```bash
ip -6 route add local 2001:db8::/64 dev lo
```

之后，**任何发往该 /64 内任意地址的数据包**，内核都会当作"发给本机"处理。

→ 网卡上不需要绑这些地址。
→ Reality 监听 `[::]:443` 即可接受 /64 内全部 2^64 个地址 + 443 端口的连接。

### 2.2 这个特性的官方来源

需要你查证的官方资料：

| 资料 | 用途 | 查找方法 |
|---|---|---|
| `ip-route(8)` man page | Linux 官方文档，看 `TYPE` 章节里的 `local` | 在任何 Linux 上执行 `man ip-route`，搜索 `local` |
| Linux 内核源码 `net/ipv6/route.c` | 看 `RTN_LOCAL` 的处理逻辑 | https://github.com/torvalds/linux/blob/master/net/ipv6/route.c |
| `iproute2` 项目源码 | 命令行工具实现 | https://git.kernel.org/pub/scm/network/iproute2/iproute2.git |

**关键术语用于搜索**：
- `linux ip route local`
- `linux anyip`
- `RTN_LOCAL ipv6`

### 2.3 生产环境真实使用案例（强证据）

这不是冷门技巧，**Cloudflare 用它给上百万客户提供服务**：

- **Cloudflare 博客** "How we built Spectrum"（约 2018）
  - 描述 Cloudflare 如何用 AnyIP 让一台机器响应大量 IP
  - 搜索：`Cloudflare Spectrum AnyIP blog`
  - 也可看 Marek Majkowski（Cloudflare 网络工程师）的系列博客
- **Fastly / Akamai** 的 anycast 边缘节点也广泛使用类似技术
- **GitHub** 上搜 `ip route add local` 能看到大量真实部署脚本

### 2.4 验证步骤（先在测试机上跑，别动生产 VPS）

```bash
# 步骤 1：在一台测试 VPS 上，确认是否拿到 /64
ip -6 addr show scope global
# 期望看到类似：inet6 2a01:4f9:c011:1234::1/64

# 步骤 2：启用 AnyIP（不会破坏现有服务）
ip -6 route add local 2a01:4f9:c011:1234::/64 dev lo

# 步骤 3：从外部任意一台机器（比如另一台 VPS、家用电脑）测试
# ping 一个你「没有给网卡分配」的地址
ping6 2a01:4f9:c011:1234::deadbeef
# 如果通了 → AnyIP 生效 ✅
# 如果不通 → 你 VPS 商家不允许，或者上游路由器没把 /64 路由给你

# 步骤 4：撤销（恢复原状）
ip -6 route del local 2a01:4f9:c011:1234::/64 dev lo
```

### 2.5 已知会失败的场景

⚠️ **不是所有 VPS 都能用 AnyIP**：

| 场景 | 现象 | 是否可用 |
|---|---|---|
| VPS 商分配独立 /64 + routed 模式 | `ping6 任意 /64 内地址` 通 | ✅ 可用 |
| VPS 商分配 /64 但要求 NDP 邻居发现 | 只有网卡上绑的地址能 ping 通 | ❌ 不可用 |
| VPS 商分配 /112、/120 | 地址空间太小，AnyIP 失去意义 | ❌ 不可用 |
| VPS 商分配单个 /128 | 没法玩 | ❌ 不可用 |

**已知给 routed /64 的商家**（需要你自己再次验证当前政策）：
- Vultr
- Linode / Akamai Cloud
- DigitalOcean
- Hetzner Cloud
- BuyVM
- Netcup

**已知不给或共享 /64 的**：部分国内系小商家、部分按 /128 分配的廉价机房。

→ **必须自己 ping 验证**，别看商家页面宣传。

---

## 3. 层 2：IPv6 Privacy Extensions

### 3.1 RFC 标准（强证据）

| RFC | 标题 | 状态 | 链接 |
|---|---|---|---|
| **RFC 4941** | Privacy Extensions for Stateless Address Autoconfiguration in IPv6 | 已被 8981 取代 | https://datatracker.ietf.org/doc/html/rfc4941 |
| **RFC 8981** | Temporary Address Extensions for Stateless Address Autoconfiguration in IPv6 | **当前标准（2021-02）** | https://datatracker.ietf.org/doc/html/rfc8981 |

**RFC 8981 关键内容**：
- 客户端应自动生成临时 IPv6 地址
- 默认 `PREFERRED_LIFETIME` = 86400s（1 天，过后生成新临时地址）
- 默认 `VALID_LIFETIME` = 604800s（7 天，老地址在此之前仍可接收入站）
- 出站连接优先使用最新临时地址

### 3.2 各操作系统支持情况

| 系统 | 默认状态 | 控制方式 |
|---|---|---|
| Windows 10/11 | ✅ 默认启用 | `netsh interface ipv6 show privacy` |
| macOS / iOS | ✅ 默认启用 | 系统层无 UI 控制，默认行为 |
| Linux | ⚠️ 多数发行版默认未启用 | `sysctl net.ipv6.conf.*.use_tempaddr` |
| Android | ✅ 4.0+ 默认启用 | 无 UI 控制 |

### 3.3 验证步骤

**Windows（管理员 PowerShell）**：
```powershell
netsh interface ipv6 show privacy
# 期望：State=enabled

# 强制启用（如未开）
netsh interface ipv6 set privacy state=enabled
netsh interface ipv6 set global randomizeidentifiers=enabled
```

**Linux**：
```bash
sysctl net.ipv6.conf.all.use_tempaddr
# 0 = 关闭（很多发行版默认）
# 1 = 启用但不优先使用
# 2 = 启用且优先使用 ← 推荐

# 启用
echo "net.ipv6.conf.all.use_tempaddr=2" | sudo tee -a /etc/sysctl.conf
echo "net.ipv6.conf.default.use_tempaddr=2" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# 查看当前临时地址
ip -6 addr show | grep -E "temporary|mngtmpaddr"
```

**macOS**：默认就是开的，命令行无标准查看方式。可以用：
```bash
ifconfig en0 | grep "inet6.*temporary"
```
应该能看到 `temporary` 标记的地址。

### 3.4 调整轮换频率（可选）

**默认 24 小时**轮换。想更激进可以缩短：

```bash
# Linux 例：每 6 小时轮换一次新地址
echo "net.ipv6.conf.all.temp_prefered_lft=21600" | sudo tee -a /etc/sysctl.conf
echo "net.ipv6.conf.all.temp_valid_lft=86400" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

⚠️ **不推荐设太短**（< 1h），会跟正常用户行为差异变大，反而成为指纹特征。

---

## 4. 层 3：DNS AAAA 每日轮换

### 4.1 原理

客户端 Reality 配置不写死 IP，写域名 `reality.your-domain.com`。
后台 cron 每天凌晨用 Cloudflare API 把这个域名的 AAAA 记录改成 /64 内随机一个地址。
TTL 设为 60-300 秒，客户端每次连接前都会重新解析。

### 4.2 实现脚本

`/usr/local/bin/rotate-aaaa.sh`：

```bash
#!/bin/bash
set -euo pipefail

PREFIX="2a01:4f9:c011:1234"  # ← 改成你的 /64 前缀（不带 :: 后缀）
DOMAIN="reality.your-domain.com"
ZONE_ID="<填 Cloudflare Zone ID>"
RECORD_ID="<填 AAAA Record ID>"
CF_TOKEN="<填 Cloudflare API Token，权限只给 DNS:Edit>"

# 生成 /64 内随机地址（64 位主机部分 = 16 个 hex 字符）
HEX=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
NEW_ADDR="${PREFIX}:${HEX:0:4}:${HEX:4:4}:${HEX:8:4}:${HEX:12:4}"

# 调用 Cloudflare API
RESP=$(curl -s -X PUT \
  "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "{\"type\":\"AAAA\",\"name\":\"${DOMAIN}\",\"content\":\"${NEW_ADDR}\",\"ttl\":300,\"proxied\":false}")

if echo "$RESP" | grep -q '"success":true'; then
    echo "$(date -Iseconds): rotated to ${NEW_ADDR}"
else
    echo "$(date -Iseconds): FAILED: ${RESP}" >&2
    exit 1
fi
```

cron 配置（每天 4:13 执行，避开整点和半点）：
```bash
chmod +x /usr/local/bin/rotate-aaaa.sh
echo "13 4 * * * root /usr/local/bin/rotate-aaaa.sh >> /var/log/rotate-aaaa.log 2>&1" | sudo tee /etc/cron.d/rotate-aaaa
```

### 4.3 Cloudflare API 文档（用于验证）

- 官方 API 文档：https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/edit/
- API Token 权限：仅勾选 `Zone:DNS:Edit`，限定到具体 Zone
- 关键端点：`PUT /zones/{zone_id}/dns_records/{record_id}`

### 4.4 验证步骤

```bash
# 验证脚本
/usr/local/bin/rotate-aaaa.sh
# 然后查 DNS
dig AAAA reality.your-domain.com +short
# 第二天执行后再查，应该是不同地址
```

---

## 5. 综合效果评估

### 5.1 对 GFW 画像的影响

| 维度 | 不轮换 | 三层全开 |
|---|---|---|
| GFW 看到的目的 IP 数（30 天） | 1 | 30 |
| 单 IP 累积观察时间 | 30 天 | 1 天 |
| 客户端源 IP（30 天） | 1 | 30 |
| 5 元组重复率 | 极高 | 极低 |
| 行为画像收敛性 | 30 天稳定 | 永远收敛不上 |
| 一次封禁能影响的连接数 | 全部 | 当日的 1/30 |

### 5.2 对你日常体验的影响

- 客户端：**零感知**（域名连接，DNS 自动解析新 IP）
- 服务端：**零维护**（cron 自动跑）
- 故障率：cron 失败时域名指向旧 IP，老地址在 7 天内仍能接 Reality 入站（RFC 8981 给的 `VALID_LIFETIME`）

---

## 6. 风险与坑（部署前必读）

### 6.1 不会变好的情况

- 你 VPS 没真 /64 → 整套方案失效，先验证再说
- 国内运营商对 IPv6 出境流量做了 NAT64 → 你看到的源 IP 是运营商的，Privacy Extensions 失效
- 客户端代理软件不查 DNS（直接连 IP）→ 层 3 失效

### 6.2 可能踩的坑

| 坑 | 现象 | 排查 |
|---|---|---|
| AnyIP 启用后 VPS 商告警 | 商家邮件警告"异常 IP 使用" | 改用更宽容的商家（Vultr/BuyVM 暂未听说） |
| Cloudflare API Token 泄露 | 域名被恶意改 | Token 只给 DNS:Edit，且限定具体 Zone |
| cron 失败导致 DNS 长期不变 | 连续多日同一 IP | 加监控告警，或 cron 跑两次（凌晨 + 中午）不同时段 |
| /64 整段被 GFW 封 | Reality 连不上 | 换 VPS 商，整段重置 |
| Reality dest 与你的 /64 地理矛盾 | 主动探测时被怀疑 | dest 选目标 IP 在同地理区域的大型 CDN |

### 6.3 法律与合规

- VPS 商家的 ToS 大多不禁止"使用整个分配的 /64"
- 但**滥用可能触发反滥用系统**（如对外扫描、攻击）
- 用于 Reality 入站这种纯监听场景，没听说有商家投诉案例

---

## 7. 我自己要查证的清单（在动 VPS 之前）

- [ ] 在 Linux 测试机上跑 `man ip-route`，确认 `local` 路由类型存在
- [ ] 读 RFC 8981 至少前 5 页，确认临时地址机制描述
- [ ] Google 搜索 "Cloudflare AnyIP" 看 Cloudflare 官方博客
- [ ] 在我自己一台不重要的 VPS 上做 2.4 节验证步骤，从家里 ping 通任意 /64 地址
- [ ] 在我电脑上跑 3.3 节验证，确认 Privacy Extensions 已开
- [ ] 申请一个测试域名 + Cloudflare Zone，跑通 4.2 节脚本
- [ ] 抓包确认：客户端连接时目的 IP 真的是当日 AAAA 解析的那个
- [ ] 重启 VPS 验证 AnyIP 持久化（systemd service）真的生效

完成上述全部 ✅ 之后，再考虑改造 `leyili.sh`。

---

## 8. 完整参考资料

### 标准与 RFC
- RFC 8981 (当前) — Temporary Address Extensions for SLAAC: https://datatracker.ietf.org/doc/html/rfc8981
- RFC 4941 (历史) — Privacy Extensions: https://datatracker.ietf.org/doc/html/rfc4941
- RFC 4291 — IPv6 Addressing Architecture: https://datatracker.ietf.org/doc/html/rfc4291

### Linux 文档
- `ip-route(8)` man page（系统自带）
- Linux Networking documentation: https://docs.kernel.org/networking/
- Linux 内核 IPv6 路由源码: https://github.com/torvalds/linux/tree/master/net/ipv6

### 生产案例
- Cloudflare 工程博客（搜索 AnyIP / Spectrum）: https://blog.cloudflare.com/
- Marek Majkowski 的网络底层文章（Cloudflare 工程师）

### Reality 协议
- Xray-core Reality 文档: https://github.com/XTLS/Xray-core
- sing-box Reality 文档: https://sing-box.sagernet.org/

### Cloudflare API
- DNS Records API: https://developers.cloudflare.com/api/resources/dns/

### IPv6 工具
- 在线 IPv6 ping 测试: https://ipv6-test.com/
- 在线 IPv6 prefix 计算器: https://www.calculator.net/ip-subnet-calculator.html

---

## 9. 如果以上全验证通过，对 leyili.sh 的改造范围

**仅供参考，先别动代码**：

1. 新增菜单项：`IPv6 AnyIP 模式（开启/关闭/状态）`
2. 新增检测函数：自动识别本机 /64 前缀
3. 新增持久化：写一个 `anyip.service` systemd 单元
4. 修改 inbound 生成器：IPv6 入站 listen 字段强制为 `::`
5. 新增菜单项：`配置 DNS AAAA 自动轮换`
6. 新增辅助函数：随机 v6 地址生成器（在 /64 内）
7. 新增菜单项：`轮换状态查看`（cron 日志、当前 AAAA、AnyIP 路由表）

代码量预估：~150-200 行 Bash，对你现有脚本风格友好。

---

## 10. 一句话总结

> **AnyIP（Linux 原生）+ Privacy Extensions（RFC 标准）+ DNS 轮换（Cloudflare API）= 一台 VPS 在 GFW 眼里每天都是新人。**
>
> 全部技术都是公开 + 标准 + 生产验证过的，**唯一需要你做的是在你的 VPS 上验证商家是否分配了真正可路由的 /64**。

---

*本文档需要交叉验证后再使用，不要直接复制命令上生产 VPS。*
