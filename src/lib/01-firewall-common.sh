check_port_in_use(){
  local port="$1"

  if [ -z "$port" ]; then
    return 1
  fi

  if command -v ss >/dev/null 2>&1; then
    ss -tlnH 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit !found}'
    return $?
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit !found}'
    return $?
  fi

  return 1
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
      if ufw allow "${port}/${proto}" >/dev/null 2>&1; then
        echo -e "  防火墙  : ${C}ufw 已放行 ${port}/${proto}${N}"
      else
        echo -e "  防火墙  : ${Y}ufw 放行失败，请手动执行 ufw allow ${port}/${proto}${N}"
      fi
      ;;
    firewalld)
      if firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 \
         && firewall-cmd --reload >/dev/null 2>&1; then
        echo -e "  防火墙  : ${C}firewalld 已放行 ${port}/${proto}${N}"
      else
        echo -e "  防火墙  : ${Y}firewalld 放行失败，请手动执行 firewall-cmd --permanent --add-port=${port}/${proto}${N}"
      fi
      ;;
    *)
      echo -e "  防火墙  : ${D}未启用 ufw/firewalld（如有外部安全组请自行放行 ${port}/${proto}）${N}"
      ;;
  esac
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
      ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true
      echo -e "  防火墙  : ${D}ufw 撤销 ${port}/${proto}${N}"
      ;;
    firewalld)
      firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
      echo -e "  防火墙  : ${D}firewalld 撤销 ${port}/${proto}${N}"
      ;;
    *)
      :
      ;;
  esac
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
  local need_v4=0 need_v6=0

  case "$mode" in
    ipv4)              need_v4=1 ;;
    dualstack)         need_v4=1; need_v6=1 ;;
    ipv6-in-ipv4-out)  need_v6=1 ;;
    *)                 need_v4=1 ;;
  esac

  # ufw / firewalld 是双栈，只要任一侧需要就调一次
  if [ "$need_v4" = "1" ] || [ "$need_v6" = "1" ]; then
    allow_port_in_firewall "$port" "$proto"
  fi

  # 脚本自管的 iptables 防火墙（默认策略 DROP 时 INPUT 是白名单制）
  if [ "$need_v4" = "1" ] && command -v iptables >/dev/null 2>&1; then
    local v4_pol
    v4_pol=$(ip4_get_input_policy 2>/dev/null || true)
    if [ "$v4_pol" = "DROP" ]; then
      if iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
        echo -e "  v4 防火墙: ${D}${port}/${proto} 已在放行列表${N}"
      else
        iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
          && echo -e "  v4 防火墙: ${C}iptables 已放行 ${port}/${proto}${N}" \
          || echo -e "  v4 防火墙: ${Y}iptables 放行失败，请手动检查${N}"
        ip4_save_rules >/dev/null 2>&1 || true
      fi
    fi
  fi

  if [ "$need_v6" = "1" ] && command -v ip6tables >/dev/null 2>&1; then
    local v6_pol
    v6_pol=$(ip6_get_input_policy 2>/dev/null || true)
    if [ "$v6_pol" = "DROP" ]; then
      if ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
        echo -e "  v6 防火墙: ${D}${port}/${proto} 已在放行列表${N}"
      else
        ip6tables -A INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
          && echo -e "  v6 防火墙: ${C}ip6tables 已放行 ${port}/${proto}${N}" \
          || echo -e "  v6 防火墙: ${Y}ip6tables 放行失败，请手动检查${N}"
        ip6_save_rules >/dev/null 2>&1 || true
      fi
    fi
  fi
}

