# leyili.sh IPv6 Reality 一键轮换 —— 实施方案

> **状态**：📋 方案设计完成 · 待开发
> **创建日期**：2026-05-04
> **目标版本**：基于当前 `leyili.sh`（8162 行）增量开发
> **决策已锁定**：硬切换（无软过期）+ 不动现有逻辑

---

## 1. 文档目的

为 `leyili.sh` 新增「IPv6 Reality 一键轮换」功能。本文档：
- 锁定功能边界与设计决策
- 给出完整的状态机、数据结构、函数清单
- 列出与现有代码的接触面（确保零破坏）
- 提供开发前必须确认的细节问题
- 提供开发完成后的验收测试清单

**不在本文档范围**：代码本身。本文档目的是让我们按图施工，避免开发过程中临时拍脑袋。

---

## 2. 已完成的可行性验证（2026-05-04）

| 验证项 | 结果 | 证据 |
|---|---|---|
| GreenCloud 给的是真 /64 | ✅ | `inet6 2a12:a304:4:9b8::a/64 scope global` |
| 可绑定 /64 内任意地址 | ✅ | `ip -6 addr add 2a12:a304:4:9b8:aaaa:bbbb:cccc:dddd/64 dev eth0` 成功 |
| 外部可 ping 绑定地址 | ✅ | 家用电脑 ping 4 包全通，~100ms |
| Reality 在新地址响应 | ✅ | `curl` 返回 `SEC_E_ILLEGAL_MESSAGE`（Reality 拒绝非法 TLS，符合预期） |
| AnyIP 路由可用 | ❌ | 未绑定地址 ping 全部超时（NDP 邻居发现限制） |

**结论**：方案 B（绑定/解绑具体地址）100% 可用。AnyIP 不可用，本方案不依赖。

---

## 3. 设计原则（最高优先级）

### P0 · 不动现有逻辑
- **不修改** `leyili.sh` 任何已有函数
- **不修改** sing-box 现有 inbound 配置（包括 `listen` 字段）
- **不修改** 现有节点的 `info` 文件
- **不修改** 现有菜单项的编号与文案
- **不修改** 全局变量（仅**读取** `CONFIG_PATH`、`NODES_DIR` 等）
- **不修改** 防火墙规则（继续复用 8443 端口的现有放行规则）

### P1 · 硬切换语义
- 任何时刻，**最多** 1 个轮换地址绑定在 eth0
- 用户点"轮换" → 旧轮换地址**立即解绑**、新地址绑定、新链接输出
- 旧链接**立刻失效**（30 秒内 TCP 连接被 RST）
- **原始地址 `::a` 永远保留**，原始 URL 永远可用（这是"现有逻辑"的一部分）

### P2 · 零外部依赖增量
- 仅使用脚本已有依赖：`bash`、`ip`、`jq`、`/dev/urandom`
- 不引入 `qrencode` 等新依赖（二维码不渲染，仅输出文本 URL）
- 不引入 `python`、`curl` API 调用等

### P3 · 状态独立持久化
- 状态文件存放在**独立目录**：`/etc/sing-box/ipv6-rotation/`
- 不污染 `NODES_DIR`（`/etc/sing-box/nodes/`）
- 卸载本功能 = 删除该目录 + 解绑当前地址，零残留

### P4 · 重启即重置（默认）
- 不写 systemd unit 持久化绑定
- 重启 VPS 后轮换地址消失，原始 `::a` 仍工作
- 用户重启后从菜单"立即轮换"一键重建即可

---

## 4. 功能边界

### 做什么

| ID | 功能 | 说明 |
|---|---|---|
| F1 | 立即轮换 | 替换当前轮换地址为新随机地址，输出新 URL |
| F2 | 查看当前 | 显示当前轮换地址、绑定时间、对应 URL |
| F3 | 重置 | 解绑当前轮换地址，回到"无轮换"状态 |
| F4 | 状态健康检查 | 检测 state.json 与 eth0 实际状态是否一致 |

### 不做什么（明确排除）

