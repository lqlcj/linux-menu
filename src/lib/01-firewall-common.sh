check_port_in_use(){
  local port="$1"
  local proto="${2:-tcp}"
  local ss_args="-tlnH"
  local netstat_args="-tln"

  if [ -z "$port" ]; then
    return 1
  fi

  case "$proto" in
    udp) ss_args="-ulnH"; netstat_args="-uln" ;;
    tcp) ;;
    *) return 1 ;;
  esac

  if command -v ss >/dev/null 2>&1; then
    ss $ss_args 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit !found}'
    return $?
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat $netstat_args 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit !found}'
    return $?
  fi

  return 1
}

firewall_owned_port_key(){
  printf '%s\t%s\t%s' "$1" "$2" "$3"
}

firewall_owned_port_has(){
  local backend="$1" port="$2" proto="$3" key
  [ -r "$FIREWALL_PORT_STATE" ] || return 1
  key=$(firewall_owned_port_key "$backend" "$port" "$proto")
  grep -Fqx "$key" "$FIREWALL_PORT_STATE"
}

firewall_owned_port_add(){
  local backend="$1" port="$2" proto="$3" key tmp
  ensure_leyili_state_dir || return 1
  key=$(firewall_owned_port_key "$backend" "$port" "$proto")
  tmp=$(mktemp "${FIREWALL_PORT_STATE}.tmp.XXXXXX") || return 1
  if [ -f "$FIREWALL_PORT_STATE" ]; then
    cat "$FIREWALL_PORT_STATE" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  grep -Fqx "$key" "$tmp" 2>/dev/null || printf '%s\n' "$key" >> "$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$FIREWALL_PORT_STATE"
}

firewall_owned_port_remove(){
  local backend="$1" port="$2" proto="$3" tmp
  [ -f "$FIREWALL_PORT_STATE" ] || return 0
  tmp=$(mktemp "${FIREWALL_PORT_STATE}.tmp.XXXXXX") || return 1
  if ! awk -F '\t' -v b="$backend" -v p="$port" -v r="$proto" \
      '!(NF >= 3 && $1 == b && $2 == p && $3 == r)' \
      "$FIREWALL_PORT_STATE" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$FIREWALL_PORT_STATE"
}

firewall_backend_port_exists(){
  local backend="$1" port="$2" proto="$3"
  case "$backend" in
    ufw)
      command -v ufw >/dev/null 2>&1 || return 1
      ufw status 2>/dev/null | awk -v rule="${port}/${proto}" \
        '$1 == rule && $2 == "ALLOW" { found=1 } END { exit !found }'
      ;;
    firewalld)
      command -v firewall-cmd >/dev/null 2>&1 || return 1
      firewall-cmd --permanent --query-port="${port}/${proto}" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

firewall_backend_add_port_raw(){
  local backend="$1" port="$2" proto="$3"
  case "$backend" in
    ufw)
      firewall_backend_port_exists ufw "$port" "$proto" && return 0
      ufw allow "${port}/${proto}" >/dev/null 2>&1
      ;;
    firewalld)
      firewall_backend_port_exists firewalld "$port" "$proto" && return 0
      firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 \
        && firewall-cmd --reload >/dev/null 2>&1
      ;;
    none) return 0 ;;
    *) return 1 ;;
  esac
}

firewall_backend_remove_port_raw(){
  local backend="$1" port="$2" proto="$3"
  case "$backend" in
    ufw)
      firewall_backend_port_exists ufw "$port" "$proto" || return 0
      ufw delete allow "${port}/${proto}" >/dev/null 2>&1
      ;;
    firewalld)
      firewall_backend_port_exists firewalld "$port" "$proto" || return 0
      firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 \
        && firewall-cmd --reload >/dev/null 2>&1
      ;;
    none) return 0 ;;
    *) return 1 ;;
  esac
}

