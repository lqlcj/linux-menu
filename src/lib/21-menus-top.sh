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
      0)
        return
        ;;
      *)
        notify_invalid_choice
        ;;
    esac
  done
}

show_network_menu(){
  while true; do
    render_section_header "网络管理"
    render_menu_item 1 "安装 / 配置 fail2ban (SSH 多端口防爆破)"
    render_menu_item 2 "服务器状态"
    render_menu_item 3 "本地链路测评"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        setup_fail2ban
        ;;
      2)
        show_server_status
        ;;
      3)
        show_netbench_menu
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
    render_menu_item 7 "关闭 SSH 密码登录 (仅密钥)"
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
      7)
        disable_ssh_password_login
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

show_update_menu(){
  local choice
  while true; do
    render_section_header "更新管理"
    render_menu_item 1 "更新脚本"
    render_menu_item 2 "清理配置备份"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice
    case $choice in
      1) update_self_script ;;
      2) cleanup_config_backups ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}
