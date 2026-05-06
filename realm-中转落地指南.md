# Realm 中转落地完整指南

> 给"网络小白"看的、不打哑谜的中转落地方案。
> 现在 leyili.sh 自己内置了 Realm 中转管理，无需另装其它脚本。

---

## 一、先理清三个名词

| 名词 | 干什么 | 在哪 |
|------|--------|------|
| **客户端** | 你手机/电脑上的 sing-box / v2rayN / Clash | 你家里 |
| **中转机 A** | 国内连接质量好的 VPS（也叫"前置机"） | 国内能连得快的机房 |
| **落地机 B** | 真正出网到 Google / YouTube 的 VPS | 海外机房（IP 干净） |

**为什么要中转？**

- B 的 IP 干净但线路差（绕路 / 丢包 / 国内连过去卡）
- A 的线路好但 IP 脏 / 被墙 / 不适合直接出网
- 让 A 给 B 当"加速通道"，国内 → A 走优质链路，A → B 走机房间高速线路

---

## 二、原理一句话总结

> **realm 是一根"傻瓜水管"**：客户端往 A:443 灌进来什么字节，realm 就把这堆字节原样吐到 B:443。加密是客户端和 B 之间的事，realm 完全不参与。

```
客户端 ──Reality加密──▶ A(realm 字节搬运) ──同一段密文原样转发──▶ B(sing-box 解密) ──▶ 互联网
                              ↑
                       A 不解密、不知道在传啥
```

所以：

- 客户端配置里的 `IP` 要写 **A 的 IP**
- 客户端配置里的 `SNI / pbk / shortId / UUID` 要全部用 **B 的**
- A 上**不需要**有 sing-box 节点 / UUID

---

## 三、三步搭建（保姆级）

### 步骤 1：B 落地机（你已有的 VPS）

照常用 `leyili.sh`：

```bash
sb           # 进主菜单
3            # 节点 / 内核管理
1            # 创建节点（选 Reality 或 Hysteria2）
```

装完回主菜单 `5 → 7` 复制客户端链接，长这样：

```
vless://uuid@B的IP:443?security=reality&pbk=xxx&sni=www.tesla.com&sid=abc#B-Reality
```

把 **B 的 IP、端口、UUID、pbk、sni、sid** 记下来备用。

> **防火墙提示**：如果 B 的 iptables 限制了来源 IP，记得放行 A 的 IP 访问 B 的对应端口。在 `leyili.sh` 的防火墙菜单里加白名单即可。

---

### 步骤 2：A 中转机（也跑 leyili.sh）

A 机器**只需要装本脚本**，不需要装 sing-box 节点。

```bash
sb           # 进主菜单
4            # Realm 中转管理
1            # 安装 Realm
```

安装完成（约 5 秒），继续：

```bash
2            # 添加转发规则
```

按提示输入：

| 配置项 | 填什么 |
|--------|--------|
| **本机监听端口** | `443`（A 对外暴露的端口，可换） |
| **落地机 IP** | `B 的 IP`（IPv4 / IPv6 都行，IPv6 会自动加方括号） |
| **落地机端口** | `443`（B 上 Reality / Hysteria2 的端口） |
| **监听地址类型** | `1`（双栈监听，推荐）或 `2`（仅 v4） |

脚本会自动：

- 写入 `/etc/realm/config.toml`
- 用 iptables 放行 TCP+UDP 端口（v4+v6）
- 重启 realm 服务

检查（脚本里也能看到）：

```bash
systemctl status realm     # 应该 active (running)
ss -tlnp | grep 443        # 应该看到 realm 在监听
```

---

### 步骤 3：客户端配置

把 B 给的链接里的 **IP 部分改成 A 的 IP**，**所有其它字段（pbk/sni/sid/uuid/端口）保持不变**：

```diff
- vless://uuid@B的IP:443?security=reality&pbk=xxx&sni=www.tesla.com&sid=abc#B-Reality
+ vless://uuid@A的IP:443?security=reality&pbk=xxx&sni=www.tesla.com&sid=abc#经A中转
```