firewall_owned_ports_restore(){
  local desired="$1" existed_marker="$2"
  local current backend port proto rc=0

  current=$(mktemp "${TMPDIR:-/tmp}/leyili-fw-owned.XXXXXX") || return 1
  if [ -f "$FIREWALL_PORT_STATE" ]; then
    cp -a -- "$FIREWALL_PORT_STATE" "$current" || { rm -f -- "$current"; return 1; }
  else
    : > "$current"
  fi

  while IFS=$'\t' read -r backend port proto; do
    [ -n "$backend" ] && [ -n "$port" ] && [ -n "$proto" ] || continue
    if ! grep -Fqx "$(firewall_owned_port_key "$backend" "$port" "$proto")" "$desired" 2>/dev/null; then
      firewall_backend_remove_port_raw "$backend" "$port" "$proto" || rc=1
    fi
  done < "$current"
  while IFS=$'\t' read -r backend port proto; do
    [ -n "$backend" ] && [ -n "$port" ] && [ -n "$proto" ] || continue
    if ! grep -Fqx "$(firewall_owned_port_key "$backend" "$port" "$proto")" "$current" 2>/dev/null; then
      firewall_backend_add_port_raw "$backend" "$port" "$proto" || rc=1
    fi
  done < "$desired"

  if [ -f "$existed_marker" ]; then
    ensure_leyili_state_dir || rc=1
    if [ "$rc" -eq 0 ]; then
      restore_file_snapshot "$desired" "$FIREWALL_PORT_STATE" || rc=1
      chmod 600 "$FIREWALL_PORT_STATE" 2>/dev/null || rc=1
    fi
  else
    rm -f -- "$FIREWALL_PORT_STATE" || rc=1
  fi
  rm -f -- "$current"
  return "$rc"
}

firewall_remove_all_owned_ports(){
  local backend port proto rc=0
  [ -f "$FIREWALL_PORT_STATE" ] || return 0
  while IFS=$'\t' read -r backend port proto; do
    [ -n "$backend" ] && [ -n "$port" ] && [ -n "$proto" ] || continue
    firewall_backend_remove_port_raw "$backend" "$port" "$proto" || rc=1
  done < "$FIREWALL_PORT_STATE"
  if [ "$rc" -eq 0 ]; then
    rm -f -- "$FIREWALL_PORT_STATE" || rc=1
  fi
  return "$rc"
}

detect_firewall_backend(){
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "^Status: active"; then
    printf '%s' "ufw"
    return
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    printf '%s' "firewalld"
    return
  fi

  printf '%s' "none"
}

allow_port_in_firewall(){
  local port="$1"
  local proto="${2:-tcp}"
  local backend
  backend=$(detect_firewall_backend)

  case "$backend" in
    ufw)
      if firewall_backend_port_exists ufw "$port" "$proto"; then
        echo -e "  防火墙  : ${D}ufw 已有 ${port}/${proto} 规则，保持不变${N}"
      elif firewall_backend_add_port_raw ufw "$port" "$proto" \
           && firewall_owned_port_add ufw "$port" "$proto"; then
        echo -e "  防火墙  : ${C}ufw 已放行 ${port}/${proto}（脚本托管）${N}"
      else
        if ! firewall_backend_remove_port_raw ufw "$port" "$proto" >/dev/null 2>&1; then
          echo -e "  防火墙  : ${R}ufw 所有权记录失败，且新增规则撤销失败，请立即检查 ${port}/${proto}${N}"
        fi
        echo -e "  防火墙  : ${Y}ufw 放行失败，请手动执行 ufw allow ${port}/${proto}${N}"
        return 1
      fi
      ;;
    firewalld)
      if firewall_backend_port_exists firewalld "$port" "$proto"; then
        echo -e "  防火墙  : ${D}firewalld 已有 ${port}/${proto} 规则，保持不变${N}"
      elif firewall_backend_add_port_raw firewalld "$port" "$proto" \
           && firewall_owned_port_add firewalld "$port" "$proto"; then
        echo -e "  防火墙  : ${C}firewalld 已放行 ${port}/${proto}（脚本托管）${N}"
      else
        if ! firewall_backend_remove_port_raw firewalld "$port" "$proto" >/dev/null 2>&1; then
          echo -e "  防火墙  : ${R}firewalld 所有权记录失败，且新增规则撤销失败，请立即检查 ${port}/${proto}${N}"
        fi
        echo -e "  防火墙  : ${Y}firewalld 放行失败，请手动执行 firewall-cmd --permanent --add-port=${port}/${proto}${N}"
        return 1
      fi
      ;;
    *)
      echo -e "  防火墙  : ${D}未启用 ufw/firewalld（如有外部安全组请自行放行 ${port}/${proto}）${N}"
      ;;
  esac
  return 0
}

