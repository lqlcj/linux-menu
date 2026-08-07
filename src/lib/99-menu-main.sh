show_firewall_menu(){
  while true; do
    render_section_header "防火墙管理"
    render_menu_item 1 "IPv4 防火墙管理"
    render_menu_item 2 "IPv6 防火墙管理"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        show_ipv4_firewall_menu
        ;;
      2)
        show_ipv6_firewall_menu
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

show_menu(){
  local main_action_label=""

  while true; do
    migrate_legacy_info

    if [ "$(count_installed_nodes)" -gt 0 ]; then
      main_action_label="节点管理"
    else
      main_action_label="创建节点"
    fi

    clear
    render_brand_banner
    render_main_menu_card
    render_menu_item 1 "管理员设置"
    render_menu_item 2 "系统基础设置"
    render_menu_item 3 "${main_action_label}"
    render_menu_item 4 "网络管理"
    render_menu_item 5 "防火墙管理"
    render_menu_item 6 "卸载脚本"
    render_menu_item 7 "更新管理"
    render_menu_item 0 "退出"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        show_admin_menu
        ;;
      2)
        show_system_menu
        ;;
      3)
        if [ "$(count_installed_nodes)" -eq 0 ]; then
          show_node_install_menu
        else
          show_node_manage_menu
        fi
        ;;
      4)
        show_network_menu
        ;;
      5)
        show_firewall_menu
        ;;
      6)
        uninstall_script_completely
        ;;
      7)
        show_update_menu
        ;;
      0)
        exit 0
        ;;
      *)
        notify_invalid_choice
        ;;
    esac
  done
}
