#!/bin/bash
set -o pipefail

SAGERNET_KEY_URL="https://sing-box.app/gpg.key"
SAGERNET_KEYRING="/etc/apt/keyrings/sagernet.asc"
SAGERNET_SOURCES="/etc/apt/sources.list.d/sagernet.sources"
SAGERNET_REPO_URI="https://deb.sagernet.org/"
CONFIG_PATH="/etc/sing-box/config.json"
INFO_PATH="/root/proxy-info.txt"
NODES_DIR="/etc/sing-box/nodes"
CERTS_DIR="/etc/sing-box/certs"
CHAINS_DIR="/etc/sing-box/chains"
APP_NAME="Leyili"
COMMAND_NAME="sb"
SCRIPT_PATH="/usr/local/bin/${COMMAND_NAME}"
SELF_INSTALL_URL="${SELF_INSTALL_URL:-https://raw.githubusercontent.com/lqlcj/linux-menu/main/leyili.sh}"
TCP_TUNING_PATH="/etc/sysctl.d/99-proxy-optimized.conf"
INITCWND_SERVICE_PATH="/etc/systemd/system/initcwnd.service"
INITCWND_VALUE="24"
SWAPFILE_PATH="/swapfile"
SWAP_SIZE="2G"
SWAP_SIZE_MB="2048"
SWAP_SYSCTL_PATH="/etc/sysctl.d/99-swap-tuning.conf"
SWAPPINESS_VALUE="10"
SYSTEM_TIMEZONE="Asia/Shanghai"
BASIC_TOOLS_PACKAGES="curl wget git vim htop unzip net-tools"
SSHD_CONFIG_PATH="/etc/ssh/sshd_config"
SUDOERS_DROPIN_DIR="/etc/sudoers.d"
SSH_RANDOM_PORT_MIN="20000"
SSH_RANDOM_PORT_MAX="65535"
IP6_RULES_PATH_DEBIAN="/etc/iptables/rules.v6"
IP6_RULES_PATH_RHEL="/etc/sysconfig/ip6tables"
IP4_RULES_PATH_DEBIAN="/etc/iptables/rules.v4"
IP4_RULES_PATH_RHEL="/etc/sysconfig/iptables"

# ─── 颜色 ────────────────────────────────────────────
G="\033[32m" Y="\033[33m" C="\033[36m" R="\033[31m" B="\033[1m" N="\033[0m"
L="\033[94m" W="\033[97m" D="\033[2m"

# ─── 通用辅助 ────────────────────────────────────────
detect_distro(){
  if [ ! -r /etc/os-release ]; then
    printf '%s' "unknown"
    return
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  printf '%s' "${ID:-unknown}"
}

is_debian_family(){
  local id id_like
  if [ ! -r /etc/os-release ]; then
    return 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  id="${ID:-}"
  id_like="${ID_LIKE:-}"
  case "$id" in
    debian|ubuntu|raspbian|linuxmint|devuan|kali|pop|elementary|zorin)
      return 0
      ;;
  esac
  case "$id_like" in
    *debian*|*ubuntu*)
      return 0
      ;;
  esac
  return 1
}

require_debian_family(){
  if is_debian_family; then
    return 0
  fi

  echo ""
  echo -e "  ${R}此脚本仅支持 Debian / Ubuntu 系发行版${N}"
  echo -e "  当前系统: ${C}$(detect_distro)${N}"
  echo -e "  如需强制运行可设置环境变量 ${B}LEYILI_ALLOW_ANY_DISTRO=1${N}"
  return 1
}

cleanup_old_backups(){
  local pattern="$1"
  local keep="${2:-5}"
  local dir base victim
  local -a victims=()

  if [ -z "$pattern" ]; then
    return 0
  fi

  case "$keep" in
    ''|*[!0-9]*) return 0 ;;
  esac

  # 用 find + null 分隔取代 ls 通配，正确处理含空格 / 特殊字符的路径
  dir=$(dirname -- "$pattern")
  base=$(basename -- "$pattern")
  [ -d "$dir" ] || return 0

  # 按 mtime 倒序收集，跳过最新 $keep 份后删除其余
  while IFS= read -r -d '' victim; do
    victims+=("${victim#*$'\t'}")
  done < <(find "$dir" -maxdepth 1 -type f -name "$base" -printf '%T@\t%p\0' 2>/dev/null \
           | LC_ALL=C sort -zrn 2>/dev/null)

  if [ "${#victims[@]}" -le "$keep" ]; then
    return 0
  fi

  local i
  for ((i = keep; i < ${#victims[@]}; i++)); do
    [ -n "${victims[i]}" ] && rm -f -- "${victims[i]}"
  done
}

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
  ip6tables -L INPUT -n 2>/dev/null | head -n1 | awk '{print $4}'
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
  iptables -L INPUT -n 2>/dev/null | head -n1 | awk '{print $4}'
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

register_sb_command(){
  local source_path=""

  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    source_path="${BASH_SOURCE[0]}"
  elif [ -n "${0:-}" ] && [ -f "$0" ]; then
    source_path="$0"
  fi

  if [ -n "$source_path" ]; then
    if cp "$source_path" "$SCRIPT_PATH" 2>/dev/null && chmod +x "$SCRIPT_PATH" 2>/dev/null; then
      return 0
    fi
  fi

  if [ -n "$SELF_INSTALL_URL" ]; then
    if curl -fsSL "$SELF_INSTALL_URL" -o "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"; then
      return 0
    fi
  fi

  echo -e "${Y}警告：${N} 无法自动安装 ${B}${APP_NAME}${N} 到 ${SCRIPT_PATH}。"
  echo -e "  请从本地文件运行脚本，或在安装前设置 ${B}SELF_INSTALL_URL${N}。"
  return 1
}

pause_screen(){
  echo ""
  read -p "按回车返回..." _
}

notify_invalid_choice(){
  echo ""
  echo -e "  ${Y}无效选项，请重新输入${N}"
  sleep 1
}

render_divider(){
  echo -e "  ${D}──────────────────────────────────────────────────────${N}"
}

render_brand_banner(){
  echo ""
  echo -e "  ${L}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "  ${L}║${N}  ${B}${W}${APP_NAME}${N}  ${D}Linux Menu${N}                                  ${L}║${N}"
  echo -e "  ${L}╚══════════════════════════════════════════════════════╝${N}"
}

render_section_header(){
  local title="$1"

  clear
  render_brand_banner
  echo -e "  ${B}${C}›  ${title}${N}"
  render_divider
}

render_menu_item(){
  local key="$1"
  local label="$2"

  echo -e "  ${D}│${N}  ${Y}${B}${key}${N}  ${label}"
}

render_info_line(){
  local label="$1"
  local value="$2"

  printf "  ${L}●${N} %-10s : %b\n" "$label" "$value"
}

validate_port(){
  local port="$1"

  case "$port" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac

  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

sanitize_sni(){
  printf '%s' "$1" | tr -d '\r\n' | tr -d '"'
}

require_root(){
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  echo ""
  echo -e "${R}该功能需要 root 权限${N}"
  pause_screen
  return 1
}

validate_linux_username(){
  local username="$1"

  printf '%s' "$username" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'
}

prompt_for_linux_username(){
  local prompt_text="$1"
  local username=""

  while true; do
    read -p "$prompt_text" username

    if ! validate_linux_username "$username"; then
      echo -e "${R}用户名只能使用小写字母、数字、下划线和连字符，且必须以字母或下划线开头${N}"
      continue
    fi

    if [ "$username" = "root" ]; then
      echo -e "${R}这里不能使用 root 作为普通用户名${N}"
      continue
    fi

    printf '%s' "$username"
    return 0
  done
}

detect_ssh_service_name(){
  if systemctl cat ssh >/dev/null 2>&1; then
    printf '%s' "ssh"
  elif systemctl cat sshd >/dev/null 2>&1; then
    printf '%s' "sshd"
  else
    printf '%s' "ssh"
  fi
}

get_sshd_binary(){
  if command -v sshd >/dev/null 2>&1; then
    command -v sshd
  elif [ -x /usr/sbin/sshd ]; then
    printf '%s' "/usr/sbin/sshd"
  fi
}

get_current_ssh_port(){
  local current_port=""

  if [ -f "$SSHD_CONFIG_PATH" ]; then
    current_port=$(awk '
      BEGIN { in_match = 0 }
      /^[[:space:]]*Match[[:space:]]+/ {
        in_match = 1
        next
      }
      !in_match && $0 ~ /^[[:space:]]*#?[[:space:]]*Port[[:space:]]+[0-9]+([[:space:]]|$)/ {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^[0-9]+$/) {
            print $i
            exit
          }
        }
      }
    ' "$SSHD_CONFIG_PATH")
  fi

  printf '%s' "${current_port:-22}"
}

# 用 sshd -T 取某指令实际生效值（已合并 sshd_config.d 与 Match 默认段）
# 返回小写值，找不到时返回空。失败不终止调用方。
get_effective_sshd_value(){
  local key="$1"
  local sshd_bin=""
  local lower_key=""

  [ -z "$key" ] && return 0
  sshd_bin=$(get_sshd_binary)
  [ -z "$sshd_bin" ] && return 0
  [ ! -f "$SSHD_CONFIG_PATH" ] && return 0

  lower_key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
  "$sshd_bin" -T -f "$SSHD_CONFIG_PATH" 2>/dev/null \
    | awk -v k="$lower_key" 'tolower($1) == k {print $2; exit}'
}

# 把 /etc/ssh/sshd_config.d/*.conf 里 <key> 不等于 <expected_value> 的赋值行注释掉
# 备份原文件为 <file>.bak.<时间戳>，使用 cleanup_old_backups 保留 5 份
# 返回 0=已处理或无需处理，1=有错误
neutralize_sshd_dropin_overrides(){
  local key="$1"
  local expected_value="$2"
  local dropin_dir="/etc/ssh/sshd_config.d"
  local file=""
  local timestamp=""
  local touched=0
  local lower_expected=""

  [ -z "$key" ] && return 1
  [ -d "$dropin_dir" ] || return 0

  lower_expected=$(printf '%s' "$expected_value" | tr '[:upper:]' '[:lower:]')
  timestamp=$(date +%Y%m%d%H%M%S)

  shopt -s nullglob
  for file in "$dropin_dir"/*.conf; do
    [ -f "$file" ] || continue
    # 文件里是否存在 <key> 的有效赋值，且值不等于期望
    if awk -v k="$key" -v want="$lower_expected" '
      BEGIN{ ignore=0 }
      /^[[:space:]]*Match[[:space:]]+/ { ignore=1; next }
      /^[[:space:]]*$/ { next }
      tolower($1) == tolower(k) && !ignore {
        v=tolower($2)
        if (v != want) { found=1; exit }
      }
      END{ exit !found }
    ' "$file"; then
      cp "$file" "${file}.bak.${timestamp}" 2>/dev/null || true
      # 注释掉所有 <key> 行（在 Match 之前），保留 Match 之后不动
      awk -v k="$key" '
        BEGIN{ in_match=0 }
        /^[[:space:]]*Match[[:space:]]+/ { in_match=1; print; next }
        {
          if (!in_match && tolower($1) == tolower(k) && $0 !~ /^[[:space:]]*#/) {
            print "# leyili-disabled: " $0
            next
          }
          print
        }
      ' "$file" > "${file}.tmp.$$" && mv "${file}.tmp.$$" "$file"
      touched=1
      echo -e "  ${Y}已注释覆盖项：${N}${C}${file}${N} ${D}(备份 .bak.${timestamp})${N}"
    fi
  done
  shopt -u nullglob

  if [ "$touched" = "1" ]; then
    cleanup_old_backups "${dropin_dir}/*.bak.*" 5 2>/dev/null || true
  fi
  return 0
}

generate_random_high_port(){
  local current_port="$1"
  local candidate=""
  local port_range=$((SSH_RANDOM_PORT_MAX - SSH_RANDOM_PORT_MIN + 1))

  while true; do
    candidate=$(( ((RANDOM << 15) | RANDOM) % port_range + SSH_RANDOM_PORT_MIN ))
    if [ "$candidate" -ne "$current_port" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
}

set_sshd_global_directive(){
  local key="$1"
  local value="$2"
  local tmp_file=""

  tmp_file=$(mktemp)
  if ! awk -v key="$key" -v value="$value" '
    BEGIN {
      updated = 0
      in_match = 0
    }
    /^[[:space:]]*Match[[:space:]]+/ {
      if (!updated) {
        print key " " value
        updated = 1
      }
      in_match = 1
      print
      next
    }
    {
      if (!in_match && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "([[:space:]]+.*)?$") {
        next
      }
      print
    }
    END {
      if (!updated) {
        print key " " value
      }
    }
  ' "$SSHD_CONFIG_PATH" > "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi

  mv "$tmp_file" "$SSHD_CONFIG_PATH"
}

apply_sshd_setting(){
  local key="$1"
  local value="$2"
  local success_message="$3"
  local backup_path=""
  local sshd_bin=""
  local ssh_service=""
  local effective_value=""
  local lower_key=""
  local lower_value=""
  local listen_ok=0

  if ! require_root; then
    return 1
  fi

  if [ ! -f "$SSHD_CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到 SSH 配置文件：$SSHD_CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  sshd_bin=$(get_sshd_binary)
  if [ -z "$sshd_bin" ]; then
    echo ""
    echo -e "${R}未找到 sshd，可执行文件校验失败${N}"
    pause_screen
    return 1
  fi

  backup_path="${SSHD_CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  if ! cp "$SSHD_CONFIG_PATH" "$backup_path"; then
    echo ""
    echo -e "${R}SSH 配置备份失败${N}"
    pause_screen
    return 1
  fi

  if ! set_sshd_global_directive "$key" "$value"; then
    cp "$backup_path" "$SSHD_CONFIG_PATH" 2>/dev/null || true
    echo ""
    echo -e "${R}SSH 配置写入失败，已恢复备份${N}"
    pause_screen
    return 1
  fi

  if ! "$sshd_bin" -t -f "$SSHD_CONFIG_PATH"; then
    cp "$backup_path" "$SSHD_CONFIG_PATH" 2>/dev/null || true
    echo ""
    echo -e "${R}SSH 配置校验失败，已恢复备份${N}"
    pause_screen
    return 1
  fi

  # 用 sshd -T 校验"实际生效值"等于目标（覆盖 Match 块和 sshd_config.d/*.conf 影响）
  # 不一致时先尝试自动注释 sshd_config.d 中的反向覆盖再次校验，仍不一致才回滚
  lower_key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
  lower_value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  effective_value=$(get_effective_sshd_value "$key")
  if [ -n "$effective_value" ] && [ "$(printf '%s' "$effective_value" | tr '[:upper:]' '[:lower:]')" != "$lower_value" ]; then
    echo -e "  ${Y}sshd -T 报告 ${key} 实际生效=${effective_value}，与目标 ${value} 不一致${N}"
    echo -e "  ${Y}尝试清理 /etc/ssh/sshd_config.d/*.conf 中的覆盖项...${N}"
    neutralize_sshd_dropin_overrides "$key" "$value" || true
    if ! "$sshd_bin" -t -f "$SSHD_CONFIG_PATH"; then
      cp "$backup_path" "$SSHD_CONFIG_PATH" 2>/dev/null || true
      echo -e "${R}清理覆盖后 sshd -t 校验失败，已恢复备份${N}"
      pause_screen
      return 1
    fi
    effective_value=$(get_effective_sshd_value "$key")
    if [ -n "$effective_value" ] && [ "$(printf '%s' "$effective_value" | tr '[:upper:]' '[:lower:]')" != "$lower_value" ]; then
      cp "$backup_path" "$SSHD_CONFIG_PATH" 2>/dev/null || true
      echo ""
      echo -e "${R}sshd -T 仍显示 ${key}=${effective_value}，无法达到 ${value}，已恢复备份${N}"
      echo -e "${Y}可能存在 Match 块限制，请手动检查 /etc/ssh/sshd_config 与 /etc/ssh/sshd_config.d/${N}"
      pause_screen
      return 1
    fi
  fi

  ssh_service=$(detect_ssh_service_name)
  if ! systemctl restart "$ssh_service"; then
    cp "$backup_path" "$SSHD_CONFIG_PATH" 2>/dev/null || true
    "$sshd_bin" -t -f "$SSHD_CONFIG_PATH" >/dev/null 2>&1 || true
    systemctl restart "$ssh_service" >/dev/null 2>&1 || true
    echo ""
    echo -e "${R}SSH 服务重启失败，已恢复备份并尝试恢复原配置${N}"
    pause_screen
    return 1
  fi

  # 重启后等待 sshd 重新监听，验证新端口确实在监听（最多等 3 秒）
  if [ "$key" = "Port" ] && command -v ss >/dev/null 2>&1; then
    local i=0
    while [ "$i" -lt 6 ]; do
      if ss -tlnp 2>/dev/null | awk -v p=":${value}$" '$4 ~ p && $0 ~ /sshd/ {found=1} END {exit !found}'; then
        listen_ok=1
        break
      fi
      sleep 0.5
      i=$((i + 1))
    done
    if [ "$listen_ok" -ne 1 ]; then
      cp "$backup_path" "$SSHD_CONFIG_PATH" 2>/dev/null || true
      systemctl restart "$ssh_service" >/dev/null 2>&1 || true
      echo ""
      echo -e "${R}sshd 已重启，但新端口 ${value} 未检测到监听，已回滚配置${N}"
      pause_screen
      return 1
    fi
  fi

  echo ""
  echo -e "${G}${success_message}${N}"
  echo -e "  备份文件: ${C}$backup_path${N}"
  if [ "$key" = "Port" ]; then
    echo -e "  ${Y}重要：${N}请立即开新终端验证新端口可登录，再关闭当前会话！"
  fi
  return 0
}

# 幂等：确保 SSH 密码登录全局生效
# - 主 sshd_config 写入 PasswordAuthentication=yes、KbdInteractiveAuthentication=yes
# - 清理 /etc/ssh/sshd_config.d/*.conf 里的反向覆盖
# - sshd -t 校验 + sshd -T 验证实际生效值 + 重启服务
# 失败时尽量回滚。返回 0=成功或已是预期状态，1=失败
ensure_password_auth_enabled(){
  local sshd_bin=""
  local ssh_service=""
  local backup_path=""
  local effective=""
  local need_restart=0

  if ! require_root; then
    return 1
  fi

  if [ ! -f "$SSHD_CONFIG_PATH" ]; then
    echo -e "${R}未找到 $SSHD_CONFIG_PATH${N}"
    return 1
  fi

  sshd_bin=$(get_sshd_binary)
  if [ -z "$sshd_bin" ]; then
    echo -e "${R}未找到 sshd 可执行文件${N}"
    return 1
  fi

  # 已经 yes 就早退（幂等）
  effective=$(get_effective_sshd_value PasswordAuthentication)
  local kbd_effective
  kbd_effective=$(get_effective_sshd_value KbdInteractiveAuthentication)
  if [ "$effective" = "yes" ] && { [ -z "$kbd_effective" ] || [ "$kbd_effective" = "yes" ]; }; then
    echo -e "  ${D}密码登录已启用（PasswordAuthentication=yes），跳过${N}"
    return 0
  fi

  echo -e "${Y}==> 确保 SSH 密码登录可用${N}"
  backup_path="${SSHD_CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  if ! cp "$SSHD_CONFIG_PATH" "$backup_path"; then
    echo -e "${R}SSH 配置备份失败${N}"
    return 1
  fi

  if ! set_sshd_global_directive "PasswordAuthentication" "yes"; then
    cp "$backup_path" "$SSHD_CONFIG_PATH" 2>/dev/null || true
    echo -e "${R}写入 PasswordAuthentication 失败，已回滚${N}"
    return 1
  fi
  if ! set_sshd_global_directive "KbdInteractiveAuthentication" "yes"; then
    cp "$backup_path" "$SSHD_CONFIG_PATH" 2>/dev/null || true
    echo -e "${R}写入 KbdInteractiveAuthentication 失败，已回滚${N}"
    return 1
  fi

  neutralize_sshd_dropin_overrides "PasswordAuthentication" "yes" || true
  neutralize_sshd_dropin_overrides "KbdInteractiveAuthentication" "yes" || true

  if ! "$sshd_bin" -t -f "$SSHD_CONFIG_PATH"; then
    cp "$backup_path" "$SSHD_CONFIG_PATH" 2>/dev/null || true
    echo -e "${R}sshd -t 校验失败，已回滚主配置${N}"
    return 1
  fi

  effective=$(get_effective_sshd_value PasswordAuthentication)
  if [ -n "$effective" ] && [ "$effective" != "yes" ]; then
    cp "$backup_path" "$SSHD_CONFIG_PATH" 2>/dev/null || true
    echo -e "${R}sshd -T 显示 PasswordAuthentication 实际为 ${effective}，已回滚${N}"
    echo -e "${Y}请手动检查 /etc/ssh/sshd_config.d/ 是否有未识别的覆盖${N}"
    return 1
  fi

  ssh_service=$(detect_ssh_service_name)
  if ! systemctl restart "$ssh_service"; then
    cp "$backup_path" "$SSHD_CONFIG_PATH" 2>/dev/null || true
    systemctl restart "$ssh_service" >/dev/null 2>&1 || true
    echo -e "${R}SSH 服务重启失败，已回滚${N}"
    return 1
  fi

  cleanup_old_backups "${SSHD_CONFIG_PATH}.bak.*" 5 2>/dev/null || true
  echo -e "  ${G}PasswordAuthentication = yes (已生效)${N}"
  return 0
}

detect_primary_ipv4(){
  local detected=""

  if command -v ip >/dev/null 2>&1; then
    detected=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i == "src") {
          print $(i + 1)
          exit
        }
      }
    }')

    if [ -z "$detected" ]; then
      detected=$(ip -4 addr show scope global up 2>/dev/null | awk '/inet / {
        split($2, parts, "/")
        print parts[1]
        exit
      }')
    fi
  fi

  if [ -z "$detected" ]; then
    detected=$(curl -s4 --max-time 3 ip.sb 2>/dev/null || true)
  fi

  printf '%s' "$detected"
}

detect_primary_ipv6(){
  local detected=""

  if command -v ip >/dev/null 2>&1; then
    detected=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i == "src") {
          print $(i + 1)
          exit
        }
      }
    }')

    if [ -z "$detected" ]; then
      detected=$(ip -6 addr show scope global up 2>/dev/null | awk '/inet6 / {
        split($2, parts, "/")
        print parts[1]
        exit
      }')
    fi
  fi

  if [ -z "$detected" ]; then
    detected=$(curl -s6 --max-time 3 ip.sb 2>/dev/null || true)
  fi

  printf '%s' "$detected"
}

describe_install_mode(){
  case "$1" in
    ipv6-in-ipv4-out)
      printf '%s' '仅 IPv6 入站 + 仅 IPv4 出站'
      ;;
    dualstack)
      printf '%s' '双栈入站 + 仅 IPv4 出站'
      ;;
    *)
      printf '%s' '仅 IPv4 入站 + 仅 IPv4 出站'
      ;;
  esac
}

is_singbox_installed(){
  command -v sing-box >/dev/null 2>&1
}

ensure_sagernet_repo(){
  local pkg need=()
  for pkg in curl gnupg ca-certificates; do
    command -v "$pkg" >/dev/null 2>&1 || dpkg -s "$pkg" >/dev/null 2>&1 || need+=("$pkg")
  done
  if [ "${#need[@]}" -gt 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" >/dev/null 2>&1; then
      echo -e "${R}依赖安装失败：${need[*]}${N}"
      return 1
    fi
  fi

  mkdir -p /etc/apt/keyrings || { echo -e "${R}无法创建 /etc/apt/keyrings${N}"; return 1; }

  if [ ! -s "$SAGERNET_KEYRING" ]; then
    if ! curl -fsSL --max-time 15 "$SAGERNET_KEY_URL" -o "$SAGERNET_KEYRING"; then
      echo -e "${R}下载 SagerNet GPG key 失败：$SAGERNET_KEY_URL${N}"
      rm -f "$SAGERNET_KEYRING"
      return 1
    fi
    chmod a+r "$SAGERNET_KEYRING"
  fi

  if [ ! -f "$SAGERNET_SOURCES" ]; then
    cat > "$SAGERNET_SOURCES" <<EOF
Types: deb
URIs: $SAGERNET_REPO_URI
Suites: *
Components: *
Enabled: yes
Signed-By: $SAGERNET_KEYRING
EOF
  fi

  return 0
}

install_singbox(){
  if ! ensure_sagernet_repo; then
    return 1
  fi

  # 关键：在 apt-get install 之前预写干净骨架，dpkg 看到 conffile 已存在
  # 配合 --force-confold 就不会落地 deb 自带的危险默认配置
  # （含端口 8080、固定密码 Gn1JUS14bLUHgv1cWDDp4A== 的 shadowsocks 入站）
  if ! config_ensure_skeleton; then
    echo -e "${R}写入 sing-box 配置骨架失败${N}"
    return 1
  fi

  if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
    echo -e "${Y}apt-get update 出错，继续尝试安装...${N}"
  fi

  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        sing-box; then
    echo -e "${R}apt-get install sing-box 失败${N}"
    return 1
  fi

  if ! command -v sing-box >/dev/null 2>&1; then
    echo -e "${R}sing-box 安装后仍找不到可执行文件${N}"
    return 1
  fi

  # postinst 可能已拉起服务（虽然此时配置是空骨架，无监听）。停下来由业务流程后续 restart。
  systemctl stop sing-box >/dev/null 2>&1 || true
  return 0
}

upgrade_singbox(){
  if ! ensure_sagernet_repo; then
    return 1
  fi

  if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
    echo -e "${Y}apt-get update 出错，继续尝试升级...${N}"
  fi

  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        sing-box; then
    echo -e "${R}apt-get install --only-upgrade sing-box 失败${N}"
    return 1
  fi

  return 0
}

require_singbox_installed(){
  if is_singbox_installed; then
    return 0
  fi

  echo ""
  echo -e "${Y}sing-box 尚未安装，请先在主菜单选择“安装 sing-box”。${N}"
  pause_screen
  return 1
}

get_info_value(){
  local key="$1"

  if [ ! -f "$INFO_PATH" ]; then
    return 1
  fi

  grep -m1 "^${key}=" "$INFO_PATH" | cut -d= -f2-
}

set_info_value(){
  local key="$1"
  local value="$2"
  local tmp_file

  if [ ! -f "$INFO_PATH" ]; then
    printf '%s=%s\n' "$key" "$value" > "$INFO_PATH"
    return 0
  fi

  tmp_file=$(mktemp)
  awk -v key="$key" -v value="$value" '
    BEGIN { updated = 0 }
    index($0, key "=") == 1 {
      print key "=" value
      updated = 1
      next
    }
    { print }
    END {
      if (!updated) {
        print key "=" value
      }
    }
  ' "$INFO_PATH" > "$tmp_file"
  mv "$tmp_file" "$INFO_PATH"
}

# ─── 节点存储 (per-node info file) ──────────────────
ensure_nodes_dir(){
  mkdir -p "$NODES_DIR" "$CERTS_DIR" 2>/dev/null || true
}

node_info_path(){
  printf '%s' "$NODES_DIR/$1.info"
}

node_installed(){
  [ -f "$(node_info_path "$1")" ]
}

list_installed_nodes(){
  ensure_nodes_dir
  local f base
  for f in "$NODES_DIR"/*.info; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf '%s\n' "${base%.info}"
  done
}

count_installed_nodes(){
  local n
  n=$(list_installed_nodes | wc -l)
  printf '%s' "$(echo "$n" | tr -d ' \t\n\r')"
}

get_node_value(){
  local type="$1" key="$2" f
  f=$(node_info_path "$type")
  [ -f "$f" ] || return 1
  grep -m1 "^${key}=" "$f" | cut -d= -f2-
}

set_node_value(){
  local type="$1" key="$2" value="$3" f tmp
  f=$(node_info_path "$type")
  ensure_nodes_dir
  if [ ! -f "$f" ]; then
    printf '%s=%s\n' "$key" "$value" > "$f"
    return 0
  fi
  tmp=$(mktemp)
  awk -v key="$key" -v value="$value" '
    BEGIN { updated = 0 }
    index($0, key "=") == 1 { print key "=" value; updated = 1; next }
    { print }
    END { if (!updated) print key "=" value }
  ' "$f" > "$tmp"
  mv "$tmp" "$f"
}

remove_node_info(){
  rm -f "$(node_info_path "$1")"
}

# 在多节点情况下让用户选一个节点；仅 1 个时直接回显；0 个返回 1
select_node_interactive(){
  local prompt_label="${1:-选择节点}"
  local nodes count input n i
  local arr=()
  while IFS= read -r n; do
    [ -n "$n" ] && arr+=("$n")
  done < <(list_installed_nodes)
  count=${#arr[@]}
  if [ "$count" -eq 0 ]; then
    return 1
  fi
  if [ "$count" -eq 1 ]; then
    printf '%s' "${arr[0]}"
    return 0
  fi
  {
    echo ""
    echo "  ${prompt_label}："
    i=1
    for n in "${arr[@]}"; do
      echo "    $i) $n"
      i=$((i + 1))
    done
  } >&2
  read -p "  请输入序号 (1): " input >&2
  input="${input:-1}"
  if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "$count" ]; then
    printf '%s' "${arr[$((input - 1))]}"
    return 0
  fi
  return 1
}

# ─── 配置文件 (jq 增量编辑) ─────────────────────────
ensure_jq(){
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  echo -e "${Y}==> 安装 jq...${N}"
  if ! apt-get install -y jq 2>/dev/null; then
    echo -e "${R}jq 安装失败，请手动执行：apt install jq${N}"
    return 1
  fi
  return 0
}

config_ensure_skeleton(){
  ensure_jq || return 1
  mkdir -p /etc/sing-box
  if [ ! -f "$CONFIG_PATH" ] || ! jq empty "$CONFIG_PATH" >/dev/null 2>&1; then
    cat > "$CONFIG_PATH" <<'EOF'
{
  "log": {"disabled": false, "level": "warn", "timestamp": true},
  "dns": {
    "servers": [
      {"type": "udp", "tag": "cloudflare", "server": "1.1.1.1", "detour": "direct-out"},
      {"type": "udp", "tag": "google", "server": "8.8.8.8", "detour": "direct-out"}
    ],
    "strategy": "ipv4_only"
  },
  "inbounds": [],
  "outbounds": [{
    "type": "direct",
    "tag": "direct-out",
    "domain_resolver": "cloudflare"
  }],
  "route": {
    "default_domain_resolver": "cloudflare",
    "rules": [
      {"port": 53, "action": "hijack-dns"}
    ],
    "final": "direct-out"
  }
}
EOF
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  # 透明升级：
  # 1) 若没 outbounds 或为空，建一条 tagged direct-out
  # 2) 若 direct outbound 没 tag，加上 tag=direct-out
  # 3) 确保 route 块存在，final 默认 direct-out
  # 4) DNS 兜底：servers 列表为空时塞两条公共 V4 上游（Cloudflare + Google）
  # 5) 路由兜底：保证有 hijack-dns:53 规则，避免客户端 DNS 走原路泄漏
  if jq '
      .log = (.log // {"disabled": false, "level": "warn", "timestamp": true})
    | .dns = (.dns // {})
    | .dns.servers = (if ((.dns.servers // []) | length) == 0
                      then [
                        {"type":"udp","tag":"cloudflare","server":"1.1.1.1","detour":"direct-out"},
                        {"type":"udp","tag":"google","server":"8.8.8.8","detour":"direct-out"}
                      ]
                      else .dns.servers end)
    | .dns.strategy = (.dns.strategy // "ipv4_only")
    | .inbounds = ((.inbounds // []) | map(select(.tag == "reality-in" or .tag == "hy2-in")))
    | .outbounds = (if ((.outbounds // []) | length) == 0
                    then [{"type":"direct","tag":"direct-out","domain_resolver":"cloudflare"}]
                    else (.outbounds | map(
                        if .type == "direct" and (.tag // "") == ""
                        then .tag = "direct-out"
                        else . end))
                    end)
    | .route = (.route // {})
    | .route.default_domain_resolver = (.route.default_domain_resolver // "cloudflare")
    | .route.rules = (
        ((.route.rules // []) | map(select(.action != "hijack-dns" and (.port // null) != 53)))
        + [{"port": 53, "action": "hijack-dns"}]
      )
    | .route.final = (.route.final // "direct-out")
  ' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$CONFIG_PATH"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

config_add_inbound(){
  local inbound="$1"
  ensure_jq || return 1
  config_ensure_skeleton || return 1
  local tmp tag
  tag=$(printf '%s' "$inbound" | jq -r '.tag // empty' 2>/dev/null)
  if [ -z "$tag" ]; then
    echo -e "${R}内部错误：inbound 缺少 tag${N}"
    return 1
  fi
  tmp=$(mktemp)
  if ! jq --argjson nb "$inbound" --arg tag "$tag" '
    .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) + [$nb]
  ' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$CONFIG_PATH"
}

config_remove_inbound_by_tag(){
  local tag="$1"
  ensure_jq || return 1
  [ -f "$CONFIG_PATH" ] || return 0
  local tmp
  tmp=$(mktemp)
  if ! jq --arg tag "$tag" '.inbounds = ((.inbounds // []) | map(select(.tag != $tag)))' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$CONFIG_PATH"
}

config_add_outbound(){
  local outbound="$1"
  ensure_jq || return 1
  config_ensure_skeleton || return 1
  local tmp tag
  tag=$(printf '%s' "$outbound" | jq -r '.tag // empty' 2>/dev/null)
  if [ -z "$tag" ]; then
    echo -e "${R}内部错误：outbound 缺少 tag${N}"
    return 1
  fi
  tmp=$(mktemp)
  if ! jq --argjson nb "$outbound" --arg tag "$tag" '
    .outbounds = ((.outbounds // []) | map(select(.tag != $tag))) + [$nb]
  ' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$CONFIG_PATH"
}

config_remove_outbound_by_tag(){
  local tag="$1"
  ensure_jq || return 1
  [ -f "$CONFIG_PATH" ] || return 0
  # 不允许移除 direct-out
  if [ "$tag" = "direct-out" ]; then
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  if ! jq --arg tag "$tag" '.outbounds = ((.outbounds // []) | map(select(.tag != $tag)))' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$CONFIG_PATH"
}

# 把 inbound -> outbound 的 route 规则替换或追加
config_set_inbound_chain(){
  local inbound_tag="$1" outbound_tag="$2"
  ensure_jq || return 1
  config_ensure_skeleton || return 1
  local tmp
  tmp=$(mktemp)
  if ! jq --arg ib "$inbound_tag" --arg ob "$outbound_tag" '
    .route = (.route // {rules: [], final: "direct-out"})
    | .route.rules = (
        ((.route.rules // []) | map(
          if (.inbound // []) | type == "array" and (. | index($ib))
          then empty else . end
        ))
        + [{inbound: [$ib], outbound: $ob}]
      )
  ' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$CONFIG_PATH"
}

# 删除某 inbound 对应的所有 route 规则（恢复到走 final=direct-out）
config_remove_inbound_chain(){
  local inbound_tag="$1"
  ensure_jq || return 1
  [ -f "$CONFIG_PATH" ] || return 0
  local tmp
  tmp=$(mktemp)
  if ! jq --arg ib "$inbound_tag" '
    .route = (.route // {rules: [], final: "direct-out"})
    | .route.rules = (
        (.route.rules // []) | map(
          if ((.inbound // []) | type == "array" and (. | index($ib)))
          then empty else . end
        )
      )
  ' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$CONFIG_PATH"
}

# 查询某 inbound 当前的出站 tag（没规则返回空）
config_get_inbound_outbound(){
  local inbound_tag="$1"
  ensure_jq || return 1
  [ -f "$CONFIG_PATH" ] || return 1
  jq -r --arg ib "$inbound_tag" '
    (.route.rules // [])
    | map(select((.inbound // []) | type == "array" and (. | index($ib))))
    | (.[0].outbound // "")
  ' "$CONFIG_PATH" 2>/dev/null
}

# ─── chain.info 存储 ─────────────────────────────────
ensure_chains_dir(){
  mkdir -p "$CHAINS_DIR" 2>/dev/null || true
}

chain_info_path(){
  printf '%s' "$CHAINS_DIR/$1.info"
}

chain_installed(){
  [ -f "$(chain_info_path "$1")" ]
}

get_chain_value(){
  local type="$1" key="$2" f
  f=$(chain_info_path "$type")
  [ -f "$f" ] || return 1
  grep -m1 "^${key}=" "$f" | cut -d= -f2-
}

remove_chain_info(){
  rm -f "$(chain_info_path "$1")"
}

config_check_and_restart(){
  if ! sing-box check -c "$CONFIG_PATH"; then
    return 1
  fi
  systemctl enable sing-box >/dev/null 2>&1 || true
  if ! systemctl restart sing-box; then
    return 1
  fi
  return 0
}

# 旧 /root/proxy-info.txt 迁移到 /etc/sing-box/nodes/reality.info
migrate_legacy_info(){
  # 旧配置里 reality inbound 的 tag 是 vless-in，统一重命名为 reality-in
  if [ -f "$CONFIG_PATH" ] && grep -q '"vless-in"' "$CONFIG_PATH" 2>/dev/null; then
    if command -v jq >/dev/null 2>&1; then
      local tmp
      tmp=$(mktemp)
      if jq '(.inbounds[]? | select(.tag == "vless-in") | .tag) = "reality-in"' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$CONFIG_PATH"
      else
        rm -f "$tmp"
      fi
    fi
  fi

  if node_installed reality; then
    return 0
  fi
  [ -f "$INFO_PATH" ] || return 0

  local uuid pubk prik ip port sni sid tag listen link mode bind4
  uuid=$(get_info_value UUID 2>/dev/null || true)
  pubk=$(get_info_value PublicKey 2>/dev/null || true)
  prik=$(get_info_value PrivateKey 2>/dev/null || true)
  ip=$(get_info_value IP 2>/dev/null || true)
  port=$(get_info_value Port 2>/dev/null || true)
  sni=$(get_info_value SNI 2>/dev/null || true)
  sid=$(get_info_value ShortID 2>/dev/null || true)
  tag=$(get_info_value Tag 2>/dev/null || true)
  listen=$(get_info_value ListenAddr 2>/dev/null || true)
  link=$(get_info_value Link 2>/dev/null || true)
  mode=$(get_info_value Mode 2>/dev/null || true)
  bind4=$(get_info_value BindIPv4 2>/dev/null || true)

  if [ -z "$uuid" ] && [ -z "$pubk" ]; then
    return 0
  fi

  ensure_nodes_dir
  local f
  f=$(node_info_path reality)
  cat > "$f" <<EOF
Type=reality
Tag=${tag:-reality}
Mode=${mode:-ipv4}
ListenAddr=${listen}
Port=${port}
SNI=${sni}
UUID=${uuid}
PublicKey=${pubk}
PrivateKey=${prik}
ShortID=${sid}
IP=${ip}
BindIPv4=${bind4}
Link=${link}
EOF
}

write_proxy_info(){
  local uuid="$1"
  local public_key="$2"
  local private_key="$3"
  local ip="$4"
  local port="$5"
  local sni="$6"
  local short_id="$7"
  local tag="$8"
  local listen_addr="$9"
  local link="${10}"
  local mode="${11:-ipv4}"
  local bind_ipv4="${12:-}"

  cat > "$INFO_PATH" << EOF
UUID=$uuid
PublicKey=$public_key
PrivateKey=$private_key
IP=$ip
Port=$port
SNI=$sni
ShortID=$short_id
Tag=$tag
ListenAddr=$listen_addr
Link=$link
Mode=$mode
BindIPv4=$bind_ipv4
EOF
}

load_proxy_context(){
  MENU_UUID=$(get_info_value UUID 2>/dev/null || true)
  MENU_PUBLIC_KEY=$(get_info_value PublicKey 2>/dev/null || true)
  MENU_PRIVATE_KEY=$(get_info_value PrivateKey 2>/dev/null || true)
  MENU_IP=$(get_info_value IP 2>/dev/null || true)
  MENU_PORT=$(get_info_value Port 2>/dev/null || true)
  MENU_SNI=$(get_info_value SNI 2>/dev/null || true)
  MENU_SHORT_ID=$(get_info_value ShortID 2>/dev/null || true)
  MENU_TAG=$(get_info_value Tag 2>/dev/null || true)
  MENU_LISTEN_ADDR=$(get_info_value ListenAddr 2>/dev/null || true)
  MENU_LINK=$(get_info_value Link 2>/dev/null || true)
  MENU_MODE=$(get_info_value Mode 2>/dev/null || true)
  MENU_BIND_IPV4=$(get_info_value BindIPv4 2>/dev/null || true)

  if [ -f "$CONFIG_PATH" ] && command -v jq >/dev/null 2>&1; then
    # 用 jq 解析 reality-in inbound（多行/缩进/空格都能正确处理）
    local jq_inbound='(.inbounds // [])
      | map(select(.tag == "reality-in" or .type == "vless"))
      | (.[0] // {})'

    if [ -z "$MENU_UUID" ]; then
      MENU_UUID=$(jq -r "${jq_inbound} | (.users[0].uuid // \"\")" "$CONFIG_PATH" 2>/dev/null)
    fi

    if [ -z "$MENU_PRIVATE_KEY" ]; then
      MENU_PRIVATE_KEY=$(jq -r "${jq_inbound} | (.tls.reality.private_key // \"\")" "$CONFIG_PATH" 2>/dev/null)
    fi

    if [ -z "$MENU_PORT" ]; then
      MENU_PORT=$(jq -r "${jq_inbound} | (.listen_port // empty)" "$CONFIG_PATH" 2>/dev/null)
    fi

    if [ -z "$MENU_SNI" ]; then
      MENU_SNI=$(jq -r "${jq_inbound} | (.tls.server_name // \"\")" "$CONFIG_PATH" 2>/dev/null)
    fi

    if [ -z "$MENU_SHORT_ID" ]; then
      MENU_SHORT_ID=$(jq -r "${jq_inbound} | (.tls.reality.short_id[0] // \"\")" "$CONFIG_PATH" 2>/dev/null)
    fi

    if [ -z "$MENU_LISTEN_ADDR" ]; then
      MENU_LISTEN_ADDR=$(jq -r "${jq_inbound} | (.listen // \"\")" "$CONFIG_PATH" 2>/dev/null)
    fi

    if [ -z "$MENU_BIND_IPV4" ]; then
      MENU_BIND_IPV4=$(jq -r '
        (.outbounds // [])
        | map(select(.type == "direct"))
        | (.[0].inet4_bind_address // "")
      ' "$CONFIG_PATH" 2>/dev/null)
    fi

    if [ -z "$MENU_MODE" ]; then
      case "$MENU_LISTEN_ADDR" in
        ::)
          MENU_MODE="dualstack"
          ;;
        *:*)
          MENU_MODE="ipv6-in-ipv4-out"
          ;;
        *)
          local final_route
          final_route=$(jq -r '.route.final // ""' "$CONFIG_PATH" 2>/dev/null)
          [ "$final_route" = "v4-out" ] && MENU_MODE="ipv6-in-ipv4-out"
          ;;
      esac
    fi
  elif [ -f "$CONFIG_PATH" ]; then
    # jq 不可用时，沿用旧的 sed 兜底（容错差但避免完全失效）
    if [ -z "$MENU_UUID" ]; then
      MENU_UUID=$(sed -n 's/.*"uuid":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_PATH" | head -1)
    fi
    if [ -z "$MENU_PRIVATE_KEY" ]; then
      MENU_PRIVATE_KEY=$(sed -n 's/.*"private_key":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_PATH" | head -1)
    fi
    if [ -z "$MENU_PORT" ]; then
      MENU_PORT=$(sed -n 's/.*"listen_port":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CONFIG_PATH" | head -1)
    fi
    if [ -z "$MENU_SNI" ]; then
      MENU_SNI=$(sed -n 's/.*"server_name":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_PATH" | head -1)
    fi
    if [ -z "$MENU_SHORT_ID" ]; then
      MENU_SHORT_ID=$(sed -n 's/.*"short_id":[[:space:]]*\["\([^"]*\)"\].*/\1/p' "$CONFIG_PATH" | head -1)
    fi
    if [ -z "$MENU_LISTEN_ADDR" ]; then
      MENU_LISTEN_ADDR=$(sed -n 's/.*"listen":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_PATH" | head -1)
    fi
    if [ -z "$MENU_BIND_IPV4" ]; then
      MENU_BIND_IPV4=$(sed -n 's/.*"inet4_bind_address":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_PATH" | head -1)
    fi
    if [ -z "$MENU_MODE" ]; then
      case "$MENU_LISTEN_ADDR" in
        ::)
          MENU_MODE="dualstack"
          ;;
        *:*)
          MENU_MODE="ipv6-in-ipv4-out"
          ;;
        *)
          if grep -Eq '"final":[[:space:]]*"v4-out"' "$CONFIG_PATH"; then
            MENU_MODE="ipv6-in-ipv4-out"
          fi
          ;;
      esac
    fi
  fi

  if [ -z "$MENU_IP" ]; then
    if [ "$MENU_MODE" = "ipv6-in-ipv4-out" ]; then
      MENU_IP=$(detect_primary_ipv6)
    else
      MENU_IP=$(detect_primary_ipv4)
    fi
  fi

  if [ -z "$MENU_IP" ]; then
    MENU_IP=$(detect_primary_ipv6)
  fi

  if [ -z "$MENU_TAG" ]; then
    MENU_TAG="reality"
  fi

  if [ -z "$MENU_LINK" ]; then
    MENU_LINK=$(build_client_link "$MENU_UUID" "$MENU_IP" "$MENU_PORT" "$MENU_SNI" "$MENU_PUBLIC_KEY" "$MENU_SHORT_ID" "$MENU_TAG" 2>/dev/null || true)
  fi
}