allow_tcp_port_in_firewall(){
  allow_port_in_firewall "$1" tcp
}

deny_port_in_firewall(){
  local port="$1"
  local proto="${2:-tcp}"
  local backend
  backend=$(detect_firewall_backend)

  case "$backend" in
    ufw)
      if firewall_owned_port_has ufw "$port" "$proto"; then
        if ! firewall_backend_remove_port_raw ufw "$port" "$proto"; then
          return 1
        fi
        if ! firewall_owned_port_remove ufw "$port" "$proto"; then
          if ! firewall_backend_add_port_raw ufw "$port" "$proto" >/dev/null 2>&1; then
            echo -e "${R}ufw 所有权记录更新失败，且旧规则恢复失败：${port}/${proto}${N}" >&2
          fi
          return 1
        fi
        echo -e "  防火墙  : ${D}ufw 已撤销脚本托管的 ${port}/${proto}${N}"
      else
        echo -e "  防火墙  : ${D}ufw 的 ${port}/${proto} 非脚本托管，已保留${N}"
      fi
      ;;
    firewalld)
      if firewall_owned_port_has firewalld "$port" "$proto"; then
        if ! firewall_backend_remove_port_raw firewalld "$port" "$proto"; then
          return 1
        fi
        if ! firewall_owned_port_remove firewalld "$port" "$proto"; then
          if ! firewall_backend_add_port_raw firewalld "$port" "$proto" >/dev/null 2>&1; then
            echo -e "${R}firewalld 所有权记录更新失败，且旧规则恢复失败：${port}/${proto}${N}" >&2
          fi
          return 1
        fi
        echo -e "  防火墙  : ${D}firewalld 已撤销脚本托管的 ${port}/${proto}${N}"
      else
        echo -e "  防火墙  : ${D}firewalld 的 ${port}/${proto} 非脚本托管，已保留${N}"
      fi
      ;;
    *)
      :
      ;;
  esac
  return 0
}

firewall_managed_chain_exists(){
  local family="$1"
  local cmd chain
  case "$family" in
    4) cmd="iptables"; chain="$IP4_LEYILI_CHAIN" ;;
    6) cmd="ip6tables"; chain="$IP6_LEYILI_CHAIN" ;;
    *) return 1 ;;
  esac
  command -v "$cmd" >/dev/null 2>&1 || return 1
  "$cmd" -nL "$chain" >/dev/null 2>&1
}

firewall_ensure_managed_chain(){
  local family="$1"
  local cmd chain
  case "$family" in
    4) cmd="iptables"; chain="$IP4_LEYILI_CHAIN" ;;
    6) cmd="ip6tables"; chain="$IP6_LEYILI_CHAIN" ;;
    *) return 1 ;;
  esac
  command -v "$cmd" >/dev/null 2>&1 || return 1
  "$cmd" -nL "$chain" >/dev/null 2>&1 || "$cmd" -N "$chain" || return 1
  # 放在 INPUT 末尾：先让 fail2ban / 用户已有规则执行，避免脚本 ACCEPT 绕过封禁链。
  "$cmd" -C INPUT -j "$chain" >/dev/null 2>&1 || "$cmd" -A INPUT -j "$chain" || return 1
}

firewall_add_managed_port(){
  local family="$1" proto="$2" port="$3"
  local cmd chain
  case "$family" in
    4) cmd="iptables"; chain="$IP4_LEYILI_CHAIN" ;;
    6) cmd="ip6tables"; chain="$IP6_LEYILI_CHAIN" ;;
    *) return 1 ;;
  esac
  firewall_ensure_managed_chain "$family" || return 1
  "$cmd" -C "$chain" -p "$proto" --dport "$port" -m comment --comment "leyili-managed" -j ACCEPT >/dev/null 2>&1 \
    || "$cmd" -A "$chain" -p "$proto" --dport "$port" -m comment --comment "leyili-managed" -j ACCEPT
}

