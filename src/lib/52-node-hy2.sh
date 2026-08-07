generate_hy2_random_port(){
  local p attempts=0
  while [ $attempts -lt 30 ]; do
    p=$(( (RANDOM << 15 | RANDOM) % 45535 + 20000 ))
    if ! check_port_in_use "$p" udp; then
      printf '%s' "$p"
      return 0
    fi
    attempts=$((attempts + 1))
  done
  printf '%s' "$p"
}

# AnyTLS 默认端口生成：避开本机已占端口与已安装节点已用端口
generate_anytls_random_port(){
  local p attempts=0 t taken_ports=""
  for t in reality hy2 tuic ss2022; do
    if node_installed "$t"; then
      taken_ports="$taken_ports $(get_node_value "$t" Port 2>/dev/null || true)"
    fi
  done
  while [ $attempts -lt 30 ]; do
    p=$(( (RANDOM << 15 | RANDOM) % 45535 + 20000 ))
    attempts=$((attempts + 1))
    if printf '%s\n' $taken_ports | grep -qFx "$p"; then
      continue
    fi
    if ! check_port_in_use "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  printf '%s' "$p"
}

generate_self_signed_cert(){
  local type="$1" sni="$2"
  local crt="$CERTS_DIR/${type}.crt"
  local key="$CERTS_DIR/${type}.key"
  local workdir new_crt new_key

  ensure_nodes_dir || return 1
  if ! command -v openssl >/dev/null 2>&1; then
    echo -e "${R}未找到 openssl${N}"
    return 1
  fi
  workdir=$(mktemp -d "$CERTS_DIR/.${type}.XXXXXX") || return 1
  chmod 700 "$workdir" 2>/dev/null || { rm -rf -- "$workdir"; return 1; }
  new_crt="$workdir/${type}.crt"
  new_key="$workdir/${type}.key"
  if ! openssl ecparam -genkey -name prime256v1 -out "$new_key" 2>/dev/null; then
    if ! openssl genrsa -out "$new_key" 2048 >/dev/null 2>&1; then
      echo -e "${R}私钥生成失败${N}"
      rm -rf -- "$workdir"
      return 1
    fi
  fi
  if ! openssl req -new -x509 -days 3650 -key "$new_key" -out "$new_crt" \
       -subj "/CN=${sni}" >/dev/null 2>&1; then
    echo -e "${R}自签证书生成失败${N}"
    rm -rf -- "$workdir"
    return 1
  fi
  chmod 600 "$new_key" "$new_crt" 2>/dev/null || { rm -rf -- "$workdir"; return 1; }
  if [ -f "$key" ] && ! cp -a -- "$key" "$workdir/old.key"; then
    rm -rf -- "$workdir"
    return 1
  fi
  if [ -f "$crt" ] && ! cp -a -- "$crt" "$workdir/old.crt"; then
    rm -rf -- "$workdir"
    return 1
  fi
  if ! mv -f -- "$new_key" "$key" || ! mv -f -- "$new_crt" "$crt"; then
    local restore_ok=1
    if [ -f "$workdir/old.key" ]; then
      cp -a -- "$workdir/old.key" "$key" 2>/dev/null || restore_ok=0
    else
      rm -f -- "$key" || restore_ok=0
    fi
    if [ -f "$workdir/old.crt" ]; then
      cp -a -- "$workdir/old.crt" "$crt" 2>/dev/null || restore_ok=0
    else
      rm -f -- "$crt" || restore_ok=0
    fi
    rm -rf -- "$workdir"
    [ "$restore_ok" -eq 1 ] || echo -e "${R}证书替换失败且旧证书恢复不完整${N}" >&2
    return 1
  fi
  rm -rf -- "$workdir"
  printf '%s\n%s' "$crt" "$key"
}

generate_self_signed_cert_for_hy2(){
  generate_self_signed_cert hy2 "$1"
}

generate_self_signed_cert_for_tuic(){
  generate_self_signed_cert tuic "$1"
}

