PORT_HOP_NAT_CHAIN="LEYILI_HOP_NAT"
PORT_HOP_RANGE_SIZE=999

port_hop_compute_range(){
  local port="$1" start end above below
  above=$((65535 - port))
  if [ "$port" -gt 1024 ]; then
    below=$((port - 1024))
  else
    below=0
  fi
  # 优先放主端口上方；上方不够就放下方；都不够则选空间大的一侧
  if [ "$above" -ge "$PORT_HOP_RANGE_SIZE" ]; then
    start=$((port + 1))
    end=$((port + PORT_HOP_RANGE_SIZE))
  elif [ "$below" -ge "$PORT_HOP_RANGE_SIZE" ]; then
    end=$((port - 1))
    start=$((end - PORT_HOP_RANGE_SIZE))
  elif [ "$above" -ge "$below" ] && [ "$above" -ge 50 ]; then
    start=$((port + 1))
    end=65535
  elif [ "$below" -ge 50 ]; then
    end=$((port - 1))
    start=1024
  else
    # 极端情况（不会发生：port 在 1024 以内），仍输出可用范围
    start=$((port + 1))
    end=65535
  fi
  printf '%s %s' "$start" "$end"
}

port_hop_range_has_conflict(){
  local start="$1" end="$2"
  ss -ulnH 2>/dev/null | awk -v s="$start" -v e="$end" '
    {n=split($4,a,":"); p=a[n]+0;
     if (p>=s && p<=e) {found=1; exit}}
    END {exit !found}'
}

port_hop_list_conflicts(){
  local start="$1" end="$2"
  ss -ulnH 2>/dev/null | awk -v s="$start" -v e="$end" '
    {n=split($4,a,":"); p=a[n]+0;
     if (p>=s && p<=e) print "  · 端口 " p " → " $NF}'
}

port_hop_apply_v4(){
  local port="$1" start="$2" end="$3" listen="$4"
  command -v iptables >/dev/null 2>&1 || return 1
  iptables -t nat -nL "$PORT_HOP_NAT_CHAIN" >/dev/null 2>&1 \
    || iptables -t nat -N "$PORT_HOP_NAT_CHAIN" || return 1
  iptables -t nat -F "$PORT_HOP_NAT_CHAIN" || return 1
  if [ -z "$listen" ] || [ "$listen" = "0.0.0.0" ]; then
    iptables -t nat -A "$PORT_HOP_NAT_CHAIN" -p udp \
      --dport "${start}:${end}" -j REDIRECT --to-ports "$port" || return 1
  else
    iptables -t nat -A "$PORT_HOP_NAT_CHAIN" -p udp \
      --dport "${start}:${end}" -j DNAT --to-destination "${listen}:${port}" || return 1
  fi
  iptables -t nat -C PREROUTING -j "$PORT_HOP_NAT_CHAIN" 2>/dev/null \
    || iptables -t nat -I PREROUTING 1 -j "$PORT_HOP_NAT_CHAIN" || return 1
}

port_hop_apply_v6(){
  local port="$1" start="$2" end="$3" listen="$4"
  if ! command -v ip6tables >/dev/null 2>&1; then
    return 0
  fi
  ip6tables -t nat -nL "$PORT_HOP_NAT_CHAIN" >/dev/null 2>&1 \
    || ip6tables -t nat -N "$PORT_HOP_NAT_CHAIN" || return 1
  ip6tables -t nat -F "$PORT_HOP_NAT_CHAIN" || return 1
  if [ -z "$listen" ] || [ "$listen" = "::" ]; then
    ip6tables -t nat -A "$PORT_HOP_NAT_CHAIN" -p udp \
      --dport "${start}:${end}" -j REDIRECT --to-ports "$port" || return 1
  else
    ip6tables -t nat -A "$PORT_HOP_NAT_CHAIN" -p udp \
      --dport "${start}:${end}" -j DNAT --to-destination "[${listen}]:${port}" || return 1
  fi
  ip6tables -t nat -C PREROUTING -j "$PORT_HOP_NAT_CHAIN" 2>/dev/null \
    || ip6tables -t nat -I PREROUTING 1 -j "$PORT_HOP_NAT_CHAIN" || return 1
}

port_hop_remove_v4(){
  command -v iptables >/dev/null 2>&1 || return 0
  iptables -t nat -nL "$PORT_HOP_NAT_CHAIN" >/dev/null 2>&1 || return 0
  while iptables -t nat -C PREROUTING -j "$PORT_HOP_NAT_CHAIN" >/dev/null 2>&1; do
    iptables -t nat -D PREROUTING -j "$PORT_HOP_NAT_CHAIN" || return 1
  done
  iptables -t nat -F "$PORT_HOP_NAT_CHAIN" || return 1
  iptables -t nat -X "$PORT_HOP_NAT_CHAIN" || return 1
  # 注意：不在此删除 INPUT 链主端口 ACCEPT，因为节点本身可能仍需要它；
  # 节点真正卸载时由 node_revoke_firewall_for_mode 统一清理。
}

