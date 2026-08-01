# ═══════════════════════════════════════════════════════
#  流量统计：/proc/net/dev 计数器累计 + systemd 定时器落盘
#  - 状态文件跨重启累计（重启后内核计数器归零，采样器自动续算）
#  - 采样器是写死路径的独立小脚本，不依赖脚本本体：
#    本体升级 / 回退 / 被删都不影响每分钟的计数落盘
# ═══════════════════════════════════════════════════════

# 从状态文件读取单个字段（awk 提取，不 source，防止执行任意内容）
_traffic_state_get(){
  awk -F'=' -v k="$1" '$1==k {print $2; exit}' "$TRAFFIC_STATE_PATH" 2>/dev/null
}

# 非法 / 空值一律回落为 0，保证后续算术安全
_traffic_num(){
  case "${1:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac
}

# 载入状态到全局变量；未启用（无状态文件 / 网卡名非法）返回 1
traffic_load_state(){
  TRAFFIC_IFACE_V=""
  TRAFFIC_ACC_RX_V=0; TRAFFIC_ACC_TX_V=0
  TRAFFIC_LAST_RX_V=0; TRAFFIC_LAST_TX_V=0
  TRAFFIC_RESET_AT_V=0
  [ -f "$TRAFFIC_STATE_PATH" ] || return 1
  local v
  v=$(_traffic_state_get IFACE)
  case "$v" in ''|*[!A-Za-z0-9._-]*) return 1 ;; *) TRAFFIC_IFACE_V="$v" ;; esac
  TRAFFIC_ACC_RX_V=$(_traffic_num "$(_traffic_state_get ACC_RX)")
  TRAFFIC_ACC_TX_V=$(_traffic_num "$(_traffic_state_get ACC_TX)")
  TRAFFIC_LAST_RX_V=$(_traffic_num "$(_traffic_state_get LAST_RX)")
  TRAFFIC_LAST_TX_V=$(_traffic_num "$(_traffic_state_get LAST_TX)")
  TRAFFIC_RESET_AT_V=$(_traffic_num "$(_traffic_state_get RESET_AT)")
  return 0
}

# 原子落盘（tmp + mv）；写失败静默返回 1（非 root 只读浏览时容错）
traffic_save_state(){
  local tmp="${TRAFFIC_STATE_PATH}.tmp.$$"
  mkdir -p "$TRAFFIC_DIR" 2>/dev/null || return 1
  {
    echo "IFACE=$TRAFFIC_IFACE_V"
    echo "ACC_RX=$TRAFFIC_ACC_RX_V"
    echo "ACC_TX=$TRAFFIC_ACC_TX_V"
    echo "LAST_RX=$TRAFFIC_LAST_RX_V"
    echo "LAST_TX=$TRAFFIC_LAST_TX_V"
    echo "RESET_AT=$TRAFFIC_RESET_AT_V"
  } 2>/dev/null > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$TRAFFIC_STATE_PATH" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# 手动跑一次采样器（root 打开页面时把未落盘增量先结算掉）；任何失败静默
traffic_run_sampler(){
  [ -x "$TRAFFIC_SAMPLER_PATH" ] && "$TRAFFIC_SAMPLER_PATH" >/dev/null 2>&1
  return 0
}

# 实时总量（只读不落盘）：已累计值 + 当前计数与上次快照的差
# 输出 "rx tx total"（bytes）；调用前需先 traffic_load_state
traffic_live_totals(){
  local v cur_rx cur_tx rx tx
  rx=$TRAFFIC_ACC_RX_V; tx=$TRAFFIC_ACC_TX_V
  v=$(status_read_iface "$TRAFFIC_IFACE_V")
  if [ -n "$v" ]; then
    cur_rx=$(_traffic_num "${v% *}")
    cur_tx=$(_traffic_num "${v#* }")
    if [ "$cur_rx" -ge "$TRAFFIC_LAST_RX_V" ] && [ "$cur_tx" -ge "$TRAFFIC_LAST_TX_V" ]; then
      rx=$(( rx + cur_rx - TRAFFIC_LAST_RX_V ))
      tx=$(( tx + cur_tx - TRAFFIC_LAST_TX_V ))
    else
      # 计数器已归零（重启后定时器还没跑过）：按新计数整段并入
      rx=$(( rx + cur_rx ))
      tx=$(( tx + cur_tx ))
    fi
  fi
  printf '%s %s %s' "$rx" "$tx" "$(( rx + tx ))"
}

# 紧凑字节格式（主页卡片用，最长 5 可见列：1023G / 99.9G / 9.99G / 999B）
traffic_format_compact(){
  local b
  b=$(_traffic_num "${1:-0}")
  awk -v n="$b" 'BEGIN{
    split("B K M G T P", u, " ")
    i = 1
    while (n >= 1024 && i < 6) { n /= 1024; i++ }
    if (i == 1)        printf "%d%s",   n, u[i]
    else if (n >= 100) printf "%.0f%s", n, u[i]
    else if (n >= 10)  printf "%.1f%s", n, u[i]
    else               printf "%.2f%s", n, u[i]
  }'
}