firewall_remove_managed_port(){
  local family="$1" proto="$2" port="$3"
  local cmd chain removed=0
  case "$family" in
    4) cmd="iptables"; chain="$IP4_LEYILI_CHAIN" ;;
    6) cmd="ip6tables"; chain="$IP6_LEYILI_CHAIN" ;;
    *) return 1 ;;
  esac
  firewall_managed_chain_exists "$family" || return 0
  while "$cmd" -C "$chain" -p "$proto" --dport "$port" -m comment --comment "leyili-managed" -j ACCEPT >/dev/null 2>&1; do
    if ! "$cmd" -D "$chain" -p "$proto" --dport "$port" -m comment --comment "leyili-managed" -j ACCEPT; then
      return 1
    fi
    removed=1
  done
  [ "$removed" -eq 0 ] || return 0
}

firewall_remove_managed_chain(){
  local family="$1"
  local cmd chain
  case "$family" in
    4) cmd="iptables"; chain="$IP4_LEYILI_CHAIN" ;;
    6) cmd="ip6tables"; chain="$IP6_LEYILI_CHAIN" ;;
    *) return 1 ;;
  esac
  command -v "$cmd" >/dev/null 2>&1 || return 0
  while "$cmd" -C INPUT -j "$chain" >/dev/null 2>&1; do
    "$cmd" -D INPUT -j "$chain" || return 1
  done
  if "$cmd" -nL "$chain" >/dev/null 2>&1; then
    "$cmd" -F "$chain" || return 1
    "$cmd" -X "$chain" || return 1
  fi
}

# 节点入站统一开放端口：
# - ufw / firewalld 走 allow_port_in_firewall（双栈，一条命令同时开 v4+v6）
# - 若 v4 / v6 INPUT 默认策略 = DROP（脚本本身的 iptables / ip6tables 防火墙菜单初始化过），
#   主动追加该协议主端口的 ACCEPT 规则并持久化
# 用法：node_apply_firewall_for_mode <port> <proto:tcp|udp> <mode:ipv4|dualstack|ipv6-in-ipv4-out>
node_apply_firewall_for_mode(){
  local port="$1"
  local proto="${2:-tcp}"
  local mode="${3:-ipv4}"
  local need_v4=0 need_v6=0 backend txn

  case "$mode" in
    ipv4)              need_v4=1 ;;
    dualstack)         need_v4=1; need_v6=1 ;;
    ipv6-in-ipv4-out)  need_v6=1 ;;
    *)                 need_v4=1 ;;
  esac

  backend=$(detect_firewall_backend)
  # ufw / firewalld 是双栈，只要任一侧需要就调一次。
  if [ "$need_v4" = "1" ] || [ "$need_v6" = "1" ]; then
    allow_port_in_firewall "$port" "$proto" || return 1
  fi

  # ufw/firewalld 活跃时不再额外插裸 iptables ACCEPT，避免绕过其封禁语义。
  if [ "$backend" != "none" ]; then
    return 0
  fi

  if [ "$need_v4" = "1" ] && command -v iptables >/dev/null 2>&1 \
     && { [ "$(ip4_get_input_policy 2>/dev/null)" = "DROP" ] || firewall_managed_chain_exists 4; }; then
    txn=$(firewall_transaction_begin 4) || return 1
    if firewall_add_managed_port 4 "$proto" "$port" && ip4_save_rules; then
      firewall_transaction_commit "$txn"
      echo -e "  v4 防火墙: ${C}已放行 ${port}/${proto}${N}"
    else
      firewall_transaction_rollback 4 "$txn"
      echo -e "  v4 防火墙: ${R}放行失败，已恢复原规则${N}"
      return 1
    fi
  fi

  if [ "$need_v6" = "1" ] && command -v ip6tables >/dev/null 2>&1 \
     && { [ "$(ip6_get_input_policy 2>/dev/null)" = "DROP" ] || firewall_managed_chain_exists 6; }; then
    txn=$(firewall_transaction_begin 6) || return 1
    if firewall_add_managed_port 6 "$proto" "$port" && ip6_save_rules; then
      firewall_transaction_commit "$txn"
      echo -e "  v6 防火墙: ${C}已放行 ${port}/${proto}${N}"
    else
      firewall_transaction_rollback 6 "$txn"
      echo -e "  v6 防火墙: ${R}放行失败，已恢复原规则${N}"
      return 1
    fi
  fi
  return 0
}