# ─── 链接构造（按协议） ───────────────────────────────
url_encode_host(){
  # 给 IPv6 地址套 [] ，IPv4 / 域名原样返回
  local ip="$1"
  case "$ip" in
    \[*\]) printf '%s' "$ip" ;;
    *:*)   printf '[%s]' "$ip" ;;
    *)     printf '%s' "$ip" ;;
  esac
}

build_reality_link(){
  local uuid="$1"
  local ip="$2"
  local port="$3"
  local sni="$4"
  local public_key="$5"
  local short_id="$6"
  local tag="${7:-reality}"

  if [ -z "$uuid" ] || [ -z "$ip" ] || [ -z "$port" ] || [ -z "$sni" ] || [ -z "$public_key" ] || [ -z "$short_id" ]; then
    return 1
  fi

  local host
  host=$(url_encode_host "$ip")
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
    "$uuid" "$host" "$port" "$sni" "$public_key" "$short_id" "$tag"
}

build_hy2_link(){
  # build_hy2_link <password> <ip> <port> <sni> <insecure 0|1> <obfs_type|""> <obfs_password|""> <tag> [hop_start] [hop_end]
  local password="$1"
  local ip="$2"
  local port="$3"
  local sni="$4"
  local insecure="${5:-0}"
  local obfs_type="$6"
  local obfs_password="$7"
  local tag="${8:-hy2}"
  local hop_start="${9:-}"
  local hop_end="${10:-}"

  if [ -z "$password" ] || [ -z "$ip" ] || [ -z "$port" ]; then
    return 1
  fi

  local host
  host=$(url_encode_host "$ip")
  local query="sni=${sni:-}&insecure=${insecure}"
  if [ -n "$obfs_type" ]; then
    query="${query}&obfs=${obfs_type}&obfs-password=${obfs_password}"
  fi

  local server_part
  if [ -n "$hop_start" ] && [ -n "$hop_end" ]; then
    server_part="${host}:${port},${hop_start}-${hop_end}"
  else
    server_part="${host}:${port}"
  fi
  printf 'hysteria2://%s@%s?%s#%s\n' \
    "$password" "$server_part" "$query" "$tag"
}

# ─── 链接解析（中转机用） ───────────────────────────
url_decode(){
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

# 把 URL query 串拆成 KEY=VALUE 行（已 url-decode）
parse_query_string(){
  local q="$1" pair k v
  local -a pairs=()
  IFS='&' read -ra pairs <<<"$q"
  for pair in "${pairs[@]}"; do
    k="${pair%%=*}"
    v="${pair#*=}"
    [ -z "$k" ] && continue
    printf '%s=%s\n' "$k" "$(url_decode "$v")"
  done
}

# 输入：vless:// 或 hysteria2:// 链接
# 输出：KEY=VALUE 行（Type / Host / Port / Tag 是通用字段，其余协议特有）
parse_node_link(){
  local url="$1"
  if [ -z "$url" ]; then return 1; fi

  local proto rest userinfo hostport query frag host port
  case "$url" in
    vless://*)
      proto="vless"
      rest="${url#vless://}"
      ;;
    hysteria2://*)
      proto="hy2"
      rest="${url#hysteria2://}"
      ;;
    hy2://*)
      proto="hy2"
      rest="${url#hy2://}"
      ;;
    *)
      return 1
      ;;
  esac

  # 拆 #fragment
  if [[ "$rest" == *"#"* ]]; then
    frag="${rest#*#}"
    rest="${rest%%#*}"
    frag=$(url_decode "$frag")
  fi
  # 拆 ?query
  if [[ "$rest" == *"?"* ]]; then
    query="${rest#*?}"
    rest="${rest%%\?*}"
  fi
  # 拆 user@host:port
  if [[ "$rest" == *"@"* ]]; then
    userinfo="${rest%@*}"
    hostport="${rest##*@}"
    userinfo=$(url_decode "$userinfo")
  else
    hostport="$rest"
  fi
  # 拆 host:port，IPv6 用 [host]:port
  case "$hostport" in
    \[*\]:*)
      host="${hostport#\[}"
      host="${host%%\]:*}"
      port="${hostport##*\]:}"
      ;;
    *:*)
      host="${hostport%:*}"
      port="${hostport##*:}"
      ;;
    *)
      host="$hostport"
      port=""
      ;;
  esac

  if [ -z "$host" ] || [ -z "$port" ]; then
    return 1
  fi
  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  # 通用输出
  printf 'Tag=%s\n' "${frag:-target}"
  printf 'Host=%s\n' "$host"
  printf 'Port=%s\n' "$port"

  if [ "$proto" = "vless" ]; then
    printf 'Type=reality\n'
    printf 'UUID=%s\n' "$userinfo"
    # 解析 query
    local kv
    while IFS= read -r kv; do
      [ -z "$kv" ] && continue
      local k="${kv%%=*}" v="${kv#*=}"
      case "$k" in
        sni)        printf 'SNI=%s\n' "$v" ;;
        pbk)        printf 'PublicKey=%s\n' "$v" ;;
        sid)        printf 'ShortID=%s\n' "$v" ;;
        flow)       printf 'Flow=%s\n' "$v" ;;
        security)   printf 'Security=%s\n' "$v" ;;
        type)       printf 'Network=%s\n' "$v" ;;
        fp)         printf 'Fingerprint=%s\n' "$v" ;;
      esac
    done < <(parse_query_string "${query:-}")
  else
    printf 'Type=hy2\n'
    printf 'Password=%s\n' "$userinfo"
    local kv
    while IFS= read -r kv; do
      [ -z "$kv" ] && continue
      local k="${kv%%=*}" v="${kv#*=}"
      case "$k" in
        sni)            printf 'SNI=%s\n' "$v" ;;
        insecure)       printf 'Insecure=%s\n' "$v" ;;
        obfs)           printf 'Obfs=%s\n' "$v" ;;
        obfs-password)  printf 'ObfsPassword=%s\n' "$v" ;;
      esac
    done < <(parse_query_string "${query:-}")
  fi

  return 0
}

# 用解析出的字段（KEY=VALUE 行）+ 期望的 outbound tag，组装一个 sing-box outbound 对象 (JSON)。
# 用法：build_chain_outbound_from_link <link> <outbound_tag>
build_chain_outbound_from_link(){
  local link="$1" outbound_tag="$2"
  local fields type host port sni
  fields=$(parse_node_link "$link") || return 1

  type=$(printf '%s\n' "$fields" | sed -n 's/^Type=//p' | head -1)
  host=$(printf '%s\n' "$fields" | sed -n 's/^Host=//p' | head -1)
  port=$(printf '%s\n' "$fields" | sed -n 's/^Port=//p' | head -1)
  sni=$(printf '%s\n' "$fields" | sed -n 's/^SNI=//p' | head -1)

  if [ -z "$type" ] || [ -z "$host" ] || [ -z "$port" ]; then
    return 1
  fi

  ensure_jq || return 1

  case "$type" in
    reality)
      local uuid pubk sid flow
      uuid=$(printf '%s\n' "$fields" | sed -n 's/^UUID=//p' | head -1)
      pubk=$(printf '%s\n' "$fields" | sed -n 's/^PublicKey=//p' | head -1)
      sid=$(printf '%s\n' "$fields" | sed -n 's/^ShortID=//p' | head -1)
      flow=$(printf '%s\n' "$fields" | sed -n 's/^Flow=//p' | head -1)
      flow="${flow:-xtls-rprx-vision}"
      if [ -z "$uuid" ] || [ -z "$pubk" ] || [ -z "$sid" ] || [ -z "$sni" ]; then
        return 1
      fi
      jq -n \
        --arg tag "$outbound_tag" \
        --arg server "$host" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg flow "$flow" \
        --arg sni "$sni" \
        --arg pbk "$pubk" \
        --arg sid "$sid" '
        {
          type: "vless",
          tag: $tag,
          server: $server,
          server_port: $port,
          uuid: $uuid,
          flow: $flow,
          domain_strategy: "ipv4_only",
          tls: {
            enabled: true,
            server_name: $sni,
            utls: {enabled: true, fingerprint: "chrome"},
            reality: {
              enabled: true,
              public_key: $pbk,
              short_id: $sid
            }
          }
        }'
      ;;
    hy2)
      local password insecure obfs obfs_pw
      password=$(printf '%s\n' "$fields" | sed -n 's/^Password=//p' | head -1)
      insecure=$(printf '%s\n' "$fields" | sed -n 's/^Insecure=//p' | head -1)
      insecure="${insecure:-0}"
      obfs=$(printf '%s\n' "$fields" | sed -n 's/^Obfs=//p' | head -1)
      obfs_pw=$(printf '%s\n' "$fields" | sed -n 's/^ObfsPassword=//p' | head -1)
      if [ -z "$password" ] || [ -z "$sni" ]; then
        return 1
      fi
      local insecure_bool="false"
      [ "$insecure" = "1" ] && insecure_bool="true"
      local obfs_json="null"
      if [ -n "$obfs" ] && [ "$obfs" != "none" ] && [ -n "$obfs_pw" ]; then
        obfs_json=$(jq -n --arg t "$obfs" --arg p "$obfs_pw" '{type: $t, password: $p}')
      fi
      jq -n \
        --arg tag "$outbound_tag" \
        --arg server "$host" \
        --argjson port "$port" \
        --arg password "$password" \
        --arg sni "$sni" \
        --argjson insecure "$insecure_bool" \
        --argjson obfs "$obfs_json" '
        ({
          type: "hysteria2",
          tag: $tag,
          server: $server,
          server_port: $port,
          password: $password,
          domain_strategy: "ipv4_only",
          tls: {
            enabled: true,
            server_name: $sni,
            insecure: $insecure,
            alpn: ["h3"]
          }
        }) + (if $obfs == null then {} else {obfs: $obfs} end)'
      ;;
    *)
      return 1
      ;;
  esac
}

# 由节点 info 文件构造链接（dispatcher）
build_link_for_node(){
  local type="$1"
  local ip_override="${2:-}"
  local tag_override="${3:-}"

  local node_type tag ip port sni
  node_type=$(get_node_value "$type" Type 2>/dev/null || echo "$type")
  tag=$(get_node_value "$type" Tag 2>/dev/null || echo "$type")
  [ -n "$tag_override" ] && tag="$tag_override"
  ip=${ip_override:-$(get_node_value "$type" IP 2>/dev/null || true)}
  port=$(get_node_value "$type" Port 2>/dev/null || true)
  sni=$(get_node_value "$type" SNI 2>/dev/null || true)

  case "$node_type" in
    reality)
      local uuid pubk sid
      uuid=$(get_node_value "$type" UUID 2>/dev/null || true)
      pubk=$(get_node_value "$type" PublicKey 2>/dev/null || true)
      sid=$(get_node_value "$type" ShortID 2>/dev/null || true)
      build_reality_link "$uuid" "$ip" "$port" "$sni" "$pubk" "$sid" "$tag"
      ;;
    hy2)
      local password insecure obfs_type obfs_pw hop_enabled hop_start hop_end
      password=$(get_node_value "$type" Password 2>/dev/null || true)
      insecure=$(get_node_value "$type" Insecure 2>/dev/null || echo 0)
      obfs_type=$(get_node_value "$type" Obfs 2>/dev/null || true)
      [ "$obfs_type" = "none" ] && obfs_type=""
      obfs_pw=$(get_node_value "$type" ObfsPassword 2>/dev/null || true)
      hop_enabled=$(get_node_value "$type" PortHop 2>/dev/null || echo 0)
      if [ "$hop_enabled" = "1" ]; then
        hop_start=$(get_node_value "$type" PortHopStart 2>/dev/null || true)
        hop_end=$(get_node_value "$type" PortHopEnd 2>/dev/null || true)
      fi
      build_hy2_link "$password" "$ip" "$port" "$sni" "$insecure" "$obfs_type" "$obfs_pw" "$tag" "${hop_start:-}" "${hop_end:-}"
      ;;
    *)
      return 1
      ;;
  esac
}

# 兼容旧调用（少数仍以 7 个参数调用 build_client_link 的地方）
build_client_link(){
  build_reality_link "$@"
}

