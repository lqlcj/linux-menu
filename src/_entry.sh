# ─── 入口判断 ─────────────────────────────────────────
# 测试只加载函数时设置 LEYILI_SOURCE_ONLY=1，不执行菜单、写入口或获取全局锁。
if [ "${LEYILI_SOURCE_ONLY:-0}" != "1" ]; then
  if [ "${LEYILI_ALLOW_ANY_DISTRO:-0}" != "1" ] && ! require_debian_family; then
    exit 1
  fi
  if ! acquire_global_lock; then
    exit 1
  fi

  register_sb_command
  sb_install_rc=$?

  # curl … | bash 时 stdin 就是脚本自身，bash 读完只剩 EOF：
  # 菜单的 read 会立刻返回空值，一路掉进「无效选项」死循环。先把 stdin 接回控制终端。
  if attach_terminal_stdin; then
    # show_menu 第一件事就是 clear，安装失败的提示会被立刻抹掉；
    # 先停下来等回车，否则用户到下次敲 sb 才发现命令不存在。
    if [ "$sb_install_rc" -ne 0 ]; then
      read -r -p "  按回车继续进入菜单..." _ || true
    fi
    show_menu
  else
    # 真的没有终端（cron / CI / 无 tty 的管道）：装完入口就收工，不进交互菜单。
    echo ""
    if [ "$sb_install_rc" -ne 0 ]; then
      echo -e "  ${R}当前会话没有可用终端，且 ${COMMAND_NAME} 入口未安装成功${N}"
      exit 1
    fi
    echo -e "  ${G}${COMMAND_NAME} 命令已安装到 ${SCRIPT_PATH}${N}"
    echo -e "  当前会话没有可用终端，请在终端里执行 ${B}${COMMAND_NAME}${N} 打开菜单。"
  fi
fi