# 节点入站统一撤销端口（uninstall / 改端口时配套使用）
# 用法：node_revoke_firewall_for_mode <port> <proto> <mode>
node_revoke_firewall_for_mode(){
  local port="$1"
  local proto="${2:-tcp}"
  local mode="${3:-ipv4}"
  local need_v4=0 need_v6=0 backend txn

  case "$mode" in
    ipv4)              need_v4=1 ;;
    dualstack)         need_v4=1; need_v6=1 ;;
    ipv6-in-ipv4-out)  need_v6=1 ;;
    *)                 need_v4=1 ;;
  esac

  backend=$(detect_firewall_backend)
  if [ "$need_v4" = "1" ] || [ "$need_v6" = "1" ]; then
    deny_port_in_firewall "$port" "$proto" || return 1
  fi

  [ "$backend" != "none" ] && return 0

  if [ "$need_v4" = "1" ] && firewall_managed_chain_exists 4; then
    txn=$(firewall_transaction_begin 4) || return 1
    if firewall_remove_managed_port 4 "$proto" "$port" && ip4_save_rules; then
      firewall_transaction_commit "$txn"
      echo -e "  v4 防火墙: ${D}已撤销 ${port}/${proto}${N}"
    else
      firewall_transaction_rollback 4 "$txn"
      return 1
    fi
  fi

  if [ "$need_v6" = "1" ] && firewall_managed_chain_exists 6; then
    txn=$(firewall_transaction_begin 6) || return 1
    if firewall_remove_managed_port 6 "$proto" "$port" && ip6_save_rules; then
      firewall_transaction_commit "$txn"
      echo -e "  v6 防火墙: ${D}已撤销 ${port}/${proto}${N}"
    else
      firewall_transaction_rollback 6 "$txn"
      return 1
    fi
  fi
  return 0
}

# 给用户打印"请自行放行端口"的提示，覆盖 IPv4(ufw/firewalld)、IPv6(本脚本菜单)、云安全组
print_firewall_hint(){
  local port="$1"
  local proto="${2:-tcp}"
  local label="${3:-}"
  local backend
  backend=$(detect_firewall_backend)

  echo ""
  echo -e "  ${Y}${B}请自行放行入站端口：${C}${port}/${proto}${N}${label:+  ${D}(${label})${N}}"
  case "$backend" in
    ufw)
      echo -e "    ${L}·${N} ufw    : ${C}ufw allow ${port}/${proto}${N}"
      ;;
    firewalld)
      echo -e "    ${L}·${N} firewalld : ${C}firewall-cmd --permanent --add-port=${port}/${proto} && firewall-cmd --reload${N}"
      ;;
    *)
      echo -e "    ${L}·${N} 本机未启用 ufw/firewalld（如启用过 IPv6 防火墙菜单，请走下条）"
      ;;
  esac
  if command -v ip6tables >/dev/null 2>&1; then
    echo -e "    ${L}·${N} IPv6 防火墙菜单 : 主菜单 ${C}5) 防火墙管理 → 2) IPv6 防火墙管理 → 4) 开放端口${N}"
  fi
  echo -e "    ${L}·${N} 云厂商安全组    : ${D}阿里云 / 腾讯云 / AWS / Vultr 等控制台需自行加 ${port}/${proto} 入站规则${N}"
  echo ""
}

ip6_get_input_policy(){
  ip6tables -L INPUT -n 2>/dev/null | head -n1 | awk '{gsub(/\)/, "", $4); print $4}'
}