# 双栈模式下，节点的 IPv6 副链接（如果与主 IP 不同）
build_dualstack_ipv6_link_for_node(){
  local type="$1"
  local mode ipv6 main_ip tag
  mode=$(get_node_value "$type" Mode 2>/dev/null || true)
  if [ "$mode" != "dualstack" ]; then
    return 1
  fi
  ipv6=$(detect_primary_ipv6)
  main_ip=$(get_node_value "$type" IP 2>/dev/null || true)
  if [ -z "$ipv6" ] || [ "$ipv6" = "$main_ip" ]; then
    return 1
  fi
  tag=$(get_node_value "$type" Tag 2>/dev/null || echo "$type")
  build_link_for_node "$type" "$ipv6" "${tag}-ipv6"
}

# 旧名兼容（仍被部分老代码调用，但新代码请用 build_dualstack_ipv6_link_for_node）
build_dualstack_ipv6_link(){
  local uuid="$1"
  local port="$2"
  local sni="$3"
  local public_key="$4"
  local short_id="$5"
  local tag="${6:-reality}"
  local ipv6=""

  if [ "${MENU_MODE:-}" != "dualstack" ]; then
    return 1
  fi

  ipv6=$(detect_primary_ipv6)
  if [ -z "$ipv6" ] || [ "$ipv6" = "$MENU_IP" ]; then
    return 1
  fi

  build_reality_link "$uuid" "$ipv6" "$port" "$sni" "$public_key" "$short_id" "${tag}-ipv6"
}

show_status_menu(){
  if ! require_singbox_installed; then
    return
  fi

  while true; do
    render_section_header "查看状态"
    render_menu_item 1 "查看运行状态"
    render_menu_item 2 "修改节点参数"
    render_menu_item 3 "实时日志"
    render_menu_item 4 "重启服务"
    render_menu_item 5 "停止服务"
    render_menu_item 6 "启动服务"
    render_menu_item 7 "查看客户端链接 / 二维码"
    render_menu_item 8 "查看配置"
    render_menu_item 9 "编辑配置"
    render_menu_item 10 "清理配置备份"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        systemctl status sing-box || true
        pause_screen
        ;;
      2)
        modify_node_params
        ;;
      3)
        echo -e "${Y}按 Ctrl+C 退出日志${N}"
        journalctl -u sing-box -f || true
        ;;
      4)
        if systemctl restart sing-box; then
          echo -e "${G}服务已重启${N}"
        else
          echo -e "${R}重启失败，请检查上方输出${N}"
        fi
        sleep 1
        ;;
      5)
        if systemctl stop sing-box; then
          echo -e "${Y}服务已停止${N}"
        else
          echo -e "${R}停止失败，请检查上方输出${N}"
        fi
        sleep 1
        ;;
      6)
        if systemctl start sing-box; then
          echo -e "${G}服务已启动${N}"
        else
          echo -e "${R}启动失败，请检查上方输出${N}"
        fi
        sleep 1
        ;;
      7)
        show_client_link
        ;;
      8)
        view_singbox_config
        ;;
      9)
        edit_singbox_config
        ;;
      10)
        cleanup_config_backups
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

show_system_menu(){
  while true; do
    render_section_header "系统基础设置"
    render_menu_item 1 "更新系统"
    render_menu_item 2 "启用自动更新"
    render_menu_item 3 "校正系统时间"
    render_menu_item 4 "安装基础工具"
    render_menu_item 5 "一键网络优化 (TCP + initcwnd)"
    render_menu_item 6 "查看网络优化状态"
    render_menu_item 7 "添加 SWAP (2G)"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        update_system_packages
        ;;
      2)
        enable_auto_updates
        ;;
      3)
        configure_system_time
        ;;
      4)
        install_basic_tools
        ;;
      5)
        show_network_optimization_menu
        ;;
      6)
        show_network_optimization_status
        ;;
      7)
        configure_swap
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

show_admin_menu(){
  while true; do
    render_section_header "管理员设置"
    render_menu_item 1 "创建普通用户"
    render_menu_item 2 "加入 sudo 组"
    render_menu_item 3 "测试用户登录"
    render_menu_item 4 "修改 SSH 端口"
    render_menu_item 5 "禁止 root 登录"
    render_menu_item 6 "配置 sudo 免密"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        create_regular_user
        ;;
      2)
        add_user_to_sudo_group
        ;;
      3)
        test_user_login
        ;;
      4)
        configure_ssh_port
        ;;
      5)
        disable_root_ssh_login
        ;;
      6)
        configure_passwordless_sudo
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

show_ipv6_firewall_menu(){
  local ssh_port

  if ! require_root; then
    return 1
  fi

  if ! command -v ip6tables >/dev/null 2>&1; then
    echo ""
    echo -e "${R}系统未安装 ip6tables，无法管理 IPv6 防火墙${N}"
    pause_screen
    return 1
  fi

  while true; do
    ssh_port=$(ip6_detect_ssh_port)

    render_section_header "IPv6 防火墙管理"
    echo -e "  ${L}│${N}  SSH 端口  ${D}·${N}  ${C}${ssh_port}${N}"

    local input_policy opened_ports
    input_policy=$(ip6_get_input_policy)
    opened_ports=$(ip6_list_opened_ports_compact)
    if [ -n "$opened_ports" ]; then
      echo -e "  ${L}│${N}  已开放    ${D}·${N}  ${C}${opened_ports}${N}"
    elif [ "$input_policy" = "ACCEPT" ]; then
      echo -e "  ${L}│${N}  已开放    ${D}·${N}  ${Y}默认策略 ACCEPT${N}  ${D}(无显式规则, 全部入站放行)${N}"
    else
      echo -e "  ${L}│${N}  已开放    ${D}·${N}  ${D}(无)${N}"
    fi
    render_divider
    render_menu_item 1 "查看当前规则"
    render_menu_item 2 "查看监听 IPv6 的服务"
    render_menu_item 3 "一键初始化 (放行 SSH/80/443)"
    render_menu_item 4 "开放端口"
    render_menu_item 5 "关闭端口"
    render_menu_item 6 "紧急放行 (关闭 v6 防火墙)"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        ip6_view_rules
        ;;
      2)
        ip6_view_listening
        ;;
      3)
        ip6_init_firewall
        ;;
      4)
        ip6_open_port
        ;;
      5)
        ip6_close_port
        ;;
      6)
        ip6_emergency_disable
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

ip6_view_rules(){
  local input_policy output_policy forward_policy opened

  input_policy=$(ip6_get_input_policy)
  output_policy=$(ip6tables -L OUTPUT -n 2>/dev/null | head -n1 | awk '{print $4}')
  forward_policy=$(ip6tables -L FORWARD -n 2>/dev/null | head -n1 | awk '{print $4}')

  echo ""
  echo -e "  ${B}${C}默认策略${N}"
  echo -e "  INPUT   : ${C}${input_policy}${N}  ${D}(别人主动连你)${N}"
  echo -e "  OUTPUT  : ${C}${output_policy}${N}  ${D}(你主动出去连别人)${N}"
  echo -e "  FORWARD : ${C}${forward_policy}${N}  ${D}(转发, Docker 用, 脚本不动)${N}"
  echo ""

  echo -e "  ${B}${C}已开放的入站端口${N}"
  opened=$(ip6tables-save 2>/dev/null | awk '
    /^-A INPUT/ {
      proto=""; port=""
      for (i = 1; i <= NF; i++) {
        if ($i == "-p") proto = $(i + 1)
        if ($i == "--dport") port = $(i + 1)
      }
      if (port != "") printf "  %s  %s\n", toupper(proto), port
    }' | sort -u)

  if [ -z "$opened" ]; then
    echo -e "  ${D}(无)${N}"
  else
    echo "$opened"
  fi
  echo ""

  echo -e "  ${B}${C}完整 INPUT 规则${N}"
  ip6tables -L INPUT -n -v --line-numbers
  pause_screen
}

ip6_view_listening(){
  echo ""
  echo -e "  ${B}${C}监听 IPv6 的服务${N}"
  render_divider
  echo -e "  ${Y}TCP${N}"
  if ! ss -6tlnp 2>/dev/null; then
    echo -e "  ${R}ss 不可用${N}"
  fi
  echo ""
  echo -e "  ${Y}UDP${N}"
  if ! ss -6ulnp 2>/dev/null; then
    echo -e "  ${R}ss 不可用${N}"
  fi
  echo ""
  echo -e "  ${D}提示：监听 [::] 表示同时接受 IPv4 (经映射) 和 IPv6 连接${N}"
  pause_screen
}

ip6_init_firewall(){
  local ssh_port confirm
  local backup_rules="" rb_choice="y" rb_pid="" rb_seconds=180

  ssh_port=$(ip6_detect_ssh_port)

  echo ""
  echo -e "  ${B}${C}一键初始化${N}"
  render_divider
  echo "  本次会执行："
  echo "    1) 清空当前 IPv6 INPUT 规则"
  echo "    2) 放行回环 lo"
  echo "    3) 放行已建立的连接 (ESTABLISHED, RELATED)"
  echo "    4) 放行 ICMPv6 (邻居发现等必需)"
  echo -e "    5) 放行 SSH 端口: ${C}${ssh_port}${N}/tcp  ${D}(自动检测)${N}"
  echo "    6) 放行 80/tcp"
  echo "    7) 放行 443/tcp"
  echo "    8) INPUT 默认策略 = DROP"
  echo "    9) OUTPUT 保持 ACCEPT"
  echo "   10) FORWARD 不动 (留给 Docker)"
  echo ""
  echo -e "  ${D}注意：节点端口（Reality TCP / Hysteria2 UDP）不在此初始化范围内，${N}"
  echo -e "  ${D}      请在初始化完成后到本菜单 ${C}4) 开放端口${N} ${D}里手动放行。${N}"
  echo ""

  # 锁库前置检查：sshd 必须真的在 ssh_port 上监听
  if ! verify_sshd_listening_on_port "$ssh_port"; then
    echo -e "  ${R}${B}严重警告：sshd 未在 ${ssh_port}/tcp 上监听${N}"
    echo -e "  ${Y}如果你当前是通过 IPv6 SSH 进来的，应用规则可能立即断开${N}"
    echo ""
    read -p "  仍要继续吗？输入大写 ${R}YES${N} 强制继续: " confirm
    if [ "$confirm" != "YES" ]; then
      echo -e "  已取消"
      sleep 1
      return 0
    fi
  fi

  if ip6_check_current_ssh_v6; then
    echo -e "  ${R}${B}警告：你当前 SSH 是 IPv6 进来的${N}"
    echo -e "  ${Y}建议先用 IPv4 登录后再操作${N}"
    echo ""
  fi

  read -p "  确认继续？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  # 兜底：是否启用延时自动回滚守护
  echo ""
  echo -e "  ${B}延时自动回滚守护（强烈建议启用）${N}"
  echo -e "  ${D}启用后规则应用 ${rb_seconds}s 内若未手动取消，将自动恢复旧规则${N}"
  read -p "  启用 ${rb_seconds}s 自动回滚守护？(Y/n): " rb_choice
  if [ "$rb_choice" = "n" ] || [ "$rb_choice" = "N" ]; then
    rb_choice="n"
  else
    rb_choice="y"
    backup_rules=$(mktemp /tmp/leyili-ip6tables-rb.XXXXXX 2>/dev/null) || backup_rules=""
    if [ -n "$backup_rules" ]; then
      ip6tables-save > "$backup_rules" 2>/dev/null || { rm -f "$backup_rules"; backup_rules=""; }
    fi
  fi

  if ! ip6_ensure_persistence; then
    echo ""
    echo -e "${R}持久化工具安装失败${N}"
    [ -n "$backup_rules" ] && rm -f "$backup_rules"
    pause_screen
    return 1
  fi

  ip6tables -F INPUT
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
  ip6tables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
  ip6tables -A INPUT -p tcp --dport 80 -j ACCEPT
  ip6tables -A INPUT -p tcp --dport 443 -j ACCEPT
  ip6tables -P INPUT DROP
  ip6tables -P OUTPUT ACCEPT

  # 自动恢复 reality / hy2 节点主端口放行（IPv6 侧）
  # 仅在节点 Mode 为 dualstack / ipv6-in-ipv4-out 时需要
  local node_port node_mode
  if node_installed reality; then
    node_port=$(get_node_value reality Port 2>/dev/null || true)
    node_mode=$(get_node_value reality Mode 2>/dev/null || echo ipv4)
    if [ -n "$node_port" ] \
       && { [ "$node_mode" = "dualstack" ] || [ "$node_mode" = "ipv6-in-ipv4-out" ]; }; then
      ip6tables -C INPUT -p tcp --dport "$node_port" -j ACCEPT 2>/dev/null \
        || ip6tables -A INPUT -p tcp --dport "$node_port" -j ACCEPT 2>/dev/null || true
      echo -e "  ${G}已自动恢复 reality 主端口放行 (v6)：${node_port}/tcp${N}"
    fi
  fi
  if node_installed hy2; then
    node_port=$(get_node_value hy2 Port 2>/dev/null || true)
    node_mode=$(get_node_value hy2 Mode 2>/dev/null || echo ipv4)
    if [ -n "$node_port" ] \
       && { [ "$node_mode" = "dualstack" ] || [ "$node_mode" = "ipv6-in-ipv4-out" ]; }; then
      ip6tables -C INPUT -p udp --dport "$node_port" -j ACCEPT 2>/dev/null \
        || ip6tables -A INPUT -p udp --dport "$node_port" -j ACCEPT 2>/dev/null || true
      echo -e "  ${G}已自动恢复 hy2 主端口放行 (v6)：${node_port}/udp${N}"
    fi
  fi

  if ! ip6_save_rules; then
    echo -e "${Y}规则已生效，但持久化失败，重启后可能丢失${N}"
  fi

  echo ""
  echo -e "${G}IPv6 防火墙已启用${N}"

  if [ "$rb_choice" = "y" ] && [ -n "$backup_rules" ]; then
    rb_pid=$(schedule_iptables_rollback "$rb_seconds" "" "$backup_rules")
    if [ -n "$rb_pid" ]; then
      echo -e "  ${Y}延时回滚守护已启动 (PID ${rb_pid})，${rb_seconds}s 后自动恢复旧规则${N}"
      echo -e "  ${B}请尽快开新终端验证 SSH 仍可登录，然后执行：${N}"
      echo -e "    ${C}kill ${rb_pid} && rm -f ${backup_rules}${N}  ${D}# 取消回滚${N}"
    fi
  fi
  pause_screen
}

ip6_open_port(){
  local proto_choice protos="" port proto changed=0

  echo ""
  echo -e "  ${B}${C}开放端口${N}"
  render_divider
  render_menu_item 1 "TCP"
  render_menu_item 2 "UDP"
  render_menu_item 3 "TCP + UDP (都开)"
  render_menu_item 0 "返回"
  render_divider
  read -p "  选择协议: " proto_choice

  case "$proto_choice" in
    1) protos="tcp" ;;
    2) protos="udp" ;;
    3) protos="tcp udp" ;;
    0) return 0 ;;
    *)
      notify_invalid_choice
      return 0
      ;;
  esac

  read -p "  端口号 (1-65535): " port
  if ! validate_port "$port"; then
    echo -e "${R}端口必须是 1-65535 的数字${N}"
    pause_screen
    return 1
  fi

  for proto in $protos; do
    if ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
      echo -e "  ${Y}${port}/${proto} 已放行，跳过${N}"
    else
      ip6tables -A INPUT -p "$proto" --dport "$port" -j ACCEPT
      echo -e "  ${G}已放行 ${port}/${proto}${N}"
      changed=1
    fi
  done

  if [ "$changed" -eq 1 ]; then
    if ! ip6_save_rules; then
      echo -e "${Y}持久化失败${N}"
    fi
  fi
  pause_screen
}

ip6_close_port(){
  local proto_choice protos="" port ssh_port confirm proto removed=0

  echo ""
  echo -e "  ${B}${C}关闭端口${N}"
  render_divider
  render_menu_item 1 "TCP"
  render_menu_item 2 "UDP"
  render_menu_item 3 "TCP + UDP (都关)"
  render_menu_item 0 "返回"
  render_divider
  read -p "  选择协议: " proto_choice

  case "$proto_choice" in
    1) protos="tcp" ;;
    2) protos="udp" ;;
    3) protos="tcp udp" ;;
    0) return 0 ;;
    *)
      notify_invalid_choice
      return 0
      ;;
  esac

  read -p "  要关闭的端口号 (1-65535): " port

  if ! validate_port "$port"; then
    echo -e "${R}端口必须是 1-65535 的数字${N}"
    pause_screen
    return 1
  fi

  ssh_port=$(ip6_detect_ssh_port)
  if [ "$port" = "$ssh_port" ] && printf '%s' "$protos" | grep -qw tcp; then
    echo ""
    echo -e "  ${R}${B}警告：${port}/tcp 是当前 SSH 端口${N}"
    echo -e "  ${Y}关闭后将无法通过 IPv6 SSH（IPv4 不受影响）${N}"
    read -p "  确认继续？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo -e "  已取消"
      sleep 1
      return 0
    fi
  fi

  for proto in $protos; do
    while ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; do
      ip6tables -D INPUT -p "$proto" --dport "$port" -j ACCEPT
      echo -e "  ${G}已删除 ${port}/${proto}${N}"
      removed=$((removed + 1))
    done
  done

  if [ "$removed" -eq 0 ]; then
    echo -e "  ${Y}端口 ${port} 在所选协议下没有放行规则${N}"
  else
    if ! ip6_save_rules; then
      echo -e "${Y}持久化失败${N}"
    fi
  fi
  pause_screen
}

ip6_emergency_disable(){
  local confirm confirm2

  echo ""
  echo -e "  ${R}${B}紧急放行（关闭 v6 防火墙）${N}"
  render_divider
  echo "  执行后："
  echo "    - 清空所有 IPv6 INPUT 规则"
  echo "    - 默认策略改回 ACCEPT"
  echo "    - v6 入站回到完全裸奔状态"
  echo ""

  read -p "  确认？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi
  read -p "  再次确认（输入大写 YES 继续）: " confirm2
  if [ "$confirm2" != "YES" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  ip6tables -P INPUT ACCEPT
  ip6tables -F INPUT
  if ! ip6_save_rules; then
    echo -e "${Y}持久化失败${N}"
  fi

  echo ""
  echo -e "${Y}已关闭 v6 防火墙${N}"
  pause_screen
}

# ─── IPv4 防火墙菜单 ─────────────────────────────────
show_ipv4_firewall_menu(){
  local ssh_port conflicts

  if ! require_root; then
    return 1
  fi

  if ! command -v iptables >/dev/null 2>&1; then
    echo ""
    echo -e "${R}系统未安装 iptables，无法管理 IPv4 防火墙${N}"
    pause_screen
    return 1
  fi

  while true; do
    ssh_port=$(ip6_detect_ssh_port)
    conflicts=$(ip4_detect_conflicts)

    render_section_header "IPv4 防火墙管理"
    echo -e "  ${L}│${N}  SSH 端口  ${D}·${N}  ${C}${ssh_port}${N}"
    if [ -n "$conflicts" ]; then
      echo -e "  ${L}│${N}  ${R}${B}冲突警告${N}  ${D}·${N}  ${Y}检测到 ${C}${conflicts}${N}${Y} 在管理 IPv4 防火墙${N}"
      echo -e "  ${L}│${N}  ${D}            本菜单直接改 iptables，可能与上述工具冲突或被覆盖${N}"
    fi
    echo -e "  ${L}│${N}  说明      ${D}·${N}  ${D}本菜单只动 IPv4，不影响 IPv6 / Docker FORWARD${N}"
    render_divider
    render_menu_item 1 "查看当前规则"
    render_menu_item 2 "查看监听 IPv4 的服务"
    render_menu_item 3 "一键初始化 (放行 SSH/80/443)"
    render_menu_item 4 "开放端口"
    render_menu_item 5 "关闭端口"
    render_menu_item 6 "紧急放行 (关闭 v4 防火墙)"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1) ip4_view_rules ;;
      2) ip4_view_listening ;;
      3) ip4_init_firewall ;;
      4) ip4_open_port ;;
      5) ip4_close_port ;;
      6) ip4_emergency_disable ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

ip4_view_rules(){
  local input_policy output_policy forward_policy opened

  input_policy=$(ip4_get_input_policy)
  output_policy=$(iptables -L OUTPUT -n 2>/dev/null | head -n1 | awk '{print $4}')
  forward_policy=$(iptables -L FORWARD -n 2>/dev/null | head -n1 | awk '{print $4}')

  echo ""
  echo -e "  ${B}${C}默认策略${N}"
  echo -e "  INPUT   : ${C}${input_policy}${N}  ${D}(别人主动连你)${N}"
  echo -e "  OUTPUT  : ${C}${output_policy}${N}  ${D}(你主动出去连别人)${N}"
  echo -e "  FORWARD : ${C}${forward_policy}${N}  ${D}(转发, Docker 用, 脚本不动)${N}"
  echo ""

  echo -e "  ${B}${C}已开放的入站端口${N}"
  opened=$(iptables-save 2>/dev/null | awk '
    /^-A INPUT/ {
      proto=""; port=""
      for (i = 1; i <= NF; i++) {
        if ($i == "-p") proto = $(i + 1)
        if ($i == "--dport") port = $(i + 1)
      }
      if (port != "") printf "  %s  %s\n", toupper(proto), port
    }' | sort -u)

  if [ -z "$opened" ]; then
    echo -e "  ${D}(无)${N}"
  else
    echo "$opened"
  fi
  echo ""

  echo -e "  ${B}${C}完整 INPUT 规则${N}"
  iptables -L INPUT -n -v --line-numbers
  pause_screen
}

ip4_view_listening(){
  echo ""
  echo -e "  ${B}${C}监听 IPv4 的服务${N}"
  render_divider
  echo -e "  ${Y}TCP${N}"
  if ! ss -4tlnp 2>/dev/null; then
    echo -e "  ${R}ss 不可用${N}"
  fi
  echo ""
  echo -e "  ${Y}UDP${N}"
  if ! ss -4ulnp 2>/dev/null; then
    echo -e "  ${R}ss 不可用${N}"
  fi
  echo ""
  echo -e "  ${D}提示：监听 0.0.0.0 表示接受所有 IPv4 客户端${N}"
  pause_screen
}

ip4_init_firewall(){
  local ssh_port confirm conflicts
  local backup_rules="" rb_choice="y" rb_pid="" rb_seconds=180

  ssh_port=$(ip6_detect_ssh_port)
  conflicts=$(ip4_detect_conflicts)

  echo ""
  echo -e "  ${B}${C}一键初始化${N}"
  render_divider
  echo "  本次会执行："
  echo "    1) 清空当前 IPv4 INPUT 规则"
  echo "    2) 放行回环 lo"
  echo "    3) 放行已建立的连接 (ESTABLISHED, RELATED)"
  echo "    4) 放行 ICMP (ping 等必需)"
  echo -e "    5) 放行 SSH 端口: ${C}${ssh_port}${N}/tcp  ${D}(自动检测)${N}"
  echo "    6) 放行 80/tcp"
  echo "    7) 放行 443/tcp"
  echo "    8) INPUT 默认策略 = DROP"
  echo "    9) OUTPUT 保持 ACCEPT"
  echo "   10) FORWARD 不动 (留给 Docker)"
  echo ""
  echo -e "  ${D}注意：节点端口（Reality TCP / Hysteria2 UDP）不在此初始化范围内，${N}"
  echo -e "  ${D}      请在初始化完成后到本菜单 ${C}4) 开放端口${N} ${D}里手动放行。${N}"
  echo ""

  # 锁库前置检查 1：sshd 必须真的在 ssh_port 监听
  if ! verify_sshd_listening_on_port "$ssh_port"; then
    echo -e "  ${R}${B}严重警告：sshd 未在 ${ssh_port}/tcp 上监听${N}"
    echo -e "  ${Y}如果应用规则会立即锁死所有 SSH 连接。请确认：${N}"
    echo -e "    1) sshd 服务是否运行：systemctl status ssh"
    echo -e "    2) sshd 实际端口：ss -tlnp | grep sshd"
    echo ""
    read -p "  仍要继续吗？输入大写 ${R}YES${N} 强制继续: " confirm
    if [ "$confirm" != "YES" ]; then
      echo -e "  已取消"
      sleep 1
      return 0
    fi
  fi

  if [ -n "$conflicts" ]; then
    echo -e "  ${R}${B}警告：检测到 ${conflicts} 在管理防火墙${N}"
    echo -e "  ${Y}继续可能与上述工具冲突或被覆盖。如果你用 1Panel / ufw / firewalld 管 IPv4，${N}"
    echo -e "  ${Y}建议在那边管，本菜单留给纯 iptables 用户。${N}"
    echo ""
  fi

  if ip4_check_current_ssh_v4; then
    echo -e "  ${R}${B}重要：你当前 SSH 是 IPv4 进来的${N}"
    echo -e "  ${R}${B}如果上面检测的 SSH 端口 ${ssh_port} 不对，应用规则后你会立刻断开${N}"
    echo -e "  ${Y}请先单独开个新会话测试 ssh root@<本机IP> -p ${ssh_port} 能不能连上${N}"
    echo ""
  fi

  read -p "  确认继续？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  # 兜底问询：是否启用延时自动回滚守护
  echo ""
  echo -e "  ${B}延时自动回滚守护（强烈建议启用）${N}"
  echo -e "  ${D}若启用，规则应用后会启动后台守护，${rb_seconds} 秒内若你未手动取消，将自动恢复旧规则${N}"
  echo -e "  ${D}规则生效后请立即开新终端验证 SSH 仍可登录，再回此菜单选「6) 紧急放行」之外的任意项即可取消守护${N}"
  read -p "  启用 ${rb_seconds}s 自动回滚守护？(Y/n): " rb_choice
  if [ "$rb_choice" = "n" ] || [ "$rb_choice" = "N" ]; then
    rb_choice="n"
  else
    rb_choice="y"
    backup_rules=$(mktemp /tmp/leyili-iptables-rb.XXXXXX 2>/dev/null) || backup_rules=""
    if [ -n "$backup_rules" ]; then
      iptables-save > "$backup_rules" 2>/dev/null || { rm -f "$backup_rules"; backup_rules=""; }
    fi
  fi

  if ! ip6_ensure_persistence; then
    echo ""
    echo -e "${R}持久化工具安装失败${N}"
    [ -n "$backup_rules" ] && rm -f "$backup_rules"
    pause_screen
    return 1
  fi

  iptables -F INPUT
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A INPUT -p icmp -j ACCEPT
  iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
  iptables -A INPUT -p tcp --dport 80 -j ACCEPT
  iptables -A INPUT -p tcp --dport 443 -j ACCEPT
  iptables -P INPUT DROP
  iptables -P OUTPUT ACCEPT

  # 自动恢复 reality / hy2 节点主端口放行（IPv4 侧）
  # 仅在节点 Mode 为 ipv4 / dualstack 时需要
  local node_port node_mode
  if node_installed reality; then
    node_port=$(get_node_value reality Port 2>/dev/null || true)
    node_mode=$(get_node_value reality Mode 2>/dev/null || echo ipv4)
    if [ -n "$node_port" ] \
       && { [ "$node_mode" = "ipv4" ] || [ "$node_mode" = "dualstack" ]; }; then
      iptables -C INPUT -p tcp --dport "$node_port" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport "$node_port" -j ACCEPT 2>/dev/null || true
      echo -e "  ${G}已自动恢复 reality 主端口放行：${node_port}/tcp${N}"
    fi
  fi
  if node_installed hy2; then
    node_port=$(get_node_value hy2 Port 2>/dev/null || true)
    node_mode=$(get_node_value hy2 Mode 2>/dev/null || echo ipv4)
    if [ -n "$node_port" ] \
       && { [ "$node_mode" = "ipv4" ] || [ "$node_mode" = "dualstack" ]; }; then
      iptables -C INPUT -p udp --dport "$node_port" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p udp --dport "$node_port" -j ACCEPT 2>/dev/null || true
      echo -e "  ${G}已自动恢复 hy2 主端口放行：${node_port}/udp${N}"
    fi
  fi

  # 应用后再次校验 sshd 监听依然存在（防止备份/检测误差）
  if ! verify_sshd_listening_on_port "$ssh_port"; then
    if [ -n "$backup_rules" ]; then
      iptables-restore < "$backup_rules" 2>/dev/null || true
      rm -f "$backup_rules"
      echo -e "${R}应用后 sshd 在 ${ssh_port} 上未监听，已自动回滚到旧规则${N}"
    else
      echo -e "${R}应用后 sshd 在 ${ssh_port} 上未监听，但你未启用回滚守护，请尽快人工处理${N}"
    fi
    pause_screen
    return 1
  fi

  if ! ip4_save_rules; then
    echo -e "${Y}规则已生效，但持久化失败，重启后可能丢失${N}"
  fi

  echo ""
  echo -e "${G}IPv4 防火墙已启用${N}"

  # 启动延时回滚守护
  if [ "$rb_choice" = "y" ] && [ -n "$backup_rules" ]; then
    rb_pid=$(schedule_iptables_rollback "$rb_seconds" "$backup_rules" "")
    if [ -n "$rb_pid" ]; then
      echo -e "  ${Y}延时回滚守护已启动 (PID ${rb_pid})，${rb_seconds}s 后自动恢复旧规则${N}"
      echo -e "  ${B}请在 ${rb_seconds} 秒内开新终端验证 SSH 可登录，然后执行：${N}"
      echo -e "    ${C}kill ${rb_pid} && rm -f ${backup_rules}${N}  ${D}# 取消回滚${N}"
      echo -e "  ${D}（也可以直接等待 ${rb_seconds}s 让规则被自动撤销）${N}"
    fi
  fi
  pause_screen
}

ip4_open_port(){
  local proto_choice protos="" port proto changed=0

  echo ""
  echo -e "  ${B}${C}开放端口${N}"
  render_divider
  render_menu_item 1 "TCP"
  render_menu_item 2 "UDP"
  render_menu_item 3 "TCP + UDP (都开)"
  render_menu_item 0 "返回"
  render_divider
  read -p "  选择协议: " proto_choice

  case "$proto_choice" in
    1) protos="tcp" ;;
    2) protos="udp" ;;
    3) protos="tcp udp" ;;
    0) return 0 ;;
    *)
      notify_invalid_choice
      return 0
      ;;
  esac

  read -p "  端口号 (1-65535): " port
  if ! validate_port "$port"; then
    echo -e "${R}端口必须是 1-65535 的数字${N}"
    pause_screen
    return 1
  fi

  for proto in $protos; do
    if iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
      echo -e "  ${Y}${port}/${proto} 已放行，跳过${N}"
    else
      iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT
      echo -e "  ${G}已放行 ${port}/${proto}${N}"
      changed=1
    fi
  done

  if [ "$changed" -eq 1 ]; then
    if ! ip4_save_rules; then
      echo -e "${Y}持久化失败${N}"
    fi
  fi
  pause_screen
}

