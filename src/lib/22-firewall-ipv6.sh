show_ipv6_firewall_menu(){
  local ssh_port

  if ! require_root; then
    return 1
  fi

  if ! ensure_iptables_installed; then
    pause_screen
    return 1
  fi

  while true; do
    ssh_port=$(ip6_detect_ssh_port)

    render_section_header "IPv6 防火墙管理"
    echo -e "  ${L}│${N}  SSH 端口  ${D}·${N}  ${C}${ssh_port}${N}"

    local input_policy opened_ports
    input_policy=$(ip6_get_input_policy)
    opened_ports=$(ip6_list_opened_ports_compact)
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
    render_menu_item 3 "一键关闭所有 IPv6 入站端口"
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
        ;;
      4)
        ip6_open_port
        ;;
      5)
        ip6_close_port
        ;;
      6)
        ip6_emergency_disable
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
  local input_policy output_policy forward_policy opened

  input_policy=$(ip6_get_input_policy)
  output_policy=$(ip6tables -L OUTPUT -n 2>/dev/null | head -n1 | awk '{gsub(/\)/, "", $4); print $4}')
  forward_policy=$(ip6tables -L FORWARD -n 2>/dev/null | head -n1 | awk '{gsub(/\)/, "", $4); print $4}')

  echo ""
  echo -e "  ${B}${C}默认策略${N}"
  echo -e "  INPUT   : ${C}${input_policy}${N}  ${D}(别人主动连你)${N}"
  echo -e "  OUTPUT  : ${C}${output_policy}${N}  ${D}(你主动出去连别人)${N}"
  echo -e "  FORWARD : ${C}${forward_policy}${N}  ${D}(转发, Docker 用, 脚本不动)${N}"
  echo ""

  echo -e "  ${B}${C}已开放的入站端口${N}"
  opened=$(ip6tables-save 2>/dev/null | awk '
    /^-A INPUT/ {
      proto=""; port=""
      for (i = 1; i <= NF; i++) {
        if ($i == "-p") proto = $(i + 1)
        if ($i == "--dport") port = $(i + 1)
      }
      if (port != "") printf "  %s  %s\n", toupper(proto), port
    }' | sort -u)

  if [ -z "$opened" ]; then
    echo -e "  ${D}(无)${N}"
  else
    echo "$opened"
  fi
  echo ""

  echo -e "  ${B}${C}完整 INPUT 规则${N}"
  ip6tables -L INPUT -n -v --line-numbers
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
  local backup_rules="" rb_choice="y" rb_pid="" rb_seconds=180

  echo ""
  echo -e "  ${B}${C}一键关闭所有 IPv6 入站端口${N}"
  render_divider
  echo "  本次会执行："
  echo "    1) 清空当前 IPv6 INPUT 规则"
  echo "    2) 放行回环 lo"
  echo "    3) 放行已建立的连接 (ESTABLISHED, RELATED)"
  echo "    4) 放行 ICMPv6 (NDP / 邻居发现, IPv6 网络必需)"
  echo -e "    5) ${R}${B}不放行任何业务端口 (含 SSH/80/443/节点端口)${N}"
  echo "    6) INPUT 默认策略 = DROP"
  echo "    7) OUTPUT 保持 ACCEPT (出站不受影响)"
  echo "    8) FORWARD 不动 (留给 Docker)"
  echo ""
  echo -e "  ${Y}效果：外部无法主动连入任何 IPv6 端口；本机 IPv6 出站仍可用，回包能进。${N}"
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

  # 兜底：是否启用延时自动回滚守护
  echo ""
  echo -e "  ${B}延时自动回滚守护（强烈建议启用）${N}"
  echo -e "  ${D}启用后规则应用 ${rb_seconds}s 内若未手动取消，将自动恢复旧规则${N}"
  read -p "  启用 ${rb_seconds}s 自动回滚守护？(Y/n): " rb_choice
  if [ "$rb_choice" = "n" ] || [ "$rb_choice" = "N" ]; then
    rb_choice="n"
  else
    rb_choice="y"
    backup_rules=$(mktemp /tmp/leyili-ip6tables-rb.XXXXXX 2>/dev/null) || backup_rules=""
    if [ -n "$backup_rules" ]; then
      ip6tables-save > "$backup_rules" 2>/dev/null || { rm -f "$backup_rules"; backup_rules=""; }
    fi
  fi

  if ! ip6_ensure_persistence; then
    echo ""
    echo -e "${R}持久化工具安装失败${N}"
    [ -n "$backup_rules" ] && rm -f "$backup_rules"
    pause_screen
    return 1
  fi

  ip6tables -F INPUT
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
  ip6tables -P INPUT DROP
  ip6tables -P OUTPUT ACCEPT

  if ! ip6_save_rules; then
    echo -e "${Y}规则已生效，但持久化失败，重启后可能丢失${N}"
  fi

  echo ""
  echo -e "${G}所有 IPv6 入站端口已关闭${N}"

  if [ "$rb_choice" = "y" ] && [ -n "$backup_rules" ]; then
    rb_pid=$(schedule_iptables_rollback "$rb_seconds" "" "$backup_rules")
    if [ -n "$rb_pid" ]; then
      echo -e "  ${Y}延时回滚守护已启动 (PID ${rb_pid})，${rb_seconds}s 后自动恢复旧规则${N}"
      echo -e "  ${B}请尽快开新终端验证 SSH/服务仍可用 (走 IPv4)，然后执行：${N}"
      echo -e "    ${C}kill ${rb_pid} && rm -f ${backup_rules}${N}  ${D}# 取消回滚${N}"
    fi
  fi
  pause_screen
}

ip6_open_port(){
  local proto_choice protos="" port proto changed=0

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

  for proto in $protos; do
    if ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
      echo -e "  ${Y}${port}/${proto} 已放行，跳过${N}"
    else
      ip6tables -A INPUT -p "$proto" --dport "$port" -j ACCEPT
      echo -e "  ${G}已放行 ${port}/${proto}${N}"
      changed=1
    fi
  done

  if [ "$changed" -eq 1 ]; then
    if ! ip6_save_rules; then
      echo -e "${Y}持久化失败${N}"
    fi
  fi
  pause_screen
}

ip6_close_port(){
  local proto_choice protos="" port ssh_port confirm proto removed=0

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

  for proto in $protos; do
    while ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; do
      ip6tables -D INPUT -p "$proto" --dport "$port" -j ACCEPT
      echo -e "  ${G}已删除 ${port}/${proto}${N}"
      removed=$((removed + 1))
    done
  done

  if [ "$removed" -eq 0 ]; then
    echo -e "  ${Y}端口 ${port} 在所选协议下没有放行规则${N}"
  else
    if ! ip6_save_rules; then
      echo -e "${Y}持久化失败${N}"
    fi
  fi
  pause_screen
}

ip6_emergency_disable(){
  local confirm confirm2

  echo ""
  echo -e "  ${R}${B}紧急放行（关闭 v6 防火墙）${N}"
  render_divider
  echo "  执行后："
  echo "    - 清空所有 IPv6 INPUT 规则"
  echo "    - 默认策略改回 ACCEPT"
  echo "    - v6 入站回到完全裸奔状态"
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

  ip6tables -P INPUT ACCEPT
  ip6tables -F INPUT
  if ! ip6_save_rules; then
    echo -e "${Y}持久化失败${N}"
  fi

  echo ""
  echo -e "${Y}已关闭 v6 防火墙${N}"
  pause_screen
}

# ─── IPv4 防火墙菜单 ─────────────────────────────────
