show_node_install_menu(){
  while true; do
    render_section_header "创建节点"
    render_menu_item 1 "创建 Reality 节点$(node_installed reality && echo "  ${D}(已安装，将覆盖)${N}")"
    render_menu_item 2 "创建 Hysteria2 节点$(node_installed hy2 && echo "  ${D}(已安装，将覆盖)${N}")"
    if node_installed reality; then
      render_menu_item 3 "创建 AnyTLS 节点$(node_installed anytls && echo "  ${D}(已安装，将覆盖)${N}")"
    else
      echo -e "  ${D}3) 创建 AnyTLS 节点  (需先创建 Reality)${N}"
    fi
    render_menu_item 4 "创建 TUIC v5 节点$(node_installed tuic && echo "  ${D}(已安装，将覆盖)${N}")"
    render_menu_item 5 "创建 Shadowsocks-2022 节点  ${R}[谨慎]${N}$(node_installed ss2022 && echo "  ${D}(已安装，将覆盖)${N}")"
    render_menu_item 6 "创建 Vless-xhttp-reality-enc 节点  ${C}[Xray + ENC]${N}$(node_installed xhr && echo "  ${D}(已安装，将覆盖)${N}")"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice
    case $choice in
      1) install_reality_node; return ;;
      2) install_hy2_node; return ;;
      3)
        if node_installed reality; then
          install_anytls_node; return
        else
          notify_invalid_choice
        fi
        ;;
      4) install_tuic_node; return ;;
      5) install_ss2022_node; return ;;
      6) install_xhr_node; return ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

show_node_uninstall_menu(){
  while true; do
    render_section_header "卸载单个节点"
    if node_installed reality; then
      render_menu_item 1 "卸载 Reality 节点"
    else
      echo -e "  ${D}1) Reality 未安装${N}"
    fi
    if node_installed hy2; then
      render_menu_item 2 "卸载 Hysteria2 节点"
    else
      echo -e "  ${D}2) Hysteria2 未安装${N}"
    fi
    if node_installed anytls; then
      render_menu_item 3 "卸载 AnyTLS 节点"
    else
      echo -e "  ${D}3) AnyTLS 未安装${N}"
    fi
    if node_installed tuic; then
      render_menu_item 4 "卸载 TUIC v5 节点"
    else
      echo -e "  ${D}4) TUIC 未安装${N}"
    fi
    if node_installed ss2022; then
      render_menu_item 5 "卸载 Shadowsocks-2022 节点"
    else
      echo -e "  ${D}5) Shadowsocks-2022 未安装${N}"
    fi
    if node_installed xhr; then
      render_menu_item 6 "卸载 Vless-xhttp-reality-enc 节点"
    else
      echo -e "  ${D}6) Vless-xhttp-reality-enc 未安装${N}"
    fi
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice
    case $choice in
      1) node_installed reality && uninstall_reality_node; return ;;
      2) node_installed hy2 && uninstall_hy2_node; return ;;
      3) node_installed anytls && uninstall_anytls_node; return ;;
      4) node_installed tuic && uninstall_tuic_node; return ;;
      5) node_installed ss2022 && uninstall_ss2022_node; return ;;
      6) node_installed xhr && uninstall_xhr_node; return ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

upgrade_singbox_kernel(){
  local cur_ver latest_ver confirm
  cur_ver=$(get_current_singbox_version)
  latest_ver=$(get_latest_singbox_version)
  echo ""
  echo -e "  当前版本: ${C}${cur_ver:-未知}${N}"
  echo -e "  最新版本: ${C}${latest_ver:-获取失败}${N}"
  if [ -n "$cur_ver" ] && [ -n "$latest_ver" ] && [ "$cur_ver" = "$latest_ver" ]; then
    echo -e "${G}已是最新版本${N}"
    sleep 1
    return 0
  fi
  read -p "  确认升级 sing-box 内核？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi
  echo -e "${Y}==> 升级内核（不覆盖配置）...${N}"
  if ! upgrade_singbox; then
    echo ""
    echo -e "${R}sing-box 升级失败，请检查上方输出${N}"
    pause_screen
  elif ! systemctl restart sing-box; then
    echo ""
    echo -e "${R}升级完成，但服务重启失败${N}"
    pause_screen
  else
    echo -e "${G}升级完成${N}"
    sleep 1
  fi
}

