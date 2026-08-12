show_ipv6_firewall_menu(){
  local ssh_port input_policy opened_ports rules refresh_status=1

  if ! require_root; then
    return 1
  fi

  if ! ensure_iptables_installed; then
    pause_screen
    return 1
  fi

  # 菜单状态一次读取自同一份规则快照，减少反复执行 ip6tables/ss 的卡顿。
  ssh_port=$(ip6_detect_ssh_port)

  while true; do
    if [ "$refresh_status" -eq 1 ]; then
      rules=$(ip6tables-save 2>/dev/null)
      input_policy=$(printf '%s\n' "$rules" | firewall_policy_from_saved_rules INPUT)
      opened_ports=$(printf '%s\n' "$rules" | firewall_list_opened_ports_from_saved_rules compact)
      refresh_status=0
    fi

    render_section_header "IPv6 防火墙管理"
    echo -e "  ${L}│${N}  SSH 端口  ${D}·${N}  ${C}${ssh_port}${N}"

    if [ -n "$opened_ports" ]; then
      echo -e "  ${L}│${N}  已开放    ${D}·${N}  ${C}${opened_ports}${N}"
    elif [ "$input_policy" = "ACCEPT" ]; then
      echo -e "  ${L}│${N}  已开放    ${D}·${N}  ${Y}默认策略 ACCEPT${N}  ${D}(无显式规则, 全部入站放行)${N}"
    else
      echo -e "  ${L}│${N}  已开放    ${D}·${N}  ${D}(无)${N}"
    fi
    render_divider
    render_menu_item 1 "查看当前规则"
    render_menu_item 2 "查看监听 IPv6 的服务"
    render_menu_item 3 "初始化 IPv6 防火墙（默认拒绝，保留用户规则）"
    render_menu_item 4 "开放端口"
    render_menu_item 5 "关闭端口"
    render_menu_item 6 "紧急放行 (关闭 v6 防火墙)"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        ip6_view_rules
        ;;
      2)
        ip6_view_listening
        ;;
      3)
        ip6_close_all_inbound
        refresh_status=1
        ;;
      4)
        ip6_open_port
        refresh_status=1
        ;;
      5)
        ip6_close_port
        refresh_status=1
        ;;
      6)
        ip6_emergency_disable
        refresh_status=1
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

ip6_view_rules(){
  local input_policy output_policy forward_policy opened rules

  rules=$(ip6tables-save 2>/dev/null)
  input_policy=$(printf '%s\n' "$rules" | firewall_policy_from_saved_rules INPUT)
  output_policy=$(printf '%s\n' "$rules" | firewall_policy_from_saved_rules OUTPUT)
  forward_policy=$(printf '%s\n' "$rules" | firewall_policy_from_saved_rules FORWARD)

  echo ""
  echo -e "  ${B}${C}默认策略${N}"
  echo -e "  INPUT   : ${C}${input_policy}${N}  ${D}(别人主动连你)${N}"
  echo -e "  OUTPUT  : ${C}${output_policy}${N}  ${D}(你主动出去连别人)${N}"
  echo -e "  FORWARD : ${C}${forward_policy}${N}  ${D}(转发, Docker 用, 脚本不动)${N}"
  echo ""

  echo -e "  ${B}${C}已开放的入站端口${N}"
  opened=$(printf '%s\n' "$rules" | firewall_list_opened_ports_from_saved_rules lines)

  if [ -z "$opened" ]; then
    echo -e "  ${D}(无)${N}"
  else
    echo "$opened"
  fi
  echo ""

  echo -e "  ${B}${C}完整 INPUT 规则${N}"
  ip6tables -L INPUT -n -v --line-numbers
  if firewall_managed_chain_exists 6; then
    echo ""
    echo -e "  ${B}${C}${IP6_LEYILI_CHAIN} 规则${N}"
    ip6tables -L "$IP6_LEYILI_CHAIN" -n -v --line-numbers
  fi
  pause_screen
}

ip6_view_listening(){
  echo ""
  echo -e "  ${B}${C}监听 IPv6 的服务${N}"
  render_divider
  echo -e "  ${Y}TCP${N}"
  if ! ss -6tlnp 2>/dev/null; then
    echo -e "  ${R}ss 不可用${N}"
  fi
  echo ""
  echo -e "  ${Y}UDP${N}"
  if ! ss -6ulnp 2>/dev/null; then
    echo -e "  ${R}ss 不可用${N}"
  fi
  echo ""
  echo -e "  ${D}提示：监听 [::] 表示同时接受 IPv4 (经映射) 和 IPv6 连接${N}"
  pause_screen
}

