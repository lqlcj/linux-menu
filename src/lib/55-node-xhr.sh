install_xhr_node(){
  local port_input="" sni_input="" tag_input=""
  local x25519_out="" vlessenc_out=""
  local private_key="" public_key="" dec_key="" enc_key=""
  local access_ip="" link="" ipv6_link=""
  local public_ipv4="" public_ipv6=""
  local install_mode="ipv4" mode_label=""
  local PORT SNI TAG LISTEN_CHOICE LISTEN_ADDR UUID SHORT_ID PATH_TOKEN confirm

  if ! require_root; then return 1; fi

  render_section_header "创建 Vless-xhttp-reality-enc 节点"
  echo -e "  ${Y}直接回车使用括号内默认值${N}"
  echo -e "  ${D}（基于 Xray 25.x，需 v2rayN 6.x / NekoBox-starifly 等支持 ENC + xhttp 的客户端）${N}"
  echo ""

  if node_installed xhr; then
    echo -e "${Y}检测到已存在 Vless-xhttp-reality-enc 节点，继续将覆盖原节点配置${N}"
    read -p "  继续？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo -e "  已取消"
      return 0
    fi
  fi

  while true; do
    read -p "  端口 (8443): " port_input
    PORT="${port_input:-8443}"
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

  while true; do
    read -p "  Reality SNI 域名 (www.ucla.edu): " sni_input
    sni_input="${sni_input:-www.ucla.edu}"
    SNI=$(sanitize_sni "$sni_input")
    if [ -n "$SNI" ]; then
      break
    fi
    echo -e "${R}域名不能为空，且不能只包含引号或换行${N}"
  done

  read -p "  节点名称 (xhr): " tag_input
  TAG="${tag_input:-xhr}"

  echo -e "  监听模式："
  echo "    1) 仅 IPv4 入站 + 仅 IPv4 出站 - 0.0.0.0（默认）"
  echo "    2) 双栈入站 + 仅 IPv4 出站 - ::"
  echo "    3) 仅 IPv6 入站 + 仅 IPv4 出站"
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
      echo -e "${R}未检测到可用的 IPv6 地址，无法使用"仅 IPv6 入站 + 仅 IPv4 出站"模式${N}"
      pause_screen
      return 1
    fi
  fi

  # 装 Xray 内核（不影响 sing-box）
  if ! is_xray_installed; then
    echo ""
    echo -e "${Y}==> 安装 Xray 内核（用于 xhttp + ENC）...${N}"
    if ! install_xray; then
      echo ""
      echo -e "${R}Xray 安装失败，请检查上方输出${N}"
      pause_screen
      return 1
    fi
  else
    echo -e "${D}  已检测到 Xray 内核：v$(get_current_xray_version)${N}"
  fi

  xray_install_systemd_unit
  xray_config_ensure_skeleton || { pause_screen; return 1; }

  echo -e "${Y}==> 生成 UUID / ShortID / Reality 密钥对 / ENC 密钥对...${N}"
  UUID=$(cat /proc/sys/kernel/random/uuid)
  SHORT_ID=$(openssl rand -hex 4)
  PATH_TOKEN="${UUID}-xh"

  # Reality 公私钥（参考 argosbx.sh:208-214；xray x25519 输出格式：
  #   "PrivateKey: ..." 和 "Password: ..."，Password 即客户端用的 PublicKey）
  if ! x25519_out=$("$XRAY_BIN_PATH" x25519 2>&1); then
    echo -e "${R}xray x25519 执行失败：${N}"
    printf '%s\n' "$x25519_out" | sed 's/^/    /'
    pause_screen
    return 1
  fi
  private_key=$(printf '%s\n' "$x25519_out" | awk -F':' '/PrivateKey/ {print $2}' | xargs)
  public_key=$(printf '%s\n' "$x25519_out" | awk -F':' '/Password/ {print $2}' | xargs)
  if [ -z "$private_key" ] || [ -z "$public_key" ]; then
    echo -e "${R}Reality 密钥对解析失败，原始输出：${N}"
    printf '%s\n' "$x25519_out" | sed 's/^/    /'
    pause_screen
    return 1
  fi

  # ENC 密钥对（参考 argosbx.sh:222-224）
  # xray vlessenc 输出包含 server / client 两块 JSON，每块都有
  # "decryption": "..." 和 "encryption": "..."，但 server 的 decryption 才是
  # 服务器要的，client 的 encryption 才是客户端要的（取第 2 个匹配）
  if ! vlessenc_out=$("$XRAY_BIN_PATH" vlessenc 2>&1); then
    echo -e "${R}xray vlessenc 执行失败 — 你的 Xray 版本可能太旧不支持 ENC：${N}"
    printf '%s\n' "$vlessenc_out" | sed 's/^/    /'
    echo -e "${Y}请通过菜单「更新管理」升级 Xray 内核到 25.x 以上${N}"
    pause_screen
    return 1
  fi
  dec_key=$(printf '%s\n' "$vlessenc_out" | grep '"decryption":' | sed -n '2p' | cut -d' ' -f2- | tr -d '",')
  enc_key=$(printf '%s\n' "$vlessenc_out" | grep '"encryption":' | sed -n '2p' | cut -d' ' -f2- | tr -d '",')
  if [ -z "$dec_key" ] || [ -z "$enc_key" ]; then
    echo -e "${R}ENC 密钥对解析失败，原始输出：${N}"
    printf '%s\n' "$vlessenc_out" | sed 's/^/    /'
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

  echo -e "${Y}==> 写入 Xray 配置...${N}"
  local inbound_json
  inbound_json=$(jq -n \
    --arg tag "$XRAY_INBOUND_TAG" \
    --arg listen "$LISTEN_ADDR" \
    --argjson port "$PORT" \
    --arg uuid "$UUID" \
    --arg dec "$dec_key" \
    --arg sni "$SNI" \
    --arg priv "$private_key" \
    --arg sid "$SHORT_ID" \
    --arg path "$PATH_TOKEN" '{
      tag: $tag,
      listen: $listen,
      port: $port,
      protocol: "vless",
      settings: {
        clients: [{id: $uuid, flow: "xtls-rprx-vision"}],
        decryption: $dec
      },
      streamSettings: {
        network: "xhttp",
        security: "reality",
        realitySettings: {
          fingerprint: "chrome",
          target: ($sni + ":443"),
          serverNames: [$sni],
          privateKey: $priv,
          shortIds: [$sid]
        },
        xhttpSettings: {
          host: "",
          path: $path,
          mode: "auto"
        }
      },
      sniffing: {
        enabled: true,
        destOverride: ["http", "tls", "quic"],
        metadataOnly: false
      }
    }')

  if ! xray_config_add_inbound "$inbound_json"; then
    echo -e "${R}写入 Xray inbound 失败${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 校验并启动 ${XRAY_SERVICE_NAME}...${N}"
  if ! xray_config_check_and_restart; then
    echo ""
    echo -e "${R}Xray 校验或重启失败${N}"
    pause_screen
    return 1
  fi

  node_apply_firewall_for_mode "$PORT" tcp "$install_mode"
  print_firewall_hint "$PORT" tcp "Vless-xhttp-reality-enc 节点入站"

  link=$(build_xhr_link "$UUID" "$access_ip" "$PORT" "$SNI" "$public_key" "$SHORT_ID" "$enc_key" "$PATH_TOKEN" "$TAG" 2>/dev/null || true)
  if [ "$install_mode" = "dualstack" ] && [ -n "$public_ipv6" ] && [ "$public_ipv6" != "$access_ip" ]; then
    ipv6_link=$(build_xhr_link "$UUID" "$public_ipv6" "$PORT" "$SNI" "$public_key" "$SHORT_ID" "$enc_key" "$PATH_TOKEN" "${TAG}-ipv6" 2>/dev/null || true)
  fi

  ensure_nodes_dir
  cat > "$(node_info_path xhr)" <<EOF
Type=xhr
Tag=$TAG
Mode=$install_mode
ListenAddr=$LISTEN_ADDR
Port=$PORT
SNI=$SNI
UUID=$UUID
PublicKey=$public_key
PrivateKey=$private_key
ShortID=$SHORT_ID
EncKey=$enc_key
DecKey=$dec_key
Path=$PATH_TOKEN
IP=$access_ip
Link=$link
EOF

  register_sb_command || true

  echo ""
  echo -e "  ${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "  ${G}║${N}  ${B}${W}${APP_NAME}${N}  ${G}Vless-xhttp-reality-enc 节点创建完成${N}        ${G}║${N}"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${N}"
  echo -e "  模式      : ${C}$mode_label${N}"
  echo -e "  UUID      : ${C}$UUID${N}"
  echo -e "  PublicKey : ${C}$public_key${N}"
  echo -e "  ShortID   : ${C}$SHORT_ID${N}"
  echo -e "  入口 IP   : ${C}${access_ip:-未知}${N}"
  echo -e "  出站策略  : ${C}仅 IPv4${N}"
  echo -e "  端口      : ${C}$PORT${N}  ${D}(TCP)${N}"
  echo -e "  SNI       : ${C}$SNI${N}"
  echo -e "  网络层    : ${C}xhttp${N}  ${D}path=${PATH_TOKEN}${N}"
  echo -e "  加密      : ${C}ENC (Post-Quantum)${N}"
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
  echo -e "  ${Y}注意：此协议需要支持 ENC + xhttp + Reality 的客户端${N}"
  echo -e "  ${D}  · v2rayN 6.x+ / NekoBox-starifly fork (Android) / Happ (iOS)${N}"
  echo -e "  信息已保存至 ${Y}$(node_info_path xhr)${N}"
  echo -e "  输入 ${B}${COMMAND_NAME}${N} 进入管理菜单"
  pause_screen
}

uninstall_xhr_node(){
  local confirm
  if ! node_installed xhr; then
    echo -e "${Y}Vless-xhttp-reality-enc 节点未安装${N}"
    pause_screen
    return 0
  fi

  echo ""
  read -p "  确认卸载 Vless-xhttp-reality-enc 节点？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  # 必须在 remove_node_info 之前撤防火墙规则，否则读不到 Mode/Port
  local rt_port rt_mode
  rt_port=$(get_node_value xhr Port 2>/dev/null || true)
  rt_mode=$(get_node_value xhr Mode 2>/dev/null || echo ipv4)
  if [ -n "$rt_port" ]; then
    node_revoke_firewall_for_mode "$rt_port" tcp "$rt_mode"
  fi

  xray_config_remove_inbound_by_tag "$XRAY_INBOUND_TAG" || true
  remove_node_info xhr
  post_uninstall_xray_step
  echo -e "${G}Vless-xhttp-reality-enc 节点已卸载${N}"
  pause_screen
}