install_hy2_node(){
  local port_input="" sni_input=""
  local PORT SNI TAG LISTEN_CHOICE LISTEN_ADDR install_mode="ipv4"
  local cert_choice cert_source="self" acme_email=""
  local password obfs_password obfs_choice obfs_enable=1
  local public_ipv4="" public_ipv6="" access_ip=""
  local link="" ipv6_link="" mode_label="" confirm
  local cert_paths cert_path key_path
  local up_mbps=100 down_mbps=300 bw_choice
  local hop_choice HOP_ENABLE=0 HOP_MODE="" HOP_START="" HOP_END=""
  local range_input confirm_hop confirm_small force_hop
  local listen_v4="" listen_v6=""
  local txn="" old_port="" old_mode="ipv4" old_hop="0" old_hop_start="" old_hop_end=""

  if ! require_root; then return 1; fi

  render_section_header "创建 Hysteria2 节点"
  echo -e "  ${Y}直接回车使用括号内默认值${N}"
  echo ""

  if node_installed hy2; then
    echo -e "${Y}检测到已存在 Hysteria2 节点，继续将覆盖原节点配置${N}"
    read -p "  继续？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo -e "  已取消"
      return 0
    fi
    old_port=$(get_node_value hy2 Port 2>/dev/null || true)
    old_mode=$(get_node_value hy2 Mode 2>/dev/null || echo ipv4)
    old_hop=$(get_node_value hy2 PortHop 2>/dev/null || echo 0)
    old_hop_start=$(get_node_value hy2 PortHopStart 2>/dev/null || true)
    old_hop_end=$(get_node_value hy2 PortHopEnd 2>/dev/null || true)
  fi

  # 端口（默认随机高位 UDP）
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
  read -p "  节点名称 (hy2): " TAG
  TAG="${TAG:-hy2}"

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

  # obfs（默认启用 salamander）
  echo -e "  obfs 混淆 (salamander)："
  echo "    1) 启用，密码自动生成（默认）"
  echo "    2) 不启用"
  read -p "  请选择 (1): " obfs_choice
  case "$obfs_choice" in
    2) obfs_enable=0 ;;
    *) obfs_enable=1 ;;
  esac

  # 带宽限制（防 HY2 跑满线路被云厂商盯）
  echo ""
  echo -e "  ${B}带宽限制${N}（防 HY2 跑满线路被云厂商盯，不影响日常使用）："
  echo "    1) 保守    上 30  / 下 80  Mbps  - 小机器 / 共享带宽限速重的"
  echo "    2) 推荐    上 100 / 下 300 Mbps  - 99% 情况，闭眼选（默认）"
  echo "    3) 大带宽  上 300 / 下 800 Mbps  - 测速过、确认有大带宽"
  echo "    4) 自定义"
  echo "    5) 不限制（不推荐，可能触发云厂商告警）"
  read -p "  请选择 (2): " bw_choice
  case "$bw_choice" in
    1) up_mbps=30;  down_mbps=80 ;;
    3) up_mbps=300; down_mbps=800 ;;
    4)
      while true; do
        read -p "  上行 Mbps (正整数): " up_mbps
        if [ -n "$up_mbps" ] && [ "$up_mbps" -gt 0 ] 2>/dev/null; then break; fi
        echo -e "${R}必须为正整数${N}"
      done
      while true; do
        read -p "  下行 Mbps (正整数): " down_mbps
        if [ -n "$down_mbps" ] && [ "$down_mbps" -gt 0 ] 2>/dev/null; then break; fi
        echo -e "${R}必须为正整数${N}"
      done
      ;;
    5) up_mbps=0; down_mbps=0 ;;
    *) up_mbps=100; down_mbps=300 ;;
  esac

  # 端口跳跃（进阶选项）
  echo ""
  echo -e "  ${B}端口跳跃${N} (port hopping) — 进阶选项："
  echo -e "    ${D}作用：客户端在多个端口间随机跳跃，封一个端口没用，对抗成本提升 100 倍${N}"
  echo -e "    ${D}代价：消耗大量端口，部分云厂商可能告警，可能与 Docker / 其他服务冲突${N}"
  echo "    1) 不启用（默认，推荐小白）"
  echo "    2) 启用 - 自动选择范围（主端口 +1 到 +999）"
  echo "    3) 启用 - 自定义范围（避开 Docker / 其他服务）"
  read -p "  请选择 (1): " hop_choice
  case "$hop_choice" in
    2)
      HOP_ENABLE=1
      HOP_MODE="auto"
      read -r HOP_START HOP_END < <(port_hop_compute_range "$PORT")
      echo -e "  自动选择：${C}${HOP_START}-${HOP_END}${N} ${D}（共 $((HOP_END-HOP_START+1)) 个端口）${N}"
      echo -e "  ${Y}注意：会自动配置 iptables NAT 规则并占用整个范围${N}"
      read -p "  确认启用？(y/N): " confirm_hop
      if [ "$confirm_hop" != "y" ] && [ "$confirm_hop" != "Y" ]; then
        HOP_ENABLE=0; HOP_MODE=""; HOP_START=""; HOP_END=""
      fi
      ;;
    3)
      HOP_ENABLE=1
      HOP_MODE="custom"
      echo -e "  ${D}建议范围至少 100 个端口，越大抗封效果越好${N}"
      echo -e "  ${D}格式示例：30000-31000  (含两端，共 1001 个端口)${N}"
      echo -e "  ${D}建议避开：22 (SSH)、80/443 (Web)、Docker 已用端口${N}"
      while true; do
        read -p "  端口范围 (起始-结束): " range_input
        HOP_START=$(echo "$range_input" | awk -F- '{print $1}' | tr -dc '0-9')
        HOP_END=$(echo "$range_input" | awk -F- '{print $2}' | tr -dc '0-9')
        if [ -z "$HOP_START" ] || [ -z "$HOP_END" ]; then
          echo -e "  ${R}格式错误，请按 起始-结束 格式输入${N}"; continue
        fi
        if [ "$HOP_START" -lt 1024 ] || [ "$HOP_END" -gt 65535 ]; then
          echo -e "  ${R}端口必须在 1024-65535 之间${N}"; continue
        fi
        if [ "$HOP_START" -ge "$HOP_END" ]; then
          echo -e "  ${R}起始端口必须小于结束端口${N}"; continue
        fi
        if [ "$PORT" -ge "$HOP_START" ] && [ "$PORT" -le "$HOP_END" ]; then
          echo -e "  ${R}范围不能包含主端口 $PORT${N}"; continue
        fi
        if [ $((HOP_END - HOP_START)) -lt 50 ]; then
          echo -e "  ${Y}警告：范围只有 $((HOP_END-HOP_START+1)) 个端口，抗封效果有限${N}"
          read -p "  仍然使用？(y/N): " confirm_small
          if [ "$confirm_small" != "y" ] && [ "$confirm_small" != "Y" ]; then continue; fi
        fi
        break
      done
      ;;
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
  password=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-22)
  if [ "$obfs_enable" = "1" ]; then
    obfs_password=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-22)
  fi

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
  txn=$(node_transaction_begin hy2) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

  # 准备证书
  if [ "$cert_source" = "self" ]; then
    echo -e "${Y}==> 生成自签证书...${N}"
    if ! cert_paths=$(generate_self_signed_cert_for_hy2 "$SNI"); then
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
      acme: {domain: [$sni], email: $email}
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

  local obfs_json="null"
  if [ "$obfs_enable" = "1" ]; then
    if ! obfs_json=$(jq -n --arg pw "$obfs_password" '{type: "salamander", password: $pw}'); then
      node_transaction_rollback "$txn"
      pause_screen
      return 1
    fi
  fi

  # 构造 user 对象（Hysteria2 的 user 仅含 password；带宽限制 up_mbps/down_mbps 是 inbound 顶层字段）
  local user_obj
  if ! user_obj=$(jq -n --arg pw "$password" '{password: $pw}'); then
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
    --argjson obfs "$obfs_json" \
    --argjson up "$up_mbps" \
    --argjson down "$down_mbps" '
    {
      type: "hysteria2",
      tag: "hy2-in",
      listen: $listen,
      listen_port: $port,
      users: [$user],
      tls: $tls
    }
    + (if $obfs == null then {} else {obfs: $obfs} end)
    + (if $up > 0 and $down > 0 then {up_mbps: $up, down_mbps: $down} else {} end)'); then
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

  # 先撤掉旧节点的跳跃规则；后续任一步失败由节点事务恢复。
  if [ "$old_hop" = "1" ] && [ -n "$old_hop_start" ] && [ -n "$old_hop_end" ]; then
    if ! port_hop_remove "$old_hop_start" "$old_hop_end" "$old_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧端口跳跃规则清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi

  # 应用端口跳跃规则（启用时）
  if [ "$HOP_ENABLE" = "1" ]; then
    if port_hop_range_has_conflict "$HOP_START" "$HOP_END"; then
      echo ""
      echo -e "${Y}端口范围 ${HOP_START}-${HOP_END} 内已有其他 UDP 服务监听：${N}"
      port_hop_list_conflicts "$HOP_START" "$HOP_END"
      read -p "  仍然继续？冲突端口可能被 NAT 规则覆盖 (y/N): " force_hop
      if [ "$force_hop" != "y" ] && [ "$force_hop" != "Y" ]; then
        HOP_ENABLE=0; HOP_MODE=""; HOP_START=""; HOP_END=""
        echo -e "  ${Y}已取消端口跳跃${N}"
      fi
    fi
    if [ "$HOP_ENABLE" = "1" ]; then
      local addrs_pair
      addrs_pair=$(port_hop_listen_addrs_for_mode "$install_mode" "$public_ipv6")
      listen_v4="${addrs_pair%|*}"
      listen_v6="${addrs_pair#*|}"
      if ! port_hop_apply "$PORT" "$HOP_START" "$HOP_END" "$install_mode" "$listen_v4" "$listen_v6"; then
        node_transaction_rollback "$txn"
        echo -e "${R}端口跳跃规则应用失败，已完整回滚${N}"
        pause_screen
        return 1
      fi
      echo -e "  ${G}端口跳跃已启用：${HOP_START}-${HOP_END} (UDP)${N}"
    fi
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
  print_firewall_hint "$PORT" udp "Hysteria2 节点入站"
  if [ "$HOP_ENABLE" = "1" ]; then
    echo -e "  ${D}端口跳跃 DNAT 已配置：${HOP_START}-${HOP_END}/udp → 主端口 ${PORT}/udp${N}"
  fi
  if [ "$cert_source" = "acme" ]; then
    print_firewall_hint 80 tcp "ACME 证书签发与续期，签发期间必须可外部访问"
  fi

  local insecure="0"
  [ "$cert_source" = "self" ] && insecure="1"
  local link_obfs_type=""
  [ "$obfs_enable" = "1" ] && link_obfs_type="salamander"

  link=$(build_hy2_link "$password" "$access_ip" "$PORT" "$SNI" "$insecure" "$link_obfs_type" "${obfs_password:-}" "$TAG" "$HOP_START" "$HOP_END" 2>/dev/null || true)
  if [ "$install_mode" = "dualstack" ] && [ -n "$public_ipv6" ] && [ "$public_ipv6" != "$access_ip" ]; then
    ipv6_link=$(build_hy2_link "$password" "$public_ipv6" "$PORT" "$SNI" "$insecure" "$link_obfs_type" "${obfs_password:-}" "${TAG}-ipv6" "$HOP_START" "$HOP_END" 2>/dev/null || true)
  fi

  if ! write_node_info_file hy2 <<EOF