port_hop_remove_v6(){
  if ! command -v ip6tables >/dev/null 2>&1; then
    return 0
  fi
  ip6tables -t nat -nL "$PORT_HOP_NAT_CHAIN" >/dev/null 2>&1 || return 0
  while ip6tables -t nat -C PREROUTING -j "$PORT_HOP_NAT_CHAIN" >/dev/null 2>&1; do
    ip6tables -t nat -D PREROUTING -j "$PORT_HOP_NAT_CHAIN" || return 1
  done
  ip6tables -t nat -F "$PORT_HOP_NAT_CHAIN" || return 1
  ip6tables -t nat -X "$PORT_HOP_NAT_CHAIN" || return 1
  # 同上，不在此清 INPUT 主端口规则
}

port_hop_apply(){
  local port="$1" start="$2" end="$3" mode="$4"
  local listen_v4="$5" listen_v6="$6"
  case "$mode" in
    ipv4)              port_hop_apply_v4 "$port" "$start" "$end" "$listen_v4" ;;
    dualstack)         port_hop_apply_v4 "$port" "$start" "$end" "$listen_v4" \
                         && port_hop_apply_v6 "$port" "$start" "$end" "$listen_v6" ;;
    ipv6-in-ipv4-out)  port_hop_apply_v6 "$port" "$start" "$end" "$listen_v6" ;;
    *) return 1 ;;
  esac
  local rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  case "$mode" in
    ipv4|dualstack) ip4_save_rules >/dev/null 2>&1 || return 1 ;;
  esac
  case "$mode" in
    dualstack|ipv6-in-ipv4-out) ip6_save_rules >/dev/null 2>&1 || return 1 ;;
  esac
}

port_hop_remove(){
  local start="$1" end="$2" mode="$3"
  case "$mode" in
    ipv4|dualstack)              port_hop_remove_v4 "$start" "$end" || return 1 ;;
  esac
  case "$mode" in
    dualstack|ipv6-in-ipv4-out)  port_hop_remove_v6 "$start" "$end" || return 1 ;;
  esac
  case "$mode" in
    ipv4|dualstack) ip4_save_rules >/dev/null 2>&1 || return 1 ;;
  esac
  case "$mode" in
    dualstack|ipv6-in-ipv4-out) ip6_save_rules >/dev/null 2>&1 || return 1 ;;
  esac
}

port_hop_cleanup_all(){
  local rc=0
  if command -v iptables >/dev/null 2>&1 \
     && iptables -t nat -nL "$PORT_HOP_NAT_CHAIN" >/dev/null 2>&1; then
    while iptables -t nat -C PREROUTING -j "$PORT_HOP_NAT_CHAIN" >/dev/null 2>&1; do
      iptables -t nat -D PREROUTING -j "$PORT_HOP_NAT_CHAIN" || rc=1
      [ "$rc" -eq 0 ] || break
    done
    iptables -t nat -F "$PORT_HOP_NAT_CHAIN" || rc=1
    iptables -t nat -X "$PORT_HOP_NAT_CHAIN" || rc=1
    ip4_save_rules >/dev/null 2>&1 || rc=1
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    if ip6tables -t nat -nL "$PORT_HOP_NAT_CHAIN" >/dev/null 2>&1; then
      while ip6tables -t nat -C PREROUTING -j "$PORT_HOP_NAT_CHAIN" >/dev/null 2>&1; do
        ip6tables -t nat -D PREROUTING -j "$PORT_HOP_NAT_CHAIN" || rc=1
        [ "$rc" -eq 0 ] || break
      done
      ip6tables -t nat -F "$PORT_HOP_NAT_CHAIN" || rc=1
      ip6tables -t nat -X "$PORT_HOP_NAT_CHAIN" || rc=1
      ip6_save_rules >/dev/null 2>&1 || rc=1
    fi
  fi
  return "$rc"
}

# 根据 install_mode 推导端口跳跃所需的 v4 / v6 监听地址
port_hop_listen_addrs_for_mode(){
  local mode="$1" public_ipv6="$2"
  local listen_v4="" listen_v6=""
  case "$mode" in
    ipv4)             listen_v4="0.0.0.0" ;;
    dualstack)        listen_v4="0.0.0.0"; listen_v6="::" ;;
    ipv6-in-ipv4-out) listen_v6="$public_ipv6" ;;
  esac
  printf '%s|%s' "$listen_v4" "$listen_v6"
}

# ─── Hysteria2 节点 ────────────────────────────────────