upgrade_xray_kernel(){
  local cur_ver latest_ver confirm
  cur_ver=$(get_current_xray_version 2>/dev/null || echo "")
  latest_ver=$(get_latest_xray_version)
  echo ""
  echo -e "  当前版本: ${C}${cur_ver:-未安装}${N}"
  echo -e "  最新版本: ${C}${latest_ver:-获取失败}${N}"
  if [ -n "$cur_ver" ] && [ -n "$latest_ver" ] && [ "v${cur_ver}" = "$latest_ver" ]; then
    echo -e "${G}已是最新版本${N}"
    sleep 1
    return 0
  fi
  read -p "  确认升级 Xray 内核？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi
  echo -e "${Y}==> 升级内核（不覆盖配置）...${N}"
  if ! upgrade_xray; then
    echo ""
    echo -e "${R}Xray 升级失败，请检查上方输出${N}"
    pause_screen
    return 1
  fi
  # 只有正在跑的 xray-leyili 才重启；没装节点时静默跳过
  if systemctl is-active "$XRAY_SERVICE_NAME" >/dev/null 2>&1; then
    if ! systemctl restart "$XRAY_SERVICE_NAME"; then
      echo ""
      echo -e "${R}升级完成，但服务重启失败${N}"
      pause_screen
      return 1
    fi
  fi
  echo -e "${G}升级完成${N}"
  sleep 1
}

show_update_menu(){
  local choice cur_ver kernel_label xray_label xray_cur
  while true; do
    if command -v sing-box >/dev/null 2>&1; then
      cur_ver=$(get_current_singbox_version)
      if [ -n "$cur_ver" ]; then
        kernel_label="升级 sing-box 内核  ${D}(当前: v${cur_ver})${N}"
      else
        kernel_label="升级 sing-box 内核  ${D}(版本未知)${N}"
      fi
    else
      kernel_label="升级 sing-box 内核  ${D}(未安装)${N}"
    fi

    if is_xray_installed; then
      xray_cur=$(get_current_xray_version 2>/dev/null || echo "")
      if [ -n "$xray_cur" ]; then
        xray_label="升级 Xray 内核  ${D}(当前: v${xray_cur})${N}"
      else
        xray_label="升级 Xray 内核  ${D}(版本未知)${N}"
      fi
    else
      xray_label="升级 Xray 内核  ${D}(未安装，仅 xhttp-reality-enc 节点需要)${N}"
    fi

    render_section_header "更新管理"
    render_menu_item 1 "更新脚本"
    render_menu_item 2 "$kernel_label"
    render_menu_item 3 "$xray_label"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice
    case $choice in
      1) update_self_script ;;
      2) upgrade_singbox_kernel ;;
      3) upgrade_xray_kernel ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