ip4_close_port(){
  local proto_choice protos="" port ssh_port confirm proto removed=0

  echo ""
  echo -e "  ${B}${C}关闭端口${N}"
  render_divider
  render_menu_item 1 "TCP"
  render_menu_item 2 "UDP"
  render_menu_item 3 "TCP + UDP (都关)"
  render_menu_item 0 "返回"
  render_divider
  read -p "  选择协议: " proto_choice

  case "$proto_choice" in
    1) protos="tcp" ;;
    2) protos="udp" ;;
    3) protos="tcp udp" ;;
    0) return 0 ;;
    *)
      notify_invalid_choice
      return 0
      ;;
  esac

  read -p "  要关闭的端口号 (1-65535): " port

  if ! validate_port "$port"; then
    echo -e "${R}端口必须是 1-65535 的数字${N}"
    pause_screen
    return 1
  fi

  ssh_port=$(ip6_detect_ssh_port)
  if [ "$port" = "$ssh_port" ] && printf '%s' "$protos" | grep -qw tcp; then
    echo ""
    echo -e "  ${R}${B}严重警告：${port}/tcp 是当前 SSH 端口${N}"
    echo -e "  ${R}${B}关闭后你的 IPv4 SSH 会立刻断开${N}"
    read -p "  确认继续？输入大写 YES 才继续: " confirm
    if [ "$confirm" != "YES" ]; then
      echo -e "  已取消"
      sleep 1
      return 0
    fi
  fi

  for proto in $protos; do
    while iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; do
      iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT
      echo -e "  ${G}已删除 ${port}/${proto}${N}"
      removed=$((removed + 1))
    done
  done

  if [ "$removed" -eq 0 ]; then
    echo -e "  ${Y}端口 ${port} 在所选协议下没有放行规则${N}"
  else
    if ! ip4_save_rules; then
      echo -e "${Y}持久化失败${N}"
    fi
  fi
  pause_screen
}

ip4_emergency_disable(){
  local confirm confirm2

  echo ""
  echo -e "  ${R}${B}紧急放行（关闭 v4 防火墙）${N}"
  render_divider
  echo "  执行后："
  echo "    - 清空所有 IPv4 INPUT 规则"
  echo "    - 默认策略改回 ACCEPT"
  echo "    - v4 入站回到完全裸奔状态"
  echo ""

  read -p "  确认？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi
  read -p "  再次确认（输入大写 YES 继续）: " confirm2
  if [ "$confirm2" != "YES" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  iptables -P INPUT ACCEPT
  iptables -F INPUT
  if ! ip4_save_rules; then
    echo -e "${Y}持久化失败${N}"
  fi

  echo ""
  echo -e "${Y}已关闭 v4 防火墙（INPUT=ACCEPT 且规则清空）${N}"
  pause_screen
}

# ─── Docker 管理（轻量补充，深度管理请用 1Panel） ────
require_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    echo ""
    echo -e "${R}Docker 未安装${N}"
    echo -e "${D}建议通过 1Panel 或官方脚本安装：${C}bash <(curl -fsSL https://get.docker.com)${N}"
    pause_screen
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo ""
    echo -e "${R}Docker 守护进程未运行${N}"
    echo -e "${D}尝试：${C}systemctl start docker${N}"
    pause_screen
    return 1
  fi
  return 0
}

# 选一个容器（含已停止），将容器 ID 输出到 stdout，UI 输出到 stderr
select_docker_container(){
  local prompt_label="${1:-请选择容器}"
  local rows=()
  local row id name status image input

  while IFS= read -r row; do
    [ -n "$row" ] && rows+=("$row")
  done < <(docker ps -a --format '{{.ID}}'$'\t''{{.Names}}'$'\t''{{.Status}}'$'\t''{{.Image}}' 2>/dev/null)

  if [ ${#rows[@]} -eq 0 ]; then
    echo "" >&2
    echo -e "  ${Y}没有任何容器${N}" >&2
    return 1
  fi

  {
    echo ""
    echo -e "  ${B}${C}${prompt_label}${N}"
    printf "    %-3s  %-12s  %-22s  %-26s  %s\n" "#" "ID" "NAME" "STATUS" "IMAGE"
    local i=1 r
    for r in "${rows[@]}"; do
      IFS=$'\t' read -r id name status image <<<"$r"
      printf "    %-3s  %-12s  %-22s  %-26s  %s\n" "$i" "${id:0:12}" "${name:0:22}" "${status:0:26}" "$image"
      i=$((i + 1))
    done
  } >&2

  read -p "  序号 (0=取消): " input >&2
  if [ -z "$input" ] || [ "$input" = "0" ]; then
    return 1
  fi
  if ! [[ "$input" =~ ^[0-9]+$ ]] || [ "$input" -lt 1 ] || [ "$input" -gt ${#rows[@]} ]; then
    echo -e "${R}序号无效${N}" >&2
    return 1
  fi
  IFS=$'\t' read -r id _ _ _ <<<"${rows[$((input - 1))]}"
  printf '%s' "$id"
  return 0
}

docker_list_containers(){
  if ! require_docker; then return 1; fi
  echo ""
  echo -e "  ${B}${C}容器列表（含已停止）${N}"
  render_divider
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' || true
  pause_screen
}

docker_show_stats(){
  if ! require_docker; then return 1; fi
  echo ""
  echo -e "${Y}按 Ctrl+C 退出实时监控${N}"
  echo ""
  docker stats || true
}

docker_show_disk(){
  if ! require_docker; then return 1; fi
  echo ""
  echo -e "  ${B}${C}Docker 磁盘占用${N}"
  render_divider
  docker system df -v 2>/dev/null || docker system df || true
  pause_screen
}

docker_prune(){
  local confirm
  if ! require_docker; then return 1; fi

  echo ""
  echo -e "  ${B}${C}清理无用资源${N}"
  render_divider
  echo "  执行 ${C}docker system prune -f${N} 后会清理："
  echo "    - 已停止的容器"
  echo "    - 没有任何容器使用的网络"
  echo "    - 悬空 (dangling) 镜像"
  echo "    - 构建缓存"
  echo ""
  echo -e "  ${D}不会清理：数据卷、运行中的容器、有 tag 的未使用镜像${N}"
  echo ""
  echo -e "${Y}当前占用：${N}"
  docker system df 2>/dev/null || true
  echo ""
  read -p "  确认清理？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi
  docker system prune -f || true
  pause_screen
}

docker_operate_container(){
  local id name status choice

  if ! require_docker; then return 1; fi

  id=$(select_docker_container "选择要操作的容器") || return 0
  if [ -z "$id" ]; then
    return 0
  fi

  while true; do
    name=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's|^/||')
    status=$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null)

    if [ -z "$name" ]; then
      echo -e "${R}容器已不存在${N}"
      pause_screen
      return 0
    fi

    render_section_header "容器操作"
    echo -e "  ${L}│${N}  容器  ${D}·${N}  ${C}${name}${N}  ${D}(${id:0:12})${N}"
    echo -e "  ${L}│${N}  状态  ${D}·${N}  ${C}${status}${N}"
    render_divider
    render_menu_item 1 "查看实时日志 (tail -f)"
    render_menu_item 2 "重启"
    render_menu_item 3 "停止"
    render_menu_item 4 "启动"
    render_menu_item 5 "进入容器 shell"
    render_menu_item 0 "返回"
    render_divider
    read -p "  请输入序号: " choice
    case "$choice" in
      1)
        echo ""
        echo -e "${Y}按 Ctrl+C 退出日志${N}"
        echo ""
        docker logs -f --tail 200 "$id" 2>&1 || true
        ;;
      2)
        if docker restart "$id" >/dev/null 2>&1; then
          echo -e "${G}已重启${N}"
        else
          echo -e "${R}重启失败${N}"
        fi
        sleep 1
        ;;
      3)
        if docker stop "$id" >/dev/null 2>&1; then
          echo -e "${G}已停止${N}"
        else
          echo -e "${R}停止失败${N}"
        fi
        sleep 1
        ;;
      4)
        if docker start "$id" >/dev/null 2>&1; then
          echo -e "${G}已启动${N}"
        else
          echo -e "${R}启动失败${N}"
        fi
        sleep 1
        ;;
      5)
        echo ""
        echo -e "${Y}进入容器，输入 ${C}exit${Y} 退出${N}"
        echo ""
        if ! docker exec -it "$id" /bin/bash 2>/dev/null; then
          if ! docker exec -it "$id" /bin/sh; then
            echo -e "${R}进入失败（容器内可能没有 sh / bash，或容器未运行）${N}"
            pause_screen
          fi
        fi
        ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

show_docker_menu(){
  if ! require_root; then return 1; fi

  while true; do
    local docker_ver running_count total_count
    if command -v docker >/dev/null 2>&1; then
      docker_ver=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
      if docker info >/dev/null 2>&1; then
        running_count=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
        total_count=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')
      else
        running_count=""
        total_count=""
      fi
    else
      docker_ver=""
    fi

    render_section_header "Docker 管理"
    if [ -z "$docker_ver" ]; then
      echo -e "  ${L}│${N}  Docker  ${D}·${N}  ${Y}未安装${N}"
      echo -e "  ${L}│${N}  ${D}            建议用 1Panel 安装 Docker，本菜单仅作日常补充${N}"
    elif [ -z "$running_count" ]; then
      echo -e "  ${L}│${N}  Docker  ${D}·${N}  ${C}v${docker_ver}${N}  ${R}(守护进程未运行)${N}"
    else
      echo -e "  ${L}│${N}  Docker  ${D}·${N}  ${C}v${docker_ver}${N}"
      echo -e "  ${L}│${N}  容器    ${D}·${N}  ${G}${running_count}${N} 运行中 / ${C}${total_count}${N} 总计"
    fi
    echo -e "  ${L}│${N}  说明    ${D}·${N}  ${D}轻量补充，深度管理请用 1Panel${N}"
    render_divider
    render_menu_item 1 "容器列表"
    render_menu_item 2 "实时资源 (docker stats)"
    render_menu_item 3 "容器操作 (日志/重启/停止/启动/进入)"
    render_menu_item 4 "磁盘占用 (docker system df)"
    render_menu_item 5 "清理无用资源 (docker system prune)"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice
    case "$choice" in
      1) docker_list_containers ;;
      2) docker_show_stats ;;
      3) docker_operate_container ;;
      4) docker_show_disk ;;
      5) docker_prune ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

create_regular_user(){
  local username=""
  local home_dir=""
  local copy_choice=""

  if ! require_root; then
    return 1
  fi

  echo ""
  username=$(prompt_for_linux_username "  请输入要创建的普通用户名: ")
  if [ -z "$username" ]; then
    echo -e "${R}用户名读取失败${N}"
    pause_screen
    return 1
  fi

  if id "$username" >/dev/null 2>&1; then
    echo -e "${Y}用户 ${C}$username${N}${Y} 已存在，跳过创建${N}"
    pause_screen
    return 0
  fi

  echo -e "${Y}==> 开始创建用户 ${C}$username${N}${Y}，接下来会进入 adduser 交互流程...${N}"
  if ! adduser "$username"; then
    echo ""
    echo -e "${R}用户创建失败，请检查上方输出${N}"
    pause_screen
    return 1
  fi

  # 如果 root 有 authorized_keys，询问是否拷贝给新用户（密钥登录场景双保险）
  if [ -s /root/.ssh/authorized_keys ]; then
    home_dir=$(getent passwd "$username" | cut -d: -f6)
    if [ -n "$home_dir" ] && [ -d "$home_dir" ]; then
      echo ""
      echo -e "  ${Y}检测到 /root/.ssh/authorized_keys 存在${N}"
      read -p "  是否将 root 的 SSH 公钥复制给 ${username}？(Y/n): " copy_choice
      if [ "$copy_choice" != "n" ] && [ "$copy_choice" != "N" ]; then
        mkdir -p "$home_dir/.ssh"
        if cp /root/.ssh/authorized_keys "$home_dir/.ssh/authorized_keys"; then
          chmod 700 "$home_dir/.ssh"
          chmod 600 "$home_dir/.ssh/authorized_keys"
          chown -R "$username:$username" "$home_dir/.ssh"
          echo -e "  ${G}已复制公钥到 ${C}${home_dir}/.ssh/authorized_keys${N}"
        else
          echo -e "  ${R}公钥复制失败，请稍后手动处理${N}"
        fi
      else
        echo -e "  ${D}已跳过公钥复制${N}"
      fi
    fi
  fi

  echo ""
  echo -e "${G}用户 ${C}$username${N}${G} 创建完成${N}"
  pause_screen
}

add_user_to_sudo_group(){
  local username=""

  if ! require_root; then
    return 1
  fi

  echo ""
  username=$(prompt_for_linux_username "  请输入要加入 sudo 组的用户名: ")
  if [ -z "$username" ]; then
    echo -e "${R}用户名读取失败${N}"
    pause_screen
    return 1
  fi

  if ! id "$username" >/dev/null 2>&1; then
    echo -e "${R}用户 ${C}$username${N}${R} 不存在${N}"
    pause_screen
    return 1
  fi

  if ! getent group sudo >/dev/null 2>&1; then
    echo -e "${R}系统中不存在 sudo 组${N}"
    pause_screen
    return 1
  fi

  if id -nG "$username" | tr ' ' '\n' | grep -Fxq sudo; then
    echo -e "${Y}用户 ${C}$username${N}${Y} 已经在 sudo 组中${N}"
    pause_screen
    return 0
  fi

  if ! usermod -aG sudo "$username"; then
    echo -e "${R}加入 sudo 组失败，请检查上方输出${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${G}已将 ${C}$username${N}${G} 加入 sudo 组${N}"
  echo -e "  ${Y}提示：${N} 新的组权限通常需要重新登录后才会完全生效"
  pause_screen
}

test_user_login(){
  local username=""

  if ! require_root; then
    return 1
  fi

  echo ""
  username=$(prompt_for_linux_username "  请输入要测试登录的用户名: ")
  if [ -z "$username" ]; then
    echo -e "${R}用户名读取失败${N}"
    pause_screen
    return 1
  fi

  if ! id "$username" >/dev/null 2>&1; then
    echo -e "${R}用户 ${C}$username${N}${R} 不存在${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 即将切换到 ${C}$username${N}${Y} 的登录环境${N}"
  echo -e "  输入 ${B}exit${N} 返回当前菜单"
  echo ""

  if su - "$username"; then
    echo ""
    echo -e "${G}已返回当前菜单，用户切换流程正常${N}"
  else
    echo ""
    echo -e "${R}su - $username 执行失败，请检查密码、shell 或 PAM 配置${N}"
  fi

  pause_screen
}

configure_ssh_port(){
  local ssh_port=""
  local confirm=""
  local server_ip=""
  local suggested_ssh_port=""
  local current_ssh_port=""

  if ! require_root; then
    return 1
  fi

  echo ""
  current_ssh_port=$(get_current_ssh_port)
  suggested_ssh_port=$(generate_random_high_port "$current_ssh_port")

  while true; do
    read -p "  新 SSH 端口 (${suggested_ssh_port}): " ssh_port
    ssh_port="${ssh_port:-$suggested_ssh_port}"
    if ! validate_port "$ssh_port"; then
      echo -e "${R}端口必须是 1-65535 的数字${N}"
      continue
    fi
    if [ "$ssh_port" = "$current_ssh_port" ]; then
      echo -e "${Y}新端口与当前 SSH 端口相同，无需修改${N}"
      sleep 1
      return 0
    fi
    if check_port_in_use "$ssh_port"; then
      echo -e "${R}端口 ${ssh_port} 已被占用，请换一个${N}"
      continue
    fi
    break
  done

  echo -e "${Y}警告：${N} 修改后请确认安全组（云平台）已放行新端口。"
  read -p "  确认将 SSH 端口修改为 ${ssh_port} 并重启 SSH 服务？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  # 先确保密码登录可用（防止云镜像 sshd_config.d 默认禁用密码登录），
  # 否则改完端口、关掉旧会话后普通用户就连不上了。
  echo ""
  if ! ensure_password_auth_enabled; then
    echo -e "${R}密码登录配置失败，已中止 SSH 端口修改${N}"
    pause_screen
    return 1
  fi

  allow_tcp_port_in_firewall "$ssh_port"

  if apply_sshd_setting "Port" "$ssh_port" "SSH 端口已更新并重启服务"; then
    cleanup_old_backups "${SSHD_CONFIG_PATH}.bak.*" 5

    # iptables 兜底：如果旧端口在 INPUT 链有显式 ACCEPT 规则
    # （常见于搬瓦工预装 iptables-persistent 的镜像），给新端口加同样的规则
    if command -v iptables >/dev/null 2>&1 \
       && iptables -C INPUT -p tcp --dport "$current_ssh_port" -j ACCEPT 2>/dev/null; then
      if ! iptables -C INPUT -p tcp --dport "$ssh_port" -j ACCEPT 2>/dev/null; then
        if iptables -I INPUT -p tcp --dport "$ssh_port" -j ACCEPT 2>/dev/null; then
          echo -e "  ${G}已在 iptables INPUT 链放行 ${ssh_port}/tcp${N}"
          if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
          elif [ -d /etc/iptables ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
          fi
        else
          echo -e "  ${Y}iptables 规则追加失败，请手动执行：iptables -I INPUT -p tcp --dport ${ssh_port} -j ACCEPT${N}"
        fi
      fi
    fi

    server_ip=$(detect_primary_ipv4)
    server_ip="${server_ip:-你的IP}"
    echo -e "  新登录方式: ${C}ssh 用户名@${server_ip} -p ${ssh_port}${N}"
    echo -e "  配置文件: ${C}$SSHD_CONFIG_PATH${N}"
    echo ""
    echo -e "  ${B}${R}【强烈建议】${N}${B}保留当前 SSH 窗口！${N}"
    echo -e "  ${B}先开新终端用普通用户 + 新端口验证可登录，再关闭当前窗口。${N}"
    pause_screen
  fi
}

disable_root_ssh_login(){
  local confirm=""
  local sudo_users=""
  local user=""
  local home_dir=""
  local has_key=0
  local has_passwd=0
  local can_login_user=""
  local pwd_auth_effective=""

  if ! require_root; then
    return 1
  fi

  echo ""
  echo -e "${Y}警告：${N} 请先确认普通用户已经可以正常登录并执行 sudo。"
  read -p "  确认禁止 root 通过 SSH 登录？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  # 防呆 1：保证密码登录可用（幂等，已开启就跳过）
  echo ""
  if ! ensure_password_auth_enabled; then
    echo -e "${R}密码登录配置失败，已中止禁用 root 登录${N}"
    pause_screen
    return 1
  fi

  # 防呆 2：必须至少有 1 个非 root 的 sudo 用户能 SSH 登录
  pwd_auth_effective=$(get_effective_sshd_value PasswordAuthentication)
  sudo_users=$(getent group sudo 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | grep -v '^root$' | grep -v '^$')
  if [ -z "$sudo_users" ]; then
    echo ""
    echo -e "${R}没有发现非 root 的 sudo 组成员，禁用 root 登录会导致服务器变砖${N}"
    echo -e "${Y}请先在管理员设置中执行 1)创建普通用户 + 2)加入 sudo 组${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "  ${B}检查可登录的非 root sudo 用户...${N}"
  while IFS= read -r user; do
    [ -z "$user" ] && continue
    has_key=0
    has_passwd=0
    home_dir=$(getent passwd "$user" | cut -d: -f6)
    if [ -n "$home_dir" ] && [ -s "$home_dir/.ssh/authorized_keys" ]; then
      has_key=1
    fi
    if [ "$pwd_auth_effective" = "yes" ] \
       && passwd -S "$user" 2>/dev/null | awk '{exit !($2 == "P")}'; then
      has_passwd=1
    fi
    if [ "$has_key" = "1" ] || [ "$has_passwd" = "1" ]; then
      can_login_user="$user"
      local marks=""
      [ "$has_passwd" = "1" ] && marks="${marks}密码 "
      [ "$has_key" = "1" ] && marks="${marks}公钥 "
      echo -e "    ${G}✓${N}  ${C}${user}${N}  ${D}(${marks% })${N}"
    else
      echo -e "    ${R}✗${N}  ${C}${user}${N}  ${D}(未设密码且无 authorized_keys)${N}"
    fi
  done <<EOF
$sudo_users
EOF

  if [ -z "$can_login_user" ]; then
    echo ""
    echo -e "${R}没有任何非 root sudo 用户能 SSH 登录，已中止${N}"
    echo -e "${Y}修复建议：${N}"
    echo -e "  - 给某个 sudo 用户设密码：${C}passwd <用户名>${N}"
    echo -e "  - 或将公钥放到 ${C}~<用户名>/.ssh/authorized_keys${N}"
    pause_screen
    return 1
  fi
  echo -e "  ${G}通过：至少 ${C}${can_login_user}${G} 可登录${N}"

  if apply_sshd_setting "PermitRootLogin" "no" "root SSH 登录已禁用"; then
    cleanup_old_backups "${SSHD_CONFIG_PATH}.bak.*" 5
    echo -e "  当前设置: ${C}PermitRootLogin no${N}"
    echo -e "  配置文件: ${C}$SSHD_CONFIG_PATH${N}"
    echo ""
    echo -e "  ${B}${R}【强烈建议】${N}${B}保留当前 SSH 窗口！${N}"
    echo -e "  ${B}先开新终端用普通用户登录，并验证 ${C}sudo -i${N}${B} 可用，再关闭当前窗口。${N}"
    pause_screen
  fi
}

enable_root_ssh_login(){
  local confirm=""

  if ! require_root; then
    return 1
  fi

  echo ""
  echo -e "${Y}警告：${N} 恢复 root 登录后建议继续使用密钥登录，避免暴力破解。"
  read -p "  确认恢复 root 通过 SSH 登录？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  if apply_sshd_setting "PermitRootLogin" "yes" "root SSH 登录已恢复"; then
    cleanup_old_backups "${SSHD_CONFIG_PATH}.bak.*" 5
    echo -e "  当前设置: ${C}PermitRootLogin yes${N}"
    echo -e "  配置文件: ${C}$SSHD_CONFIG_PATH${N}"
    pause_screen
  fi
}

configure_passwordless_sudo(){
  local username=""
  local dropin_path=""
  local tmp_file=""

  if ! require_root; then
    return 1
  fi

  echo ""
  username=$(prompt_for_linux_username "  请输入要配置 sudo 免密的用户名: ")
  if [ -z "$username" ]; then
    echo -e "${R}用户名读取失败${N}"
    pause_screen
    return 1
  fi

  if ! id "$username" >/dev/null 2>&1; then
    echo -e "${R}用户 ${C}$username${N}${R} 不存在${N}"
    pause_screen
    return 1
  fi

  if ! command -v visudo >/dev/null 2>&1; then
    echo -e "${R}未找到 visudo，无法安全校验 sudoers 规则${N}"
    pause_screen
    return 1
  fi

  if ! grep -Eq '^[[:space:]]*[@#]includedir[[:space:]]+/etc/sudoers\.d([[:space:]]|$)' /etc/sudoers; then
    echo -e "${R}当前 /etc/sudoers 未启用 @includedir/#includedir /etc/sudoers.d，无法安全写入免密规则${N}"
    pause_screen
    return 1
  fi

  mkdir -p "$SUDOERS_DROPIN_DIR"
  dropin_path="${SUDOERS_DROPIN_DIR}/${username}-nopasswd"
  tmp_file=$(mktemp)

  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$username" > "$tmp_file"
  chmod 440 "$tmp_file"

  if ! visudo -cf "$tmp_file" >/dev/null 2>&1; then
    rm -f "$tmp_file"
    echo -e "${R}sudoers 规则语法校验失败${N}"
    pause_screen
    return 1
  fi

  if ! cp "$tmp_file" "$dropin_path"; then
    rm -f "$tmp_file"
    echo -e "${R}sudo 免密规则写入失败${N}"
    pause_screen
    return 1
  fi
  chmod 440 "$dropin_path"
  rm -f "$tmp_file"

  if ! visudo -cf /etc/sudoers >/dev/null 2>&1; then
    rm -f "$dropin_path"
    echo -e "${R}sudoers 总配置校验失败，已回滚${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${G}已为 ${C}$username${N}${G} 配置 sudo 免密${N}"
  echo -e "  规则文件: ${C}$dropin_path${N}"
  echo -e "  现在可直接使用 ${C}sudo -i${N}"
  pause_screen
}

remove_passwordless_sudo(){
  local username=""
  local dropin_path=""

  if ! require_root; then
    return 1
  fi

  echo ""
  username=$(prompt_for_linux_username "  请输入要移除 sudo 免密的用户名: ")
  if [ -z "$username" ]; then
    echo -e "${R}用户名读取失败${N}"
    pause_screen
    return 1
  fi

  dropin_path="${SUDOERS_DROPIN_DIR}/${username}-nopasswd"
  if [ ! -f "$dropin_path" ]; then
    echo -e "${Y}未找到 ${C}$dropin_path${N}${Y}，无需移除${N}"
    pause_screen
    return 0
  fi

  if ! rm -f "$dropin_path"; then
    echo -e "${R}移除失败${N}"
    pause_screen
    return 1
  fi

  if command -v visudo >/dev/null 2>&1 && ! visudo -cf /etc/sudoers >/dev/null 2>&1; then
    echo -e "${Y}移除后 /etc/sudoers 校验有告警，请人工检查${N}"
  fi

  echo ""
  echo -e "${G}已移除 ${C}$username${N}${G} 的 sudo 免密规则${N}"
  pause_screen
}

update_system_packages(){
  if ! require_root; then return 1; fi
  echo ""
  echo -e "${Y}==> 更新软件源...${N}"
  if ! apt update; then
    echo ""
    echo -e "${R}apt update 执行失败，请检查上方输出${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 升级系统软件包...${N}"
  if ! apt upgrade -y; then
    echo ""
    echo -e "${R}apt upgrade 执行失败，请检查上方输出${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${G}系统更新完成${N}"
  pause_screen
}

enable_auto_updates(){
  if ! require_root; then return 1; fi
  echo ""
  echo -e "${Y}==> 检查 unattended-upgrades 是否已安装...${N}"
  if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    if ! apt install -y unattended-upgrades; then
      echo ""
      echo -e "${R}unattended-upgrades 安装失败${N}"
      pause_screen
      return 1
    fi
  fi

  echo ""
  echo -e "${Y}提示：${N} 如果出现交互界面，请选择 ${B}Yes${N}。"
  echo ""
  if ! dpkg-reconfigure unattended-upgrades; then
    echo ""
    echo -e "${R}自动更新配置未完成，请检查上方输出${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${G}自动更新配置完成${N}"
  pause_screen
}

disable_auto_updates(){
  local confirm=""

  if ! require_root; then
    return 1
  fi

  if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    echo ""
    echo -e "${Y}unattended-upgrades 未安装，无需禁用${N}"
    pause_screen
    return 0
  fi

  echo ""
  read -p "  是否同时卸载 unattended-upgrades 软件包？(y/N): " confirm

  echo -e "${Y}==> 关闭自动更新...${N}"
  systemctl disable --now unattended-upgrades.service >/dev/null 2>&1 || true
  systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

  if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    echo -e "${Y}==> 卸载 unattended-upgrades...${N}"
    if ! apt-get remove --purge -y unattended-upgrades; then
      echo -e "${R}卸载失败，请检查上方输出${N}"
      pause_screen
      return 1
    fi
  fi

  echo ""
  echo -e "${G}自动更新已禁用${N}"
  pause_screen
}

configure_system_time(){
  if ! require_root; then return 1; fi
  echo ""
  echo -e "${Y}==> 设置时区为 ${SYSTEM_TIMEZONE}...${N}"
  if ! timedatectl set-timezone "$SYSTEM_TIMEZONE"; then
    echo ""
    echo -e "${R}时区设置失败${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 启用自动时间同步...${N}"
  if ! timedatectl set-ntp true; then
    echo ""
    echo -e "${R}NTP 自动同步启用失败${N}"
    pause_screen
    return 1
  fi

  echo ""
  timedatectl
  pause_screen
}

install_basic_tools(){
  if ! require_root; then return 1; fi
  echo ""
  echo -e "${Y}==> 安装基础工具...${N}"
  echo -e "  ${C}$BASIC_TOOLS_PACKAGES${N}"
  if ! apt install -y $BASIC_TOOLS_PACKAGES; then
    echo ""
    echo -e "${R}基础工具安装失败，请检查上方输出${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${G}基础工具安装完成${N}"
  pause_screen
}

render_node_detail(){
  local type="$1"
  local node_type tag mode mode_label ip port sni
  node_type=$(get_node_value "$type" Type 2>/dev/null || echo "$type")
  tag=$(get_node_value "$type" Tag 2>/dev/null || echo "$type")
  mode=$(get_node_value "$type" Mode 2>/dev/null || echo ipv4)
  mode_label=$(describe_install_mode "$mode")
  ip=$(get_node_value "$type" IP 2>/dev/null || true)
  port=$(get_node_value "$type" Port 2>/dev/null || true)
  sni=$(get_node_value "$type" SNI 2>/dev/null || true)

  case "$node_type" in
    reality)
      local uuid pubk
      uuid=$(get_node_value "$type" UUID 2>/dev/null || true)
      pubk=$(get_node_value "$type" PublicKey 2>/dev/null || true)
      echo -e "  类型      : ${C}Reality${N}  Tag : ${C}${tag}${N}"
      echo -e "  UUID      : ${C}${uuid:-未知}${N}"
      echo -e "  PublicKey : ${C}${pubk:-未知}${N}"
      echo -e "  模式      : ${C}${mode_label}${N}"
      echo -e "  IP        : ${C}${ip:-未知}${N}"
      echo -e "  端口      : ${C}${port:-未知}${N} ${D}(TCP)${N}"
      echo -e "  SNI       : ${C}${sni:-未知}${N}"
      ;;
    hy2)
      local pwd_v cert_src obfs_t up_v down_v hop_v hop_mode_v hop_start_v hop_end_v
      pwd_v=$(get_node_value "$type" Password 2>/dev/null || true)
      cert_src=$(get_node_value "$type" CertSource 2>/dev/null || true)
      obfs_t=$(get_node_value "$type" Obfs 2>/dev/null || echo none)
      up_v=$(get_node_value "$type" UpMbps 2>/dev/null || true)
      down_v=$(get_node_value "$type" DownMbps 2>/dev/null || true)
      hop_v=$(get_node_value "$type" PortHop 2>/dev/null || echo 0)
      hop_mode_v=$(get_node_value "$type" PortHopMode 2>/dev/null || true)
      hop_start_v=$(get_node_value "$type" PortHopStart 2>/dev/null || true)
      hop_end_v=$(get_node_value "$type" PortHopEnd 2>/dev/null || true)
      echo -e "  类型      : ${C}Hysteria2${N}  Tag : ${C}${tag}${N}"
      echo -e "  Password  : ${C}${pwd_v:-未知}${N}"
      echo -e "  证书      : ${C}${cert_src:-未知}${N}"
      echo -e "  Obfs      : ${C}${obfs_t}${N}"
      echo -e "  模式      : ${C}${mode_label}${N}"
      echo -e "  IP        : ${C}${ip:-未知}${N}"
      echo -e "  端口      : ${C}${port:-未知}${N} ${D}(UDP)${N}"
      echo -e "  SNI       : ${C}${sni:-未知}${N}"
      if [ -n "$up_v" ] && [ -n "$down_v" ]; then
        echo -e "  带宽限制  : ${C}上 ${up_v} / 下 ${down_v} Mbps${N}"
      else
        echo -e "  带宽限制  : ${Y}未限制${N} ${D}(建议设置)${N}"
      fi
      if [ "$hop_v" = "1" ] && [ -n "$hop_start_v" ] && [ -n "$hop_end_v" ]; then
        echo -e "  端口跳跃  : ${C}${hop_start_v}-${hop_end_v}${N} ${D}(${hop_mode_v} 模式)${N}"
      else
        echo -e "  端口跳跃  : ${D}未启用${N}"
      fi
      ;;
  esac
}