| 排除项 | 理由 |
|---|---|
| 软过期 / 多地址并存 | 用户明确选择硬切换 |
| 持久化（重启保留） | 用户选择重启即重置 |
| AnyIP 模式 | GreenCloud 不支持，已验证 |
| DNS AAAA 自动轮换 | 不在本期范围（参考 `IPv6-每日轮换方案.md` 层 3） |
| 修改 sing-box `listen` 字段 | 违反 P0 原则 |
| 同时轮换 hy2 / anytls | 用户仅要求 Reality（hy2/anytls 若 listen `::`，会被动获益但不主动支持） |
| 二维码渲染 | 违反 P2 原则 |
| 多 Reality 节点选择 | 假设仅 1 个 IPv6 Reality；多节点场景报错提示 |
| Web UI / 远程控制 | 超出脚本范围 |

---

## 5. 状态机

```
                    [INIT]
                  无轮换地址
                      │
                      │ 立即轮换 (F1)
                      ▼
              ┌──────────────────┐
              │   [ROTATED]      │
              │ 1 个轮换地址在    │
              │ eth0 上          │ ◄──┐
              └──────────────────┘    │
                      │                │
                      ├────────────────┘
                      │  立即轮换 (F1)
                      │  → 解绑旧、绑定新
                      │
                      │ 重置 (F3)
                      ▼
                    [INIT]
```

**所有状态下 `2a12:a304:4:9b8::a` 保持绑定**（属于"现有逻辑"）。

---

## 6. 用户交互流程

### 6.1 流程：F1「立即轮换」

```
用户点击 "IPv6 Reality 地址轮换" → "1. 立即轮换"
   ↓
[前置检查]
   ├─ sing-box 已安装？ (require_singbox_installed)
   ├─ 存在 reality-in inbound？ (jq 查 CONFIG_PATH)
   ├─ reality-in 的 listen 是 "::" ？
   ├─ /64 前缀可探测？
   └─ eth0 接口存在且 UP？
   ↓ 任一失败 → 友好错误提示 + pause_screen + 返回菜单
   ↓ 全部通过
[读取 Reality 配置]
   port、UUID、public_key、short_id、server_name、flow
   （短 ID 可能是数组，取第一个）
   ↓
[读取或初始化 state.json]
   ├─ 存在 → 读 current_rotated
   └─ 不存在 → 初始化空状态
   ↓
[生成新地址]
   ├─ 从 eth0 解析 /64 前缀（缓存到 state）
   └─ 用 /dev/urandom 生成 64 位主机部分
   ↓
[执行解绑+绑定]
   ├─ if state.current_rotated:
   │     ip -6 addr del <旧>/64 dev eth0    （失败容忍，仅警告）
   ├─ ip -6 addr add <新>/64 dev eth0       （失败 → 回滚，报错）
   └─ 验证：ip -6 addr show 看到新地址
   ↓
[更新 state.json]
   原子写入（写 .tmp + mv）
   ↓
[生成 URL + 输出]
   render_divider
   render_section_header "✅ 轮换成功"
   render_info_line "新地址" "..."
   render_info_line "端口" "..."
   render_info_line "绑定时间" "..."
   echo "<vless URL>"
   render_info_line "提示" "旧链接已失效，请用新链接"
   render_divider
   pause_screen
```

### 6.2 流程：F2「查看当前」

```
[读 state.json]
   ↓
   ├─ 无状态 / current_rotated=null
   │     → 显示"当前未轮换，节点使用原始地址 ::a"
   │
   └─ 有状态
       ├─ 校验：ip -6 addr show 是否真有这个地址
       │   ├─ 一致 → 显示完整信息 + URL
       │   └─ 不一致（重启过？被其他人改过？）
       │       → 警告 "状态与实际不符，建议重置后重新轮换"
```

### 6.3 流程：F3「重置」

```
[确认提示]
   "将解绑当前轮换地址 <addr>，原始地址 ::a 不受影响。继续？(y/N)"
   ↓ y
[执行]
   ├─ ip -6 addr del <current>/64 dev eth0   （失败容忍）
   └─ 清空 state.current_rotated
   ↓
[输出]
   "已重置，节点已回退到原始地址 ::a 提供服务"
```

### 6.4 流程：F4「状态健康检查」

可作为 F2 的子动作或独立菜单项。检测：
- state.json 的 current_rotated 是否真在 eth0 上
- prefix 是否仍与 eth0 当前 /64 匹配（VPS 换 IP 段时会失配）
- reality-in inbound 是否仍存在

---

## 7. 状态文件设计

### 7.1 路径
```
/etc/sing-box/ipv6-rotation/state.json
/etc/sing-box/ipv6-rotation/state.json.bak    （写入前自动备份）
```

