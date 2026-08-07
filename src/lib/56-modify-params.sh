modify_ss2022_params(){
  local new_port="" new_method="" new_tag=""
  local cur_port cur_method cur_tag cur_password regen_choice
  local backup_path="" confirm new_password="" txn=""

  if ! require_root; then return 1; fi
  if ! require_singbox_installed; then return 1; fi
  if ! node_installed ss2022; then
    echo ""
    echo -e "${R}未发现 Shadowsocks-2022 节点信息${N}"
    pause_screen
    return 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到配置文件：$CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  cur_port=$(get_node_value ss2022 Port 2>/dev/null || true)
  cur_method=$(get_node_value ss2022 Method 2>/dev/null || echo 2022-blake3-aes-128-gcm)
  cur_tag=$(get_node_value ss2022 Tag 2>/dev/null || echo ss2022)
  cur_password=$(get_node_value ss2022 Password 2>/dev/null || true)

  render_section_header "修改 Shadowsocks-2022 节点"
  echo -e "  ${Y}留空回车则保留当前值${N}"
  echo ""

  while true; do
    read -p "  端口 (${cur_port}): " new_port
    new_port="${new_port:-$cur_port}"
    if ! validate_port "$new_port"; then
      echo -e "${R}端口必须是 1-65535 的数字${N}"
      continue
    fi
    new_port=$((10#$new_port))
    if [ "$new_port" != "$cur_port" ] && check_port_in_use "$new_port"; then
      echo -e "${R}端口 ${new_port} 已被其他服务占用${N}"
      local force_port=""
      read -p "  仍然使用此端口？(y/N): " force_port
      if [ "$force_port" != "y" ] && [ "$force_port" != "Y" ]; then
        continue
      fi
    fi
    break
  done

  echo -e "  加密方式 (当前: ${C}${cur_method}${N})："
  echo -e "    0) 保持不变（默认）"
  echo -e "    1) 2022-blake3-aes-128-gcm"
  echo -e "    2) 2022-blake3-aes-256-gcm"
  echo -e "    3) 2022-blake3-chacha20-poly1305"
  read -p "  请选择 (0): " METHOD_CHOICE
  case "$METHOD_CHOICE" in
    1) new_method="2022-blake3-aes-128-gcm" ;;
    2) new_method="2022-blake3-aes-256-gcm" ;;
    3) new_method="2022-blake3-chacha20-poly1305" ;;
    *) new_method="$cur_method" ;;
  esac

  read -p "  节点名称 (${cur_tag}): " new_tag
  new_tag="${new_tag:-$cur_tag}"

  # 改加密方式必须重新生成密钥（密钥长度可能变）
  if [ "$new_method" != "$cur_method" ]; then
    echo -e "  ${Y}加密方式已变更，将自动重新生成密钥${N}"
    regen_choice="y"
  else
    read -p "  重新生成密钥？(y/N): " regen_choice
  fi

  if [ "$regen_choice" = "y" ] || [ "$regen_choice" = "Y" ]; then
    new_password=$(generate_ss2022_password "$new_method")
    if [ -z "$new_password" ]; then
      echo -e "${R}密钥生成失败${N}"
      pause_screen
      return 1
    fi
  else
    new_password="$cur_password"
  fi

  echo ""
  echo -e "  即将写入："
  echo -e "    端口      : ${C}${new_port}${N}"
  echo -e "    加密方式  : ${C}${new_method}${N}"
  echo -e "    Tag       : ${C}${new_tag}${N}"
  if [ "$new_password" != "$cur_password" ]; then
    echo -e "    Password  : ${C}${new_password}${N} ${Y}(已更新)${N}"
  else
    echo -e "    Password  : ${D}保持不变${N}"
  fi
  read -p "  确认应用？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  ensure_jq || { pause_screen; return 1; }
  txn=$(node_transaction_begin ss2022) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }
  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
  if ! cp "$CONFIG_PATH" "$backup_path"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置备份失败${N}"
    pause_screen
    return 1
  fi

  local cur_listen cur_mode
  cur_listen=$(get_node_value ss2022 ListenAddr 2>/dev/null || echo "0.0.0.0")
  cur_mode=$(get_node_value ss2022 Mode 2>/dev/null || echo ipv4)

  local inbound_json
  if ! inbound_json=$(jq -n \
    --arg listen "$cur_listen" \
    --argjson port "$new_port" \
    --arg method "$new_method" \
    --arg password "$new_password" '{
      type: "shadowsocks",
      tag: "ss2022-in",
      listen: $listen,
      listen_port: $port,
      network: "tcp",
      method: $method,
      password: $password
    }'); then
    node_transaction_rollback "$txn"
    echo -e "${R}节点配置生成失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if ! config_add_inbound "$inbound_json"; then
    node_transaction_rollback "$txn"
    echo -e "${R}写入 inbound 失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if ! config_check_and_restart "$new_port" tcp; then
    node_transaction_rollback "$txn"
    echo -e "${R}sing-box 校验或健康检查失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  # 端口变化时同步防火墙
  if [ "$new_port" != "$cur_port" ]; then
    if ! node_revoke_firewall_for_mode "$cur_port" tcp "$cur_mode" \
       || ! node_apply_firewall_for_mode "$new_port" tcp "$cur_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}防火墙端口切换失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    print_firewall_hint "$new_port" tcp "Shadowsocks-2022 节点入站"
  fi

  if ! set_node_value ss2022 Port "$new_port" \
     || ! set_node_value ss2022 Method "$new_method" \
     || ! set_node_value ss2022 Tag "$new_tag" \
     || ! set_node_value ss2022 Password "$new_password"; then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  local cur_ip new_link ipv6_new_link
  cur_ip=$(get_node_value ss2022 IP 2>/dev/null || true)
  new_link=$(build_ss2022_link "$new_method" "$new_password" "$cur_ip" "$new_port" "$new_tag" 2>/dev/null || true)
  ipv6_new_link=$(build_dualstack_ipv6_link_for_node ss2022 2>/dev/null || true)
  if [ -n "$new_link" ] && ! set_node_value ss2022 Link "$new_link"; then
    node_transaction_rollback "$txn"
    echo -e "${R}客户端链接保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  node_transaction_commit "$txn"
  cleanup_old_backups "${CONFIG_PATH}.bak.*" 5 \
    || echo -e "${Y}旧配置备份自动清理失败，可稍后从备份菜单处理${N}"

  echo ""
  echo -e "  ${G}修改完成${N}"
  if [ -n "$new_link" ]; then
    echo ""
    echo -e "  ${B}新客户端链接：${N}"
    echo -e "  ${G}${new_link}${N}"
    print_qrcode "$new_link"
  fi
  if [ -n "$ipv6_new_link" ]; then
    echo ""
    echo -e "  ${B}新 IPv6 客户端链接：${N}"
    echo -e "  ${G}${ipv6_new_link}${N}"
    print_qrcode "$ipv6_new_link"
  fi
  echo ""
  echo -e "  备份: ${Y}${backup_path}${N}"
  pause_screen
}

