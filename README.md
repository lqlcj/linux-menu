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