### 7.2 Schema

```json
{
  "version": 1,
  "prefix": "2a12:a304:4:9b8",
  "interface": "eth0",
  "node_snapshot": {
    "inbound_tag": "reality-in",
    "port": 8443,
    "uuid": "550e8400-e29b-41d4-a716-446655440000",
    "public_key": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "short_id": "01ab",
    "server_name": "www.apple.com",
    "flow": "xtls-rprx-vision"
  },
  "current_rotated": {
    "address": "2a12:a304:4:9b8:abcd:1234:5678:9abc",
    "created_at": "2026-05-04T19:30:00+08:00"
  }
}
```

### 7.3 字段语义

| 字段 | 含义 | 何时更新 |
|---|---|---|
| `version` | schema 版本，未来升级用 | 仅初始化时写 |
| `prefix` | /64 前缀（不含 `::` 和后缀） | 每次轮换前从 eth0 重新探测 |
| `interface` | 物理网卡名 | 初始化时写，假设固定 |
| `node_snapshot` | Reality 配置快照 | 每次轮换前从 sing-box 配置重新读取并刷新 |
| `current_rotated.address` | 当前活动的轮换地址完整形式 | 轮换/重置时更新 |
| `current_rotated.created_at` | 绑定时间 ISO8601 | 轮换时写 |

`current_rotated = null` 表示无轮换，处于 INIT 状态。

### 7.4 原子写入策略
```
1. 读旧 state → 内存
2. 修改内存中的对象
3. jq 序列化到 state.json.tmp
4. mv state.json state.json.bak
5. mv state.json.tmp state.json
```
中途崩溃时 .bak 仍可用作恢复源。

---

## 8. 函数清单（命名对齐 leyili.sh 现有约定）

### 8.1 命名约定
- `snake_case`
- 域前缀：`ipv6_rotation_` 或缩写 `ipv6r_`
- 内部函数 / 工具函数 不使用 `function` 关键字（与现有风格一致）
- 复用现有 render/util 函数

### 8.2 完整函数清单

#### 探测与校验
| 函数名 | 职责 | 复用 |
|---|---|---|
| `ipv6_rotation_detect_prefix` | 从 `ip -6 addr show dev eth0` 解析 /64 前缀（去掉主机段） | — |
| `ipv6_rotation_detect_interface` | 探测 IPv6 全局地址所在网卡（默认 eth0，兜底自动） | — |
| `ipv6_rotation_check_prereqs` | 综合前置检查：sing-box / reality-in / listen=:: / 前缀可探测 | `require_singbox_installed`、`ensure_jq` |

#### 配置读取（只读，不修改 sing-box 配置）
| 函数名 | 职责 |
|---|---|
| `ipv6_rotation_read_reality_inbound` | 用 `jq` 查 `CONFIG_PATH` 中 `tag == "reality-in"` 的 inbound 完整对象 |
| `ipv6_rotation_extract_node_snapshot` | 从 inbound 提取 port/UUID/pbk/sid/sni/flow |
| `ipv6_rotation_get_listen` | 提取 `listen` 字段，校验是否为 `::` |

#### 状态文件管理
| 函数名 | 职责 |
|---|---|
| `ipv6_rotation_state_dir` | 返回 `/etc/sing-box/ipv6-rotation`，不存在则 mkdir |
| `ipv6_rotation_state_path` | 返回 state.json 完整路径 |
| `ipv6_rotation_state_load` | 读 state.json，不存在返回空模板 |
| `ipv6_rotation_state_save` | 原子写入（tmp + mv + bak） |
| `ipv6_rotation_state_init` | 写入 version=1 + 当前 prefix + node_snapshot 的初始 state |
| `ipv6_rotation_state_validate` | 校验 schema 完整性，损坏时备份并重建 |

#### 地址操作
| 函数名 | 职责 |
|---|---|
| `ipv6_rotation_random_host64` | 用 `od -An -tx1 -N8 /dev/urandom` 生成 16 位 hex，分组成 4×4 |
| `ipv6_rotation_compose_addr` | `${prefix}:${host64}` 拼接 |
| `ipv6_rotation_addr_bind` | `ip -6 addr add <addr>/64 dev <iface>`，捕获返回码 |
| `ipv6_rotation_addr_unbind` | `ip -6 addr del <addr>/64 dev <iface>`，失败仅警告 |
| `ipv6_rotation_addr_exists_on_iface` | `ip -6 addr show dev <iface>` 检测地址是否真在网卡上 |