check_reality_dest_domain(){
  local domain ips ip ipn org cdn_match handshake proto x25 alpn cipher
  local cert_san cert_match=0 san san_value suffix
  local any_fail=0 fastest=999 t i testip
  local CDN_BLACKLIST="Cloudflare|Fastly|Akamai|CloudFront|Amazon|Microsoft|Google|Azure|Incapsula|Imperva"

  echo ""
  read -p "  请输入要测试的域名（如 www.osaka-u.ac.jp，回车取消）: " domain
  domain=$(echo "$domain" | tr -d ' \t\r\n')
  if [ -z "$domain" ]; then
    return 0
  fi
  if ! printf '%s' "$domain" | grep -qE '^[a-zA-Z0-9._-]+$'; then
    echo -e "${R}  域名格式不合法（仅允许字母、数字、点、横线、下划线）${N}"
    pause_screen
    return 1
  fi

  echo ""
  render_section_header "Reality 域名检测：$domain"
  echo ""

  # 1. DNS 解析
  echo -e "  ${B}[1/6] DNS 解析${N}"
  ips=$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
  if [ -z "$ips" ]; then
    echo -e "    ${R}✗ DNS 解析失败${N}"
    echo ""
    render_divider
    echo -e "  ${R}✗ 不可用 — DNS 解析失败${N}"
    echo ""
    pause_screen
    return 1
  fi
  ipn=$(echo "$ips" | wc -l | tr -d ' ')
  ip=$(echo "$ips" | head -1)
  if [ "$ipn" -le 3 ]; then
    echo -e "    ${G}✓${N} 解析到 ${C}${ipn}${N} 个 IP："
  else
    echo -e "    ${Y}△${N} 解析到 ${C}${ipn}${N} 个 IP（>3 个有踩死 IP 风险）："
  fi
  echo "$ips" | sed 's/^/      /'

  # 2. ASN / 归属
  echo ""
  echo -e "  ${B}[2/6] IP 归属（首个 IP）${N}"
  org=$(curl -s --max-time 5 "https://ipinfo.io/$ip/org" 2>/dev/null | tr -d '\n')
  if [ -z "$org" ]; then
    echo -e "    ${Y}? 无法查询 ipinfo.io（VPS 网络受限），跳过${N}"
    org="未知"
  elif echo "$org" | grep -qiE "$CDN_BLACKLIST"; then
    cdn_match=$(echo "$org" | grep -ioE "$CDN_BLACKLIST" | head -1)
    echo -e "    ${R}✗ $org${N}"
    echo -e "    ${R}  → 命中 CDN/云厂商黑名单（${cdn_match}）${N}"
  else
    echo -e "    ${G}✓ $org${N}"
  fi

  # 3. TCP 443 通断（所有 IP）
  echo ""
  echo -e "  ${B}[3/6] TCP 443 通断${N}"
  for testip in $ips; do
    if timeout 3 bash -c "echo > /dev/tcp/$testip/443" 2>/dev/null; then
      echo -e "    ${G}✓${N} $testip"
    else
      echo -e "    ${R}✗${N} $testip"
      any_fail=1
    fi
  done

  # 4. TLS 1.3 + X25519 + ALPN
  echo ""
  echo -e "  ${B}[4/6] TLS 1.3 + X25519 + ALPN（IP=${ip}）${N}"
  handshake=$(echo | timeout 5 openssl s_client -connect "$ip:443" -servername "$domain" \
                -tls1_3 -groups X25519 -alpn h2,http/1.1 2>/dev/null)
  proto=$(echo "$handshake" | grep -m1 -oE 'TLSv1\.[0-9]+')
  x25=$(echo "$handshake" | grep -q 'X25519' && echo yes || echo no)
  alpn=$(echo "$handshake" | grep -m1 -oE 'ALPN protocol: \S+' | awk '{print $3}')
  cipher=$(echo "$handshake" | grep -m1 -oE 'Cipher\s*:\s*\S+' | awk -F'[: ]+' '{print $NF}')

  if [ "$proto" = "TLSv1.3" ]; then
    echo -e "    ${G}✓${N} Protocol: TLSv1.3"
  else
    echo -e "    ${R}✗${N} Protocol: ${proto:-握手失败} ${R}(reality 强制 TLS 1.3)${N}"
  fi
  if [ "$x25" = "yes" ]; then
    echo -e "    ${G}✓${N} X25519 密钥交换支持"
  else
    echo -e "    ${R}✗${N} X25519 ${R}不支持（reality 默认密钥交换）${N}"
  fi
  case "$alpn" in
    h2)        echo -e "    ${G}✓${N} ALPN: h2 (HTTP/2，最现代)" ;;
    http/1.1)  echo -e "    ${Y}△${N} ALPN: http/1.1 (可用但伪装稍弱)" ;;
    "")        echo -e "    ${Y}△${N} ALPN: 未协商" ;;
    *)         echo -e "    ${Y}△${N} ALPN: $alpn" ;;
  esac
  if [ -n "$cipher" ]; then
    echo -e "    ${C}  Cipher: $cipher${N}"
  fi

  # 5. 证书 SAN
  echo ""
  echo -e "  ${B}[5/6] 证书 SAN 是否覆盖该域名${N}"
  cert_san=$(echo | timeout 5 openssl s_client -connect "$ip:443" -servername "$domain" 2>/dev/null \
              | openssl x509 -noout -ext subjectAltName 2>/dev/null \
              | grep -oE 'DNS:[^,]+' | tr -d ' ' | head -10)
  if [ -n "$cert_san" ]; then
    while IFS= read -r san; do
      san_value=${san#DNS:}
      if [ "$san_value" = "$domain" ]; then
        cert_match=1
        break
      fi
      case "$san_value" in
        \*.*)
          suffix=${san_value#\*.}
          case "$domain" in
            *.$suffix) cert_match=1; break ;;
          esac
          ;;
      esac
    done <<EOF