# 候选网卡列表（/proc/net/dev 里除 lo 外的所有接口）
traffic_list_ifaces(){
  awk -F':' 'NR > 2 {gsub(/[[:space:]]/, "", $1); if ($1 != "" && $1 != "lo") print $1}' /proc/net/dev 2>/dev/null
}

traffic_timer_is_active(){
  systemctl is-active "$(basename "$TRAFFIC_TIMER_PATH")" >/dev/null 2>&1
}

# 写独立采样器脚本（与本体解耦；STATE 路径在安装时展开写死）
traffic_write_sampler(){
  mkdir -p "$TRAFFIC_DIR" 2>/dev/null || return 1
  {
    printf '#!/bin/bash\n'
    printf '# %s 流量采样器：由 %s 每分钟调用，勿手动编辑\n' "$APP_NAME" "$(basename "$TRAFFIC_TIMER_PATH")"
    printf 'STATE=%s\n' "$TRAFFIC_STATE_PATH"
    cat << 'SAMPLER_EOF'
[ -r "$STATE" ] || exit 0

num(){ case "${1:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac }
get(){ awk -F'=' -v k="$1" '$1==k {print $2; exit}' "$STATE" 2>/dev/null; }

iface=$(get IFACE)
case "$iface" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
acc_rx=$(num "$(get ACC_RX)");   acc_tx=$(num "$(get ACC_TX)")
last_rx=$(num "$(get LAST_RX)"); last_tx=$(num "$(get LAST_TX)")
reset_at=$(num "$(get RESET_AT)")

v=$(awk -v key="${iface}:" '$1==key {print $2" "$10; exit}' /proc/net/dev 2>/dev/null)
[ -n "$v" ] || exit 0
cur_rx=$(num "${v% *}"); cur_tx=$(num "${v#* }")

if [ "$cur_rx" -ge "$last_rx" ] && [ "$cur_tx" -ge "$last_tx" ]; then
  acc_rx=$(( acc_rx + cur_rx - last_rx ))
  acc_tx=$(( acc_tx + cur_tx - last_tx ))
else
  # 计数器已归零（重启 / 回绕）：按新计数整段累计
  acc_rx=$(( acc_rx + cur_rx ))
  acc_tx=$(( acc_tx + cur_tx ))
fi

tmp="${STATE}.tmp.$$"
{
  echo "IFACE=$iface"
  echo "ACC_RX=$acc_rx"
  echo "ACC_TX=$acc_tx"
  echo "LAST_RX=$cur_rx"
  echo "LAST_TX=$cur_tx"
  echo "RESET_AT=$reset_at"
} 2>/dev/null > "$tmp" && mv -f "$tmp" "$STATE"
exit 0
SAMPLER_EOF
  } > "$TRAFFIC_SAMPLER_PATH" || return 1
  chmod +x "$TRAFFIC_SAMPLER_PATH"
}

# 写 systemd service + timer 并启用（开机 50s 后首采，此后每分钟一次）
traffic_install_units(){
  cat > "$TRAFFIC_SERVICE_PATH" << EOF
[Unit]
Description=${APP_NAME} traffic accounting sample
ConditionPathExists=${TRAFFIC_STATE_PATH}

[Service]
Type=oneshot
ExecStart=${TRAFFIC_SAMPLER_PATH}
EOF

  cat > "$TRAFFIC_TIMER_PATH" << EOF
[Unit]
Description=${APP_NAME} traffic accounting timer

[Timer]
OnBootSec=50s
OnUnitActiveSec=60s
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now "$(basename "$TRAFFIC_TIMER_PATH")" >/dev/null 2>&1
}

traffic_remove_units(){
  systemctl disable --now "$(basename "$TRAFFIC_TIMER_PATH")" >/dev/null 2>&1 || true
  rm -f "$TRAFFIC_TIMER_PATH" "$TRAFFIC_SERVICE_PATH"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

enable_traffic_monitor(){
  if ! require_root; then return 1; fi

  local iface v cur_rx cur_tx
  iface=$(status_default_iface)
  if [ -z "$iface" ] || [ -z "$(status_read_iface "$iface")" ]; then
    echo ""
    echo -e "  ${Y}未能从默认路由识别网卡，请手动选择：${N}"
    traffic_list_ifaces | sed 's/^/    · /'
    echo ""
    read -p "  请输入网卡名: " iface
    iface=$(printf '%s' "$iface" | tr -d '[:space:]')
    if [ -z "$iface" ] || [ -z "$(status_read_iface "$iface")" ]; then
      echo -e "  ${R}网卡不存在或无计数数据，已取消${N}"
      sleep 1
      return 1
    fi
  fi

  v=$(status_read_iface "$iface")
  cur_rx=$(_traffic_num "${v% *}")
  cur_tx=$(_traffic_num "${v#* }")

  TRAFFIC_IFACE_V="$iface"
  TRAFFIC_ACC_RX_V=0; TRAFFIC_ACC_TX_V=0
  TRAFFIC_LAST_RX_V=$cur_rx; TRAFFIC_LAST_TX_V=$cur_tx
  TRAFFIC_RESET_AT_V=$(date +%s)

  if ! traffic_save_state; then
    echo -e "  ${R}状态文件写入失败：${TRAFFIC_STATE_PATH}${N}"
    pause_screen
    return 1
  fi
  if ! traffic_write_sampler; then
    echo -e "  ${R}采样器写入失败：${TRAFFIC_SAMPLER_PATH}${N}"
    pause_screen
    return 1
  fi
  if ! traffic_install_units; then
    echo -e "  ${R}systemd 定时器启用失败，可稍后在本菜单选「修复采样定时器」重试${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "  ${G}流量统计已启用${N}  监控网卡: ${C}${iface}${N} ${D}·${N} 每分钟自动落盘"
  sleep 1
}

# 重置：累计清零，基线对齐当前计数，重新从零开始
reset_traffic_stats(){
  if ! require_root; then return 1; fi
  echo ""
  read -p "  确认清零已累计的入站 / 出站流量？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi
  local v
  v=$(status_read_iface "$TRAFFIC_IFACE_V")
  if [ -n "$v" ]; then
    TRAFFIC_LAST_RX_V=$(_traffic_num "${v% *}")
    TRAFFIC_LAST_TX_V=$(_traffic_num "${v#* }")
  fi
  TRAFFIC_ACC_RX_V=0
  TRAFFIC_ACC_TX_V=0
  TRAFFIC_RESET_AT_V=$(date +%s)
  if traffic_save_state; then
    echo -e "  ${G}已重置，重新从零开始累计${N}"
  else
    echo -e "  ${R}状态写入失败${N}"
  fi
  sleep 1
}

change_traffic_iface(){
  if ! require_root; then return 1; fi
  local iface v
  echo ""
  echo -e "  当前监控网卡: ${C}${TRAFFIC_IFACE_V}${N}，可选网卡："
  traffic_list_ifaces | sed 's/^/    · /'
  echo ""
  read -p "  请输入新网卡名 (留空取消): " iface
  iface=$(printf '%s' "$iface" | tr -d '[:space:]')
  if [ -z "$iface" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi
  case "$iface" in *[!A-Za-z0-9._-]*)
    echo -e "  ${R}网卡名不合法${N}"
    sleep 1
    return 1 ;;
  esac
  if [ -z "$(status_read_iface "$iface")" ]; then
    echo -e "  ${R}网卡不存在或无计数数据${N}"
    sleep 1
    return 1
  fi
  # 先把旧网卡未落盘的增量结算掉，历史累计保留，再切基线到新网卡
  traffic_run_sampler
  traffic_load_state || return 1
  v=$(status_read_iface "$iface")
  TRAFFIC_IFACE_V="$iface"
  TRAFFIC_LAST_RX_V=$(_traffic_num "${v% *}")
  TRAFFIC_LAST_TX_V=$(_traffic_num "${v#* }")
  if traffic_save_state; then
    echo -e "  ${G}已切换到 ${iface}，历史累计保留${N}"
  else
    echo -e "  ${R}状态写入失败${N}"
  fi
  sleep 1
}

disable_traffic_monitor(){
  if ! require_root; then return 1; fi
  echo ""
  read -p "  确认停用流量统计并删除累计数据？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi
  traffic_remove_units
  rm -rf "$TRAFFIC_DIR"
  [ -d /etc/leyili ] && rmdir --ignore-fail-on-non-empty /etc/leyili 2>/dev/null
  echo -e "  ${Y}流量统计已停用，数据已清除${N}"
  sleep 1
  return 0
}

show_traffic_menu(){
  local choice confirm
  while true; do
    render_section_header "流量统计"

    if ! traffic_load_state; then
      echo ""
      echo -e "  ${D}统计指定网卡的入站 / 出站累计流量，重启不清零，可随时重置。${N}"
      echo -e "  ${D}启用后由 systemd 定时器每分钟采样落盘，主页卡片同步展示。${N}"
      echo ""
      render_menu_item 1 "启用流量统计"
      render_menu_item 0 "返回上级"
      render_divider
      read -p "  请输入序号: " choice
      case $choice in
        1) enable_traffic_monitor ;;
        0) return ;;
        *) notify_invalid_choice ;;
      esac
      continue
    fi

    # 已启用：root 时先结算一次未落盘增量，再展示
    traffic_run_sampler
    traffic_load_state

    local totals rx tx sum iface_disp have_iface reset_str elapsed_str
    totals=$(traffic_live_totals)
    read -r rx tx sum <<< "$totals"

    have_iface=0
    if [ -n "$(status_read_iface "$TRAFFIC_IFACE_V")" ]; then
      have_iface=1
      iface_disp="${C}${TRAFFIC_IFACE_V}${N}"
    else
      iface_disp="${R}${TRAFFIC_IFACE_V} (未找到，请更换网卡)${N}"
    fi

    reset_str=$(date -d "@${TRAFFIC_RESET_AT_V}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "未知")
    local now diff
    now=$(date +%s)
    diff=$(( now - TRAFFIC_RESET_AT_V ))
    [ "$diff" -lt 0 ] && diff=0
    if [ "$diff" -ge 86400 ]; then
      elapsed_str="已统计 $(( diff / 86400 )) 天"
    elif [ "$diff" -ge 3600 ]; then
      elapsed_str="已统计 $(( diff / 3600 )) 小时"
    else
      elapsed_str="已统计 $(( diff / 60 )) 分钟"
    fi

    local timer_active=0 timer_line saved_str
    traffic_timer_is_active && timer_active=1
    if [ "$timer_active" -eq 1 ]; then
      saved_str=$(date -r "$TRAFFIC_STATE_PATH" '+%H:%M:%S' 2>/dev/null || echo "?")
      timer_line="${G}运行中${N} ${D}· 每分钟落盘 · 上次 ${saved_str}${N}"
    else
      timer_line="${R}未运行${N} ${D}· 重启会丢数据，请选 4 修复${N}"
    fi

    echo ""
    printf "  ${L}●${N} %s : %b\n" "监控网卡" "$iface_disp"
    printf "  ${L}●${N} %s : %b\n" "统计起始" "${reset_str} ${D}(${elapsed_str})${N}"
    printf "  ${L}●${N} %s : %b\n" "入站流量" "${G}↓${N} ${C}$(status_format_bytes "$rx")${N}"
    printf "  ${L}●${N} %s : %b\n" "出站流量" "${C}↑${N} ${C}$(status_format_bytes "$tx")${N}"
    printf "  ${L}●${N} %s : %b\n" "流量总计" "${B}${C}$(status_format_bytes "$sum")${N}"
    printf "  ${L}●${N} %s : %b\n" "采样服务" "$timer_line"

    if [ "$have_iface" -eq 1 ]; then
      echo ""
      echo -e "  ${C}正在采样实时速率（约 1 秒）...${N}"
      local speeds spd_rx spd_tx
      speeds=$(status_sample_speed "$TRAFFIC_IFACE_V")
      spd_rx=$(_traffic_num "${speeds% *}")
      spd_tx=$(_traffic_num "${speeds#* }")
      printf "\033[1A\033[2K"
      printf "  ${L}●${N} %s : ${G}↓${N} %s   ${C}↑${N} %s\n" "实时速率" \
        "$(status_format_speed "$spd_rx")" "$(status_format_speed "$spd_tx")"
    fi

    echo ""
    render_menu_item 1 "重置流量统计"
    render_menu_item 2 "更换监控网卡"
    render_menu_item 3 "停用流量统计"
    [ "$timer_active" -eq 0 ] && render_menu_item 4 "修复采样定时器"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号 (回车刷新): " choice

    case $choice in
      "")
        continue
        ;;
      1)
        reset_traffic_stats
        ;;
      2)
        change_traffic_iface
        ;;
      3)
        disable_traffic_monitor
        ;;
      4)
        if [ "$timer_active" -eq 0 ]; then
          if require_root; then
            if traffic_write_sampler && traffic_install_units; then
              echo -e "  ${G}采样定时器已修复${N}"
            else
              echo -e "  ${R}修复失败，请检查 systemd 状态${N}"
            fi
            sleep 1
          fi
        else
          notify_invalid_choice
        fi
        ;;
      0)
        return
        ;;
      *)
        notify_invalid_choice
        ;;
    esac
  done
}