show_client_link(){
  local target current_link ipv6_link

  echo ""
  if ! is_singbox_installed; then
    echo -e "  ${R}sing-box 尚未安装${N}"
    pause_screen
    return 1
  fi
  if [ "$(count_installed_nodes)" -eq 0 ]; then
    echo -e "  ${R}未发现节点，请先创建节点${N}"
    pause_screen
    return 1
  fi

  target=$(select_node_interactive "请选择要查看的节点")
  if [ -z "$target" ]; then
    echo -e "${R}选择无效${N}"
    pause_screen
    return 1
  fi

  render_node_detail "$target"

  current_link=$(build_link_for_node "$target" 2>/dev/null || true)
  ipv6_link=$(build_dualstack_ipv6_link_for_node "$target" 2>/dev/null || true)
  if [ -n "$current_link" ]; then
    set_node_value "$target" Link "$current_link"
  fi

  echo ""
  echo -e "  ${B}客户端链接：${N}"
  echo -e "  ${G}${current_link:-未生成}${N}"
  print_qrcode "${current_link:-}"
  if [ -n "$ipv6_link" ]; then
    echo ""
    echo -e "  ${B}IPv6 客户端链接：${N}"
    echo -e "  ${G}${ipv6_link}${N}"
    print_qrcode "$ipv6_link"
  fi
  pause_screen
}

modify_reality_params(){
  local new_port="" new_sni="" new_uuid="" regen_keypair="n"
  local new_pri="" new_pub="" keypair="" new_short_id=""
  local cur_port cur_sni cur_uuid backup_path="" confirm

  if ! require_root; then return 1; fi
  if ! require_singbox_installed; then return 1; fi
  if ! node_installed reality; then
    echo ""
    echo -e "${R}未发现 Reality 节点信息${N}"
    pause_screen
    return 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到配置文件：$CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  cur_port=$(get_node_value reality Port 2>/dev/null || true)
  cur_sni=$(get_node_value reality SNI 2>/dev/null || true)
  cur_uuid=$(get_node_value reality UUID 2>/dev/null || true)

  echo ""
  echo -e "  ${B}${C}修改 Reality 节点参数${N}  ${D}直接回车保留当前值${N}"
  render_divider

  while true; do
    read -p "  端口 (${cur_port:-当前未知}): " new_port
    new_port="${new_port:-$cur_port}"
    if validate_port "$new_port"; then break; fi
    echo -e "${R}端口必须是 1-65535 的数字${N}"
  done

  while true; do
    read -p "  SNI 域名 (${cur_sni:-当前未知}): " new_sni
    new_sni="${new_sni:-$cur_sni}"
    new_sni=$(sanitize_sni "$new_sni")
    if [ -n "$new_sni" ]; then break; fi
    echo -e "${R}SNI 不能为空${N}"
  done

  read -p "  UUID (回车保留当前 / 输入 new 随机生成新 UUID): " new_uuid
  case "$new_uuid" in
    new|NEW)
      new_uuid=$(cat /proc/sys/kernel/random/uuid)
      echo -e "  ${D}新 UUID：$new_uuid${N}"
      ;;
    "") new_uuid="$cur_uuid" ;;
  esac
  if [ -z "$new_uuid" ]; then
    echo -e "${R}UUID 无效${N}"
    pause_screen
    return 1
  fi

  read -p "  同时重新生成 Reality 密钥对 + ShortID？(y/N): " regen_keypair
  if [ "$regen_keypair" = "y" ] || [ "$regen_keypair" = "Y" ]; then
    echo -e "${Y}==> 生成新密钥对...${N}"
    if ! keypair=$(sing-box generate reality-keypair); then
      echo -e "${R}密钥对生成失败${N}"
      pause_screen
      return 1
    fi
    new_pri=$(echo "$keypair" | grep PrivateKey | awk '{print $2}')
    new_pub=$(echo "$keypair" | grep PublicKey | awk '{print $2}')
    if [ -z "$new_pri" ] || [ -z "$new_pub" ]; then
      echo -e "${R}密钥对解析失败${N}"
      pause_screen
      return 1
    fi
    new_short_id=$(openssl rand -hex 4)
    echo -e "  ${D}新 PublicKey：$new_pub${N}"
    echo -e "  ${D}新 ShortID  ：$new_short_id${N}"
  fi

  echo ""
  echo -e "  将写入：端口 ${C}$new_port${N}  SNI ${C}$new_sni${N}  UUID ${C}$new_uuid${N}"
  if [ -n "$new_pub" ]; then
    echo -e "  PublicKey  : ${C}$new_pub${N}  ${Y}(记得更新客户端 pbk / sid 参数)${N}"
    echo -e "  ShortID    : ${C}$new_short_id${N}"
  fi
  read -p "  确认修改？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  if ! cp "$CONFIG_PATH" "$backup_path"; then
    echo -e "${R}配置备份失败${N}"
    pause_screen
    return 1
  fi

  ensure_jq || { pause_screen; return 1; }

  local jq_filter='(.inbounds[] | select(.tag == "reality-in"))
    |= ( .listen_port = ($port | tonumber)
       | .users[0].uuid = $uuid
       | .tls.server_name = $sni
       | .tls.reality.handshake.server = $sni
       | (if $pri != "" then .tls.reality.private_key = $pri else . end)
       | (if $sid != "" then .tls.reality.short_id = [$sid] else . end))'

  local tmp_file
  tmp_file=$(mktemp)
  # 兜底：函数返回 / 信号中断时清理临时文件（已存在的 rm -f 路径仍保留，trap 仅作保险）
  trap 'rm -f "$tmp_file"' RETURN INT TERM
  if ! jq --arg port "$new_port" --arg sni "$new_sni" --arg uuid "$new_uuid" \
       --arg pri "${new_pri:-}" --arg sid "${new_short_id:-}" \
       "$jq_filter" "$CONFIG_PATH" > "$tmp_file"; then
    rm -f "$tmp_file"
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    echo -e "${R}配置写入失败，已恢复备份${N}"
    pause_screen
    return 1
  fi
  mv "$tmp_file" "$CONFIG_PATH"

  if ! sing-box check -c "$CONFIG_PATH"; then
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    echo ""
    echo -e "${R}配置校验失败，已恢复备份${N}"
    pause_screen
    return 1
  fi
  if ! systemctl restart sing-box; then
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    echo ""
    echo -e "${R}服务重启失败，已恢复备份${N}"
    pause_screen
    return 1
  fi

  set_node_value reality Port "$new_port"
  set_node_value reality SNI "$new_sni"
  set_node_value reality UUID "$new_uuid"
  if [ -n "$new_pub" ]; then
    set_node_value reality PublicKey "$new_pub"
    set_node_value reality PrivateKey "$new_pri"
    set_node_value reality ShortID "$new_short_id"
  fi

  local cur_ip cur_tag final_pub final_sid new_link ipv6_new_link
  cur_ip=$(get_node_value reality IP 2>/dev/null || true)
  cur_tag=$(get_node_value reality Tag 2>/dev/null || echo reality)
  final_pub="${new_pub:-$(get_node_value reality PublicKey 2>/dev/null || true)}"
  final_sid="${new_short_id:-$(get_node_value reality ShortID 2>/dev/null || true)}"
  new_link=$(build_reality_link "$new_uuid" "$cur_ip" "$new_port" "$new_sni" "$final_pub" "$final_sid" "${cur_tag:-reality}" 2>/dev/null || true)
  ipv6_new_link=$(build_dualstack_ipv6_link_for_node reality 2>/dev/null || true)
  [ -n "$new_link" ] && set_node_value reality Link "$new_link"
  if [ -n "$new_port" ] && [ "$new_port" != "$cur_port" ]; then
    local rt_mode_now
    rt_mode_now=$(get_node_value reality Mode 2>/dev/null || echo ipv4)
    # 旧端口先撤、新端口再开（双栈/v6 模式同时处理 v4/v6）
    [ -n "$cur_port" ] && node_revoke_firewall_for_mode "$cur_port" tcp "$rt_mode_now"
    node_apply_firewall_for_mode "$new_port" tcp "$rt_mode_now"
    print_firewall_hint "$new_port" tcp "Reality 节点新端口"
  fi
  cleanup_old_backups "${CONFIG_PATH}.bak.*" 5

  echo ""
  echo -e "${G}Reality 节点参数已更新并重启服务${N}"
  echo -e "  备份文件：${D}$backup_path${N}"
  if [ -n "$new_link" ]; then
    echo ""
    echo -e "  ${B}新客户端链接：${N}"
    echo -e "  ${G}$new_link${N}"
    print_qrcode "$new_link"
  fi
  if [ -n "$ipv6_new_link" ]; then
    echo ""
    echo -e "  ${B}新 IPv6 客户端链接：${N}"
    echo -e "  ${G}$ipv6_new_link${N}"
    print_qrcode "$ipv6_new_link"
  fi
  pause_screen
}

# 节点参数修改 dispatcher（多节点时让用户选择）
modify_node_params(){
  if ! require_root; then return 1; fi
  if ! require_singbox_installed; then return 1; fi
  local count target
  count=$(count_installed_nodes)
  if [ "$count" -eq 0 ]; then
    echo ""
    echo -e "${R}未发现节点，请先创建节点${N}"
    pause_screen
    return 1
  fi
  target=$(select_node_interactive "请选择要修改的节点")
  if [ -z "$target" ]; then
    echo -e "${R}选择无效${N}"
    pause_screen
    return 1
  fi
  local node_type
  node_type=$(get_node_value "$target" Type 2>/dev/null || echo "$target")
  case "$node_type" in
    reality) modify_reality_params ;;
    hy2)     modify_hy2_params ;;
    *)
      echo -e "${R}未知节点类型: $node_type${N}"
      pause_screen
      return 1
      ;;
  esac
}

print_qrcode(){
  local link="$1"

  if [ -z "$link" ]; then
    return 1
  fi

  if ! command -v qrencode >/dev/null 2>&1; then
    echo -e "${Y}==> 未检测到 qrencode，正在安装...${N}"
    if ! apt-get install -y qrencode 2>/dev/null; then
      echo -e "${R}qrencode 安装失败，请手动执行：apt install qrencode${N}"
      return 1
    fi
  fi

  echo ""
  echo -e "  ${B}扫码导入：${N}"
  echo ""
  qrencode -t ANSIUTF8 "$link"
}

apply_tcp_tuning(){
  local region="${1:-us-west}"
  local mem_tier="${2:-2g}"
  local region_label notsent_lowat fin_timeout buffer_max mem_label

  if ! require_root; then return 1; fi

  case "$region" in
    hk)
      region_label="香港"
      notsent_lowat=131072
      fin_timeout=5
      ;;
    jp)
      region_label="日本"
      notsent_lowat=131072
      fin_timeout=5
      ;;
    us-west)
      region_label="美西"
      notsent_lowat=131072
      fin_timeout=10
      ;;
    eu)
      region_label="欧洲"
      notsent_lowat=131072
      fin_timeout=10
      ;;
    *)
      echo -e "${R}未知地区: $region${N}"
      return 1
      ;;
  esac

  case "${region}_${mem_tier}" in
    hk_1g)       buffer_max=16777216  ;;
    hk_2g)       buffer_max=33554432  ;;
    hk_4g)       buffer_max=33554432  ;;
    hk_8g)       buffer_max=67108864  ;;
    jp_1g)       buffer_max=16777216  ;;
    jp_2g)       buffer_max=33554432  ;;
    jp_4g)       buffer_max=67108864  ;;
    jp_8g)       buffer_max=67108864  ;;
    us-west_1g)  buffer_max=25165824  ;;
    us-west_2g)  buffer_max=67108864  ;;
    us-west_4g)  buffer_max=100663296 ;;
    us-west_8g)  buffer_max=134217728 ;;
    eu_1g)       buffer_max=33554432  ;;
    eu_2g)       buffer_max=67108864  ;;
    eu_4g)       buffer_max=134217728 ;;
    eu_8g)       buffer_max=134217728 ;;
    *)
      echo -e "${R}未知组合: ${region}/${mem_tier}${N}"
      return 1
      ;;
  esac

  case "$mem_tier" in
    1g)  mem_label="1GB"  ;;
    2g)  mem_label="2GB"  ;;
    4g)  mem_label="4GB"  ;;
    8g)  mem_label="8GB+" ;;
    *)   mem_label="$mem_tier" ;;
  esac

  echo ""
  echo -e "${Y}==> 写入 ${region_label}/${mem_label} TCP 参数优化配置 (上限 $((buffer_max/1024/1024))M)...${N}"

  cat > "$TCP_TUNING_PATH" <<EOF
# leyili-profile: region=${region} mem_tier=${mem_tier}
# 由 leyili.sh 一键网络优化生成 (${region_label} / ${mem_label})

# --- 拥塞控制 + 调度 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# TFO 客户端+服务端 (RFC 7413)；国内运营商可能干扰 TFO cookie，
# 内核 blackhole 机制会自动退化为普通 TCP，开了不一定有用但不会有害
net.ipv4.tcp_fastopen = 3

# --- 缓冲区 (按地区 BDP 与内存档计算) ---
net.core.rmem_max = ${buffer_max}
net.core.wmem_max = ${buffer_max}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 16384 262144 ${buffer_max}
net.ipv4.tcp_wmem = 16384 262144 ${buffer_max}

# --- 长连接 / 慢启动 / MTU ---
# 防 TCP-in-TCP 隧道 bufferbloat (Cloudflare web server 通用值 + NaiveProxy 推荐)
net.ipv4.tcp_notsent_lowat = ${notsent_lowat}
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_no_pmtu_disc = 0

# --- 连接回收与高并发 ---
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = ${fin_timeout}
net.ipv4.tcp_max_tw_buckets = 65536
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1

# --- 保活 (防中间设备踢空闲连接) ---
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# --- 代理服务器专用 ---
# 不缓存上次连接的 RTT/cwnd 指纹 (面对全球客户端必加)
net.ipv4.tcp_no_metrics_save = 1
# ECN: 2 = 被动接受不主动发起 (RFC 8311 推荐，避开国内运营商对 ECN 标记的误判)
net.ipv4.tcp_ecn = 2
# TIME-WAIT 状态下抑制迷路 RST/重复 FIN 干扰 (RFC 1337)
net.ipv4.tcp_rfc1337 = 1
# 异常连接重试上限 (Alibaba Cloud 推荐 5-10，10≈280s 给翻墙耐心容忍家庭网络抖动)
net.ipv4.tcp_retries2 = 10
# SYN+ACK 重试 (Cloudflare/Red Hat 主流推荐 3≈45s，比默认 5≈63s 更稳健)
net.ipv4.tcp_synack_retries = 3
# 孤儿连接重试 (HAProxy/Nginx 生产标配；默认 8 在高并发下消耗内存，3≈25s 释放)
net.ipv4.tcp_orphan_retries = 3

# --- 临时端口范围 (避开常用服务端口) ---
net.ipv4.ip_local_port_range = 10000 65535
EOF

  echo -e "${Y}==> 应用 sysctl 配置...${N}"
  if ! sysctl -p "$TCP_TUNING_PATH"; then
    echo -e "${R}TCP 参数应用失败，请检查内核兼容性或 sysctl 输出${N}"
    return 1
  fi

  return 0
}

remove_tcp_tuning(){
  local confirm=""

  if ! require_root; then
    return 1
  fi

  if [ ! -f "$TCP_TUNING_PATH" ]; then
    echo ""
    echo -e "${Y}未检测到 TCP 优化配置，无需移除${N}"
    pause_screen
    return 0
  fi

  echo ""
  echo -e "${Y}==> 即将移除 ${C}$TCP_TUNING_PATH${N}${Y}，并恢复默认 qdisc / 拥塞算法${N}"
  read -p "  确认继续？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  rm -f "$TCP_TUNING_PATH"

  sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || true

  echo ""
  echo -e "${G}TCP 优化已移除（部分参数重启后完全复位）${N}"
  pause_screen
}

apply_initcwnd_optimization(){
  local route_line route_spec ip_bin current_route
  local initcwnd_value="${1:-$INITCWND_VALUE}"
  local quiet="${2:-0}"

  if ! require_root; then return 1; fi

  echo ""

  if ! command -v ip &>/dev/null; then
    echo -e "${R}未找到 ip 命令，无法配置 initcwnd${N}"
    [ "$quiet" != "1" ] && pause_screen
    return 1
  fi

  route_line=$(ip route show default 2>/dev/null | head -1)
  if [ -z "$route_line" ]; then
    echo -e "${R}未检测到默认路由，无法自动配置 initcwnd${N}"
    [ "$quiet" != "1" ] && pause_screen
    return 1
  fi

  route_spec=$(printf '%s\n' "$route_line" | awk '{
    sep=""
    for (i = 1; i <= NF; i++) {
      if ($i == "initcwnd" || $i == "initrwnd") {
        i++
        next
      }
      printf "%s%s", sep, $i
      sep=" "
    }
    printf "\n"
  }')
  ip_bin=$(command -v ip 2>/dev/null || echo /sbin/ip)

  echo -e "${Y}==> 当前默认路由:${N} ${C}$route_line${N}"
  echo -e "${Y}==> 应用 initcwnd/initrwnd ${initcwnd_value}...${N}"
  if ! ip route replace $route_spec initcwnd $initcwnd_value initrwnd $initcwnd_value; then
    echo -e "${R}默认路由优化失败，请检查路由权限或当前网络环境${N}"
    [ "$quiet" != "1" ] && pause_screen
    return 1
  fi

  echo -e "${Y}==> 写入 systemd 持久化服务...${N}"
  cat > "$INITCWND_SERVICE_PATH" << EOF
[Unit]
Description=Set TCP initcwnd/initrwnd
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$ip_bin route replace $route_spec initcwnd $initcwnd_value initrwnd $initcwnd_value
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  if ! systemctl daemon-reload; then
    echo -e "${R}systemd 重新加载失败${N}"
    [ "$quiet" != "1" ] && pause_screen
    return 1
  fi

  if ! systemctl enable --now "$(basename "$INITCWND_SERVICE_PATH")"; then
    echo -e "${R}initcwnd 持久化服务启用失败${N}"
    [ "$quiet" != "1" ] && pause_screen
    return 1
  fi

  if [ "$quiet" = "1" ]; then
    return 0
  fi

  current_route=$(ip route show default 2>/dev/null | head -1)
  echo ""
  echo -e "${G}initcwnd 优化已生效${N}"
  echo -e "  当前默认路由: ${C}$current_route${N}"
  if printf '%s\n' "$current_route" | grep -Eq "(^| )initcwnd ${initcwnd_value}( |$)"; then
    echo -e "  initcwnd: ${C}${initcwnd_value}${N}"
  fi
  if printf '%s\n' "$current_route" | grep -Eq "(^| )initrwnd ${initcwnd_value}( |$)"; then
    echo -e "  initrwnd: ${C}${initcwnd_value}${N}"
  fi
  echo -e "  持久化服务: ${C}$(basename "$INITCWND_SERVICE_PATH")${N}"
  pause_screen
}

remove_initcwnd_optimization(){
  local confirm=""
  local service_name
  local route_line route_spec

  if ! require_root; then
    return 1
  fi

  service_name=$(basename "$INITCWND_SERVICE_PATH")
  if [ ! -f "$INITCWND_SERVICE_PATH" ] && ! systemctl cat "$service_name" >/dev/null 2>&1; then
    echo ""
    echo -e "${Y}未检测到 initcwnd 持久化服务，无需移除${N}"
    pause_screen
    return 0
  fi

  echo ""
  read -p "  确认移除 initcwnd 持久化服务并恢复默认路由？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  systemctl disable --now "$service_name" >/dev/null 2>&1 || true
  rm -f "$INITCWND_SERVICE_PATH"
  systemctl daemon-reload >/dev/null 2>&1 || true

  if command -v ip >/dev/null 2>&1; then
    route_line=$(ip route show default 2>/dev/null | head -1)
    if [ -n "$route_line" ]; then
      route_spec=$(printf '%s\n' "$route_line" | awk '{
        sep=""
        for (i = 1; i <= NF; i++) {
          if ($i == "initcwnd" || $i == "initrwnd") {
            i++
            next
          }
          printf "%s%s", sep, $i
          sep=" "
        }
      }')
      # shellcheck disable=SC2086
      ip route replace $route_spec >/dev/null 2>&1 || true
    fi
  fi

  echo ""
  echo -e "${G}initcwnd 优化已移除${N}"
  pause_screen
}

_buffer_label_for(){
  local r="$1" m="$2"
  case "${r}_${m}" in
    hk_1g)       echo "16M" ;;
    hk_2g)       echo "32M" ;;
    hk_4g)       echo "32M" ;;
    hk_8g)       echo "64M" ;;
    jp_1g)       echo "16M" ;;
    jp_2g)       echo "32M" ;;
    jp_4g)       echo "64M" ;;
    jp_8g)       echo "64M" ;;
    us-west_1g)  echo "24M" ;;
    us-west_2g)  echo "64M" ;;
    us-west_4g)  echo "96M" ;;
    us-west_8g)  echo "128M" ;;
    eu_1g)       echo "32M" ;;
    eu_2g)       echo "64M" ;;
    eu_4g)       echo "128M" ;;
    eu_8g)       echo "128M" ;;
    *)           echo "?" ;;
  esac
}

apply_network_optimization(){
  local region="$1"
  local mem_tier="$2"
  local region_label initcwnd_value mem_label
  local buffer_max notsent_lowat fin_timeout

  if ! require_root; then return 1; fi

  case "$region" in
    hk)      region_label="香港"; initcwnd_value=32 ;;
    jp)      region_label="日本"; initcwnd_value=32 ;;
    us-west) region_label="美西"; initcwnd_value=32 ;;
    eu)      region_label="欧洲"; initcwnd_value=32 ;;
    *)
      echo -e "${R}未知地区: $region${N}"
      pause_screen
      return 1
      ;;
  esac

  case "$mem_tier" in
    1g)  mem_label="1GB"  ;;
    2g)  mem_label="2GB"  ;;
    4g)  mem_label="4GB"  ;;
    8g)  mem_label="8GB+" ;;
    *)
      echo -e "${R}未知内存档: $mem_tier${N}"
      pause_screen
      return 1
      ;;
  esac

  if ! apply_tcp_tuning "$region" "$mem_tier"; then
    echo -e "${R}TCP 调优失败，已中止${N}"
    pause_screen
    return 1
  fi

  if ! apply_initcwnd_optimization "$initcwnd_value" 1; then
    echo -e "${R}initcwnd 优化失败（TCP 调优已生效，但 initcwnd 未应用）${N}"
    pause_screen
    return 1
  fi

  buffer_max=$(awk -F'=' '/^[[:space:]]*net\.core\.rmem_max/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$TCP_TUNING_PATH" 2>/dev/null)
  notsent_lowat=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo "?")
  fin_timeout=$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null || echo "?")

  echo ""
  echo -e "${G}✓ 网络优化完成${N}"
  echo -e "  地区        : ${C}$region_label${N}"
  echo -e "  内存档位    : ${C}$mem_label${N}"
  if [ -n "$buffer_max" ] && [ "$buffer_max" -gt 0 ] 2>/dev/null; then
    echo -e "  rmem/wmem   : ${C}$((buffer_max / 1024 / 1024))M${N}"
  fi
  echo -e "  notsent     : ${C}$notsent_lowat${N}"
  echo -e "  fin_timeout : ${C}$fin_timeout${N}"
  echo -e "  initcwnd    : ${C}$initcwnd_value${N}"
  echo -e "  qdisc / cc  : ${C}$(sysctl -n net.core.default_qdisc 2>/dev/null) / $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${N}"
  echo -e "  配置文件    : ${C}$TCP_TUNING_PATH${N}"
  pause_screen
}

