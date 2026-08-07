# ─── 入口判断 ─────────────────────────────────────────
# 测试只加载函数时设置 LEYILI_SOURCE_ONLY=1，不执行菜单、写入口或获取全局锁。
if [ "${LEYILI_SOURCE_ONLY:-0}" != "1" ]; then
  if [ "${LEYILI_ALLOW_ANY_DISTRO:-0}" != "1" ] && ! require_debian_family; then
    exit 1
  fi
  if ! acquire_global_lock; then
    exit 1
  fi
  register_sb_command || true

  show_menu
fi
