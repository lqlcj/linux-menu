show_status_menu(){
  if ! require_singbox_installed; then
    return
  fi

  while true; do
    render_section_header "查看状态"
    render_menu_item 1 "查看运行状态"
    render_menu_item 2 "修改节点参数"
    render_menu_item 3 "实时日志"
    render_menu_item 4 "重启服务"
    render_menu_item 5 "停止服务"
    render_menu_item 6 "启动服务"
    render_menu_item 7 "查看客户端链接 / 二维码"
    render_menu_item 8 "查看配置"
    render_menu_item 9 "编辑配置"
    render_menu_item 10 "清理配置备份"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        systemctl status sing-box || true
        pause_screen
        ;;
      2)
        modify_node_params
        ;;
      3)
        echo -e "${Y}按 Ctrl+C 退出日志${N}"
        journalctl -u sing-box -f || true
        ;;
      4)
        if systemctl restart sing-box; then
          echo -e "${G}服务已重启${N}"
        else
          echo -e "${R}重启失败，请检查上方输出${N}"
        fi
        sleep 1
        ;;
      5)
        if systemctl stop sing-box; then
          echo -e "${Y}服务已停止${N}"
        else
          echo -e "${R}停止失败，请检查上方输出${N}"
        fi
        sleep 1
        ;;
      6)
        if systemctl start sing-box; then
          echo -e "${G}服务已启动${N}"
        else
          echo -e "${R}启动失败，请检查上方输出${N}"
        fi
        sleep 1
        ;;
      7)
        show_client_link
        ;;
      8)
        view_singbox_config
        ;;
      9)
        edit_singbox_config
        ;;
      10)
        cleanup_config_backups
        ;;
      0)
        return
        ;;
      *)
        notify_invalid_choice
        ;;
    esac
  done
}

show_system_menu(){
  while true; do
    render_section_header "系统基础设置"
    render_menu_item 1 "更新系统"
    render_menu_item 2 "启用自动更新"
    render_menu_item 3 "校正系统时间"
    render_menu_item 4 "安装基础工具"
    render_menu_item 5 "网络优化"
    render_menu_item 6 "查看网络优化状态"
    render_menu_item 7 "添加 SWAP"
    render_menu_item 8 "安装 fail2ban (SSH 防爆破)"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        update_system_packages
        ;;
      2)
        enable_auto_updates
        ;;
      3)
        configure_system_time
        ;;
      4)
        install_basic_tools
        ;;
      5)
        show_network_optimization_menu
        ;;
      6)
        show_network_optimization_status
        ;;
      7)
        show_swap_picker
        ;;
      8)
        setup_fail2ban
        ;;
      0)
        return
        ;;
      *)
        notify_invalid_choice
        ;;
    esac
  done
}

show_admin_menu(){
  while true; do
    render_section_header "管理员设置"
    render_menu_item 1 "创建普通用户"
    render_menu_item 2 "加入 sudo 组"
    render_menu_item 3 "测试用户登录"
    render_menu_item 4 "修改 SSH 端口"
    render_menu_item 5 "禁止 root 登录"
    render_menu_item 6 "配置 sudo 免密"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        create_regular_user
        ;;
      2)
        add_user_to_sudo_group
        ;;
      3)
        test_user_login
        ;;
      4)
        configure_ssh_port
        ;;
      5)
        disable_root_ssh_login
        ;;
      6)
        configure_passwordless_sudo
        ;;
      0)
        return
        ;;
      *)
        notify_invalid_choice
        ;;
    esac
  done
}