ip6_close_all_inbound(){
  local confirm
  local txn

  echo ""
  echo -e "  ${B}${C}初始化 IPv6 防火墙${N}"
  render_divider
  echo "  本次会执行："
  echo -e "    1) 仅重建脚本专属链 ${C}${IP6_LEYILI_CHAIN}${N}，保留用户与 fail2ban 规则"
  echo "    2) 放行回环、已建立连接和 ICMPv6 (NDP 必需)"
  echo -e "    3) ${R}${B}脚本专属链不放行业务端口${N}"
  echo "    4) INPUT 默认策略 = DROP"
  echo "    5) OUTPUT / FORWARD 保持原样"
  echo ""
  echo -e "  ${Y}效果：未被用户既有规则放行的 IPv6 新入站会被拒绝；出站与回包可用。${N}"
  echo -e "  ${D}如需 IPv6 提供 HTTP/HTTPS/SSH 等服务，请改用本菜单 ${C}4) 开放端口${N}${D}。${N}"
  echo ""

  if ip6_check_current_ssh_v6; then
    echo -e "  ${R}${B}严重警告：你当前 SSH 是 IPv6 进来的${N}"
    echo -e "  ${R}应用规则后该会话将立即断开 (IPv4 SSH 不受影响)${N}"
    echo -e "  ${Y}建议先用 IPv4 登录后再操作${N}"
    echo ""
    read -p "  仍要继续吗？输入大写 ${R}YES${N} 强制继续: " confirm
    if [ "$confirm" != "YES" ]; then
      echo -e "  已取消"
      sleep 1
      return 0
    fi
  fi

  read -p "  确认继续？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  if ! ip6_ensure_persistence; then
    echo ""
    echo -e "${R}持久化工具安装失败${N}"
    pause_screen
    return 1
  fi

  txn=$(firewall_transaction_begin 6) || { echo -e "${R}防火墙快照失败${N}"; pause_screen; return 1; }
  if ! firewall_ensure_managed_chain 6 \
     || ! ip6tables -F "$IP6_LEYILI_CHAIN" \
     || ! ip6tables -A "$IP6_LEYILI_CHAIN" -i lo -m comment --comment "leyili-managed" -j ACCEPT \
     || ! ip6tables -A "$IP6_LEYILI_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "leyili-managed" -j ACCEPT \
     || ! ip6tables -A "$IP6_LEYILI_CHAIN" -p ipv6-icmp -m comment --comment "leyili-managed" -j ACCEPT \
     || ! ip6tables -P INPUT DROP \
     || ! ip6_save_rules; then
    firewall_transaction_rollback 6 "$txn"
    echo -e "${R}规则写入或持久化失败，已恢复原规则${N}"
    pause_screen
    return 1
  fi
  firewall_transaction_commit "$txn"

  echo ""
  echo -e "${G}IPv6 默认拒绝策略已启用${N}"
  echo -e "  ${D}用户 INPUT 规则均已保留；未启动延时回滚守护。${N}"
  pause_screen
}

ip6_open_port(){
  local proto_choice protos="" port proto changed=0 txn

  echo ""
  echo -e "  ${B}${C}开放端口${N}"
  render_divider
  render_menu_item 1 "TCP"
  render_menu_item 2 "UDP"
  render_menu_item 3 "TCP + UDP (都开)"
  render_menu_item 0 "返回"
  render_divider
  read -p "  选择协议: " proto_choice

  case "$proto_choice" in
    1) protos="tcp" ;;
    2) protos="udp" ;;
    3) protos="tcp udp" ;;
    0) return 0 ;;
    *)
      notify_invalid_choice
      return 0
      ;;
  esac

  read -p "  端口号 (1-65535): " port
  if ! validate_port "$port"; then
    echo -e "${R}端口必须是 1-65535 的数字${N}"
    pause_screen
    return 1
  fi

  txn=$(firewall_transaction_begin 6) || { echo -e "${R}防火墙快照失败${N}"; pause_screen; return 1; }
  for proto in $protos; do
    if ip6tables -C "$IP6_LEYILI_CHAIN" -p "$proto" --dport "$port" -m comment --comment "leyili-managed" -j ACCEPT 2>/dev/null; then
      echo -e "  ${Y}${port}/${proto} 已放行，跳过${N}"
    else
      if ! firewall_add_managed_port 6 "$proto" "$port"; then
        firewall_transaction_rollback 6 "$txn"
        echo -e "${R}规则写入失败，已恢复原规则${N}"
        pause_screen
        return 1
      fi
      echo -e "  ${G}已放行 ${port}/${proto}${N}"
      changed=1
    fi
  done

  if [ "$changed" -eq 1 ] && ! ip6_save_rules; then
    firewall_transaction_rollback 6 "$txn"
    echo -e "${R}持久化失败，已恢复原规则${N}"
    pause_screen
    return 1
  fi
  firewall_transaction_commit "$txn"
  pause_screen
}

