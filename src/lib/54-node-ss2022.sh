generate_ss2022_random_port(){
  local p attempts=0
  while [ $attempts -lt 30 ]; do
    p=$(( (RANDOM << 15 | RANDOM) % 45535 + 20000 ))
    attempts=$((attempts + 1))
    if ! check_port_in_use "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  printf '%s' "$p"
}

# SS-2022 密钥长度由加密方式决定：
#   2022-blake3-aes-128-gcm        → 16 bytes
#   2022-blake3-aes-256-gcm        → 32 bytes
#   2022-blake3-chacha20-poly1305  → 32 bytes
generate_ss2022_password(){
  local method="${1:-2022-blake3-aes-128-gcm}"
  local bytes=16
  case "$method" in
    *aes-128-gcm)                       bytes=16 ;;
    *aes-256-gcm|*chacha20-poly1305)    bytes=32 ;;
  esac
  if ! command -v openssl >/dev/null 2>&1; then
    return 1
  fi
  openssl rand -base64 "$bytes" | tr -d '\r\n'
}

install_ss2022_node(){
  local port_input=""
  local access_ip="" link="" ipv6_link=""
  local public_ipv4="" public_ipv6=""
  local install_mode="ipv4" mode_label=""
  local PORT TAG LISTEN_CHOICE LISTEN_ADDR METHOD PASSWORD METHOD_CHOICE confirm
  local default_port

  if ! require_root; then return 1; fi

  render_section_header "创建 Shadowsocks-2022 节点"
  echo -e "  ${R}⚠ 谨慎：SS-2022 抗主动探测能力弱于 Reality / Hysteria2${N}"
  echo -e "  ${R}  在被高强度 GFW 主动探测的链路上更容易被识别${N}"
  echo -e "  ${D}  建议仅在低风险环境（落地中转 / 跨境企业线路）使用${N}"
  echo -e "  ${Y}直接回车使用括号内默认值${N}"
  echo ""

  if node_installed ss2022; then
    echo -e "${Y}检测到已存在 Shadowsocks-2022 节点，继续将覆盖原节点配置${N}"
    read -p "  继续？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo -e "  已取消"
      return 0
    fi
  fi

  default_port=$(generate_ss2022_random_port)
  while true; do
    read -p "  端口 (${default_port}): " port_input
    PORT="${port_input:-$default_port}"
    if ! validate_port "$PORT"; then
      echo -e "${R}端口必须是 1-65535 的数字${N}"
      continue
    fi
    PORT=$((10#$PORT))
    if check_port_in_use "$PORT"; then
      echo -e "${R}端口 ${PORT} 已被其他服务占用${N}"
      local force_port=""
      read -p "  仍然使用此端口？(y/N): " force_port
      if [ "$force_port" != "y" ] && [ "$force_port" != "Y" ]; then
        continue
      fi
    fi
    break
  done

  read -p "  节点名称 (ss2022): " TAG
  TAG="${TAG:-ss2022}"

  echo -e "  加密方式："
  echo -e "    1) 2022-blake3-aes-128-gcm        ${D}(默认，AES-NI 性能最佳)${N}"
  echo -e "    2) 2022-blake3-aes-256-gcm        ${D}(更高安全冗余，CPU 开销略增)${N}"
  echo -e "    3) 2022-blake3-chacha20-poly1305  ${D}(无 AES 硬件加速时更快)${N}"
  read -p "  请选择 (1): " METHOD_CHOICE
  case "$METHOD_CHOICE" in
    2) METHOD="2022-blake3-aes-256-gcm" ;;
    3) METHOD="2022-blake3-chacha20-poly1305" ;;
    *) METHOD="2022-blake3-aes-128-gcm" ;;
  esac

  echo -e "  监听模式："
  echo "    1) 仅 IPv4 入站 - 0.0.0.0（默认）"
  echo "    2) 双栈入站 - ::"
  echo "    3) 仅 IPv6 入站"
  read -p "  请选择 (1): " LISTEN_CHOICE
  case "$LISTEN_CHOICE" in
    2) LISTEN_ADDR="::"; install_mode="dualstack" ;;
    3) LISTEN_ADDR=""; install_mode="ipv6-in-ipv4-out" ;;
    *) LISTEN_ADDR="0.0.0.0"; install_mode="ipv4" ;;
  esac

  if [ "$install_mode" = "ipv6-in-ipv4-out" ]; then
    public_ipv6=$(detect_primary_ipv6)
    if [ -z "$public_ipv6" ]; then
      echo ""
      echo -e "${R}未检测到可用的 IPv6 地址，无法使用“仅 IPv6 入站”模式${N}"
      pause_screen
      return 1
    fi
  fi

  if ! is_singbox_installed; then
    echo ""
    echo -e "${Y}==> 安装 sing-box...${N}"
    if ! install_singbox; then
      echo ""
      echo -e "${R}sing-box 安装失败，请检查上方输出${N}"
      pause_screen
      return 1
    fi
  fi

  echo -e "${Y}==> 生成 SS-2022 密钥...${N}"
  PASSWORD=$(generate_ss2022_password "$METHOD")
  if [ -z "$PASSWORD" ]; then
    echo ""
    echo -e "${R}密钥生成失败（缺少 openssl?）${N}"
    pause_screen
    return 1
  fi

  public_ipv4=${public_ipv4:-$(detect_primary_ipv4)}
  public_ipv6=${public_ipv6:-$(detect_primary_ipv6)}

  case "$install_mode" in
    ipv6-in-ipv4-out)
      access_ip="$public_ipv6"
      LISTEN_ADDR="$public_ipv6"
      if [ -z "$access_ip" ]; then
        echo ""
        echo -e "${R}未检测到可用的 IPv6 地址${N}"
        pause_screen
        return 1
      fi
      ;;
    dualstack)
      access_ip="${public_ipv4:-$public_ipv6}"
      if [ -z "$access_ip" ]; then
        echo ""
        echo -e "${R}未检测到可用的 IPv4 / IPv6 地址${N}"
        pause_screen
        return 1
      fi
      ;;
    *)
      access_ip="$public_ipv4"
      if [ -z "$access_ip" ]; then
        echo ""
        echo -e "${R}未检测到可用的 IPv4 地址，请检查网络环境${N}"
        pause_screen
        return 1
      fi
      ;;
  esac

  mode_label=$(describe_install_mode "$install_mode")

  echo -e "${Y}==> 写入配置...${N}"
  ensure_jq || { pause_screen; return 1; }

  # network=tcp 屏蔽 UDP relay：减小攻击面，单一 TCP 防火墙规则
  local inbound_json
  inbound_json=$(jq -n \
    --arg listen "$LISTEN_ADDR" \
    --argjson port "$PORT" \
    --arg method "$METHOD" \
    --arg password "$PASSWORD" '{
      type: "shadowsocks",
      tag: "ss2022-in",
      listen: $listen,
      listen_port: $port,
      network: "tcp",
      method: $method,
      password: $password
    }')

  if ! config_add_inbound "$inbound_json"; then
    echo -e "${R}写入 inbound 失败${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 校验并启动...${N}"
  if ! config_check_and_restart; then
    echo ""
    echo -e "${R}sing-box 校验或重启失败${N}"
    pause_screen
    return 1
  fi

  node_apply_firewall_for_mode "$PORT" tcp "$install_mode"
  print_firewall_hint "$PORT" tcp "Shadowsocks-2022 节点入站"

  link=$(build_ss2022_link "$METHOD" "$PASSWORD" "$access_ip" "$PORT" "$TAG" 2>/dev/null || true)
  if [ "$install_mode" = "dualstack" ] && [ -n "$public_ipv6" ] && [ "$public_ipv6" != "$access_ip" ]; then
    ipv6_link=$(build_ss2022_link "$METHOD" "$PASSWORD" "$public_ipv6" "$PORT" "${TAG}-ipv6" 2>/dev/null || true)
  fi

  ensure_nodes_dir
  cat > "$(node_info_path ss2022)" <<EOF