#### URL 生成
| 函数名 | 职责 |
|---|---|
| `ipv6_rotation_build_vless_url` | 复用现有 1911 行 vless URL 模板（IPv6 用方括号包裹），输出新链接 |

> **注意**：现有 1911 行 `printf` 不能直接复用，因为 IPv6 地址需要 `[...]` 包裹。需要新写一份只针对 IPv6 的 builder，**或** 复用同一模板但传入已包好方括号的字符串。倾向后者，避免重复代码。

#### 业务主流程
| 函数名 | 职责 |
|---|---|
| `ipv6_rotation_rotate_now` | F1 主流程：检查 → 读配置 → 生成新地址 → 解绑旧 → 绑定新 → 写 state → 输出 URL |
| `ipv6_rotation_show_current` | F2 查看当前状态 + URL |
| `ipv6_rotation_reset` | F3 解绑当前 + 清空 state |
| `ipv6_rotation_health_check` | F4 一致性校验 |

#### 菜单
| 函数名 | 职责 |
|---|---|
| `ipv6_rotation_menu` | 二级菜单分发，参考现有 `*_menu` 函数结构 |

### 8.3 文件级新增（lines of code 估算）

| 区域 | 估计行数 |
|---|---|
| 探测与校验函数 | ~40 |
| 配置读取 | ~30 |
| 状态文件管理 | ~60 |
| 地址操作 | ~40 |
| URL 生成 | ~15 |
| 业务主流程 | ~80 |
| 菜单 | ~30 |
| **小计** | **~295 行** |

---

## 9. 菜单结构改动点

### 9.1 主菜单新增项

在主菜单的**最后一个功能项之后、退出项之前**新增 1 项：

```
（已有项 1..N）
N+1. IPv6 Reality 地址轮换         ← 新增
0.   退出
```

具体编号取决于当前主菜单已有项数（开发时确认）。

### 9.2 二级菜单（新建）

```
═══════ IPv6 Reality 地址轮换 ═══════
当前状态：[INIT 或 ROTATED]
当前轮换地址：<显示或"无">
原始节点地址：::a (始终保留)

  1. 立即轮换（生成新地址 + 链接）
  2. 查看当前轮换地址 + 链接
  3. 重置（解绑当前轮换地址）
  4. 健康检查（state 与实际是否一致）
  0. 返回主菜单
═══════════════════════════════════════
请选择:
```

复用 `render_section_header`、`render_menu_item`、`render_info_line`、`notify_invalid_choice`、`pause_screen`。

---

## 10. 与现有逻辑的接触面（详细审查）

### 10.1 只读取，不修改（✅ 安全）

| 资源 | 用途 | 接触方式 |
|---|---|---|
| `CONFIG_PATH` (`/etc/sing-box/config.json`) | 读取 reality-in inbound | `jq` 查询，不写 |
| `NODES_DIR` (`/etc/sing-box/nodes/`) | 不接触 | — |
| `is_singbox_installed`、`require_singbox_installed` | 前置检查 | 函数调用 |
| `ensure_jq` | 确保 jq 存在 | 函数调用 |
| 现有 render/pause/notify 函数 | UI 输出 | 函数调用 |
| 全局颜色变量 `R/G/Y/N/D` 等 | UI 着色 | 直接引用 |

### 10.2 仅新增，不替换

| 文件/目录 | 性质 |
|---|---|
| `/etc/sing-box/ipv6-rotation/` | 新建独立目录 |
| `/etc/sing-box/ipv6-rotation/state.json` | 新建状态文件 |
| `leyili.sh` 内新增函数 | 追加在现有函数之后 |
| 主菜单新增 1 项 | 在现有项之后插入新分支 |

### 10.3 系统层临时修改

| 操作 | 影响 | 回滚方法 |
|---|---|---|
| `ip -6 addr add` 临时绑定 | 在 eth0 上多一个全局 IPv6 地址 | `ip -6 addr del` |
| `ip -6 addr del` 解绑 | 网卡少一个 IPv6 地址 | `ip -6 addr add` 重新绑 |