modify_anytls_params(){
  local new_port="" new_sni="" new_pw="" new_tag=""
  local cur_port cur_sni cur_pw cur_tag backup_path="" confirm txn=""

  if ! require_root; then return 1; fi
  if ! require_singbox_installed; then return 1; fi
  if ! node_installed anytls; then
    echo ""
    echo -e "${R}未发现 AnyTLS 节点信息${N}"
    pause_screen
    return 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到配置文件：$CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  cur_port=$(get_node_value anytls Port 2>/dev/null || true)
  cur_sni=$(get_node_value anytls SNI 2>/dev/null || true)
  cur_pw=$(get_node_value anytls Password 2>/dev/null || true)
  cur_tag=$(get_node_value anytls Tag 2>/dev/null || echo anytls)

  echo ""
  echo -e "  ${B}${C}修改 AnyTLS 节点参数${N}  ${D}直接回车保留当前值${N}"
  echo -e "  ${D}（如需轮换密钥对 / ShortID，请卸载后重新安装节点）${N}"
  render_divider

  while true; do
    read -p "  端口 (${cur_port:-当前未知}): " new_port
    new_port="${new_port:-$cur_port}"
    if ! validate_port "$new_port"; then
      echo -e "${R}端口必须是 1-65535 的数字${N}"
      continue
    fi
    new_port=$((10#$new_port))
    if [ "$new_port" != "$cur_port" ] && check_port_in_use "$new_port" tcp; then
      local force_port=""
      echo -e "${R}端口 ${new_port} 已被其他 TCP 服务占用${N}"
      read -p "  仍然使用此端口？(y/N): " force_port
      if [ "$force_port" != "y" ] && [ "$force_port" != "Y" ]; then
        continue
      fi
    fi
    break
  done

  while true; do
    read -p "  SNI 域名 (${cur_sni:-当前未知}): " new_sni
    new_sni="${new_sni:-$cur_sni}"
    new_sni=$(sanitize_sni "$new_sni")
    if [ -n "$new_sni" ]; then break; fi
    echo -e "${R}SNI 不能为空${N}"
  done

  read -p "  Password (回车保留当前 / 输入 new 重新随机生成): " new_pw
  case "$new_pw" in
    new|NEW)
      new_pw=$(cat /proc/sys/kernel/random/uuid)
      echo -e "  ${D}新 Password：$new_pw${N}"
      ;;
    "") new_pw="$cur_pw" ;;
  esac
  if [ -z "$new_pw" ]; then
    echo -e "${R}Password 无效${N}"
    pause_screen
    return 1
  fi

  read -p "  节点名称 (${cur_tag}): " new_tag
  new_tag="${new_tag:-$cur_tag}"

  echo ""
  echo -e "  即将应用："
  echo -e "    端口     ${cur_port:-?} ${D}→${N} ${C}${new_port}${N}"
  echo -e "    SNI      ${cur_sni:-?} ${D}→${N} ${C}${new_sni}${N}"
  if [ "$new_pw" != "$cur_pw" ]; then
    echo -e "    Password ${cur_pw:-?} ${D}→${N} ${C}${new_pw}${N}"
  else
    echo -e "    Password ${D}保留${N}"
  fi
  if [ "$new_tag" != "$cur_tag" ]; then
    echo -e "    Tag      ${cur_tag} ${D}→${N} ${C}${new_tag}${N}"
  else
    echo -e "    Tag      ${D}保留${N}"
  fi
  read -p "  确认？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  ensure_jq || { pause_screen; return 1; }
  txn=$(node_transaction_begin anytls) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

  # 备份配置
  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
  if ! cp "$CONFIG_PATH" "$backup_path"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置备份失败${N}"
    pause_screen
    return 1
  fi

  local tmp jq_filter
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN
  jq_filter='(.inbounds[] | select(.tag == "anytls-in"))
       |= (.listen_port = ($port | tonumber)
           | .users[0].password = $pw
           | .tls.server_name = $sni
           | .tls.reality.handshake.server = $sni)'
  if ! jq --arg port "$new_port" \
          --arg sni "$new_sni" \
          --arg pw "$new_pw" \
          "$jq_filter" "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置写入失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  if ! mv "$tmp" "$CONFIG_PATH"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置替换失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if ! config_check_and_restart "$new_port" tcp; then
    node_transaction_rollback "$txn"
    echo ""
    echo -e "${R}sing-box 校验或健康检查失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  # 防火墙：撤旧放新
  local cur_mode
  cur_mode=$(get_node_value anytls Mode 2>/dev/null || echo ipv4)
  if [ -n "$cur_port" ] && [ "$cur_port" != "$new_port" ]; then
    if ! node_revoke_firewall_for_mode "$cur_port" tcp "$cur_mode" \
       || ! node_apply_firewall_for_mode "$new_port" tcp "$cur_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}防火墙端口切换失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    print_firewall_hint "$new_port" tcp "AnyTLS 节点新端口"
  fi

  # 更新 info
  if ! set_node_value anytls Port "$new_port" \
     || ! set_node_value anytls SNI "$new_sni" \
     || ! set_node_value anytls Password "$new_pw" \
     || ! set_node_value anytls Tag "$new_tag"; then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  # 重生成 Link
  local cur_ip pub sid new_link ipv6_new_link
  cur_ip=$(get_node_value anytls IP 2>/dev/null || true)
  pub=$(get_node_value anytls PublicKey 2>/dev/null || true)
  sid=$(get_node_value anytls ShortID 2>/dev/null || true)
  new_link=$(build_anytls_link "$new_pw" "$cur_ip" "$new_port" "$new_sni" "$pub" "$sid" "$new_tag" 2>/dev/null || true)
  ipv6_new_link=$(build_dualstack_ipv6_link_for_node anytls 2>/dev/null || true)
  if [ -n "$new_link" ] && ! set_node_value anytls Link "$new_link"; then
    node_transaction_rollback "$txn"
    echo -e "${R}客户端链接保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  node_transaction_commit "$txn"
  cleanup_old_backups "${CONFIG_PATH}.bak.*" 5 \
    || echo -e "${Y}旧配置备份自动清理失败，可稍后从备份菜单处理${N}"

  echo ""
  echo -e "${G}AnyTLS 节点参数已更新并重启服务${N}"
  if [ -n "$new_link" ]; then
    echo ""
    echo -e "  ${B}新客户端链接：${N}"
    echo -e "  ${G}$new_link${N}"
    print_qrcode "$new_link"
  fi
  if [ -n "$ipv6_new_link" ]; then
    echo ""
    echo -e "  ${B}新 IPv6 客户端链接：${N}"
    echo -e "  ${G}$ipv6_new_link${N}"
    print_qrcode "$ipv6_new_link"
  fi
  pause_screen
}

