uninstall_script_completely(){
  if ! require_root; then return 1; fi

  render_section_header "卸载脚本"
  echo ""
  echo -e "  ${R}此操作将清除以下脚本托管内容：${N}"
  echo -e "    ${L}·${N} 脚本专属防火墙链和已登记的 ufw/firewalld 端口"
  echo -e "    ${L}·${N} 链路测评数据、专用 nexttrace 与 ${C}${SCRIPT_PATH}${N}"
  echo ""
  echo -e "  ${D}保留：SSH 配置 / 用户账户 / sudoers / 自动更新 / 1Panel${N}"
  echo -e "  ${D}保留：TCP 网络优化 / QUIC 协议优化 / initcwnd 持久化服务 / 本脚本创建的 SWAP${N}"
  echo -e "  ${Y}脚本专属防火墙链移除前会把 INPUT 默认策略改为 ACCEPT，避免卸载后 SSH 被锁。${N}"
  echo ""
  read -p "  确认卸载？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  local rc=0
  local fw4_txn="" fw6_txn="" fw_owned_txn="" cleanup_ok=1 rollback_ok=1

  # 整段只有操作前快照与失败即时恢复，不创建任何定时自动回滚任务。
  echo -e "${Y}==> 清理脚本托管防火墙规则...${N}"
  fw_owned_txn=$(mktemp -d "${TMPDIR:-/tmp}/leyili-fw-owned-uninstall.XXXXXX") \
    || { echo -e "${R}防火墙所有权快照创建失败${N}"; pause_screen; return 1; }
  chmod 700 "$fw_owned_txn" 2>/dev/null \
    || { rm -rf -- "$fw_owned_txn"; echo -e "${R}防火墙所有权快照权限设置失败${N}"; pause_screen; return 1; }
  if [ -f "$FIREWALL_PORT_STATE" ]; then
    cp -a -- "$FIREWALL_PORT_STATE" "$fw_owned_txn/firewall-ports.state" \
      || { rm -rf -- "$fw_owned_txn"; echo -e "${R}防火墙端口所有权快照失败${N}"; pause_screen; return 1; }
    : > "$fw_owned_txn/firewall-ports.existed"
  else
    : > "$fw_owned_txn/firewall-ports.state"
  fi

  if command -v iptables >/dev/null 2>&1; then
    fw4_txn=$(firewall_transaction_begin 4) || {
      rm -rf -- "$fw_owned_txn"
      echo -e "${R}IPv4 防火墙快照失败，未修改任何规则${N}"
      pause_screen
      return 1
    }
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    fw6_txn=$(firewall_transaction_begin 6) || {
      [ -n "$fw4_txn" ] && firewall_transaction_commit "$fw4_txn"
      rm -rf -- "$fw_owned_txn"
      echo -e "${R}IPv6 防火墙快照失败，未修改任何规则${N}"
      pause_screen
      return 1
    }
  fi

  firewall_remove_all_owned_ports || cleanup_ok=0
  if [ "$cleanup_ok" -eq 1 ] && firewall_managed_chain_exists 4; then
    if ! iptables -P INPUT ACCEPT \
       || ! firewall_remove_managed_chain 4 \
       || ! ip4_save_rules; then
      cleanup_ok=0
    fi
  fi
  if [ "$cleanup_ok" -eq 1 ] && firewall_managed_chain_exists 6; then
    if ! ip6tables -P INPUT ACCEPT \
       || ! firewall_remove_managed_chain 6 \
       || ! ip6_save_rules; then
      cleanup_ok=0
    fi
  fi

  if [ "$cleanup_ok" -ne 1 ]; then
    firewall_owned_ports_restore "$fw_owned_txn/firewall-ports.state" \
      "$fw_owned_txn/firewall-ports.existed" || rollback_ok=0
    [ -n "$fw6_txn" ] && firewall_transaction_rollback 6 "$fw6_txn" || {
      [ -z "$fw6_txn" ] || rollback_ok=0
    }
    [ -n "$fw4_txn" ] && firewall_transaction_rollback 4 "$fw4_txn" || {
      [ -z "$fw4_txn" ] || rollback_ok=0
    }
    if [ "$rollback_ok" -eq 1 ]; then
      rm -rf -- "$fw_owned_txn"
      echo -e "${R}防火墙规则清理失败，已立即恢复操作前快照；完整卸载已中止${N}"
    else
      echo -e "${R}防火墙规则清理及回滚未完全成功，请立即检查；所有权快照保留在 ${fw_owned_txn}${N}"
    fi
    pause_screen
    return 1
  fi

  if [ -n "$fw6_txn" ] && ! firewall_transaction_commit "$fw6_txn"; then rc=1; fi
  if [ -n "$fw4_txn" ] && ! firewall_transaction_commit "$fw4_txn"; then rc=1; fi
  rm -rf -- "$fw_owned_txn" || rc=1

  # 链路测评（独立命名文件，不碰用户自装 nexttrace）
  # NETBENCH_NEXTTRACE_BIN 是独立文件名，不会误删用户自装的 /usr/local/bin/nexttrace
  if [ -f "$NETBENCH_ENV_PATH" ] || [ -f "$NETBENCH_NEXTTRACE_BIN" ] || [ -n "$(_nb_latest_report)" ]; then
    echo -e "${Y}==> 清理链路测评数据与 nexttrace...${N}"
    rm -f -- "$NETBENCH_ENV_PATH" "$NETBENCH_NEXTTRACE_BIN" || rc=1
    rm -f -- "${NETBENCH_REPORT_PREFIX}"-*.txt || rc=1
    [ -d /etc/leyili ] && rmdir --ignore-fail-on-non-empty /etc/leyili 2>/dev/null || true
  fi

  # 只有前面全部完成才删除脚本本体；失败时保留入口方便重试。
  echo -e "${Y}==> 清理脚本本体...${N}"

  if [ "$rc" -ne 0 ]; then
    echo ""
    echo -e "${R}部分清理步骤失败，未删除 ${SCRIPT_PATH}；请检查上方信息后重试。${N}"
    pause_screen
    return 1
  fi
  if ! rm -f -- "$SCRIPT_PATH"; then
    echo -e "${R}脚本入口删除失败：${SCRIPT_PATH}${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "  ${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "  ${G}║${N}  ${B}${W}${APP_NAME}${N}  ${G}脚本托管内容已卸载${N}                          ${G}║${N}"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${N}"
  exit 0
}