**完全不涉及**：
- iptables / nftables 规则
- systemd unit
- /etc/network/interfaces
- /etc/sysctl.conf
- sing-box 配置
- 防火墙后端
- DNS / hosts

### 10.4 重启行为

| 项 | 重启前 | 重启后 |
|---|---|---|
| 原始 `::a` 地址 | 在 | 在（系统配置） |
| 轮换地址 | 在 | **消失**（未持久化） |
| state.json | 存在 | 存在（磁盘持久） |
| 一致性 | 一致 | state 显示有轮换地址，但 eth0 没有 → 健康检查会报警 |

**预期行为**：重启后用户进入菜单 F2 查看 → 看到"状态不一致"警告 → 用户点 F1 立即轮换重建 OR F3 重置后再 F1。

---

## 11. 边界情况与错误处理

| 情况 | 处理 |
|---|---|
| sing-box 未安装 | `require_singbox_installed` 兜底，标准提示 |
| `reality-in` inbound 不存在 | 红字提示"未找到 IPv6 Reality 节点，请先创建"，pause + 返回 |
| `reality-in` 的 `listen` 不是 `::` | 红字提示"当前 Reality 监听地址非 `::`，无法支持地址轮换。请使用脚本的 IPv6 dualstack 模式重新创建节点"，pause + 返回（**不主动改 listen**） |
| 多个 reality 类 inbound | 取第一个 `tag == "reality-in"`，并提示"检测到多 Reality inbound，仅轮换 reality-in" |
| /64 前缀探测失败 | 提示"未检测到全局 IPv6 /64 地址，请检查 IPv6 配置"，pause |
| `ip -6 addr add` 失败 | 检查错误：是否已存在（罕见碰撞）、是否权限不足、是否商家限制；不更新 state，提示用户 |
| `ip -6 addr del` 失败 | 仅警告（地址可能已不存在），继续执行 |
| state.json 损坏 | 自动备份为 `state.json.bak.<timestamp>` 后重建 |
| state.current 与 eth0 不符（重启后） | F2/F4 显示警告，F1 仍可执行（不依赖旧状态） |
| /64 前缀变更（VPS 迁移） | 检测到 prefix 变了 → 警告 + 自动更新 state.prefix |
| 磁盘满（无法写 state） | 红字报错，地址操作回滚 |
| 用户在两个 SSH 会话同时点轮换 | 文件锁 `/var/lock/leyili-ipv6r.lock` 串行化 |
| 随机生成的地址恰好与 `::a` 相同（概率极低） | 重新生成（最多 3 次，失败则报错） |
| jq 解析失败 | 提示并退出菜单项，不影响主菜单 |

---

## 12. 前置条件检查清单

执行 F1 前必须依次通过：

```
[1] sing-box 已安装          → require_singbox_installed
[2] jq 可用                  → ensure_jq
[3] CONFIG_PATH 存在且可读   → [ -r "$CONFIG_PATH" ]
[4] reality-in inbound 存在  → jq -e '.inbounds[] | select(.tag=="reality-in")'
[5] listen 字段为 "::"       → 上一条 jq 输出 .listen == "::"
[6] eth0 (或探测的 iface) 存在 → ip link show <iface>
[7] /64 全局 IPv6 地址存在   → ip -6 addr show dev <iface> scope global | grep /64
[8] 当前用户为 root          → require_root（脚本本就要求）
[9] 无并发锁                 → flock /var/lock/leyili-ipv6r.lock
```

任何一条不过 → 标准化错误提示 + 返回菜单。

---

## 13. 实施步骤（开发顺序建议）

按以下顺序提交，每步可独立测试：

| 步骤 | 内容 | 验收 |
|---|---|---|
| S1 | 添加底层工具函数：`ipv6_rotation_detect_prefix`、`ipv6_rotation_random_host64`、`ipv6_rotation_compose_addr` | 单元测试：脚本中 dry-run 打印 |
| S2 | 添加状态文件 CRUD 函数 | 手动调用，检查 state.json 内容 |
| S3 | 添加配置读取函数 | 手动调用，输出 node_snapshot |
| S4 | 添加地址操作函数（bind/unbind） | 手动调用，对比 `ip -6 addr show` |
| S5 | 添加前置检查函数 | 各种错误场景跑一遍 |
| S6 | 添加 URL 生成函数 | 跟现有 1911 行对比，仅 IPv6 加 `[]` |
| S7 | 添加业务主流程：rotate_now / show_current / reset | 端到端测试 |
| S8 | 添加菜单 + 主菜单挂载点 | UI 走查 |
| S9 | 添加并发锁、健康检查 | 双 SSH 同时点测试 |
| S10 | 文档与注释完善 | code review |

