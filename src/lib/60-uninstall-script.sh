uninstall_script_completely(){
  if ! require_root; then return 1; fi

  render_section_header "卸载脚本"
  echo ""
  echo -e "  ${R}此操作将清除以下内容（不可恢复）：${N}"
  echo -e "    ${L}·${N} 所有 sing-box 节点（Reality / Hysteria2 / AnyTLS）及其防火墙端口"
  echo -e "    ${L}·${N} sing-box 服务、软件包与 ${C}/etc/sing-box${N} 整个目录"
  echo -e "    ${L}·${N} 旧版遗留组件（Realm 中转 / Xray 内核 / 流量统计），如存在"
  echo -e "    ${L}·${N} ${C}${INFO_PATH}${N} 与 ${C}${SCRIPT_PATH}${N}"
  echo ""
  echo -e "  ${D}保留：SSH 配置 / 用户账户 / sudoers / 自动更新 / IPv6 防火墙规则 / 1Panel${N}"
  echo -e "  ${D}保留：TCP 网络优化 / QUIC 协议优化 / initcwnd 持久化服务 / 本脚本创建的 SWAP${N}"
  echo ""
  read -p "  确认卸载？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  # 1. 节点防火墙端口（按 nodes/*.info 反查）
  echo ""
  echo -e "${Y}==> 撤销节点防火墙端口...${N}"
  local node port type cert_src
  if [ -d "$NODES_DIR" ]; then
    while IFS= read -r node; do
      [ -n "$node" ] || continue
      type=$(get_node_value "$node" Type 2>/dev/null || echo "$node")
      port=$(get_node_value "$node" Port 2>/dev/null || true)
      case "$type" in
        reality)
          [ -n "$port" ] && deny_port_in_firewall "$port" tcp
          ;;
        anytls)
          [ -n "$port" ] && deny_port_in_firewall "$port" tcp
          ;;
        ss2022)
          [ -n "$port" ] && deny_port_in_firewall "$port" tcp
          ;;
        hy2)
          [ -n "$port" ] && deny_port_in_firewall "$port" udp
          cert_src=$(get_node_value "$node" CertSource 2>/dev/null || true)
          # ACME 模式安装时放行过 80/tcp；但 80 是公共端口（面板 / nginx 等也可能在用），
          # 不自动撤销以免误伤同机其它 web 服务，仅提示用户按需自行处理
          if [ "$cert_src" = "acme" ]; then
            echo -e "  ${D}提示：此前为 ACME 放行过 80/tcp，如确认无其它服务使用可自行关闭${N}"
          fi
          # 端口跳跃范围撤销 ufw / firewalld 规则
          local hop_v hop_start_v hop_end_v
          hop_v=$(get_node_value "$node" PortHop 2>/dev/null || echo 0)
          if [ "$hop_v" = "1" ]; then
            hop_start_v=$(get_node_value "$node" PortHopStart 2>/dev/null || true)
            hop_end_v=$(get_node_value "$node" PortHopEnd 2>/dev/null || true)
            if [ -n "$hop_start_v" ] && [ -n "$hop_end_v" ]; then
              case "$(detect_firewall_backend)" in
                ufw)
                  ufw delete allow "${hop_start_v}:${hop_end_v}/udp" >/dev/null 2>&1 || true
                  ;;
                firewalld)
                  firewall-cmd --permanent --remove-port="${hop_start_v}-${hop_end_v}/udp" >/dev/null 2>&1 || true
                  firewall-cmd --reload >/dev/null 2>&1 || true
                  ;;
              esac
            fi
          fi
          ;;
      esac
    done < <(list_installed_nodes)
  fi

  # 端口跳跃 iptables 链兜底清理
  echo -e "${Y}==> 清理端口跳跃 iptables / ip6tables 规则...${N}"
  port_hop_cleanup_all
  ip4_save_rules >/dev/null 2>&1 || true
  ip6_save_rules >/dev/null 2>&1 || true

  # 2. 停服 + 卸载 sing-box 软件包
  echo -e "${Y}==> 停止并禁用 sing-box 服务...${N}"
  systemctl stop sing-box >/dev/null 2>&1 || true
  systemctl disable sing-box >/dev/null 2>&1 || true

  echo -e "${Y}==> 卸载 sing-box 软件包...${N}"
  apt-get remove --purge -y sing-box >/dev/null 2>&1 || true

  echo -e "${Y}==> 清理 /etc/sing-box（节点信息 / 证书 / 配置 / 备份）...${N}"
  rm -rf /etc/sing-box

  echo -e "${Y}==> 清理 SagerNet APT 仓库与签名 key...${N}"
  rm -f "$SAGERNET_SOURCES" "$SAGERNET_KEYRING"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true

  # 2.5 历史遗留组件清理（Realm 中转 / Xray 内核 / 流量统计已从本脚本移除，
  #     这里兜底清掉旧版本装过的服务与数据，避免留下孤儿 unit）
  echo -e "${Y}==> 清理旧版遗留组件（Realm / Xray / 流量统计）...${N}"
  local legacy_u
  for legacy_u in realm xray-leyili leyili-traffic.timer leyili-traffic; do
    systemctl stop    "$legacy_u" >/dev/null 2>&1 || true
    systemctl disable "$legacy_u" >/dev/null 2>&1 || true
  done
  rm -f /usr/local/bin/realm-bin /usr/local/bin/xray-leyili
  rm -f /etc/systemd/system/realm.service \
        /etc/systemd/system/xray-leyili.service \
        /etc/systemd/system/leyili-traffic.service \
        /etc/systemd/system/leyili-traffic.timer
  rm -rf /etc/realm /etc/leyili/xray /etc/leyili/traffic
  systemctl daemon-reload >/dev/null 2>&1 || true

  # 3. 链路测评（目标 IP 记录 + 历史报告 + 脚本自装的 nexttrace）
  # NETBENCH_NEXTTRACE_BIN 是独立文件名，不会误删用户自装的 /usr/local/bin/nexttrace
  if [ -f "$NETBENCH_ENV_PATH" ] || [ -f "$NETBENCH_NEXTTRACE_BIN" ] || [ -n "$(_nb_latest_report)" ]; then
    echo -e "${Y}==> 清理链路测评数据与 nexttrace...${N}"
    rm -f "$NETBENCH_ENV_PATH" "$NETBENCH_NEXTTRACE_BIN"
    rm -f "${NETBENCH_REPORT_PREFIX}"-*.txt
    [ -d /etc/leyili ] && rmdir --ignore-fail-on-non-empty /etc/leyili 2>/dev/null || true
  fi

  # 4. 脚本痕迹
  echo -e "${Y}==> 清理脚本本体与 legacy 信息文件...${N}"
  rm -f "$INFO_PATH"
  rm -f "$SCRIPT_PATH"

  echo ""
  echo -e "  ${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "  ${G}║${N}  ${B}${W}${APP_NAME}${N}  ${G}已彻底卸载${N}                                  ${G}║${N}"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${N}"
  exit 0
}

# ─── 管理菜单卡片 ─────────────────────────────────────
# 卡片内宽（不含两侧 │ 边框）；外宽 = CARD_INNER_WIDTH + 2，与品牌横幅 56 同宽