Type=hy2
Tag=$TAG
Mode=$install_mode
ListenAddr=$LISTEN_ADDR
Port=$PORT
SNI=$SNI
CertSource=$cert_source
ACMEEmail=$acme_email
CertPath=${cert_path:-}
KeyPath=${key_path:-}
Password=$password
Obfs=${link_obfs_type:-none}
ObfsPassword=${obfs_password:-}
Insecure=$insecure
IP=$access_ip
UpMbps=$([ "$up_mbps" -gt 0 ] && printf '%s' "$up_mbps")
DownMbps=$([ "$down_mbps" -gt 0 ] && printf '%s' "$down_mbps")
PortHop=$HOP_ENABLE
PortHopMode=$HOP_MODE
PortHopStart=$HOP_START
PortHopEnd=$HOP_END
Link=$link
EOF
  then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if [ "$cert_source" = "acme" ]; then
    if ! rm -f -- "$CERTS_DIR/hy2.crt" "$CERTS_DIR/hy2.key"; then
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
  echo -e "  ${G}║${N}  ${B}${W}${APP_NAME}${N}  ${G}Hysteria2 节点创建完成${N}                     ${G}║${N}"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${N}"
  echo -e "  模式      : ${C}$mode_label${N}"
  echo -e "  端口      : ${C}$PORT${N} ${D}(UDP)${N}"
  echo -e "  入口 IP   : ${C}${access_ip:-未知}${N}"
  echo -e "  SNI       : ${C}$SNI${N}"
  echo -e "  证书      : ${C}${cert_source}${N}$([ "$insecure" = "1" ] && echo "  ${Y}(客户端需 insecure=1)${N}")"
  echo -e "  Password  : ${C}$password${N}"
  if [ "$obfs_enable" = "1" ]; then
    echo -e "  Obfs      : ${C}salamander${N}  ObfsPwd : ${C}$obfs_password${N}"
  fi
  if [ "$up_mbps" -gt 0 ] && [ "$down_mbps" -gt 0 ]; then
    echo -e "  带宽限制  : ${C}上 ${up_mbps} / 下 ${down_mbps} Mbps${N}"
  else
    echo -e "  带宽限制  : ${Y}未限制${N} ${D}(可能触发云厂商告警)${N}"
  fi
  if [ "$HOP_ENABLE" = "1" ]; then
    echo -e "  端口跳跃  : ${C}${HOP_START}-${HOP_END}${N} ${D}($HOP_MODE 模式, $((HOP_END-HOP_START+1)) 端口)${N}"
  else
    echo -e "  端口跳跃  : ${D}未启用${N}"
  fi
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
  echo -e "  信息已保存至 ${Y}$(node_info_path hy2)${N}"
  echo -e "  输入 ${B}${COMMAND_NAME}${N} 进入管理菜单"
  pause_screen
}