每步完成后用 `git diff` 复核：**未触碰原有函数行**。

---

## 14. 验收测试清单

### 14.1 功能测试

| 用例 | 步骤 | 预期 |
|---|---|---|
| T1 初始轮换 | INIT 状态 → 点 F1 | 网卡多 1 个新地址，state 写入，URL 输出 |
| T2 二次轮换 | ROTATED 状态 → 点 F1 | 旧地址消失，新地址出现，URL 更新 |
| T3 查看 | ROTATED 状态 → 点 F2 | 显示当前地址 + URL |
| T4 重置 | ROTATED 状态 → 点 F3 | 旧地址消失，state.current=null |
| T5 重置后查看 | INIT 状态 → 点 F2 | 显示"未轮换" |
| T6 重启后健康检查 | F1 后重启 VPS → 点 F4 | 报警"state 有但网卡无"，提供修复指引 |
| T7 重启后再轮换 | 重启后直接点 F1 | 自动跳过解绑（地址已不存在），正常绑新地址 |

### 14.2 兼容性测试

| 用例 | 验证点 |
|---|---|
| C1 原节点不受影响 | F1 后 `::a` 上的 Reality 仍可正常连接 |
| C2 hy2/anytls 不受影响 | F1 前后 hy2/anytls 端口 ping/连接正常 |
| C3 防火墙规则未变 | `iptables-save` 前后 diff 为空 |
| C4 sing-box 配置未变 | `md5sum /etc/sing-box/config.json` 前后一致 |
| C5 NODES_DIR 未变 | `ls /etc/sing-box/nodes/` 前后一致 |
| C6 现有菜单项未变 | 现有 1..N 项可正常使用 |

### 14.3 错误注入测试

| 用例 | 注入 | 预期 |
|---|---|---|
| E1 reality-in 不存在 | 临时备份 sing-box 配置后删除 inbound | 友好报错，不崩溃 |
| E2 listen 改为具体 IP | 临时改 sing-box 配置 | 拒绝执行，提示用户 |
| E3 state.json 写坏 | echo "garbage" > state.json | 自动备份并重建 |
| E4 网卡断 | `ip link set eth0 down`（测试时谨慎，会断 SSH） | 报错，不修改 state |
| E5 并发点击 | 两个 SSH 同时 F1 | 第二个等锁或拒绝 |

### 14.4 卸载测试

完整移除本功能：
1. F3 重置（解绑当前地址）
2. `rm -rf /etc/sing-box/ipv6-rotation/`
3. 删除 leyili.sh 中新增的函数和菜单项
4. 验证：`diff` 与开发前的脚本，仅本功能新增内容差异

---

## 15. 风险评估与回滚

### 15.1 风险矩阵

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| 新地址绑定后 GFW 立即风控 | 低-中 | 用户切回原 URL 即可 | 原 `::a` 一直保留 |
| 商家配额限制（不允许多 IP） | 低 | 绑定失败 | 错误提示 + 保留原状 |
| state.json 与实际不同步 | 中 | 显示错误 URL | 健康检查 + 重置功能 |
| 用户误删 `::a` | 极低 | 节点宕 | 本功能不操作 `::a`，与本功能无关 |
| 脚本 bug 导致 sing-box 配置被改 | 低 | 节点异常 | P0 原则 + 验收 C4 |

### 15.2 紧急回滚（如开发后发现问题）

```bash
# 1. 停止使用本功能（解绑当前轮换地址）
ip -6 addr show dev eth0 | grep "inet6 2a12" | grep -v "::a/64" | awk '{print $2}' \
  | xargs -I{} ip -6 addr del {} dev eth0

# 2. 删除状态目录
rm -rf /etc/sing-box/ipv6-rotation/

# 3. 替换 leyili.sh 为开发前版本
git checkout HEAD~1 -- leyili.sh   # 或恢复备份
```

原节点 `::a/64` 完全不受影响。

---

## 16. 待开发前需要确认的问题

开发开始前，请逐一确认或回答：

