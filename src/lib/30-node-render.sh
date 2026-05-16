render_node_detail(){
  local type="$1"
  local node_type tag mode mode_label ip port sni
  node_type=$(get_node_value "$type" Type 2>/dev/null || echo "$type")
  tag=$(get_node_value "$type" Tag 2>/dev/null || echo "$type")
  mode=$(get_node_value "$type" Mode 2>/dev/null || echo ipv4)
  mode_label=$(describe_install_mode "$mode")
  ip=$(get_node_value "$type" IP 2>/dev/null || true)
  port=$(get_node_value "$type" Port 2>/dev/null || true)
  sni=$(get_node_value "$type" SNI 2>/dev/null || true)

  case "$node_type" in
    reality)
      local uuid pubk
      uuid=$(get_node_value "$type" UUID 2>/dev/null || true)
      pubk=$(get_node_value "$type" PublicKey 2>/dev/null || true)
      echo -e "  类型      : ${C}Reality${N}  Tag : ${C}${tag}${N}"
      echo -e "  UUID      : ${C}${uuid:-未知}${N}"
      echo -e "  PublicKey : ${C}${pubk:-未知}${N}"
      echo -e "  模式      : ${C}${mode_label}${N}"
      echo -e "  IP        : ${C}${ip:-未知}${N}"
      echo -e "  端口      : ${C}${port:-未知}${N} ${D}(TCP)${N}"
      echo -e "  SNI       : ${C}${sni:-未知}${N}"
      ;;
    hy2)
      local pwd_v cert_src obfs_t up_v down_v hop_v hop_mode_v hop_start_v hop_end_v
      pwd_v=$(get_node_value "$type" Password 2>/dev/null || true)
      cert_src=$(get_node_value "$type" CertSource 2>/dev/null || true)
      obfs_t=$(get_node_value "$type" Obfs 2>/dev/null || echo none)
      up_v=$(get_node_value "$type" UpMbps 2>/dev/null || true)
      down_v=$(get_node_value "$type" DownMbps 2>/dev/null || true)
      hop_v=$(get_node_value "$type" PortHop 2>/dev/null || echo 0)
      hop_mode_v=$(get_node_value "$type" PortHopMode 2>/dev/null || true)
      hop_start_v=$(get_node_value "$type" PortHopStart 2>/dev/null || true)
      hop_end_v=$(get_node_value "$type" PortHopEnd 2>/dev/null || true)
      echo -e "  类型      : ${C}Hysteria2${N}  Tag : ${C}${tag}${N}"
      echo -e "  Password  : ${C}${pwd_v:-未知}${N}"
      echo -e "  证书      : ${C}${cert_src:-未知}${N}"
      echo -e "  Obfs      : ${C}${obfs_t}${N}"
      echo -e "  模式      : ${C}${mode_label}${N}"
      echo -e "  IP        : ${C}${ip:-未知}${N}"
      echo -e "  端口      : ${C}${port:-未知}${N} ${D}(UDP)${N}"
      echo -e "  SNI       : ${C}${sni:-未知}${N}"
      if [ -n "$up_v" ] && [ -n "$down_v" ]; then
        echo -e "  带宽限制  : ${C}上 ${up_v} / 下 ${down_v} Mbps${N}"
      else
        echo -e "  带宽限制  : ${Y}未限制${N} ${D}(建议设置)${N}"
      fi
      if [ "$hop_v" = "1" ] && [ -n "$hop_start_v" ] && [ -n "$hop_end_v" ]; then
        echo -e "  端口跳跃  : ${C}${hop_start_v}-${hop_end_v}${N} ${D}(${hop_mode_v} 模式)${N}"
      else
        echo -e "  端口跳跃  : ${D}未启用${N}"
      fi
      ;;
    anytls)
      local pwd_v pubk_v sid_v
      pwd_v=$(get_node_value "$type" Password 2>/dev/null || true)
      pubk_v=$(get_node_value "$type" PublicKey 2>/dev/null || true)
      sid_v=$(get_node_value "$type" ShortID 2>/dev/null || true)
      echo -e "  类型      : ${C}AnyTLS${N}  Tag : ${C}${tag}${N}"
      echo -e "  Password  : ${C}${pwd_v:-未知}${N}"
      echo -e "  PublicKey : ${C}${pubk_v:-未知}${N} ${D}(共享自 Reality)${N}"
      echo -e "  ShortID   : ${C}${sid_v:-未知}${N} ${D}(共享自 Reality)${N}"
      echo -e "  模式      : ${C}${mode_label}${N}"
      echo -e "  IP        : ${C}${ip:-未知}${N}"
      echo -e "  端口      : ${C}${port:-未知}${N} ${D}(TCP)${N}"
      echo -e "  SNI       : ${C}${sni:-未知}${N}"
      ;;
    ss2022)
      local method_v pwd_v
      method_v=$(get_node_value "$type" Method 2>/dev/null || true)
      pwd_v=$(get_node_value "$type" Password 2>/dev/null || true)
      echo -e "  类型      : ${C}Shadowsocks-2022${N}  Tag : ${C}${tag}${N}"
      echo -e "  加密方式  : ${C}${method_v:-未知}${N}"
      echo -e "  Password  : ${C}${pwd_v:-未知}${N}"
      echo -e "  模式      : ${C}${mode_label}${N}"
      echo -e "  IP        : ${C}${ip:-未知}${N}"
      echo -e "  端口      : ${C}${port:-未知}${N} ${D}(TCP)${N}"
      echo -e "  ${R}⚠ 谨慎：抗主动探测较弱，避免在高 GFW 风险链路单独使用${N}"
      ;;
    xhr)
      local uuid_v pubk_v sid_v enkey_v path_v enkey_disp
      uuid_v=$(get_node_value "$type" UUID 2>/dev/null || true)
      pubk_v=$(get_node_value "$type" PublicKey 2>/dev/null || true)
      sid_v=$(get_node_value "$type" ShortID 2>/dev/null || true)
      enkey_v=$(get_node_value "$type" EncKey 2>/dev/null || true)
      path_v=$(get_node_value "$type" Path 2>/dev/null || true)
      # ENC 密钥很长，截断显示
      if [ -n "$enkey_v" ] && [ "${#enkey_v}" -gt 60 ]; then
        enkey_disp="${enkey_v:0:30}...${enkey_v: -20}"
      else
        enkey_disp="$enkey_v"
      fi
      echo -e "  类型      : ${C}Vless-xhttp-reality-enc${N}  Tag : ${C}${tag}${N}"
      echo -e "  UUID      : ${C}${uuid_v:-未知}${N}"
      echo -e "  PublicKey : ${C}${pubk_v:-未知}${N}"
      echo -e "  ShortID   : ${C}${sid_v:-未知}${N}"
      echo -e "  EncKey    : ${C}${enkey_disp:-未知}${N} ${D}(Post-Quantum)${N}"
      echo -e "  模式      : ${C}${mode_label}${N}"
      echo -e "  IP        : ${C}${ip:-未知}${N}"
      echo -e "  端口      : ${C}${port:-未知}${N} ${D}(TCP)${N}"
      echo -e "  SNI       : ${C}${sni:-未知}${N}"
      echo -e "  网络层    : ${C}xhttp${N}  ${D}path=${path_v}${N}"
      ;;
  esac
}

