install_reality_node(){
  local port_input="" sni_input=""
  local keypair="" private_key="" public_key=""
  local access_ip="" link="" ipv6_link=""
  local public_ipv4="" public_ipv6=""
  local install_mode="ipv4" mode_label=""
  local PORT SNI TAG LISTEN_CHOICE LISTEN_ADDR UUID SHORT_ID confirm
  local txn="" old_port="" old_mode="ipv4"

  if ! require_root; then return 1; fi

  render_section_header "创建 Reality 节点"
  echo -e "  ${Y}直接回车使用括号内默认值${N}"
  echo ""

  if node_installed reality; then
    echo -e "${Y}检测到已存在 Reality 节点，继续将覆盖原节点配置${N}"
    read -p "  继续？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo -e "  已取消"
      return 0
    fi
    old_port=$(get_node_value reality Port 2>/dev/null || true)
    old_mode=$(get_node_value reality Mode 2>/dev/null || echo ipv4)
  fi

  while true; do
    read -p "  端口 (8443): " port_input
    PORT="${port_input:-8443}"
    if ! validate_port "$PORT"; then
      echo -e "${R}端口必须是 1-65535 的数字${N}"
      continue
    fi
    PORT=$((10#$PORT))
    if [ "$PORT" != "$old_port" ] && check_port_in_use "$PORT" tcp; then
      echo -e "${R}端口 ${PORT} 已被其他服务占用${N}"
      local force_port=""
      read -p "  仍然使用此端口？(y/N): " force_port
      if [ "$force_port" != "y" ] && [ "$force_port" != "Y" ]; then
        continue
      fi
    fi
    break
  done

  while true; do
    read -p "  域名 (www.tesla.com): " sni_input
    sni_input="${sni_input:-www.tesla.com}"
    SNI=$(sanitize_sni "$sni_input")
    if [ -n "$SNI" ]; then
      break
    fi
    echo -e "${R}域名不能为空，且不能只包含引号或换行${N}"
  done

  read -p "  节点名称 (reality): " TAG
  TAG="${TAG:-reality}"

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

  echo -e "${Y}==> 生成参数...${N}"
  UUID=$(cat /proc/sys/kernel/random/uuid)
  SHORT_ID=$(openssl rand -hex 4)
  if ! keypair=$(sing-box generate reality-keypair); then
    echo ""
    echo -e "${R}密钥对生成失败${N}"
    pause_screen
    return 1
  fi
  private_key=$(echo "$keypair" | grep PrivateKey | awk '{print $2}')
  public_key=$(echo "$keypair" | grep PublicKey | awk '{print $2}')
  if [ -z "$private_key" ] || [ -z "$public_key" ]; then
    echo ""
    echo -e "${R}密钥对解析失败${N}"
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
  txn=$(node_transaction_begin reality) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

  local inbound_json
  inbound_json=$(jq -n \
    --arg listen "$LISTEN_ADDR" \
    --argjson port "$PORT" \
    --arg uuid "$UUID" \
    --arg sni "$SNI" \
    --arg priv "$private_key" \
    --arg sid "$SHORT_ID" '{
      type: "vless",
      tag: "reality-in",
      listen: $listen,
      listen_port: $port,
      users: [{uuid: $uuid, flow: "xtls-rprx-vision"}],
      tls: {
        enabled: true,
        server_name: $sni,
        reality: {
          enabled: true,
          handshake: {server: $sni, server_port: 443},
          private_key: $priv,
          short_id: [$sid]
        }
      }
    }')

  if ! config_add_inbound "$inbound_json"; then
    node_transaction_rollback "$txn"
    echo -e "${R}写入 inbound 失败${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 校验并启动...${N}"
  if ! config_check_and_restart "$PORT" tcp; then
    node_transaction_rollback "$txn"
    echo ""
    echo -e "${R}sing-box 校验或重启失败${N}"
    pause_screen
    return 1
  fi

  if ! node_apply_firewall_for_mode "$PORT" tcp "$install_mode"; then
    node_transaction_rollback "$txn"
    echo -e "${R}防火墙放行失败，节点配置已回滚${N}"
    pause_screen
    return 1
  fi
  print_firewall_hint "$PORT" tcp "Reality 节点入站"

  link=$(build_reality_link "$UUID" "$access_ip" "$PORT" "$SNI" "$public_key" "$SHORT_ID" "$TAG" 2>/dev/null || true)
  if [ "$install_mode" = "dualstack" ] && [ -n "$public_ipv6" ] && [ "$public_ipv6" != "$access_ip" ]; then
    ipv6_link=$(build_reality_link "$UUID" "$public_ipv6" "$PORT" "$SNI" "$public_key" "$SHORT_ID" "${TAG}-ipv6" 2>/dev/null || true)
  fi

  if ! write_node_info_file reality <<EOF
Type=reality
Tag=$TAG
Mode=$install_mode
ListenAddr=$LISTEN_ADDR
Port=$PORT
SNI=$SNI
UUID=$UUID
PublicKey=$public_key
PrivateKey=$private_key
ShortID=$SHORT_ID
IP=$access_ip
Link=$link
EOF
  then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if [ -n "$old_port" ] && [ "$old_port" != "$PORT" ]; then
    if ! node_revoke_firewall_for_mode "$old_port" tcp "$old_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧端口防火墙清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi
  node_transaction_commit "$txn"

  register_sb_command || true

  echo ""
  echo -e "  ${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "  ${G}║${N}  ${B}${W}${APP_NAME}${N}  ${G}Reality 节点创建完成${N}                       ${G}║${N}"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${N}"
  echo -e "  模式      : ${C}$mode_label${N}"
  echo -e "  UUID      : ${C}$UUID${N}"
  echo -e "  PublicKey : ${C}$public_key${N}"
  echo -e "  入口 IP   : ${C}${access_ip:-未知}${N}"
  echo -e "  出站策略  : ${C}双栈（跟随系统路由）${N}"
  echo -e "  端口      : ${C}$PORT${N}"
  echo -e "  SNI       : ${C}$SNI${N}"
  echo ""
  echo -e "  ${B}客户端链接：${N}"
  echo -e "  ${G}${link:-未生成}${N}"
  print_qrcode "${link:-}"
  if [ -n "$ipv6_link" ]; then
    echo ""
    echo -e "  ${B}IPv6 客户端链接：${N}"
    echo -e "  ${G}${ipv6_link}${N}"
    print_qrcode "$ipv6_link"
  fi
  echo ""
  echo -e "  信息已保存至 ${Y}$(node_info_path reality)${N}"
  echo -e "  输入 ${B}${COMMAND_NAME}${N} 进入管理菜单"
  pause_screen
}

config_inbound_count(){
  if [ ! -f "$CONFIG_PATH" ]; then
    printf '0'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  jq -er '(.inbounds // []) | length' "$CONFIG_PATH" 2>/dev/null
}

# 卸载某节点后调用：剩 0 个 inbound 则停服务，否则校验+重启
post_uninstall_service_step(){
  if ! is_singbox_installed; then
    return 0
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    return 0
  fi
  local remain
  remain=$(config_inbound_count) || return 1
  [[ "$remain" =~ ^[0-9]+$ ]] || return 1
  if [ "${remain:-0}" -eq 0 ]; then
    echo -e "${Y}==> 已无任何节点，停止 sing-box 服务...${N}"
    systemctl stop sing-box >/dev/null 2>&1 || return 1
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then
      systemctl disable sing-box >/dev/null 2>&1 || return 1
    fi
    systemctl is-active --quiet sing-box 2>/dev/null && return 1
    return 0
  fi
  config_check_and_restart
}

uninstall_node_transaction(){
  local type="$1" inbound_tag="$2" proto="$3"
  local txn port mode hop_enabled hop_start hop_end

  port=$(get_node_value "$type" Port 2>/dev/null || true)
  mode=$(get_node_value "$type" Mode 2>/dev/null || echo ipv4)
  txn=$(node_transaction_begin "$type") || return 1

  if [ "$type" = "hy2" ]; then
    hop_enabled=$(get_node_value hy2 PortHop 2>/dev/null || echo 0)
    hop_start=$(get_node_value hy2 PortHopStart 2>/dev/null || true)
    hop_end=$(get_node_value hy2 PortHopEnd 2>/dev/null || true)
    if [ "$hop_enabled" = "1" ] && [ -n "$hop_start" ] && [ -n "$hop_end" ]; then
      if ! port_hop_remove "$hop_start" "$hop_end" "$mode"; then
        node_transaction_rollback "$txn"
        return 1
      fi
    fi
  fi

  if [ -n "$port" ] && ! node_revoke_firewall_for_mode "$port" "$proto" "$mode"; then
    node_transaction_rollback "$txn"
    return 1
  fi
  if ! config_remove_inbound_by_tag "$inbound_tag" || ! remove_node_info "$type"; then
    node_transaction_rollback "$txn"
    return 1
  fi
  case "$type" in
    hy2|tuic)
      if ! rm -f -- "$CERTS_DIR/${type}.crt" "$CERTS_DIR/${type}.key"; then
        node_transaction_rollback "$txn"
        return 1
      fi
      ;;
  esac
  if ! post_uninstall_service_step; then
    node_transaction_rollback "$txn"
    return 1
  fi
  node_transaction_commit "$txn"
}

uninstall_reality_node(){
  local confirm
  if ! node_installed reality; then
    echo -e "${Y}Reality 节点未安装${N}"
    pause_screen
    return 0
  fi

  echo ""
  read -p "  确认卸载 Reality 节点？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  if ! uninstall_node_transaction reality reality-in tcp; then
    echo -e "${R}Reality 节点卸载失败，已恢复原配置${N}"
    pause_screen
    return 1
  fi
  echo -e "${G}Reality 节点已卸载${N}"
  pause_screen
}

# 兼容入口：do_install 默认创建 Reality 节点
do_install(){ install_reality_node; }

# ─── 端口跳跃公共逻辑 ─────────────────────────────────
