uninstall_script_completely(){
  if ! require_root; then return 1; fi

  render_section_header "卸载脚本"
  echo ""
  echo -e "  ${R}此操作将清除以下脚本托管内容：${N}"
  echo -e "    ${L}·${N} Reality / Hysteria2 / AnyTLS / TUIC / SS-2022 节点与端口"
  echo -e "    ${L}·${N} WARP 账号、脚本规则、端口跳跃与专属防火墙链"
  echo -e "    ${L}·${N} sing-box 服务与软件包（不使用 purge）"
  echo -e "    ${L}·${N} 可确认属于旧版脚本的 Realm / Xray / 流量统计组件"
  echo -e "    ${L}·${N} ${C}${INFO_PATH}${N} 与 ${C}${SCRIPT_PATH}${N}"
  echo ""
  echo -e "  ${G}会保留：${C}/etc/sing-box${N} 中的用户自定义配置、inbound、DNS、路由和其它文件${N}"
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

  local node tag proto txn rc=0
  local warp_cache_added warp_cache_path
  local fw4_txn="" fw6_txn="" fw_owned_txn="" cleanup_ok=1 rollback_ok=1

  # 1. WARP：先从配置移除，再删除账号。失败立即恢复配置与账号。
  echo ""
  echo -e "${Y}==> 清理 WARP 分流与账号...${N}"
  warp_cache_added=$(warp_managed_state_get CacheFileAdded 2>/dev/null || echo 0)
  warp_cache_path=$(warp_managed_state_get CachePath 2>/dev/null || true)
  if [ -f "$CONFIG_PATH" ] && { warp_config_has_outbound || warp_config_has_rule; }; then
    txn=$(warp_transaction_begin) || { echo -e "${R}WARP 快照失败，卸载已中止${N}"; pause_screen; return 1; }
    if ! warp_config_remove || ! config_check_and_restart; then
      warp_transaction_rollback "$txn"
      echo -e "${R}WARP 配置清理失败，已恢复原状态；卸载已中止${N}"
      pause_screen
      return 1
    fi
    warp_transaction_commit "$txn"
  fi
  if [ "$warp_cache_added" = "1" ] && [ -n "$warp_cache_path" ]; then
    case "$warp_cache_path" in
      /var/lib/sing-box/*|/var/cache/leyili/*) rm -f -- "$warp_cache_path" || rc=1 ;;
    esac
  fi
  rm -f -- "$WARP_WGCF_BIN" || rc=1
  rm -rf -- "$WARP_DIR" || rc=1

  # 2. 逐个移除有状态记录的脚本节点；每个节点自身都是即时回滚事务。
  echo -e "${Y}==> 清理脚本托管节点...${N}"
  for node in reality hy2 anytls tuic ss2022; do
    node_installed "$node" || continue
    case "$node" in
      reality) tag="reality-in"; ;;
      hy2)     tag="hy2-in"; ;;
      anytls)  tag="anytls-in"; ;;
      tuic)    tag="tuic-in"; ;;
      ss2022)  tag="ss2022-in"; ;;
    esac
    case "$node" in hy2|tuic) proto="udp" ;; *) proto="tcp" ;; esac
    if ! uninstall_node_transaction "$node" "$tag" "$proto"; then
      echo -e "${R}${node} 清理失败并已回滚，完整卸载已中止${N}"
      pause_screen
      return 1
    fi
  done

  # 旧版可能遗失 .info；只删除脚本固定 tag，不碰其它 inbound。
  if [ -f "$CONFIG_PATH" ]; then
    ensure_jq || { pause_screen; return 1; }
    txn=$(config_transaction_begin uninstall-orphans) \
      || { echo -e "${R}配置快照失败，卸载已中止${N}"; pause_screen; return 1; }
    for tag in reality-in hy2-in anytls-in tuic-in ss2022-in; do
      if ! config_remove_inbound_by_tag "$tag"; then
        config_transaction_rollback "$txn"
        echo -e "${R}清理遗留 inbound 失败，已恢复原配置${N}"
        pause_screen
        return 1
      fi
    done
    if ! post_uninstall_service_step; then
      config_transaction_rollback "$txn"
      echo -e "${R}sing-box 健康检查失败，已恢复原配置${N}"
      pause_screen
      return 1
    fi
    config_transaction_commit "$txn"
  fi

  # 3. 端口跳跃、脚本登记的 ufw/firewalld 端口、专属链。
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

  port_hop_cleanup_all || cleanup_ok=0
  if [ "$cleanup_ok" -eq 1 ]; then
    firewall_remove_all_owned_ports || cleanup_ok=0
  fi
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

  # 4. 停服 + 卸载软件包。remove 不用 purge，避免包管理器删除用户配置。
  echo -e "${Y}==> 停止并禁用 sing-box 服务...${N}"
  if systemctl is-active --quiet sing-box 2>/dev/null; then
    systemctl stop sing-box >/dev/null 2>&1 || rc=1
  fi
  if systemctl is-enabled --quiet sing-box 2>/dev/null; then
    systemctl disable sing-box >/dev/null 2>&1 || rc=1
  fi

  echo -e "${Y}==> 卸载 sing-box 软件包...${N}"
  if dpkg-query -W -f='${Status}' sing-box 2>/dev/null | grep -q 'install ok installed'; then
    if ! DEBIAN_FRONTEND=noninteractive apt-get remove -y sing-box >/dev/null 2>&1; then
      echo -e "${R}sing-box 软件包卸载失败；脚本本体已保留，便于重试${N}"
      pause_screen
      return 1
    fi
  fi

  echo -e "${Y}==> 清理脚本节点信息、证书与自身生成的配置备份...${N}"
  rm -f -- "$NODES_DIR/reality.info" "$NODES_DIR/hy2.info" "$NODES_DIR/anytls.info" \
            "$NODES_DIR/tuic.info" "$NODES_DIR/ss2022.info" || rc=1
  rm -f -- "$CERTS_DIR/hy2.crt" "$CERTS_DIR/hy2.key" \
            "$CERTS_DIR/tuic.crt" "$CERTS_DIR/tuic.key" || rc=1
  if [ -d "$(dirname -- "$CONFIG_PATH")" ]; then
    find "$(dirname -- "$CONFIG_PATH")" -maxdepth 1 -type f \
      \( -name 'config.json.bak.*' -o -name 'config.json.*.bak' \) -delete 2>/dev/null || rc=1
  fi
  [ -d "$NODES_DIR" ] && rmdir -- "$NODES_DIR" 2>/dev/null || true
  [ -d "$CERTS_DIR" ] && rmdir -- "$CERTS_DIR" 2>/dev/null || true
  [ -d /etc/sing-box ] && rmdir -- /etc/sing-box 2>/dev/null || true

  echo -e "${Y}==> 清理脚本添加的 SagerNet APT 仓库与签名 key...${N}"
  if ! sagernet_repo_restore; then
    echo -e "${R}SagerNet 仓库文件恢复/清理失败${N}"
    rc=1
  fi
  if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1; then
    echo -e "  ${Y}APT 索引刷新失败，但仓库文件已移除；稍后可手动 apt-get update${N}"
  fi

  # 5. 历史遗留：只处理脚本特征明确的 unit，不盲删用户自装的 realm。
  echo -e "${Y}==> 清理旧版遗留组件（Realm / Xray / 流量统计）...${N}"
  local legacy_u
  for legacy_u in xray-leyili leyili-traffic.timer leyili-traffic; do
    if systemctl is-active --quiet "$legacy_u" 2>/dev/null \
       && ! systemctl stop "$legacy_u" >/dev/null 2>&1; then
      rc=1
    fi
    if systemctl is-enabled --quiet "$legacy_u" 2>/dev/null \
       && ! systemctl disable "$legacy_u" >/dev/null 2>&1; then
      rc=1
    fi
  done
  if [ -f /etc/systemd/system/realm.service ] \
     && grep -Fq '/usr/local/bin/realm-bin' /etc/systemd/system/realm.service; then
    if systemctl is-active --quiet realm 2>/dev/null \
       && ! systemctl stop realm >/dev/null 2>&1; then rc=1; fi
    if systemctl is-enabled --quiet realm 2>/dev/null \
       && ! systemctl disable realm >/dev/null 2>&1; then rc=1; fi
    rm -f -- /etc/systemd/system/realm.service /usr/local/bin/realm-bin \
              /etc/realm/config.toml || rc=1
    [ -d /etc/realm ] && rmdir -- /etc/realm 2>/dev/null || true
  fi
  rm -f -- /usr/local/bin/xray-leyili \
        /etc/systemd/system/xray-leyili.service \
        /etc/systemd/system/leyili-traffic.service \
        /etc/systemd/system/leyili-traffic.timer || rc=1
  rm -rf -- /etc/leyili/xray /etc/leyili/traffic || rc=1
  systemctl daemon-reload >/dev/null 2>&1 || rc=1

  # 6. 链路测评（独立命名文件，不碰用户自装 nexttrace）
  # NETBENCH_NEXTTRACE_BIN 是独立文件名，不会误删用户自装的 /usr/local/bin/nexttrace
  if [ -f "$NETBENCH_ENV_PATH" ] || [ -f "$NETBENCH_NEXTTRACE_BIN" ] || [ -n "$(_nb_latest_report)" ]; then
    echo -e "${Y}==> 清理链路测评数据与 nexttrace...${N}"
    rm -f -- "$NETBENCH_ENV_PATH" "$NETBENCH_NEXTTRACE_BIN" || rc=1
    rm -f -- "${NETBENCH_REPORT_PREFIX}"-*.txt || rc=1
    [ -d /etc/leyili ] && rmdir --ignore-fail-on-non-empty /etc/leyili 2>/dev/null || true
  fi

  # 7. 只有前面全部完成才删除脚本本体；失败时保留入口方便重试。
  echo -e "${Y}==> 清理脚本本体与 legacy 信息文件...${N}"
  rm -f -- "$INFO_PATH" || rc=1

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
  if [ -f "$CONFIG_PATH" ] || [ -d /etc/sing-box ]; then
    echo -e "  ${D}用户自定义的 /etc/sing-box 内容已保留。${N}"
  fi
  exit 0
}

# ─── 管理菜单卡片 ─────────────────────────────────────
# 卡片内宽（不含两侧 │ 边框）；外宽 = CARD_INNER_WIDTH + 2，与品牌横幅 56 同宽