show_client_link(){
  local target current_link ipv6_link

  echo ""
  if ! is_singbox_installed; then
    echo -e "  ${R}sing-box 尚未安装${N}"
    pause_screen
    return 1
  fi
  if [ "$(count_installed_nodes)" -eq 0 ]; then
    echo -e "  ${R}未发现节点，请先创建节点${N}"
    pause_screen
    return 1
  fi

  target=$(select_node_interactive "请选择要查看的节点")
  if [ -z "$target" ]; then
    echo -e "${R}选择无效${N}"
    pause_screen
    return 1
  fi

  render_node_detail "$target"

  current_link=$(build_link_for_node "$target" 2>/dev/null || true)
  ipv6_link=$(build_dualstack_ipv6_link_for_node "$target" 2>/dev/null || true)
  if [ -n "$current_link" ]; then
    set_node_value "$target" Link "$current_link"
  fi

  echo ""
  echo -e "  ${B}客户端链接：${N}"
  echo -e "  ${G}${current_link:-未生成}${N}"
  print_qrcode "${current_link:-}"
  if [ -n "$ipv6_link" ]; then
    echo ""
    echo -e "  ${B}IPv6 客户端链接：${N}"
    echo -e "  ${G}${ipv6_link}${N}"
    print_qrcode "$ipv6_link"
  fi
  pause_screen
}