Type=ss2022
Tag=$TAG
Mode=$install_mode
ListenAddr=$LISTEN_ADDR
Port=$PORT
Method=$METHOD
Password=$PASSWORD
IP=$access_ip
Link=$link
EOF

  register_sb_command || true

  echo ""
  echo -e "  ${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "  ${G}║${N}  ${B}${W}${APP_NAME}${N}  ${G}Shadowsocks-2022 节点创建完成${N}              ${G}║${N}"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${N}"
  echo -e "  模式      : ${C}$mode_label${N}"
  echo -e "  加密方式  : ${C}$METHOD${N}"
  echo -e "  Password  : ${C}$PASSWORD${N}"
  echo -e "  入口 IP   : ${C}${access_ip:-未知}${N}"
  echo -e "  端口      : ${C}$PORT${N} ${D}(TCP)${N}"
  if [ -n "$link" ]; then
    echo ""
    echo -e "  ${B}客户端链接：${N}"
    echo -e "  ${G}$link${N}"
    print_qrcode "$link"
  fi
  if [ -n "$ipv6_link" ]; then
    echo ""
    echo -e "  ${B}IPv6 客户端链接：${N}"
    echo -e "  ${G}$ipv6_link${N}"
    print_qrcode "$ipv6_link"
  fi
  echo ""
  echo -e "  ${R}⚠ SS-2022 抗主动探测较弱，建议结合 CDN / 中转或仅在低风险环境使用${N}"
  echo -e "  ${D}  默认仅启用 TCP；如需 UDP relay 请手动编辑 /etc/sing-box/config.json${N}"
  echo -e "  信息已保存至 ${Y}$(node_info_path ss2022)${N}"
  echo -e "  输入 ${B}${COMMAND_NAME}${N} 进入管理菜单"
  pause_screen
}

uninstall_ss2022_node(){
  local confirm
  if ! node_installed ss2022; then
    echo -e "${Y}Shadowsocks-2022 节点未安装${N}"
    pause_screen
    return 0
  fi
  echo ""
  read -p "  确认卸载 Shadowsocks-2022 节点？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  # 必须在 remove_node_info 之前撤防火墙规则，否则读不到 Mode/Port
  local ss_port ss_mode
  ss_port=$(get_node_value ss2022 Port 2>/dev/null || true)
  ss_mode=$(get_node_value ss2022 Mode 2>/dev/null || echo ipv4)
  if [ -n "$ss_port" ]; then
    node_revoke_firewall_for_mode "$ss_port" tcp "$ss_mode"
  fi

  config_remove_inbound_by_tag "ss2022-in" || true
  remove_node_info ss2022
  post_uninstall_service_step
  echo -e "${G}Shadowsocks-2022 节点已卸载${N}"
  pause_screen
}