导入到 v2rayN / sing-box 客户端，连上访问 [ipify.org](https://api.ipify.org)：

- **看到 B 的 IP** → 链路通了 ✓
- **看到 A 的 IP** → 转发没生效（多半是 A 的端口被防火墙挡了）
- **连不上** → 看下面"常见坑"

---

## 四、Realm 菜单完整说明

进入 `sb → 4) Realm 中转管理`，有 8 个子项：

| 序号 | 子菜单项 | 用途 |
|------|---------|------|
| 1 | 安装 Realm | 下载二进制 + 写 systemd + 起服务（首次必选） |
| 2 | 添加转发规则 | 交互式输入，含端口占用检测 + 自动放行防火墙 |
| 3 | 查看规则 / 服务状态 | 列出所有规则 + 当前 systemd 状态 |
| 4 | 删除单条规则 | 输入编号删除，自动撤销对应防火墙端口 |
| 5 | 清空全部规则 | 一键清空，撤所有防火墙端口 |
| 6 | 重启 realm 服务 | 改完配置或排错时用 |
| 7 | 查看实时日志 | 等价 `journalctl -u realm -f`，Ctrl+C 退出 |
| 8 | 卸载 Realm | 完全清理：停服 + 删二进制 + 删配置 + 撤防火墙 |

---

## 五、常见坑

### 1. 客户端 SNI / pbk 写成了 A 的

**症状**：握手失败 / TLS error

**原因**：Reality 是端到端加密，握手发生在客户端 ↔ B 之间，A 只是字节搬运工。如果你把客户端 SNI 改成 A 的域名，B 收到的 ClientHello 就对不上 B 自己的 Reality 配置了。

**记住**：除了 IP/端口，其他字段全部用 B 的。

---

### 2. UDP 协议（Hysteria2）不通

**症状**：Reality 能用，Hysteria2 不通

**原因**：Hysteria2 走 UDP。

**修法**：本脚本默认 TCP+UDP 双协议都开（`use_udp = true`），且防火墙同时放行两个协议。如果不通，先看防火墙：`iptables -L INPUT -n | grep <端口>` 应该既有 tcp 又有 udp 的 ACCEPT。

---

### 3. B 的防火墙挡了 A

**症状**：A 上 `realm` 启动正常，但客户端连不上 / 报 timeout

**排查**：

```bash
# 在 A 上测试能否连到 B
nc -zv B的IP 443
# 不通就是 B 的防火墙拦了
```

在 `leyili.sh` 的防火墙菜单里给 B 放行 A 的 IP，或者把 A 的 IP 加白名单。

---

### 4. 自连环（落地 IP 填成了本机）

**症状**：流量在本机反复转发，CPU 跑满

**避免**：本脚本 menu_add 暂未做这个检测，请你**手动确认落地 IP 不是中转机自己**。

---

### 5. 中转机 IP 被墙了

**现象**：某一天突然 A 全部不通，但 B 直连还能用

**说明**：A 暴露的就是普通 TCP 端口，被探测封掉的概率比直连低，但仍然存在。换 IP 或加多条转发规则到不同的 B 即可。

---

### 6. 端口已被占用

**症状**：选 `2) 添加转发规则` 时报 `端口 X 已被本机其它进程占用`

**说明**：本脚本会用 `ss` 事前检测，避免加完规则才发现起不来。换个端口即可。

---

## 六、本脚本 vs 其它 Realm 一键脚本

我们的 Realm 菜单只做"够用就好"：

| 功能 | 本脚本（leyili.sh） | playfulsoul/realm-installer | zywe03/realm-xwPF |
|------|---------------------|------------------------------|---------------------|
| 安装/卸载 | ✓ | ✓ | ✓ |
| 添加规则 | ✓（含端口占用检测） | ✓ | ✓ |
| 查看规则列表 | ✓（带编号表格） | 仅 cat 配置 | ✓ |
| 删除单条 | ✓ | ✗（要手改 toml） | ✓ |
| 清空规则 | ✓ | ✗ | ✓ |
| iptables 防火墙 | ✓（复用脚本既有） | ✗（用 ufw） | ✓ |
| 双栈监听选择 | ✓（v4+v6 / 仅 v4） | ✗（仅 v4） | ✓ |
| 负载均衡 | ✗ | ✗ | ✓ |
| 故障转移 | ✗ | ✗ | ✓ |
| WSS+TLS 隧道 | ✗ | ✗ | ✓ |
| 端口段转发 | ✗ | ✗ | ✓ |

**什么时候装 realm-xwPF 而不是本脚本？**

- 需要多落地负载均衡 / 故障转移
- 需要端口段（一次性转一段如 `10000-10100`）
- 需要 WSS 加密隧道再套一层伪装

**绝大多数个人用户场景，本脚本的 Realm 菜单就够了。**

---

## 七、总结：什么场景用什么方案

| 场景 | 方案 | 备注 |
|------|------|------|
| **A 和 B 都用同一种协议（最常见）** | **leyili.sh → 4) Realm 中转管理** | 透传，性能最好 |
| **想隐藏 B 的 IP 又不想多租 VPS** | Cloudflare CDN（限 WS+TLS 协议） | 代价是速度受 CDN 影响 |
| **多落地、要负载均衡 / 故障转移** | realm-xwPF | 自带健康检查 |

---

## 参考资料

- realm 原项目：<https://github.com/zhboner/realm>
- realm-xwPF（功能更全的一键脚本）：<https://github.com/zywe03/realm-xwPF>
- LinuxDo 教程：<https://linux.do/t/topic/920558>
- sing-box 官方文档：<https://sing-box.sagernet.org/configuration/>