modify_reality_params(){
  local new_port="" new_sni="" new_uuid="" regen_keypair="n"
  local new_pri="" new_pub="" keypair="" new_short_id=""
  local cur_port cur_sni cur_uuid backup_path="" confirm

  if ! require_root; then return 1; fi
  if ! require_singbox_installed; then return 1; fi
  if ! node_installed reality; then
    echo ""
    echo -e "${R}未发现 Reality 节点信息${N}"
    pause_screen
    return 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到配置文件：$CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  cur_port=$(get_node_value reality Port 2>/dev/null || true)
  cur_sni=$(get_node_value reality SNI 2>/dev/null || true)
  cur_uuid=$(get_node_value reality UUID 2>/dev/null || true)

  echo ""
  echo -e "  ${B}${C}修改 Reality 节点参数${N}  ${D}直接回车保留当前值${N}"
  render_divider

  while true; do
    read -p "  端口 (${cur_port:-当前未知}): " new_port
    new_port="${new_port:-$cur_port}"
    if validate_port "$new_port"; then break; fi
    echo -e "${R}端口必须是 1-65535 的数字${N}"
  done

  while true; do
    read -p "  SNI 域名 (${cur_sni:-当前未知}): " new_sni
    new_sni="${new_sni:-$cur_sni}"
    new_sni=$(sanitize_sni "$new_sni")
    if [ -n "$new_sni" ]; then break; fi
    echo -e "${R}SNI 不能为空${N}"
  done

  read -p "  UUID (回车保留当前 / 输入 new 随机生成新 UUID): " new_uuid
  case "$new_uuid" in
    new|NEW)
      new_uuid=$(cat /proc/sys/kernel/random/uuid)
      echo -e "  ${D}新 UUID：$new_uuid${N}"
      ;;
    "") new_uuid="$cur_uuid" ;;
  esac
  if [ -z "$new_uuid" ]; then
    echo -e "${R}UUID 无效${N}"
    pause_screen
    return 1
  fi

  read -p "  同时重新生成 Reality 密钥对 + ShortID？(y/N): " regen_keypair
  if [ "$regen_keypair" = "y" ] || [ "$regen_keypair" = "Y" ]; then
    echo -e "${Y}==> 生成新密钥对...${N}"
    if ! keypair=$(sing-box generate reality-keypair); then
      echo -e "${R}密钥对生成失败${N}"
      pause_screen
      return 1
    fi
    new_pri=$(echo "$keypair" | grep PrivateKey | awk '{print $2}')
    new_pub=$(echo "$keypair" | grep PublicKey | awk '{print $2}')
    if [ -z "$new_pri" ] || [ -z "$new_pub" ]; then
      echo -e "${R}密钥对解析失败${N}"
      pause_screen
      return 1
    fi
    new_short_id=$(openssl rand -hex 4)
    echo -e "  ${D}新 PublicKey：$new_pub${N}"
    echo -e "  ${D}新 ShortID  ：$new_short_id${N}"
  fi

  echo ""
  echo -e "  将写入：端口 ${C}$new_port${N}  SNI ${C}$new_sni${N}  UUID ${C}$new_uuid${N}"
  if [ -n "$new_pub" ]; then
    echo -e "  PublicKey  : ${C}$new_pub${N}  ${Y}(记得更新客户端 pbk / sid 参数)${N}"
    echo -e "  ShortID    : ${C}$new_short_id${N}"
  fi
  read -p "  确认修改？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  if ! cp "$CONFIG_PATH" "$backup_path"; then
    echo -e "${R}配置备份失败${N}"
    pause_screen
    return 1
  fi

  ensure_jq || { pause_screen; return 1; }

  local jq_filter='(.inbounds[] | select(.tag == "reality-in"))
    |= ( .listen_port = ($port | tonumber)
       | .users[0].uuid = $uuid
       | .tls.server_name = $sni
       | .tls.reality.handshake.server = $sni
       | (if $pri != "" then .tls.reality.private_key = $pri else . end)
       | (if $sid != "" then .tls.reality.short_id = [$sid] else . end))'

  local tmp_file
  tmp_file=$(mktemp)
  # 兜底：函数返回时清理临时文件（不挂 INT/TERM，避免污染全局信号 trap）
  trap 'rm -f "$tmp_file"' RETURN
  if ! jq --arg port "$new_port" --arg sni "$new_sni" --arg uuid "$new_uuid" \
       --arg pri "${new_pri:-}" --arg sid "${new_short_id:-}" \
       "$jq_filter" "$CONFIG_PATH" > "$tmp_file"; then
    rm -f "$tmp_file"
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    echo -e "${R}配置写入失败，已恢复备份${N}"
    pause_screen
    return 1
  fi
  mv "$tmp_file" "$CONFIG_PATH"

  if ! sing-box check -c "$CONFIG_PATH"; then
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    echo ""
    echo -e "${R}配置校验失败，已恢复备份${N}"
    pause_screen
    return 1
  fi
  if ! systemctl restart sing-box; then
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    echo ""
    echo -e "${R}服务重启失败，已恢复备份${N}"
    pause_screen
    return 1
  fi

  set_node_value reality Port "$new_port"
  set_node_value reality SNI "$new_sni"
  set_node_value reality UUID "$new_uuid"
  if [ -n "$new_pub" ]; then
    set_node_value reality PublicKey "$new_pub"
    set_node_value reality PrivateKey "$new_pri"
    set_node_value reality ShortID "$new_short_id"

    # 联动：AnyTLS 节点也复用同一对密钥，必须同步否则客户端会静默连不上
    if node_installed anytls; then
      echo ""
      echo -e "${Y}==> 同步更新 AnyTLS 节点的密钥对...${N}"
      if sync_anytls_to_reality_keys "$new_pri" "$new_pub" "$new_short_id"; then
        if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1 \
           && systemctl restart sing-box >/dev/null 2>&1; then
          echo -e "  ${G}AnyTLS 节点密钥已同步${N}"
          echo -e "  ${Y}请用「查看客户端链接」获取新的 AnyTLS 分享链接${N}"
        else
          echo -e "  ${R}AnyTLS 同步后配置校验或重启失败，请手动排查 sing-box 日志${N}"
        fi
      else
        echo -e "  ${R}AnyTLS 同步失败（jq 改写错误），请手动排查${N}"
      fi
    fi
  fi

  local cur_ip cur_tag final_pub final_sid new_link ipv6_new_link
  cur_ip=$(get_node_value reality IP 2>/dev/null || true)
  cur_tag=$(get_node_value reality Tag 2>/dev/null || echo reality)
  final_pub="${new_pub:-$(get_node_value reality PublicKey 2>/dev/null || true)}"
  final_sid="${new_short_id:-$(get_node_value reality ShortID 2>/dev/null || true)}"
  new_link=$(build_reality_link "$new_uuid" "$cur_ip" "$new_port" "$new_sni" "$final_pub" "$final_sid" "${cur_tag:-reality}" 2>/dev/null || true)
  ipv6_new_link=$(build_dualstack_ipv6_link_for_node reality 2>/dev/null || true)
  [ -n "$new_link" ] && set_node_value reality Link "$new_link"
  if [ -n "$new_port" ] && [ "$new_port" != "$cur_port" ]; then
    local rt_mode_now
    rt_mode_now=$(get_node_value reality Mode 2>/dev/null || echo ipv4)
    # 旧端口先撤、新端口再开（双栈/v6 模式同时处理 v4/v6）
    [ -n "$cur_port" ] && node_revoke_firewall_for_mode "$cur_port" tcp "$rt_mode_now"
    node_apply_firewall_for_mode "$new_port" tcp "$rt_mode_now"
    print_firewall_hint "$new_port" tcp "Reality 节点新端口"
  fi
  cleanup_old_backups "${CONFIG_PATH}.bak.*" 5

  echo ""
  echo -e "${G}Reality 节点参数已更新并重启服务${N}"
  echo -e "  备份文件：${D}$backup_path${N}"
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

