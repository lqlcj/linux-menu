# Leyili Linux Menu

面向 Debian / Ubuntu 系 VPS 的自用运维菜单，集中管理 sing-box 节点、网络设置、防火墙、WARP、fail2ban、系统调优和卸载清理。

## 安装

建议先下载为本地临时文件再执行，这样脚本可以安全地原子安装 `/usr/local/bin/sb`：

```bash
tmp_script=$(mktemp)
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/lqlcj/linux-menu/main/leyili.sh \
  -o "$tmp_script"
bash "$tmp_script"
rm -f -- "$tmp_script"
```

之后运行 `sb` 即可再次打开菜单。大多数写操作需要 root 权限。

支持变量：

| 变量 | 作用 |
| --- | --- |
| `LEYILI_ALLOW_ANY_DISTRO=1` | 跳过 Debian/Ubuntu 系统保护，仅用于人工兼容测试，不代表其它发行版受支持 |
| `SELF_INSTALL_URL` | 自定义脚本更新来源，必须为 HTTPS |
| `SELF_INSTALL_SHA256` | 固定自更新文件的 SHA-256；未设置时自更新要求人工输入 `UNVERIFIED` |

## `sb` 命令不可用

`sb` 是首次运行时脚本把自身复制到 `/usr/local/bin/sb` 得到的。装不上时，脚本会在进入菜单前打印具体原因并等待回车（早期版本这行提示会被菜单的 `clear` 立刻抹掉，导致直到下次敲 `sb` 才发现命令不存在）：

| 原因 | 说明 |
| --- | --- |
| 管道运行 | `curl … \| bash`、`bash <(curl …)` 没有可复制的本地文件，必须按上面的方式先下载为临时文件 |
| 非 root | 无权写入 `/usr/local/bin` |
| 写入失败 | `/usr` 只读挂载或磁盘已满 |
| 不在 PATH | 文件已就位但命令解析不到，可直接用绝对路径 `/usr/local/bin/sb` 启动 |

已经出问题的机器，重新执行一次上面的安装命令即可恢复。先看现状：

```bash
ls -l /usr/local/bin/sb; echo "$PATH"
```

## 菜单结构

```text
1  管理员设置
2  系统基础设置
3  创建节点 / 节点管理
   └─ 查看状态 / 节点配置
4  网络管理
   ├─ fail2ban（SSH 多端口防爆破）
   ├─ Reality 域名检测工具
   ├─ WARP 谷歌解锁分流
   ├─ 服务器状态
   └─ 本地链路测评
5  防火墙管理
   ├─ IPv4 防火墙管理
   └─ IPv6 防火墙管理
6  卸载脚本
7  更新管理
0  退出
```

首页卡片保持精简，不再展示未安装的 Hysteria2 / AnyTLS / TUIC，也不展示 TCP、QUIC、initcwnd 调优状态行。

fail2ban 可输入逗号、空格或中文分隔符分开的 SSH 端口，自动去重，最多保护 15 个端口；它不会修改 SSH 监听端口，也不会自动开放防火墙。

## 安全与回滚边界

- 全局使用私有权限、进程互斥锁、临时文件和同目录原子替换。
- Reality、Hysteria2、AnyTLS、TUIC、SS-2022、WARP、SSH、fail2ban 和关键配置修改均先创建快照，校验或重启失败时立即恢复。
- 防火墙只采用“操作前快照、失败立即恢复”，不会创建定时器、后台任务或延迟自动回滚。
- iptables/ip6tables 规则写入脚本专属链 `LEYILI_INPUT`、`LEYILI6_INPUT`；ufw/firewalld 只撤销脚本登记为自己新增的端口。
- 回滚本身若失败，会明确报警并保留权限为 700 的私有事务目录，不会继续报告成功。
- WARP 规则集固定到明确提交，SagerNet 仓库公钥校验固定指纹；账号替换先验证临时文件再原子覆盖。
- 自更新先校验 HTTPS、文件结构、大小、Bash 语法和可选 SHA-256，再原子替换脚本入口。

## 完整卸载

完整卸载只清理脚本能够确认所有权的内容：固定节点 tag、节点信息和证书、WARP、端口跳跃、脚本专属防火墙链、脚本登记的 ufw/firewalld 端口、sing-box 软件包及明确的旧版遗留组件。

它不会 `purge` sing-box，也不会删除整个 `/etc/sing-box`。用户自定义 inbound、DNS、路由、outbound 和其它文件会保留；预先存在的 SagerNet sources/key 能恢复则恢复，所有权不明确时优先保留。前序步骤失败时脚本入口也会保留，便于重新执行卸载。

TCP/QUIC 调优、initcwnd、SSH、用户账户、sudoers、自动更新设置、1Panel 和脚本创建的 SWAP 默认不属于完整卸载范围，可在各自菜单单独管理。

## 开发与验证

`src/` 是源码，`leyili.sh` 是 `build.sh` 拼接生成并提交到仓库的发布文件：

```bash
bash build.sh
bash tests/smoke.sh
```

CI 会执行：

- `build.sh`、每个 `src/*.sh` 和最终 `leyili.sh` 的 Bash 语法检查；
- 重新构建后校验 `leyili.sh` 与源码完全一致；
- `git diff --check`、ShellCheck error 级检查和菜单/事务冒烟测试。

Windows/Git Bash 只能完成构建和静态测试。发布前仍应在干净的 Debian/Ubuntu 测试机回归 systemd、sshd、fail2ban、iptables/ip6tables、ufw/firewalld、sing-box、WARP 和真实网络连通性。
