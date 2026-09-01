install_anytls_node(){
  local port_input="" sni_input=""
  local access_ip="" link="" ipv6_link=""
  local public_ipv4="" public_ipv6=""
  local install_mode="ipv4" mode_label=""
  local PORT SNI TAG LISTEN_CHOICE LISTEN_ADDR PASSWORD confirm
  local default_port default_sni keypair private_key public_key short_id
  local txn="" old_port="" old_mode="ipv4"

  if ! require_root; then return 1; fi

  render_section_header "创建 AnyTLS 节点"
  echo -e "  ${Y}AnyTLS + Reality（独立 Reality 密钥对，与其他节点互不影响）${N}"
  echo -e "  ${Y}直接回车使用括号内默认值${N}"
  echo ""

  # ── sing-box 必须已安装且 >= 1.12
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
  if ! sb_version_at_least 1.12; then
    local cur_ver
    cur_ver=$(get_current_singbox_version)
    echo ""
    echo -e "${R}AnyTLS 协议需要 sing-box ≥ 1.12，当前版本: ${cur_ver:-未知}${N}"
    echo -e "${Y}请先在「主菜单 → 更新管理 → 升级 sing-box 内核」中升级后再创建 AnyTLS 节点${N}"
    pause_screen
    return 1
  fi

  if node_installed anytls; then
    echo -e "${Y}检测到已存在 AnyTLS 节点，继续将覆盖原节点配置${N}"
    read -p "  继续？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo -e "  已取消"
      return 0
    fi
    old_port=$(get_node_value anytls Port 2>/dev/null || true)
    old_mode=$(get_node_value anytls Mode 2>/dev/null || echo ipv4)
  fi

  # ── 端口（默认随机，避开 reality 端口与已占端口）
  default_port=$(generate_anytls_random_port)
  while true; do
    read -p "  端口 (${default_port}): " port_input
    PORT="${port_input:-$default_port}"
    if ! validate_port "$PORT"; then
      echo -e "${R}端口必须是 1-65535 的数字${N}"
      continue
    fi
    PORT=$((10#$PORT))
    local reality_port
    reality_port=$(get_node_value reality Port 2>/dev/null || true)
    if [ -n "$reality_port" ] && [ "$PORT" -eq "$reality_port" ]; then
      echo -e "${R}端口与 Reality 节点冲突（Reality 已使用 ${reality_port}）${N}"
      continue
    fi
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

  # ── SNI（默认 tesla.com；若已装 Reality，沿用其 SNI 提升伪装一致性）
  default_sni=$(get_node_value reality SNI 2>/dev/null || true)
  default_sni="${default_sni:-www.tesla.com}"
  while true; do
    read -p "  域名 (${default_sni}): " sni_input
    sni_input="${sni_input:-$default_sni}"
    SNI=$(sanitize_sni "$sni_input")
    if [ -n "$SNI" ]; then
      break
    fi
    echo -e "${R}域名不能为空，且不能只包含引号或换行${N}"
  done

  read -p "  节点名称 (anytls): " TAG
  TAG="${TAG:-anytls}"

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

  echo -e "${Y}==> 生成 Reality 密钥对 / ShortID...${N}"
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
  short_id=$(openssl rand -hex 4)

  echo -e "${Y}==> 生成 AnyTLS 用户密码...${N}"
  PASSWORD=$(cat /proc/sys/kernel/random/uuid)

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
  txn=$(node_transaction_begin anytls) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

  local inbound_json
  inbound_json=$(jq -n \
    --arg listen "$LISTEN_ADDR" \
    --argjson port "$PORT" \
    --arg password "$PASSWORD" \
    --arg sni "$SNI" \
    --arg priv "$private_key" \
    --arg sid "$short_id" '{
      type: "anytls",
      tag: "anytls-in",
      listen: $listen,
      listen_port: $port,
      users: [{name: "default", password: $password}],
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
  print_firewall_hint "$PORT" tcp "AnyTLS 节点入站"

  link=$(build_anytls_link "$PASSWORD" "$access_ip" "$PORT" "$SNI" "$public_key" "$short_id" "$TAG" 2>/dev/null || true)
  if [ "$install_mode" = "dualstack" ] && [ -n "$public_ipv6" ] && [ "$public_ipv6" != "$access_ip" ]; then
    ipv6_link=$(build_anytls_link "$PASSWORD" "$public_ipv6" "$PORT" "$SNI" "$public_key" "$short_id" "${TAG}-ipv6" 2>/dev/null || true)
  fi

  if ! write_node_info_file anytls <<EOF
Type=anytls
Tag=$TAG
Mode=$install_mode
ListenAddr=$LISTEN_ADDR
Port=$PORT
SNI=$SNI
Password=$PASSWORD
PublicKey=$public_key
PrivateKey=$private_key
ShortID=$short_id
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
  echo -e "  ${G}║${N}  ${B}${W}${APP_NAME}${N}  ${G}AnyTLS 节点创建完成${N}                        ${G}║${N}"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${N}"
  echo -e "  模式      : ${C}$mode_label${N}"
  echo -e "  Password  : ${C}$PASSWORD${N}"
  echo -e "  PublicKey : ${C}$public_key${N}"
  echo -e "  IP        : ${C}$access_ip${N}"
  echo -e "  端口      : ${C}$PORT${N} ${D}(TCP)${N}"
  echo -e "  SNI       : ${C}$SNI${N}"
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
  echo -e "  ${Y}注意：AnyTLS + Reality 仅 sing-box 1.12+ / Xray-core 25.x+ 客户端支持${N}"
  echo -e "  ${D}      Mihomo / Clash 系客户端目前不支持${N}"
  echo -e "  信息已保存至 ${Y}$(node_info_path anytls)${N}"
  pause_screen
}

install_tuic_node(){
  local port_input="" sni_input=""
  local PORT SNI TAG LISTEN_CHOICE LISTEN_ADDR install_mode="ipv4"
  local cert_choice cert_source="self" acme_email=""
  local UUID PASSWORD cc_choice CC="bbr"
  local public_ipv4="" public_ipv6="" access_ip=""
  local link="" ipv6_link="" mode_label="" confirm
  local cert_paths cert_path key_path
  local txn="" old_port="" old_mode="ipv4"

  if ! require_root; then return 1; fi

  render_section_header "创建 TUIC v5 节点"
  echo -e "  ${Y}直接回车使用括号内默认值${N}"
  echo ""

  if node_installed tuic; then
    echo -e "${Y}检测到已存在 TUIC 节点，继续将覆盖原节点配置${N}"
    read -p "  继续？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo -e "  已取消"
      return 0
    fi
    old_port=$(get_node_value tuic Port 2>/dev/null || true)
    old_mode=$(get_node_value tuic Mode 2>/dev/null || echo ipv4)
  fi

  # 端口（默认随机高位 UDP，复用 hy2 的端口生成器）
  local default_port
  default_port=$(generate_hy2_random_port)
  while true; do
    read -p "  端口 (${default_port}, 回车随机): " port_input
    PORT="${port_input:-$default_port}"
    if validate_port "$PORT"; then
      PORT=$((10#$PORT))
      if [ "$PORT" != "$old_port" ] && check_port_in_use "$PORT" udp; then
        echo -e "${R}UDP 端口 ${PORT} 已被其他服务占用${N}"
        local force_port=""
        read -p "  仍然使用此端口？(y/N): " force_port
        if [ "$force_port" != "y" ] && [ "$force_port" != "Y" ]; then
          continue
        fi
      fi
      break
    fi
    echo -e "${R}端口必须是 1-65535 的数字${N}"
  done

  # 节点名
  read -p "  节点名称 (tuic): " TAG
  TAG="${TAG:-tuic}"

  # 监听模式
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

  # 证书来源
  echo -e "  证书来源："
  echo "    1) 自签证书（推荐，客户端 insecure=1）（默认）"
  echo "    2) ACME 自动签发（需要真实域名 + 80 端口可用）"
  read -p "  请选择 (1): " cert_choice
  case "$cert_choice" in
    2) cert_source="acme" ;;
    *) cert_source="self" ;;
  esac

  # SNI / 域名
  if [ "$cert_source" = "acme" ]; then
    while true; do
      read -p "  真实域名（已解析到本机）: " sni_input
      sni_input="${sni_input:-}"
      SNI=$(sanitize_sni "$sni_input")
      if [ -n "$SNI" ]; then break; fi
      echo -e "${R}ACME 模式必须提供真实域名${N}"
    done
    while true; do
      read -p "  ACME 邮箱: " acme_email
      if [ -n "$acme_email" ] && printf '%s' "$acme_email" | grep -q "@"; then break; fi
      echo -e "${R}邮箱不能为空，且必须包含 @${N}"
    done
  else
    while true; do
      read -p "  伪装 SNI (bing.com): " sni_input
      sni_input="${sni_input:-bing.com}"
      SNI=$(sanitize_sni "$sni_input")
      if [ -n "$SNI" ]; then break; fi
      echo -e "${R}SNI 不能为空${N}"
    done
  fi

  # 拥塞控制
  echo -e "  拥塞控制算法："
  echo "    1) bbr   （默认，推荐，多数场景速度最快）"
  echo "    2) cubic （对 TCP 友好，与其他流量并存时更平稳）"
  read -p "  请选择 (1): " cc_choice
  case "$cc_choice" in
    2) CC="cubic" ;;
    *) CC="bbr" ;;
  esac

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
  if ! command -v openssl >/dev/null 2>&1; then
    echo -e "${R}缺少 openssl${N}"
    pause_screen
    return 1
  fi
  UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
  if [ -z "$UUID" ] && command -v sing-box >/dev/null 2>&1; then
    UUID=$(sing-box generate uuid 2>/dev/null)
  fi
  if [ -z "$UUID" ]; then
    echo -e "${R}UUID 生成失败${N}"
    pause_screen
    return 1
  fi
  PASSWORD=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-22)

  public_ipv4=${public_ipv4:-$(detect_primary_ipv4)}
  public_ipv6=${public_ipv6:-$(detect_primary_ipv6)}

  case "$install_mode" in
    ipv6-in-ipv4-out)
      access_ip="$public_ipv6"
      LISTEN_ADDR="$public_ipv6"
      [ -z "$access_ip" ] && { echo -e "${R}未检测到 IPv6${N}"; pause_screen; return 1; }
      ;;
    dualstack)
      access_ip="${public_ipv4:-$public_ipv6}"
      [ -z "$access_ip" ] && { echo -e "${R}未检测到 IPv4 / IPv6${N}"; pause_screen; return 1; }
      ;;
    *)
      access_ip="$public_ipv4"
      [ -z "$access_ip" ] && { echo -e "${R}未检测到 IPv4${N}"; pause_screen; return 1; }
      ;;
  esac

  mode_label=$(describe_install_mode "$install_mode")

  echo -e "${Y}==> 建立节点事务快照...${N}"
  ensure_jq || { pause_screen; return 1; }
  txn=$(node_transaction_begin tuic) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

  # 准备证书
  if [ "$cert_source" = "self" ]; then
    echo -e "${Y}==> 生成自签证书...${N}"
    if ! cert_paths=$(generate_self_signed_cert_for_tuic "$SNI"); then
      node_transaction_rollback "$txn"
      pause_screen
      return 1
    fi
    cert_path=$(echo "$cert_paths" | sed -n '1p')
    key_path=$(echo "$cert_paths" | sed -n '2p')
  fi

  echo -e "${Y}==> 写入配置...${N}"

  local tls_json
  if [ "$cert_source" = "acme" ]; then
    if ! tls_json=$(jq -n --arg sni "$SNI" --arg email "$acme_email" '{
      enabled: true,
      server_name: $sni,
      alpn: ["h3"],
      certificate_provider: {type: "acme", domain: [$sni], email: $email}
    }'); then
      node_transaction_rollback "$txn"
      pause_screen
      return 1
    fi
  else
    if ! tls_json=$(jq -n --arg sni "$SNI" --arg crt "$cert_path" --arg key "$key_path" '{
      enabled: true,
      server_name: $sni,
      alpn: ["h3"],
      certificate_path: $crt,
      key_path: $key
    }'); then
      node_transaction_rollback "$txn"
      pause_screen
      return 1
    fi
  fi

  local user_obj
  if ! user_obj=$(jq -n --arg uuid "$UUID" --arg pw "$PASSWORD" '{uuid: $uuid, password: $pw}'); then
    node_transaction_rollback "$txn"
    pause_screen
    return 1
  fi

  local inbound_json
  if ! inbound_json=$(jq -n \
    --arg listen "$LISTEN_ADDR" \
    --argjson port "$PORT" \
    --argjson user "$user_obj" \
    --argjson tls "$tls_json" \
    --arg cc "$CC" '
    {
      type: "tuic",
      tag: "tuic-in",
      listen: $listen,
      listen_port: $port,
      users: [$user],
      congestion_control: $cc,
      auth_timeout: "3s",
      zero_rtt_handshake: false,
      heartbeat: "10s",
      tls: $tls
    }'); then
    node_transaction_rollback "$txn"
    pause_screen
    return 1
  fi

  if ! config_add_inbound "$inbound_json"; then
    node_transaction_rollback "$txn"
    echo -e "${R}写入 inbound 失败${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 校验并启动...${N}"
  if ! config_check_and_restart "$PORT" udp; then
    node_transaction_rollback "$txn"
    echo ""
    echo -e "${R}sing-box 校验或重启失败${N}"
    pause_screen
    return 1
  fi

  if [ -n "$old_port" ] && { [ "$old_port" != "$PORT" ] || [ "$old_mode" != "$install_mode" ]; }; then
    if ! node_revoke_firewall_for_mode "$old_port" udp "$old_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧端口防火墙清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi
  if ! node_apply_firewall_for_mode "$PORT" udp "$install_mode"; then
    node_transaction_rollback "$txn"
    echo -e "${R}防火墙放行失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  print_firewall_hint "$PORT" udp "TUIC v5 节点入站"
  if [ "$cert_source" = "acme" ]; then
    print_firewall_hint 80 tcp "ACME 证书签发与续期，签发期间必须可外部访问"
  fi

  local insecure="0"
  [ "$cert_source" = "self" ] && insecure="1"

  link=$(build_tuic_link "$UUID" "$PASSWORD" "$access_ip" "$PORT" "$SNI" "$insecure" "$CC" "$TAG" 2>/dev/null || true)
  if [ "$install_mode" = "dualstack" ] && [ -n "$public_ipv6" ] && [ "$public_ipv6" != "$access_ip" ]; then
    ipv6_link=$(build_tuic_link "$UUID" "$PASSWORD" "$public_ipv6" "$PORT" "$SNI" "$insecure" "$CC" "${TAG}-ipv6" 2>/dev/null || true)
  fi

  if ! write_node_info_file tuic <<EOF
Type=tuic
Tag=$TAG
Mode=$install_mode
ListenAddr=$LISTEN_ADDR
Port=$PORT
SNI=$SNI
CertSource=$cert_source
ACMEEmail=$acme_email
CertPath=${cert_path:-}
KeyPath=${key_path:-}
UUID=$UUID
Password=$PASSWORD
CongestionControl=$CC
Insecure=$insecure
IP=$access_ip
Link=$link
EOF
  then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if [ "$cert_source" = "acme" ]; then
    if ! rm -f -- "$CERTS_DIR/tuic.crt" "$CERTS_DIR/tuic.key"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧自签证书清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi
  node_transaction_commit "$txn"

  register_sb_command || true

  echo ""
  echo -e "  ${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "  ${G}║${N}  ${B}${W}${APP_NAME}${N}  ${G}TUIC v5 节点创建完成${N}                       ${G}║${N}"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${N}"
  echo -e "  模式      : ${C}$mode_label${N}"
  echo -e "  端口      : ${C}$PORT${N} ${D}(UDP)${N}"
  echo -e "  入口 IP   : ${C}${access_ip:-未知}${N}"
  echo -e "  SNI       : ${C}$SNI${N}"
  echo -e "  证书      : ${C}${cert_source}${N}$([ "$insecure" = "1" ] && echo "  ${Y}(客户端需 insecure=1)${N}")"
  echo -e "  UUID      : ${C}$UUID${N}"
  echo -e "  Password  : ${C}$PASSWORD${N}"
  echo -e "  拥塞控制  : ${C}$CC${N}"
  echo -e "  出站策略  : ${C}双栈（跟随系统路由）${N}"
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
  echo -e "  信息已保存至 ${Y}$(node_info_path tuic)${N}"
  echo -e "  输入 ${B}${COMMAND_NAME}${N} 进入管理菜单"
  pause_screen
}

uninstall_anytls_node(){
  local confirm
  if ! node_installed anytls; then
    echo -e "${Y}AnyTLS 节点未安装${N}"
    pause_screen
    return 0
  fi
  echo ""
  read -p "  确认卸载 AnyTLS 节点？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  if ! uninstall_node_transaction anytls anytls-in tcp; then
    echo -e "${R}AnyTLS 节点卸载失败，已恢复原配置${N}"
    pause_screen
    return 1
  fi
  echo -e "${G}AnyTLS 节点已卸载${N}"
  pause_screen
}

uninstall_tuic_node(){
  local confirm
  if ! node_installed tuic; then
    echo -e "${Y}TUIC 节点未安装${N}"
    pause_screen
    return 0
  fi
  echo ""
  read -p "  确认卸载 TUIC 节点？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  if ! uninstall_node_transaction tuic tuic-in udp; then
    echo -e "${R}TUIC 节点卸载失败，已恢复原配置${N}"
    pause_screen
    return 1
  fi
  echo -e "${G}TUIC 节点已卸载${N}"
  pause_screen
}

# ─── Shadowsocks-2022 ─────────────────────────────────
# 抗主动探测能力弱于 Reality / Hysteria2，菜单中标记为 [谨慎]