ip6_close_port(){
  local proto_choice protos="" port ssh_port confirm proto removed=0 txn

  echo ""
  echo -e "  ${B}${C}关闭端口${N}"
  render_divider
  render_menu_item 1 "TCP"
  render_menu_item 2 "UDP"
  render_menu_item 3 "TCP + UDP (都关)"
  render_menu_item 0 "返回"
  render_divider
  read -p "  选择协议: " proto_choice

  case "$proto_choice" in
    1) protos="tcp" ;;
    2) protos="udp" ;;
    3) protos="tcp udp" ;;
    0) return 0 ;;
    *)
      notify_invalid_choice
      return 0
      ;;
  esac

  read -p "  要关闭的端口号 (1-65535): " port

  if ! validate_port "$port"; then
    echo -e "${R}端口必须是 1-65535 的数字${N}"
    pause_screen
    return 1
  fi

  ssh_port=$(ip6_detect_ssh_port)
  if [ "$port" = "$ssh_port" ] && printf '%s' "$protos" | grep -qw tcp; then
    echo ""
    echo -e "  ${R}${B}警告：${port}/tcp 是当前 SSH 端口${N}"
    echo -e "  ${Y}关闭后将无法通过 IPv6 SSH（IPv4 不受影响）${N}"
    read -p "  确认继续？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo -e "  已取消"
      sleep 1
      return 0
    fi
  fi

  txn=$(firewall_transaction_begin 6) || { echo -e "${R}防火墙快照失败${N}"; pause_screen; return 1; }
  for proto in $protos; do
    if ip6tables -C "$IP6_LEYILI_CHAIN" -p "$proto" --dport "$port" -m comment --comment "leyili-managed" -j ACCEPT 2>/dev/null; then
      if ! firewall_remove_managed_port 6 "$proto" "$port"; then
        firewall_transaction_rollback 6 "$txn"
        echo -e "${R}删除失败，已恢复原规则${N}"
        pause_screen
        return 1
      fi
      echo -e "  ${G}已删除脚本托管规则 ${port}/${proto}${N}"
      removed=$((removed + 1))
    fi
  done

  if [ "$removed" -eq 0 ]; then
    echo -e "  ${Y}端口 ${port} 在所选协议下没有放行规则${N}"
  else
    if ! ip6_save_rules; then
      firewall_transaction_rollback 6 "$txn"
      echo -e "${R}持久化失败，已恢复原规则${N}"
      pause_screen
      return 1
    fi
  fi
  firewall_transaction_commit "$txn"
  for proto in $protos; do
    if ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
      echo -e "  ${Y}提示：INPUT 中仍有非脚本托管的 ${port}/${proto} ACCEPT 规则，本菜单未删除。${N}"
    fi
  done
  pause_screen
}

ip6_emergency_disable(){
  local confirm confirm2 txn

  echo ""
  echo -e "  ${R}${B}紧急放行（关闭 v6 防火墙）${N}"
  render_divider
  echo "  执行后："
  echo -e "    - 删除脚本专属链 ${C}${IP6_LEYILI_CHAIN}${N}"
  echo "    - INPUT 默认策略改回 ACCEPT"
  echo "    - 保留用户规则、fail2ban 与面板规则"
  echo ""

  read -p "  确认？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi
  read -p "  再次确认（输入大写 YES 继续）: " confirm2
  if [ "$confirm2" != "YES" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  txn=$(firewall_transaction_begin 6) || { echo -e "${R}防火墙快照失败${N}"; pause_screen; return 1; }
  if ! ip6tables -P INPUT ACCEPT \
     || ! firewall_remove_managed_chain 6 \
     || ! ip6_save_rules; then
    firewall_transaction_rollback 6 "$txn"
    echo -e "${R}操作失败，已恢复原规则${N}"
    pause_screen
    return 1
  fi
  firewall_transaction_commit "$txn"

  echo ""
  echo -e "${Y}已停用脚本管理的 v6 防火墙（用户/面板规则仍保留）${N}"
  pause_screen
}

# ─── IPv4 防火墙菜单 ─────────────────────────────────