### Q1 · 网卡名是否始终为 `eth0`？
- 当前测试显示 eth0
- 个别 VPS 用 `ens3`、`enp0s3` 等
- **方案 A**：硬编码 eth0（简单）
- **方案 B**：探测全局 IPv6 所在的网卡（鲁棒，**推荐**）

### Q2 · 节点信息从哪里读取？
- **方案 A**：直接从 `CONFIG_PATH` 解析 sing-box config（jq 查 inbound）
- **方案 B**：从 `NODES_DIR/<node-id>/info` 文件读取（如果脚本现有 info 文件保存了 pbk/sid/sni 等）
- 需要看 `node_info_path`、`get_node_value` 函数实际存了什么字段

### Q3 · vless URL 生成器是否有现成可复用？
- 当前 1911 行已有 vless 模板，但 IPv6 需要 `[]` 包裹
- **方案 A**：新写一份 IPv6 专用 builder
- **方案 B**：在调用现有模板前，检测是 IPv6 就把地址包成 `[addr]` 字符串再传入
- 倾向 B，但要看 1911 行函数签名能否兼容

### Q4 · 主菜单新增项的具体编号是几？
- 需要看主菜单当前最大编号
- 假设是 N，新项就是 N+1

### Q5 · 是否需要把"立即轮换"做成可在 SSH 里直接 `leyili.sh rotate-ipv6` 一行调用？
- 当前脚本是否支持非交互式参数？
- 如果支持，加一个非交互入口很方便（适合做 cron）
- **建议**：本期仅菜单，不上非交互（保持范围最小）

### Q6 · 当前 IPv6 Reality inbound 的 `listen` 字段实际是什么？
请在 VPS 上执行：
```bash
jq '.inbounds[] | select(.tag=="reality-in") | {listen, listen_port}' /etc/sing-box/config.json
```
**这是开发前必须确认的关键值**。如果不是 `::`，本方案需要先解决"如何让用户切到 `::`"的前置工作，再开发轮换功能。

### Q7 · 是否需要在轮换时同时输出"上一个地址"以便临时回退？
- 硬切换语义下，旧地址被解绑，无法连接
- 但可以打印"上一个地址：xxx（已失效）"作为信息
- **建议**：打印作为信息，但明确标注已失效

### Q8 · /64 前缀提取的地址源
- 当前 eth0 上的全局地址 `2a12:a304:4:9b8::a/64` → 取前 4 段
- 如果未来商家给的是 `/56` 或更大段（少见），取法不同
- **建议**：本期假设 /64，检测到非 /64 时报错

---

## 17. 总览图

```
┌─────────────────────────────────────────────────────────────┐
│ leyili.sh （现有 8162 行 + 新增 ~295 行）                    │
│                                                              │
│ 现有逻辑                                                     │
│  ├─ 主菜单 1..N                                             │
│  │   └─ Reality / hy2 / anytls 节点管理（不动）             │
│  ├─ sing-box 配置 (CONFIG_PATH)（只读）                     │
│  ├─ 节点 info (NODES_DIR)（不动）                           │
│  └─ 防火墙、SSH 等（不动）                                  │
│                                                              │
│ 新增模块：IPv6 Reality 轮换                                  │
│  ├─ 主菜单第 N+1 项 → ipv6_rotation_menu                    │
│  ├─ 状态目录 /etc/sing-box/ipv6-rotation/                   │
│  ├─ 状态文件 state.json                                     │
│  ├─ 函数 ~14 个（全部 ipv6_rotation_ 前缀）                 │
│  └─ 唯一系统副作用：ip -6 addr add/del 操作                 │
└─────────────────────────────────────────────────────────────┘
```

---

## 18. 签收

完成本方案后，下一步：

1. ☐ 用户阅读本方案，回答第 16 章 Q1-Q8
2. ☐ 在 VPS 上执行 Q6 的 jq 命令并贴回结果
3. ☐ 双方对方案最终细节达成一致
4. ☐ 进入开发阶段，按第 13 章步骤 S1-S10 推进
5. ☐ 每步完成后跑第 14 章对应验收用例
6. ☐ 全部 ✅ 后合并到 leyili.sh 主线

---

*本方案严守"不动现有逻辑"P0 原则。任何会修改现有函数、配置文件的需求，请回到方案讨论阶段重新评估，不在开发阶段临时决策。*
