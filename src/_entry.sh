# ─── 入口判断 ─────────────────────────────────────────
# 测试只加载函数时设置 LEYILI_SOURCE_ONLY=1，不执行菜单、写入口或获取全局锁。
if [ "${LEYILI_SOURCE_ONLY:-0}" != "1" ]; then
  if [ "${LEYILI_ALLOW_ANY_DISTRO:-0}" != "1" ] && ! require_debian_family; then
    exit 1
  fi
  if ! acquire_global_lock; then
    exit 1
  fi
  # show_menu 第一件事就是 clear，安装失败的提示会被立刻抹掉；
  # 先停下来等回车，否则用户到下次敲 sb 才发现命令不存在。
  # 只在有终端时暂停：管道运行时 stdin 是脚本本身，read 会吃掉一行脚本内容。
  if ! register_sb_command && [ -t 0 ]; then
    read -r -p "  按回车继续进入菜单..." _ || true
  fi

  show_menu
fi