uninstall_hy2_node(){
  local confirm
  if ! node_installed hy2; then
    echo -e "${Y}Hysteria2 节点未安装${N}"
    pause_screen
    return 0
  fi
  echo ""
  read -p "  确认卸载 Hysteria2 节点？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  if ! uninstall_node_transaction hy2 hy2-in udp; then
    echo -e "${R}Hysteria2 节点卸载失败，已恢复原配置${N}"
    pause_screen
    return 1
  fi
  echo -e "${G}Hysteria2 节点已卸载${N}"
  pause_screen
}

modify_hy2_params(){
  local new_port="" new_sni="" regen_pw="n"
  local cur_port cur_sni cur_pw cur_obfs cur_obfs_pw cur_cert_src cur_email
  local cur_up cur_down cur_hop cur_hop_mode cur_hop_start cur_hop_end cur_mode
  local new_pw="" new_obfs_pw=""
  local backup_path="" confirm
  local bw_choice bw_action="keep" new_up=0 new_down=0
  local hop_choice new_hop=0 new_hop_mode="" new_hop_start="" new_hop_end=""
  local range_input confirm_small
  local txn=""

  if ! require_root; then return 1; fi
  if ! require_singbox_installed; then return 1; fi
  if ! node_installed hy2; then
    echo ""
    echo -e "${R}未发现 Hysteria2 节点信息${N}"
    pause_screen
    return 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到配置文件：$CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  cur_port=$(get_node_value hy2 Port 2>/dev/null || true)
  cur_sni=$(get_node_value hy2 SNI 2>/dev/null || true)
  cur_pw=$(get_node_value hy2 Password 2>/dev/null || true)
  cur_obfs=$(get_node_value hy2 Obfs 2>/dev/null || true)
  cur_obfs_pw=$(get_node_value hy2 ObfsPassword 2>/dev/null || true)
  cur_cert_src=$(get_node_value hy2 CertSource 2>/dev/null || echo self)
  cur_email=$(get_node_value hy2 ACMEEmail 2>/dev/null || true)
  cur_up=$(get_node_value hy2 UpMbps 2>/dev/null || true)
  cur_down=$(get_node_value hy2 DownMbps 2>/dev/null || true)
  cur_hop=$(get_node_value hy2 PortHop 2>/dev/null || echo 0)
  cur_hop_mode=$(get_node_value hy2 PortHopMode 2>/dev/null || true)
  cur_hop_start=$(get_node_value hy2 PortHopStart 2>/dev/null || true)
  cur_hop_end=$(get_node_value hy2 PortHopEnd 2>/dev/null || true)
  cur_mode=$(get_node_value hy2 Mode 2>/dev/null || echo ipv4)

  echo ""
  echo -e "  ${B}${C}修改 Hysteria2 节点参数${N}  ${D}直接回车保留当前值${N}"
  render_divider

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

  while true; do
    read -p "  SNI (${cur_sni:-当前未知}): " new_sni
    new_sni="${new_sni:-$cur_sni}"
    new_sni=$(sanitize_sni "$new_sni")
    if [ -n "$new_sni" ]; then break; fi
    echo -e "${R}SNI 不能为空${N}"
  done

  read -p "  重新生成 Password？(y/N): " regen_pw
  if [ "$regen_pw" = "y" ] || [ "$regen_pw" = "Y" ]; then
    new_pw=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-22)
    echo -e "  ${D}新 Password：$new_pw${N}"
  fi

  if [ "$cur_obfs" = "salamander" ]; then
    read -p "  重新生成 obfs 密码？(y/N): " regen_obfs
    if [ "$regen_obfs" = "y" ] || [ "$regen_obfs" = "Y" ]; then
      new_obfs_pw=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-22)
      echo -e "  ${D}新 obfs 密码：$new_obfs_pw${N}"
    fi
  fi

  # 带宽限制修改
  echo ""
  if [ -n "$cur_up" ] && [ -n "$cur_down" ]; then
    echo -e "  ${B}带宽限制${N} (当前: 上 ${C}${cur_up}${N} / 下 ${C}${cur_down}${N} Mbps)："
  else
    echo -e "  ${B}带宽限制${N} (当前: ${Y}未限制${N})："
  fi
  echo "    1) 保留当前设置（默认）"
  echo "    2) 保守    上 30  / 下 80  Mbps"
  echo "    3) 推荐    上 100 / 下 300 Mbps"
  echo "    4) 大带宽  上 300 / 下 800 Mbps"
  echo "    5) 自定义"
  echo "    6) 取消限制"
  read -p "  请选择 (1): " bw_choice
  case "$bw_choice" in
    2) bw_action="set"; new_up=30;  new_down=80 ;;
    3) bw_action="set"; new_up=100; new_down=300 ;;
    4) bw_action="set"; new_up=300; new_down=800 ;;
    5)
      bw_action="set"
      while true; do
        read -p "  上行 Mbps (正整数): " new_up
        if [ -n "$new_up" ] && [ "$new_up" -gt 0 ] 2>/dev/null; then break; fi
        echo -e "${R}必须为正整数${N}"
      done
      while true; do
        read -p "  下行 Mbps (正整数): " new_down
        if [ -n "$new_down" ] && [ "$new_down" -gt 0 ] 2>/dev/null; then break; fi
        echo -e "${R}必须为正整数${N}"
      done
      ;;
    6) bw_action="unset" ;;
    *) bw_action="keep" ;;
  esac

  # 端口跳跃修改
  echo ""
  if [ "$cur_hop" = "1" ]; then
    echo -e "  ${B}端口跳跃${N} (当前: ${C}${cur_hop_start}-${cur_hop_end}${N} / ${cur_hop_mode} 模式)："
  else
    echo -e "  ${B}端口跳跃${N} (当前: ${Y}未启用${N})："
  fi
  echo "    1) 保留当前设置（默认）"
  echo "    2) 切换/启用 自动范围（基于新主端口）"
  echo "    3) 切换/启用 自定义范围"
  echo "    4) 关闭端口跳跃"
  read -p "  请选择 (1): " hop_choice
  case "$hop_choice" in
    2)
      new_hop=1
      new_hop_mode="auto"
      read -r new_hop_start new_hop_end < <(port_hop_compute_range "$new_port")
      echo -e "  自动选择：${C}${new_hop_start}-${new_hop_end}${N}"
      ;;
    3)
      new_hop=1
      new_hop_mode="custom"
      echo -e "  ${D}格式：起始-结束（如 30000-31000），范围不能含主端口 ${new_port}${N}"
      while true; do
        read -p "  端口范围 (起始-结束): " range_input
        new_hop_start=$(echo "$range_input" | awk -F- '{print $1}' | tr -dc '0-9')
        new_hop_end=$(echo "$range_input" | awk -F- '{print $2}' | tr -dc '0-9')
        if [ -z "$new_hop_start" ] || [ -z "$new_hop_end" ]; then
          echo -e "  ${R}格式错误${N}"; continue
        fi
        if [ "$new_hop_start" -lt 1024 ] || [ "$new_hop_end" -gt 65535 ]; then
          echo -e "  ${R}端口必须在 1024-65535 之间${N}"; continue
        fi
        if [ "$new_hop_start" -ge "$new_hop_end" ]; then
          echo -e "  ${R}起始端口必须小于结束端口${N}"; continue
        fi
        if [ "$new_port" -ge "$new_hop_start" ] && [ "$new_port" -le "$new_hop_end" ]; then
          echo -e "  ${R}范围不能包含主端口 $new_port${N}"; continue
        fi
        if [ $((new_hop_end - new_hop_start)) -lt 50 ]; then
          echo -e "  ${Y}警告：范围只有 $((new_hop_end-new_hop_start+1)) 个端口${N}"
          read -p "  仍然使用？(y/N): " confirm_small
          if [ "$confirm_small" != "y" ] && [ "$confirm_small" != "Y" ]; then continue; fi
        fi
        break
      done
      ;;
    4)
      new_hop=0
      new_hop_mode=""
      new_hop_start=""
      new_hop_end=""
      ;;
    *)
      # 保留当前设置：若主端口变了且原模式是 auto，则按新端口重算
      new_hop="$cur_hop"
      new_hop_mode="$cur_hop_mode"
      new_hop_start="$cur_hop_start"
      new_hop_end="$cur_hop_end"
      if [ "$cur_hop" = "1" ] && [ "$new_port" != "$cur_port" ]; then
        if [ "$cur_hop_mode" = "auto" ]; then
          read -r new_hop_start new_hop_end < <(port_hop_compute_range "$new_port")
          echo -e "  ${D}主端口已变，自动范围重算为 ${new_hop_start}-${new_hop_end}${N}"
        else
          # 自定义模式下主端口变了，校验老范围是否仍然合法
          if [ "$new_port" -ge "$cur_hop_start" ] && [ "$new_port" -le "$cur_hop_end" ]; then
            echo -e "  ${Y}新主端口落在原自定义范围内 (${cur_hop_start}-${cur_hop_end})${N}"
            echo -e "  ${Y}请重新输入自定义范围${N}"
            new_hop_mode="custom"
            while true; do
              read -p "  新端口范围 (起始-结束): " range_input
              new_hop_start=$(echo "$range_input" | awk -F- '{print $1}' | tr -dc '0-9')
              new_hop_end=$(echo "$range_input" | awk -F- '{print $2}' | tr -dc '0-9')
              if [ -z "$new_hop_start" ] || [ -z "$new_hop_end" ] \
                 || [ "$new_hop_start" -lt 1024 ] || [ "$new_hop_end" -gt 65535 ] \
                 || [ "$new_hop_start" -ge "$new_hop_end" ] \
                 || ([ "$new_port" -ge "$new_hop_start" ] && [ "$new_port" -le "$new_hop_end" ]); then
                echo -e "  ${R}范围非法，请重输${N}"; continue
              fi
              break
            done
          fi
        fi
      fi
      ;;
  esac

  echo ""
  echo -e "  将写入：端口 ${C}$new_port${N}  SNI ${C}$new_sni${N}"
  if [ "$bw_action" = "set" ]; then
    echo -e "  带宽限制：${C}上 ${new_up} / 下 ${new_down} Mbps${N}"
  elif [ "$bw_action" = "unset" ]; then
    echo -e "  带宽限制：${Y}取消限制${N}"
  fi
  if [ "$new_hop" = "1" ]; then
    echo -e "  端口跳跃：${C}${new_hop_start}-${new_hop_end}${N} (${new_hop_mode})"
  elif [ "$cur_hop" = "1" ] && [ "$new_hop" != "1" ]; then
    echo -e "  端口跳跃：${Y}关闭${N}"
  fi
  read -p "  确认修改？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  ensure_jq || { pause_screen; return 1; }
  txn=$(node_transaction_begin hy2) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  if ! cp "$CONFIG_PATH" "$backup_path"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置备份失败${N}"
    pause_screen
    return 1
  fi

  # 自签时若 SNI 改变，重签证书
  if [ "$cur_cert_src" = "self" ] && [ "$new_sni" != "$cur_sni" ]; then
    echo -e "${Y}==> SNI 变更，重新生成自签证书...${N}"
    if ! generate_self_signed_cert_for_hy2 "$new_sni" >/dev/null; then
      node_transaction_rollback "$txn"
      echo -e "${R}自签证书生成失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi

  local jq_filter='(.inbounds[] | select(.tag == "hy2-in"))
    |= ( .listen_port = ($port | tonumber)
       | .tls.server_name = $sni
       | (if $sni != "" and (.tls.acme | type) == "object" then .tls.acme.domain = [$sni] else . end)
       | (if $pw != "" then .users[0].password = $pw else . end)
       | (if $opw != "" and (.obfs | type) == "object" then .obfs.password = $opw else . end)
       | .users[0] |= del(.up_mbps, .down_mbps)
       | (if $bw_action == "set"
          then .up_mbps = ($up | tonumber) | .down_mbps = ($down | tonumber)
          elif $bw_action == "unset"
          then del(.up_mbps, .down_mbps)
          else . end))'

  local tmp_file
  tmp_file=$(mktemp)
  trap 'rm -f "$tmp_file"' RETURN
  if ! jq --arg port "$new_port" --arg sni "$new_sni" \
       --arg pw "${new_pw:-}" --arg opw "${new_obfs_pw:-}" \
       --arg bw_action "$bw_action" --arg up "$new_up" --arg down "$new_down" \
       "$jq_filter" "$CONFIG_PATH" > "$tmp_file"; then
    rm -f "$tmp_file"
    node_transaction_rollback "$txn"
    echo -e "${R}配置写入失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  if ! mv "$tmp_file" "$CONFIG_PATH"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置替换失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if ! config_check_and_restart "$new_port" udp; then
    node_transaction_rollback "$txn"
    echo ""
    echo -e "${R}配置校验或服务健康检查失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  # 端口跳跃规则同步：先清旧的，再加新的
  local need_remove_hop=0
  if [ "$cur_hop" = "1" ] && [ -n "$cur_hop_start" ] && [ -n "$cur_hop_end" ]; then
    # 旧的启用，且：新的禁用 / 范围变了 / 模式变了 / 主端口变了
    if [ "$new_hop" != "1" ] \
       || [ "$cur_hop_start" != "$new_hop_start" ] \
       || [ "$cur_hop_end" != "$new_hop_end" ] \
       || [ "$cur_port" != "$new_port" ]; then
      need_remove_hop=1
    fi
  fi
  if [ "$need_remove_hop" = "1" ]; then
    if ! port_hop_remove "$cur_hop_start" "$cur_hop_end" "$cur_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧端口跳跃规则清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    echo -e "  ${D}旧端口跳跃规则已清理${N}"
  fi
  if [ "$new_hop" = "1" ] && [ -n "$new_hop_start" ] && [ -n "$new_hop_end" ]; then
    local listen_v4="" listen_v6="" public_ipv6_now="" addrs_pair
    public_ipv6_now=$(detect_primary_ipv6 2>/dev/null || true)
    addrs_pair=$(port_hop_listen_addrs_for_mode "$cur_mode" "$public_ipv6_now")
    listen_v4="${addrs_pair%|*}"
    listen_v6="${addrs_pair#*|}"
    if ! port_hop_apply "$new_port" "$new_hop_start" "$new_hop_end" "$cur_mode" "$listen_v4" "$listen_v6"; then
      node_transaction_rollback "$txn"
      echo -e "${R}新端口跳跃规则应用失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    echo -e "  ${G}新端口跳跃规则已应用：${new_hop_start}-${new_hop_end}${N}"
  fi

  if [ -n "$new_port" ] && [ "$new_port" != "$cur_port" ]; then
    if [ -n "$cur_port" ] && ! node_revoke_firewall_for_mode "$cur_port" udp "$cur_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧防火墙端口清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    if ! node_apply_firewall_for_mode "$new_port" udp "$cur_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}防火墙端口切换失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    print_firewall_hint "$new_port" udp "Hysteria2 节点新端口"
  fi

  # 写回 hy2.info
  if ! set_node_value hy2 Port "$new_port" || ! set_node_value hy2 SNI "$new_sni"; then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  if [ -n "$new_pw" ] && ! set_node_value hy2 Password "$new_pw"; then
    node_transaction_rollback "$txn"
    echo -e "${R}节点密码保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  if [ -n "$new_obfs_pw" ] && ! set_node_value hy2 ObfsPassword "$new_obfs_pw"; then
    node_transaction_rollback "$txn"
    echo -e "${R}混淆密码保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  case "$bw_action" in
    set)
      if ! set_node_value hy2 UpMbps "$new_up" || ! set_node_value hy2 DownMbps "$new_down"; then
        node_transaction_rollback "$txn"
        echo -e "${R}带宽参数保存失败，已完整回滚${N}"
        pause_screen
        return 1
      fi
      ;;
    unset)
      # 清空（以空字符串覆盖；后续读取会判空）
      if ! set_node_value hy2 UpMbps "" || ! set_node_value hy2 DownMbps ""; then
        node_transaction_rollback "$txn"
        echo -e "${R}带宽参数保存失败，已完整回滚${N}"
        pause_screen
        return 1
      fi
      ;;
  esac
  if [ "$new_hop" = "1" ]; then
    if ! set_node_value hy2 PortHop "1" \
       || ! set_node_value hy2 PortHopMode "$new_hop_mode" \
       || ! set_node_value hy2 PortHopStart "$new_hop_start" \
       || ! set_node_value hy2 PortHopEnd "$new_hop_end"; then
      node_transaction_rollback "$txn"
      echo -e "${R}端口跳跃信息保存失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  else
    if ! set_node_value hy2 PortHop "0" \
       || ! set_node_value hy2 PortHopMode "" \
       || ! set_node_value hy2 PortHopStart "" \
       || ! set_node_value hy2 PortHopEnd ""; then
      node_transaction_rollback "$txn"
      echo -e "${R}端口跳跃信息保存失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi

  local cur_ip cur_tag insecure obfs_type final_pw final_obfs_pw new_link ipv6_new_link
  cur_ip=$(get_node_value hy2 IP 2>/dev/null || true)
  cur_tag=$(get_node_value hy2 Tag 2>/dev/null || echo hy2)
  insecure=$(get_node_value hy2 Insecure 2>/dev/null || echo 0)
  obfs_type=$(get_node_value hy2 Obfs 2>/dev/null || true)
  [ "$obfs_type" = "none" ] && obfs_type=""
  final_pw="${new_pw:-$cur_pw}"
  final_obfs_pw="${new_obfs_pw:-$cur_obfs_pw}"
  local link_hop_start="" link_hop_end=""
  if [ "$new_hop" = "1" ]; then
    link_hop_start="$new_hop_start"
    link_hop_end="$new_hop_end"
  fi
  new_link=$(build_hy2_link "$final_pw" "$cur_ip" "$new_port" "$new_sni" "$insecure" "$obfs_type" "$final_obfs_pw" "${cur_tag:-hy2}" "$link_hop_start" "$link_hop_end" 2>/dev/null || true)
  ipv6_new_link=$(build_dualstack_ipv6_link_for_node hy2 2>/dev/null || true)
  if [ -n "$new_link" ] && ! set_node_value hy2 Link "$new_link"; then
    node_transaction_rollback "$txn"
    echo -e "${R}客户端链接保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  node_transaction_commit "$txn"
  cleanup_old_backups "${CONFIG_PATH}.bak.*" 5

  echo ""
  echo -e "${G}Hysteria2 节点参数已更新并重启服务${N}"
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

# ─── AnyTLS + Reality 节点（独立 Reality 密钥对） ────────
# 设计：
#   * 独立生成 private_key / public_key / short_id，与 reality 节点互不依赖
#   * 可与 reality 节点共存（端口独立）；也可单独安装，无前置依赖
#   * 默认 SNI 若检测到 reality 已装则沿用其 SNI（仅 UI 默认值，不影响协议）
#   * sing-box 1.12+ 才支持 type: "anytls"
#   * 不写 padding_scheme，使用 anytls-go 内置默认填充规则