show_network_optimization_menu(){
  local region region_choice region_label mem_choice mem_tier
  local detected_mem_kb detected_mem_gb

  while true; do
    render_section_header "一键网络优化（TCP + initcwnd）"
    render_menu_item 1 "香港   ${D}(RTT≈80ms,  BDP≈10M)${N}"
    render_menu_item 2 "日本   ${D}(RTT≈120ms, BDP≈15M)${N}"
    render_menu_item 3 "美西   ${D}(RTT≈200ms, BDP≈25M)${N}"
    render_menu_item 4 "欧洲   ${D}(RTT≈280ms, BDP≈35M)${N}"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请选择地区: " region_choice

    case "$region_choice" in
      1) region="hk";      region_label="香港" ;;
      2) region="jp";      region_label="日本" ;;
      3) region="us-west"; region_label="美西" ;;
      4) region="eu";      region_label="欧洲" ;;
      0) return ;;
      *) notify_invalid_choice; continue ;;
    esac

    while true; do
      render_section_header "${region_label} · 选择内存档位"

      detected_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
      if [ -n "$detected_mem_kb" ] && [ "$detected_mem_kb" -gt 0 ]; then
        detected_mem_gb=$(awk -v kb="$detected_mem_kb" 'BEGIN { printf "%.1f", kb / 1024 / 1024 }')
        echo -e "  ${D}当前检测到内存: ${detected_mem_gb} GB（仅供参考，请按实际选择）${N}"
        echo ""
      fi

      render_menu_item 1 "1 GB     ${D}缓冲上限 $(_buffer_label_for "$region" 1g)${N}"
      render_menu_item 2 "2 GB     ${D}缓冲上限 $(_buffer_label_for "$region" 2g)${N}"
      render_menu_item 3 "4 GB     ${D}缓冲上限 $(_buffer_label_for "$region" 4g)${N}"
      render_menu_item 4 "8 GB+    ${D}缓冲上限 $(_buffer_label_for "$region" 8g)${N}"
      render_menu_item 0 "返回选择地区"
      render_divider
      read -p "  请选择内存档位: " mem_choice

      case "$mem_choice" in
        1) mem_tier="1g" ;;
        2) mem_tier="2g" ;;
        3) mem_tier="4g" ;;
        4) mem_tier="8g" ;;
        0) break ;;
        *) notify_invalid_choice; continue ;;
      esac

      apply_network_optimization "$region" "$mem_tier"
      break
    done
  done
}

show_network_optimization_status(){
  local route_line initcwnd_current initrwnd_current initcwnd_enabled initcwnd_active
  local tcp_qdisc tcp_cc tcp_fastopen tcp_notsent tcp_fin_timeout tcp_keepalive
  local tcp_config_status

  echo ""
  echo -e "  ${B}${C}网络优化状态${N}"
  echo -e "  ───────────────────────────────────"

  if command -v ip &>/dev/null; then
    route_line=$(ip route show default 2>/dev/null | head -1)
  fi

  if [ -n "$route_line" ]; then
    initcwnd_current=$(printf '%s\n' "$route_line" | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i == "initcwnd") {
          print $(i + 1)
          exit
        }
      }
    }')
    initrwnd_current=$(printf '%s\n' "$route_line" | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i == "initrwnd") {
          print $(i + 1)
          exit
        }
      }
    }')
  fi

  initcwnd_current="${initcwnd_current:-未设置}"
  initrwnd_current="${initrwnd_current:-未设置}"
  initcwnd_enabled=$(systemctl is-enabled "$(basename "$INITCWND_SERVICE_PATH")" 2>/dev/null || echo "未启用")
  initcwnd_active=$(systemctl is-active "$(basename "$INITCWND_SERVICE_PATH")" 2>/dev/null || echo "未知")

  echo -e "  ${B}initcwnd 状态${N}"
  if [ -n "$route_line" ]; then
    echo -e "  默认路由  : ${C}$route_line${N}"
  else
    echo -e "  默认路由  : ${R}未检测到${N}"
  fi
  echo -e "  initcwnd  : ${C}$initcwnd_current${N}"
  echo -e "  initrwnd  : ${C}$initrwnd_current${N}"
  echo -e "  服务启用  : ${C}$initcwnd_enabled${N}"
  echo -e "  服务状态  : ${C}$initcwnd_active${N}"
  echo ""

  tcp_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
  tcp_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
  tcp_fastopen=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "未知")
  tcp_notsent=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo "未知")
  tcp_fin_timeout=$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null || echo "未知")
  tcp_keepalive=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "未知")

  local tcp_profile_text="未配置"
  local tcp_rmem_max
  tcp_rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "")
  if [ -f "$TCP_TUNING_PATH" ]; then
    tcp_config_status="已存在"
    local profile_line region mem_tier region_label="" mem_label=""
    profile_line=$(awk '/^# leyili-profile:/ { print; exit }' "$TCP_TUNING_PATH" 2>/dev/null)
    if [ -n "$profile_line" ]; then
      region=$(printf '%s\n' "$profile_line" | sed -n 's/.*region=\([a-z-]\+\).*/\1/p')
      mem_tier=$(printf '%s\n' "$profile_line" | sed -n 's/.*mem_tier=\([a-z0-9]\+\).*/\1/p')
      case "$region" in
        hk)      region_label="香港" ;;
        jp)      region_label="日本" ;;
        us-west) region_label="美西" ;;
        eu)      region_label="欧洲" ;;
      esac
      case "$mem_tier" in
        1g) mem_label="1GB"  ;;
        2g) mem_label="2GB"  ;;
        4g) mem_label="4GB"  ;;
        8g) mem_label="8GB+" ;;
      esac
      if [ -n "$region_label" ] && [ -n "$mem_label" ]; then
        tcp_profile_text="${region_label} / ${mem_label}"
      fi
    fi
  else
    tcp_config_status="未写入"
  fi

  echo -e "  ${B}TCP 参数状态${N}"
  echo -e "  配置文件  : ${C}$tcp_config_status${N} (${TCP_TUNING_PATH})"
  echo -e "  配置档位  : ${C}$tcp_profile_text${N}"
  if [ -n "$tcp_rmem_max" ] && [ "$tcp_rmem_max" -gt 0 ] 2>/dev/null; then
    echo -e "  rmem_max  : ${C}$((tcp_rmem_max / 1024 / 1024))M${N}"
  fi
  echo -e "  qdisc     : ${C}$tcp_qdisc${N}"
  echo -e "  BBR       : ${C}$tcp_cc${N}"
  echo -e "  Fast Open : ${C}$tcp_fastopen${N}"
  echo -e "  notsent   : ${C}$tcp_notsent${N}"
  echo -e "  fin_timeout : ${C}$tcp_fin_timeout${N}"
  echo -e "  keepalive : ${C}$tcp_keepalive${N}"
  pause_screen
}

configure_swap(){
  local swap_active="false"

  if ! require_root; then return 1; fi

  echo ""
  echo -e "  ${B}${C}当前内存 / SWAP 状态${N}"
  free -h
  echo ""

  if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAPFILE_PATH"; then
    swap_active="true"
  fi

  if [ "$swap_active" = "true" ]; then
    echo -e "${Y}==> 检测到 ${SWAPFILE_PATH} 已启用，跳过创建${N}"
  else
    if [ -f "$SWAPFILE_PATH" ]; then
      echo -e "${Y}==> 检测到已有 ${SWAPFILE_PATH}，继续复用${N}"
    else
      echo -e "${Y}==> 创建 ${SWAP_SIZE} SWAP 文件...${N}"
      if ! fallocate -l "$SWAP_SIZE" "$SWAPFILE_PATH"; then
        echo -e "${Y}==> fallocate 失败，改用 dd 创建...${N}"
        dd if=/dev/zero of="$SWAPFILE_PATH" bs=1M count="$SWAP_SIZE_MB" status=progress || {
          echo -e "${R}SWAP 文件创建失败${N}"
          pause_screen
          return 1
        }
      fi
    fi

    echo -e "${Y}==> 设置 SWAP 文件权限...${N}"
    chmod 600 "$SWAPFILE_PATH"

    echo -e "${Y}==> 格式化 SWAP...${N}"
    mkswap "$SWAPFILE_PATH"

    echo -e "${Y}==> 启用 SWAP...${N}"
    swapon "$SWAPFILE_PATH"
  fi

  echo -e "${Y}==> 写入开机自动挂载...${N}"
  if ! grep -Eq '^[[:space:]]*/swapfile[[:space:]]+none[[:space:]]+swap[[:space:]]+sw[[:space:]]+0[[:space:]]+0([[:space:]]|$)' /etc/fstab; then
    echo "$SWAPFILE_PATH none swap sw 0 0" >> /etc/fstab
  fi

  echo -e "${Y}==> 设置 swappiness = ${SWAPPINESS_VALUE}...${N}"
  cat > "$SWAP_SYSCTL_PATH" << EOF
vm.swappiness = $SWAPPINESS_VALUE
EOF

  if ! sysctl -p "$SWAP_SYSCTL_PATH"; then
    echo -e "${R}swappiness 配置加载失败，请检查 sysctl 输出${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${G}SWAP 配置完成${N}"
  free -h
  echo ""
  swapon --show
  pause_screen
}

remove_swap(){
  local confirm=""
  local tmp_file=""

  if ! require_root; then
    return 1
  fi

  if [ ! -f "$SWAPFILE_PATH" ] && [ ! -f "$SWAP_SYSCTL_PATH" ] \
     && ! grep -Eq "^[[:space:]]*${SWAPFILE_PATH}[[:space:]]" /etc/fstab 2>/dev/null; then
    echo ""
    echo -e "${Y}未检测到脚本创建的 SWAP，无需移除${N}"
    pause_screen
    return 0
  fi

  echo ""
  echo -e "${Y}==> 即将关闭并删除 ${C}$SWAPFILE_PATH${N}${Y}，并移除 swappiness 配置${N}"
  read -p "  确认继续？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAPFILE_PATH"; then
    echo -e "${Y}==> 关闭 SWAP...${N}"
    if ! swapoff "$SWAPFILE_PATH"; then
      echo -e "${R}关闭 SWAP 失败，可能存在占用${N}"
      pause_screen
      return 1
    fi
  fi

  if [ -f "$SWAPFILE_PATH" ]; then
    rm -f "$SWAPFILE_PATH"
  fi

  if grep -Eq "^[[:space:]]*${SWAPFILE_PATH}[[:space:]]" /etc/fstab 2>/dev/null; then
    tmp_file=$(mktemp)
    awk -v p="$SWAPFILE_PATH" '$1 != p {print}' /etc/fstab > "$tmp_file" && mv "$tmp_file" /etc/fstab
  fi

  if [ -f "$SWAP_SYSCTL_PATH" ]; then
    rm -f "$SWAP_SYSCTL_PATH"
    sysctl --system >/dev/null 2>&1 || true
  fi

  echo ""
  echo -e "${G}SWAP 已移除${N}"
  free -h
  pause_screen
}

# ─── 脚本自更新 / 配置管理 ────────────────────────────
get_latest_singbox_version(){
  local ver=""
  ver=$(curl -fsSL --max-time 5 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name":[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)
  printf '%s' "$ver"
}

get_current_singbox_version(){
  if ! command -v sing-box >/dev/null 2>&1; then
    printf '%s' ""
    return
  fi
  sing-box version 2>/dev/null | head -1 | awk '{print $3}'
}

update_self_script(){
  local tmp_file=""
  local confirm=""

  if ! require_root; then
    return 1
  fi

  if [ -z "$SELF_INSTALL_URL" ]; then
    echo ""
    echo -e "${R}未配置 SELF_INSTALL_URL，无法自更新${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${Y}==> 下载最新脚本...${N}"
  tmp_file=$(mktemp)
  trap 'rm -f "$tmp_file"' RETURN INT TERM
  if ! curl -fsSL --max-time 15 "$SELF_INSTALL_URL" -o "$tmp_file"; then
    rm -f "$tmp_file"
    echo -e "${R}下载失败，请检查网络或 SELF_INSTALL_URL${N}"
    pause_screen
    return 1
  fi

  if ! bash -n "$tmp_file"; then
    rm -f "$tmp_file"
    echo -e "${R}新脚本语法校验失败，已放弃更新${N}"
    pause_screen
    return 1
  fi

  if [ -f "$SCRIPT_PATH" ] && cmp -s "$tmp_file" "$SCRIPT_PATH"; then
    rm -f "$tmp_file"
    echo -e "${G}当前已是最新版本${N}"
    pause_screen
    return 0
  fi

  echo -e "  来源: ${C}$SELF_INSTALL_URL${N}"
  read -p "  确认覆盖 ${SCRIPT_PATH}？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    rm -f "$tmp_file"
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  if [ -f "$SCRIPT_PATH" ]; then
    cp "$SCRIPT_PATH" "${SCRIPT_PATH}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    cleanup_old_backups "${SCRIPT_PATH}.bak.*" 3
  fi

  if ! install -m 0755 "$tmp_file" "$SCRIPT_PATH"; then
    rm -f "$tmp_file"
    echo -e "${R}写入 $SCRIPT_PATH 失败${N}"
    pause_screen
    return 1
  fi
  rm -f "$tmp_file"

  echo ""
  echo -e "${G}脚本已更新，请重新运行 ${B}${COMMAND_NAME}${N}"
  pause_screen
  exit 0
}

view_singbox_config(){
  if ! require_singbox_installed; then
    return 1
  fi

  if [ ! -f "$CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到配置文件：$CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "  ${B}${C}$CONFIG_PATH${N}"
  render_divider
  if command -v jq >/dev/null 2>&1; then
    jq . "$CONFIG_PATH" 2>/dev/null || cat "$CONFIG_PATH"
  else
    cat "$CONFIG_PATH"
  fi
  pause_screen
}

edit_singbox_config(){
  local editor_bin=""
  local backup_path=""

  if ! require_root; then
    return 1
  fi
  if ! require_singbox_installed; then
    return 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到配置文件：$CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  editor_bin="${EDITOR:-}"
  if [ -z "$editor_bin" ] || ! command -v "$editor_bin" >/dev/null 2>&1; then
    for candidate in nano vim vi; do
      if command -v "$candidate" >/dev/null 2>&1; then
        editor_bin="$candidate"
        break
      fi
    done
  fi

  if [ -z "$editor_bin" ]; then
    echo ""
    echo -e "${R}未找到可用的编辑器（nano/vim/vi），请先安装或设置 EDITOR${N}"
    pause_screen
    return 1
  fi

  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  if ! cp "$CONFIG_PATH" "$backup_path"; then
    echo -e "${R}配置备份失败${N}"
    pause_screen
    return 1
  fi

  "$editor_bin" "$CONFIG_PATH"

  if ! sing-box check -c "$CONFIG_PATH"; then
    echo ""
    read -p "  配置校验失败，是否回滚到编辑前备份？(Y/n): " rollback
    if [ "$rollback" != "n" ] && [ "$rollback" != "N" ]; then
      cp "$backup_path" "$CONFIG_PATH"
      echo -e "${G}已回滚${N}"
    else
      echo -e "${Y}已保留有问题的配置（备份：$backup_path）${N}"
    fi
    pause_screen
    return 1
  fi

  if ! systemctl restart sing-box; then
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    systemctl restart sing-box >/dev/null 2>&1 || true
    echo -e "${R}服务重启失败，已回滚${N}"
    pause_screen
    return 1
  fi

  cleanup_old_backups "${CONFIG_PATH}.bak.*" 5

  echo ""
  echo -e "${G}配置已更新并重启服务${N}"
  echo -e "  备份文件: ${C}$backup_path${N}"
  pause_screen
}

cleanup_config_backups(){
  local count=0
  local confirm=""

  if ! require_root; then
    return 1
  fi

  count=$(ls -1 "${CONFIG_PATH}".bak.* 2>/dev/null | wc -l)
  count=$((count + $(ls -1 "${SSHD_CONFIG_PATH}".bak.* 2>/dev/null | wc -l)))
  count=$((count + $(ls -1 "${SCRIPT_PATH}".bak.* 2>/dev/null | wc -l)))

  echo ""
  echo -e "  ${B}当前备份文件${N}"
  ls -1 "${CONFIG_PATH}".bak.* "${SSHD_CONFIG_PATH}".bak.* "${SCRIPT_PATH}".bak.* 2>/dev/null || true
  echo ""
  if [ "$count" -eq 0 ]; then
    echo -e "${Y}无需清理${N}"
    pause_screen
    return 0
  fi

  read -p "  保留最近几份备份？(默认 3): " keep
  keep="${keep:-3}"
  case "$keep" in
    ''|*[!0-9]*)
      echo -e "${R}必须为非负整数${N}"
      pause_screen
      return 1
      ;;
  esac

  read -p "  确认按此规则清理？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  cleanup_old_backups "${CONFIG_PATH}.bak.*" "$keep"
  cleanup_old_backups "${SSHD_CONFIG_PATH}.bak.*" "$keep"
  cleanup_old_backups "${SCRIPT_PATH}.bak.*" "$keep"

  echo ""
  echo -e "${G}备份已清理${N}"
  pause_screen
}

# ─── 首次安装入口 ─────────────────────────────────────
install_reality_node(){
  local port_input="" sni_input=""
  local keypair="" private_key="" public_key=""
  local access_ip="" link="" ipv6_link=""
  local public_ipv4="" public_ipv6=""
  local install_mode="ipv4" mode_label=""
  local PORT SNI TAG LISTEN_CHOICE LISTEN_ADDR UUID SHORT_ID confirm

  if ! require_root; then return 1; fi

  render_section_header "创建 Reality 节点"
  echo -e "  ${Y}直接回车使用括号内默认值${N}"
  echo ""

  if node_installed reality; then
    echo -e "${Y}检测到已存在 Reality 节点，继续将覆盖原节点配置${N}"
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
    read -p "  域名 (www.ucla.edu): " sni_input
    sni_input="${sni_input:-www.ucla.edu}"
    SNI=$(sanitize_sni "$sni_input")
    if [ -n "$SNI" ]; then
      break
    fi
    echo -e "${R}域名不能为空，且不能只包含引号或换行${N}"
  done

  read -p "  节点名称 (reality): " TAG
  TAG="${TAG:-reality}"

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
      echo -e "${R}未检测到可用的 IPv6 地址，无法使用“仅 IPv6 入站 + 仅 IPv4 出站”模式${N}"
      pause_screen
      return 1
    fi
  fi

  if ! is_singbox_installed; then
    echo ""
    echo -e "${Y}==> 安装 sing-box...${N}"
    if ! install_singbox; then
      echo ""
      echo -e "${R}sing-box 安装失败，请检查上方输出${N}"
      pause_screen
      return 1
    fi
  fi

  echo -e "${Y}==> 生成参数...${N}"
  UUID=$(cat /proc/sys/kernel/random/uuid)
  SHORT_ID=$(openssl rand -hex 4)
  if ! keypair=$(sing-box generate reality-keypair); then
    echo ""
    echo -e "${R}密钥对生成失败${N}"
    pause_screen
    return 1
  fi
  private_key=$(echo "$keypair" | grep PrivateKey | awk '{print $2}')
  public_key=$(echo "$keypair" | grep PublicKey | awk '{print $2}')
  if [ -z "$private_key" ] || [ -z "$public_key" ]; then
    echo ""
    echo -e "${R}密钥对解析失败${N}"
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

  echo -e "${Y}==> 写入配置...${N}"
  ensure_jq || { pause_screen; return 1; }

  local inbound_json
  inbound_json=$(jq -n \
    --arg listen "$LISTEN_ADDR" \
    --argjson port "$PORT" \
    --arg uuid "$UUID" \
    --arg sni "$SNI" \
    --arg priv "$private_key" \
    --arg sid "$SHORT_ID" '{
      type: "vless",
      tag: "reality-in",
      listen: $listen,
      listen_port: $port,
      users: [{uuid: $uuid, flow: "xtls-rprx-vision"}],
      tls: {
        enabled: true,
        server_name: $sni,
        reality: {
          enabled: true,
          handshake: {server: $sni, server_port: 443},
          private_key: $priv,
          short_id: [$sid]
        }
      }
    }')

  if ! config_add_inbound "$inbound_json"; then
    echo -e "${R}写入 inbound 失败${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 校验并启动...${N}"
  if ! config_check_and_restart; then
    echo ""
    echo -e "${R}sing-box 校验或重启失败${N}"
    pause_screen
    return 1
  fi

  node_apply_firewall_for_mode "$PORT" tcp "$install_mode"
  print_firewall_hint "$PORT" tcp "Reality 节点入站"

  link=$(build_reality_link "$UUID" "$access_ip" "$PORT" "$SNI" "$public_key" "$SHORT_ID" "$TAG" 2>/dev/null || true)
  if [ "$install_mode" = "dualstack" ] && [ -n "$public_ipv6" ] && [ "$public_ipv6" != "$access_ip" ]; then
    ipv6_link=$(build_reality_link "$UUID" "$public_ipv6" "$PORT" "$SNI" "$public_key" "$SHORT_ID" "${TAG}-ipv6" 2>/dev/null || true)
  fi

  ensure_nodes_dir
  cat > "$(node_info_path reality)" <<EOF
Type=reality
Tag=$TAG
Mode=$install_mode
ListenAddr=$LISTEN_ADDR
Port=$PORT
SNI=$SNI
UUID=$UUID
PublicKey=$public_key
PrivateKey=$private_key
ShortID=$SHORT_ID
IP=$access_ip
Link=$link
EOF

  register_sb_command || true

  echo ""
  echo -e "  ${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "  ${G}║${N}  ${B}${W}${APP_NAME}${N}  ${G}Reality 节点创建完成${N}                       ${G}║${N}"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${N}"
  echo -e "  模式      : ${C}$mode_label${N}"
  echo -e "  UUID      : ${C}$UUID${N}"
  echo -e "  PublicKey : ${C}$public_key${N}"
  echo -e "  入口 IP   : ${C}${access_ip:-未知}${N}"
  echo -e "  出站策略  : ${C}仅 IPv4${N}"
  echo -e "  端口      : ${C}$PORT${N}"
  echo -e "  SNI       : ${C}$SNI${N}"
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
  echo -e "  信息已保存至 ${Y}$(node_info_path reality)${N}"
  echo -e "  输入 ${B}${COMMAND_NAME}${N} 进入管理菜单"
  pause_screen
}

config_inbound_count(){
  if [ ! -f "$CONFIG_PATH" ]; then
    printf '0'
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '0'
    return
  fi
  jq '(.inbounds // []) | length' "$CONFIG_PATH" 2>/dev/null || printf '0'
}

# 卸载某节点后调用：剩 0 个 inbound 则停服务，否则校验+重启
post_uninstall_service_step(){
  if ! is_singbox_installed; then
    return 0
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    return 0
  fi
  local remain
  remain=$(config_inbound_count)
  if [ "${remain:-0}" -eq 0 ]; then
    echo -e "${Y}==> 已无任何节点，停止 sing-box 服务...${N}"
    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true
    return 0
  fi
  if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
    systemctl restart sing-box >/dev/null 2>&1 || true
  fi
}

uninstall_reality_node(){
  local confirm
  if ! node_installed reality; then
    echo -e "${Y}Reality 节点未安装${N}"
    pause_screen
    return 0
  fi
  echo ""
  read -p "  确认卸载 Reality 节点？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  # 必须在 remove_node_info 之前撤防火墙规则，否则读不到 Mode/Port
  local rt_port rt_mode
  rt_port=$(get_node_value reality Port 2>/dev/null || true)
  rt_mode=$(get_node_value reality Mode 2>/dev/null || echo ipv4)
  if [ -n "$rt_port" ]; then
    node_revoke_firewall_for_mode "$rt_port" tcp "$rt_mode"
  fi

  config_remove_inbound_by_tag "reality-in" || true
  config_remove_inbound_chain "reality-in" || true
  config_remove_outbound_by_tag "chain-reality-out" || true
  remove_node_info reality
  remove_chain_info reality
  post_uninstall_service_step
  echo -e "${G}Reality 节点已卸载${N}"
  pause_screen
}

# 兼容入口：do_install 默认创建 Reality 节点
do_install(){ install_reality_node; }

# ─── 端口跳跃公共逻辑 ─────────────────────────────────
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
generate_hy2_random_port(){
  local p attempts=0
  while [ $attempts -lt 30 ]; do
    p=$(( (RANDOM << 15 | RANDOM) % 45535 + 20000 ))
    if ! check_port_in_use "$p"; then
      printf '%s' "$p"
      return 0
    fi
    attempts=$((attempts + 1))
  done
  printf '%s' "$p"
}

generate_self_signed_cert_for_hy2(){
  local sni="$1"
  ensure_nodes_dir
  local crt="$CERTS_DIR/hy2.crt"
  local key="$CERTS_DIR/hy2.key"
  if ! command -v openssl >/dev/null 2>&1; then
    echo -e "${R}未找到 openssl${N}"
    return 1
  fi
  if ! openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null; then
    if ! openssl genrsa -out "$key" 2048 >/dev/null 2>&1; then
      echo -e "${R}私钥生成失败${N}"
      return 1
    fi
  fi
  if ! openssl req -new -x509 -days 3650 -key "$key" -out "$crt" \
       -subj "/CN=${sni}" >/dev/null 2>&1; then
    echo -e "${R}自签证书生成失败${N}"
    return 1
  fi
  chmod 600 "$key"
  printf '%s\n%s' "$crt" "$key"
}

install_hy2_node(){
  local port_input="" sni_input=""
  local PORT SNI TAG LISTEN_CHOICE LISTEN_ADDR install_mode="ipv4"
  local cert_choice cert_source="self" acme_email=""
  local password obfs_password obfs_choice obfs_enable=1
  local public_ipv4="" public_ipv6="" access_ip=""
  local link="" ipv6_link="" mode_label="" confirm
  local cert_paths cert_path key_path
  local up_mbps=100 down_mbps=300 bw_choice
  local hop_choice HOP_ENABLE=0 HOP_MODE="" HOP_START="" HOP_END=""
  local range_input confirm_hop confirm_small force_hop
  local listen_v4="" listen_v6=""

  if ! require_root; then return 1; fi

  render_section_header "创建 Hysteria2 节点"
  echo -e "  ${Y}直接回车使用括号内默认值${N}"
  echo ""

  if node_installed hy2; then
    echo -e "${Y}检测到已存在 Hysteria2 节点，继续将覆盖原节点配置${N}"
    read -p "  继续？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo -e "  已取消"
      return 0
    fi
  fi

  # 端口（默认随机高位 UDP）
  local default_port
  default_port=$(generate_hy2_random_port)
  while true; do
    read -p "  端口 (${default_port}, 回车随机): " port_input
    PORT="${port_input:-$default_port}"
    if validate_port "$PORT"; then
      PORT=$((10#$PORT))
      break
    fi
    echo -e "${R}端口必须是 1-65535 的数字${N}"
  done

  # 节点名
  read -p "  节点名称 (hy2): " TAG
  TAG="${TAG:-hy2}"

  # 监听模式
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
      echo -e "${R}未检测到可用的 IPv6 地址，无法使用“仅 IPv6 入站 + 仅 IPv4 出站”模式${N}"
      pause_screen
      return 1
    fi
  fi

  # 证书来源
  echo -e "  证书来源："
  echo "    1) 自签证书（推荐，客户端 insecure=1）（默认）"
  echo "    2) ACME 自动签发（需要真实域名 + 80 端口可用）"
  read -p "  请选择 (1): " cert_choice
  case "$cert_choice" in
    2) cert_source="acme" ;;
    *) cert_source="self" ;;
  esac

  # SNI / 域名
  if [ "$cert_source" = "acme" ]; then
    while true; do
      read -p "  真实域名（已解析到本机）: " sni_input
      sni_input="${sni_input:-}"
      SNI=$(sanitize_sni "$sni_input")
      if [ -n "$SNI" ]; then break; fi
      echo -e "${R}ACME 模式必须提供真实域名${N}"
    done
    while true; do
      read -p "  ACME 邮箱: " acme_email
      if [ -n "$acme_email" ] && printf '%s' "$acme_email" | grep -q "@"; then break; fi
      echo -e "${R}邮箱不能为空，且必须包含 @${N}"
    done
  else
    while true; do
      read -p "  伪装 SNI (bing.com): " sni_input
      sni_input="${sni_input:-bing.com}"
      SNI=$(sanitize_sni "$sni_input")
      if [ -n "$SNI" ]; then break; fi
      echo -e "${R}SNI 不能为空${N}"
    done
  fi

  # obfs（默认启用 salamander）
  echo -e "  obfs 混淆 (salamander)："
  echo "    1) 启用，密码自动生成（默认）"
  echo "    2) 不启用"
  read -p "  请选择 (1): " obfs_choice
  case "$obfs_choice" in
    2) obfs_enable=0 ;;
    *) obfs_enable=1 ;;
  esac

  # 带宽限制（防 HY2 跑满线路被云厂商盯）
  echo ""
  echo -e "  ${B}带宽限制${N}（防 HY2 跑满线路被云厂商盯，不影响日常使用）："
  echo "    1) 保守    上 30  / 下 80  Mbps  - 小机器 / 共享带宽限速重的"
  echo "    2) 推荐    上 100 / 下 300 Mbps  - 99% 情况，闭眼选（默认）"
  echo "    3) 大带宽  上 300 / 下 800 Mbps  - 测速过、确认有大带宽"
  echo "    4) 自定义"
  echo "    5) 不限制（不推荐，可能触发云厂商告警）"
  read -p "  请选择 (2): " bw_choice
  case "$bw_choice" in
    1) up_mbps=30;  down_mbps=80 ;;
    3) up_mbps=300; down_mbps=800 ;;
    4)
      while true; do
        read -p "  上行 Mbps (正整数): " up_mbps
        if [ -n "$up_mbps" ] && [ "$up_mbps" -gt 0 ] 2>/dev/null; then break; fi
        echo -e "${R}必须为正整数${N}"
      done
      while true; do
        read -p "  下行 Mbps (正整数): " down_mbps
        if [ -n "$down_mbps" ] && [ "$down_mbps" -gt 0 ] 2>/dev/null; then break; fi
        echo -e "${R}必须为正整数${N}"
      done
      ;;
    5) up_mbps=0; down_mbps=0 ;;
    *) up_mbps=100; down_mbps=300 ;;
  esac

  # 端口跳跃（进阶选项）
  echo ""
  echo -e "  ${B}端口跳跃${N} (port hopping) — 进阶选项："
  echo -e "    ${D}作用：客户端在多个端口间随机跳跃，封一个端口没用，对抗成本提升 100 倍${N}"
  echo -e "    ${D}代价：消耗大量端口，部分云厂商可能告警，可能与 Docker / 其他服务冲突${N}"
  echo "    1) 不启用（默认，推荐小白）"
  echo "    2) 启用 - 自动选择范围（主端口 +1 到 +999）"
  echo "    3) 启用 - 自定义范围（避开 Docker / 其他服务）"
  read -p "  请选择 (1): " hop_choice
  case "$hop_choice" in
    2)
      HOP_ENABLE=1
      HOP_MODE="auto"
      read HOP_START HOP_END < <(port_hop_compute_range "$PORT")
      echo -e "  自动选择：${C}${HOP_START}-${HOP_END}${N} ${D}（共 $((HOP_END-HOP_START+1)) 个端口）${N}"
      echo -e "  ${Y}注意：会自动配置 iptables NAT 规则并占用整个范围${N}"
      read -p "  确认启用？(y/N): " confirm_hop
      if [ "$confirm_hop" != "y" ] && [ "$confirm_hop" != "Y" ]; then
        HOP_ENABLE=0; HOP_MODE=""; HOP_START=""; HOP_END=""
      fi
      ;;
    3)
      HOP_ENABLE=1
      HOP_MODE="custom"
      echo -e "  ${D}建议范围至少 100 个端口，越大抗封效果越好${N}"
      echo -e "  ${D}格式示例：30000-31000  (含两端，共 1001 个端口)${N}"
      echo -e "  ${D}建议避开：22 (SSH)、80/443 (Web)、Docker 已用端口${N}"
      while true; do
        read -p "  端口范围 (起始-结束): " range_input
        HOP_START=$(echo "$range_input" | awk -F- '{print $1}' | tr -dc '0-9')
        HOP_END=$(echo "$range_input" | awk -F- '{print $2}' | tr -dc '0-9')
        if [ -z "$HOP_START" ] || [ -z "$HOP_END" ]; then
          echo -e "  ${R}格式错误，请按 起始-结束 格式输入${N}"; continue
        fi
        if [ "$HOP_START" -lt 1024 ] || [ "$HOP_END" -gt 65535 ]; then
          echo -e "  ${R}端口必须在 1024-65535 之间${N}"; continue
        fi
        if [ "$HOP_START" -ge "$HOP_END" ]; then
          echo -e "  ${R}起始端口必须小于结束端口${N}"; continue
        fi
        if [ "$PORT" -ge "$HOP_START" ] && [ "$PORT" -le "$HOP_END" ]; then
          echo -e "  ${R}范围不能包含主端口 $PORT${N}"; continue
        fi
        if [ $((HOP_END - HOP_START)) -lt 50 ]; then
          echo -e "  ${Y}警告：范围只有 $((HOP_END-HOP_START+1)) 个端口，抗封效果有限${N}"
          read -p "  仍然使用？(y/N): " confirm_small
          if [ "$confirm_small" != "y" ] && [ "$confirm_small" != "Y" ]; then continue; fi
        fi
        break
      done
      ;;
  esac

  if ! is_singbox_installed; then
    echo ""
    echo -e "${Y}==> 安装 sing-box...${N}"
    if ! install_singbox; then
      echo ""
      echo -e "${R}sing-box 安装失败，请检查上方输出${N}"
      pause_screen
      return 1
    fi
  fi

  echo -e "${Y}==> 生成参数...${N}"
  if ! command -v openssl >/dev/null 2>&1; then
    echo -e "${R}缺少 openssl${N}"
    pause_screen
    return 1
  fi
  password=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-22)
  if [ "$obfs_enable" = "1" ]; then
    obfs_password=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-22)
  fi

  public_ipv4=${public_ipv4:-$(detect_primary_ipv4)}
  public_ipv6=${public_ipv6:-$(detect_primary_ipv6)}

  case "$install_mode" in
    ipv6-in-ipv4-out)
      access_ip="$public_ipv6"
      LISTEN_ADDR="$public_ipv6"
      [ -z "$access_ip" ] && { echo -e "${R}未检测到 IPv6${N}"; pause_screen; return 1; }
      ;;
    dualstack)
      access_ip="${public_ipv4:-$public_ipv6}"
      [ -z "$access_ip" ] && { echo -e "${R}未检测到 IPv4 / IPv6${N}"; pause_screen; return 1; }
      ;;
    *)
      access_ip="$public_ipv4"
      [ -z "$access_ip" ] && { echo -e "${R}未检测到 IPv4${N}"; pause_screen; return 1; }
      ;;
  esac

  mode_label=$(describe_install_mode "$install_mode")

  # 准备证书
  if [ "$cert_source" = "self" ]; then
    echo -e "${Y}==> 生成自签证书...${N}"
    cert_paths=$(generate_self_signed_cert_for_hy2 "$SNI") || { pause_screen; return 1; }
    cert_path=$(echo "$cert_paths" | sed -n '1p')
    key_path=$(echo "$cert_paths" | sed -n '2p')
  fi

  echo -e "${Y}==> 写入配置...${N}"
  ensure_jq || { pause_screen; return 1; }

  local tls_json
  if [ "$cert_source" = "acme" ]; then
    tls_json=$(jq -n --arg sni "$SNI" --arg email "$acme_email" '{
      enabled: true,
      server_name: $sni,
      alpn: ["h3"],
      acme: {domain: [$sni], email: $email}
    }')
  else
    tls_json=$(jq -n --arg sni "$SNI" --arg crt "$cert_path" --arg key "$key_path" '{
      enabled: true,
      server_name: $sni,
      alpn: ["h3"],
      certificate_path: $crt,
      key_path: $key
    }')
  fi

  local obfs_json="null"
  if [ "$obfs_enable" = "1" ]; then
    obfs_json=$(jq -n --arg pw "$obfs_password" '{type: "salamander", password: $pw}')
  fi

  # 构造 user 对象（Hysteria2 的 user 仅含 password；带宽限制 up_mbps/down_mbps 是 inbound 顶层字段）
  local user_obj
  user_obj=$(jq -n --arg pw "$password" '{password: $pw}')

  local inbound_json
  inbound_json=$(jq -n \
    --arg listen "$LISTEN_ADDR" \
    --argjson port "$PORT" \
    --argjson user "$user_obj" \
    --argjson tls "$tls_json" \
    --argjson obfs "$obfs_json" \
    --argjson up "$up_mbps" \
    --argjson down "$down_mbps" '
    {
      type: "hysteria2",
      tag: "hy2-in",
      listen: $listen,
      listen_port: $port,
      users: [$user],
      tls: $tls
    }
    + (if $obfs == null then {} else {obfs: $obfs} end)
    + (if $up > 0 and $down > 0 then {up_mbps: $up, down_mbps: $down} else {} end)')

  if ! config_add_inbound "$inbound_json"; then
    echo -e "${R}写入 inbound 失败${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 校验并启动...${N}"
  if ! config_check_and_restart; then
    echo ""
    echo -e "${R}sing-box 校验或重启失败${N}"
    pause_screen
    return 1
  fi

  # 应用端口跳跃规则（启用时）
  if [ "$HOP_ENABLE" = "1" ]; then
    if port_hop_range_has_conflict "$HOP_START" "$HOP_END"; then
      echo ""
      echo -e "${Y}端口范围 ${HOP_START}-${HOP_END} 内已有其他 UDP 服务监听：${N}"
      port_hop_list_conflicts "$HOP_START" "$HOP_END"
      read -p "  仍然继续？冲突端口可能被 NAT 规则覆盖 (y/N): " force_hop
      if [ "$force_hop" != "y" ] && [ "$force_hop" != "Y" ]; then
        HOP_ENABLE=0; HOP_MODE=""; HOP_START=""; HOP_END=""
        echo -e "  ${Y}已取消端口跳跃${N}"
      fi
    fi
    if [ "$HOP_ENABLE" = "1" ]; then
      local addrs_pair
      addrs_pair=$(port_hop_listen_addrs_for_mode "$install_mode" "$public_ipv6")
      listen_v4="${addrs_pair%|*}"
      listen_v6="${addrs_pair#*|}"
      port_hop_apply "$PORT" "$HOP_START" "$HOP_END" "$install_mode" "$listen_v4" "$listen_v6"
      echo -e "  ${G}端口跳跃已启用：${HOP_START}-${HOP_END} (UDP)${N}"
    fi
  fi

  node_apply_firewall_for_mode "$PORT" udp "$install_mode"
  print_firewall_hint "$PORT" udp "Hysteria2 节点入站"
  if [ "$HOP_ENABLE" = "1" ]; then
    echo -e "  ${D}端口跳跃 DNAT 已配置：${HOP_START}-${HOP_END}/udp → 主端口 ${PORT}/udp${N}"
  fi
  if [ "$cert_source" = "acme" ]; then
    print_firewall_hint 80 tcp "ACME 证书签发与续期，签发期间必须可外部访问"
  fi

  local insecure="0"
  [ "$cert_source" = "self" ] && insecure="1"
  local link_obfs_type=""
  [ "$obfs_enable" = "1" ] && link_obfs_type="salamander"

  link=$(build_hy2_link "$password" "$access_ip" "$PORT" "$SNI" "$insecure" "$link_obfs_type" "${obfs_password:-}" "$TAG" "$HOP_START" "$HOP_END" 2>/dev/null || true)
  if [ "$install_mode" = "dualstack" ] && [ -n "$public_ipv6" ] && [ "$public_ipv6" != "$access_ip" ]; then
    ipv6_link=$(build_hy2_link "$password" "$public_ipv6" "$PORT" "$SNI" "$insecure" "$link_obfs_type" "${obfs_password:-}" "${TAG}-ipv6" "$HOP_START" "$HOP_END" 2>/dev/null || true)
  fi

  ensure_nodes_dir
  {
    cat <<EOF
Type=hy2
Tag=$TAG
Mode=$install_mode
ListenAddr=$LISTEN_ADDR
Port=$PORT
SNI=$SNI
CertSource=$cert_source
ACMEEmail=$acme_email
CertPath=${cert_path:-}
KeyPath=${key_path:-}
Password=$password
Obfs=${link_obfs_type:-none}
ObfsPassword=${obfs_password:-}
Insecure=$insecure
IP=$access_ip
EOF
    if [ "$up_mbps" -gt 0 ] && [ "$down_mbps" -gt 0 ]; then
      echo "UpMbps=$up_mbps"
      echo "DownMbps=$down_mbps"
    fi
    if [ "$HOP_ENABLE" = "1" ]; then
      echo "PortHop=1"
      echo "PortHopMode=$HOP_MODE"
      echo "PortHopStart=$HOP_START"
      echo "PortHopEnd=$HOP_END"
    fi
    echo "Link=$link"
  } > "$(node_info_path hy2)"

  register_sb_command || true

  echo ""
  echo -e "  ${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "  ${G}║${N}  ${B}${W}${APP_NAME}${N}  ${G}Hysteria2 节点创建完成${N}                     ${G}║${N}"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${N}"
  echo -e "  模式      : ${C}$mode_label${N}"
  echo -e "  端口      : ${C}$PORT${N} ${D}(UDP)${N}"
  echo -e "  入口 IP   : ${C}${access_ip:-未知}${N}"
  echo -e "  SNI       : ${C}$SNI${N}"
  echo -e "  证书      : ${C}${cert_source}${N}$([ "$insecure" = "1" ] && echo "  ${Y}(客户端需 insecure=1)${N}")"
  echo -e "  Password  : ${C}$password${N}"
  if [ "$obfs_enable" = "1" ]; then
    echo -e "  Obfs      : ${C}salamander${N}  ObfsPwd : ${C}$obfs_password${N}"
  fi
  if [ "$up_mbps" -gt 0 ] && [ "$down_mbps" -gt 0 ]; then
    echo -e "  带宽限制  : ${C}上 ${up_mbps} / 下 ${down_mbps} Mbps${N}"
  else
    echo -e "  带宽限制  : ${Y}未限制${N} ${D}(可能触发云厂商告警)${N}"
  fi
  if [ "$HOP_ENABLE" = "1" ]; then
    echo -e "  端口跳跃  : ${C}${HOP_START}-${HOP_END}${N} ${D}($HOP_MODE 模式, $((HOP_END-HOP_START+1)) 端口)${N}"
  else
    echo -e "  端口跳跃  : ${D}未启用${N}"
  fi
  echo -e "  出站策略  : ${C}仅 IPv4${N}"
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
  echo -e "  信息已保存至 ${Y}$(node_info_path hy2)${N}"
  echo -e "  输入 ${B}${COMMAND_NAME}${N} 进入管理菜单"
  pause_screen
}

