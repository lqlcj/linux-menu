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
  iptables -t nat -N "$PORT_HOP_NAT_CHAIN" 2>/dev/null || true
  iptables -t nat -F "$PORT_HOP_NAT_CHAIN"
  if [ -z "$listen" ] || [ "$listen" = "0.0.0.0" ]; then
    iptables -t nat -A "$PORT_HOP_NAT_CHAIN" -p udp \
      --dport "${start}:${end}" -j REDIRECT --to-ports "$port"
  else
    iptables -t nat -A "$PORT_HOP_NAT_CHAIN" -p udp \
      --dport "${start}:${end}" -j DNAT --to-destination "${listen}:${port}"
  fi
  iptables -t nat -C PREROUTING -j "$PORT_HOP_NAT_CHAIN" 2>/dev/null \
    || iptables -t nat -I PREROUTING 1 -j "$PORT_HOP_NAT_CHAIN"
  # filter 表 INPUT 看到的是 DNAT/REDIRECT 之后的 dport（主端口），所以放行主端口而非 hop 范围
  iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -p udp --dport "$port" -j ACCEPT
}

port_hop_apply_v6(){
  local port="$1" start="$2" end="$3" listen="$4"
  if ! command -v ip6tables >/dev/null 2>&1; then
    return 0
  fi
  ip6tables -t nat -N "$PORT_HOP_NAT_CHAIN" 2>/dev/null || true
  ip6tables -t nat -F "$PORT_HOP_NAT_CHAIN"
  if [ -z "$listen" ] || [ "$listen" = "::" ]; then
    ip6tables -t nat -A "$PORT_HOP_NAT_CHAIN" -p udp \
      --dport "${start}:${end}" -j REDIRECT --to-ports "$port"
  else
    ip6tables -t nat -A "$PORT_HOP_NAT_CHAIN" -p udp \
      --dport "${start}:${end}" -j DNAT --to-destination "[${listen}]:${port}"
  fi
  ip6tables -t nat -C PREROUTING -j "$PORT_HOP_NAT_CHAIN" 2>/dev/null \
    || ip6tables -t nat -I PREROUTING 1 -j "$PORT_HOP_NAT_CHAIN"
  # filter 表 INPUT 看到的是 DNAT/REDIRECT 之后的 dport（主端口），所以放行主端口而非 hop 范围
  ip6tables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null \
    || ip6tables -A INPUT -p udp --dport "$port" -j ACCEPT
}

port_hop_remove_v4(){
  local start="$1" end="$2"
  iptables -t nat -F "$PORT_HOP_NAT_CHAIN" 2>/dev/null || true
  iptables -t nat -D PREROUTING -j "$PORT_HOP_NAT_CHAIN" 2>/dev/null || true
  iptables -t nat -X "$PORT_HOP_NAT_CHAIN" 2>/dev/null || true
  # 注意：不在此删除 INPUT 链主端口 ACCEPT，因为节点本身可能仍需要它；
  # 节点真正卸载时由 node_revoke_firewall_for_mode 统一清理。
}

port_hop_remove_v6(){
  local start="$1" end="$2"
  if ! command -v ip6tables >/dev/null 2>&1; then
    return 0
  fi
  ip6tables -t nat -F "$PORT_HOP_NAT_CHAIN" 2>/dev/null || true
  ip6tables -t nat -D PREROUTING -j "$PORT_HOP_NAT_CHAIN" 2>/dev/null || true
  ip6tables -t nat -X "$PORT_HOP_NAT_CHAIN" 2>/dev/null || true
  # 同上，不在此清 INPUT 主端口规则
}

port_hop_apply(){
  local port="$1" start="$2" end="$3" mode="$4"
  local listen_v4="$5" listen_v6="$6"
  case "$mode" in
    ipv4)              port_hop_apply_v4 "$port" "$start" "$end" "$listen_v4" ;;
    dualstack)         port_hop_apply_v4 "$port" "$start" "$end" "$listen_v4"
                       port_hop_apply_v6 "$port" "$start" "$end" "$listen_v6" ;;
    ipv6-in-ipv4-out)  port_hop_apply_v6 "$port" "$start" "$end" "$listen_v6" ;;
  esac
  # ufw / firewalld：DNAT 后 dport 是主端口，放行 hop 范围本身没用，
  # 但用户阅读规则列表时能看到该范围被显式标记，且不会与节点主端口规则冲突。
  # 主端口本身由 node_apply_firewall_for_mode 在 install/modify 时放行。
  case "$(detect_firewall_backend)" in
    ufw)
      ufw allow "${start}:${end}/udp" >/dev/null 2>&1 || true
      ;;
    firewalld)
      firewall-cmd --permanent --add-port="${start}-${end}/udp" >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
      ;;
  esac
  ip4_save_rules >/dev/null 2>&1 || true
  ip6_save_rules >/dev/null 2>&1 || true
}

port_hop_remove(){
  local start="$1" end="$2" mode="$3"
  case "$mode" in
    ipv4|dualstack)              port_hop_remove_v4 "$start" "$end" ;;
  esac
  case "$mode" in
    dualstack|ipv6-in-ipv4-out)  port_hop_remove_v6 "$start" "$end" ;;
  esac
  case "$(detect_firewall_backend)" in
    ufw)
      ufw delete allow "${start}:${end}/udp" >/dev/null 2>&1 || true
      ;;
    firewalld)
      firewall-cmd --permanent --remove-port="${start}-${end}/udp" >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
      ;;
  esac
  ip4_save_rules >/dev/null 2>&1 || true
  ip6_save_rules >/dev/null 2>&1 || true
}

port_hop_cleanup_all(){
  iptables -t nat -F "$PORT_HOP_NAT_CHAIN" 2>/dev/null || true
  iptables -t nat -D PREROUTING -j "$PORT_HOP_NAT_CHAIN" 2>/dev/null || true
  iptables -t nat -X "$PORT_HOP_NAT_CHAIN" 2>/dev/null || true
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t nat -F "$PORT_HOP_NAT_CHAIN" 2>/dev/null || true
    ip6tables -t nat -D PREROUTING -j "$PORT_HOP_NAT_CHAIN" 2>/dev/null || true
    ip6tables -t nat -X "$PORT_HOP_NAT_CHAIN" 2>/dev/null || true
  fi
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
