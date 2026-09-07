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
  local choice

  while true; do
    clear
    render_brand_banner
    render_menu_item 1 "管理员设置"
    render_menu_item 2 "系统基础设置"
    render_menu_item 3 "网络管理"
    render_menu_item 4 "防火墙管理"
    render_menu_item 5 "卸载脚本"
    render_menu_item 6 "更新管理"
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
        show_network_menu
        ;;
      4)
        show_firewall_menu
        ;;
      5)
        uninstall_script_completely
        ;;
      6)
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
