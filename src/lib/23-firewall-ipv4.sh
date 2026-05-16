show_ipv4_firewall_menu(){
  local ssh_port conflicts have_1panel=0 hp_choice

  if ! require_root; then
    return 1
  fi

  if ! ensure_iptables_installed; then
    pause_screen
    return 1
  fi

  # 一次性提示：检测到 1Panel 时引导用户清理脚本残留 IPv4 规则
  if ip4_detect_1panel && [ "${IP4_1PANEL_HANDOFF_PROMPTED:-0}" -ne 1 ]; then
    echo ""
    echo -e "  ${R}${B}检测到 1Panel 在管理 IPv4 防火墙${N}"
    render_divider
    echo -e "  ${Y}本脚本之前可能下发过 INPUT DROP/ACCEPT 规则，会与 1Panel 冲突${N}"
    echo -e "  ${D}清理动作：${C}iptables -F INPUT${N} ${D}+ ${C}iptables -P INPUT ACCEPT${N} ${D}并持久化${N}"
    echo -e "  ${D}清理后 IPv4 入站策略全部交给 1Panel 管理${N}"
    echo -e "  ${R}注意：会清空 INPUT 链所有规则 (1Panel 通常走 ufw/firewalld，不直接挂 INPUT，一般安全)${N}"
    echo ""
    read -p "  立即清理脚本残留 IPv4 规则交还 1Panel？(y/N): " hp_choice
    if [ "$hp_choice" = "y" ] || [ "$hp_choice" = "Y" ]; then
      if ip4_handover_to_1panel; then
        echo -e "  ${G}已清空 INPUT 规则并切回 ACCEPT，IPv4 防火墙由 1Panel 接管${N}"
      else
        echo -e "  ${R}清理失败，请手动检查${N}"
      fi
    else
      echo -e "  ${D}已跳过自动清理（菜单仍会禁用写入操作）${N}"
    fi
    sleep 1
    IP4_1PANEL_HANDOFF_PROMPTED=1
  fi

  while true; do
    ssh_port=$(ip6_detect_ssh_port)
    conflicts=$(ip4_detect_conflicts)
    if ip4_detect_1panel; then
      have_1panel=1
    else
      have_1panel=0
    fi

    render_section_header "IPv4 防火墙管理"
    echo -e "  ${L}│${N}  SSH 端口  ${D}·${N}  ${C}${ssh_port}${N}"
    if [ "$have_1panel" -eq 1 ]; then
      echo -e "  ${L}│${N}  ${R}${B}已托管${N}    ${D}·${N}  ${Y}1Panel 在管理 IPv4 防火墙，本菜单写入操作已禁用${N}"
    elif [ -n "$conflicts" ]; then
      echo -e "  ${L}│${N}  ${R}${B}冲突警告${N}  ${D}·${N}  ${Y}检测到 ${C}${conflicts}${N}${Y} 在管理 IPv4 防火墙${N}"
      echo -e "  ${L}│${N}  ${D}            本菜单直接改 iptables，可能与上述工具冲突或被覆盖${N}"
    fi
    echo -e "  ${L}│${N}  说明      ${D}·${N}  ${D}本菜单只动 IPv4，不影响 IPv6 / Docker FORWARD${N}"
    render_divider
    render_menu_item 1 "查看当前规则"
    render_menu_item 2 "查看监听 IPv4 的服务"
    if [ "$have_1panel" -eq 1 ]; then
      render_menu_item 3 "一键初始化 (放行 SSH/80/443)  ${R}[已禁用·1Panel 托管]${N}"
      render_menu_item 4 "开放端口  ${R}[已禁用·1Panel 托管]${N}"
      render_menu_item 5 "关闭端口  ${R}[已禁用·1Panel 托管]${N}"
      render_menu_item 6 "紧急放行 (关闭 v4 防火墙)  ${R}[已禁用·1Panel 托管]${N}"
    else
      render_menu_item 3 "一键初始化 (放行 SSH/80/443)"
      render_menu_item 4 "开放端口"
      render_menu_item 5 "关闭端口"
      render_menu_item 6 "紧急放行 (关闭 v4 防火墙)"
    fi
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1) ip4_view_rules ;;
      2) ip4_view_listening ;;
      3|4|5|6)
        if [ "$have_1panel" -eq 1 ]; then
          echo ""
          echo -e "  ${Y}1Panel 正在管理 IPv4 防火墙，本项已禁用${N}"
          echo -e "  ${D}请到 1Panel Web 面板「主机 → 防火墙」管理 IPv4 端口策略${N}"
          pause_screen
        else
          case $choice in
            3) ip4_init_firewall ;;
            4) ip4_open_port ;;
            5) ip4_close_port ;;
            6) ip4_emergency_disable ;;
          esac
        fi
        ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