$cert_san
EOF
    if [ "$cert_match" = "1" ]; then
      echo -e "    ${G}✓${N} 证书覆盖该域名"
    else
      echo -e "    ${Y}△${N} 证书 SAN 未明确覆盖："
    fi
    echo "$cert_san" | head -3 | sed 's/^/      /'
  else
    echo -e "    ${Y}△${N} 无法读取证书 SAN"
  fi

  # 6. TCP 握手延迟
  echo ""
  echo -e "  ${B}[6/6] TCP 握手延迟（3 次取最快）${N}"
  for i in 1 2 3; do
    t=$(curl -o /dev/null -s --max-time 4 --resolve "$domain:443:$ip" \
        -w '%{time_connect}' "https://$domain/" 2>/dev/null)
    if [ -n "$t" ]; then
      echo -e "    第 $i 次: ${C}${t}s${N}"
      if awk "BEGIN { exit !($t < $fastest) }" 2>/dev/null; then
        fastest=$t
      fi
    else
      echo -e "    第 $i 次: ${R}失败${N}"
    fi
  done

  # 综合评级
  echo ""
  render_divider
  echo -e "  ${B}综合判定${N}"
  if [ -n "$cdn_match" ]; then
    echo -e "    ${R}✗ 不可用 — 命中 CDN/云厂商黑名单（$cdn_match）${N}"
  elif [ "$proto" != "TLSv1.3" ] || [ "$x25" != "yes" ]; then
    echo -e "    ${R}✗ 不可用 — TLS 1.3 + X25519 不满足${N}"
  elif [ "$any_fail" = "1" ]; then
    echo -e "    ${Y}△ 慎用 — 有 IP 不通，可能成为定时炸弹（参考 tmu.ac.jp 案例）${N}"
  elif [ "$ipn" -gt 3 ]; then
    echo -e "    ${Y}△ 慎用 — IP 数量较多（${ipn} 个），未来踩死 IP 风险偏高${N}"
  elif [ "$alpn" != "h2" ]; then
    echo -e "    ${Y}△ 可用 — 但 ALPN 是 ${alpn:-未协商}，伪装稍弱${N}"
  elif [ "$cert_match" != "1" ]; then
    echo -e "    ${Y}△ 可用 — 但证书 SAN 未覆盖该域名${N}"
  else
    echo -e "    ${G}✓ 完美 — 全部硬指标通过，建议作为 reality dest${N}"
  fi
  if [ "$fastest" != "999" ]; then
    echo -e "    最快延迟: ${C}${fastest}s${N}"
  fi
  echo ""
  pause_screen
}

show_node_manage_menu(){
  while true; do
    render_section_header "节点管理"
    render_menu_item 1 "创建节点 (Reality / Hysteria2 / AnyTLS / TUIC / SS-2022)"
    render_menu_item 2 "卸载单个节点"
    render_menu_item 3 "Reality 域名检测工具"
    render_menu_item 4 "WARP 谷歌解锁分流"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice
    case $choice in
      1) show_node_install_menu ;;
      2) show_node_uninstall_menu ;;
      3) check_reality_dest_domain ;;
      4) show_warp_menu ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════════════
# WARP 谷歌解锁分流模块
# ─────────────────────────────────────────────────────────────────────
# 用途   : 解决 VPS 出口 IP 被 Google 标记为中国导致 Gemini/搜索/YouTube 异常
# 原理   : 在 sing-box 配置里加一个 wireguard endpoint（Cloudflare WARP），
#          配合 geosite:google 规则集做路由分流，让 Google 流量从 WARP 出去
# 影响面 : 仅修改 /etc/sing-box/config.json 一个文件，不动 DNS / iptables /
#          内核 WireGuard / ip route，不影响现有 Reality/Hy2/AnyTLS/TUIC 节点
# 边界   : 只对通过 sing-box 入站节点转发的流量生效，不影响 VPS 本机直连
# ═══════════════════════════════════════════════════════════════════════