ip6_list_opened_ports_compact(){
  ip6tables-save 2>/dev/null | awk '
    /^-A INPUT/ {
      proto=""; port=""
      for (i = 1; i <= NF; i++) {
        if ($i == "-p")      proto = $(i + 1)
        if ($i == "--dport") port  = $(i + 1)
      }
      if (port == "") next
      if (proto == "tcp") {
        if (!(port in tcp_seen)) { tcp_list = tcp_list (tcp_list ? ", " : "") port; tcp_seen[port]=1 }
      } else if (proto == "udp") {
        if (!(port in udp_seen)) { udp_list = udp_list (udp_list ? ", " : "") port; udp_seen[port]=1 }
      }
    }
    END {
      out = ""
      if (tcp_list != "") out = "TCP " tcp_list
      if (udp_list != "") out = out (out ? "  " : "") "UDP " udp_list
      print out
    }'
}

ip6_detect_ssh_port(){
  local port=""

  if command -v ss >/dev/null 2>&1; then
    port=$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' \
           | awk -F: '{print $NF}' | sort -u | head -n1)
  fi

  if [ -z "$port" ]; then
    port=$(get_current_ssh_port)
  fi

  printf '%s' "${port:-22}"
}

ip6_check_current_ssh_v6(){
  local ip=""

  if [ -n "${SSH_CLIENT:-}" ]; then
    ip=$(printf '%s' "$SSH_CLIENT" | awk '{print $1}')
    case "$ip" in
      *:*)
        return 0
        ;;
    esac
  fi
  return 1
}

ip6_ensure_persistence(){
  if is_debian_family; then
    if dpkg -s iptables-persistent >/dev/null 2>&1; then
      return 0
    fi

    echo -e "${Y}==> 安装 iptables-persistent（重启后自动加载规则）...${N}"
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" \
        | debconf-set-selections 2>/dev/null
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" \
        | debconf-set-selections 2>/dev/null
    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
      return 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null; then
      return 1
    fi
    return 0
  fi

  echo -e "${Y}非 Debian 系发行版，跳过持久化工具自动安装${N}"
  return 0
}

# 确保 iptables/ip6tables 命令可用（minimal cloud 镜像常缺）
# 返回 0=已就绪或安装成功，1=失败
ensure_iptables_installed(){
  local need_install=0

  if ! command -v iptables >/dev/null 2>&1 || ! command -v ip6tables >/dev/null 2>&1; then
    need_install=1
  fi

  if [ "$need_install" = "0" ]; then
    return 0
  fi

  if ! is_debian_family; then
    echo -e "${R}非 Debian 系发行版，请手动安装 iptables 后重试${N}"
    return 1
  fi

  echo ""
  echo -e "${Y}==> 检测到 iptables/ip6tables 未安装，使用官方源 (apt) 安装...${N}"
  if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
    echo -e "${R}apt-get update 失败${N}"
    return 1
  fi
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y iptables >/dev/null; then
    echo -e "${R}apt-get install iptables 失败${N}"
    return 1
  fi

  if ! command -v iptables >/dev/null 2>&1 || ! command -v ip6tables >/dev/null 2>&1; then
    echo -e "${R}安装后仍找不到 iptables/ip6tables，请手动检查${N}"
    return 1
  fi

  echo -e "${G}iptables / ip6tables 安装完成${N}"
  return 0
}

ip6_save_rules(){
  local target="$IP6_RULES_PATH_DEBIAN"
  local tmp

  if ! is_debian_family; then
    target="$IP6_RULES_PATH_RHEL"
  fi

  mkdir -p "$(dirname "$target")" || return 1
  tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
  if ! ip6tables-save > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$target"
}

# ─── IPv4 防火墙底层 helpers ──────────────────────────
ip4_save_rules(){
  local target="$IP4_RULES_PATH_DEBIAN"
  local tmp

  if ! is_debian_family; then
    target="$IP4_RULES_PATH_RHEL"
  fi

  mkdir -p "$(dirname "$target")" || return 1
  tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
  if ! iptables-save > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$target"
}