uninstall_hy2_node(){
  local confirm
  if ! node_installed hy2; then
    echo -e "${Y}Hysteria2 节点未安装${N}"
    pause_screen
    return 0
  fi
  echo ""
  read -p "  确认卸载 Hysteria2 节点？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  # 清理端口跳跃规则（必须在 remove_node_info 之前，否则读不到 info）
  local hop_enabled hop_start hop_end mode hy2_port
  hop_enabled=$(get_node_value hy2 PortHop 2>/dev/null || echo 0)
  hy2_port=$(get_node_value hy2 Port 2>/dev/null || true)
  mode=$(get_node_value hy2 Mode 2>/dev/null || echo ipv4)
  if [ "$hop_enabled" = "1" ]; then
    hop_start=$(get_node_value hy2 PortHopStart 2>/dev/null || true)
    hop_end=$(get_node_value hy2 PortHopEnd 2>/dev/null || true)
    if [ -n "$hop_start" ] && [ -n "$hop_end" ]; then
      port_hop_remove "$hop_start" "$hop_end" "$mode"
      echo -e "  ${D}端口跳跃规则已清理 (${hop_start}-${hop_end})${N}"
    fi
  fi

  # 撤销主端口防火墙规则
  if [ -n "$hy2_port" ]; then
    node_revoke_firewall_for_mode "$hy2_port" udp "$mode"
  fi

  config_remove_inbound_by_tag "hy2-in" || true
  config_remove_inbound_chain "hy2-in" || true
  config_remove_outbound_by_tag "chain-hy2-out" || true
  remove_node_info hy2
  remove_chain_info hy2
  rm -f "$CERTS_DIR/hy2.crt" "$CERTS_DIR/hy2.key" 2>/dev/null || true
  post_uninstall_service_step
  echo -e "${G}Hysteria2 节点已卸载${N}"
  pause_screen
}

modify_hy2_params(){
  local new_port="" new_sni="" regen_pw="n"
  local cur_port cur_sni cur_pw cur_obfs cur_obfs_pw cur_cert_src cur_email
  local cur_up cur_down cur_hop cur_hop_mode cur_hop_start cur_hop_end cur_mode
  local new_pw="" new_obfs_pw=""
  local backup_path="" confirm
  local bw_choice bw_action="keep" new_up=0 new_down=0
  local hop_choice new_hop=0 new_hop_mode="" new_hop_start="" new_hop_end=""
  local range_input confirm_small

  if ! require_root; then return 1; fi
  if ! require_singbox_installed; then return 1; fi
  if ! node_installed hy2; then
    echo ""
    echo -e "${R}未发现 Hysteria2 节点信息${N}"
    pause_screen
    return 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到配置文件：$CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  cur_port=$(get_node_value hy2 Port 2>/dev/null || true)
  cur_sni=$(get_node_value hy2 SNI 2>/dev/null || true)
  cur_pw=$(get_node_value hy2 Password 2>/dev/null || true)
  cur_obfs=$(get_node_value hy2 Obfs 2>/dev/null || true)
  cur_obfs_pw=$(get_node_value hy2 ObfsPassword 2>/dev/null || true)
  cur_cert_src=$(get_node_value hy2 CertSource 2>/dev/null || echo self)
  cur_email=$(get_node_value hy2 ACMEEmail 2>/dev/null || true)
  cur_up=$(get_node_value hy2 UpMbps 2>/dev/null || true)
  cur_down=$(get_node_value hy2 DownMbps 2>/dev/null || true)
  cur_hop=$(get_node_value hy2 PortHop 2>/dev/null || echo 0)
  cur_hop_mode=$(get_node_value hy2 PortHopMode 2>/dev/null || true)
  cur_hop_start=$(get_node_value hy2 PortHopStart 2>/dev/null || true)
  cur_hop_end=$(get_node_value hy2 PortHopEnd 2>/dev/null || true)
  cur_mode=$(get_node_value hy2 Mode 2>/dev/null || echo ipv4)

  echo ""
  echo -e "  ${B}${C}修改 Hysteria2 节点参数${N}  ${D}直接回车保留当前值${N}"
  render_divider

  while true; do
    read -p "  端口 (${cur_port:-当前未知}): " new_port
    new_port="${new_port:-$cur_port}"
    if validate_port "$new_port"; then break; fi
    echo -e "${R}端口必须是 1-65535 的数字${N}"
  done

  while true; do
    read -p "  SNI (${cur_sni:-当前未知}): " new_sni
    new_sni="${new_sni:-$cur_sni}"
    new_sni=$(sanitize_sni "$new_sni")
    if [ -n "$new_sni" ]; then break; fi
    echo -e "${R}SNI 不能为空${N}"
  done

  read -p "  重新生成 Password？(y/N): " regen_pw
  if [ "$regen_pw" = "y" ] || [ "$regen_pw" = "Y" ]; then
    new_pw=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-22)
    echo -e "  ${D}新 Password：$new_pw${N}"
  fi

  if [ "$cur_obfs" = "salamander" ]; then
    read -p "  重新生成 obfs 密码？(y/N): " regen_obfs
    if [ "$regen_obfs" = "y" ] || [ "$regen_obfs" = "Y" ]; then
      new_obfs_pw=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-22)
      echo -e "  ${D}新 obfs 密码：$new_obfs_pw${N}"
    fi
  fi

  # 带宽限制修改
  echo ""
  if [ -n "$cur_up" ] && [ -n "$cur_down" ]; then
    echo -e "  ${B}带宽限制${N} (当前: 上 ${C}${cur_up}${N} / 下 ${C}${cur_down}${N} Mbps)："
  else
    echo -e "  ${B}带宽限制${N} (当前: ${Y}未限制${N})："
  fi
  echo "    1) 保留当前设置（默认）"
  echo "    2) 保守    上 30  / 下 80  Mbps"
  echo "    3) 推荐    上 100 / 下 300 Mbps"
  echo "    4) 大带宽  上 300 / 下 800 Mbps"
  echo "    5) 自定义"
  echo "    6) 取消限制"
  read -p "  请选择 (1): " bw_choice
  case "$bw_choice" in
    2) bw_action="set"; new_up=30;  new_down=80 ;;
    3) bw_action="set"; new_up=100; new_down=300 ;;
    4) bw_action="set"; new_up=300; new_down=800 ;;
    5)
      bw_action="set"
      while true; do
        read -p "  上行 Mbps (正整数): " new_up
        if [ -n "$new_up" ] && [ "$new_up" -gt 0 ] 2>/dev/null; then break; fi
        echo -e "${R}必须为正整数${N}"
      done
      while true; do
        read -p "  下行 Mbps (正整数): " new_down
        if [ -n "$new_down" ] && [ "$new_down" -gt 0 ] 2>/dev/null; then break; fi
        echo -e "${R}必须为正整数${N}"
      done
      ;;
    6) bw_action="unset" ;;
    *) bw_action="keep" ;;
  esac

  # 端口跳跃修改
  echo ""
  if [ "$cur_hop" = "1" ]; then
    echo -e "  ${B}端口跳跃${N} (当前: ${C}${cur_hop_start}-${cur_hop_end}${N} / ${cur_hop_mode} 模式)："
  else
    echo -e "  ${B}端口跳跃${N} (当前: ${Y}未启用${N})："
  fi
  echo "    1) 保留当前设置（默认）"
  echo "    2) 切换/启用 自动范围（基于新主端口）"
  echo "    3) 切换/启用 自定义范围"
  echo "    4) 关闭端口跳跃"
  read -p "  请选择 (1): " hop_choice
  case "$hop_choice" in
    2)
      new_hop=1
      new_hop_mode="auto"
      read new_hop_start new_hop_end < <(port_hop_compute_range "$new_port")
      echo -e "  自动选择：${C}${new_hop_start}-${new_hop_end}${N}"
      ;;
    3)
      new_hop=1
      new_hop_mode="custom"
      echo -e "  ${D}格式：起始-结束（如 30000-31000），范围不能含主端口 ${new_port}${N}"
      while true; do
        read -p "  端口范围 (起始-结束): " range_input
        new_hop_start=$(echo "$range_input" | awk -F- '{print $1}' | tr -dc '0-9')
        new_hop_end=$(echo "$range_input" | awk -F- '{print $2}' | tr -dc '0-9')
        if [ -z "$new_hop_start" ] || [ -z "$new_hop_end" ]; then
          echo -e "  ${R}格式错误${N}"; continue
        fi
        if [ "$new_hop_start" -lt 1024 ] || [ "$new_hop_end" -gt 65535 ]; then
          echo -e "  ${R}端口必须在 1024-65535 之间${N}"; continue
        fi
        if [ "$new_hop_start" -ge "$new_hop_end" ]; then
          echo -e "  ${R}起始端口必须小于结束端口${N}"; continue
        fi
        if [ "$new_port" -ge "$new_hop_start" ] && [ "$new_port" -le "$new_hop_end" ]; then
          echo -e "  ${R}范围不能包含主端口 $new_port${N}"; continue
        fi
        if [ $((new_hop_end - new_hop_start)) -lt 50 ]; then
          echo -e "  ${Y}警告：范围只有 $((new_hop_end-new_hop_start+1)) 个端口${N}"
          read -p "  仍然使用？(y/N): " confirm_small
          if [ "$confirm_small" != "y" ] && [ "$confirm_small" != "Y" ]; then continue; fi
        fi
        break
      done
      ;;
    4)
      new_hop=0
      new_hop_mode=""
      new_hop_start=""
      new_hop_end=""
      ;;
    *)
      # 保留当前设置：若主端口变了且原模式是 auto，则按新端口重算
      new_hop="$cur_hop"
      new_hop_mode="$cur_hop_mode"
      new_hop_start="$cur_hop_start"
      new_hop_end="$cur_hop_end"
      if [ "$cur_hop" = "1" ] && [ "$new_port" != "$cur_port" ]; then
        if [ "$cur_hop_mode" = "auto" ]; then
          read new_hop_start new_hop_end < <(port_hop_compute_range "$new_port")
          echo -e "  ${D}主端口已变，自动范围重算为 ${new_hop_start}-${new_hop_end}${N}"
        else
          # 自定义模式下主端口变了，校验老范围是否仍然合法
          if [ "$new_port" -ge "$cur_hop_start" ] && [ "$new_port" -le "$cur_hop_end" ]; then
            echo -e "  ${Y}新主端口落在原自定义范围内 (${cur_hop_start}-${cur_hop_end})${N}"
            echo -e "  ${Y}请重新输入自定义范围${N}"
            new_hop_mode="custom"
            while true; do
              read -p "  新端口范围 (起始-结束): " range_input
              new_hop_start=$(echo "$range_input" | awk -F- '{print $1}' | tr -dc '0-9')
              new_hop_end=$(echo "$range_input" | awk -F- '{print $2}' | tr -dc '0-9')
              if [ -z "$new_hop_start" ] || [ -z "$new_hop_end" ] \
                 || [ "$new_hop_start" -lt 1024 ] || [ "$new_hop_end" -gt 65535 ] \
                 || [ "$new_hop_start" -ge "$new_hop_end" ] \
                 || ([ "$new_port" -ge "$new_hop_start" ] && [ "$new_port" -le "$new_hop_end" ]); then
                echo -e "  ${R}范围非法，请重输${N}"; continue
              fi
              break
            done
          fi
        fi
      fi
      ;;
  esac

  echo ""
  echo -e "  将写入：端口 ${C}$new_port${N}  SNI ${C}$new_sni${N}"
  if [ "$bw_action" = "set" ]; then
    echo -e "  带宽限制：${C}上 ${new_up} / 下 ${new_down} Mbps${N}"
  elif [ "$bw_action" = "unset" ]; then
    echo -e "  带宽限制：${Y}取消限制${N}"
  fi
  if [ "$new_hop" = "1" ]; then
    echo -e "  端口跳跃：${C}${new_hop_start}-${new_hop_end}${N} (${new_hop_mode})"
  elif [ "$cur_hop" = "1" ] && [ "$new_hop" != "1" ]; then
    echo -e "  端口跳跃：${Y}关闭${N}"
  fi
  read -p "  确认修改？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  if ! cp "$CONFIG_PATH" "$backup_path"; then
    echo -e "${R}配置备份失败${N}"
    pause_screen
    return 1
  fi

  ensure_jq || { pause_screen; return 1; }

  # 自签时若 SNI 改变，重签证书
  if [ "$cur_cert_src" = "self" ] && [ "$new_sni" != "$cur_sni" ]; then
    echo -e "${Y}==> SNI 变更，重新生成自签证书...${N}"
    if ! generate_self_signed_cert_for_hy2 "$new_sni" >/dev/null; then
      echo -e "${R}自签证书生成失败${N}"
      pause_screen
      return 1
    fi
  fi

  local jq_filter='(.inbounds[] | select(.tag == "hy2-in"))
    |= ( .listen_port = ($port | tonumber)
       | .tls.server_name = $sni
       | (if $sni != "" and (.tls.acme | type) == "object" then .tls.acme.domain = [$sni] else . end)
       | (if $pw != "" then .users[0].password = $pw else . end)
       | (if $opw != "" and (.obfs | type) == "object" then .obfs.password = $opw else . end)
       | .users[0] |= del(.up_mbps, .down_mbps)
       | (if $bw_action == "set"
          then .up_mbps = ($up | tonumber) | .down_mbps = ($down | tonumber)
          elif $bw_action == "unset"
          then del(.up_mbps, .down_mbps)
          else . end))'

  local tmp_file
  tmp_file=$(mktemp)
  trap 'rm -f "$tmp_file"' RETURN INT TERM
  if ! jq --arg port "$new_port" --arg sni "$new_sni" \
       --arg pw "${new_pw:-}" --arg opw "${new_obfs_pw:-}" \
       --arg bw_action "$bw_action" --arg up "$new_up" --arg down "$new_down" \
       "$jq_filter" "$CONFIG_PATH" > "$tmp_file"; then
    rm -f "$tmp_file"
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    echo -e "${R}配置写入失败，已恢复备份${N}"
    pause_screen
    return 1
  fi
  mv "$tmp_file" "$CONFIG_PATH"

  if ! sing-box check -c "$CONFIG_PATH"; then
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    echo ""
    echo -e "${R}配置校验失败，已恢复备份${N}"
    pause_screen
    return 1
  fi
  if ! systemctl restart sing-box; then
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    echo ""
    echo -e "${R}服务重启失败，已恢复备份${N}"
    pause_screen
    return 1
  fi

  # 端口跳跃规则同步：先清旧的，再加新的
  local need_remove_hop=0
  if [ "$cur_hop" = "1" ] && [ -n "$cur_hop_start" ] && [ -n "$cur_hop_end" ]; then
    # 旧的启用，且：新的禁用 / 范围变了 / 模式变了 / 主端口变了
    if [ "$new_hop" != "1" ] \
       || [ "$cur_hop_start" != "$new_hop_start" ] \
       || [ "$cur_hop_end" != "$new_hop_end" ] \
       || [ "$cur_port" != "$new_port" ]; then
      need_remove_hop=1
    fi
  fi
  if [ "$need_remove_hop" = "1" ]; then
    port_hop_remove "$cur_hop_start" "$cur_hop_end" "$cur_mode"
    echo -e "  ${D}旧端口跳跃规则已清理${N}"
  fi
  if [ "$new_hop" = "1" ] && [ -n "$new_hop_start" ] && [ -n "$new_hop_end" ]; then
    local listen_v4="" listen_v6="" public_ipv6_now="" addrs_pair
    public_ipv6_now=$(detect_primary_ipv6 2>/dev/null || true)
    addrs_pair=$(port_hop_listen_addrs_for_mode "$cur_mode" "$public_ipv6_now")
    listen_v4="${addrs_pair%|*}"
    listen_v6="${addrs_pair#*|}"
    port_hop_apply "$new_port" "$new_hop_start" "$new_hop_end" "$cur_mode" "$listen_v4" "$listen_v6"
    echo -e "  ${G}新端口跳跃规则已应用：${new_hop_start}-${new_hop_end}${N}"
  fi

  # 写回 hy2.info
  set_node_value hy2 Port "$new_port"
  set_node_value hy2 SNI  "$new_sni"
  [ -n "$new_pw" ] && set_node_value hy2 Password "$new_pw"
  [ -n "$new_obfs_pw" ] && set_node_value hy2 ObfsPassword "$new_obfs_pw"
  case "$bw_action" in
    set)
      set_node_value hy2 UpMbps "$new_up"
      set_node_value hy2 DownMbps "$new_down"
      ;;
    unset)
      # 清空（以空字符串覆盖；后续读取会判空）
      set_node_value hy2 UpMbps ""
      set_node_value hy2 DownMbps ""
      ;;
  esac
  if [ "$new_hop" = "1" ]; then
    set_node_value hy2 PortHop "1"
    set_node_value hy2 PortHopMode "$new_hop_mode"
    set_node_value hy2 PortHopStart "$new_hop_start"
    set_node_value hy2 PortHopEnd "$new_hop_end"
  else
    set_node_value hy2 PortHop "0"
    set_node_value hy2 PortHopMode ""
    set_node_value hy2 PortHopStart ""
    set_node_value hy2 PortHopEnd ""
  fi

  local cur_ip cur_tag insecure obfs_type final_pw final_obfs_pw new_link ipv6_new_link
  cur_ip=$(get_node_value hy2 IP 2>/dev/null || true)
  cur_tag=$(get_node_value hy2 Tag 2>/dev/null || echo hy2)
  insecure=$(get_node_value hy2 Insecure 2>/dev/null || echo 0)
  obfs_type=$(get_node_value hy2 Obfs 2>/dev/null || true)
  [ "$obfs_type" = "none" ] && obfs_type=""
  final_pw="${new_pw:-$cur_pw}"
  final_obfs_pw="${new_obfs_pw:-$cur_obfs_pw}"
  local link_hop_start="" link_hop_end=""
  if [ "$new_hop" = "1" ]; then
    link_hop_start="$new_hop_start"
    link_hop_end="$new_hop_end"
  fi
  new_link=$(build_hy2_link "$final_pw" "$cur_ip" "$new_port" "$new_sni" "$insecure" "$obfs_type" "$final_obfs_pw" "${cur_tag:-hy2}" "$link_hop_start" "$link_hop_end" 2>/dev/null || true)
  ipv6_new_link=$(build_dualstack_ipv6_link_for_node hy2 2>/dev/null || true)
  [ -n "$new_link" ] && set_node_value hy2 Link "$new_link"
  if [ -n "$new_port" ] && [ "$new_port" != "$cur_port" ]; then
    local hy2_mode_now
    hy2_mode_now=$(get_node_value hy2 Mode 2>/dev/null || echo ipv4)
    # 旧端口先撤、新端口再开（双栈/v6 模式同时处理 v4/v6）
    [ -n "$cur_port" ] && node_revoke_firewall_for_mode "$cur_port" udp "$hy2_mode_now"
    node_apply_firewall_for_mode "$new_port" udp "$hy2_mode_now"
    print_firewall_hint "$new_port" udp "Hysteria2 节点新端口"
  fi
  cleanup_old_backups "${CONFIG_PATH}.bak.*" 5

  echo ""
  echo -e "${G}Hysteria2 节点参数已更新并重启服务${N}"
  echo -e "  备份文件：${D}$backup_path${N}"
  if [ -n "$new_link" ]; then
    echo ""
    echo -e "  ${B}新客户端链接：${N}"
    echo -e "  ${G}$new_link${N}"
    print_qrcode "$new_link"
  fi
  if [ -n "$ipv6_new_link" ]; then
    echo ""
    echo -e "  ${B}新 IPv6 客户端链接：${N}"
    echo -e "  ${G}$ipv6_new_link${N}"
    print_qrcode "$ipv6_new_link"
  fi
  pause_screen
}