modify_tuic_params(){
  local new_port="" new_sni="" new_uuid="" new_pw="" new_cc="" new_tag=""
  local cur_port cur_sni cur_uuid cur_pw cur_cc cur_cert_src cur_email cur_mode cur_insecure cur_tag
  local cur_cert_path cur_key_path
  local backup_path="" confirm cc_choice regen_uuid regen_pw txn=""

  if ! require_root; then return 1; fi
  if ! require_singbox_installed; then return 1; fi
  if ! node_installed tuic; then
    echo ""
    echo -e "${R}未发现 TUIC 节点信息${N}"
    pause_screen
    return 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到配置文件：$CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  cur_port=$(get_node_value tuic Port 2>/dev/null || true)
  cur_sni=$(get_node_value tuic SNI 2>/dev/null || true)
  cur_uuid=$(get_node_value tuic UUID 2>/dev/null || true)
  cur_pw=$(get_node_value tuic Password 2>/dev/null || true)
  cur_cc=$(get_node_value tuic CongestionControl 2>/dev/null || echo bbr)
  cur_cert_src=$(get_node_value tuic CertSource 2>/dev/null || echo self)
  cur_email=$(get_node_value tuic ACMEEmail 2>/dev/null || true)
  cur_mode=$(get_node_value tuic Mode 2>/dev/null || echo ipv4)
  cur_insecure=$(get_node_value tuic Insecure 2>/dev/null || echo 0)
  cur_cert_path=$(get_node_value tuic CertPath 2>/dev/null || true)
  cur_key_path=$(get_node_value tuic KeyPath 2>/dev/null || true)
  cur_tag=$(get_node_value tuic Tag 2>/dev/null || echo tuic)

  echo ""
  echo -e "  ${B}${C}修改 TUIC v5 节点参数${N}  ${D}直接回车保留当前值${N}"
  echo -e "  ${D}（证书来源 ${cur_cert_src} 不可在此修改，需要切换请卸载重装）${N}"
  render_divider

  # 端口
  while true; do
    read -p "  端口 (${cur_port:-当前未知}): " new_port
    new_port="${new_port:-$cur_port}"
    if validate_port "$new_port"; then
      new_port=$((10#$new_port))
      if [ "$new_port" != "$cur_port" ] && check_port_in_use "$new_port" udp; then
        local force_port=""
        echo -e "${R}端口 ${new_port} 已被其他 UDP 服务占用${N}"
        read -p "  仍然使用此端口？(y/N): " force_port
        if [ "$force_port" != "y" ] && [ "$force_port" != "Y" ]; then
          continue
        fi
      fi
      break
    fi
    echo -e "${R}端口必须是 1-65535 的数字${N}"
  done

  # SNI
  while true; do
    if [ "$cur_cert_src" = "acme" ]; then
      read -p "  域名 (${cur_sni:-当前未知}, 改后会触发 ACME 重签): " new_sni
    else
      read -p "  SNI (${cur_sni:-当前未知}): " new_sni
    fi
    new_sni="${new_sni:-$cur_sni}"
    new_sni=$(sanitize_sni "$new_sni")
    if [ -n "$new_sni" ]; then break; fi
    echo -e "${R}SNI 不能为空${N}"
  done

  # UUID
  read -p "  UUID (回车保留当前 / 输入 new 重新生成): " regen_uuid
  case "$regen_uuid" in
    new|NEW)
      new_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
      if [ -z "$new_uuid" ] && command -v sing-box >/dev/null 2>&1; then
        new_uuid=$(sing-box generate uuid 2>/dev/null)
      fi
      if [ -z "$new_uuid" ]; then
        echo -e "${R}UUID 生成失败${N}"
        pause_screen
        return 1
      fi
      echo -e "  ${D}新 UUID：$new_uuid${N}"
      ;;
    *) new_uuid="$cur_uuid" ;;
  esac

  # Password
  read -p "  Password (回车保留当前 / 输入 new 重新随机生成): " regen_pw
  case "$regen_pw" in
    new|NEW)
      new_pw=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-22)
      echo -e "  ${D}新 Password：$new_pw${N}"
      ;;
    *) new_pw="$cur_pw" ;;
  esac

  # 拥塞控制
  echo -e "  拥塞控制算法 (当前: ${C}${cur_cc}${N})："
  echo "    1) 保留当前（默认）"
  echo "    2) bbr"
  echo "    3) cubic"
  read -p "  请选择 (1): " cc_choice
  case "$cc_choice" in
    2) new_cc="bbr" ;;
    3) new_cc="cubic" ;;
    *) new_cc="$cur_cc" ;;
  esac

  # 节点名称
  read -p "  节点名称 (${cur_tag}): " new_tag
  new_tag="${new_tag:-$cur_tag}"

  # 应用前确认
  echo ""
  echo -e "  即将应用："
  echo -e "    端口         ${cur_port:-?} ${D}→${N} ${C}${new_port}${N}"
  echo -e "    SNI          ${cur_sni:-?} ${D}→${N} ${C}${new_sni}${N}"
  if [ "$new_uuid" != "$cur_uuid" ]; then
    echo -e "    UUID         ${cur_uuid:-?} ${D}→${N} ${C}${new_uuid}${N}"
  else
    echo -e "    UUID         ${D}保留${N}"
  fi
  if [ "$new_pw" != "$cur_pw" ]; then
    echo -e "    Password     ${cur_pw:-?} ${D}→${N} ${C}${new_pw}${N}"
  else
    echo -e "    Password     ${D}保留${N}"
  fi
  if [ "$new_cc" != "$cur_cc" ]; then
    echo -e "    拥塞控制     ${cur_cc:-?} ${D}→${N} ${C}${new_cc}${N}"
  else
    echo -e "    拥塞控制     ${D}保留${N}"
  fi
  if [ "$new_tag" != "$cur_tag" ]; then
    echo -e "    Tag          ${cur_tag} ${D}→${N} ${C}${new_tag}${N}"
  else
    echo -e "    Tag          ${D}保留${N}"
  fi
  read -p "  确认？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  ensure_jq || { pause_screen; return 1; }
  txn=$(node_transaction_begin tuic) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

  # 备份配置
  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
  if ! cp "$CONFIG_PATH" "$backup_path"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置备份失败${N}"
    pause_screen
    return 1
  fi

  # 自签证书：SNI 变了 → 重新自签
  if [ "$cur_cert_src" = "self" ] && [ "$new_sni" != "$cur_sni" ]; then
    echo -e "${Y}==> SNI 已修改，重新生成自签证书...${N}"
    if ! generate_self_signed_cert_for_tuic "$new_sni" >/dev/null; then
      node_transaction_rollback "$txn"
      echo -e "${R}自签证书生成失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi

  # jq 修改 inbound
  local tmp jq_filter
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN
  jq_filter='(.inbounds[] | select(.tag == "tuic-in"))
       |= (.listen_port = ($port | tonumber)
           | .users[0].uuid = $uuid
           | .users[0].password = $pw
           | .congestion_control = $cc
           | .tls.server_name = $sni
           | (if .tls.acme then .tls.acme.domain = [$sni] else . end))'
  if ! jq --arg port "$new_port" \
          --arg sni "$new_sni" \
          --arg uuid "$new_uuid" \
          --arg pw "$new_pw" \
          --arg cc "$new_cc" \
          "$jq_filter" "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置写入失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  if ! mv "$tmp" "$CONFIG_PATH"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置替换失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if ! config_check_and_restart "$new_port" udp; then
    node_transaction_rollback "$txn"
    echo ""
    echo -e "${R}sing-box 校验或健康检查失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  # 防火墙：撤旧放新
  if [ -n "$cur_port" ] && [ "$cur_port" != "$new_port" ]; then
    if ! node_revoke_firewall_for_mode "$cur_port" udp "$cur_mode" \
       || ! node_apply_firewall_for_mode "$new_port" udp "$cur_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}防火墙端口切换失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    print_firewall_hint "$new_port" udp "TUIC 节点新端口"
  fi

  # 更新 .info
  if ! set_node_value tuic Port "$new_port" \
     || ! set_node_value tuic SNI "$new_sni" \
     || ! set_node_value tuic UUID "$new_uuid" \
     || ! set_node_value tuic Password "$new_pw" \
     || ! set_node_value tuic CongestionControl "$new_cc" \
     || ! set_node_value tuic Tag "$new_tag"; then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  # 重生成 Link
  local cur_ip new_link ipv6_new_link
  cur_ip=$(get_node_value tuic IP 2>/dev/null || true)
  new_link=$(build_tuic_link "$new_uuid" "$new_pw" "$cur_ip" "$new_port" "$new_sni" "$cur_insecure" "$new_cc" "$new_tag" 2>/dev/null || true)
  ipv6_new_link=$(build_dualstack_ipv6_link_for_node tuic 2>/dev/null || true)
  if [ -n "$new_link" ] && ! set_node_value tuic Link "$new_link"; then
    node_transaction_rollback "$txn"
    echo -e "${R}客户端链接保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  node_transaction_commit "$txn"
  cleanup_old_backups "${CONFIG_PATH}.bak.*" 5 \
    || echo -e "${Y}旧配置备份自动清理失败，可稍后从备份菜单处理${N}"

  echo ""
  echo -e "${G}TUIC 节点参数已更新并重启服务${N}"
  if [ -n "$new_link" ]; then
    echo ""
    echo -e "  ${B}新客户端链接：${N}"
    echo -e "  ${G}$new_link${N}"
    print_qrcode "$new_link"
  fi
  if [ -n "$ipv6_new_link" ]; then
    echo ""
    echo -e "  ${B}新 IPv6 客户端链接：${N}"
    echo -e "  ${G}$ipv6_new_link${N}"
    print_qrcode "$ipv6_new_link"
  fi
  pause_screen
}

# ─── 完整卸载脚本 ─────────────────────────────────────
# 清理范围：脚本固定 tag 的节点 inbound、节点信息/证书/防火墙端口、
#          WARP 与 sing-box 服务/软件包、脚本生成的配置备份、
#          legacy /root/proxy-info.txt、/usr/local/bin/sb。
# 保留：/etc/sing-box 内用户自定义 inbound、DNS、路由、outbound 与其它文件。
# 不动：SSH 端口/sshd 配置、用户账户、sudoers、自动更新策略、
#        IPv6 防火墙菜单规则、1Panel、apt 基础工具、
#        TCP 网络优化、QUIC 协议优化、initcwnd 持久化服务、本脚本创建的 SWAP。
