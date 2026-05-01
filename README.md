#### 自用运维脚本

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lqlcj/linux-menu/main/leyili.sh)
```

安装后可直接用 `sb` 命令再次唤起菜单。

---

## 简介

一键运维脚本，集系统调优、防火墙与 Docker 管理于一体。仅支持 **Debian / Ubuntu** 系（如需在其它发行版强制运行，设置环境变量 `LEYILI_ALLOW_ANY_DISTRO=1`）。

## 关键路径

- 配置：`/etc/sing-box/config.json`、`/etc/sing-box/nodes/`、`/etc/sing-box/chains/`
- 证书：`/etc/sing-box/certs/`
- 客户端信息：`/root/proxy-info.txt`
- 命令入口：`/usr/local/bin/sb`
- TCP 调优：`/etc/sysctl.d/99-proxy-optimized.conf`
- initcwnd 服务：`/etc/systemd/system/initcwnd.service`

## 环境变量

| 变量 | 作用 |
| :-- | :-- |
| `LEYILI_ALLOW_ANY_DISTRO=1` | 允许在非 Debian/Ubuntu 系强制运行 |
| `SELF_INSTALL_URL` | 自定义脚本更新源 |
