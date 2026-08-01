#### 自用运维脚本

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lqlcj/linux-menu/main/leyili.sh)
```

安装后可直接用 `sb` 命令再次唤起菜单。

---

## 简介

一键运维脚本，集系统调优、防火墙与 Docker 管理于一体。

| 变量 | 作用 |
| :-- | :-- |
| `LEYILI_ALLOW_ANY_DISTRO=1` | 允许在非 Debian/Ubuntu 系强制运行 |
| `SELF_INSTALL_URL` | 自定义脚本更新源 |

  linux-menu/
  ├── leyili.sh           ← 11388 行 / LF / 自动构建产物（每次跑 ./build.sh 重写）
  ├── leyili.sh.baseline  ← 原 11357 行 CRLF 版本（验证用，几次确认后可删）
  ├── build.sh            ← 构建脚本
  ├── .gitattributes      ← 锁定 .sh / .md 为 LF
  ├── README.md
  └── src/
      ├── _header.sh      (70 行: shebang + 常量 + 颜色)
      ├── _entry.sh       (11 行: 入口判断 + show_menu 调用)
      └── lib/            (32 个文件，72-1123 行不等)
          ├── 00-utils-head.sh
          ├── 01-firewall-common.sh
          ├── 02-utils-ui.sh
          ├── 03-system-admin-low.sh
          ├── 04-utils-ip.sh
          ├── 10-singbox-core.sh
          ├── 11-xray-core.sh          ← 改 Xray 内核相关
          ├── 12-singbox-config-storage.sh
          ├── 20-link-builders.sh
          ├── 21-menus-top.sh
          ├── 22-firewall-ipv6.sh
          ├── 23-firewall-ipv4.sh
          ├── 24-system-admin-high.sh
          ├── 25-system-basic.sh
          ├── 30-node-render.sh
          ├── 40-network-tuning.sh
          ├── 41-update-self.sh
          ├── 50-node-reality.sh
          ├── 51-port-hop.sh
          ├── 52-node-hy2.sh
          ├── 53-nodes-anytls-tuic.sh
          ├── 54-node-ss2022.sh
          ├── 55-node-xhr.sh           ← 改 vless-xhttp-reality 节点
          ├── 56-modify-params.sh
          ├── 60-uninstall-script.sh
          ├── 70-render-ui.sh
          ├── 80-menu-node.sh
          ├── 90-warp.sh
          ├── 91-realm.sh
          ├── 92-status.sh
          ├── 93-traffic.sh            ← 流量统计（累计 + 定时器落盘）
          └── 99-menu-main.sh