# 节点入站统一撤销端口（uninstall / 改端口时配套使用）
# 用法：node_revoke_firewall_for_mode <port> <proto> <mode>
node_revoke_firewall_for_mode(){
  local port="$1"
  local proto="${2:-tcp}"
  local mode="${3:-ipv4}"
  local need_v4=0 need_v6=0

  case "$mode" in
    ipv4)              need_v4=1 ;;
    dualstack)         need_v4=1; need_v6=1 ;;
    ipv6-in-ipv4-out)  need_v6=1 ;;
    *)                 need_v4=1 ;;
  esac

  if [ "$need_v4" = "1" ] || [ "$need_v6" = "1" ]; then
    deny_port_in_firewall "$port" "$proto"
  fi

  if [ "$need_v4" = "1" ] && command -v iptables >/dev/null 2>&1; then
    local v4_removed=0
    while iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; do
      iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || break
      v4_removed=1
    done
    if [ "$v4_removed" = "1" ]; then
      echo -e "  v4 防火墙: ${D}iptables 撤销 ${port}/${proto}${N}"
      ip4_save_rules >/dev/null 2>&1 || true
    fi
  fi

  if [ "$need_v6" = "1" ] && command -v ip6tables >/dev/null 2>&1; then
    local v6_removed=0
    while ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; do
      ip6tables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || break
      v6_removed=1
    done
    if [ "$v6_removed" = "1" ]; then
      echo -e "  v6 防火墙: ${D}ip6tables 撤销 ${port}/${proto}${N}"
      ip6_save_rules >/dev/null 2>&1 || true
    fi
  fi
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
    echo -e "    ${L}·${N} IPv6 防火墙菜单 : 主菜单 ${C}6) IPv6 防火墙管理 → 4) 开放端口${N}"
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

  if ! is_debian_family; then
    target="$IP6_RULES_PATH_RHEL"
  fi

  mkdir -p "$(dirname "$target")"
  if ! ip6tables-save > "$target"; then
    return 1
  fi
  return 0
}

# ─── IPv4 防火墙底层 helpers ──────────────────────────
ip4_save_rules(){
  local target="$IP4_RULES_PATH_DEBIAN"

  if ! is_debian_family; then
    target="$IP4_RULES_PATH_RHEL"
  fi

  mkdir -p "$(dirname "$target")"
  if ! iptables-save > "$target"; then
    return 1
  fi
  return 0
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

# 把 IPv4 防火墙交还 1Panel：清掉 INPUT 规则 + 默认策略 ACCEPT，并持久化
ip4_handover_to_1panel(){
  iptables -P INPUT ACCEPT 2>/dev/null || return 1
  iptables -F INPUT 2>/dev/null || return 1
  ip4_save_rules >/dev/null 2>&1 || true
  return 0
}

# ─── 防火墙锁库兜底机制 ──────────────────────────────
# 验证 sshd 真的在指定端口监听（不依赖 sshd 进程名 grep，更稳）
verify_sshd_listening_on_port(){
  local port="$1"
  if [ -z "$port" ]; then return 1; fi
  if ! command -v ss >/dev/null 2>&1; then
    return 0  # 无 ss 工具时不阻塞调用方
  fi
  ss -tlnp 2>/dev/null \
    | awk -v p=":${port}$" '$4 ~ p && $0 ~ /sshd/ {found=1} END {exit !found}'
}

# 安排一个延时回滚守护：seconds 秒后自动恢复 iptables/ip6tables 备份
# 用法：rb_pid=$(schedule_iptables_rollback 180 /tmp/v4.bak /tmp/v6.bak)
# 取消：cancel_rollback_pid "$rb_pid"
schedule_iptables_rollback(){
  local seconds="${1:-180}"
  local backup_v4="${2:-}"
  local backup_v6="${3:-}"
  local cmd=""

  if [ -n "$backup_v4" ] && [ -s "$backup_v4" ]; then
    cmd="iptables-restore < '$backup_v4' 2>/dev/null; "
  fi
  if [ -n "$backup_v6" ] && [ -s "$backup_v6" ]; then
    cmd="${cmd}ip6tables-restore < '$backup_v6' 2>/dev/null; "
  fi
  if [ -z "$cmd" ]; then
    return 1
  fi

  # 用 setsid 让守护脱离会话，避免 SSH 断开被 SIGHUP 杀掉
  setsid bash -c "sleep $seconds; $cmd rm -f '$backup_v4' '$backup_v6' 2>/dev/null" \
    </dev/null >/dev/null 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  printf '%s' "$pid"
}

cancel_rollback_pid(){
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
}