# 节点参数修改 dispatcher（多节点时让用户选择）
modify_node_params(){
  if ! require_root; then return 1; fi
  if ! require_singbox_installed; then return 1; fi
  local count target
  count=$(count_installed_nodes)
  if [ "$count" -eq 0 ]; then
    echo ""
    echo -e "${R}未发现节点，请先创建节点${N}"
    pause_screen
    return 1
  fi
  target=$(select_node_interactive "请选择要修改的节点")
  if [ -z "$target" ]; then
    echo -e "${R}选择无效${N}"
    pause_screen
    return 1
  fi
  local node_type
  node_type=$(get_node_value "$target" Type 2>/dev/null || echo "$target")
  case "$node_type" in
    reality) modify_reality_params ;;
    hy2)     modify_hy2_params ;;
    anytls)  modify_anytls_params ;;
    tuic)    modify_tuic_params ;;
    ss2022)  modify_ss2022_params ;;
    *)
      echo -e "${R}未知节点类型: $node_type${N}"
      pause_screen
      return 1
      ;;
  esac
}

print_qrcode(){
  local link="$1"

  if [ -z "$link" ]; then
    return 1
  fi

  if ! command -v qrencode >/dev/null 2>&1; then
    echo -e "${Y}==> 未检测到 qrencode，正在安装...${N}"
    if ! apt-get install -y qrencode 2>/dev/null; then
      DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
      if ! apt-get install -y qrencode 2>/dev/null; then
        echo -e "${R}qrencode 安装失败，请手动执行：apt install qrencode${N}"
        return 1
      fi
    fi
  fi

  echo ""
  echo -e "  ${B}扫码导入：${N}"
  echo ""
  qrencode -t ANSIUTF8 "$link"
}