# ─── 完整卸载脚本 ─────────────────────────────────────
# 清理范围：节点 inbound、节点防火墙端口、sing-box 服务与软件包、
#          /etc/sing-box（含 nodes/、certs/、备份）、
#          legacy /root/proxy-info.txt、/usr/local/bin/sb。
# 不动：SSH 端口/sshd 配置、用户账户、sudoers、自动更新策略、
#        IPv6 防火墙菜单规则、1Panel、apt 基础工具、
#        TCP 网络优化、initcwnd 持久化服务、本脚本创建的 SWAP。
uninstall_script_completely(){
  if ! require_root; then return 1; fi

  render_section_header "卸载脚本"
  echo ""
  echo -e "  ${R}此操作将清除以下内容（不可恢复）：${N}"
  echo -e "    ${L}·${N} 所有 sing-box 节点（Reality / Hysteria2）及其防火墙端口"
  echo -e "    ${L}·${N} sing-box 服务、软件包与 ${C}/etc/sing-box${N} 整个目录"
  echo -e "    ${L}·${N} ${C}${INFO_PATH}${N} 与 ${C}${SCRIPT_PATH}${N}"
  echo ""
  echo -e "  ${D}保留：SSH 配置 / 用户账户 / sudoers / 自动更新 / IPv6 防火墙规则 / 1Panel${N}"
  echo -e "  ${D}保留：TCP 网络优化 / initcwnd 持久化服务 / 本脚本创建的 SWAP${N}"
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
        hy2)
          [ -n "$port" ] && deny_port_in_firewall "$port" udp
          cert_src=$(get_node_value "$node" CertSource 2>/dev/null || true)
          # ACME 模式安装时放行过 80/tcp，此处一并撤销
          if [ "$cert_src" = "acme" ]; then
            deny_port_in_firewall 80 tcp
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

  # 3. 脚本痕迹
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
CARD_INNER_WIDTH=52

# 计算字符串可见宽度（剥除 ANSI 颜色码）
# 直接看 UTF-8 字节头：ASCII 与 2 字节字符按 1 列、3 字节 / 4 字节按 2 列。
# 不依赖 wc -m 的 locale 行为，C / POSIX locale 下也能正确算 CJK 宽度。
# 注意：● 与 box-drawing 字符 ─ ╭ ╮ ╰ ╯ │ 这些 "3 字节 UTF-8 但实际单倍宽"
# 的字符会被高估 1，所以本框架不在被测内容里使用它们（边框由本框架自身绘制）。
_card_visible(){
  local s
  s=$(printf '%b' "$1" | sed $'s/\x1b\\[[0-9;]*[a-zA-Z]//g')
  printf '%s' "$s" | od -An -tu1 | awk '
    BEGIN { n = 0 }
    {
      for (i = 1; i <= NF; i++) {
        b = $i + 0
        if (b < 128) n += 1
        else if (b < 192) continue
        else if (b < 224) n += 1
        else if (b < 240) n += 2
        else            n += 2
      }
    }
    END { print n }
  '
}

# 卡片空白行
render_card_blank(){
  echo -e "  ${L}│${N}$(printf '%*s' "$CARD_INNER_WIDTH" '')${L}│${N}"
}

# 拼接 N 个 ─（避开 tr ' ' '─'：多数 tr 实现只能单字节替换，会把 ─ 截成 0xE2 乱码）
_card_dash_fill(){
  local n="$1" out="" i
  for ((i = 0; i < n; i++)); do out+='─'; done
  printf '%s' "$out"
}

# 卡片普通行（自动右侧补空格到内宽）
render_card_line(){
  local content="$1" visible pad
  visible=$(_card_visible "$content")
  pad=$((CARD_INNER_WIDTH - visible))
  [ "$pad" -lt 0 ] && pad=0
  echo -e "  ${L}│${N}${content}$(printf '%*s' "$pad" '')${L}│${N}"
}

# 卡片顶部：╭─ TITLE ─...─ RIGHT ─╮
render_card_top(){
  local title="$1" right="$2"
  local title_w right_w fill_w fill
  title_w=$(_card_visible "$title")
  right_w=$(_card_visible "$right")
  # 内宽 = 1(─) + 1(空) + title + 1(空) + N + 1(空) + right + 1(空) + 1(─)
  fill_w=$((CARD_INNER_WIDTH - 6 - title_w - right_w))
  [ "$fill_w" -lt 1 ] && fill_w=1
  fill=$(_card_dash_fill "$fill_w")
  echo -e "  ${L}╭─${N} ${title} ${L}${fill}${N} ${right} ${L}─╮${N}"
}

# 卡片底部
render_card_bottom(){
  local fill
  fill=$(_card_dash_fill "$CARD_INNER_WIDTH")
  echo -e "  ${L}╰${fill}╯${N}"
}

# ─── 节点行（占两排：状态/端口/IP + 网络方向；未安装时只占一排） ───
render_node_card_block(){
  local type="$1" label
  case "$type" in
    reality) label="Reality    " ;;   # 11 可见列：7 + 4 sp
    hy2)     label="Hysteria2  " ;;   # 11 可见列：9 + 2 sp
    *)       label=$(printf '%-11s' "$type") ;;
  esac

  if ! node_installed "$type"; then
    render_card_line "   ${C}${label}${N}${Y}未安装${N}"
    return
  fi

  local port ip mode_label
  port=$(get_node_value "$type" Port 2>/dev/null || true)
  ip=$(get_node_value "$type" IP 2>/dev/null || true)
  mode_label=$(describe_install_mode "$(get_node_value "$type" Mode 2>/dev/null || echo ipv4)")

  # 让短端口和长端口的 IP 起始列尽量对齐
  local port_len gap gap_str
  port_len=${#port}
  gap=$((7 - port_len))
  [ "$gap" -lt 1 ] && gap=1
  gap_str=$(printf '%*s' "$gap" '')

  # 附加信息：HY2 端口跳跃 / 链式中转
  local extra=""
  if [ "$type" = "hy2" ]; then
    local hop_v
    hop_v=$(get_node_value "$type" PortHop 2>/dev/null || echo 0)
    [ "$hop_v" = "1" ] && extra="  ${C}+hop${N}"
  fi
  if chain_installed "$type"; then
    local target_host target_port
    target_host=$(get_chain_value "$type" TargetHost 2>/dev/null || true)
    target_port=$(get_chain_value "$type" TargetPort 2>/dev/null || true)
    extra="${extra}  ${Y}↳中转→${target_host:-?}:${target_port:-?}${N}"
  fi

  # 第一行：协议名 + 已安装 + :端口 + IP + 附加
  render_card_line "   ${C}${label}${N}${G}已安装${N}  :${C}${port:-?}${N}${gap_str}${C}${ip:-?}${N}${extra}"
  # 第二行：网络方向（缩进对齐到第一行的状态列）
  render_card_line "              ${D}${mode_label}${N}"
}

# TCP 调优行（单排）
render_tcp_card_line(){
  local label="TCP 调优   "  # 11 可见列
  if [ ! -f "$TCP_TUNING_PATH" ]; then
    render_card_line "   ${C}${label}${N}${D}未启用${N}"
    return
  fi
  local profile_line region="" mem_tier="" region_label="" mem_label=""
  profile_line=$(awk '/^# leyili-profile:/ { print; exit }' "$TCP_TUNING_PATH" 2>/dev/null)
  if [ -n "$profile_line" ]; then
    region=$(printf '%s\n' "$profile_line" | sed -n 's/.*region=\([a-z-]\+\).*/\1/p')
    mem_tier=$(printf '%s\n' "$profile_line" | sed -n 's/.*mem_tier=\([a-z0-9]\+\).*/\1/p')
    case "$region" in
      hk)      region_label="香港" ;;
      jp)      region_label="日本" ;;
      us-west) region_label="美西" ;;
      eu)      region_label="欧洲" ;;
    esac
    case "$mem_tier" in
      1g) mem_label="1G"  ;;
      2g) mem_label="2G"  ;;
      4g) mem_label="4G"  ;;
      8g) mem_label="8G+" ;;
    esac
  fi
  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  if [ -n "$region_label" ] && [ -n "$mem_label" ]; then
    render_card_line "   ${C}${label}${N}${G}已启用${N} ${D}·${N} ${C}${region_label}/${mem_label}${N} ${D}·${N} ${D}cc=${cc}${N}"
  else
    render_card_line "   ${C}${label}${N}${G}已启用${N} ${D}·${N} ${D}cc=${cc}${N}"
  fi
}

# initcwnd 行（单排）
render_initcwnd_card_line(){
  local label="initcwnd   "  # 11 可见列
  if ! command -v ip >/dev/null 2>&1; then
    render_card_line "   ${C}${label}${N}${D}未知 (ip 命令缺失)${N}"
    return
  fi
  local route_line val persist
  route_line=$(ip route show default 2>/dev/null | head -n1)
  if [ -z "$route_line" ]; then
    render_card_line "   ${C}${label}${N}${D}无默认路由${N}"
    return
  fi
  val=$(printf '%s\n' "$route_line" | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i == "initcwnd") { print $(i + 1); exit }
    }
  }')
  if [ -z "$val" ]; then
    render_card_line "   ${C}${label}${N}${D}未设置${N}"
    return
  fi
  if [ -f "$INITCWND_SERVICE_PATH" ] \
     && systemctl is-enabled "$(basename "$INITCWND_SERVICE_PATH")" >/dev/null 2>&1; then
    persist="${D}(已持久化)${N}"
  else
    persist="${Y}(未持久化)${N}"
  fi
  render_card_line "   ${C}${label}${N}${C}${val}${N}  ${persist}"
}

# 主菜单卡片：标题栏 + 协议块 + 系统调优行
render_main_menu_card(){
  local ver status status_str title
  if is_singbox_installed; then
    ver=$(sing-box version 2>/dev/null | head -1 | awk '{print $3}' || echo "未知")
    status=$(systemctl is-active sing-box 2>/dev/null || echo "未知")
    if [ "$status" = "active" ]; then
      status_str="${G}运行中${N}"
    else
      status_str="${R}${status}${N}"
    fi
  else
    ver="未安装"
    status_str="${Y}未安装${N}"
  fi

  title="${B}${C}管理菜单${N} ${D}·${N} ${C}v${ver}${N}"
  render_card_top "$title" "$status_str"
  render_card_blank
  render_node_card_block reality
  render_card_blank
  render_node_card_block hy2
  render_card_blank
  render_tcp_card_line
  render_initcwnd_card_line
  render_card_blank
  render_card_bottom
}

show_node_install_menu(){
  while true; do
    render_section_header "创建节点"
    render_menu_item 1 "创建 Reality 节点$(node_installed reality && echo "  ${D}(已安装，将覆盖)${N}")"
    render_menu_item 2 "创建 Hysteria2 节点$(node_installed hy2 && echo "  ${D}(已安装，将覆盖)${N}")"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice
    case $choice in
      1) install_reality_node; return ;;
      2) install_hy2_node; return ;;
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
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice
    case $choice in
      1) node_installed reality && uninstall_reality_node; return ;;
      2) node_installed hy2 && uninstall_hy2_node; return ;;
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

show_node_manage_menu(){
  while true; do
    render_section_header "节点 / 内核管理"
    render_menu_item 1 "创建节点 (Reality / Hysteria2)"
    render_menu_item 2 "卸载单个节点"
    render_menu_item 3 "升级 sing-box 内核"
    render_menu_item 4 "链式代理设置 (中转机)"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice
    case $choice in
      1) show_node_install_menu ;;
      2) show_node_uninstall_menu ;;
      3) upgrade_singbox_kernel ;;
      4) show_chain_menu ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

# ─── 链式代理（中转机） ──────────────────────────────
inbound_tag_for_type(){
  case "$1" in
    reality) printf 'reality-in' ;;
    hy2)     printf 'hy2-in' ;;
    *)       return 1 ;;
  esac
}

# 返回 "直连" / "中转→host:port (type)" / 空（节点不存在）
chain_describe(){
  local type="$1"
  if ! node_installed "$type"; then
    printf ''
    return
  fi
  if ! chain_installed "$type"; then
    printf '直连'
    return
  fi
  local target_host target_port target_type
  target_host=$(get_chain_value "$type" TargetHost)
  target_port=$(get_chain_value "$type" TargetPort)
  target_type=$(get_chain_value "$type" TargetType)
  printf '中转→%s:%s (%s)' "${target_host:-?}" "${target_port:-?}" "${target_type:-?}"
}

# 配置中转：解析链接 → 写 chain.info → 加 outbound → 加路由规则 → 重启
chain_set(){
  local inbound_type="$1" link="$2"
  local inbound_tag outbound_tag
  inbound_tag=$(inbound_tag_for_type "$inbound_type") || return 1
  outbound_tag="chain-${inbound_type}-out"

  if ! node_installed "$inbound_type"; then
    echo -e "${R}本机未安装 ${inbound_type} 入站节点${N}"
    return 1
  fi

  ensure_jq || return 1

  # 先解析链接，校验有效
  local fields target_type target_host target_port target_sni
  fields=$(parse_node_link "$link") || {
    echo -e "${R}无法解析链接，请检查格式${N}"
    return 1
  }
  target_type=$(printf '%s\n' "$fields" | sed -n 's/^Type=//p' | head -1)
  target_host=$(printf '%s\n' "$fields" | sed -n 's/^Host=//p' | head -1)
  target_port=$(printf '%s\n' "$fields" | sed -n 's/^Port=//p' | head -1)
  target_sni=$(printf '%s\n' "$fields" | sed -n 's/^SNI=//p' | head -1)

  if [ -z "$target_type" ] || [ -z "$target_host" ] || [ -z "$target_port" ]; then
    echo -e "${R}链接缺少必要字段${N}"
    return 1
  fi

  # 自连环检查（粗略）
  local my_v4 my_v6
  my_v4=$(detect_primary_ipv4 2>/dev/null || true)
  my_v6=$(detect_primary_ipv6 2>/dev/null || true)
  if [ -n "$target_host" ] && { [ "$target_host" = "$my_v4" ] || [ "$target_host" = "$my_v6" ]; }; then
    echo ""
    echo -e "${R}${B}警告：落地机地址 ${target_host} 与本机 IP 相同${N}"
    echo -e "${Y}这会形成路由回环，sing-box 启动会失败${N}"
    local confirm_loop
    read -p "  仍然继续？(y/N): " confirm_loop
    if [ "$confirm_loop" != "y" ] && [ "$confirm_loop" != "Y" ]; then
      echo -e "  已取消"
      return 1
    fi
  fi

  echo -e "${Y}==> 解析落地机信息...${N}"
  echo -e "  类型 : ${C}${target_type}${N}"
  echo -e "  地址 : ${C}${target_host}:${target_port}${N}"
  echo -e "  SNI  : ${C}${target_sni:-未指定}${N}"

  # 构造 outbound JSON
  local outbound_json
  outbound_json=$(build_chain_outbound_from_link "$link" "$outbound_tag") || {
    echo -e "${R}构造 outbound 失败${N}"
    return 1
  }

  # 备份配置
  local backup_path
  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_PATH" "$backup_path" 2>/dev/null || true

  # 写 outbound + 路由规则
  if ! config_add_outbound "$outbound_json"; then
    echo -e "${R}写入 outbound 失败${N}"
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    return 1
  fi
  if ! config_set_inbound_chain "$inbound_tag" "$outbound_tag"; then
    echo -e "${R}写入路由规则失败${N}"
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    return 1
  fi

  # 校验 + 重启
  echo -e "${Y}==> 校验并重启 sing-box...${N}"
  if ! sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${R}配置校验失败，已恢复备份${N}"
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    return 1
  fi
  if ! systemctl restart sing-box; then
    echo -e "${R}sing-box 重启失败，已恢复备份${N}"
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    return 1
  fi

  # 持久化 chain.info
  ensure_chains_dir
  cat > "$(chain_info_path "$inbound_type")" <<EOF
TargetType=${target_type}
TargetHost=${target_host}
TargetPort=${target_port}
TargetSNI=${target_sni}
TargetUUID=$(printf '%s\n' "$fields" | sed -n 's/^UUID=//p' | head -1)
TargetPubKey=$(printf '%s\n' "$fields" | sed -n 's/^PublicKey=//p' | head -1)
TargetShortID=$(printf '%s\n' "$fields" | sed -n 's/^ShortID=//p' | head -1)
TargetPassword=$(printf '%s\n' "$fields" | sed -n 's/^Password=//p' | head -1)
TargetInsecure=$(printf '%s\n' "$fields" | sed -n 's/^Insecure=//p' | head -1)
TargetObfs=$(printf '%s\n' "$fields" | sed -n 's/^Obfs=//p' | head -1)
TargetObfsPassword=$(printf '%s\n' "$fields" | sed -n 's/^ObfsPassword=//p' | head -1)
EOF

  set_node_value "$inbound_type" Chain "$outbound_tag"
  cleanup_old_backups "${CONFIG_PATH}.bak.*" 5

  echo ""
  echo -e "${G}已配置：${inbound_type} 入站 → 中转到 ${target_host}:${target_port} (${target_type})${N}"
  return 0
}

chain_unset(){
  local inbound_type="$1"
  local inbound_tag outbound_tag
  inbound_tag=$(inbound_tag_for_type "$inbound_type") || return 1
  outbound_tag="chain-${inbound_type}-out"

  if ! chain_installed "$inbound_type"; then
    echo -e "${Y}${inbound_type} 当前未配置中转${N}"
    return 0
  fi

  local backup_path
  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_PATH" "$backup_path" 2>/dev/null || true

  config_remove_inbound_chain "$inbound_tag" || true
  config_remove_outbound_by_tag "$outbound_tag" || true

  echo -e "${Y}==> 校验并重启 sing-box...${N}"
  if ! sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${R}配置校验失败，已恢复备份${N}"
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    return 1
  fi
  if ! systemctl restart sing-box; then
    echo -e "${R}sing-box 重启失败，已恢复备份${N}"
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    return 1
  fi

  remove_chain_info "$inbound_type"
  set_node_value "$inbound_type" Chain "direct"
  cleanup_old_backups "${CONFIG_PATH}.bak.*" 5

  echo -e "${G}已恢复：${inbound_type} 入站 → 直连${N}"
}

# 让用户在已装的 inbound 中挑一个返回类型字符串
select_inbound_for_chain(){
  local prompt_label="${1:-请选择入站节点}"
  local arr=() n input i count
  while IFS= read -r n; do
    [ -n "$n" ] && arr+=("$n")
  done < <(list_installed_nodes)
  count=${#arr[@]}
  if [ "$count" -eq 0 ]; then
    return 1
  fi
  if [ "$count" -eq 1 ]; then
    printf '%s' "${arr[0]}"
    return 0
  fi
  {
    echo ""
    echo "  ${prompt_label}："
    i=1
    for n in "${arr[@]}"; do
      local desc
      desc=$(chain_describe "$n")
      echo "    $i) $n  ${desc:+(当前: $desc)}"
      i=$((i + 1))
    done
  } >&2
  read -p "  请输入序号 (1): " input >&2
  input="${input:-1}"
  if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "$count" ]; then
    printf '%s' "${arr[$((input - 1))]}"
    return 0
  fi
  return 1
}

show_chain_menu(){
  local target link confirm
  if ! require_root; then return 1; fi
  if ! require_singbox_installed; then return 1; fi

  while true; do
    render_section_header "链式代理设置（中转机）"

    # ─── 教程提示 ───
    echo -e "  ${B}${C}什么是链式代理？${N}"
    echo -e "  ${D}客户端 → ${C}中转机 A${D} → ${C}落地机 B${D} → 互联网${N}"
    echo -e "  ${D}用 A 的入站接客户端，A 把流量再转到 B 出网，外面看到的是 B 的 IP。${N}"
    echo ""
    echo -e "  ${B}${C}典型流程${N}（两台 VPS 都跑这个脚本）"
    echo -e "  ${Y}①${N} 落地机 B：装节点 → 主菜单 ${C}4) 查看状态${N} → ${C}7) 查看客户端链接 / 二维码${N} → 复制"
    echo -e "  ${Y}②${N} 中转机 A：装节点（客户端实际连的就是 A 的这个入站）"
    echo -e "  ${Y}③${N} 中转机 A：${C}本菜单 → 1) 配置中转${N} → 选入站 → 粘贴 B 的链接"
    echo -e "  ${Y}④${N} 客户端连 A，访问 ipify.org 应看到 B 的 IP，搞定"
    echo ""
    echo -e "  ${D}· 我是中转机？→ 1) 粘贴落地机链接${N}"
    echo -e "  ${D}· 我是落地机？→ 啥都不用做，3) 把本机链接复制给中转机用即可${N}"
    echo -e "  ${D}· 每个入站（Reality / HY2）可独立选直连或中转，互不影响${N}"
    echo -e "  ${D}· 详细教程：HY2-节点搭建说明.md 第十一节${N}"
    render_divider

    if [ "$(count_installed_nodes)" -eq 0 ]; then
      echo -e "  ${Y}本机尚未创建任何入站节点${N}"
      echo -e "  ${D}请先回到「节点 / 内核管理 → 创建节点」装一个 Reality 或 Hysteria2，${N}"
      echo -e "  ${D}它们会作为客户端连接的入口，再回来配链路${N}"
      echo ""
      pause_screen
      return 0
    fi

    # ─── 当前状态：列每个已装入站的链路 ───
    echo -e "  ${B}${C}本机入站链路状态${N}"
    local n desc
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      desc=$(chain_describe "$n")
      printf "  ${L}│${N}  %-10s ${D}·${N}  %s\n" "$n" "${desc:-未知}"
    done < <(list_installed_nodes)
    render_divider
    render_menu_item 1 "配置中转 (选入站 → 粘贴落地机链接)"
    render_menu_item 2 "取消中转 (选入站 → 恢复直连)"
    render_menu_item 3 "导出本机入站链接（让别的中转机连本机）"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice
    case "$choice" in
      1)
        target=$(select_inbound_for_chain "选要配中转的入站") || { echo -e "${R}选择无效${N}"; pause_screen; continue; }
        echo ""
        echo -e "  ${B}请粘贴落地机的客户端链接${N}"
        echo -e "  ${D}（在落地机上跑 sb → 4) 查看状态 → 7) 查看客户端链接 / 二维码 复制）${N}"
        echo -e "  ${D}支持格式：vless://...reality...   或   hysteria2://...${N}"
        read -p "  链接: " link
        link="${link%%[[:space:]]}"
        if [ -z "$link" ]; then
          echo -e "${Y}已取消${N}"
          pause_screen
          continue
        fi
        if chain_installed "$target"; then
          echo -e "${Y}${target} 已配置中转，将覆盖${N}"
          read -p "  继续？(y/N): " confirm
          if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo -e "  已取消"
            pause_screen
            continue
          fi
        fi
        chain_set "$target" "$link" || true
        pause_screen
        ;;
      2)
        target=$(select_inbound_for_chain "选要取消中转的入站") || { echo -e "${R}选择无效${N}"; pause_screen; continue; }
        if ! chain_installed "$target"; then
          echo -e "${Y}${target} 当前是直连，无需取消${N}"
          pause_screen
          continue
        fi
        chain_unset "$target" || true
        pause_screen
        ;;
      3)
        show_client_link
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

show_menu(){
  local main_action_label=""

  while true; do
    migrate_legacy_info

    if is_singbox_installed && [ "$(count_installed_nodes)" -gt 0 ]; then
      main_action_label="节点 / 内核管理"
    else
      main_action_label="创建节点"
    fi

    clear
    render_brand_banner
    render_main_menu_card
    render_menu_item 1 "管理员设置"
    render_menu_item 2 "系统基础设置"
    render_menu_item 3 "${main_action_label}"
    render_menu_item 4 "查看状态"
    render_menu_item 5 "Docker 管理"
    render_menu_item 6 "IPv4 防火墙管理"
    render_menu_item 7 "IPv6 防火墙管理"
    render_menu_item 8 "卸载脚本"
    render_menu_item 9 "更新脚本"
    render_menu_item 0 "退出"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        show_admin_menu
        ;;
      2)
        show_system_menu
        ;;
      3)
        if ! is_singbox_installed || [ "$(count_installed_nodes)" -eq 0 ]; then
          show_node_install_menu
        else
          show_node_manage_menu
        fi
        ;;
      4)
        show_status_menu
        ;;
      5)
        show_docker_menu
        ;;
      6)
        show_ipv4_firewall_menu
        ;;
      7)
        show_ipv6_firewall_menu
        ;;
      8)
        uninstall_script_completely
        ;;
      9)
        update_self_script
        ;;
      0)
        exit 0
        ;;
      *)
        notify_invalid_choice
        ;;
    esac
  done
}

# ─── 入口判断 ─────────────────────────────────────────
if [ "${LEYILI_ALLOW_ANY_DISTRO:-0}" != "1" ]; then
  if ! require_debian_family; then
    exit 1
  fi
fi
register_sb_command || true
show_menu