firewall_transaction_begin(){
  local family="$1"
  local txn save_cmd target

  case "$family" in
    4)
      save_cmd="iptables-save"
      target="$IP4_RULES_PATH_DEBIAN"
      is_debian_family || target="$IP4_RULES_PATH_RHEL"
      ;;
    6)
      save_cmd="ip6tables-save"
      target="$IP6_RULES_PATH_DEBIAN"
      is_debian_family || target="$IP6_RULES_PATH_RHEL"
      ;;
    *) return 1 ;;
  esac
  command -v "$save_cmd" >/dev/null 2>&1 || return 1
  txn=$(mktemp -d "${TMPDIR:-/tmp}/leyili-fw${family}.XXXXXX") || return 1
  chmod 700 "$txn" 2>/dev/null || { rm -rf -- "$txn"; return 1; }
  if ! "$save_cmd" > "$txn/active.rules"; then
    rm -rf -- "$txn"
    return 1
  fi
  printf '%s\n' "$target" > "$txn/persistent.path"
  if [ -f "$target" ]; then
    cp -a -- "$target" "$txn/persistent.rules" || { rm -rf -- "$txn"; return 1; }
    : > "$txn/persistent.existed"
  fi
  printf '%s' "$txn"
}

firewall_transaction_rollback(){
  local family="$1" txn="$2"
  local restore_cmd target rc=0

  [ -d "$txn" ] || return 1
  case "$family" in
    4) restore_cmd="iptables-restore" ;;
    6) restore_cmd="ip6tables-restore" ;;
    *) return 1 ;;
  esac
  "$restore_cmd" < "$txn/active.rules" 2>/dev/null || rc=1
  target=$(cat "$txn/persistent.path" 2>/dev/null)
  if [ -n "$target" ]; then
    if [ -f "$txn/persistent.existed" ]; then
      restore_file_snapshot "$txn/persistent.rules" "$target" || rc=1
    else
      rm -f -- "$target" || rc=1
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    rm -rf -- "$txn" || rc=1
  fi
  [ "$rc" -eq 0 ] || echo -e "${R}警告：IPv${family} 防火墙回滚未完全成功，请立即检查规则；快照保留在 ${txn}${N}" >&2
  return "$rc"
}

firewall_transaction_commit(){
  rm -rf -- "$1"
}

ip4_get_input_policy(){
  iptables -L INPUT -n 2>/dev/null | head -n1 | awk '{gsub(/\)/, "", $4); print $4}'
}

ip4_check_current_ssh_v4(){
  local ip=""
  if [ -n "${SSH_CLIENT:-}" ]; then
    ip=$(printf '%s' "$SSH_CLIENT" | awk '{print $1}')
    case "$ip" in
      *:*) return 1 ;;
      *)   [ -n "$ip" ] && return 0 ;;
    esac
  fi
  return 1
}

# 检查可能与 iptables 直接编辑冲突的管理工具
ip4_detect_conflicts(){
  local conflicts=""

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "^Status: active"; then
    conflicts="${conflicts}ufw "
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    conflicts="${conflicts}firewalld "
  fi
  if [ -d /opt/1panel ] || systemctl list-unit-files 2>/dev/null | grep -q '^1panel'; then
    conflicts="${conflicts}1Panel "
  fi

  printf '%s' "${conflicts% }"
}

# 单独检测 1Panel 是否在场（用于 IPv4 菜单托管接管）
ip4_detect_1panel(){
  [ -d /opt/1panel ] && return 0
  systemctl list-unit-files 2>/dev/null | grep -q '^1panel' && return 0
  return 1
}

# 把 IPv4 防火墙交还 1Panel：只清脚本专属链，保留用户/fail2ban 规则。
ip4_handover_to_1panel(){
  local txn
  txn=$(firewall_transaction_begin 4) || return 1
  if iptables -P INPUT ACCEPT \
     && firewall_remove_managed_chain 4 \
     && ip4_save_rules; then
    firewall_transaction_commit "$txn"
    return 0
  fi
  firewall_transaction_rollback 4 "$txn"
  return 1
}

# ─── 防火墙锁库校验 ──────────────────────────────────
# 验证指定 SSH 端口确实在监听；兼容 ssh.socket 下监听进程显示为 systemd。
verify_sshd_listening_on_port(){
  local port="$1"
  if [ -z "$port" ]; then return 1; fi
  # 无 ss 工具时无法验证 → 视为未通过，让调用方触发回滚保护
  # （ss 在 Debian/Ubuntu 默认 iproute2 内，缺失极罕见）
  command -v ss >/dev/null 2>&1 || return 1
  ss -tlnH 2>/dev/null \
    | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit !found}'
}