ip4_view_rules(){
  local input_policy output_policy forward_policy opened

  input_policy=$(ip4_get_input_policy)
  output_policy=$(iptables -L OUTPUT -n 2>/dev/null | head -n1 | awk '{gsub(/\)/, "", $4); print $4}')
  forward_policy=$(iptables -L FORWARD -n 2>/dev/null | head -n1 | awk '{gsub(/\)/, "", $4); print $4}')

  echo ""
  echo -e "  ${B}${C}默认策略${N}"
  echo -e "  INPUT   : ${C}${input_policy}${N}  ${D}(别人主动连你)${N}"
  echo -e "  OUTPUT  : ${C}${output_policy}${N}  ${D}(你主动出去连别人)${N}"
  echo -e "  FORWARD : ${C}${forward_policy}${N}  ${D}(转发, Docker 用, 脚本不动)${N}"
  echo ""

  echo -e "  ${B}${C}已开放的入站端口${N}"
  opened=$(iptables-save 2>/dev/null | awk '
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
  iptables -L INPUT -n -v --line-numbers
  pause_screen
}

ip4_view_listening(){
  echo ""
  echo -e "  ${B}${C}监听 IPv4 的服务${N}"
  render_divider
  echo -e "  ${Y}TCP${N}"
  if ! ss -4tlnp 2>/dev/null; then
    echo -e "  ${R}ss 不可用${N}"
  fi
  echo ""
  echo -e "  ${Y}UDP${N}"
  if ! ss -4ulnp 2>/dev/null; then
    echo -e "  ${R}ss 不可用${N}"
  fi
  echo ""
  echo -e "  ${D}提示：监听 0.0.0.0 表示接受所有 IPv4 客户端${N}"
  pause_screen
}

ip4_init_firewall(){
  local ssh_port confirm conflicts
  local backup_rules="" rb_choice="y" rb_pid="" rb_seconds=180

  ssh_port=$(ip6_detect_ssh_port)
  conflicts=$(ip4_detect_conflicts)

  echo ""
  echo -e "  ${B}${C}一键初始化${N}"
  render_divider
  echo "  本次会执行："
  echo "    1) 清空当前 IPv4 INPUT 规则"
  echo "    2) 放行回环 lo"
  echo "    3) 放行已建立的连接 (ESTABLISHED, RELATED)"
  echo "    4) 放行 ICMP (ping 等必需)"
  echo -e "    5) 放行 SSH 端口: ${C}${ssh_port}${N}/tcp  ${D}(自动检测)${N}"
  echo "    6) 放行 80/tcp"
  echo "    7) 放行 443/tcp"
  echo "    8) INPUT 默认策略 = DROP"
  echo "    9) OUTPUT 保持 ACCEPT"
  echo "   10) FORWARD 不动 (留给 Docker)"
  echo ""
  echo -e "  ${D}注意：节点端口（Reality TCP / Hysteria2 UDP）不在此初始化范围内，${N}"
  echo -e "  ${D}      请在初始化完成后到本菜单 ${C}4) 开放端口${N} ${D}里手动放行。${N}"
  echo ""

  # 锁库前置检查 1：sshd 必须真的在 ssh_port 监听
  if ! verify_sshd_listening_on_port "$ssh_port"; then
    echo -e "  ${R}${B}严重警告：sshd 未在 ${ssh_port}/tcp 上监听${N}"
    echo -e "  ${Y}如果应用规则会立即锁死所有 SSH 连接。请确认：${N}"
    echo -e "    1) sshd 服务是否运行：systemctl status ssh"
    echo -e "    2) sshd 实际端口：ss -tlnp | grep sshd"
    echo ""
    read -p "  仍要继续吗？输入大写 ${R}YES${N} 强制继续: " confirm
    if [ "$confirm" != "YES" ]; then
      echo -e "  已取消"
      sleep 1
      return 0
    fi
  fi

  if [ -n "$conflicts" ]; then
    echo -e "  ${R}${B}警告：检测到 ${conflicts} 在管理防火墙${N}"
    echo -e "  ${Y}继续可能与上述工具冲突或被覆盖。如果你用 1Panel / ufw / firewalld 管 IPv4，${N}"
    echo -e "  ${Y}建议在那边管，本菜单留给纯 iptables 用户。${N}"
    echo ""
  fi

  if ip4_check_current_ssh_v4; then
    echo -e "  ${R}${B}重要：你当前 SSH 是 IPv4 进来的${N}"
    echo -e "  ${R}${B}如果上面检测的 SSH 端口 ${ssh_port} 不对，应用规则后你会立刻断开${N}"
    echo -e "  ${Y}请先单独开个新会话测试 ssh root@<本机IP> -p ${ssh_port} 能不能连上${N}"
    echo ""
  fi

  read -p "  确认继续？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  # 兜底问询：是否启用延时自动回滚守护
  echo ""
  echo -e "  ${B}延时自动回滚守护（强烈建议启用）${N}"
  echo -e "  ${D}若启用，规则应用后会启动后台守护，${rb_seconds} 秒内若你未手动取消，将自动恢复旧规则${N}"
  echo -e "  ${D}规则生效后请立即开新终端验证 SSH 仍可登录，再回此菜单选「6) 紧急放行」之外的任意项即可取消守护${N}"
  read -p "  启用 ${rb_seconds}s 自动回滚守护？(Y/n): " rb_choice
  if [ "$rb_choice" = "n" ] || [ "$rb_choice" = "N" ]; then
    rb_choice="n"
  else
    rb_choice="y"
    backup_rules=$(mktemp /tmp/leyili-iptables-rb.XXXXXX 2>/dev/null) || backup_rules=""
    if [ -n "$backup_rules" ]; then
      iptables-save > "$backup_rules" 2>/dev/null || { rm -f "$backup_rules"; backup_rules=""; }
    fi
  fi

  if ! ip6_ensure_persistence; then
    echo ""
    echo -e "${R}持久化工具安装失败${N}"
    [ -n "$backup_rules" ] && rm -f "$backup_rules"
    pause_screen
    return 1
  fi

  iptables -F INPUT
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A INPUT -p icmp -j ACCEPT
  iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
  iptables -A INPUT -p tcp --dport 80 -j ACCEPT
  iptables -A INPUT -p tcp --dport 443 -j ACCEPT
  iptables -P INPUT DROP
  iptables -P OUTPUT ACCEPT

  # 自动恢复 reality / hy2 / anytls 节点主端口放行（IPv4 侧）
  # 仅在节点 Mode 为 ipv4 / dualstack 时需要
  local node_port node_mode
  if node_installed reality; then
    node_port=$(get_node_value reality Port 2>/dev/null || true)
    node_mode=$(get_node_value reality Mode 2>/dev/null || echo ipv4)
    if [ -n "$node_port" ] \
       && { [ "$node_mode" = "ipv4" ] || [ "$node_mode" = "dualstack" ]; }; then
      iptables -C INPUT -p tcp --dport "$node_port" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport "$node_port" -j ACCEPT 2>/dev/null || true
      echo -e "  ${G}已自动恢复 reality 主端口放行：${node_port}/tcp${N}"
    fi
  fi
  if node_installed hy2; then
    node_port=$(get_node_value hy2 Port 2>/dev/null || true)
    node_mode=$(get_node_value hy2 Mode 2>/dev/null || echo ipv4)
    if [ -n "$node_port" ] \
       && { [ "$node_mode" = "ipv4" ] || [ "$node_mode" = "dualstack" ]; }; then
      iptables -C INPUT -p udp --dport "$node_port" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p udp --dport "$node_port" -j ACCEPT 2>/dev/null || true
      echo -e "  ${G}已自动恢复 hy2 主端口放行：${node_port}/udp${N}"
    fi
  fi
  if node_installed anytls; then
    node_port=$(get_node_value anytls Port 2>/dev/null || true)
    node_mode=$(get_node_value anytls Mode 2>/dev/null || echo ipv4)
    if [ -n "$node_port" ] \
       && { [ "$node_mode" = "ipv4" ] || [ "$node_mode" = "dualstack" ]; }; then
      iptables -C INPUT -p tcp --dport "$node_port" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport "$node_port" -j ACCEPT 2>/dev/null || true
      echo -e "  ${G}已自动恢复 anytls 主端口放行：${node_port}/tcp${N}"
    fi
  fi
  if node_installed tuic; then
    node_port=$(get_node_value tuic Port 2>/dev/null || true)
    node_mode=$(get_node_value tuic Mode 2>/dev/null || echo ipv4)
    if [ -n "$node_port" ] \
       && { [ "$node_mode" = "ipv4" ] || [ "$node_mode" = "dualstack" ]; }; then
      iptables -C INPUT -p udp --dport "$node_port" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p udp --dport "$node_port" -j ACCEPT 2>/dev/null || true
      echo -e "  ${G}已自动恢复 tuic 主端口放行：${node_port}/udp${N}"
    fi
  fi
  if node_installed ss2022; then
    node_port=$(get_node_value ss2022 Port 2>/dev/null || true)
    node_mode=$(get_node_value ss2022 Mode 2>/dev/null || echo ipv4)
    if [ -n "$node_port" ] \
       && { [ "$node_mode" = "ipv4" ] || [ "$node_mode" = "dualstack" ]; }; then
      iptables -C INPUT -p tcp --dport "$node_port" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport "$node_port" -j ACCEPT 2>/dev/null || true
      echo -e "  ${G}已自动恢复 ss2022 主端口放行：${node_port}/tcp${N}"
    fi
  fi

  # 应用后再次校验 sshd 监听依然存在（防止备份/检测误差）
  if ! verify_sshd_listening_on_port "$ssh_port"; then
    if [ -n "$backup_rules" ]; then
      iptables-restore < "$backup_rules" 2>/dev/null || true
      rm -f "$backup_rules"
      echo -e "${R}应用后 sshd 在 ${ssh_port} 上未监听，已自动回滚到旧规则${N}"
    else
      echo -e "${R}应用后 sshd 在 ${ssh_port} 上未监听，但你未启用回滚守护，请尽快人工处理${N}"
    fi
    pause_screen
    return 1
  fi

  if ! ip4_save_rules; then
    echo -e "${Y}规则已生效，但持久化失败，重启后可能丢失${N}"
  fi

  echo ""
  echo -e "${G}IPv4 防火墙已启用${N}"

  # 启动延时回滚守护
  if [ "$rb_choice" = "y" ] && [ -n "$backup_rules" ]; then
    rb_pid=$(schedule_iptables_rollback "$rb_seconds" "$backup_rules" "")
    if [ -n "$rb_pid" ]; then
      echo -e "  ${Y}延时回滚守护已启动 (PID ${rb_pid})，${rb_seconds}s 后自动恢复旧规则${N}"
      echo -e "  ${B}请在 ${rb_seconds} 秒内开新终端验证 SSH 可登录，然后执行：${N}"
      echo -e "    ${C}kill ${rb_pid} && rm -f ${backup_rules}${N}  ${D}# 取消回滚${N}"
      echo -e "  ${D}（也可以直接等待 ${rb_seconds}s 让规则被自动撤销）${N}"
    fi
  fi
  pause_screen
}

ip4_open_port(){
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
    if iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
      echo -e "  ${Y}${port}/${proto} 已放行，跳过${N}"
    else
      iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT
      echo -e "  ${G}已放行 ${port}/${proto}${N}"
      changed=1
    fi
  done

  if [ "$changed" -eq 1 ]; then
    if ! ip4_save_rules; then
      echo -e "${Y}持久化失败${N}"
    fi
  fi
  pause_screen
}

ip4_close_port(){
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
    echo -e "  ${R}${B}严重警告：${port}/tcp 是当前 SSH 端口${N}"
    echo -e "  ${R}${B}关闭后你的 IPv4 SSH 会立刻断开${N}"
    read -p "  确认继续？输入大写 YES 才继续: " confirm
    if [ "$confirm" != "YES" ]; then
      echo -e "  已取消"
      sleep 1
      return 0
    fi
  fi

  for proto in $protos; do
    while iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; do
      iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT
      echo -e "  ${G}已删除 ${port}/${proto}${N}"
      removed=$((removed + 1))
    done
  done

  if [ "$removed" -eq 0 ]; then
    echo -e "  ${Y}端口 ${port} 在所选协议下没有放行规则${N}"
  else
    if ! ip4_save_rules; then
      echo -e "${Y}持久化失败${N}"
    fi
  fi
  pause_screen
}

ip4_emergency_disable(){
  local confirm confirm2

  echo ""
  echo -e "  ${R}${B}紧急放行（关闭 v4 防火墙）${N}"
  render_divider
  echo "  执行后："
  echo "    - 清空所有 IPv4 INPUT 规则"
  echo "    - 默认策略改回 ACCEPT"
  echo "    - v4 入站回到完全裸奔状态"
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

  iptables -P INPUT ACCEPT
  iptables -F INPUT
  if ! ip4_save_rules; then
    echo -e "${Y}持久化失败${N}"
  fi

  echo ""
  echo -e "${Y}已关闭 v4 防火墙（INPUT=ACCEPT 且规则清空）${N}"
  pause_screen
}

