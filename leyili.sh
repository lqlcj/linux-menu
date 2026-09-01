#!/bin/bash
set -o pipefail
umask 077

SAGERNET_KEY_URL="https://deb.sagernet.org/gpg.key"
SAGERNET_KEY_FINGERPRINT="2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C"
SAGERNET_KEYRING="/etc/apt/keyrings/sagernet.asc"
SAGERNET_SOURCES="/etc/apt/sources.list.d/sagernet.sources"
SAGERNET_REPO_URI="https://deb.sagernet.org/"
CONFIG_PATH="/etc/sing-box/config.json"
INFO_PATH="/root/proxy-info.txt"
NODES_DIR="/etc/sing-box/nodes"
CERTS_DIR="/etc/sing-box/certs"
LEYILI_DIR="/etc/leyili"
LEYILI_STATE_DIR="${LEYILI_DIR}/state"
SAGERNET_REPO_STATE="${LEYILI_STATE_DIR}/sagernet-repo.state"
LEYILI_CACHE_DIR="/var/cache/leyili"
LEYILI_LOCK_PATH="/run/lock/leyili.lock"
FIREWALL_PORT_STATE="${LEYILI_STATE_DIR}/firewall-ports.state"

# 首页展示「最新稳定版」用的缓存（避免每次刷新菜单都请求 GitHub）
SINGBOX_LATEST_CACHE="${LEYILI_CACHE_DIR}/singbox-latest"
SINGBOX_LATEST_TTL="21600"     # 有效缓存 6 小时
SINGBOX_LATEST_NEG_TTL="300"   # 联网失败后 5 分钟内不再重试
APP_NAME="Leyili"
COMMAND_NAME="sb"
SCRIPT_PATH="/usr/local/bin/${COMMAND_NAME}"
SELF_INSTALL_URL="${SELF_INSTALL_URL:-https://raw.githubusercontent.com/lqlcj/linux-menu/main/leyili.sh}"
SELF_INSTALL_SHA256="${SELF_INSTALL_SHA256:-}"
# 自更新与入口安装共用的下载物大小区间（字节），防止把截断内容或整站错误页当脚本装上
SELF_PAYLOAD_MIN_BYTES="50000"
SELF_PAYLOAD_MAX_BYTES="2097152"
TCP_TUNING_PATH="/etc/sysctl.d/99-proxy-optimized.conf"
QUIC_TUNING_PATH="/etc/sysctl.d/99-quic-optimized.conf"
TCP_TUNING_STATE="${LEYILI_STATE_DIR}/tcp-sysctl.state"
TCP_QDISC_STATE="${LEYILI_STATE_DIR}/tcp-qdisc.state"
QUIC_TUNING_STATE="${LEYILI_STATE_DIR}/quic-sysctl.state"
INITCWND_SERVICE_PATH="/etc/systemd/system/initcwnd.service"
INITCWND_HELPER_PATH="/usr/local/libexec/leyili-initcwnd"
INITCWND_STATE_PATH="${LEYILI_STATE_DIR}/initcwnd.state"
INITCWND_VALUE="24"
SWAPFILE_PATH="/swapfile"
SWAP_SYSCTL_PATH="/etc/sysctl.d/99-swap-tuning.conf"
SWAP_STATE_PATH="${LEYILI_STATE_DIR}/swap.state"
SWAPPINESS_VALUE="10"

SYSTEM_TIMEZONE="Asia/Shanghai"
BASIC_TOOLS_PACKAGES="curl wget git vim htop unzip net-tools"
SSHD_CONFIG_PATH="/etc/ssh/sshd_config"
SUDOERS_DROPIN_DIR="/etc/sudoers.d"
SSH_RANDOM_PORT_MIN="20000"
SSH_RANDOM_PORT_MAX="65535"
SSHD_SOCKET_DROPIN_PATH="/etc/systemd/system/ssh.socket.d/99-leyili-port.conf"
FAIL2BAN_JAIL_PATH="/etc/fail2ban/jail.d/leyili-sshd.local"
FAIL2BAN_MAXRETRY="5"
FAIL2BAN_BANTIME="600"
FAIL2BAN_FINDTIME="300"
IP6_RULES_PATH_DEBIAN="/etc/iptables/rules.v6"
IP6_RULES_PATH_RHEL="/etc/sysconfig/ip6tables"
IP4_RULES_PATH_DEBIAN="/etc/iptables/rules.v4"
IP4_RULES_PATH_RHEL="/etc/sysconfig/iptables"
IP4_LEYILI_CHAIN="LEYILI_INPUT"
IP6_LEYILI_CHAIN="LEYILI6_INPUT"

# ─── WARP 谷歌解锁分流 ───────────────────────────────
WARP_APP_NAME="WARP 谷歌解锁分流"
WARP_DIR="/etc/leyili/warp"
WARP_ACCOUNT_JSON="${WARP_DIR}/account.json"
WARP_MANAGED_STATE="${WARP_DIR}/managed.state"
WARP_CACHE_DEFAULT="/var/lib/sing-box/cache.db"
# 旧版 wgcf 方案的遗留二进制路径：仅在卸载时清理用
WARP_WGCF_BIN="/usr/local/bin/wgcf"
# 模拟官方安卓客户端的注册 API（与 fscarmen/warp、warp-reg 同款参数）
WARP_API_BASE="https://api.cloudflareclient.com/v0a2158"
WARP_API_UA="okhttp/3.12.1"
WARP_API_CLIENT_VER="a-6.10-2158"
WARP_OUTBOUND_TAG="warp-out"
WARP_RULESET_TAG="geosite-google"
WARP_SNIFF_INBOUNDS_JSON='["reality-in","hy2-in","anytls-in","tuic-in","ss2022-in"]'
WARP_RULESET_COMMIT="db558913a68c00c07524b211472b968231874b5f"
WARP_RULESET_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/${WARP_RULESET_COMMIT}/geosite-google.srs"
WARP_RULESET_TAG_YT="geosite-youtube"
WARP_RULESET_URL_YT="https://raw.githubusercontent.com/SagerNet/sing-geosite/${WARP_RULESET_COMMIT}/geosite-youtube.srs"
WARP_PEER_PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
WARP_ENDPOINT_HOST="162.159.192.1"
WARP_ENDPOINT_PORT="2408"
WARP_MTU="1280"
# 端点优选候选（host:port，均为 Cloudflare WARP 官方段；WireGuard 仅 UDP）
WARP_ENDPOINT_CANDIDATES="162.159.192.1:2408 162.159.193.10:2408 188.114.96.1:2408 188.114.97.1:2408 engage.cloudflareclient.com:2408 162.159.192.1:500 162.159.192.1:894 162.159.192.1:878 162.159.192.1:1701 162.159.192.1:4500 188.114.96.1:934 162.159.193.10:943"

# ─── 颜色 ────────────────────────────────────────────
G="\033[32m" Y="\033[33m" C="\033[36m" R="\033[31m" B="\033[1m" N="\033[0m"
L="\033[94m" W="\033[97m" D="\033[2m"

# ─── 通用辅助 ────────────────────────────────────────
# ═══ source: 00-utils-head.sh ═══
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
  local dir base victim rc=0
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
    if [ -n "${victims[i]}" ] && ! rm -f -- "${victims[i]}"; then
      rc=1
    fi
  done
  return "$rc"
}

ensure_private_dir(){
  local dir="$1"
  local mode="${2:-700}"

  [ -n "$dir" ] || return 1
  if [ -L "$dir" ]; then
    echo -e "${R}拒绝使用符号链接目录：${dir}${N}" >&2
    return 1
  fi
  if ! install -d -m "$mode" "$dir" 2>/dev/null; then
    return 1
  fi
  chmod "$mode" "$dir" 2>/dev/null || return 1
}

ensure_leyili_state_dir(){
  ensure_private_dir "$LEYILI_DIR" 700 || return 1
  ensure_private_dir "$LEYILI_STATE_DIR" 700
}

atomic_replace_file(){
  local source="$1"
  local target="$2"
  local mode="${3:-600}"
  local target_dir tmp

  [ -f "$source" ] || return 1
  target_dir=$(dirname -- "$target")
  if [ -L "$target_dir" ]; then
    echo -e "${R}拒绝写入符号链接目录：${target_dir}${N}" >&2
    return 1
  fi
  mkdir -p "$target_dir" 2>/dev/null || return 1
  tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
  if ! install -m "$mode" "$source" "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$target"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# 从事务快照恢复文件：在目标目录内准备副本后原子替换，保留原权限/属主/时间戳。
restore_file_snapshot(){
  local source="$1"
  local target="$2"
  local target_dir stage_dir stage_file

  [ -e "$source" ] || return 1
  target_dir=$(dirname -- "$target")
  if [ -L "$target_dir" ]; then
    echo -e "${R}拒绝向符号链接目录恢复文件：${target_dir}${N}" >&2
    return 1
  fi
  mkdir -p -- "$target_dir" || return 1
  stage_dir=$(mktemp -d "${target_dir}/.leyili-restore.XXXXXX") || return 1
  chmod 700 "$stage_dir" 2>/dev/null || { rm -rf -- "$stage_dir"; return 1; }
  stage_file="${stage_dir}/snapshot"
  if ! cp -a -- "$source" "$stage_file"; then
    rm -rf -- "$stage_dir"
    return 1
  fi
  if ! mv -f -- "$stage_file" "$target"; then
    rm -rf -- "$stage_dir"
    return 1
  fi
  rmdir -- "$stage_dir" 2>/dev/null || true
}

# 脚本若要接管固定路径，先保存同名用户文件；移除功能时恢复，而不是写死默认值。
managed_file_prepare(){
  local path="$1"
  local marker_regex="${2:-Managed by Leyili|leyili-}"
  local original="${path}.leyili-original"

  if [ ! -e "$path" ]; then
    return 0
  fi
  if [ -L "$path" ]; then
    echo -e "${R}拒绝覆盖符号链接：${path}${N}" >&2
    return 1
  fi
  if grep -Eq "$marker_regex" "$path" 2>/dev/null; then
    return 0
  fi
  if [ -e "$original" ]; then
    echo -e "${R}检测到未托管文件及旧备份并存，拒绝覆盖：${path}${N}" >&2
    return 1
  fi
  cp -a -- "$path" "$original"
}

managed_file_restore(){
  local path="$1"
  local original="${path}.leyili-original"

  if [ -e "$original" ]; then
    mv -f -- "$original" "$path"
  else
    rm -f -- "$path"
  fi
}

managed_file_transaction_begin(){
  local path="$1"
  local marker_regex="${2:-Managed by Leyili|leyili-}"
  local txn original="${path}.leyili-original"

  txn=$(mktemp -d "${TMPDIR:-/tmp}/leyili-file.XXXXXX") || return 1
  chmod 700 "$txn" 2>/dev/null || { rm -rf -- "$txn"; return 1; }
  if [ -e "$path" ]; then
    cp -a -- "$path" "$txn/current" || { rm -rf -- "$txn"; return 1; }
    : > "$txn/current.existed"
  fi
  if [ -e "$original" ]; then
    cp -a -- "$original" "$txn/original" || { rm -rf -- "$txn"; return 1; }
    : > "$txn/original.preexisting"
  fi
  if ! managed_file_prepare "$path" "$marker_regex"; then
    rm -rf -- "$txn"
    return 1
  fi
  if [ -e "$original" ] && [ ! -f "$txn/original.preexisting" ]; then
    : > "$txn/original.created"
  fi
  printf '%s' "$txn"
}

managed_file_transaction_rollback(){
  local path="$1" txn="$2"
  local rc=0
  [ -d "$txn" ] || return 1
  if [ -f "$txn/current.existed" ]; then
    restore_file_snapshot "$txn/current" "$path" || rc=1
  else
    rm -f -- "$path" || rc=1
  fi
  if [ -f "$txn/original.preexisting" ]; then
    restore_file_snapshot "$txn/original" "${path}.leyili-original" || rc=1
  elif [ -f "$txn/original.created" ]; then
    rm -f -- "${path}.leyili-original" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    rm -rf -- "$txn" || rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    echo -e "${R}警告：文件事务回滚未完全成功，私有快照保留在 ${txn}${N}" >&2
  fi
  return "$rc"
}

managed_file_transaction_commit(){
  rm -rf -- "$1"
}

acquire_global_lock(){
  local lock_path="$LEYILI_LOCK_PATH"

  [ "${LEYILI_SKIP_LOCK:-0}" = "1" ] && return 0
  if [ "$(id -u)" -ne 0 ]; then
    lock_path="${TMPDIR:-/tmp}/leyili-${UID}.lock"
  else
    mkdir -p "$(dirname -- "$lock_path")" 2>/dev/null || return 1
  fi

  if command -v flock >/dev/null 2>&1; then
    # shellcheck disable=SC3045
    exec 9>"$lock_path" || return 1
    if ! flock -n 9; then
      echo -e "${Y}另一个 ${APP_NAME} 菜单正在运行，请先退出后重试。${N}" >&2
      return 1
    fi
    return 0
  fi

  LEYILI_LOCK_DIR="${lock_path}.d"
  if ! mkdir "$LEYILI_LOCK_DIR" 2>/dev/null; then
    echo -e "${Y}另一个 ${APP_NAME} 菜单可能正在运行：${LEYILI_LOCK_DIR}${N}" >&2
    return 1
  fi
  trap 'release_global_lock' EXIT
}

release_global_lock(){
  if [ -n "${LEYILI_LOCK_DIR:-}" ] && [ -d "$LEYILI_LOCK_DIR" ]; then
    rmdir -- "$LEYILI_LOCK_DIR" 2>/dev/null || true
  fi
}

config_transaction_begin(){
  local label="${1:-config}"
  local txn

  txn=$(mktemp -d "${TMPDIR:-/tmp}/leyili-${label}.XXXXXX") || return 1
  chmod 700 "$txn" 2>/dev/null || { rm -rf -- "$txn"; return 1; }
  if [ -f "$CONFIG_PATH" ]; then
    cp -a -- "$CONFIG_PATH" "$txn/config.json" || { rm -rf -- "$txn"; return 1; }
    : > "$txn/config.existed"
  fi
  if systemctl is-active --quiet sing-box 2>/dev/null; then
    : > "$txn/service.active"
  fi
  if systemctl is-enabled --quiet sing-box 2>/dev/null; then
    : > "$txn/service.enabled"
  fi
  printf '%s' "$txn"
}

config_transaction_restore(){
  local txn="$1"
  local rc=0

  [ -d "$txn" ] || return 1
  if [ -f "$txn/config.existed" ]; then
    restore_file_snapshot "$txn/config.json" "$CONFIG_PATH" || return 1
  else
    rm -f -- "$CONFIG_PATH" || return 1
  fi

  if command -v sing-box >/dev/null 2>&1; then
    if [ -f "$txn/service.enabled" ]; then
      systemctl enable sing-box >/dev/null 2>&1 || rc=1
    else
      systemctl disable sing-box >/dev/null 2>&1 || rc=1
    fi
    if [ -f "$txn/service.active" ]; then
      systemctl restart sing-box >/dev/null 2>&1 || rc=1
    else
      systemctl stop sing-box >/dev/null 2>&1 || rc=1
    fi
  fi
  return "$rc"
}

config_transaction_rollback(){
  local txn="$1"
  local rc=0
  config_transaction_restore "$txn" || rc=1
  if [ "$rc" -eq 0 ]; then
    rm -rf -- "$txn" || rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    echo -e "${R}警告：sing-box 配置/服务回滚未完全成功，私有快照保留在 ${txn}${N}" >&2
  fi
  return "$rc"
}

config_transaction_commit(){
  local txn="$1"
  rm -rf -- "$txn"
}

node_transaction_begin(){
  local type="$1"
  local txn info cert

  txn=$(config_transaction_begin "node-${type}") || return 1
  printf '%s\n' "$type" > "$txn/node.type"
  info="$NODES_DIR/${type}.info"
  if [ -f "$info" ]; then
    cp -a -- "$info" "$txn/node.info" || { config_transaction_rollback "$txn"; return 1; }
    : > "$txn/node.existed"
  fi
  case "$type" in
    hy2|tuic)
      for cert in "${type}.crt" "${type}.key"; do
        if [ -f "$CERTS_DIR/$cert" ]; then
          cp -a -- "$CERTS_DIR/$cert" "$txn/$cert" || { config_transaction_rollback "$txn"; return 1; }
          : > "$txn/${cert}.existed"
        fi
      done
      ;;
  esac
  if command -v iptables-save >/dev/null 2>&1; then
    iptables-save > "$txn/iptables.rules" 2>/dev/null || rm -f "$txn/iptables.rules"
  fi
  if command -v ip6tables-save >/dev/null 2>&1; then
    ip6tables-save > "$txn/ip6tables.rules" 2>/dev/null || rm -f "$txn/ip6tables.rules"
  fi
  if [ -f "$FIREWALL_PORT_STATE" ]; then
    cp -a -- "$FIREWALL_PORT_STATE" "$txn/firewall-ports.state" \
      || { config_transaction_rollback "$txn"; return 1; }
    : > "$txn/firewall-ports.existed"
  else
    : > "$txn/firewall-ports.state"
  fi
  printf '%s' "$txn"
}

node_transaction_rollback(){
  local txn="$1"
  local type info cert
  local rc=0

  [ -d "$txn" ] || return 1
  type=$(cat "$txn/node.type" 2>/dev/null)
  info="$NODES_DIR/${type}.info"
  config_transaction_restore "$txn" || rc=1

  ensure_nodes_dir >/dev/null 2>&1 || rc=1
  if [ -f "$txn/node.existed" ]; then
    restore_file_snapshot "$txn/node.info" "$info" || rc=1
  else
    rm -f -- "$info" || rc=1
  fi
  case "$type" in
    hy2|tuic)
      for cert in "${type}.crt" "${type}.key"; do
        if [ -f "$txn/${cert}.existed" ]; then
          restore_file_snapshot "$txn/$cert" "$CERTS_DIR/$cert" || rc=1
        else
          rm -f -- "$CERTS_DIR/$cert" || rc=1
        fi
      done
      ;;
  esac
  firewall_owned_ports_restore "$txn/firewall-ports.state" "$txn/firewall-ports.existed" || rc=1
  if [ -s "$txn/iptables.rules" ] && command -v iptables-restore >/dev/null 2>&1; then
    iptables-restore < "$txn/iptables.rules" 2>/dev/null || rc=1
    ip4_save_rules >/dev/null 2>&1 || rc=1
  fi
  if [ -s "$txn/ip6tables.rules" ] && command -v ip6tables-restore >/dev/null 2>&1; then
    ip6tables-restore < "$txn/ip6tables.rules" 2>/dev/null || rc=1
    ip6_save_rules >/dev/null 2>&1 || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    rm -rf -- "$txn" || rc=1
  fi
  [ "$rc" -eq 0 ] || echo -e "${R}警告：事务回滚有步骤失败，请立即检查 sing-box 与防火墙状态；快照保留在 ${txn}${N}" >&2
  return "$rc"
}

node_transaction_commit(){
  config_transaction_commit "$1"
}

write_node_info_file(){
  local type="$1"
  local target tmp

  ensure_nodes_dir || return 1
  target=$(node_info_path "$type")
  tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
  if ! cat > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$target"
}

sysctl_state_capture(){
  local state_file="$1"
  shift
  local key value

  [ -f "$state_file" ] && return 0
  ensure_leyili_state_dir || return 1
  : > "$state_file" || return 1
  chmod 600 "$state_file" 2>/dev/null || { rm -f -- "$state_file"; return 1; }
  for key in "$@"; do
    value=$(sysctl -n "$key" 2>/dev/null) || continue
    printf '%s=%s\n' "$key" "$value" >> "$state_file" || return 1
  done
}

sysctl_state_restore(){
  local state_file="$1"
  local key value rc=0

  [ -r "$state_file" ] || return 0
  while IFS='=' read -r key value; do
    [ -n "$key" ] || continue
    sysctl -w "${key}=${value}" >/dev/null 2>&1 || rc=1
  done < "$state_file"
  if [ "$rc" -eq 0 ]; then
    rm -f -- "$state_file" || rc=1
  else
    echo -e "${R}警告：部分 sysctl 参数恢复失败，状态快照已保留：${state_file}${N}" >&2
  fi
  return "$rc"
}
# ═══ source: 01-firewall-common.sh ═══
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
  if ufw_is_active; then
    printf '%s' "ufw"
    return
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    printf '%s' "firewalld"
    return
  fi

  printf '%s' "none"
}

# 优先读取 ufw 自身的启用状态文件，避免每次菜单刷新都启动 ufw 的 Python 前端
# 并再次遍历整套防火墙规则。旧安装没有状态文件时才回退到 ufw status。
ufw_is_active(){
  command -v ufw >/dev/null 2>&1 || return 1

  if [ -r /etc/ufw/ufw.conf ]; then
    grep -Eqi '^[[:space:]]*ENABLED[[:space:]]*=[[:space:]]*yes([[:space:]]|$)' /etc/ufw/ufw.conf
    return $?
  fi

  ufw status 2>/dev/null | grep -qi '^Status: active'
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

# 从 iptables-save / ip6tables-save 快照中读取链的默认策略。
firewall_policy_from_saved_rules(){
  local chain="${1:-INPUT}"
  awk -v chain="$chain" '
    $0 == "*filter" { in_filter = 1; next }
    in_filter && $0 == "COMMIT" { exit }
    in_filter && $1 == (":" chain) { print $2; exit }'
}

# 列出从 INPUT 可达的全部子链中，最终跳转到 ACCEPT 的显式 TCP/UDP 端口。
# 这样既能覆盖脚本专属链，也能覆盖 ufw 等管理器创建的子链；DROP/REJECT
# 端口不会被误报。输入必须是 iptables-save / ip6tables-save 的完整输出。
# 用法：... | firewall_list_opened_ports_from_saved_rules [lines|compact]
firewall_list_opened_ports_from_saved_rules(){
  local style="${1:-lines}"

  awk -v style="$style" '
    function add_port(proto, port, key) {
      proto = tolower(proto)
      if ((proto != "tcp" && proto != "udp") || port == "") return
      key = proto SUBSEP port
      if (seen[key]) return
      seen[key] = 1
      ordered_proto[++opened_count] = proto
      ordered_port[opened_count] = port
      if (proto == "tcp") tcp_port[++tcp_count] = port
      else                udp_port[++udp_count] = port
    }
    $0 == "*filter" {
      in_filter = 1
      next
    }
    in_filter && $0 == "COMMIT" {
      in_filter = 0
      next
    }
    in_filter {
      saved_rule[++rule_count] = $0
      if ($1 ~ /^:/) known_chain[substr($1, 2)] = 1
    }
    END {
      reachable["INPUT"] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (rule_no = 1; rule_no <= rule_count; rule_no++) {
          field_count = split(saved_rule[rule_no], field, /[[:space:]]+/)
          if (field[1] != "-A" || !(field[2] in reachable)) continue
          target = ""
          for (i = 3; i <= field_count; i++) {
            if ((field[i] == "-j" || field[i] == "-g") && i < field_count) {
              target = field[i + 1]
            }
          }
          if ((target in known_chain) && !(target in reachable)) {
            reachable[target] = 1
            changed = 1
          }
        }
      }

      for (rule_no = 1; rule_no <= rule_count; rule_no++) {
        field_count = split(saved_rule[rule_no], field, /[[:space:]]+/)
        if (field[1] != "-A" || !(field[2] in reachable)) continue
        proto = ""
        port = ""
        target = ""
        for (i = 3; i <= field_count; i++) {
          if (field[i] == "-p" && i < field_count && field[i - 1] != "!") {
            proto = field[i + 1]
          } else if ((field[i] == "--dport" || field[i] == "--dports" || field[i] == "--destination-port") \
                     && i < field_count && field[i - 1] != "!") {
            port = field[i + 1]
          } else if ((field[i] == "-j" || field[i] == "-g") && i < field_count) {
            target = field[i + 1]
          }
        }
        if (target == "ACCEPT") add_port(proto, port)
      }

      if (style == "compact") {
        output = ""
        if (tcp_count > 0) {
          output = "TCP "
          for (i = 1; i <= tcp_count; i++) output = output (i > 1 ? ", " : "") tcp_port[i]
        }
        if (udp_count > 0) {
          output = output (output != "" ? "  " : "") "UDP "
          for (i = 1; i <= udp_count; i++) output = output (i > 1 ? ", " : "") udp_port[i]
        }
        print output
      } else {
        for (i = 1; i <= opened_count; i++) {
          printf "  %s  %s\n", toupper(ordered_proto[i]), ordered_port[i]
        }
      }
    }'
}

ip6_list_opened_ports_compact(){
  ip6tables-save 2>/dev/null | firewall_list_opened_ports_from_saved_rules compact
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

  if ufw_is_active; then
    conflicts="${conflicts}ufw "
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    conflicts="${conflicts}firewalld "
  fi
  if ip4_detect_1panel; then
    conflicts="${conflicts}1Panel "
  fi

  printf '%s' "${conflicts% }"
}

# 单独检测 1Panel 是否在场（用于 IPv4 菜单托管接管）
ip4_detect_1panel(){
  local unit_dir unit

  [ -d /opt/1panel ] && return 0
  for unit_dir in /etc/systemd/system /run/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
    [ -d "$unit_dir" ] || continue
    for unit in "$unit_dir"/1panel*.service; do
      [ -e "$unit" ] || [ -L "$unit" ] || continue
      return 0
    done
  done
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
# ═══ source: 02-utils-ui.sh ═══
# ─── 脚本正文校验 ─────────────────────────────────────
# 自更新和入口安装都要判断「这坨下载内容是不是 Leyili 脚本」，
# 两处必须用同一套判据，否则改了一处另一处会悄悄放行。

leyili_payload_size_ok(){
  local size
  size=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
  case "$size" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$size" -ge "$SELF_PAYLOAD_MIN_BYTES" ] && [ "$size" -le "$SELF_PAYLOAD_MAX_BYTES" ]
}

leyili_payload_has_markers(){
  local file="$1"

  [ -f "$file" ] || return 1
  head -n 1 "$file" | grep -Eq '^#!/(usr/)?bin/(env )?bash' || return 1
  grep -Fq 'APP_NAME="Leyili"' "$file" || return 1
  grep -Fq 'show_menu' "$file" || return 1
  grep -Fq 'acquire_global_lock' "$file"
}

# 从 SELF_INSTALL_URL 取一份脚本正文到 $1，逐项校验后才算成功。
# 校验强度与自更新一致：HTTPS、大小、结构标记、Bash 语法；
# 配了 SELF_INSTALL_SHA256 时再强制哈希匹配。
fetch_leyili_payload(){
  local dest="$1" actual_sha expect_sha

  [ -n "$dest" ] || return 1
  case "$SELF_INSTALL_URL" in
    https://*) ;;
    *) return 1 ;;
  esac

  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --max-time 30 \
      "$SELF_INSTALL_URL" -o "$dest" || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only --secure-protocol=TLSv1_2 -q -T 30 -O "$dest" "$SELF_INSTALL_URL" || return 1
  else
    return 1
  fi

  leyili_payload_size_ok "$dest" || return 1
  leyili_payload_has_markers "$dest" || return 1
  bash -n "$dest" >/dev/null 2>&1 || return 1

  if [ -n "$SELF_INSTALL_SHA256" ]; then
    actual_sha=$(sha256sum "$dest" 2>/dev/null | awk '{print tolower($1)}')
    expect_sha=$(printf '%s' "$SELF_INSTALL_SHA256" | tr 'A-F' 'a-f')
    [ -n "$actual_sha" ] || return 1
    [ "$actual_sha" = "$expect_sha" ] || return 1
  fi
  return 0
}

# 管道运行时 stdin 是脚本自身，bash 读完就是 EOF：菜单的 read 会立刻返回空值，
# 一路掉进「无效选项」死循环。能拿到控制终端就把 stdin 接回去。
# 先在子 shell 里试开一次，避免 /dev/tty 不可用时把当前 shell 的 stdin 弄坏。
attach_terminal_stdin(){
  [ -t 0 ] && return 0
  ( exec 0</dev/tty ) >/dev/null 2>&1 || return 1
  exec 0</dev/tty || return 1
  [ -t 0 ]
}

# 安装入口失败时说清原因和下一步。提示随后会被 show_menu 的 clear 抹掉，
# 所以 _entry.sh 会在进菜单前停下来等回车。
report_sb_install_failure(){
  local reason="$1"
  local bin_dir

  bin_dir=$(dirname -- "$SCRIPT_PATH")
  echo ""
  echo -e "  ${R}${B}✗ ${COMMAND_NAME} 命令未安装到 ${SCRIPT_PATH}${N}"
  case "$reason" in
    pipe)
      echo -e "  ${Y}原因：${N}脚本以管道 / 进程替换方式运行，没有可复制的本地文件，"
      echo -e "        改从 ${C}${SELF_INSTALL_URL}${N} 自动获取也失败了"
      echo -e "        （网络不通、地址不可用，或内容未通过大小 / 结构 / 语法校验）。"
      echo -e "  ${Y}解决：${N}用 root 先下载为临时文件再执行："
      echo -e "    ${C}tmp_script=\$(mktemp)${N}"
      echo -e "    ${C}curl --proto '=https' --tlsv1.2 -fsSL \"${SELF_INSTALL_URL}\" -o \"\$tmp_script\"${N}"
      echo -e "    ${C}bash \"\$tmp_script\"; rm -f -- \"\$tmp_script\"${N}"
      ;;
    noroot)
      echo -e "  ${Y}原因：${N}当前用户（UID $(id -u)）无权写入 ${bin_dir}。"
      echo -e "  ${Y}解决：${N}切换到 root 再运行一次本脚本。"
      ;;
    syntax)
      echo -e "  ${Y}原因：${N}本机 bash 未通过脚本语法检查（版本过旧或文件已损坏）。"
      echo -e "  ${Y}排查：${N}${C}bash --version | head -1${N}"
      ;;
    path)
      echo -e "  ${Y}原因：${N}文件已写入，但 ${bin_dir} 不在当前 PATH 中。"
      echo -e "  ${Y}解决：${N}用绝对路径 ${C}${SCRIPT_PATH}${N} 启动，或把目录加进 PATH："
      echo -e "    ${C}echo 'export PATH=\$PATH:${bin_dir}' >> ~/.bashrc && . ~/.bashrc${N}"
      ;;
    *)
      echo -e "  ${Y}原因：${N}写入失败（只读挂载 / 磁盘已满 / 目录不可写）。"
      echo -e "  ${Y}排查：${N}${C}df -h ${bin_dir}; ls -ld ${bin_dir}${N}"
      ;;
  esac
  echo ""
}

# 文件到位不等于命令可用：PATH 里解析不到入口时，用户敲 sb 仍然是 command not found。
sb_registration_done(){
  local resolved real_resolved real_target

  hash -r 2>/dev/null || true
  resolved=$(command -v "$COMMAND_NAME" 2>/dev/null)
  if [ -n "$resolved" ]; then
    real_resolved=$(readlink -f "$resolved" 2>/dev/null || printf '%s' "$resolved")
    real_target=$(readlink -f "$SCRIPT_PATH" 2>/dev/null || printf '%s' "$SCRIPT_PATH")
    if [ "$real_resolved" = "$real_target" ]; then
      return 0
    fi
  fi
  report_sb_install_failure path
  return 1
}

# 当前进程可以复制的本地脚本文件；管道 / 进程替换运行时为空字符串。
detect_self_source_path(){
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    printf '%s' "${BASH_SOURCE[0]}"
    return 0
  fi
  if [ -n "${0:-}" ] && [ -f "$0" ]; then
    printf '%s' "$0"
    return 0
  fi
  printf '%s' ""
}

register_sb_command(){
  local source_path="" src_real dst_real tmp_file="" fail_reason="write" bin_dir

  source_path=$(detect_self_source_path)

  # 已经位于 SCRIPT_PATH（用户用 sb 命令再次进入菜单）：什么都不做
  # 否则 cp same-file 必失败，会回落到 curl 重新下载，导致每次运行都偷偷自动更新
  if [ -n "$source_path" ] && [ -f "$SCRIPT_PATH" ]; then
    src_real=$(readlink -f "$source_path" 2>/dev/null || printf '%s' "$source_path")
    dst_real=$(readlink -f "$SCRIPT_PATH" 2>/dev/null || printf '%s' "$SCRIPT_PATH")
    if [ -n "$src_real" ] && [ "$src_real" = "$dst_real" ]; then
      # 已可执行就不再 chmod：非 root 用 sb 进菜单时 chmod 必失败，那不是错误
      if [ -x "$SCRIPT_PATH" ] || chmod 755 "$SCRIPT_PATH" 2>/dev/null; then
        sb_registration_done
        return $?
      fi
      echo -e "${Y}警告：无法修正 ${SCRIPT_PATH} 的执行权限${N}" >&2
      return 1
    fi
  fi

  if [ -L "$SCRIPT_PATH" ]; then
    echo -e "${Y}警告：拒绝覆盖符号链接脚本入口 ${SCRIPT_PATH}${N}" >&2
    return 1
  fi

  if [ -n "$source_path" ]; then
    if ! bash -n "$source_path" >/dev/null 2>&1; then
      fail_reason="syntax"
    elif atomic_replace_file "$source_path" "$SCRIPT_PATH" 755; then
      sb_registration_done
      return $?
    fi
  else
    fail_reason="pipe"
  fi

  # 到这里要么在管道里跑（没有本地文件可复制），要么本地文件已损坏。
  # 唯一剩下的来源是脚本内置的 SELF_INSTALL_URL —— 用户刚刚执行的就是这个地址的内容，
  # 再取一次装进入口不引入新的信任对象，所以这里不再强求 SELF_INSTALL_SHA256；
  # 校验仍然逐项做足，配了固定哈希则继续强制匹配。
  # fail_reason=write 时本地文件本身没问题，只是写不进去（只读挂载 / 磁盘已满），
  # 重新下载同一份内容也救不了，直接跳过这次网络请求。
  bin_dir=$(dirname -- "$SCRIPT_PATH")
  if [ "$fail_reason" != "write" ] && { [ "$(id -u)" -eq 0 ] || [ -w "$bin_dir" ]; }; then
    if tmp_file=$(mktemp); then
      if fetch_leyili_payload "$tmp_file" \
         && atomic_replace_file "$tmp_file" "$SCRIPT_PATH" 755; then
        rm -f -- "$tmp_file"
        sb_registration_done
        return $?
      fi
      rm -f -- "$tmp_file"
    fi
  fi

  # 非 root 且目标目录写不进去时，权限才是真正的拦路虎，比「管道运行」更贴近事实。
  if [ "$fail_reason" != "syntax" ] && [ "$(id -u)" -ne 0 ] && [ ! -w "$bin_dir" ]; then
    fail_reason="noroot"
  fi

  report_sb_install_failure "$fail_reason"
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
  # 星空横幅：· ✦ · ─ · ✧ · ─ 重复 3 次 + · ✦ ·，共 53 可见列
  local sky="" i
  for ((i = 0; i < 3; i++)); do
    sky+="${L}·${N} ${C}✦${N} ${L}·${N} ${L}─${N} ${L}·${N} ${C}✧${N} ${L}·${N} ${L}─${N} "
  done
  sky+="${L}·${N} ${C}✦${N} ${L}·${N}"
  echo ""
  echo -e "  ${sky}"
  echo -e "          ✨  ${B}${W}${APP_NAME}${N}  ${C}Linux Menu${N}  ✨"
  echo -e "  ${sky}"
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
# ═══ source: 03-system-admin-low.sh ═══
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

  current_port=$(get_effective_sshd_value Port root 127.0.0.1 2>/dev/null || true)
  case "$current_port" in
    ''|*[!0-9]*) current_port="" ;;
  esac

  if [ -z "$current_port" ] && [ -f "$SSHD_CONFIG_PATH" ]; then
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
  local user="${2:-root}"
  local addr="${3:-127.0.0.1}"
  local sshd_bin=""
  local lower_key=""
  local host=""

  [ -z "$key" ] && return 0
  sshd_bin=$(get_sshd_binary)
  [ -z "$sshd_bin" ] && return 0
  [ ! -f "$SSHD_CONFIG_PATH" ] && return 0

  lower_key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
  host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo localhost)
  "$sshd_bin" -T -f "$SSHD_CONFIG_PATH" \
    -C "user=${user},host=${host},addr=${addr}" 2>/dev/null \
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
  local tmp_file=""

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
      if ! cp -a -- "$file" "${file}.bak.${timestamp}"; then
        shopt -u nullglob
        return 1
      fi
      # 注释掉所有 <key> 行（在 Match 之前），保留 Match 之后不动
      tmp_file=$(mktemp "${file}.tmp.XXXXXX") || { shopt -u nullglob; return 1; }
      if ! awk -v k="$key" '
        BEGIN{ in_match=0 }
        /^[[:space:]]*Match[[:space:]]+/ { in_match=1; print; next }
        {
          if (!in_match && tolower($1) == tolower(k) && $0 !~ /^[[:space:]]*#/) {
            print "# leyili-disabled: " $0
            next
          }
          print
        }
      ' "$file" > "$tmp_file"; then
        rm -f -- "$tmp_file"
        shopt -u nullglob
        return 1
      fi
      if ! chmod --reference="$file" "$tmp_file" 2>/dev/null \
         || ! chown --reference="$file" "$tmp_file" 2>/dev/null; then
        rm -f -- "$tmp_file"
        shopt -u nullglob
        return 1
      fi
      if ! mv -f -- "$tmp_file" "$file"; then
        rm -f -- "$tmp_file"
        shopt -u nullglob
        return 1
      fi
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

  tmp_file=$(mktemp "${SSHD_CONFIG_PATH}.tmp.XXXXXX") || return 1
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

  chmod --reference="$SSHD_CONFIG_PATH" "$tmp_file" 2>/dev/null \
    || chmod 600 "$tmp_file" 2>/dev/null \
    || { rm -f -- "$tmp_file"; return 1; }
  chown --reference="$SSHD_CONFIG_PATH" "$tmp_file" 2>/dev/null \
    || { rm -f -- "$tmp_file"; return 1; }
  mv -f "$tmp_file" "$SSHD_CONFIG_PATH"
}

sshd_transaction_begin(){
  local txn
  txn=$(mktemp -d "${TMPDIR:-/tmp}/leyili-sshd.XXXXXX") || return 1
  chmod 700 "$txn" 2>/dev/null || { rm -rf -- "$txn"; return 1; }
  cp -a -- "$SSHD_CONFIG_PATH" "$txn/sshd_config" || { rm -rf -- "$txn"; return 1; }
  if [ -d /etc/ssh/sshd_config.d ]; then
    cp -a -- /etc/ssh/sshd_config.d "$txn/sshd_config.d" || { rm -rf -- "$txn"; return 1; }
    : > "$txn/sshd_config.d.existed"
  fi
  if [ -f "$SSHD_SOCKET_DROPIN_PATH" ]; then
    cp -a -- "$SSHD_SOCKET_DROPIN_PATH" "$txn/ssh.socket.conf" || { rm -rf -- "$txn"; return 1; }
    : > "$txn/ssh.socket.conf.existed"
  fi
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then : > "$txn/socket.active"; fi
  if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then : > "$txn/socket.enabled"; fi
  printf '%s' "$txn"
}

sshd_transaction_restore(){
  local txn="$1"
  local prepared="" current_backup="" rc=0 dropin_ok=1
  [ -d "$txn" ] || return 1

  restore_file_snapshot "$txn/sshd_config" "$SSHD_CONFIG_PATH" || rc=1

  if [ -f "$txn/sshd_config.d.existed" ]; then
    prepared=$(mktemp -d "/etc/ssh/.sshd_config.d.restore.XXXXXX") || rc=1
    if [ -n "$prepared" ] && ! cp -a -- "$txn/sshd_config.d/." "$prepared/"; then
      rm -rf -- "$prepared"
      prepared=""
      rc=1
    fi
    if [ -n "$prepared" ]; then
      if [ -e /etc/ssh/sshd_config.d ]; then
        current_backup=$(mktemp -d "/etc/ssh/.sshd_config.d.current.XXXXXX") || {
          rm -rf -- "$prepared"
          prepared=""
          rc=1
          dropin_ok=0
        }
        if [ -n "$current_backup" ] && ! rmdir -- "$current_backup"; then
          rm -rf -- "$prepared" "$current_backup"
          prepared=""
          current_backup=""
          rc=1
          dropin_ok=0
        fi
      fi
      if [ -n "$prepared" ] && [ -e /etc/ssh/sshd_config.d ]; then
        if ! mv -- /etc/ssh/sshd_config.d "$current_backup"; then
          rc=1
          dropin_ok=0
        fi
      fi
      if [ "$dropin_ok" -eq 1 ] && ! mv -- "$prepared" /etc/ssh/sshd_config.d; then
        if [ -n "$current_backup" ] && [ -e "$current_backup" ]; then
          mv -- "$current_backup" /etc/ssh/sshd_config.d 2>/dev/null || rc=1
        fi
        rc=1
      elif [ "$dropin_ok" -ne 1 ]; then
        [ -n "$prepared" ] && rm -rf -- "$prepared"
      fi
      if [ "$dropin_ok" -eq 1 ] && [ -n "$current_backup" ] && [ -e "$current_backup" ]; then
        rm -rf -- "$current_backup" || rc=1
      fi
    fi
  elif [ -e /etc/ssh/sshd_config.d ]; then
    dropin_ok=1
    current_backup=$(mktemp -d "/etc/ssh/.sshd_config.d.remove.XXXXXX") || { rc=1; dropin_ok=0; }
    if [ -n "$current_backup" ]; then
      rmdir -- "$current_backup" || { rc=1; dropin_ok=0; }
      if [ "$dropin_ok" -eq 1 ]; then
        mv -- /etc/ssh/sshd_config.d "$current_backup" || rc=1
      fi
      if [ ! -e /etc/ssh/sshd_config.d ] && [ -e "$current_backup" ]; then
        rm -rf -- "$current_backup" || rc=1
      fi
    fi
  fi

  if [ -f "$txn/ssh.socket.conf.existed" ]; then
    restore_file_snapshot "$txn/ssh.socket.conf" "$SSHD_SOCKET_DROPIN_PATH" || rc=1
  else
    rm -f -- "$SSHD_SOCKET_DROPIN_PATH" || rc=1
  fi
  systemctl daemon-reload >/dev/null 2>&1 || rc=1
  if [ -f "$txn/socket.enabled" ]; then
    systemctl enable ssh.socket >/dev/null 2>&1 || rc=1
  else
    systemctl disable ssh.socket >/dev/null 2>&1 || rc=1
  fi
  if [ -f "$txn/socket.active" ]; then
    systemctl restart ssh.socket >/dev/null 2>&1 || rc=1
  elif systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl stop ssh.socket >/dev/null 2>&1 || rc=1
  fi
  return "$rc"
}

sshd_transaction_rollback(){
  local txn="$1"
  local service rc=0
  sshd_transaction_restore "$txn" || rc=1
  service=$(detect_ssh_service_name)
  systemctl restart "$service" >/dev/null 2>&1 || rc=1
  if [ "$rc" -eq 0 ]; then
    rm -rf -- "$txn" || rc=1
  fi
  [ "$rc" -eq 0 ] || echo -e "${R}警告：SSH 配置回滚未完全成功，请保持当前会话并立即检查 sshd；快照保留在 ${txn}${N}" >&2
  return "$rc"
}

sshd_transaction_commit(){
  rm -rf -- "$1"
}

ssh_socket_activation_in_use(){
  systemctl cat ssh.socket >/dev/null 2>&1 || return 1
  systemctl is-active --quiet ssh.socket 2>/dev/null \
    || systemctl is-enabled --quiet ssh.socket 2>/dev/null
}

configure_ssh_socket_port(){
  local port="$1"
  local dir tmp

  ssh_socket_activation_in_use || return 0
  dir=$(dirname -- "$SSHD_SOCKET_DROPIN_PATH")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "${SSHD_SOCKET_DROPIN_PATH}.tmp.XXXXXX") || return 1
  cat > "$tmp" <<EOF
# Managed by Leyili. Empty assignment resets vendor ListenStream entries.
[Socket]
ListenStream=
ListenStream=${port}
EOF
  chmod 644 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$SSHD_SOCKET_DROPIN_PATH" || return 1
  systemctl daemon-reload || return 1
  systemctl restart ssh.socket
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
  local txn=""

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

  txn=$(sshd_transaction_begin) || {
    echo -e "${R}SSH 配置事务快照失败${N}"
    pause_screen
    return 1
  }
  backup_path="${SSHD_CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  if ! cp "$SSHD_CONFIG_PATH" "$backup_path"; then
    sshd_transaction_rollback "$txn"
    echo ""
    echo -e "${R}SSH 配置备份失败${N}"
    pause_screen
    return 1
  fi

  if ! set_sshd_global_directive "$key" "$value"; then
    sshd_transaction_rollback "$txn"
    echo ""
    echo -e "${R}SSH 配置写入失败，已恢复备份${N}"
    pause_screen
    return 1
  fi

  if ! "$sshd_bin" -t -f "$SSHD_CONFIG_PATH"; then
    sshd_transaction_rollback "$txn"
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
    if ! neutralize_sshd_dropin_overrides "$key" "$value"; then
      sshd_transaction_rollback "$txn"
      echo -e "${R}处理 sshd_config.d 覆盖项失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    if ! "$sshd_bin" -t -f "$SSHD_CONFIG_PATH"; then
      sshd_transaction_rollback "$txn"
      echo -e "${R}清理覆盖后 sshd -t 校验失败，已恢复备份${N}"
      pause_screen
      return 1
    fi
    effective_value=$(get_effective_sshd_value "$key")
    if [ -n "$effective_value" ] && [ "$(printf '%s' "$effective_value" | tr '[:upper:]' '[:lower:]')" != "$lower_value" ]; then
      sshd_transaction_rollback "$txn"
      echo ""
      echo -e "${R}sshd -T 仍显示 ${key}=${effective_value}，无法达到 ${value}，已恢复备份${N}"
      echo -e "${Y}可能存在 Match 块限制，请手动检查 /etc/ssh/sshd_config 与 /etc/ssh/sshd_config.d/${N}"
      pause_screen
      return 1
    fi
  fi

  if [ "$key" = "Port" ] && ! configure_ssh_socket_port "$value"; then
    sshd_transaction_rollback "$txn"
    echo ""
    echo -e "${R}ssh.socket 端口配置失败，已恢复主配置、drop-in 与 socket 配置${N}"
    pause_screen
    return 1
  fi

  ssh_service=$(detect_ssh_service_name)
  if ! systemctl restart "$ssh_service"; then
    sshd_transaction_rollback "$txn"
    echo ""
    echo -e "${R}SSH 服务重启失败，已恢复备份并尝试恢复原配置${N}"
    pause_screen
    return 1
  fi

  # 重启后等待 sshd 重新监听，验证新端口确实在监听（最多等 3 秒）
  if [ "$key" = "Port" ] && command -v ss >/dev/null 2>&1; then
    local i=0
    while [ "$i" -lt 6 ]; do
      # 只校验端口在监听即可，不强求行内进程名是 sshd：
      # 新版 Ubuntu/Debian 默认 ssh.socket（socket activation）下监听进程是 systemd 而非 sshd
      if ss -tlnp 2>/dev/null | awk -v p=":${value}$" '$4 ~ p {found=1} END {exit !found}'; then
        listen_ok=1
        break
      fi
      sleep 0.5
      i=$((i + 1))
    done
    if [ "$listen_ok" -ne 1 ]; then
      sshd_transaction_rollback "$txn"
      echo ""
      echo -e "${R}sshd 已重启，但新端口 ${value} 未检测到监听，已回滚配置${N}"
      pause_screen
      return 1
    fi
  fi

  sshd_transaction_commit "$txn"

  echo ""
  echo -e "${G}${success_message}${N}"
  echo -e "  备份文件: ${C}$backup_path${N}"
  if [ "$key" = "Port" ]; then
    echo -e "  ${Y}重要：${N}请立即开新终端验证新端口可登录，再关闭当前会话！"
  fi
  return 0
}

# 判断 IPv4 是否属于私有 / CGNAT / 链路本地 / loopback / 0.0.0.0
# NAT 型 VPS（阿里云国际轻量、腾讯云轻量、AWS Lightsail、各种 NAT 套餐）网卡绑的是
# 内网 IP，公网 IP 在云厂商 NAT 网关上做映射；本地探测会拿到内网段，需要回退到外部接口。
# ═══ source: 04-utils-ip.sh ═══
is_private_ipv4(){
  case "$1" in
    10.*|127.*|192.168.*|0.0.0.0|169.254.*) return 0 ;;
    172.16.*|172.17.*|172.18.*|172.19.*) return 0 ;;
    172.2[0-9].*|172.3[01].*) return 0 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
  esac
  return 1
}

is_valid_ipv4(){
  local ip="$1" a b c d
  IFS=. read -r a b c d <<EOF
$ip
EOF
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] || return 1
  case "$a$b$c$d" in *[!0-9]*) return 1 ;; esac
  [ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ] && [ "$d" -le 255 ]
}

is_valid_ipv6_text(){
  local ip="$1"
  [ "${#ip}" -ge 2 ] && [ "${#ip}" -le 45 ] || return 1
  case "$ip" in
    *:*) printf '%s' "$ip" | grep -Eq '^[0-9A-Fa-f:.]+$' ;;
    *) return 1 ;;
  esac
}

# 判断 IPv6 是否属于 ULA / link-local / loopback / unspecified
is_private_ipv6(){
  local ip
  ip=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$ip" in
    ::1|::|fe8?:*|fe9?:*|fea?:*|feb?:*) return 0 ;;
    fc??:*|fd??:*) return 0 ;;
  esac
  return 1
}

detect_primary_ipv4(){
  local detected="" local_fallback=""

  if command -v ip >/dev/null 2>&1; then
    detected=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i == "src") {
          print $(i + 1)
          exit
        }
      }
    }')
    if [ -n "$detected" ] && is_private_ipv4 "$detected"; then
      local_fallback="$detected"
      detected=""
    fi

    if [ -z "$detected" ]; then
      detected=$(ip -4 addr show scope global up 2>/dev/null | awk '/inet / {
        split($2, parts, "/")
        print parts[1]
        exit
      }')
      if [ -n "$detected" ] && is_private_ipv4 "$detected"; then
        [ -z "$local_fallback" ] && local_fallback="$detected"
        detected=""
      fi
    fi
  fi

  if [ -z "$detected" ]; then
    detected=$(curl --proto '=https' --tlsv1.2 -fsS4 --max-time 5 \
      https://api.ipify.org 2>/dev/null || true)
    is_valid_ipv4 "$detected" || detected=""
  fi

  # curl 也失败时，宁可返回先前探到的内网 IP 也别返回空——
  # 至少能让用户在节点信息里看到检测结果，避免上层卡在「未检测到可用的 IPv4 地址」
  if [ -z "$detected" ]; then
    detected="$local_fallback"
  fi

  printf '%s' "$detected"
}

detect_primary_ipv6(){
  local detected="" local_fallback=""

  if command -v ip >/dev/null 2>&1; then
    detected=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i == "src") {
          print $(i + 1)
          exit
        }
      }
    }')
    if [ -n "$detected" ] && is_private_ipv6 "$detected"; then
      local_fallback="$detected"
      detected=""
    fi

    if [ -z "$detected" ]; then
      detected=$(ip -6 addr show scope global up 2>/dev/null | awk '/inet6 / {
        split($2, parts, "/")
        print parts[1]
        exit
      }')
      if [ -n "$detected" ] && is_private_ipv6 "$detected"; then
        [ -z "$local_fallback" ] && local_fallback="$detected"
        detected=""
      fi
    fi
  fi

  if [ -z "$detected" ]; then
    detected=$(curl --proto '=https' --tlsv1.2 -fsS6 --max-time 5 \
      https://api64.ipify.org 2>/dev/null || true)
    is_valid_ipv6_text "$detected" || detected=""
  fi

  if [ -z "$detected" ]; then
    detected="$local_fallback"
  fi

  printf '%s' "$detected"
}

describe_install_mode(){
  case "$1" in
    ipv6-in-ipv4-out)
      printf '%s' '仅 IPv6 入站'
      ;;
    dualstack)
      printf '%s' '双栈入站'
      ;;
    *)
      printf '%s' '仅 IPv4 入站'
      ;;
  esac
}
# ═══ source: 10-singbox-core.sh ═══
is_singbox_installed(){
  command -v sing-box >/dev/null 2>&1
}

sagernet_repo_state_get(){
  local key="$1"
  [ -f "$SAGERNET_REPO_STATE" ] || return 1
  grep -m1 "^${key}=" "$SAGERNET_REPO_STATE" | cut -d= -f2-
}

sagernet_repo_capture_state(){
  local source_existed=0 key_existed=0 tmp
  [ -f "$SAGERNET_REPO_STATE" ] && return 0
  ensure_leyili_state_dir || return 1

  [ -e "$SAGERNET_SOURCES" ] && source_existed=1
  [ -e "$SAGERNET_KEYRING" ] && key_existed=1
  # 兼容旧版脚本：带明确托管标记的 sources 及其配套 key 视为脚本创建。
  if grep -Fq '# Managed by Leyili' "$SAGERNET_SOURCES" 2>/dev/null; then
    source_existed=0
    key_existed=0
  fi

  tmp=$(mktemp "${SAGERNET_REPO_STATE}.tmp.XXXXXX") || return 1
  if ! printf 'SourceExisted=%s\nKeyExisted=%s\n' "$source_existed" "$key_existed" > "$tmp" \
     || ! chmod 600 "$tmp" \
     || ! mv -f -- "$tmp" "$SAGERNET_REPO_STATE"; then
    rm -f -- "$tmp"
    return 1
  fi
}

sagernet_repo_restore(){
  local source_existed key_existed rc=0
  source_existed=$(sagernet_repo_state_get SourceExisted 2>/dev/null || true)
  key_existed=$(sagernet_repo_state_get KeyExisted 2>/dev/null || true)

  case "$source_existed" in
    0)
      rm -f -- "$SAGERNET_SOURCES" "${SAGERNET_SOURCES}.leyili-original" || rc=1
      ;;
    1)
      if [ -e "${SAGERNET_SOURCES}.leyili-original" ]; then
        managed_file_restore "$SAGERNET_SOURCES" || rc=1
      fi
      ;;
    *)
      if [ -e "${SAGERNET_SOURCES}.leyili-original" ]; then
        managed_file_restore "$SAGERNET_SOURCES" || rc=1
      elif grep -Fq '# Managed by Leyili' "$SAGERNET_SOURCES" 2>/dev/null; then
        rm -f -- "$SAGERNET_SOURCES" || rc=1
      fi
      ;;
  esac

  case "$key_existed" in
    0)
      rm -f -- "$SAGERNET_KEYRING" "${SAGERNET_KEYRING}.leyili-original" || rc=1
      ;;
    1)
      if [ -e "${SAGERNET_KEYRING}.leyili-original" ]; then
        managed_file_restore "$SAGERNET_KEYRING" || rc=1
      fi
      ;;
    *)
      # 无所有权记录时宁可保留未知 key；只有明确备份存在才恢复。
      if [ -e "${SAGERNET_KEYRING}.leyili-original" ]; then
        managed_file_restore "$SAGERNET_KEYRING" || rc=1
      fi
      ;;
  esac

  if [ "$rc" -eq 0 ]; then
    rm -f -- "$SAGERNET_REPO_STATE" || rc=1
  fi
  return "$rc"
}

ensure_sagernet_repo(){
  local pkg need=() tmp_key actual_fpr installed_fpr="" key_existed
  local source_txn tmp_sources
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
  sagernet_repo_capture_state || { echo -e "${R}无法记录 SagerNet 仓库文件所有权${N}"; return 1; }

  if [ -s "$SAGERNET_KEYRING" ]; then
    installed_fpr=$(gpg --batch --show-keys --with-colons --fingerprint "$SAGERNET_KEYRING" 2>/dev/null \
      | awk -F: '$1 == "fpr" {print toupper($10); exit}')
  fi
  if [ "$installed_fpr" != "$SAGERNET_KEY_FINGERPRINT" ]; then
    tmp_key=$(mktemp) || return 1
    if ! curl --proto '=https' --tlsv1.2 -fsSL --max-time 20 "$SAGERNET_KEY_URL" -o "$tmp_key"; then
      echo -e "${R}下载 SagerNet GPG key 失败：$SAGERNET_KEY_URL${N}"
      rm -f -- "$tmp_key"
      return 1
    fi
    actual_fpr=$(gpg --batch --show-keys --with-colons --fingerprint "$tmp_key" 2>/dev/null \
      | awk -F: '$1 == "fpr" {print toupper($10); exit}')
    if [ "$actual_fpr" != "$SAGERNET_KEY_FINGERPRINT" ]; then
      echo -e "${R}SagerNet GPG key 指纹不匹配，拒绝安装${N}"
      echo -e "  预期: ${C}${SAGERNET_KEY_FINGERPRINT}${N}"
      echo -e "  实际: ${C}${actual_fpr:-无法解析}${N}"
      rm -f -- "$tmp_key"
      return 1
    fi
    key_existed=$(sagernet_repo_state_get KeyExisted 2>/dev/null || echo 0)
    if [ "$key_existed" = "1" ] && [ -e "$SAGERNET_KEYRING" ] \
       && [ ! -e "${SAGERNET_KEYRING}.leyili-original" ]; then
      cp -a -- "$SAGERNET_KEYRING" "${SAGERNET_KEYRING}.leyili-original" \
        || { rm -f -- "$tmp_key"; return 1; }
    fi
    if ! atomic_replace_file "$tmp_key" "$SAGERNET_KEYRING" 644; then
      rm -f -- "$tmp_key"
      return 1
    fi
    rm -f -- "$tmp_key"
  fi

  source_txn=$(managed_file_transaction_begin "$SAGERNET_SOURCES" 'Managed by Leyili|URIs:[[:space:]]*https://deb\.sagernet\.org/') \
    || return 1
  tmp_sources=$(mktemp "${SAGERNET_SOURCES}.tmp.XXXXXX") || {
    managed_file_transaction_rollback "$SAGERNET_SOURCES" "$source_txn"
    return 1
  }
  if ! cat > "$tmp_sources" <<EOF
# Managed by Leyili
Types: deb
URIs: $SAGERNET_REPO_URI
Suites: *
Components: *
Enabled: yes
Signed-By: $SAGERNET_KEYRING
EOF
  then
    rm -f -- "$tmp_sources"
    managed_file_transaction_rollback "$SAGERNET_SOURCES" "$source_txn"
    return 1
  fi
  if ! chmod 644 "$tmp_sources" \
     || ! mv -f -- "$tmp_sources" "$SAGERNET_SOURCES"; then
    rm -f -- "$tmp_sources"
    managed_file_transaction_rollback "$SAGERNET_SOURCES" "$source_txn"
    return 1
  fi
  managed_file_transaction_commit "$source_txn"

  return 0
}

install_singbox(){
  local txn
  if ! ensure_sagernet_repo; then
    return 1
  fi

  txn=$(config_transaction_begin singbox-install) || return 1

  # 关键：在 apt-get install 之前预写干净骨架，dpkg 看到 conffile 已存在
  # 配合 --force-confold 就不会落地 deb 自带的危险默认配置
  # （含端口 8080、固定密码 Gn1JUS14bLUHgv1cWDDp4A== 的 shadowsocks 入站）
  if ! config_ensure_skeleton; then
    echo -e "${R}写入 sing-box 配置骨架失败${N}"
    config_transaction_rollback "$txn"
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
    config_transaction_rollback "$txn"
    return 1
  fi

  if ! command -v sing-box >/dev/null 2>&1; then
    echo -e "${R}sing-box 安装后仍找不到可执行文件${N}"
    config_transaction_rollback "$txn"
    return 1
  fi

  # postinst 可能已拉起服务（虽然此时配置是空骨架，无监听）。停下来由业务流程后续 restart。
  if systemctl is-active --quiet sing-box 2>/dev/null \
     && ! systemctl stop sing-box >/dev/null 2>&1; then
    echo -e "${R}sing-box 安装后自动启动，但无法安全停止${N}"
    config_transaction_rollback "$txn"
    return 1
  fi
  config_transaction_commit "$txn"
  return 0
}

upgrade_singbox(){
  local old_pkg_version txn upgrade_ok=0
  if ! ensure_sagernet_repo; then
    return 1
  fi

  old_pkg_version=$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)
  txn=$(config_transaction_begin singbox-upgrade) || {
    echo -e "${R}升级前配置快照失败${N}"
    return 1
  }
  if [ -f "$CONFIG_PATH" ] && ! sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${R}当前配置本身未通过校验，已拒绝升级${N}"
    config_transaction_rollback "$txn"
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
    config_transaction_rollback "$txn"
    return 1
  fi

  if [ -f "$CONFIG_PATH" ]; then
    if [ -f "$txn/service.active" ]; then
      config_check_and_restart && upgrade_ok=1
    elif sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
      if ! systemctl is-active --quiet sing-box 2>/dev/null \
         || systemctl stop sing-box >/dev/null 2>&1; then
        upgrade_ok=1
      fi
    fi
  else
    upgrade_ok=1
  fi

  if [ "$upgrade_ok" = "1" ]; then
    config_transaction_commit "$txn"
    return 0
  fi

  echo -e "${R}新版未通过配置/服务健康检查，开始回滚${N}"
  if [ -n "$old_pkg_version" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      "sing-box=${old_pkg_version}" >/dev/null 2>&1 || \
      echo -e "${Y}旧版本 ${old_pkg_version} 已不在仓库，请人工安装后再启动服务${N}"
  fi
  config_transaction_rollback "$txn"
  return 1
}
# ═══ source: 12-singbox-config-storage.sh ═══
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

  mkdir -p "$(dirname -- "$INFO_PATH")" || return 1
  if [ ! -f "$INFO_PATH" ]; then
    (umask 077; printf '%s=%s\n' "$key" "$value" > "$INFO_PATH")
    chmod 600 "$INFO_PATH" 2>/dev/null || return 1
    return 0
  fi

  tmp_file=$(mktemp "${INFO_PATH}.tmp.XXXXXX") || return 1
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
  chmod 600 "$tmp_file" 2>/dev/null || { rm -f -- "$tmp_file"; return 1; }
  mv -f "$tmp_file" "$INFO_PATH"
}

# ─── 节点存储 (per-node info file) ──────────────────
ensure_nodes_dir(){
  ensure_private_dir "$NODES_DIR" 700 || return 1
  ensure_private_dir "$CERTS_DIR" 700 || return 1
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
  ensure_nodes_dir || return 1
  if [ ! -f "$f" ]; then
    (umask 077; printf '%s=%s\n' "$key" "$value" > "$f")
    chmod 600 "$f" 2>/dev/null || return 1
    return 0
  fi
  tmp=$(mktemp "${f}.tmp.XXXXXX") || return 1
  awk -v key="$key" -v value="$value" '
    BEGIN { updated = 0 }
    index($0, key "=") == 1 { print key "=" value; updated = 1; next }
    { print }
    END { if (!updated) print key "=" value }
  ' "$f" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f "$tmp" "$f"
}

remove_node_info(){
  rm -f -- "$(node_info_path "$1")"
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
    # 第一次跑的全新 VPS 可能 apt 缓存为空，先 update 再重试
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    if ! apt-get install -y jq 2>/dev/null; then
      echo -e "${R}jq 安装失败，请手动执行：apt install jq${N}"
      return 1
    fi
  fi
  return 0
}

config_ensure_skeleton(){
  ensure_jq || return 1
  local config_dir tmp invalid_backup
  config_dir=$(dirname -- "$CONFIG_PATH")
  mkdir -p "$config_dir" || return 1

  if [ ! -f "$CONFIG_PATH" ]; then
    tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX") || return 1
    cat > "$tmp" <<'EOF'
{
  "log": {"disabled": false, "level": "warn", "timestamp": true},
  "dns": {"servers": [{"type": "local", "tag": "dns-local"}]},
  "inbounds": [],
  "outbounds": [{
    "type": "direct",
    "tag": "direct-out"
  }],
  "route": {
    "final": "direct-out",
    "default_domain_resolver": "dns-local"
  }
}
EOF
    chmod 600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    mv -f "$tmp" "$CONFIG_PATH"
    return 0
  fi

  if ! jq empty "$CONFIG_PATH" >/dev/null 2>&1; then
    invalid_backup="${CONFIG_PATH}.invalid.$(date +%Y%m%d%H%M%S)"
    echo -e "${R}现有 sing-box 配置不是有效 JSON，已拒绝覆盖。${N}" >&2
    if cp -a -- "$CONFIG_PATH" "$invalid_backup" 2>/dev/null; then
      echo -e "${Y}原文件保留在 ${CONFIG_PATH}，副本：${invalid_backup}${N}" >&2
    else
      echo -e "${Y}原文件仍保留在 ${CONFIG_PATH}，但额外副本创建失败。${N}" >&2
    fi
    return 1
  fi

  tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX") || return 1
  # 只补充脚本运行所需的缺失字段，绝不删除用户 inbound、DNS、路由或出站。
  if jq '
      .log = (.log // {"disabled": false, "level": "warn", "timestamp": true})
    | .dns = (.dns // {})
    | .dns.servers = (.dns.servers // [])
    | if any(.dns.servers[]?; (.tag // "") == "dns-local")
      then .
      else .dns.servers += [{"type":"local","tag":"dns-local"}]
      end
    | .inbounds = (.inbounds // [])
    | .outbounds = (.outbounds // [])
    | if any(.outbounds[]?; (.tag // "") == "direct-out")
      then .
      else .outbounds += [{"type":"direct","tag":"direct-out"}]
      end
    | .route = (.route // {})
    | .route.default_domain_resolver = (.route.default_domain_resolver // "dns-local")
    | .route.rules = (.route.rules // [])
    | .route.final = (.route.final // "direct-out")
  ' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    mv -f "$tmp" "$CONFIG_PATH"
    return 0
  fi
  rm -f -- "$tmp"
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
  tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX") || return 1
  if ! jq --argjson nb "$inbound" --arg tag "$tag" '
    .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) + [$nb]
  ' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f "$tmp" "$CONFIG_PATH"
}

config_remove_inbound_by_tag(){
  local tag="$1"
  ensure_jq || return 1
  [ -f "$CONFIG_PATH" ] || return 0
  jq empty "$CONFIG_PATH" >/dev/null 2>&1 || return 1
  local tmp
  tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX") || return 1
  if ! jq --arg tag "$tag" '.inbounds = ((.inbounds // []) | map(select(.tag != $tag)))' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f "$tmp" "$CONFIG_PATH"
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
  tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX") || return 1
  if ! jq --argjson nb "$outbound" --arg tag "$tag" '
    .outbounds = ((.outbounds // []) | map(select(.tag != $tag))) + [$nb]
  ' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f "$tmp" "$CONFIG_PATH"
}

config_remove_outbound_by_tag(){
  local tag="$1"
  ensure_jq || return 1
  [ -f "$CONFIG_PATH" ] || return 0
  jq empty "$CONFIG_PATH" >/dev/null 2>&1 || return 1
  # 不允许移除 direct-out
  if [ "$tag" = "direct-out" ]; then
    return 0
  fi
  local tmp
  tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX") || return 1
  if ! jq --arg tag "$tag" '.outbounds = ((.outbounds // []) | map(select(.tag != $tag)))' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f "$tmp" "$CONFIG_PATH"
}

config_check_and_restart(){
  local expected_port="${1:-}"
  local expected_proto="${2:-tcp}"
  local i

  if ! sing-box check -c "$CONFIG_PATH"; then
    return 1
  fi
  if ! systemctl enable sing-box >/dev/null 2>&1; then
    return 1
  fi
  if ! systemctl restart sing-box; then
    return 1
  fi

  for i in 1 2 3 4 5 6 7 8 9 10; do
    if systemctl is-active --quiet sing-box 2>/dev/null; then
      if [ -z "$expected_port" ] || check_port_in_use "$expected_port" "$expected_proto"; then
        return 0
      fi
    fi
    sleep 0.5
  done
  echo -e "${R}sing-box 重启后未保持运行${expected_port:+，或未监听 ${expected_port}/${expected_proto}}${N}" >&2
  return 1
}

# 旧 /root/proxy-info.txt 迁移到 /etc/sing-box/nodes/reality.info
migrate_legacy_info(){
  # 旧配置里 reality inbound 的 tag 是 vless-in，统一重命名为 reality-in
  if [ -f "$CONFIG_PATH" ] && command -v jq >/dev/null 2>&1 \
     && jq -e 'any(.inbounds[]?; (.tag // "") == "vless-in")' "$CONFIG_PATH" >/dev/null 2>&1; then
    local tmp migration_txn migration_ok=1
    migration_txn=$(config_transaction_begin legacy-reality-tag) || return 1
    tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX") || {
      config_transaction_rollback "$migration_txn"
      return 1
    }
    if ! jq '
        (.inbounds[]? | select(.tag == "vless-in") | .tag) = "reality-in"
      | .route.rules = ((.route.rules // []) | map(
          if ((.inbound // null) | type) == "array" then
            .inbound |= map(if . == "vless-in" then "reality-in" else . end)
          elif (.inbound // "") == "vless-in" then
            .inbound = "reality-in"
          else . end
        ))
      ' "$CONFIG_PATH" > "$tmp" 2>/dev/null \
       || ! chmod 600 "$tmp" \
       || ! mv -f -- "$tmp" "$CONFIG_PATH"; then
      rm -f -- "$tmp"
      migration_ok=0
    fi
    if [ "$migration_ok" -eq 1 ] && command -v sing-box >/dev/null 2>&1; then
      sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1 || migration_ok=0
      if [ "$migration_ok" -eq 1 ] && systemctl is-active --quiet sing-box 2>/dev/null; then
        systemctl restart sing-box >/dev/null 2>&1 || migration_ok=0
      fi
    fi
    if [ "$migration_ok" -eq 1 ]; then
      config_transaction_commit "$migration_txn"
    else
      config_transaction_rollback "$migration_txn"
      echo -e "${R}旧 Reality tag 迁移失败，已恢复原配置${N}" >&2
      return 1
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

  ensure_nodes_dir || return 1
  local f
  f=$(node_info_path reality)
  write_node_info_file reality <<EOF
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

  mkdir -p "$(dirname -- "$INFO_PATH")" || return 1
  local tmp_info
  tmp_info=$(mktemp "${INFO_PATH}.tmp.XXXXXX") || return 1
  cat > "$tmp_info" << EOF
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
  chmod 600 "$tmp_info" 2>/dev/null || { rm -f -- "$tmp_info"; return 1; }
  mv -f "$tmp_info" "$INFO_PATH"
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
# ═══ source: 20-link-builders.sh ═══
url_encode_host(){
  # 给 IPv6 地址套 [] ，IPv4 / 域名原样返回
  local ip="$1"
  case "$ip" in
    \[*\]) printf '%s' "$ip" ;;
    *:*)   printf '[%s]' "$ip" ;;
    *)     printf '%s' "$ip" ;;
  esac
}

url_encode_component(){
  local value="${1:-}"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$value" | jq -sRr @uri
    return
  fi
  # 节点创建流程本身依赖 jq；这里只在手工调用链接函数时给出明确失败。
  return 1
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

  local host enc_sni enc_pub enc_sid enc_tag
  host=$(url_encode_host "$ip")
  enc_sni=$(url_encode_component "$sni") || return 1
  enc_pub=$(url_encode_component "$public_key") || return 1
  enc_sid=$(url_encode_component "$short_id") || return 1
  enc_tag=$(url_encode_component "$tag") || return 1
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
    "$uuid" "$host" "$port" "$enc_sni" "$enc_pub" "$enc_sid" "$enc_tag"
}

build_anytls_link(){
  # build_anytls_link <password> <ip> <port> <sni> <public_key> <short_id> <tag>
  # AnyTLS 标准 URI（anytls-go uri_scheme.md）只定义 sni/insecure；
  # 这里增加 reality 扩展参数（security/pbk/sid/fp），与 v2rayN / sing-box GUI / Shadowrocket 的事实标准兼容。
  local password="$1"
  local ip="$2"
  local port="$3"
  local sni="$4"
  local public_key="$5"
  local short_id="$6"
  local tag="${7:-anytls}"

  if [ -z "$password" ] || [ -z "$ip" ] || [ -z "$port" ] || [ -z "$sni" ] || [ -z "$public_key" ] || [ -z "$short_id" ]; then
    return 1
  fi

  local host enc_pw enc_sni enc_pub enc_sid enc_tag
  host=$(url_encode_host "$ip")
  enc_pw=$(url_encode_component "$password") || return 1
  enc_sni=$(url_encode_component "$sni") || return 1
  enc_pub=$(url_encode_component "$public_key") || return 1
  enc_sid=$(url_encode_component "$short_id") || return 1
  enc_tag=$(url_encode_component "$tag") || return 1
  printf 'anytls://%s@%s:%s/?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&insecure=0#%s\n' \
    "$enc_pw" "$host" "$port" "$enc_sni" "$enc_pub" "$enc_sid" "$enc_tag"
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

  local host enc_password enc_sni enc_obfs_type enc_obfs_password enc_tag
  host=$(url_encode_host "$ip")
  enc_password=$(url_encode_component "$password") || return 1
  enc_sni=$(url_encode_component "${sni:-}") || return 1
  enc_tag=$(url_encode_component "$tag") || return 1
  local query="sni=${enc_sni}&insecure=${insecure}"
  if [ -n "$obfs_type" ]; then
    enc_obfs_type=$(url_encode_component "$obfs_type") || return 1
    enc_obfs_password=$(url_encode_component "$obfs_password") || return 1
    query="${query}&obfs=${enc_obfs_type}&obfs-password=${enc_obfs_password}"
  fi

  local server_part
  if [ -n "$hop_start" ] && [ -n "$hop_end" ]; then
    server_part="${host}:${port},${hop_start}-${hop_end}"
  else
    server_part="${host}:${port}"
  fi
  printf 'hysteria2://%s@%s?%s#%s\n' \
    "$enc_password" "$server_part" "$query" "$enc_tag"
}

build_tuic_link(){
  # build_tuic_link <uuid> <password> <ip> <port> <sni> <insecure 0|1> <congestion_control> <tag>
  local uuid="$1"
  local password="$2"
  local ip="$3"
  local port="$4"
  local sni="$5"
  local insecure="${6:-0}"
  local cc="${7:-bbr}"
  local tag="${8:-tuic}"

  if [ -z "$uuid" ] || [ -z "$password" ] || [ -z "$ip" ] || [ -z "$port" ]; then
    return 1
  fi

  local host enc_password enc_sni enc_cc enc_tag
  host=$(url_encode_host "$ip")
  enc_password=$(url_encode_component "$password") || return 1
  enc_sni=$(url_encode_component "${sni:-}") || return 1
  enc_cc=$(url_encode_component "$cc") || return 1
  enc_tag=$(url_encode_component "$tag") || return 1
  printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=%s&allow_insecure=%s#%s\n' \
    "$uuid" "$enc_password" "$host" "$port" "$enc_sni" "$enc_cc" "$insecure" "$enc_tag"
}

build_ss2022_link(){
  # build_ss2022_link <method> <password> <ip> <port> <tag>
  # SIP002 标准：ss://<base64url(method:password)>@host:port#tag
  local method="$1"
  local password="$2"
  local ip="$3"
  local port="$4"
  local tag="${5:-ss2022}"

  if [ -z "$method" ] || [ -z "$password" ] || [ -z "$ip" ] || [ -z "$port" ]; then
    return 1
  fi

  local host userinfo enc_tag
  host=$(url_encode_host "$ip")
  userinfo=$(printf '%s:%s' "$method" "$password" | base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '=')
  enc_tag=$(url_encode_component "$tag") || return 1
  printf 'ss://%s@%s:%s#%s\n' \
    "$userinfo" "$host" "$port" "$enc_tag"
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
    anytls)
      local password pubk sid
      password=$(get_node_value "$type" Password 2>/dev/null || true)
      pubk=$(get_node_value "$type" PublicKey 2>/dev/null || true)
      sid=$(get_node_value "$type" ShortID 2>/dev/null || true)
      build_anytls_link "$password" "$ip" "$port" "$sni" "$pubk" "$sid" "$tag"
      ;;
    tuic)
      local uuid password insecure cc
      uuid=$(get_node_value "$type" UUID 2>/dev/null || true)
      password=$(get_node_value "$type" Password 2>/dev/null || true)
      insecure=$(get_node_value "$type" Insecure 2>/dev/null || echo 0)
      cc=$(get_node_value "$type" CongestionControl 2>/dev/null || echo bbr)
      build_tuic_link "$uuid" "$password" "$ip" "$port" "$sni" "$insecure" "$cc" "$tag"
      ;;
    ss2022)
      local method password
      method=$(get_node_value "$type" Method 2>/dev/null || true)
      password=$(get_node_value "$type" Password 2>/dev/null || true)
      build_ss2022_link "$method" "$password" "$ip" "$port" "$tag"
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
# ═══ source: 21-menus-top.sh ═══
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
        systemctl status sing-box --no-pager || true
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
    render_menu_item 5 "网络优化"
    render_menu_item 6 "查看网络优化状态"
    render_menu_item 7 "添加 SWAP"
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
        show_swap_picker
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

show_network_menu(){
  while true; do
    render_section_header "网络管理"
    render_menu_item 1 "安装 / 配置 fail2ban (SSH 多端口防爆破)"
    render_menu_item 2 "Reality 域名检测工具"
    render_menu_item 3 "WARP 谷歌解锁分流"
    render_menu_item 4 "服务器状态"
    render_menu_item 5 "本地链路测评"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        setup_fail2ban
        ;;
      2)
        check_reality_dest_domain
        ;;
      3)
        show_warp_menu
        ;;
      4)
        show_server_status
        ;;
      5)
        show_netbench_menu
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
# ═══ source: 22-firewall-ipv6.sh ═══
show_ipv6_firewall_menu(){
  local ssh_port input_policy opened_ports rules refresh_status=1

  if ! require_root; then
    return 1
  fi

  if ! ensure_iptables_installed; then
    pause_screen
    return 1
  fi

  # 菜单状态一次读取自同一份规则快照，减少反复执行 ip6tables/ss 的卡顿。
  ssh_port=$(ip6_detect_ssh_port)

  while true; do
    if [ "$refresh_status" -eq 1 ]; then
      rules=$(ip6tables-save 2>/dev/null)
      input_policy=$(printf '%s\n' "$rules" | firewall_policy_from_saved_rules INPUT)
      opened_ports=$(printf '%s\n' "$rules" | firewall_list_opened_ports_from_saved_rules compact)
      refresh_status=0
    fi

    render_section_header "IPv6 防火墙管理"
    echo -e "  ${L}│${N}  SSH 端口  ${D}·${N}  ${C}${ssh_port}${N}"

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
    render_menu_item 3 "初始化 IPv6 防火墙（默认拒绝，保留用户规则）"
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
        ip6_close_all_inbound
        refresh_status=1
        ;;
      4)
        ip6_open_port
        refresh_status=1
        ;;
      5)
        ip6_close_port
        refresh_status=1
        ;;
      6)
        ip6_emergency_disable
        refresh_status=1
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
  local input_policy output_policy forward_policy opened rules

  rules=$(ip6tables-save 2>/dev/null)
  input_policy=$(printf '%s\n' "$rules" | firewall_policy_from_saved_rules INPUT)
  output_policy=$(printf '%s\n' "$rules" | firewall_policy_from_saved_rules OUTPUT)
  forward_policy=$(printf '%s\n' "$rules" | firewall_policy_from_saved_rules FORWARD)

  echo ""
  echo -e "  ${B}${C}默认策略${N}"
  echo -e "  INPUT   : ${C}${input_policy}${N}  ${D}(别人主动连你)${N}"
  echo -e "  OUTPUT  : ${C}${output_policy}${N}  ${D}(你主动出去连别人)${N}"
  echo -e "  FORWARD : ${C}${forward_policy}${N}  ${D}(转发, Docker 用, 脚本不动)${N}"
  echo ""

  echo -e "  ${B}${C}已开放的入站端口${N}"
  opened=$(printf '%s\n' "$rules" | firewall_list_opened_ports_from_saved_rules lines)

  if [ -z "$opened" ]; then
    echo -e "  ${D}(无)${N}"
  else
    echo "$opened"
  fi
  echo ""

  echo -e "  ${B}${C}完整 INPUT 规则${N}"
  ip6tables -L INPUT -n -v --line-numbers
  if firewall_managed_chain_exists 6; then
    echo ""
    echo -e "  ${B}${C}${IP6_LEYILI_CHAIN} 规则${N}"
    ip6tables -L "$IP6_LEYILI_CHAIN" -n -v --line-numbers
  fi
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

ip6_close_all_inbound(){
  local confirm
  local txn

  echo ""
  echo -e "  ${B}${C}初始化 IPv6 防火墙${N}"
  render_divider
  echo "  本次会执行："
  echo -e "    1) 仅重建脚本专属链 ${C}${IP6_LEYILI_CHAIN}${N}，保留用户与 fail2ban 规则"
  echo "    2) 放行回环、已建立连接和 ICMPv6 (NDP 必需)"
  echo -e "    3) ${R}${B}脚本专属链不放行业务端口${N}"
  echo "    4) INPUT 默认策略 = DROP"
  echo "    5) OUTPUT / FORWARD 保持原样"
  echo ""
  echo -e "  ${Y}效果：未被用户既有规则放行的 IPv6 新入站会被拒绝；出站与回包可用。${N}"
  echo -e "  ${D}如需 IPv6 提供 HTTP/HTTPS/SSH 等服务，请改用本菜单 ${C}4) 开放端口${N}${D}。${N}"
  echo ""

  if ip6_check_current_ssh_v6; then
    echo -e "  ${R}${B}严重警告：你当前 SSH 是 IPv6 进来的${N}"
    echo -e "  ${R}应用规则后该会话将立即断开 (IPv4 SSH 不受影响)${N}"
    echo -e "  ${Y}建议先用 IPv4 登录后再操作${N}"
    echo ""
    read -p "  仍要继续吗？输入大写 ${R}YES${N} 强制继续: " confirm
    if [ "$confirm" != "YES" ]; then
      echo -e "  已取消"
      sleep 1
      return 0
    fi
  fi

  read -p "  确认继续？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  if ! ip6_ensure_persistence; then
    echo ""
    echo -e "${R}持久化工具安装失败${N}"
    pause_screen
    return 1
  fi

  txn=$(firewall_transaction_begin 6) || { echo -e "${R}防火墙快照失败${N}"; pause_screen; return 1; }
  if ! firewall_ensure_managed_chain 6 \
     || ! ip6tables -F "$IP6_LEYILI_CHAIN" \
     || ! ip6tables -A "$IP6_LEYILI_CHAIN" -i lo -m comment --comment "leyili-managed" -j ACCEPT \
     || ! ip6tables -A "$IP6_LEYILI_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "leyili-managed" -j ACCEPT \
     || ! ip6tables -A "$IP6_LEYILI_CHAIN" -p ipv6-icmp -m comment --comment "leyili-managed" -j ACCEPT \
     || ! ip6tables -P INPUT DROP \
     || ! ip6_save_rules; then
    firewall_transaction_rollback 6 "$txn"
    echo -e "${R}规则写入或持久化失败，已恢复原规则${N}"
    pause_screen
    return 1
  fi
  firewall_transaction_commit "$txn"

  echo ""
  echo -e "${G}IPv6 默认拒绝策略已启用${N}"
  echo -e "  ${D}用户 INPUT 规则均已保留；未启动延时回滚守护。${N}"
  pause_screen
}

ip6_open_port(){
  local proto_choice protos="" port proto changed=0 txn

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

  txn=$(firewall_transaction_begin 6) || { echo -e "${R}防火墙快照失败${N}"; pause_screen; return 1; }
  for proto in $protos; do
    if ip6tables -C "$IP6_LEYILI_CHAIN" -p "$proto" --dport "$port" -m comment --comment "leyili-managed" -j ACCEPT 2>/dev/null; then
      echo -e "  ${Y}${port}/${proto} 已放行，跳过${N}"
    else
      if ! firewall_add_managed_port 6 "$proto" "$port"; then
        firewall_transaction_rollback 6 "$txn"
        echo -e "${R}规则写入失败，已恢复原规则${N}"
        pause_screen
        return 1
      fi
      echo -e "  ${G}已放行 ${port}/${proto}${N}"
      changed=1
    fi
  done

  if [ "$changed" -eq 1 ] && ! ip6_save_rules; then
    firewall_transaction_rollback 6 "$txn"
    echo -e "${R}持久化失败，已恢复原规则${N}"
    pause_screen
    return 1
  fi
  firewall_transaction_commit "$txn"
  pause_screen
}

ip6_close_port(){
  local proto_choice protos="" port ssh_port confirm proto removed=0 txn

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

  txn=$(firewall_transaction_begin 6) || { echo -e "${R}防火墙快照失败${N}"; pause_screen; return 1; }
  for proto in $protos; do
    if ip6tables -C "$IP6_LEYILI_CHAIN" -p "$proto" --dport "$port" -m comment --comment "leyili-managed" -j ACCEPT 2>/dev/null; then
      if ! firewall_remove_managed_port 6 "$proto" "$port"; then
        firewall_transaction_rollback 6 "$txn"
        echo -e "${R}删除失败，已恢复原规则${N}"
        pause_screen
        return 1
      fi
      echo -e "  ${G}已删除脚本托管规则 ${port}/${proto}${N}"
      removed=$((removed + 1))
    fi
  done

  if [ "$removed" -eq 0 ]; then
    echo -e "  ${Y}端口 ${port} 在所选协议下没有放行规则${N}"
  else
    if ! ip6_save_rules; then
      firewall_transaction_rollback 6 "$txn"
      echo -e "${R}持久化失败，已恢复原规则${N}"
      pause_screen
      return 1
    fi
  fi
  firewall_transaction_commit "$txn"
  for proto in $protos; do
    if ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
      echo -e "  ${Y}提示：INPUT 中仍有非脚本托管的 ${port}/${proto} ACCEPT 规则，本菜单未删除。${N}"
    fi
  done
  pause_screen
}

ip6_emergency_disable(){
  local confirm confirm2 txn

  echo ""
  echo -e "  ${R}${B}紧急放行（关闭 v6 防火墙）${N}"
  render_divider
  echo "  执行后："
  echo -e "    - 删除脚本专属链 ${C}${IP6_LEYILI_CHAIN}${N}"
  echo "    - INPUT 默认策略改回 ACCEPT"
  echo "    - 保留用户规则、fail2ban 与面板规则"
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

  txn=$(firewall_transaction_begin 6) || { echo -e "${R}防火墙快照失败${N}"; pause_screen; return 1; }
  if ! ip6tables -P INPUT ACCEPT \
     || ! firewall_remove_managed_chain 6 \
     || ! ip6_save_rules; then
    firewall_transaction_rollback 6 "$txn"
    echo -e "${R}操作失败，已恢复原规则${N}"
    pause_screen
    return 1
  fi
  firewall_transaction_commit "$txn"

  echo ""
  echo -e "${Y}已停用脚本管理的 v6 防火墙（用户/面板规则仍保留）${N}"
  pause_screen
}

# ─── IPv4 防火墙菜单 ─────────────────────────────────
# ═══ source: 23-firewall-ipv4.sh ═══
show_ipv4_firewall_menu(){
  local ssh_port conflicts have_1panel=0 hp_choice

  if ! require_root; then
    return 1
  fi

  if ! ensure_iptables_installed; then
    pause_screen
    return 1
  fi

  # SSH 端口与防火墙管理器状态在进入菜单时读取一次。操作完成后函数会返回，
  # 再次进入时自然刷新；无需在每个菜单回合重复启动 ss/ufw/systemctl。
  ssh_port=$(ip6_detect_ssh_port)
  conflicts=$(ip4_detect_conflicts)
  case " $conflicts " in
    *" 1Panel "*) have_1panel=1 ;;
  esac

  # 一次性提示：检测到 1Panel 时引导用户清理脚本残留 IPv4 规则
  if [ "$have_1panel" -eq 1 ] && [ "${IP4_1PANEL_HANDOFF_PROMPTED:-0}" -ne 1 ]; then
    echo ""
    echo -e "  ${R}${B}检测到 1Panel 在管理 IPv4 防火墙${N}"
    render_divider
    echo -e "  ${Y}本脚本之前可能下发过 INPUT DROP/ACCEPT 规则，会与 1Panel 冲突${N}"
    echo -e "  ${D}清理动作：删除脚本专属链 ${C}${IP4_LEYILI_CHAIN}${N}，INPUT 改为 ACCEPT 并持久化${N}"
    echo -e "  ${D}用户规则与 fail2ban 链不会被清空，清理后由 1Panel 接管新增策略${N}"
    echo ""
    read -p "  立即清理脚本残留 IPv4 规则交还 1Panel？(y/N): " hp_choice
    if [ "$hp_choice" = "y" ] || [ "$hp_choice" = "Y" ]; then
      if ip4_handover_to_1panel; then
        echo -e "  ${G}已移除脚本专属链并切回 ACCEPT，IPv4 防火墙由 1Panel 接管${N}"
      else
        echo -e "  ${R}清理失败，请手动检查${N}"
      fi
    else
      echo -e "  ${D}已跳过自动清理（菜单仍会禁用写入操作）${N}"
    fi
    IP4_1PANEL_HANDOFF_PROMPTED=1
  fi

  while true; do
    render_section_header "IPv4 防火墙管理"
    echo -e "  ${L}│${N}  SSH 端口  ${D}·${N}  ${C}${ssh_port}${N}"
    if [ "$have_1panel" -eq 1 ]; then
      echo -e "  ${L}│${N}  ${R}${B}已托管${N}    ${D}·${N}  ${Y}1Panel 在管理 IPv4 防火墙，本菜单写入操作已禁用${N}"
    elif [ -n "$conflicts" ]; then
      echo -e "  ${L}│${N}  ${R}${B}冲突警告${N}  ${D}·${N}  ${Y}检测到 ${C}${conflicts}${N}${Y} 在管理 IPv4 防火墙${N}"
      echo -e "  ${L}│${N}  ${D}            本菜单直接改 iptables，可能与上述工具冲突或被覆盖${N}"
    fi
    echo -e "  ${L}│${N}  说明      ${D}·${N}  ${D}本菜单只动 IPv4，不影响 IPv6 / Docker FORWARD${N}"
    render_divider
    render_menu_item 1 "查看当前规则"
    render_menu_item 2 "查看监听 IPv4 的服务"
    if [ "$have_1panel" -eq 1 ]; then
      render_menu_item 3 "一键初始化 (放行 SSH/80/443)  ${R}[已禁用·1Panel 托管]${N}"
      render_menu_item 4 "开放端口  ${R}[已禁用·1Panel 托管]${N}"
      render_menu_item 5 "关闭端口  ${R}[已禁用·1Panel 托管]${N}"
      render_menu_item 6 "紧急放行 (关闭 v4 防火墙)  ${R}[已禁用·1Panel 托管]${N}"
    else
      render_menu_item 3 "一键初始化 (放行 SSH/80/443)"
      render_menu_item 4 "开放端口"
      render_menu_item 5 "关闭端口"
      render_menu_item 6 "紧急放行 (关闭 v4 防火墙)"
    fi
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1) ip4_view_rules ;;
      2) ip4_view_listening ;;
      3|4|5|6)
        if [ "$have_1panel" -eq 1 ]; then
          echo ""
          echo -e "  ${Y}1Panel 正在管理 IPv4 防火墙，本项已禁用${N}"
          echo -e "  ${D}请到 1Panel Web 面板「主机 → 防火墙」管理 IPv4 端口策略${N}"
          pause_screen
        else
          case $choice in
            3) ip4_init_firewall ;;
            4) ip4_open_port ;;
            5) ip4_close_port ;;
            6) ip4_emergency_disable ;;
          esac
        fi
        ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

ip4_view_rules(){
  local input_policy output_policy forward_policy opened rules

  rules=$(iptables-save 2>/dev/null)
  input_policy=$(printf '%s\n' "$rules" | firewall_policy_from_saved_rules INPUT)
  output_policy=$(printf '%s\n' "$rules" | firewall_policy_from_saved_rules OUTPUT)
  forward_policy=$(printf '%s\n' "$rules" | firewall_policy_from_saved_rules FORWARD)

  echo ""
  echo -e "  ${B}${C}默认策略${N}"
  echo -e "  INPUT   : ${C}${input_policy}${N}  ${D}(别人主动连你)${N}"
  echo -e "  OUTPUT  : ${C}${output_policy}${N}  ${D}(你主动出去连别人)${N}"
  echo -e "  FORWARD : ${C}${forward_policy}${N}  ${D}(转发, Docker 用, 脚本不动)${N}"
  echo ""

  echo -e "  ${B}${C}已开放的入站端口${N}"
  opened=$(printf '%s\n' "$rules" | firewall_list_opened_ports_from_saved_rules lines)

  if [ -z "$opened" ]; then
    echo -e "  ${D}(无)${N}"
  else
    echo "$opened"
  fi
  echo ""

  echo -e "  ${B}${C}完整 INPUT 规则${N}"
  iptables -L INPUT -n -v --line-numbers
  if firewall_managed_chain_exists 4; then
    echo ""
    echo -e "  ${B}${C}${IP4_LEYILI_CHAIN} 规则${N}"
    iptables -L "$IP4_LEYILI_CHAIN" -n -v --line-numbers
  fi
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
  local ssh_port confirm conflicts txn node node_port node_mode node_proto

  # 缺 ss 工具无法验证 sshd 监听，直接拒绝，避免写错 SSH 放行端口。
  if ! command -v ss >/dev/null 2>&1; then
    echo ""
    echo -e "  ${R}本机未安装 ss 命令（iproute2 包），无法安全验证 SSH 监听端口${N}"
    echo -e "  ${Y}请先执行：apt install -y iproute2${N}"
    pause_screen
    return 1
  fi

  ssh_port=$(ip6_detect_ssh_port)
  conflicts=$(ip4_detect_conflicts)

  echo ""
  echo -e "  ${B}${C}一键初始化${N}"
  render_divider
  echo "  本次会执行："
  echo -e "    1) 仅重建脚本专属链 ${C}${IP4_LEYILI_CHAIN}${N}，保留用户与 fail2ban 规则"
  echo "    2) 放行回环、已建立连接与 ICMP"
  echo -e "    3) 放行 SSH ${C}${ssh_port}/tcp${N}、80/tcp、443/tcp"
  echo "    4) 自动恢复全部已安装节点的 IPv4 主端口"
  echo "    5) INPUT 默认策略 = DROP"
  echo "    6) OUTPUT / FORWARD 保持原样"
  echo ""
  echo -e "  ${D}所有写入均先快照；任一步失败会立即恢复活动规则与持久化文件。${N}"
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

  if ! ip6_ensure_persistence; then
    echo ""
    echo -e "${R}持久化工具安装失败${N}"
    pause_screen
    return 1
  fi

  txn=$(firewall_transaction_begin 4) || { echo -e "${R}防火墙快照失败${N}"; pause_screen; return 1; }
  if ! firewall_ensure_managed_chain 4 \
     || ! iptables -F "$IP4_LEYILI_CHAIN" \
     || ! iptables -A "$IP4_LEYILI_CHAIN" -i lo -m comment --comment "leyili-managed" -j ACCEPT \
     || ! iptables -A "$IP4_LEYILI_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "leyili-managed" -j ACCEPT \
     || ! iptables -A "$IP4_LEYILI_CHAIN" -p icmp -m comment --comment "leyili-managed" -j ACCEPT \
     || ! firewall_add_managed_port 4 tcp "$ssh_port" \
     || ! firewall_add_managed_port 4 tcp 80 \
     || ! firewall_add_managed_port 4 tcp 443; then
    firewall_transaction_rollback 4 "$txn"
    echo -e "${R}基础规则写入失败，已恢复原规则${N}"
    pause_screen
    return 1
  fi

  for node in reality hy2 anytls tuic ss2022; do
    node_installed "$node" || continue
    node_port=$(get_node_value "$node" Port 2>/dev/null || true)
    node_mode=$(get_node_value "$node" Mode 2>/dev/null || echo ipv4)
    [ -n "$node_port" ] || continue
    { [ "$node_mode" = "ipv4" ] || [ "$node_mode" = "dualstack" ]; } || continue
    case "$node" in hy2|tuic) node_proto="udp" ;; *) node_proto="tcp" ;; esac
    if ! firewall_add_managed_port 4 "$node_proto" "$node_port"; then
      firewall_transaction_rollback 4 "$txn"
      echo -e "${R}恢复 ${node} 端口失败，已恢复原规则${N}"
      pause_screen
      return 1
    fi
    echo -e "  ${G}已恢复 ${node}：${node_port}/${node_proto}${N}"
  done

  if ! iptables -P INPUT DROP \
     || ! verify_sshd_listening_on_port "$ssh_port" \
     || ! ip4_save_rules; then
    firewall_transaction_rollback 4 "$txn"
    echo -e "${R}规则校验或持久化失败，已恢复原规则${N}"
    pause_screen
    return 1
  fi
  firewall_transaction_commit "$txn"

  echo ""
  echo -e "${G}IPv4 防火墙已启用${N}"
  echo -e "  ${D}用户 INPUT 规则与 fail2ban 链均已保留；未启动延时回滚守护。${N}"
  pause_screen
}

ip4_open_port(){
  local proto_choice protos="" port proto changed=0 txn

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

  txn=$(firewall_transaction_begin 4) || { echo -e "${R}防火墙快照失败${N}"; pause_screen; return 1; }
  for proto in $protos; do
    if iptables -C "$IP4_LEYILI_CHAIN" -p "$proto" --dport "$port" -m comment --comment "leyili-managed" -j ACCEPT 2>/dev/null; then
      echo -e "  ${Y}${port}/${proto} 已放行，跳过${N}"
    else
      if ! firewall_add_managed_port 4 "$proto" "$port"; then
        firewall_transaction_rollback 4 "$txn"
        echo -e "${R}规则写入失败，已恢复原规则${N}"
        pause_screen
        return 1
      fi
      echo -e "  ${G}已放行 ${port}/${proto}${N}"
      changed=1
    fi
  done

  if [ "$changed" -eq 1 ] && ! ip4_save_rules; then
    firewall_transaction_rollback 4 "$txn"
    echo -e "${R}持久化失败，已恢复原规则${N}"
    pause_screen
    return 1
  fi
  firewall_transaction_commit "$txn"
  pause_screen
}

ip4_close_port(){
  local proto_choice protos="" port ssh_port confirm proto removed=0 txn

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

  txn=$(firewall_transaction_begin 4) || { echo -e "${R}防火墙快照失败${N}"; pause_screen; return 1; }
  for proto in $protos; do
    if iptables -C "$IP4_LEYILI_CHAIN" -p "$proto" --dport "$port" -m comment --comment "leyili-managed" -j ACCEPT 2>/dev/null; then
      if ! firewall_remove_managed_port 4 "$proto" "$port"; then
        firewall_transaction_rollback 4 "$txn"
        echo -e "${R}删除失败，已恢复原规则${N}"
        pause_screen
        return 1
      fi
      echo -e "  ${G}已删除脚本托管规则 ${port}/${proto}${N}"
      removed=$((removed + 1))
    fi
  done

  if [ "$removed" -eq 0 ]; then
    echo -e "  ${Y}端口 ${port} 在所选协议下没有放行规则${N}"
  else
    if ! ip4_save_rules; then
      firewall_transaction_rollback 4 "$txn"
      echo -e "${R}持久化失败，已恢复原规则${N}"
      pause_screen
      return 1
    fi
  fi
  firewall_transaction_commit "$txn"
  for proto in $protos; do
    if iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
      echo -e "  ${Y}提示：INPUT 中仍有非脚本托管的 ${port}/${proto} ACCEPT 规则，本菜单未删除。${N}"
    fi
  done
  pause_screen
}

ip4_emergency_disable(){
  local confirm confirm2 txn

  echo ""
  echo -e "  ${R}${B}紧急放行（关闭 v4 防火墙）${N}"
  render_divider
  echo "  执行后："
  echo -e "    - 删除脚本专属链 ${C}${IP4_LEYILI_CHAIN}${N}"
  echo "    - INPUT 默认策略改回 ACCEPT"
  echo "    - 保留用户规则、fail2ban 与面板规则"
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

  txn=$(firewall_transaction_begin 4) || { echo -e "${R}防火墙快照失败${N}"; pause_screen; return 1; }
  if ! iptables -P INPUT ACCEPT \
     || ! firewall_remove_managed_chain 4 \
     || ! ip4_save_rules; then
    firewall_transaction_rollback 4 "$txn"
    echo -e "${R}操作失败，已恢复原规则${N}"
    pause_screen
    return 1
  fi
  firewall_transaction_commit "$txn"

  echo ""
  echo -e "${Y}已停用脚本管理的 v4 防火墙（用户/面板规则仍保留）${N}"
  pause_screen
}
# ═══ source: 24-system-admin-high.sh ═══
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

  echo ""
  if ! node_apply_firewall_for_mode "$ssh_port" tcp dualstack; then
    echo -e "${R}新 SSH 端口防火墙放行失败，已中止修改${N}"
    pause_screen
    return 1
  fi

  if apply_sshd_setting "Port" "$ssh_port" "SSH 端口已更新并重启服务"; then
    cleanup_old_backups "${SSHD_CONFIG_PATH}.bak.*" 5

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
  local pwd_auth_effective="" pubkey_auth_effective=""

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

  # 必须至少有 1 个非 root 的 sudo 用户按当前认证策略可 SSH 登录。
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
    pwd_auth_effective=$(get_effective_sshd_value PasswordAuthentication "$user")
    pubkey_auth_effective=$(get_effective_sshd_value PubkeyAuthentication "$user")
    home_dir=$(getent passwd "$user" | cut -d: -f6)
    if [ "$pubkey_auth_effective" != "no" ] \
       && [ -n "$home_dir" ] && [ -s "$home_dir/.ssh/authorized_keys" ]; then
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
# ═══ source: 25-system-basic.sh ═══
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

  if grep -Fq '# Managed by Leyili' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null \
     || [ -e /etc/apt/apt.conf.d/20auto-upgrades.leyili-original ]; then
    if ! managed_file_restore /etc/apt/apt.conf.d/20auto-upgrades; then
      echo -e "${R}恢复启用前的自动更新配置失败${N}"
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
  local confirm="" unit tmp_config="" rc=0

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
  for unit in unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer; do
    if systemctl is-active --quiet "$unit" 2>/dev/null \
       || systemctl is-enabled --quiet "$unit" 2>/dev/null; then
      systemctl disable --now "$unit" >/dev/null 2>&1 || rc=1
    fi
  done
  if ! managed_file_prepare /etc/apt/apt.conf.d/20auto-upgrades 'Managed by Leyili'; then
    rc=1
  else
    tmp_config=$(mktemp /etc/apt/apt.conf.d/20auto-upgrades.tmp.XXXXXX) || rc=1
  fi
  if [ -n "$tmp_config" ] && ! cat > "$tmp_config" << 'EOF'
# Managed by Leyili
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
  then
    rc=1
  fi
  if [ -n "$tmp_config" ] \
     && { ! chmod 644 "$tmp_config" || ! mv -f -- "$tmp_config" /etc/apt/apt.conf.d/20auto-upgrades; }; then
    rm -f -- "$tmp_config"
    rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    echo -e "${R}自动更新禁用未完全成功，请检查 systemd 定时器与 20auto-upgrades${N}"
    pause_screen
    return 1
  fi

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
    # 全新 VPS apt 缓存可能为空，先 update 再重试一次
    echo -e "${Y}==> 安装失败，刷新 apt 索引后重试...${N}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    if ! apt install -y $BASIC_TOOLS_PACKAGES; then
      echo ""
      echo -e "${R}基础工具安装失败，请检查上方输出${N}"
      pause_screen
      return 1
    fi
  fi

  echo ""
  echo -e "${G}基础工具安装完成${N}"
  pause_screen
}

# ─── fail2ban SSH 防爆破 ─────────────────────────────
normalize_fail2ban_port_list(){
  local raw="${1:-}" item ports="" count=0
  local -a items=()

  raw="${raw//，/,}"
  raw="${raw//；/,}"
  raw="${raw//;/,}"
  raw="${raw//$'\t'/,}"
  raw="${raw// /,}"
  IFS=',' read -r -a items <<< "$raw"

  for item in "${items[@]}"; do
    [ -n "$item" ] || continue
    validate_port "$item" || return 1
    item=$((10#$item))

    case ",${ports}," in
      *",${item},"*) continue ;;
    esac

    count=$((count + 1))
    [ "$count" -le 15 ] || return 2
    ports="${ports:+${ports},}${item}"
  done

  [ -n "$ports" ] || return 1
  printf '%s' "$ports"
}

fail2ban_transaction_restore(){
  local txn_dir="$1" was_active="$2" was_enabled="$3" rc=0
  if [ -f "$txn_dir/jail.existed" ]; then
    restore_file_snapshot "$txn_dir/jail.local" "$FAIL2BAN_JAIL_PATH" || rc=1
  else
    rm -f -- "$FAIL2BAN_JAIL_PATH" || rc=1
  fi
  if [ "$was_enabled" -eq 1 ]; then
    systemctl enable fail2ban >/dev/null 2>&1 || rc=1
  else
    systemctl disable fail2ban >/dev/null 2>&1 || rc=1
  fi
  if [ "$was_active" -eq 1 ]; then
    systemctl restart fail2ban >/dev/null 2>&1 || rc=1
  else
    systemctl stop fail2ban >/dev/null 2>&1 || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    rm -rf -- "$txn_dir" || rc=1
  fi
  [ "$rc" -eq 0 ] || echo -e "${R}fail2ban 回滚未完全成功，私有快照保留在 ${txn_dir}${N}" >&2
  return "$rc"
}

setup_fail2ban(){
  if ! require_root; then return 1; fi
  if ! require_debian_family; then
    pause_screen
    return 1
  fi

  render_section_header "安装 / 配置 fail2ban (SSH 多端口)"

  local current_ssh_port default_ports saved_ports input_ports ports normalize_status
  local txn_dir tmp_jail ping_ok=0 was_active=0 was_enabled=0 i
  current_ssh_port=$(get_current_ssh_port)
  default_ports="$current_ssh_port"

  if [ -f "$FAIL2BAN_JAIL_PATH" ]; then
    saved_ports=$(awk -F= '
      /^[[:space:]]*port[[:space:]]*=/ {
        value=$2
        gsub(/[[:space:]]/, "", value)
        print value
        exit
      }
    ' "$FAIL2BAN_JAIL_PATH" 2>/dev/null)
    if [ -n "$saved_ports" ] && ports=$(normalize_fail2ban_port_list "$saved_ports"); then
      default_ports="$ports"
    fi
  fi

  echo -e "  ${L}●${N} 当前检测到的 SSH 端口: ${C}${current_ssh_port}${N}"
  if [ "$default_ports" != "$current_ssh_port" ]; then
    echo -e "  ${L}●${N} 当前 fail2ban 保护端口: ${C}${default_ports}${N}"
  fi
  echo -e "  ${L}●${N} 配置参数: ${C}maxretry=${FAIL2BAN_MAXRETRY}  bantime=${FAIL2BAN_BANTIME}s  findtime=${FAIL2BAN_FINDTIME}s${N}"
  echo -e "  ${D}多个端口可用逗号或空格分隔，最多 15 个；仅填写 sshd 实际监听的端口。${N}"
  echo -e "  ${D}此处只配置防爆破，不会修改 SSH 监听端口，也不会自动开放防火墙。${N}"
  echo ""

  while :; do
    read -p "  请输入需要保护的 SSH 端口列表 (回车使用 ${default_ports}): " input_ports
    input_ports="${input_ports:-$default_ports}"
    if ports=$(normalize_fail2ban_port_list "$input_ports"); then
      break
    else
      normalize_status=$?
    fi
    if [ "$normalize_status" -eq 2 ]; then
      echo -e "  ${R}端口数量过多，最多支持 15 个不重复端口${N}"
    else
      echo -e "  ${R}端口列表无效：每项需为 1-65535 之间的整数，并用逗号或空格分隔${N}"
    fi
  done

  echo ""
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    echo -e "${Y}==> 安装 fail2ban...${N}"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban; then
      echo -e "${Y}==> 安装失败，刷新 apt 索引后重试...${N}"
      DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
      if ! DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban; then
        echo -e "${R}fail2ban 安装失败，请检查上方输出${N}"
        pause_screen
        return 1
      fi
    fi
  else
    echo -e "  ${L}●${N} fail2ban 已安装，跳过安装步骤"
  fi

  mkdir -p "$(dirname -- "$FAIL2BAN_JAIL_PATH")" || return 1
  txn_dir=$(mktemp -d "${TMPDIR:-/tmp}/leyili-fail2ban.XXXXXX") || return 1
  chmod 700 "$txn_dir" 2>/dev/null || { rm -rf -- "$txn_dir"; return 1; }
  if [ -f "$FAIL2BAN_JAIL_PATH" ]; then
    cp -a -- "$FAIL2BAN_JAIL_PATH" "$txn_dir/jail.local" || { rm -rf -- "$txn_dir"; return 1; }
    : > "$txn_dir/jail.existed"
  fi
  systemctl is-active --quiet fail2ban 2>/dev/null && was_active=1
  systemctl is-enabled --quiet fail2ban 2>/dev/null && was_enabled=1

  if [ -f "$FAIL2BAN_JAIL_PATH" ]; then
    cp -a "$FAIL2BAN_JAIL_PATH" "${FAIL2BAN_JAIL_PATH}.bak.$(date +%Y%m%d%H%M%S)" || {
      rm -rf -- "$txn_dir"
      return 1
    }
    cleanup_old_backups "${FAIL2BAN_JAIL_PATH}.bak.*" 5 \
      || echo -e "${Y}旧 fail2ban 备份清理失败，本次配置仍会继续${N}" >&2
  fi

  tmp_jail=$(mktemp "${FAIL2BAN_JAIL_PATH}.tmp.XXXXXX") || { rm -rf -- "$txn_dir"; return 1; }
  cat > "$tmp_jail" <<EOF
# Managed by ${APP_NAME} — do not edit by hand, it will be overwritten.
[sshd]
enabled  = true
port     = ${ports}
backend  = systemd
maxretry = ${FAIL2BAN_MAXRETRY}
bantime  = ${FAIL2BAN_BANTIME}
findtime = ${FAIL2BAN_FINDTIME}
EOF
  chmod 600 "$tmp_jail" || { rm -f -- "$tmp_jail"; rm -rf -- "$txn_dir"; return 1; }
  if ! mv -f -- "$tmp_jail" "$FAIL2BAN_JAIL_PATH" \
     || ! fail2ban-client -t >/dev/null 2>&1 \
     || ! systemctl enable fail2ban >/dev/null 2>&1 \
     || ! systemctl restart fail2ban; then
    local rollback_ok=1
    fail2ban_transaction_restore "$txn_dir" "$was_active" "$was_enabled" || rollback_ok=0
    echo ""
    if [ "$rollback_ok" -eq 1 ]; then
      echo -e "${R}fail2ban 配置校验或启动失败，已恢复旧 jail 与服务状态${N}"
    else
      echo -e "${R}fail2ban 配置失败，且回滚未完全成功，请立即检查服务状态${N}"
    fi
    pause_screen
    return 1
  fi

  # 等待 socket 就绪再调用 fail2ban-client，避免首次启动竞争
  for i in 1 2 3 4 5; do
    if fail2ban-client ping >/dev/null 2>&1; then ping_ok=1; break; fi
    sleep 1
  done
  if [ "$ping_ok" -ne 1 ]; then
    local rollback_ok=1
    fail2ban_transaction_restore "$txn_dir" "$was_active" "$was_enabled" || rollback_ok=0
    if [ "$rollback_ok" -eq 1 ]; then
      echo -e "${R}fail2ban socket 未就绪，已恢复旧配置与服务状态${N}"
    else
      echo -e "${R}fail2ban socket 未就绪，且回滚未完全成功，请立即检查服务状态${N}"
    fi
    pause_screen
    return 1
  fi
  if ! rm -rf -- "$txn_dir"; then
    echo -e "${Y}fail2ban 已生效，但事务临时目录清理失败：${txn_dir}${N}" >&2
  fi

  echo ""
  echo -e "${G}fail2ban 已配置并启动${N}"
  echo -e "  ${L}●${N} 配置文件 : ${C}${FAIL2BAN_JAIL_PATH}${N}"
  echo -e "  ${L}●${N} 保护端口 : ${C}${ports}${N}"
  echo -e "  ${L}●${N} 最大重试 : ${C}${FAIL2BAN_MAXRETRY}${N} 次"
  echo -e "  ${L}●${N} 发现时间 : ${C}${FAIL2BAN_FINDTIME}${N} 秒"
  echo -e "  ${L}●${N} 禁用时间 : ${C}${FAIL2BAN_BANTIME}${N} 秒"
  echo ""
  echo -e "  ${B}${C}›  当前 sshd jail 状态${N}"
  fail2ban-client status sshd 2>/dev/null || echo -e "  ${Y}sshd jail 暂未就绪，可稍后执行: fail2ban-client status sshd${N}"

  pause_screen
}
# ═══ source: 30-node-render.sh ═══
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
    anytls)
      local pwd_v pubk_v sid_v
      pwd_v=$(get_node_value "$type" Password 2>/dev/null || true)
      pubk_v=$(get_node_value "$type" PublicKey 2>/dev/null || true)
      sid_v=$(get_node_value "$type" ShortID 2>/dev/null || true)
      echo -e "  类型      : ${C}AnyTLS${N}  Tag : ${C}${tag}${N}"
      echo -e "  Password  : ${C}${pwd_v:-未知}${N}"
      echo -e "  PublicKey : ${C}${pubk_v:-未知}${N} ${D}(共享自 Reality)${N}"
      echo -e "  ShortID   : ${C}${sid_v:-未知}${N} ${D}(共享自 Reality)${N}"
      echo -e "  模式      : ${C}${mode_label}${N}"
      echo -e "  IP        : ${C}${ip:-未知}${N}"
      echo -e "  端口      : ${C}${port:-未知}${N} ${D}(TCP)${N}"
      echo -e "  SNI       : ${C}${sni:-未知}${N}"
      ;;
    ss2022)
      local method_v pwd_v
      method_v=$(get_node_value "$type" Method 2>/dev/null || true)
      pwd_v=$(get_node_value "$type" Password 2>/dev/null || true)
      echo -e "  类型      : ${C}Shadowsocks-2022${N}  Tag : ${C}${tag}${N}"
      echo -e "  加密方式  : ${C}${method_v:-未知}${N}"
      echo -e "  Password  : ${C}${pwd_v:-未知}${N}"
      echo -e "  模式      : ${C}${mode_label}${N}"
      echo -e "  IP        : ${C}${ip:-未知}${N}"
      echo -e "  端口      : ${C}${port:-未知}${N} ${D}(TCP)${N}"
      echo -e "  ${R}⚠ 谨慎：抗主动探测较弱，避免在高 GFW 风险链路单独使用${N}"
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
  local cur_port cur_sni cur_uuid backup_path="" confirm txn=""

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
    if validate_port "$new_port"; then
      new_port=$((10#$new_port))
      if [ "$new_port" != "$cur_port" ] && check_port_in_use "$new_port" tcp; then
        local force_port=""
        echo -e "${R}端口 ${new_port} 已被其他 TCP 服务占用${N}"
        read -p "  仍然使用此端口？(y/N): " force_port
        if [ "$force_port" != "y" ] && [ "$force_port" != "Y" ]; then
          continue
        fi
      fi
      break
    fi
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

  ensure_jq || { pause_screen; return 1; }
  txn=$(node_transaction_begin reality) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  if ! cp "$CONFIG_PATH" "$backup_path"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置备份失败${N}"
    pause_screen
    return 1
  fi

  local jq_filter='(.inbounds[] | select(.tag == "reality-in"))
    |= ( .listen_port = ($port | tonumber)
       | .users[0].uuid = $uuid
       | .tls.server_name = $sni
       | .tls.reality.handshake.server = $sni
       | (if $pri != "" then .tls.reality.private_key = $pri else . end)
       | (if $sid != "" then .tls.reality.short_id = [$sid] else . end))'

  local tmp_file
  tmp_file=$(mktemp)
  # 兜底：函数返回时清理临时文件（不挂 INT/TERM，避免污染全局信号 trap）
  trap 'rm -f "$tmp_file"' RETURN
  if ! jq --arg port "$new_port" --arg sni "$new_sni" --arg uuid "$new_uuid" \
       --arg pri "${new_pri:-}" --arg sid "${new_short_id:-}" \
       "$jq_filter" "$CONFIG_PATH" > "$tmp_file"; then
    rm -f "$tmp_file"
    node_transaction_rollback "$txn"
    echo -e "${R}配置写入失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  if ! mv "$tmp_file" "$CONFIG_PATH"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置替换失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if ! config_check_and_restart "$new_port" tcp; then
    node_transaction_rollback "$txn"
    echo ""
    echo -e "${R}配置校验或服务健康检查失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if [ -n "$new_port" ] && [ "$new_port" != "$cur_port" ]; then
    local rt_mode_now
    rt_mode_now=$(get_node_value reality Mode 2>/dev/null || echo ipv4)
    if [ -n "$cur_port" ] && ! node_revoke_firewall_for_mode "$cur_port" tcp "$rt_mode_now"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧防火墙端口清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    if ! node_apply_firewall_for_mode "$new_port" tcp "$rt_mode_now"; then
      node_transaction_rollback "$txn"
      echo -e "${R}防火墙端口切换失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    print_firewall_hint "$new_port" tcp "Reality 节点新端口"
  fi

  if ! set_node_value reality Port "$new_port" \
     || ! set_node_value reality SNI "$new_sni" \
     || ! set_node_value reality UUID "$new_uuid"; then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  if [ -n "$new_pub" ]; then
    if ! set_node_value reality PublicKey "$new_pub" \
       || ! set_node_value reality PrivateKey "$new_pri" \
       || ! set_node_value reality ShortID "$new_short_id"; then
      node_transaction_rollback "$txn"
      echo -e "${R}Reality 密钥信息保存失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi

  local cur_ip cur_tag final_pub final_sid new_link ipv6_new_link
  cur_ip=$(get_node_value reality IP 2>/dev/null || true)
  cur_tag=$(get_node_value reality Tag 2>/dev/null || echo reality)
  final_pub="${new_pub:-$(get_node_value reality PublicKey 2>/dev/null || true)}"
  final_sid="${new_short_id:-$(get_node_value reality ShortID 2>/dev/null || true)}"
  new_link=$(build_reality_link "$new_uuid" "$cur_ip" "$new_port" "$new_sni" "$final_pub" "$final_sid" "${cur_tag:-reality}" 2>/dev/null || true)
  ipv6_new_link=$(build_dualstack_ipv6_link_for_node reality 2>/dev/null || true)
  if [ -n "$new_link" ] && ! set_node_value reality Link "$new_link"; then
    node_transaction_rollback "$txn"
    echo -e "${R}客户端链接保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  node_transaction_commit "$txn"
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
    anytls)  modify_anytls_params ;;
    tuic)    modify_tuic_params ;;
    ss2022)  modify_ss2022_params ;;
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
      DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
      if ! apt-get install -y qrencode 2>/dev/null; then
        echo -e "${R}qrencode 安装失败，请手动执行：apt install qrencode${N}"
        return 1
      fi
    fi
  fi

  echo ""
  echo -e "  ${B}扫码导入：${N}"
  echo ""
  qrencode -t ANSIUTF8 "$link"
}
# ═══ source: 40-network-tuning.sh ═══
# TCP 调优唯一入口是智能调参向导（实测 RTT × 带宽算 BDP），buffer_max 由向导
# 计算后传入。固定地区档（hk/jp/us-west/us-west-100m/eu × 内存档查表）已随
# 菜单一并移除；各内存档封顶值保留在 _tcp_autotune_ceiling（= 历史档位最大值），
# 老机器上 region=hk 等存量 marker 仅在状态页 / 首页卡片保留展示映射。
capture_live_qdisc(){
  local state_file="$1" iface qdisc
  [ -e "$state_file" ] && return 0
  command -v tc >/dev/null 2>&1 || return 0
  iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
  [ -n "$iface" ] || return 0
  qdisc=$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1 {print $2; exit}')
  [ -n "$qdisc" ] || return 0
  ensure_leyili_state_dir || return 1
  printf 'iface=%s\nqdisc=%s\n' "$iface" "$qdisc" > "$state_file" || return 1
  chmod 600 "$state_file" 2>/dev/null || { rm -f -- "$state_file"; return 1; }
}

restore_live_qdisc(){
  local state_file="$1" remove_after="${2:-0}" iface qdisc rc=0
  [ -r "$state_file" ] || return 0
  iface=$(awk -F= '$1 == "iface" {print $2; exit}' "$state_file")
  qdisc=$(awk -F= '$1 == "qdisc" {print $2; exit}' "$state_file")
  if [ -n "$iface" ] && [ -n "$qdisc" ] && command -v tc >/dev/null 2>&1; then
    tc qdisc replace dev "$iface" root "$qdisc" >/dev/null 2>&1 || rc=1
  elif [ -n "$iface" ] && [ -n "$qdisc" ]; then
    rc=1
  fi
  if [ "$remove_after" = "1" ] && [ "$rc" -eq 0 ]; then
    rm -f -- "$state_file" || rc=1
  fi
  [ "$rc" -eq 0 ] || echo -e "${R}qdisc 恢复失败，状态快照已保留：${state_file}${N}" >&2
  return "$rc"
}

tcp_tuning_abort(){
  local file_txn="$1" runtime_state="$2" runtime_qdisc="$3"
  local tcp_state_created="${4:-0}" qdisc_state_created="${5:-0}" rc=0

  [ -n "$runtime_state" ] && sysctl_state_restore "$runtime_state" || {
    [ -z "$runtime_state" ] || rc=1
  }
  [ -n "$runtime_qdisc" ] && restore_live_qdisc "$runtime_qdisc" 1 || {
    [ -z "$runtime_qdisc" ] || rc=1
  }
  managed_file_transaction_rollback "$TCP_TUNING_PATH" "$file_txn" || rc=1
  if [ "$rc" -eq 0 ]; then
    [ "$tcp_state_created" -eq 0 ] || rm -f -- "$TCP_TUNING_STATE" || rc=1
    [ "$qdisc_state_created" -eq 0 ] || rm -f -- "$TCP_QDISC_STATE" || rc=1
    rm -f -- "$runtime_state" "$runtime_qdisc" 2>/dev/null || rc=1
  fi
  [ "$rc" -eq 0 ] || echo -e "${R}TCP 调优回滚未完全成功，运行时/事务快照已尽量保留${N}" >&2
  return "$rc"
}

apply_tcp_tuning(){
  local mem_tier="${1:-2g}"
  local buffer_max="${2:-}"   # 按实测 BDP 算出的 buffer_max（字节）
  local rtt_ms="${3:-}"       # 实测 RTT（ms，决定 fin_timeout 分档并写入 marker）
  local bw_mbps="${4:-}"      # 有效带宽（Mbps，写入 marker 供状态页展示）
  local notsent_lowat fin_timeout mem_label
  local cc_algo qdisc_algo iface _q file_txn tmp_tuning runtime_state="" runtime_qdisc=""
  local tcp_state_created=0 qdisc_state_created=0

  if ! require_root; then return 1; fi

  notsent_lowat=16384
  # fin_timeout 按实测 RTT 分档：近程（≤150ms，原 hk/jp 档）5s，远程 10s
  fin_timeout=10
  # rtt/bw 只用于 fin_timeout 分档与 marker 展示：非法或超长值置空（marker
  # 不写），合法值强制十进制（"090" 这类前导零会被 $((...)) 按八进制解析）
  case "$rtt_ms" in
    ''|*[!0-9]*|???????*) rtt_ms="" ;;
    *)
      rtt_ms=$((10#$rtt_ms))
      [ "$rtt_ms" -le 150 ] && fin_timeout=5
      ;;
  esac
  case "$bw_mbps" in
    ''|*[!0-9]*|???????*) bw_mbps="" ;;
    *) bw_mbps=$((10#$bw_mbps)) ;;
  esac

  # buffer_max 防御性复检：保证该函数被直接调用时也不会把离谱值写进 sysctl
  #（范围 = 历史固定档位的上下限）。先卡长度（>10 位十进制必然越界，也防 10#
  # 归一化时溢出），再强制十进制归一化（前导零会被 $((...)) 与内核 sysctl
  # 解析双双当成八进制），最后卡范围
  case "$buffer_max" in
    ''|*[!0-9]*)
      echo -e "${R}缺少合法的 buffer_max 参数${N}"
      return 1
      ;;
  esac
  if [ "${#buffer_max}" -gt 10 ]; then
    echo -e "${R}buffer_max 超出安全范围 (4M-64M): ${buffer_max}${N}"
    return 1
  fi
  buffer_max=$((10#$buffer_max))
  if [ "$buffer_max" -lt 4194304 ] || [ "$buffer_max" -gt 67108864 ]; then
    echo -e "${R}buffer_max 超出安全范围 (4M-64M): ${buffer_max}${N}"
    return 1
  fi

  case "$mem_tier" in
    512m) mem_label="512MB" ;;
    1g)  mem_label="1GB"  ;;
    2g)  mem_label="2GB"  ;;
    4g)  mem_label="4GB"  ;;
    8g)  mem_label="8GB+" ;;
    *)   mem_label="$mem_tier" ;;
  esac

  file_txn=$(managed_file_transaction_begin "$TCP_TUNING_PATH" 'Managed by Leyili|leyili-profile') || {
    echo -e "${R}无法安全接管 ${TCP_TUNING_PATH}${N}"
    return 1
  }
  runtime_state=$(mktemp "${TMPDIR:-/tmp}/leyili-tcp-runtime.XXXXXX") || {
    managed_file_transaction_rollback "$TCP_TUNING_PATH" "$file_txn" || :
    return 1
  }
  rm -f -- "$runtime_state"
  runtime_qdisc=$(mktemp "${TMPDIR:-/tmp}/leyili-qdisc-runtime.XXXXXX") || {
    tcp_tuning_abort "$file_txn" "$runtime_state" "" 0 0 || :
    return 1
  }
  rm -f -- "$runtime_qdisc"
  sysctl_state_capture "$runtime_state" \
    net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.tcp_fastopen \
    net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default \
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_adv_win_scale \
    net.ipv4.tcp_notsent_lowat net.ipv4.tcp_slow_start_after_idle \
    net.ipv4.tcp_window_scaling net.ipv4.tcp_timestamps net.ipv4.tcp_sack \
    net.ipv4.tcp_mtu_probing net.ipv4.ip_no_pmtu_disc net.ipv4.tcp_tw_reuse \
    net.ipv4.tcp_fin_timeout net.ipv4.tcp_max_tw_buckets net.core.somaxconn \
    net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_syncookies \
    net.ipv4.tcp_max_orphans net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl \
    net.ipv4.tcp_keepalive_probes net.ipv4.tcp_no_metrics_save net.ipv4.tcp_ecn \
    net.ipv4.tcp_rfc1337 net.ipv4.tcp_retries2 net.ipv4.tcp_synack_retries \
    net.ipv4.tcp_orphan_retries net.ipv4.ip_local_port_range || {
      tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" 0 0 || :
      return 1
    }
  if [ ! -f "$TCP_TUNING_STATE" ]; then
    cp -a -- "$runtime_state" "$TCP_TUNING_STATE" || {
      managed_file_transaction_rollback "$TCP_TUNING_PATH" "$file_txn"
      rm -f -- "$runtime_state" "$runtime_qdisc"
      return 1
    }
    tcp_state_created=1
  fi
  if ! capture_live_qdisc "$runtime_qdisc"; then
    tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" \
      "$tcp_state_created" 0 || :
    echo -e "${R}qdisc 运行时快照失败，已中止 TCP 调优${N}" >&2
    return 1
  fi
  if [ ! -f "$TCP_QDISC_STATE" ]; then
    if ! capture_live_qdisc "$TCP_QDISC_STATE"; then
      tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" \
        "$tcp_state_created" 0 || :
      echo -e "${R}qdisc 持久快照失败，已中止 TCP 调优${N}" >&2
      return 1
    fi
    [ -f "$TCP_QDISC_STATE" ] && qdisc_state_created=1
  fi
  if [ ! -r "$runtime_state" ]; then
    tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" \
      "$tcp_state_created" "$qdisc_state_created" || :
    echo -e "${R}qdisc 状态快照失败，已中止 TCP 调优${N}" >&2
    return 1
  fi

  # --- 拥塞控制探测：BBR 不是所有内核都编译进去（精简内核 / 老 OpenVZ）---
  # 写死 bbr 会让 sysctl -p 在那一行静默报错后回落 cubic，用户以为开了 BBR。
  # 先尝试加载模块，再查 tcp_available_congestion_control，不可用时明确降级并告警。
  cc_algo="bbr"
  modprobe tcp_bbr >/dev/null 2>&1 || true
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    cc_algo="cubic"
    echo -e "${Y}==> 当前内核不支持 BBR，拥塞算法降级为 cubic${N}"
    echo -e "${D}    （精简内核 / 老 OpenVZ 常见；如需 BBR 请更换支持的内核后重跑）${N}"
  fi

  # --- qdisc 选择：fq 配合 BBR 的 pacing 效果最好，但同样可能未编译 ---
  # 用 sysctl -w 依次探测 fq → fq_codel（写成功即代表内核支持该 qdisc；
  # 这步顺带把全局 default_qdisc 设成选中值，与稍后写入配置文件的值一致）。
  # 两者都不支持时留空，不写该行、保持内核默认。
  qdisc_algo=""
  modprobe sch_fq >/dev/null 2>&1 || true
  for _q in fq fq_codel; do
    if sysctl -w "net.core.default_qdisc=${_q}" >/dev/null 2>&1; then
      qdisc_algo="$_q"
      break
    fi
  done

  echo ""
  echo -e "${Y}==> 写入 智能调参/${mem_label} TCP 参数优化配置 (上限 $((buffer_max/1024/1024))M)...${N}"

  tmp_tuning=$(mktemp "${TCP_TUNING_PATH}.tmp.XXXXXX") || {
    tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" \
      "$tcp_state_created" "$qdisc_state_created" || :
    return 1
  }
  if ! cat > "$tmp_tuning" <<EOF
# Managed by Leyili
# leyili-profile: region=custom mem_tier=${mem_tier}${rtt_ms:+ rtt=${rtt_ms}}${bw_mbps:+ bw=${bw_mbps}}
# 由 leyili.sh 智能 TCP 调参生成 (自动实测 / ${mem_label})
# 偏好：交互流（网页 / 社交 / 流媒体），非吞吐党

# --- 拥塞控制 + 调度 ---
${qdisc_algo:+net.core.default_qdisc = ${qdisc_algo}}
net.ipv4.tcp_congestion_control = ${cc_algo}
# TFO = 1 仅客户端方向；服务端在国内出口常被运营商干扰 cookie，
# 首包失败比首包提前 1RTT 更常见，因此服务端关闭
# 注意：本机 sing-box 入站也不要开 tcp_fast_open（服务端 accept 方向需 bit2，
# 即此值需为 3 才生效）；两侧保持一致，避免节点开了 TFO 但内核未支撑的空配
net.ipv4.tcp_fastopen = 1

# --- 缓冲区 (按地区 BDP 与内存档计算) ---
# default 提到 512K：小连接也能直接进入有效拥塞窗口，不用等慢启动 grow
net.core.rmem_max = ${buffer_max}
net.core.wmem_max = ${buffer_max}
net.core.rmem_default = 524288
net.core.wmem_default = 524288
net.ipv4.tcp_rmem = 16384 524288 ${buffer_max}
net.ipv4.tcp_wmem = 16384 524288 ${buffer_max}
# adv_win_scale=2：内核按 space-(space>>2) 把约 3/4 划给接收窗口、1/4 留应用层
# overhead（默认 1 是各半）。跨境高 BDP 下更大的接收窗口利于吃满带宽。
# 注：6.x 内核逐步弱化此旋钮，长期留意
net.ipv4.tcp_adv_win_scale = 2

# --- 长连接 / 慢启动 / MTU ---
# 16K：NaiveProxy 实测值，TCP-in-TLS 隧道防 HoL 阻塞 / 顿挫感的关键
# (Cloudflare 早期推荐 128K 是面向 web server 吞吐场景，不适用代理转发)
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
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_syncookies = 1
# 防止异常 orphan 吃内存（小机器场景）
net.ipv4.tcp_max_orphans = 16384

# --- 保活 (防中间设备踢空闲连接) ---
# 国内运营商 NAT 表常 5min 踢，缩短到 2min；切后台回来"第一下卡"主要由此引起
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5

# --- 代理服务器专用 ---
# 不缓存上次连接的 RTT/cwnd 指纹 (面对全球客户端必加)
net.ipv4.tcp_no_metrics_save = 1
# ECN: 2 = 被动接受不主动发起 (RFC 8311 推荐，避开国内运营商对 ECN 标记的误判)
net.ipv4.tcp_ecn = 2
# TIME-WAIT 状态下抑制迷路 RST/重复 FIN 干扰 (RFC 1337)
net.ipv4.tcp_rfc1337 = 1
# 异常连接重试 8≈100s：交互流场景下烂连接早点放弃让应用层重连
# (默认 15≈924s 太久；之前 10≈280s 对刷网页/社交仍偏长)
net.ipv4.tcp_retries2 = 8
# SYN+ACK 重试 (Cloudflare/Red Hat 主流推荐 3≈45s，比默认 5≈63s 更稳健)
net.ipv4.tcp_synack_retries = 3
# 孤儿连接重试 (HAProxy/Nginx 生产标配；默认 8 在高并发下消耗内存，3≈25s 释放)
net.ipv4.tcp_orphan_retries = 3

# --- 临时端口范围 (避开常用服务端口) ---
net.ipv4.ip_local_port_range = 10000 65535
EOF
  then
    rm -f -- "$tmp_tuning"
    tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" \
      "$tcp_state_created" "$qdisc_state_created" || :
    return 1
  fi

  if ! chmod 600 "$tmp_tuning" 2>/dev/null \
     || ! mv -f -- "$tmp_tuning" "$TCP_TUNING_PATH"; then
    rm -f -- "$tmp_tuning"
    tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" \
      "$tcp_state_created" "$qdisc_state_created" || :
    return 1
  fi

  echo -e "${Y}==> 应用 sysctl 配置...${N}"
  if ! sysctl -p "$TCP_TUNING_PATH"; then
    echo -e "${R}TCP 参数应用失败，请检查内核兼容性或 sysctl 输出${N}"
    tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" \
      "$tcp_state_created" "$qdisc_state_created" || :
    return 1
  fi

  # default_qdisc 只在「网卡注册时」读取；系统启动时 eth0 早已建好，
  # 改这个值不会动现有网卡。这里对当前默认网卡手动 replace，让 fq 本次即生效
  # （否则要等重启，用户跑完却仍是 pfifo_fast）。BBR 自带 pacing，缺 fq 不致命，
  # 故 tc 失败只警告不算整体失败。
  if [ -n "$qdisc_algo" ] && command -v tc >/dev/null 2>&1; then
    iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    if [ -n "$iface" ]; then
      if tc qdisc replace dev "$iface" root "$qdisc_algo" >/dev/null 2>&1; then
        echo -e "${D}    已对 ${iface} 应用 ${qdisc_algo} qdisc（本次生效）${N}"
      else
        echo -e "${Y}    对 ${iface} 应用 ${qdisc_algo} qdisc 失败，重启后由 default_qdisc 生效${N}"
      fi
    fi
  fi

  rm -f -- "$runtime_state" "$runtime_qdisc"
  managed_file_transaction_commit "$file_txn"

  return 0
}

remove_tcp_tuning(){
  local confirm="" rc=0

  if ! require_root; then
    return 1
  fi

  if [ ! -f "$TCP_TUNING_PATH" ]; then
    echo ""
    echo -e "${Y}未检测到 TCP 优化配置，无需移除${N}"
    pause_screen
    return 0
  fi
  if ! grep -Eq 'Managed by Leyili|leyili-profile' "$TCP_TUNING_PATH" 2>/dev/null \
     && [ ! -e "${TCP_TUNING_PATH}.leyili-original" ] \
     && [ ! -f "$TCP_TUNING_STATE" ]; then
    echo -e "${R}${TCP_TUNING_PATH} 不是脚本托管文件，拒绝删除。${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${Y}==> 即将移除 ${C}$TCP_TUNING_PATH${N}${Y}，并恢复默认 qdisc / 拥塞算法${N}"
  echo -e "${Y}    同时撤销配套的 initcwnd 持久化服务（若存在）${N}"
  read -p "  确认继续？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  managed_file_restore "$TCP_TUNING_PATH" || rc=1
  sysctl --system >/dev/null 2>&1 || rc=1
  sysctl_state_restore "$TCP_TUNING_STATE" || rc=1
  restore_live_qdisc "$TCP_QDISC_STATE" 1 || rc=1
  remove_initcwnd_managed 1 || rc=1

  echo ""
  if [ "$rc" -eq 0 ]; then
    echo -e "${G}TCP 优化已移除（部分参数重启后完全复位）${N}"
  else
    echo -e "${R}TCP 优化移除未完全成功，相关状态快照已尽量保留，请检查上方警告${N}"
  fi
  pause_screen
  return "$rc"
}

quic_tuning_abort(){
  local file_txn="$1" runtime_state="$2" state_created="${3:-0}" rc=0
  [ -n "$runtime_state" ] && sysctl_state_restore "$runtime_state" || {
    [ -z "$runtime_state" ] || rc=1
  }
  managed_file_transaction_rollback "$QUIC_TUNING_PATH" "$file_txn" || rc=1
  if [ "$rc" -eq 0 ]; then
    [ "$state_created" -eq 0 ] || rm -f -- "$QUIC_TUNING_STATE" || rc=1
    [ -z "$runtime_state" ] || rm -f -- "$runtime_state" 2>/dev/null || rc=1
  fi
  [ "$rc" -eq 0 ] || echo -e "${R}QUIC 调优回滚未完全成功，运行时/事务快照已尽量保留${N}" >&2
  return "$rc"
}

apply_quic_tuning(){
  local region="${1:-us-west}"
  local mem_tier="${2:-2g}"
  local region_label mem_label conntrack_max file_txn tmp_quic runtime_state=""
  local quic_state_created=0

  if ! require_root; then return 1; fi

  case "$region" in
    hk)      region_label="香港" ;;
    jp)      region_label="日本" ;;
    us-west) region_label="美西" ;;
    eu)      region_label="欧洲" ;;
    *)
      echo -e "${R}未知地区: $region${N}"
      return 1
      ;;
  esac

  case "$mem_tier" in
    512m) mem_label="512MB"; conntrack_max=65536 ;;
    1g)  mem_label="1GB";   conntrack_max=65536 ;;
    2g)  mem_label="2GB";   conntrack_max=131072 ;;
    4g)  mem_label="4GB";   conntrack_max=262144 ;;
    8g)  mem_label="8GB+";  conntrack_max=524288 ;;
    *)   mem_label="$mem_tier"; conntrack_max=131072 ;;
  esac

  file_txn=$(managed_file_transaction_begin "$QUIC_TUNING_PATH" 'Managed by Leyili|leyili-quic-profile') || return 1
  runtime_state=$(mktemp "${TMPDIR:-/tmp}/leyili-quic-runtime.XXXXXX") || {
    managed_file_transaction_rollback "$QUIC_TUNING_PATH" "$file_txn" || :
    return 1
  }
  rm -f -- "$runtime_state"
  sysctl_state_capture "$runtime_state" \
    net.netfilter.nf_conntrack_max \
    net.netfilter.nf_conntrack_udp_timeout \
    net.netfilter.nf_conntrack_udp_timeout_stream || {
      quic_tuning_abort "$file_txn" "$runtime_state" 0 || :
      return 1
    }
  if [ ! -f "$QUIC_TUNING_STATE" ]; then
    cp -a -- "$runtime_state" "$QUIC_TUNING_STATE" || {
      managed_file_transaction_rollback "$QUIC_TUNING_PATH" "$file_txn"
      rm -f -- "$runtime_state"
      return 1
    }
    quic_state_created=1
  fi

  echo ""
  echo -e "${Y}==> 写入 ${region_label}/${mem_label} QUIC/UDP 参数优化配置 (仅 conntrack)...${N}"

  tmp_quic=$(mktemp "${QUIC_TUNING_PATH}.tmp.XXXXXX") || {
    quic_tuning_abort "$file_txn" "$runtime_state" "$quic_state_created" || :
    return 1
  }
  if ! cat > "$tmp_quic" <<EOF
# Managed by Leyili
# leyili-quic-profile: region=${region} mem_tier=${mem_tier}
# 由 leyili.sh QUIC/UDP 协议优化生成 (${region_label} / ${mem_label})
# 用户偏好：Reality TCP 主用、UDP 仅备用 → 本文件不写 net.core.* 通用键，
# 避免字典序在后覆盖 TCP 调优。QUIC/UDP socket 缓冲沿用 99-proxy-optimized
# 设置的 net.core.rmem_max / wmem_max；如出现 sing-box "failed to sufficiently
# increase receive buffer size" 警告，再考虑单独提升 TCP 那份的 rmem_max。
# 不跑 TUIC / Hysteria2 时无需此文件，可在菜单 "移除 QUIC 调优" 删除

# --- conntrack（按内存档限制，避免小内存机器被固定 1M 条目拖垮）---
# 容器/LXC 内可能写不进去，sysctl -p 失败时由上层提示
net.netfilter.nf_conntrack_max = ${conntrack_max}
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
EOF
  then
    rm -f -- "$tmp_quic"
    quic_tuning_abort "$file_txn" "$runtime_state" "$quic_state_created" || :
    return 1
  fi

  if ! chmod 600 "$tmp_quic" 2>/dev/null \
     || ! mv -f -- "$tmp_quic" "$QUIC_TUNING_PATH"; then
    rm -f -- "$tmp_quic"
    quic_tuning_abort "$file_txn" "$runtime_state" "$quic_state_created" || :
    return 1
  fi

  echo -e "${Y}==> 应用 sysctl 配置...${N}"
  if ! sysctl -p "$QUIC_TUNING_PATH" 2>/dev/null; then
    echo -e "${R}conntrack 参数未能完整应用，已恢复应用前状态${N}"
    quic_tuning_abort "$file_txn" "$runtime_state" "$quic_state_created" || :
    return 1
  fi

  rm -f -- "$runtime_state"
  managed_file_transaction_commit "$file_txn"

  return 0
}

remove_quic_tuning(){
  local confirm="" rc=0

  if ! require_root; then
    return 1
  fi

  if [ ! -f "$QUIC_TUNING_PATH" ]; then
    echo ""
    echo -e "${Y}未检测到 QUIC 优化配置，无需移除${N}"
    pause_screen
    return 0
  fi
  if ! grep -Eq 'Managed by Leyili|leyili-quic-profile' "$QUIC_TUNING_PATH" 2>/dev/null \
     && [ ! -e "${QUIC_TUNING_PATH}.leyili-original" ] \
     && [ ! -f "$QUIC_TUNING_STATE" ]; then
    echo -e "${R}${QUIC_TUNING_PATH} 不是脚本托管文件，拒绝删除。${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${Y}==> 即将移除 ${C}$QUIC_TUNING_PATH${N}${Y}，并通过 sysctl --system 复位参数${N}"
  read -p "  确认继续？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  managed_file_restore "$QUIC_TUNING_PATH" || rc=1
  sysctl --system >/dev/null 2>&1 || rc=1
  sysctl_state_restore "$QUIC_TUNING_STATE" || rc=1

  echo ""
  if [ "$rc" -eq 0 ]; then
    echo -e "${G}QUIC 优化已移除（UDP 缓冲区将回落至 99-proxy-optimized.conf 或内核默认值）${N}"
  else
    echo -e "${R}QUIC 优化移除未完全成功，状态快照已尽量保留，请检查上方警告${N}"
  fi
  pause_screen
  return "$rc"
}

apply_quic_optimization(){
  local region="$1"
  local mem_tier="$2"
  local region_label mem_label

  if ! require_root; then return 1; fi

  case "$region" in
    hk)      region_label="香港" ;;
    jp)      region_label="日本" ;;
    us-west) region_label="美西" ;;
    eu)      region_label="欧洲" ;;
    *)
      echo -e "${R}未知地区: $region${N}"
      pause_screen
      return 1
      ;;
  esac

  case "$mem_tier" in
    512m) mem_label="512MB" ;;
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

  if ! apply_quic_tuning "$region" "$mem_tier"; then
    echo -e "${R}QUIC 调优失败，已中止${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${G}✓ QUIC/UDP 协议优化完成${N}"
  echo -e "  地区        : ${C}$region_label${N}"
  echo -e "  内存档位    : ${C}$mem_label${N}"
  echo -e "  说明        : ${C}仅写 conntrack，net.core.* 沿用 TCP 调优${N}"
  echo -e "  配置文件    : ${C}$QUIC_TUNING_PATH${N}"
  echo ""
  echo -e "  ${D}提示：调优生效后建议重启 sing-box 让 TUIC/HY2 重新分配缓冲区${N}"
  echo -e "  ${D}      systemctl restart sing-box${N}"
  pause_screen
}

initcwnd_apply_rollback(){
  local route_line="$1" service_name="$2" helper_txn="$3" service_txn="$4"
  local was_enabled="$5" was_active="$6" state_created="$7" stop_service="${8:-0}"
  local rc=0

  if [ "$stop_service" = "1" ] \
     && { systemctl is-active --quiet "$service_name" 2>/dev/null \
          || systemctl is-enabled --quiet "$service_name" 2>/dev/null; }; then
    systemctl disable --now "$service_name" >/dev/null 2>&1 || rc=1
  fi
  if [ -n "$route_line" ]; then
    # shellcheck disable=SC2086
    ip route replace $route_line >/dev/null 2>&1 || rc=1
  fi
  managed_file_transaction_rollback "$INITCWND_HELPER_PATH" "$helper_txn" || rc=1
  managed_file_transaction_rollback "$INITCWND_SERVICE_PATH" "$service_txn" || rc=1
  if [ "$stop_service" = "1" ]; then
    systemctl daemon-reload >/dev/null 2>&1 || rc=1
    if [ "$was_enabled" -eq 1 ]; then systemctl enable "$service_name" >/dev/null 2>&1 || rc=1; fi
    if [ "$was_active" -eq 1 ]; then systemctl start "$service_name" >/dev/null 2>&1 || rc=1; fi
  fi
  if [ "$state_created" -eq 1 ] && [ "$rc" -eq 0 ]; then
    rm -f -- "$INITCWND_STATE_PATH" || rc=1
  fi
  [ "$rc" -eq 0 ] || echo -e "${R}initcwnd 回滚未完全成功，状态文件/事务快照已保留，请立即检查路由与服务${N}" >&2
  return "$rc"
}

apply_initcwnd_optimization(){
  local route_line route_spec current_route service_name
  local initcwnd_value="${1:-$INITCWND_VALUE}"
  local quiet="${2:-0}"
  local service_txn helper_txn tmp_service tmp_helper
  local was_active=0 was_enabled=0 state_created=0

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

  case "$initcwnd_value" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$initcwnd_value" -lt 2 ] || [ "$initcwnd_value" -gt 128 ]; then
    echo -e "${R}initcwnd 必须在 2-128 之间${N}"
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
  service_name=$(basename "$INITCWND_SERVICE_PATH")
  systemctl is-active --quiet "$service_name" 2>/dev/null && was_active=1
  systemctl is-enabled --quiet "$service_name" 2>/dev/null && was_enabled=1

  ensure_leyili_state_dir || return 1
  if [ ! -f "$INITCWND_STATE_PATH" ]; then
    {
      printf 'original_active=%s\n' "$was_active"
      printf 'original_enabled=%s\n' "$was_enabled"
    } > "$INITCWND_STATE_PATH" || return 1
    chmod 600 "$INITCWND_STATE_PATH" 2>/dev/null \
      || { rm -f -- "$INITCWND_STATE_PATH"; return 1; }
    state_created=1
  fi

  service_txn=$(managed_file_transaction_begin "$INITCWND_SERVICE_PATH" 'Managed by Leyili|Description=Set TCP initcwnd/initrwnd') || return 1
  helper_txn=$(managed_file_transaction_begin "$INITCWND_HELPER_PATH" 'Managed by Leyili') || {
    if managed_file_transaction_rollback "$INITCWND_SERVICE_PATH" "$service_txn"; then
      [ "$state_created" -eq 1 ] && rm -f -- "$INITCWND_STATE_PATH"
    fi
    return 1
  }

  echo -e "${Y}==> 当前默认路由:${N} ${C}$route_line${N}"
  echo -e "${Y}==> 应用 initcwnd/initrwnd ${initcwnd_value}...${N}"
  if ! ip route replace $route_spec initcwnd $initcwnd_value initrwnd $initcwnd_value; then
    echo -e "${R}默认路由优化失败，请检查路由权限或当前网络环境${N}"
    [ "$quiet" != "1" ] && pause_screen
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  fi

  echo -e "${Y}==> 写入动态路由 helper 与 systemd 持久化服务...${N}"
  if ! mkdir -p "$(dirname -- "$INITCWND_HELPER_PATH")"; then
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  fi
  tmp_helper=$(mktemp "${INITCWND_HELPER_PATH}.tmp.XXXXXX") || {
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  }
  if ! cat > "$tmp_helper" <<'EOF'
#!/bin/bash
# Managed by Leyili. 每次启动读取当前默认路由，避免固化旧网关/网卡。
set -euo pipefail
value="${1:?missing initcwnd value}"
ip_bin=$(command -v ip)
route_line=$($ip_bin route show default | head -n 1)
[ -n "$route_line" ]
route_spec=$(printf '%s\n' "$route_line" | awk '{
  sep=""
  for (i = 1; i <= NF; i++) {
    if ($i == "initcwnd" || $i == "initrwnd") { i++; next }
    printf "%s%s", sep, $i
    sep=" "
  }
}')
# shellcheck disable=SC2086
$ip_bin route replace $route_spec initcwnd "$value" initrwnd "$value"
EOF
  then
    rm -f -- "$tmp_helper"
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  fi
  if ! chmod 755 "$tmp_helper" \
     || ! mv -f -- "$tmp_helper" "$INITCWND_HELPER_PATH"; then
    rm -f -- "$tmp_helper"
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  fi

  tmp_service=$(mktemp "${INITCWND_SERVICE_PATH}.tmp.XXXXXX") || {
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  }
  if ! cat > "$tmp_service" << EOF
# Managed by Leyili
[Unit]
Description=Set TCP initcwnd/initrwnd
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INITCWND_HELPER_PATH $initcwnd_value
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  then
    rm -f -- "$tmp_service"
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  fi
  if ! chmod 644 "$tmp_service" 2>/dev/null \
     || ! mv -f -- "$tmp_service" "$INITCWND_SERVICE_PATH"; then
    rm -f -- "$tmp_service"
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  fi

  if ! systemctl daemon-reload \
     || ! systemctl enable --now "$service_name"; then
    if initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
         "$was_enabled" "$was_active" "$state_created" 1; then
      echo -e "${R}initcwnd 持久化服务启用失败，已恢复原文件、路由与服务状态${N}"
    else
      echo -e "${R}initcwnd 持久化服务启用失败，且回滚未完全成功${N}"
    fi
    [ "$quiet" != "1" ] && pause_screen
    return 1
  fi

  current_route=$(ip route show default 2>/dev/null | head -1)
  if ! printf '%s\n' "$current_route" | grep -Eq "(^| )initcwnd ${initcwnd_value}( |$)"; then
    if initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
         "$was_enabled" "$was_active" "$state_created" 1; then
      echo -e "${R}initcwnd 健康检查失败，已恢复原状态${N}"
    else
      echo -e "${R}initcwnd 健康检查失败，且回滚未完全成功${N}"
    fi
    return 1
  fi

  managed_file_transaction_commit "$helper_txn"
  managed_file_transaction_commit "$service_txn"

  if [ "$quiet" = "1" ]; then
    return 0
  fi

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

remove_initcwnd_managed(){
  local quiet="${1:-0}" service_name
  local route_line route_spec
  local original_active=0 original_enabled=0 managed=0 rc=0

  service_name=$(basename "$INITCWND_SERVICE_PATH")
  if grep -Fq 'Managed by Leyili' "$INITCWND_SERVICE_PATH" 2>/dev/null \
     || [ -e "${INITCWND_SERVICE_PATH}.leyili-original" ] \
     || [ -f "$INITCWND_STATE_PATH" ]; then
    managed=1
  fi
  [ "$managed" -eq 1 ] || return 0

  original_active=$(awk -F= '$1 == "original_active" {print $2; exit}' "$INITCWND_STATE_PATH" 2>/dev/null)
  original_enabled=$(awk -F= '$1 == "original_enabled" {print $2; exit}' "$INITCWND_STATE_PATH" 2>/dev/null)
  if systemctl is-active --quiet "$service_name" 2>/dev/null \
     || systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
    systemctl disable --now "$service_name" >/dev/null 2>&1 || rc=1
  fi
  managed_file_restore "$INITCWND_SERVICE_PATH" || rc=1
  managed_file_restore "$INITCWND_HELPER_PATH" || rc=1
  systemctl daemon-reload >/dev/null 2>&1 || rc=1

  if [ "$original_enabled" = "1" ]; then systemctl enable "$service_name" >/dev/null 2>&1 || rc=1; fi
  if [ "$original_active" = "1" ]; then systemctl start "$service_name" >/dev/null 2>&1 || rc=1; fi

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
      ip route replace $route_spec >/dev/null 2>&1 || rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    rm -f -- "$INITCWND_STATE_PATH" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    [ "$quiet" = "1" ] || echo -e "  ${G}initcwnd 优化已移除${N}"
  else
    echo -e "${R}initcwnd 移除/恢复未完全成功，状态文件已保留：${INITCWND_STATE_PATH}${N}" >&2
  fi
  return "$rc"
}

remove_initcwnd_optimization(){
  local confirm=""

  if ! require_root; then return 1; fi
  if ! grep -Fq 'Managed by Leyili' "$INITCWND_SERVICE_PATH" 2>/dev/null \
     && [ ! -e "${INITCWND_SERVICE_PATH}.leyili-original" ] \
     && [ ! -f "$INITCWND_STATE_PATH" ]; then
    echo ""
    echo -e "${Y}未检测到脚本管理的 initcwnd 服务，无需移除${N}"
    pause_screen
    return 0
  fi

  echo ""
  read -p "  确认移除 initcwnd 持久化服务并恢复原文件/当前路由？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  if ! remove_initcwnd_managed 0; then
    pause_screen
    return 1
  fi

  echo ""
  pause_screen
}

apply_network_optimization(){
  local mem_tier="$1"
  local buffer_max="${2:-}"   # 向导按实测 BDP 算出，透传给 apply_tcp_tuning
  local rtt_ms="${3:-}"
  local bw_mbps="${4:-}"
  local initcwnd_value=32
  local mem_label
  local notsent_lowat fin_timeout
  local live_cc live_iface live_qdisc
  local rollback_rc=0

  if ! require_root; then return 1; fi

  case "$mem_tier" in
    512m) mem_label="512MB" ;;
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

  if ! apply_tcp_tuning "$mem_tier" "$buffer_max" "$rtt_ms" "$bw_mbps"; then
    echo -e "${R}TCP 调优失败，已中止${N}"
    pause_screen
    return 1
  fi

  if ! apply_initcwnd_optimization "$initcwnd_value" 1; then
    managed_file_restore "$TCP_TUNING_PATH" || rollback_rc=1
    sysctl --system >/dev/null 2>&1 || rollback_rc=1
    sysctl_state_restore "$TCP_TUNING_STATE" || rollback_rc=1
    restore_live_qdisc "$TCP_QDISC_STATE" 1 || rollback_rc=1
    if [ "$rollback_rc" -eq 0 ]; then
      echo -e "${R}initcwnd 优化失败，TCP 调优也已回滚，避免留下半套配置${N}"
    else
      echo -e "${R}initcwnd 优化失败，且 TCP 调优回滚未完全成功，请检查上方快照提示${N}"
    fi
    pause_screen
    return 1
  fi

  # 展示用：回读实际落盘 / 生效的值（buffer_max 可能被 apply 侧归一化）
  buffer_max=$(awk -F'=' '/^[[:space:]]*net\.core\.rmem_max/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$TCP_TUNING_PATH" 2>/dev/null)
  notsent_lowat=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo "?")
  fin_timeout=$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null || echo "?")

  echo ""
  echo -e "${G}✓ 网络优化完成${N}"
  echo -e "  模式        : ${C}智能调参（自动实测）${N}"
  echo -e "  内存档位    : ${C}$mem_label${N}"
  if [ -n "$rtt_ms" ]; then
    echo -e "  实测 RTT    : ${C}${rtt_ms} ms${N}"
    echo -e "  有效带宽    : ${C}${bw_mbps} Mbps${N}"
  fi
  if [ -n "$buffer_max" ] && [ "$buffer_max" -gt 0 ] 2>/dev/null; then
    echo -e "  rmem/wmem   : ${C}$((buffer_max / 1024 / 1024))M${N}"
  fi
  echo -e "  notsent     : ${C}$notsent_lowat${N}"
  echo -e "  fin_timeout : ${C}$fin_timeout${N}"
  echo -e "  initcwnd    : ${C}$initcwnd_value${N}"
  # 显示「实际生效」的拥塞算法与网卡 qdisc：cc 读运行值可反映 BBR 是否降级；
  # qdisc 读 tc 实际值（而非全局 default_qdisc），避免误报 fq 已生效
  live_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  live_iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
  if [ -n "$live_iface" ] && command -v tc >/dev/null 2>&1; then
    live_qdisc=$(tc qdisc show dev "$live_iface" 2>/dev/null | awk 'NR==1 {print $2; exit}')
  fi
  [ -z "$live_qdisc" ] && live_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
  echo -e "  qdisc / cc  : ${C}${live_qdisc} / ${live_cc}${N}${live_iface:+ ${D}(${live_iface})${N}}"
  echo -e "  配置文件    : ${C}$TCP_TUNING_PATH${N}"
  pause_screen
}

show_network_optimization_menu(){
  local choice

  while true; do
    render_section_header "网络优化"
    render_menu_item 1 "TCP 智能调优 + initcwnd ${D}(实测 RTT × 带宽算 BDP)${N}"
    render_menu_item 2 "QUIC/UDP 协议优化"
    render_menu_item 3 "移除 TCP 调优"
    render_menu_item 4 "移除 QUIC 调优"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case "$choice" in
      1) show_tcp_auto_tune_wizard ;;
      2) show_quic_optimization_picker ;;
      3) remove_tcp_tuning ;;
      4) remove_quic_tuning ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

# ── 智能 TCP 调参（自动实测）──────────────────────────────────────────
# TCP 调优的唯一入口（固定地区档 2026-08 移除，全部机器统一走实测）。
# 思路：RTT 用两条独立通道实测取小 —— ss 直接读「本机与目标 IP 现有 TCP 连接」
# 的内核统计（用户正 SSH 在线，天然有一条到家里的活连接，ICMP 被禁也能测）；
# ping 5 发取 min 作交叉验证。带宽让用户报套餐值（VPS 侧无法单方面测出家宽
# 下行）。BDP = 带宽 × RTT，buffer_max ≈ 3×BDP 留 BBR 探测与晚高峰余量，再按
# 内存档封顶防 OOM，最后经 apply_network_optimization 落盘。

# 读内核对「与目标 IP 的既有 TCP 连接」的实测 RTT（输出整数 ms；空 = 无数据）。
# 优先 minrtt（连接存续期最小值，最接近纯传播时延），退化用 rtt: 平滑均值；
# 多条连接取最小。
_tcp_autotune_rtt_from_ss(){
  local ip="$1" dst
  case "$ip" in
    *:*) dst="[$ip]" ;;   # ss 过滤器里 IPv6 字面量需要方括号
    *)   dst="$ip" ;;
  esac
  ss -tin state established dst "$dst" 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^rtt:[0-9.]+\//) {            # 锚定 ^rtt: 避免误吞 minrtt:
          split($i, a, /[:\/]/); v = a[2] + 0
          if (v > 0 && (avg == 0 || v < avg)) avg = v
        } else if ($i ~ /^minrtt:[0-9.]+$/) {
          split($i, a, ":"); v = a[2] + 0
          if (v > 0 && (mn == 0 || v < mn)) mn = v
        }
      }
    }
    END {
      v = (mn > 0) ? mn : avg
      if (v > 0) { if (v < 1) v = 1; printf "%d", v + 0.5 }
    }'
}

# ping 5 发取 min（输出整数 ms；空 = 不通/被禁）。按 " = " 切汇总行，
# 同时兼容 iputils（rtt min/avg/max/mdev）与 busybox（round-trip min/avg/max）。
_tcp_autotune_rtt_from_ping(){
  local ip="$1" out=""
  case "$ip" in
    *:*)
      out=$(LC_ALL=C ping -6 -n -c 5 -i 0.2 -W 1 "$ip" 2>/dev/null) \
        || out=$(LC_ALL=C ping6 -n -c 5 -i 0.2 -W 1 "$ip" 2>/dev/null) || true
      ;;
    *)
      out=$(LC_ALL=C ping -n -c 5 -i 0.2 -W 1 "$ip" 2>/dev/null) || true
      ;;
  esac
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | awk '
    /min\/avg/ {
      split($0, p, " = "); split(p[2], v, "/")
      m = v[1] + 0
      if (m > 0) { if (m < 1) m = 1; printf "%d", m + 0.5 }
      exit
    }'
}

# 按 MemTotal 自动定内存档（仅用于 buffer 封顶，不再让用户手选）。
# 阈值给标称容量的实报值留裕量：512M/1G/2G/4G 实报约 480/970/1950/3900 MB。
_tcp_autotune_mem_tier(){
  local kb mb
  kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
  case "$kb" in ''|*[!0-9]*) echo "2g"; return ;; esac
  mb=$((kb / 1024))
  if [ "$mb" -lt 768 ]; then echo "512m"
  elif [ "$mb" -lt 1500 ]; then echo "1g"
  elif [ "$mb" -lt 3000 ]; then echo "2g"
  elif [ "$mb" -lt 6000 ]; then echo "4g"
  else echo "8g"
  fi
}

# 每档 buffer 上限 = 旧版固定地区档（hk/jp/us-west/eu 查表，已移除）在该内存档
# 曾交付过的最大值，保证自动模式的产出不超出以往实机验证过的范围
_tcp_autotune_ceiling(){
  case "$1" in
    512m) echo 8388608   ;;
    1g)   echo 16777216  ;;
    2g)   echo 33554432  ;;
    4g)   echo 50331648  ;;
    *)    echo 67108864  ;;
  esac
}

# BDP → buffer_max：3×BDP，向上取整到 2MiB，floor 8M，按内存档封顶。
# 乘数取 3：BBR cwnd 上限 = 2×BDP（cwnd_gain），内核 sndbuf 自动扩容又按
# 「在途 ×2 + skb 开销」定目标，2×BDP 会让 ProbeBW 阶段被发送缓冲卡住；
# 且晚高峰入国方向排队会让实际 RTT 高于实测 minRTT，3× 把这些余量都包进来。
# floor 8M 来自 100M 跨洋线的历史实测（原 us-west-100m 档：8M 比 4M/16M 稳）。
_tcp_autotune_calc_buffer(){
  local rtt_ms="$1" bw_mbps="$2" mem_tier="$3"
  local raw buf ceiling
  raw=$((bw_mbps * 125 * rtt_ms * 3))
  buf=$(( (raw + 2097151) / 2097152 * 2097152 ))
  [ "$buf" -lt 8388608 ] && buf=8388608
  ceiling=$(_tcp_autotune_ceiling "$mem_tier")
  [ "$buf" -gt "$ceiling" ] && buf="$ceiling"
  echo "$buf"
}

# 目标 IP 结构校验。此前只查字符集，"deadbeef" 这类纯 hex 串会被当合法 IP
# 收下，双路实测必然落空后又把用户绕去手动输 RTT，提示有误导。
# IPv4 严格校验点分四段 0-255；IPv6 宽松校验（字符集、"::" 至多一个、
# 组数 ≤8、单组 ≤4 个 hex、v4 结尾段递归校验）——拦明显垃圾即可，
# 可达性最终由 ss/ping 实测判定。
_tcp_autotune_valid_ip(){
  local ip="$1" seg
  case "$ip" in
    *:*)
      case "$ip" in
        *[!0-9a-fA-F:.]*|*:::*) return 1 ;;
      esac
      case "$ip" in
        *[0-9a-fA-F]*) : ;;
        *) return 1 ;;   # 只有冒号（":" / "::"），不是可测目标
      esac
      seg="${ip#*::}"
      case "$seg" in *::*) return 1 ;; esac
      local IFS=:
      # shellcheck disable=SC2086
      set -- $ip
      [ $# -le 8 ] || return 1
      for seg in "$@"; do
        case "$seg" in
          '') ;;                                             # "::" 压缩产生的空组
          *.*) _tcp_autotune_valid_ip "$seg" || return 1 ;;  # v4 结尾段
          ?????*) return 1 ;;                                # 单组超过 4 个 hex
        esac
      done
      return 0
      ;;
    *)
      case "$ip" in ''|*[!0-9.]*|.*|*.|*..*) return 1 ;; esac
      local IFS=.
      # shellcheck disable=SC2086
      set -- $ip
      [ $# -eq 4 ] || return 1
      for seg in "$@"; do
        case "$seg" in ''|????*) return 1 ;; esac
        [ "$((10#$seg))" -le 255 ] || return 1
      done
      return 0
      ;;
  esac
}

show_tcp_auto_tune_wizard(){
  local ssh_ip="" target_ip="" input
  local rtt_ss="" rtt_ping="" rtt_ms="" rtt_src=""
  local down_bw="" vps_bw="" eff_bw=""
  local mem_tier mem_label bdp buffer_max bdp_mb buf_mb ceiling_mb

  if ! require_root; then return 1; fi

  render_section_header "智能 TCP 调参（自动实测）"
  echo -e "  ${D}实测到你本地的 RTT + 你输入的带宽 → 按 BDP 自动计算缓冲区上限${N}"
  echo ""

  # --- 1/4 目标 IP：默认取当前 SSH 客户端 ---
  [ -n "${SSH_CLIENT:-}" ] && ssh_ip=$(printf '%s' "$SSH_CLIENT" | awk '{print $1}')
  while true; do
    if [ -n "$ssh_ip" ]; then
      echo -e "  ${B}检测到 SSH 客户端 IP${N} : ${C}${ssh_ip}${N}"
      read -p "  测速目标 IP (回车用上面的，可手输 IPv4/IPv6，0 返回): " input
      [ -z "$input" ] && input="$ssh_ip"
    else
      echo -e "  ${Y}未检测到 SSH 客户端 IP（可能经 su / 串口控制台进入）${N}"
      read -p "  请输入测速目标 IP (IPv4/IPv6，0 返回): " input
    fi
    [ "$input" = "0" ] && return 1
    if ! _tcp_autotune_valid_ip "$input"; then
      echo -e "  ${R}不是合法的 IPv4/IPv6 地址${N}"
      continue
    fi
    case "$input" in
      *:*) is_private_ipv6 "$input" && echo -e "  ${Y}⚠ 这是内网/链路本地地址，测出的 RTT 不能代表公网路径${N}" ;;
      *)   is_private_ipv4 "$input" && echo -e "  ${Y}⚠ 这是内网地址，如需测到你家里请用本地网络的公网出口 IP${N}" ;;
    esac
    target_ip="$input"
    break
  done

  # --- 2/4 双路实测 RTT ---
  echo ""
  echo -e "${Y}==> 测量到 ${target_ip} 的 RTT (ss 读现有连接 + ping 5 发)...${N}"
  rtt_ss=$(_tcp_autotune_rtt_from_ss "$target_ip")
  rtt_ping=$(_tcp_autotune_rtt_from_ping "$target_ip")
  [ -n "$rtt_ss" ]   && echo -e "  ${D}ss   (内核连接实测) : ${rtt_ss} ms${N}"
  [ -n "$rtt_ping" ] && echo -e "  ${D}ping (5 发取 min)   : ${rtt_ping} ms${N}"

  # 两条通道都只会高估、不会低估传播 RTT，故取可用结果的最小值
  if [ -n "$rtt_ss" ] && [ -n "$rtt_ping" ]; then
    if [ "$rtt_ping" -le "$rtt_ss" ]; then
      rtt_ms="$rtt_ping"; rtt_src="ping·双路取小"
    else
      rtt_ms="$rtt_ss"; rtt_src="ss(tcp)·双路取小"
    fi
  elif [ -n "$rtt_ss" ]; then
    rtt_ms="$rtt_ss"; rtt_src="ss(tcp)"
  elif [ -n "$rtt_ping" ]; then
    rtt_ms="$rtt_ping"; rtt_src="ping"
  else
    echo -e "  ${Y}两种方式都未测到（该 IP 无现存连接且 ICMP 不通）${N}"
    while true; do
      read -p "  请手动输入到该 IP 的 RTT (ms，1-2000，0 返回): " input
      [ "$input" = "0" ] && return 1
      case "$input" in
        ''|*[!0-9]*|???????*) echo -e "  ${R}必须为正整数${N}"; continue ;;
      esac
      input=$((10#$input))   # 强制十进制，防 "090" 这类前导零被按八进制解析
      if [ "$input" -lt 1 ] || [ "$input" -gt 2000 ]; then
        echo -e "  ${R}范围 1-2000 ms${N}"
        continue
      fi
      rtt_ms="$input"; rtt_src="手动输入"
      break
    done
  fi
  if [ "$rtt_ms" -gt 800 ]; then
    echo -e "  ${Y}⚠ RTT 超过 800ms，疑似测量异常，请确认目标 IP 是否正确${N}"
  fi

  # --- 3/4 带宽（家宽下行 VPS 侧测不了，报套餐值即可）---
  echo ""
  while true; do
    read -p "  你本地的下载带宽 (Mbps，如 300 / 500 / 1000): " down_bw
    case "$down_bw" in
      ''|*[!0-9]*|???????*) echo -e "  ${R}必须为正整数 (1-10000)${N}"; continue ;;
    esac
    down_bw=$((10#$down_bw))   # 强制十进制，防 "0300" 这类前导零被按八进制解析
    if [ "$down_bw" -lt 1 ] || [ "$down_bw" -gt 10000 ]; then
      echo -e "  ${R}范围 1-10000 Mbps${N}"
      continue
    fi
    break
  done
  # 共享带宽/超售机型：按「端口峰值」填或直接回车 —— buffer_max 是自动调节的
  # 上限、不预占内存，高峰跌速交给 BBR 自己收敛；反之填了高峰实测的低值，
  # 会把离峰时段的吞吐也一起钉死。只有硬限速套餐（如 100M）才填限速值。
  echo -e "  ${D}提示：共享带宽/不确定就直接回车按峰值算，只有硬限速套餐才填限速值${N}"
  while true; do
    read -p "  VPS 出口带宽 (Mbps，回车默认 1000): " vps_bw
    vps_bw="${vps_bw:-1000}"
    case "$vps_bw" in
      *[!0-9]*|???????*) echo -e "  ${R}必须为正整数 (1-40000)${N}"; continue ;;
    esac
    vps_bw=$((10#$vps_bw))
    if [ "$vps_bw" -lt 1 ] || [ "$vps_bw" -gt 40000 ]; then
      echo -e "  ${R}范围 1-40000 Mbps${N}"
      continue
    fi
    break
  done
  eff_bw=$(( down_bw < vps_bw ? down_bw : vps_bw ))

  # --- 4/4 计算 + 确认 ---
  mem_tier=$(_tcp_autotune_mem_tier)
  case "$mem_tier" in
    512m) mem_label="512MB" ;;
    1g)   mem_label="1GB"   ;;
    2g)   mem_label="2GB"   ;;
    4g)   mem_label="4GB"   ;;
    *)    mem_label="8GB+"  ;;
  esac
  bdp=$((eff_bw * 125 * rtt_ms))
  buffer_max=$(_tcp_autotune_calc_buffer "$rtt_ms" "$eff_bw" "$mem_tier")
  bdp_mb=$(awk -v b="$bdp" 'BEGIN { printf "%.1f", b / 1048576 }')
  buf_mb=$((buffer_max / 1024 / 1024))
  ceiling_mb=$(( $(_tcp_autotune_ceiling "$mem_tier") / 1024 / 1024 ))

  echo ""
  echo -e "  ${B}${C}推荐方案${N}"
  render_divider
  echo -e "  实测 RTT    : ${C}${rtt_ms} ms${N} ${D}(${rtt_src})${N}"
  echo -e "  有效带宽    : ${C}${eff_bw} Mbps${N} ${D}(本地 ${down_bw} / VPS ${vps_bw} 取小)${N}"
  echo -e "  BDP         : ${C}${bdp_mb} MB${N} ${D}(带宽 × RTT)${N}"
  echo -e "  buffer_max  : ${C}${buf_mb}M${N} ${D}(≈3×BDP 留探测余量; floor 8M, ${mem_label} 档顶 ${ceiling_mb}M)${N}"
  echo -e "  rmem/wmem   : ${C}16384 524288 ${buffer_max}${N}"
  echo -e "  拥塞 / 队列 : ${C}BBR + fq${N} ${D}(内核不支持时自动降级 cubic / fq_codel)${N}"
  echo -e "  initcwnd    : ${C}32${N}"
  echo -e "  内存档位    : ${C}${mem_label}${N} ${D}(自动检测，仅用于封顶)${N}"
  render_divider
  read -p "  确认应用以上参数? (y/N): " input
  if [ "$input" != "y" ] && [ "$input" != "Y" ]; then
    echo -e "  ${Y}已取消，未做任何修改${N}"
    sleep 1
    return 1
  fi

  if apply_network_optimization "$mem_tier" "$buffer_max" "$rtt_ms" "$eff_bw"; then
    return 0
  fi
  return 1
}

show_quic_optimization_picker(){
  local region region_choice region_label mem_choice mem_tier
  local detected_mem_kb detected_mem_gb

  while true; do
    render_section_header "QUIC/UDP 协议优化"
    echo -e "  ${D}面向 TUIC / Hysteria2，调整 UDP 缓冲区与 conntrack${N}"
    echo ""
    render_menu_item 1 "香港   ${D}(亚洲低延迟)${N}"
    render_menu_item 2 "日本   ${D}(亚洲低延迟)${N}"
    render_menu_item 3 "美西   ${D}(跨太平洋高 BDP)${N}"
    render_menu_item 4 "欧洲   ${D}(欧亚高延迟)${N}"
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

      render_menu_item 1 "512 MB"
      render_menu_item 2 "1 GB"
      render_menu_item 3 "2 GB"
      render_menu_item 4 "4 GB"
      render_menu_item 5 "8 GB+"
      render_menu_item 0 "返回选择地区"
      render_divider
      read -p "  请选择内存档位: " mem_choice

      case "$mem_choice" in
        1) mem_tier="512m" ;;
        2) mem_tier="1g" ;;
        3) mem_tier="2g" ;;
        4) mem_tier="4g" ;;
        5) mem_tier="8g" ;;
        0) break ;;
        *) notify_invalid_choice; continue ;;
      esac

      apply_quic_optimization "$region" "$mem_tier"
      return
    done
  done
}

show_network_optimization_status(){
  local route_line initcwnd_current initrwnd_current initcwnd_enabled initcwnd_active
  local tcp_qdisc tcp_cc tcp_fastopen tcp_notsent tcp_fin_timeout tcp_keepalive
  local tcp_config_status tcp_qdisc_live status_iface

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

  # 默认网卡上「实际生效」的 qdisc（区别于全局 default_qdisc；后者改了不动现有网卡）
  status_iface=$(printf '%s\n' "$route_line" | awk '/^default/ {print $5; exit}')
  if [ -n "$status_iface" ] && command -v tc >/dev/null 2>&1; then
    tcp_qdisc_live=$(tc qdisc show dev "$status_iface" 2>/dev/null | awk 'NR==1 {print $2; exit}')
  fi

  local tcp_profile_text="未配置"
  local tcp_rmem_max
  tcp_rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "")
  if [ -f "$TCP_TUNING_PATH" ]; then
    tcp_config_status="已存在"
    local profile_line region mem_tier region_label="" mem_label=""
    profile_line=$(awk '/^# leyili-profile:/ { print; exit }' "$TCP_TUNING_PATH" 2>/dev/null)
    if [ -n "$profile_line" ]; then
      region=$(printf '%s\n' "$profile_line" | sed -n 's/.*region=\([a-z0-9-]\+\).*/\1/p')
      mem_tier=$(printf '%s\n' "$profile_line" | sed -n 's/.*mem_tier=\([a-z0-9]\+\).*/\1/p')
      case "$region" in
        # hk/jp/us-west/eu 为旧版固定地区档的存量 marker，仅保留展示映射
        hk)      region_label="香港" ;;
        jp)      region_label="日本" ;;
        us-west) region_label="美西" ;;
        us-west-100m) region_label="美西 100M" ;;
        eu)      region_label="欧洲" ;;
        custom)  region_label="自动实测" ;;
      esac
      case "$mem_tier" in
        512m) mem_label="512MB" ;;
        1g) mem_label="1GB"  ;;
        2g) mem_label="2GB"  ;;
        4g) mem_label="4GB"  ;;
        8g) mem_label="8GB+" ;;
      esac
      if [ -n "$region_label" ] && [ -n "$mem_label" ]; then
        tcp_profile_text="${region_label} / ${mem_label}"
        # custom 档补充展示当时的实测输入（marker 里的 rtt=/bw= 附加 token）
        if [ "$region" = "custom" ]; then
          local rtt_tok bw_tok
          rtt_tok=$(printf '%s\n' "$profile_line" | sed -n 's/.*rtt=\([0-9]\+\).*/\1/p')
          bw_tok=$(printf '%s\n' "$profile_line" | sed -n 's/.*bw=\([0-9]\+\).*/\1/p')
          [ -n "$rtt_tok" ] && tcp_profile_text="${tcp_profile_text} (${rtt_tok}ms × ${bw_tok:-?}Mbps)"
        fi
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
  echo -e "  qdisc     : ${C}$tcp_qdisc${N}${tcp_qdisc_live:+ ${D}(${status_iface} 实际: ${tcp_qdisc_live})${N}}"
  echo -e "  拥塞算法  : ${C}$tcp_cc${N}$([ "$tcp_cc" = "bbr" ] && printf ' %b(BBR)%b' "$G" "$N")"
  echo -e "  Fast Open : ${C}$tcp_fastopen${N}"
  echo -e "  notsent   : ${C}$tcp_notsent${N}"
  echo -e "  fin_timeout : ${C}$tcp_fin_timeout${N}"
  echo -e "  keepalive : ${C}$tcp_keepalive${N}"
  echo ""

  local quic_config_status quic_profile_text="未配置"
  local quic_rmem_max
  local conntrack_max conntrack_count
  if [ -f "$QUIC_TUNING_PATH" ]; then
    quic_config_status="已存在"
    local quic_profile_line region mem_tier region_label="" mem_label=""
    quic_profile_line=$(awk '/^# leyili-quic-profile:/ { print; exit }' "$QUIC_TUNING_PATH" 2>/dev/null)
    if [ -n "$quic_profile_line" ]; then
      region=$(printf '%s\n' "$quic_profile_line" | sed -n 's/.*region=\([a-z0-9-]\+\).*/\1/p')
      mem_tier=$(printf '%s\n' "$quic_profile_line" | sed -n 's/.*mem_tier=\([a-z0-9]\+\).*/\1/p')
      case "$region" in
        hk)      region_label="香港" ;;
        jp)      region_label="日本" ;;
        us-west) region_label="美西" ;;
        eu)      region_label="欧洲" ;;
      esac
      case "$mem_tier" in
        512m) mem_label="512MB" ;;
        1g) mem_label="1GB"  ;;
        2g) mem_label="2GB"  ;;
        4g) mem_label="4GB"  ;;
        8g) mem_label="8GB+" ;;
      esac
      if [ -n "$region_label" ] && [ -n "$mem_label" ]; then
        quic_profile_text="${region_label} / ${mem_label}"
      fi
    fi
  else
    quic_config_status="未写入"
  fi

  quic_rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "")

  echo -e "  ${B}QUIC/UDP 参数状态${N}"
  echo -e "  配置文件  : ${C}$quic_config_status${N} (${QUIC_TUNING_PATH})"
  echo -e "  配置档位  : ${C}$quic_profile_text${N}"
  if [ -n "$quic_rmem_max" ] && [ "$quic_rmem_max" -gt 0 ] 2>/dev/null; then
    echo -e "  rmem_max  : ${C}$((quic_rmem_max / 1024 / 1024))M${N} ${D}(共用 TCP)${N}"
  fi
  if [ -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
    conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "?")
    conntrack_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "?")
    echo -e "  conntrack : ${C}${conntrack_count}${N} / ${C}${conntrack_max}${N}"
  fi
  pause_screen
}

swap_transaction_rollback(){
  local created_this_run="${1:-0}"
  local fstab_backup="${2:-}"
  local sysctl_txn="${3:-}"
  local rc=0

  if [ -n "$sysctl_txn" ] && [ -d "$sysctl_txn" ]; then
    managed_file_transaction_rollback "$SWAP_SYSCTL_PATH" "$sysctl_txn" || rc=1
  fi
  if [ -n "$fstab_backup" ] && [ -f "$fstab_backup" ]; then
    restore_file_snapshot "$fstab_backup" /etc/fstab || rc=1
  fi
  if [ "$created_this_run" = "1" ]; then
    if awk -v p="$SWAPFILE_PATH" 'NR > 1 && $1 == p {found=1} END {exit !found}' /proc/swaps 2>/dev/null; then
      swapoff "$SWAPFILE_PATH" >/dev/null 2>&1 || rc=1
    fi
    if ! awk -v p="$SWAPFILE_PATH" 'NR > 1 && $1 == p {found=1} END {exit !found}' /proc/swaps 2>/dev/null; then
      rm -f -- "$SWAPFILE_PATH" || rc=1
    else
      rc=1
    fi
  fi
  sysctl --system >/dev/null 2>&1 || rc=1
  if [ "$rc" -eq 0 ]; then
    [ -z "$fstab_backup" ] || rm -f -- "$fstab_backup" || rc=1
  else
    echo -e "${R}SWAP 事务回滚未完全成功${fstab_backup:+，fstab 快照保留在 ${fstab_backup}}${N}" >&2
  fi
  return "$rc"
}

configure_swap(){
  local swap_size_mb="${1:-2048}"
  local size_label="${2:-${swap_size_mb} MB}"
  local swap_active="false"
  local state_created_file=0 adopted=0 fstab_added=0 created_this_run=0
  local swap_tmp="" fstab_backup="" fstab_tmp="" sysctl_txn="" tmp_sysctl="" tmp_state="" adopt_choice=""

  if ! require_root; then return 1; fi

  echo ""
  echo -e "  ${B}${C}当前内存 / SWAP 状态${N}"
  free -h
  echo ""

  if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAPFILE_PATH"; then
    swap_active="true"
  fi

  if [ "$swap_active" = "true" ]; then
    if [ ! -f "$SWAP_STATE_PATH" ]; then
      echo -e "${Y}检测到已启用但无法确认由本脚本创建的 ${SWAPFILE_PATH}${N}"
      echo -e "${D}默认不会接管、格式化或删除该文件。输入 ADOPT 仅接管 swappiness；文件与既有 fstab 行仍归用户。${N}"
      read -p "  输入 ADOPT 接管设置，其它输入取消: " adopt_choice
      if [ "$adopt_choice" != "ADOPT" ]; then
        echo -e "  已取消，现有 SWAP 未作任何修改"
        pause_screen
        return 0
      fi
      adopted=1
    else
      adopted=$(awk -F= '$1 == "adopted" {print $2; exit}' "$SWAP_STATE_PATH" 2>/dev/null)
      state_created_file=$(awk -F= '$1 == "created_file" {print $2; exit}' "$SWAP_STATE_PATH" 2>/dev/null)
      fstab_added=$(awk -F= '$1 == "fstab_added" {print $2; exit}' "$SWAP_STATE_PATH" 2>/dev/null)
    fi
    echo -e "${Y}==> ${SWAPFILE_PATH} 已启用，不重新格式化${N}"
  else
    if [ -f "$SWAPFILE_PATH" ]; then
      echo -e "${R}检测到未启用的现有文件 ${SWAPFILE_PATH}，拒绝执行 mkswap（会破坏原内容）。${N}"
      echo -e "${Y}请先人工确认并移动/删除该文件，再重新运行。${N}"
      pause_screen
      return 1
    fi

    echo -e "${Y}==> 创建 ${size_label} SWAP 文件...${N}"
    swap_tmp=$(mktemp "${SWAPFILE_PATH}.leyili.XXXXXX") || return 1
    if ! fallocate -l "${swap_size_mb}M" "$swap_tmp"; then
      echo -e "${Y}==> fallocate 失败，改用 dd 创建...${N}"
      if ! dd if=/dev/zero of="$swap_tmp" bs=1M count="$swap_size_mb" status=progress; then
        rm -f -- "$swap_tmp"
        echo -e "${R}SWAP 文件创建失败${N}"
        pause_screen
        return 1
      fi
    fi
    chmod 600 "$swap_tmp" || { rm -f -- "$swap_tmp"; return 1; }
    if ! mkswap "$swap_tmp" >/dev/null \
       || ! mv -f -- "$swap_tmp" "$SWAPFILE_PATH" \
       || ! swapon "$SWAPFILE_PATH"; then
      rm -f -- "$swap_tmp" "$SWAPFILE_PATH"
      echo -e "${R}SWAP 格式化或启用失败，已删除本次新建文件${N}"
      pause_screen
      return 1
    fi
    created_this_run=1
    state_created_file=1
  fi

  fstab_backup=$(mktemp "${TMPDIR:-/tmp}/leyili-fstab.XXXXXX") || {
    swap_transaction_rollback "$created_this_run" "" ""
    return 1
  }
  cp -a -- /etc/fstab "$fstab_backup" || {
    swap_transaction_rollback "$created_this_run" "$fstab_backup" ""
    return 1
  }
  if ! awk -v p="$SWAPFILE_PATH" '$1 == p && $3 == "swap" {found=1} END {exit !found}' /etc/fstab; then
    fstab_tmp=$(mktemp /etc/fstab.tmp.XXXXXX) || {
      swap_transaction_rollback "$created_this_run" "$fstab_backup" ""
      return 1
    }
    if ! { cat /etc/fstab; printf '\n# Managed by Leyili SWAP\n%s none swap sw 0 0\n' "$SWAPFILE_PATH"; } > "$fstab_tmp"; then
      rm -f -- "$fstab_tmp"
      swap_transaction_rollback "$created_this_run" "$fstab_backup" ""
      return 1
    fi
    if ! chmod --reference=/etc/fstab "$fstab_tmp" 2>/dev/null \
       || ! chown --reference=/etc/fstab "$fstab_tmp" 2>/dev/null \
       || ! mv -f -- "$fstab_tmp" /etc/fstab; then
      rm -f -- "$fstab_tmp"
      swap_transaction_rollback "$created_this_run" "$fstab_backup" ""
      return 1
    fi
    fstab_added=1
  fi

  echo -e "${Y}==> 设置 swappiness = ${SWAPPINESS_VALUE}...${N}"
  sysctl_txn=$(managed_file_transaction_begin "$SWAP_SYSCTL_PATH" 'Managed by Leyili') || {
    swap_transaction_rollback "$created_this_run" "$fstab_backup" ""
    return 1
  }
  tmp_sysctl=$(mktemp "${SWAP_SYSCTL_PATH}.tmp.XXXXXX") || {
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    return 1
  }
  if ! cat > "$tmp_sysctl" << EOF
# Managed by Leyili
vm.swappiness = $SWAPPINESS_VALUE
EOF
  then
    rm -f -- "$tmp_sysctl"
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    return 1
  fi
  if ! chmod 600 "$tmp_sysctl" 2>/dev/null \
     || ! mv -f -- "$tmp_sysctl" "$SWAP_SYSCTL_PATH"; then
    rm -f -- "$tmp_sysctl"
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    return 1
  fi

  if ! sysctl -p "$SWAP_SYSCTL_PATH" 2>/dev/null; then
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    echo -e "${R}swappiness 应用失败，已恢复 fstab、sysctl 与本次新建 SWAP${N}"
    pause_screen
    return 1
  fi

  if ! ensure_leyili_state_dir; then
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    return 1
  fi
  tmp_state=$(mktemp "${SWAP_STATE_PATH}.tmp.XXXXXX") || {
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    return 1
  }
  {
    printf 'path=%s\n' "$SWAPFILE_PATH"
    printf 'created_file=%s\n' "${state_created_file:-0}"
    printf 'adopted=%s\n' "${adopted:-0}"
    printf 'fstab_added=%s\n' "${fstab_added:-0}"
  } > "$tmp_state" || {
    rm -f -- "$tmp_state"
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    return 1
  }
  if ! chmod 600 "$tmp_state" 2>/dev/null \
     || ! mv -f -- "$tmp_state" "$SWAP_STATE_PATH"; then
    rm -f -- "$tmp_state"
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    return 1
  fi
  managed_file_transaction_commit "$sysctl_txn"
  rm -f -- "$fstab_backup"

  echo ""
  echo -e "${G}SWAP 配置完成${N}"
  free -h
  echo ""
  swapon --show
  pause_screen
}

# SWAP 档位选择器：根据用户内存档位推荐 SWAP 大小
show_swap_picker(){
  local detected_mem_kb detected_mem_mb detected_mem_label
  local suggested=2 swap_size_mb=0 size_label="" choice
  local existing_size_mb=""

  if ! require_root; then return 1; fi

  detected_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
  if [ -n "$detected_mem_kb" ] && [ "$detected_mem_kb" -gt 0 ]; then
    detected_mem_mb=$((detected_mem_kb / 1024))
    if   [ "$detected_mem_mb" -lt 768 ];  then suggested=1; detected_mem_label="${detected_mem_mb} MB ${D}(≤ 512 MB 档)${N}"
    elif [ "$detected_mem_mb" -lt 1500 ]; then suggested=2; detected_mem_label="${detected_mem_mb} MB ${D}(1 GB 档)${N}"
    else                                       suggested=3; detected_mem_label="${detected_mem_mb} MB ${D}(≥ 2 GB 档)${N}"
    fi
  else
    detected_mem_label="未知"
  fi

  render_section_header "添加 SWAP"
  echo -e "  ${B}当前检测到内存${N} : ${C}${detected_mem_label}${N}"
  echo ""
  free -h
  echo ""

  if [ -f "$SWAPFILE_PATH" ]; then
    existing_size_mb=$(stat -c%s "$SWAPFILE_PATH" 2>/dev/null)
    if [ -n "$existing_size_mb" ] && [ "$existing_size_mb" -gt 0 ] 2>/dev/null; then
      existing_size_mb=$((existing_size_mb / 1024 / 1024))
      if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAPFILE_PATH"; then
        echo -e "  ${Y}⚠ 检测到已启用 ${SWAPFILE_PATH}（约 ${existing_size_mb} MB），不会重新格式化${N}"
        [ -f "$SWAP_STATE_PATH" ] || echo -e "  ${D}  因缺少所有权记录，后续仅在输入 ADOPT 后接管 swappiness，不会接管或删除文件${N}"
      else
        echo -e "  ${R}⚠ 检测到未启用的现有 ${SWAPFILE_PATH}（约 ${existing_size_mb} MB），脚本会拒绝 mkswap 以保护原内容${N}"
      fi
      echo ""
    fi
  fi

  echo -e "  ${B}选择内存档位（脚本按档位推荐 SWAP 大小）：${N}"
  render_menu_item 1 "≤ 512 MB    ${D}→ SWAP 1 GB    (小机器跑 apt/编译必需)${N}"
  render_menu_item 2 "1 GB        ${D}→ SWAP 2 GB    (主流入门套餐推荐)${N}"
  render_menu_item 3 "≥ 2 GB      ${D}→ SWAP 2 GB    (跑代理/转发足够)${N}"
  render_menu_item 4 "自定义大小（MB）"
  render_menu_item 0 "返回"
  render_divider
  read -p "  请选择 (默认 ${suggested}): " choice
  choice="${choice:-$suggested}"

  case "$choice" in
    1) swap_size_mb=1024; size_label="1 GB" ;;
    2) swap_size_mb=2048; size_label="2 GB" ;;
    3) swap_size_mb=2048; size_label="2 GB" ;;
    4)
      while true; do
        read -p "  自定义大小（MB，512-8192）: " swap_size_mb
        case "$swap_size_mb" in
          ''|*[!0-9]*)
            echo -e "${R}必须为正整数${N}"
            continue
            ;;
        esac
        if [ "$swap_size_mb" -lt 512 ] || [ "$swap_size_mb" -gt 8192 ]; then
          echo -e "${R}范围必须在 512-8192 MB 之间${N}"
          continue
        fi
        if [ "$swap_size_mb" -ge 1024 ] && [ $((swap_size_mb % 1024)) -eq 0 ]; then
          size_label="$((swap_size_mb / 1024)) GB"
        else
          size_label="${swap_size_mb} MB"
        fi
        break
      done
      ;;
    0) return 0 ;;
    *) notify_invalid_choice; return 0 ;;
  esac

  configure_swap "$swap_size_mb" "$size_label"
}

remove_swap(){
  local confirm=""
  local tmp_file="" fstab_backup="" sysctl_txn=""
  local created_file=0 adopted=0 fstab_added=0
  local was_active=0 rollback_ok=1 rc=0

  if ! require_root; then
    return 1
  fi

  if [ ! -f "$SWAP_STATE_PATH" ]; then
    echo ""
    echo -e "${Y}没有找到 ${SWAP_STATE_PATH}，无法证明 ${SWAPFILE_PATH} 归脚本所有。${N}"
    echo -e "${D}为避免删除用户文件，本菜单不会关闭、删除或改写现有 SWAP/fstab。${N}"
    pause_screen
    return 0
  fi

  created_file=$(awk -F= '$1 == "created_file" {print $2; exit}' "$SWAP_STATE_PATH" 2>/dev/null)
  adopted=$(awk -F= '$1 == "adopted" {print $2; exit}' "$SWAP_STATE_PATH" 2>/dev/null)
  fstab_added=$(awk -F= '$1 == "fstab_added" {print $2; exit}' "$SWAP_STATE_PATH" 2>/dev/null)

  echo ""
  if [ "$created_file" = "1" ]; then
    echo -e "${Y}==> 即将关闭并删除脚本创建的 ${C}$SWAPFILE_PATH${N}${Y}，并恢复原 swappiness 文件${N}"
  else
    echo -e "${Y}==> 此 SWAP 为显式接管项：仅恢复脚本设置，保留文件、启用状态和既有 fstab 行${N}"
  fi
  read -p "  确认继续？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  fstab_backup=$(mktemp "${TMPDIR:-/tmp}/leyili-fstab-remove.XXXXXX") || return 1
  cp -a -- /etc/fstab "$fstab_backup" || { rm -f -- "$fstab_backup"; return 1; }
  if [ "$fstab_added" = "1" ]; then
    tmp_file=$(mktemp /etc/fstab.tmp.XXXXXX) || { rm -f -- "$fstab_backup"; return 1; }
    if ! awk -v p="$SWAPFILE_PATH" '
      /^# Managed by Leyili SWAP$/ {pending=1; next}
      pending && $1 == p && $3 == "swap" {pending=0; next}
      {if (pending) {print "# Managed by Leyili SWAP"; pending=0} print}
      END {if (pending) print "# Managed by Leyili SWAP"}
    ' /etc/fstab > "$tmp_file"; then
      rm -f -- "$tmp_file" "$fstab_backup"
      return 1
    fi
    if ! chmod --reference=/etc/fstab "$tmp_file" 2>/dev/null \
       || ! chown --reference=/etc/fstab "$tmp_file" 2>/dev/null \
       || ! mv -f -- "$tmp_file" /etc/fstab; then
      rm -f -- "$tmp_file" "$fstab_backup"
      return 1
    fi
  fi

  sysctl_txn=$(managed_file_transaction_begin "$SWAP_SYSCTL_PATH" 'Managed by Leyili') || {
    if restore_file_snapshot "$fstab_backup" /etc/fstab; then
      rm -f -- "$fstab_backup"
    else
      echo -e "${R}SWAP sysctl 快照失败，且 fstab 恢复失败；快照保留在 ${fstab_backup}${N}" >&2
    fi
    return 1
  }
  if ! managed_file_restore "$SWAP_SYSCTL_PATH" \
     || ! sysctl --system >/dev/null 2>&1; then
    managed_file_transaction_rollback "$SWAP_SYSCTL_PATH" "$sysctl_txn" || rollback_ok=0
    restore_file_snapshot "$fstab_backup" /etc/fstab || rollback_ok=0
    [ "$rollback_ok" -eq 1 ] && rm -f -- "$fstab_backup"
    echo -e "${R}恢复原 swappiness 失败，已尝试回滚，SWAP 文件未删除${N}"
    pause_screen
    return 1
  fi

  if [ "$created_file" = "1" ] \
     && awk -v p="$SWAPFILE_PATH" 'NR > 1 && $1 == p {found=1} END {exit !found}' /proc/swaps 2>/dev/null; then
    was_active=1
    echo -e "${Y}==> 关闭 SWAP...${N}"
    if ! swapoff "$SWAPFILE_PATH"; then
      managed_file_transaction_rollback "$SWAP_SYSCTL_PATH" "$sysctl_txn" || rollback_ok=0
      restore_file_snapshot "$fstab_backup" /etc/fstab || rollback_ok=0
      [ "$rollback_ok" -eq 1 ] && rm -f -- "$fstab_backup"
      echo -e "${R}关闭 SWAP 失败，已尝试恢复 fstab 与 swappiness，文件未删除${N}"
      pause_screen
      return 1
    fi
  fi

  if [ "$created_file" = "1" ] && [ -f "$SWAPFILE_PATH" ]; then
    if ! rm -f -- "$SWAPFILE_PATH"; then
      [ "$was_active" -eq 1 ] && swapon "$SWAPFILE_PATH" >/dev/null 2>&1 || {
        [ "$was_active" -eq 0 ] || rollback_ok=0
      }
      managed_file_transaction_rollback "$SWAP_SYSCTL_PATH" "$sysctl_txn" || rollback_ok=0
      restore_file_snapshot "$fstab_backup" /etc/fstab || rollback_ok=0
      [ "$rollback_ok" -eq 1 ] && rm -f -- "$fstab_backup"
      echo -e "${R}删除 SWAP 文件失败，已尝试恢复启用状态、fstab 与 swappiness${N}"
      pause_screen
      return 1
    fi
  fi

  managed_file_transaction_commit "$sysctl_txn" || rc=1
  rm -f -- "$SWAP_STATE_PATH" || rc=1
  rm -f -- "$fstab_backup" || rc=1

  echo ""
  if [ "$rc" -ne 0 ]; then
    echo -e "${R}SWAP 已按确认执行，但状态/临时文件清理不完整，请检查 ${SWAP_STATE_PATH}${N}"
  elif [ "$created_file" = "1" ]; then
    echo -e "${G}脚本创建的 SWAP 已删除（不可恢复）；原 swappiness 文件已恢复${N}"
  else
    echo -e "${G}脚本的 SWAP 设置已移除；接管前的 SWAP 文件与挂载保持不变${N}"
  fi
  free -h
  pause_screen
  return "$rc"
}

# ─── 脚本自更新 / 配置管理 ────────────────────────────
# ═══ source: 41-update-self.sh ═══
get_latest_singbox_version(){
  local ver=""
  ver=$(curl -fsSL --max-time 5 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name":[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)
  printf '%s' "$ver"
}

# 带缓存的「最新稳定版」查询：首页每次刷新都会调用它，不能每次都打 GitHub。
# 命中且未过期 → 直接读缓存；过期/不存在 → 拉一次并写回。
# 拉取失败时写空内容作为「负缓存」，短 TTL 内不再重试，避免每次刷新都卡 5 秒。
get_latest_singbox_version_cached(){
  local now mtime age content ttl ver cache_ok=0 tmp_cache
  if [ ! -L "$LEYILI_CACHE_DIR" ] && ! [ -L "$SINGBOX_LATEST_CACHE" ]; then
    if [ "$(id -u)" -eq 0 ]; then
      ensure_private_dir "$LEYILI_CACHE_DIR" 700 >/dev/null 2>&1 && cache_ok=1
    elif [ -d "$LEYILI_CACHE_DIR" ] && [ -r "$SINGBOX_LATEST_CACHE" ]; then
      cache_ok=1
    fi
  fi
  if [ "$cache_ok" = "1" ] && [ -f "$SINGBOX_LATEST_CACHE" ]; then
    now=$(date +%s 2>/dev/null || echo 0)
    mtime=$(stat -c %Y "$SINGBOX_LATEST_CACHE" 2>/dev/null || echo 0)
    age=$((now - mtime))
    content=$(cat "$SINGBOX_LATEST_CACHE" 2>/dev/null)
    if [ -n "$content" ]; then ttl="$SINGBOX_LATEST_TTL"; else ttl="$SINGBOX_LATEST_NEG_TTL"; fi
    if [ "$now" -gt 0 ] && [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; then
      printf '%s' "$content"
      return 0
    fi
  fi
  ver=$(get_latest_singbox_version)
  if [ "$cache_ok" = "1" ] && [ -w "$LEYILI_CACHE_DIR" ]; then
    tmp_cache=$(mktemp "${SINGBOX_LATEST_CACHE}.tmp.XXXXXX" 2>/dev/null || true)
    if [ -n "$tmp_cache" ]; then
      printf '%s' "$ver" > "$tmp_cache" 2>/dev/null \
        && chmod 600 "$tmp_cache" 2>/dev/null \
        && mv -f -- "$tmp_cache" "$SINGBOX_LATEST_CACHE" 2>/dev/null \
        || rm -f -- "$tmp_cache"
    fi
  fi
  printf '%s' "$ver"
}

# 版本严格小于比较：$1 < $2 返回 0（真）。依赖 sort -V（coreutils，Debian/Ubuntu 自带）。
_singbox_ver_lt(){
  [ "$1" = "$2" ] && return 1
  local first
  first=$(printf '%s\n%s\n' "$1" "$2" | sort -V 2>/dev/null | head -1)
  [ "$first" = "$1" ]
}

get_current_singbox_version(){
  if ! command -v sing-box >/dev/null 2>&1; then
    printf '%s' ""
    return
  fi
  sing-box version 2>/dev/null | head -1 | awk '{print $3}'
}

# 当前 sing-box 主.次版本是否 >= 给定阈值
# 用法：sb_version_at_least 1.12  → 0 表示满足，1 表示不满足
sb_version_at_least(){
  local required="$1" cur major_req minor_req major_cur minor_cur
  cur=$(get_current_singbox_version)
  [ -n "$cur" ] || return 1
  cur="${cur#v}"
  major_req=$(printf '%s' "$required" | cut -d. -f1)
  minor_req=$(printf '%s' "$required" | cut -d. -f2)
  major_cur=$(printf '%s' "$cur" | cut -d. -f1)
  minor_cur=$(printf '%s' "$cur" | cut -d. -f2)
  case "$major_cur" in ''|*[!0-9]*) return 1 ;; esac
  case "$minor_cur" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$major_cur" -gt "$major_req" ]; then return 0; fi
  if [ "$major_cur" -eq "$major_req" ] && [ "$minor_cur" -ge "$minor_req" ]; then return 0; fi
  return 1
}

update_self_script(){
  local tmp_file=""
  local confirm=""
  local actual_sha="" size="" stage_file="" backup_path=""

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
  trap 'rm -f "$tmp_file"' RETURN
  case "$SELF_INSTALL_URL" in
    https://*) ;;
    *)
      echo -e "${R}自更新地址必须使用 HTTPS：$SELF_INSTALL_URL${N}"
      pause_screen
      return 1
      ;;
  esac
  if ! curl --proto '=https' --tlsv1.2 -fsSL --max-time 30 "$SELF_INSTALL_URL" -o "$tmp_file"; then
    rm -f "$tmp_file"
    echo -e "${R}下载失败，请检查网络或 SELF_INSTALL_URL${N}"
    pause_screen
    return 1
  fi

  size=$(wc -c < "$tmp_file" 2>/dev/null | tr -d ' ')
  if ! leyili_payload_size_ok "$tmp_file"; then
    echo -e "${R}新脚本大小异常（${size:-未知} 字节），已放弃更新${N}"
    pause_screen
    return 1
  fi

  if ! leyili_payload_has_markers "$tmp_file"; then
    echo -e "${R}下载内容缺少 Leyili 脚本结构标记，已放弃更新${N}"
    pause_screen
    return 1
  fi

  if ! bash -n "$tmp_file"; then
    rm -f "$tmp_file"
    echo -e "${R}新脚本语法校验失败，已放弃更新${N}"
    pause_screen
    return 1
  fi

  actual_sha=$(sha256sum "$tmp_file" 2>/dev/null | awk '{print $1}')
  if [ -n "$SELF_INSTALL_SHA256" ]; then
    if [ "$(printf '%s' "$actual_sha" | tr 'A-F' 'a-f')" != "$(printf '%s' "$SELF_INSTALL_SHA256" | tr 'A-F' 'a-f')" ]; then
      echo -e "${R}新脚本 SHA-256 不匹配，已放弃更新${N}"
      echo -e "  预期: ${C}${SELF_INSTALL_SHA256}${N}"
      echo -e "  实际: ${C}${actual_sha:-无法计算}${N}"
      pause_screen
      return 1
    fi
  fi

  if [ -f "$SCRIPT_PATH" ] && cmp -s "$tmp_file" "$SCRIPT_PATH"; then
    rm -f "$tmp_file"
    echo -e "${G}当前已是最新版本${N}"
    pause_screen
    return 0
  fi

  echo -e "  来源: ${C}$SELF_INSTALL_URL${N}"
  echo -e "  SHA-256: ${C}${actual_sha:-无法计算}${N}"
  if [ -z "$SELF_INSTALL_SHA256" ]; then
    echo -e "  ${Y}未配置 SELF_INSTALL_SHA256，来源身份无法做固定哈希校验。${N}"
    read -p "  如已人工核对上方哈希，输入 UNVERIFIED 继续: " confirm
    if [ "$confirm" != "UNVERIFIED" ]; then
      echo -e "  已取消"
      sleep 1
      return 0
    fi
  else
    read -p "  哈希校验通过，确认覆盖 ${SCRIPT_PATH}？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo -e "  已取消"
      sleep 1
      return 0
    fi
  fi
  if [ -z "$confirm" ]; then
    rm -f "$tmp_file"
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  if [ -L "$SCRIPT_PATH" ]; then
    echo -e "${R}拒绝覆盖符号链接脚本入口：${SCRIPT_PATH}${N}"
    pause_screen
    return 1
  fi
  mkdir -p -- "$(dirname -- "$SCRIPT_PATH")" || return 1
  stage_file=$(mktemp "${SCRIPT_PATH}.new.XXXXXX") || return 1
  if ! install -m 0755 "$tmp_file" "$stage_file"; then
    rm -f -- "$stage_file"
    echo -e "${R}准备新脚本失败${N}"
    pause_screen
    return 1
  fi
  if [ -f "$SCRIPT_PATH" ]; then
    backup_path="${SCRIPT_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    if ! cp -a -- "$SCRIPT_PATH" "$backup_path"; then
      rm -f -- "$stage_file"
      echo -e "${R}旧脚本备份失败，已取消覆盖${N}"
      pause_screen
      return 1
    fi
    cleanup_old_backups "${SCRIPT_PATH}.bak.*" 3 \
      || echo -e "${Y}旧脚本备份轮转失败，新版本仍会继续安装${N}" >&2
  fi

  if ! mv -f -- "$stage_file" "$SCRIPT_PATH"; then
    rm -f -- "$stage_file"
    rm -f "$tmp_file"
    echo -e "${R}原子替换 $SCRIPT_PATH 失败，旧入口保持不变${N}"
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
  local txn="" rollback="" rollback_ok=1 editor_rc=0

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

  txn=$(config_transaction_begin manual-edit) || {
    echo -e "${R}配置事务快照失败${N}"
    pause_screen
    return 1
  }

  "$editor_bin" "$CONFIG_PATH" || editor_rc=$?
  if [ "$editor_rc" -ne 0 ]; then
    echo -e "${Y}编辑器退出码为 ${editor_rc}，继续以配置校验结果为准${N}"
  fi

  if ! sing-box check -c "$CONFIG_PATH"; then
    echo ""
    read -p "  配置校验失败，是否回滚到编辑前备份？(Y/n): " rollback
    if [ "$rollback" != "n" ] && [ "$rollback" != "N" ]; then
      config_transaction_rollback "$txn" || rollback_ok=0
      if [ "$rollback_ok" -eq 1 ]; then
        echo -e "${G}已回滚配置与服务状态${N}"
      else
        echo -e "${R}回滚未完全成功，请立即检查；事务快照已保留${N}"
      fi
    else
      config_transaction_commit "$txn"
      echo -e "${Y}已保留有问题的配置（备份：$backup_path）${N}"
    fi
    pause_screen
    return 1
  fi

  if ! systemctl restart sing-box; then
    config_transaction_rollback "$txn" || rollback_ok=0
    if [ "$rollback_ok" -eq 1 ]; then
      echo -e "${R}服务重启失败，已回滚配置与服务状态${N}"
    else
      echo -e "${R}服务重启失败，且回滚未完全成功，请立即检查 sing-box${N}"
    fi
    pause_screen
    return 1
  fi

  config_transaction_commit "$txn"

  cleanup_old_backups "${CONFIG_PATH}.bak.*" 5 \
    || echo -e "${Y}旧配置备份轮转失败，本次配置已正常生效${N}" >&2

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
  count=$((count + $(ls -1 "${CONFIG_PATH}".*.bak 2>/dev/null | wc -l)))
  count=$((count + $(ls -1 "${SSHD_CONFIG_PATH}".bak.* 2>/dev/null | wc -l)))
  count=$((count + $(ls -1 "${FAIL2BAN_JAIL_PATH}".bak.* 2>/dev/null | wc -l)))
  count=$((count + $(ls -1 "${SCRIPT_PATH}".bak.* 2>/dev/null | wc -l)))

  echo ""
  echo -e "  ${B}当前备份文件${N}"
  ls -1 "${CONFIG_PATH}".bak.* "${CONFIG_PATH}".*.bak \
        "${SSHD_CONFIG_PATH}".bak.* "${FAIL2BAN_JAIL_PATH}".bak.* \
        "${SCRIPT_PATH}".bak.* 2>/dev/null || true
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

  if ! cleanup_old_backups "${CONFIG_PATH}.bak.*" "$keep" \
     || ! cleanup_old_backups "${CONFIG_PATH}.*.bak" "$keep" \
     || ! cleanup_old_backups "${SSHD_CONFIG_PATH}.bak.*" "$keep" \
     || ! cleanup_old_backups "${FAIL2BAN_JAIL_PATH}.bak.*" "$keep" \
     || ! cleanup_old_backups "${SCRIPT_PATH}.bak.*" "$keep"; then
    echo -e "${R}部分备份删除失败，请检查文件权限${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${G}备份已清理${N}"
  pause_screen
}

# ─── 首次安装入口 ─────────────────────────────────────
# ═══ source: 42-net-bench.sh ═══
# ─── 本地链路测评（VPS ⇄ 家宽）────────────────────────
# 从 VPS 侧实测「到用户家庭宽带公网 IP」的链路质量：延迟/抖动/丢包（ping）、
# 逐跳丢包（mtr）、回程线路识别（nexttrace，带 ASN/运营商）、路径 MTU（DF 探测）、
# 带宽与 UDP 丢包（iperf3）。产出纯文本报告，整段复制给 AI 即可结合数据调参。
# 网上通用测速脚本测的都是「VPS → 三网测速节点」，测不到用户自家 IP —— 这是
# 本模块存在的原因。
NETBENCH_ENV_PATH="/etc/leyili/netbench.env"
NETBENCH_REPORT_PREFIX="/root/netbench-report"
NETBENCH_IPERF_PORT_DEFAULT="15201"
# 用带 -leyili 后缀的独立文件名：卸载时只删自己下载的，不动用户自装的 nexttrace
NETBENCH_NEXTTRACE_BIN="/usr/local/bin/nexttrace-leyili"
NETBENCH_NEXTTRACE_VERSION="v1.7.1"
NETBENCH_NEXTTRACE_BASE="https://github.com/nxtrace/NTrace-core/releases/download/${NETBENCH_NEXTTRACE_VERSION}"
NETBENCH_NEXTTRACE_SHA256_AMD64="1f4c559cbdf6f667a1a9e050567c9cf1fc11741e8cc1e50f5fdcaf2dbb247232"
NETBENCH_NEXTTRACE_SHA256_ARM64="9c2f1b79e7d0e37f59ebe685aec1d5c41fb8f3407f54e17b34656712eaa66fd9"
NETBENCH_NEXTTRACE_SHA256_ARMV7="1eb8be9394b2ac40a991d4fa3e651960e107bc8c6757a35c5f4720c0ab8eb71d"

# 追加一行纯文本到报告（报告不带 ANSI 色与缩进，方便整段复制给 AI）
_nb_report(){
  printf '%s\n' "$1" >> "$NB_REPORT"
}

_nb_section(){
  local title="$1"
  echo ""
  echo -e "  ${B}${C}› ${title}${N}"
  _nb_report ""
  _nb_report "══════════ ${title} ══════════"
}

# 剥掉 ANSI 颜色码（nexttrace 输出带色，落报告前清洗）
_nb_strip_ansi(){
  sed 's/\x1b\[[0-9;]*[mK]//g'
}

# 统一 v4/v6 ping 入口；现代 iputils 用 `ping -6`，极老系统回落 ping6
_nb_ping(){
  local ip="$1"; shift
  case "$ip" in
    *:*)
      LC_ALL=C ping -6 -n "$@" "$ip" 2>/dev/null \
        || { command -v ping6 >/dev/null 2>&1 && LC_ALL=C ping6 -n "$@" "$ip" 2>/dev/null; }
      ;;
    *)
      LC_ALL=C ping -n "$@" "$ip" 2>/dev/null
      ;;
  esac
}

# 从 ping 汇总输出提取丢包率（"2" / "0.5"；空 = 无汇总行）。
# head -1 兜底：ping -6 失败回落 ping6 时理论上可能出现两段汇总
_nb_parse_loss(){
  sed -n 's/.*[ ,]\([0-9.]*\)% packet loss.*/\1/p' | head -n 1
}

# 提取 rtt 汇总，输出空格分隔的 "min avg max mdev"。
# 兼容 iputils（rtt min/avg/max/mdev = a/b/c/d ms）与
# busybox（round-trip min/avg/max = a/b/c ms，无 mdev → 第 4 列为空）
_nb_parse_rtt(){
  awk '
    /min\/avg/ {
      split($0, p, " = "); split(p[2], v, "/")
      gsub(/ .*/, "", v[3]); gsub(/ .*/, "", v[4])
      printf "%s %s %s %s", v[1], v[2], v[3], v[4]
      exit
    }'
}

# ── 目标 IP 持久化（家宽 IP 多为动态，但短期内复用省得每次手输）──
_nb_load_target(){
  [ -r "$NETBENCH_ENV_PATH" ] || return 0
  awk -F= '$1 == "NETBENCH_TARGET_IP" { print $2; exit }' "$NETBENCH_ENV_PATH" 2>/dev/null
}

_nb_save_target(){
  local tmp
  ensure_private_dir "$(dirname -- "$NETBENCH_ENV_PATH")" 700 || return 1
  tmp=$(mktemp "${NETBENCH_ENV_PATH}.tmp.XXXXXX") || return 1
  if ! printf 'NETBENCH_TARGET_IP=%s\n' "$1" > "$tmp" \
     || ! chmod 600 "$tmp" \
     || ! mv -f -- "$tmp" "$NETBENCH_ENV_PATH"; then
    rm -f -- "$tmp"
    return 1
  fi
}

_nb_latest_report(){
  find "$(dirname "$NETBENCH_REPORT_PREFIX")" -maxdepth 1 -type f \
       -name "$(basename "$NETBENCH_REPORT_PREFIX")-*.txt" -printf '%T@\t%p\n' 2>/dev/null \
    | LC_ALL=C sort -rn | head -n 1 | cut -f2-
}

# ── 依赖：mtr + iperf3（apt）───────────────────────────
_nb_ensure_tools(){
  local missing=""
  command -v mtr >/dev/null 2>&1 || missing="mtr-tiny"
  command -v iperf3 >/dev/null 2>&1 || missing="${missing:+$missing }iperf3"
  [ -z "$missing" ] && return 0

  echo -e "${Y}==> 安装测评依赖: ${C}${missing}${N}"
  # iperf3 的 debconf 会问「是否作为守护进程启动」，noninteractive 默认 No（正确）
  # shellcheck disable=SC2086
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y $missing >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y $missing >/dev/null 2>&1; then
      echo -e "${Y}    依赖安装失败（${missing}），对应测试将自动跳过${N}"
      return 1
    fi
  fi
  return 0
}

# nexttrace：带 ASN/运营商/归属地的路由追踪，能直接看出回程走的是
# 163 / CN2 / 4837 / 9929 / CMIN2 哪条线 —— AI 判断线路质量的关键输入。
# 下载失败不致命，回落到只看 mtr 的 IP 段。
_nb_ensure_nexttrace(){
  local arch tmp expected_sha actual_sha
  command -v nexttrace >/dev/null 2>&1 && return 0

  case "$(uname -m)" in
    x86_64|amd64)  arch="amd64"; expected_sha="$NETBENCH_NEXTTRACE_SHA256_AMD64" ;;
    aarch64|arm64) arch="arm64"; expected_sha="$NETBENCH_NEXTTRACE_SHA256_ARM64" ;;
    armv7l)        arch="armv7"; expected_sha="$NETBENCH_NEXTTRACE_SHA256_ARMV7" ;;
    *)
      echo -e "${Y}    未适配的架构 $(uname -m)，跳过 nexttrace（仅用 mtr 看路由）${N}"
      return 1
      ;;
  esac

  if [ -x "$NETBENCH_NEXTTRACE_BIN" ]; then
    actual_sha=$(sha256sum "$NETBENCH_NEXTTRACE_BIN" 2>/dev/null | awk '{print $1}')
    if [ "$actual_sha" = "$expected_sha" ]; then
      return 0
    fi
    mv -f -- "$NETBENCH_NEXTTRACE_BIN" "${NETBENCH_NEXTTRACE_BIN}.rejected.$(date +%Y%m%d%H%M%S)" 2>/dev/null || return 1
    echo -e "${Y}    已隔离校验不通过的旧 nexttrace-leyili${N}"
  fi

  echo -e "${Y}==> 下载 nexttrace（回程线路识别，仅首次）...${N}"
  tmp=$(mktemp)
  if curl --proto '=https' --tlsv1.2 -fsSL --max-time 90 \
       "${NETBENCH_NEXTTRACE_BASE}/nexttrace_linux_${arch}" -o "$tmp"; then
    actual_sha=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')
    if [ "$actual_sha" = "$expected_sha" ] \
       && [ "$(dd if="$tmp" bs=1 skip=1 count=3 2>/dev/null)" = "ELF" ]; then
      if install -m 0755 "$tmp" "$NETBENCH_NEXTTRACE_BIN"; then
        rm -f -- "$tmp"
        echo -e "  ${D}nexttrace ${NETBENCH_NEXTTRACE_VERSION} SHA-256 校验通过${N}"
        return 0
      fi
    else
      echo -e "${Y}    nexttrace SHA-256 校验失败，拒绝执行${N}"
    fi
  fi
  rm -f -- "$tmp"
  echo -e "${Y}    nexttrace 下载失败，回程线路将只有 mtr 数据${N}"
  return 1
}

_nb_nexttrace_bin(){
  if command -v nexttrace >/dev/null 2>&1; then
    command -v nexttrace
  elif [ -x "$NETBENCH_NEXTTRACE_BIN" ]; then
    printf '%s' "$NETBENCH_NEXTTRACE_BIN"
  fi
}

# ── 报告头：VPS 基本信息 + 当前网络参数基线 ───────────
# 把「调参前的现状」一并写进报告，AI 不用追问就能给出增量修改建议
_nb_sysinfo(){
  local target="$1"
  local pretty kernel virt cores mem_mb vps4 vps6 iface mtu cc qdisc live_qdisc
  local rmax wmax trmem twmem notsent icwnd profile

  pretty=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}")
  kernel=$(uname -r 2>/dev/null || echo "?")
  virt=$(systemd-detect-virt 2>/dev/null || echo "unknown")
  cores=$(nproc 2>/dev/null || echo "?")
  mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
  vps4=$(detect_primary_ipv4)
  vps6=$(detect_primary_ipv6)
  iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
  [ -n "$iface" ] && mtu=$(cat "/sys/class/net/${iface}/mtu" 2>/dev/null)
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  if [ -n "$iface" ] && command -v tc >/dev/null 2>&1; then
    live_qdisc=$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1 {print $2}')
  fi
  rmax=$(sysctl -n net.core.rmem_max 2>/dev/null)
  wmax=$(sysctl -n net.core.wmem_max 2>/dev/null)
  trmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)
  twmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)
  notsent=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)
  icwnd=$(ip route show default 2>/dev/null \
          | awk '{for (i = 1; i <= NF; i++) if ($i == "initcwnd") {print $(i+1); exit}}')
  profile=$(awk '/^# leyili-profile:/ {sub(/^# leyili-profile: */, ""); print; exit}' "$TCP_TUNING_PATH" 2>/dev/null)

  _nb_report "【给 AI 的说明】"
  _nb_report "本报告由 ${APP_NAME} 脚本在 VPS 上自动实测生成，方向为「VPS → 家庭宽带公网 IP」。"
  _nb_report "请基于以下数据分析链路质量（延迟/抖动/丢包/回程线路/MTU/带宽），并给出"
  _nb_report "Linux 内核 sysctl 与代理协议（sing-box: Reality/Hysteria2/TUIC 等）的调参建议。"
  _nb_report ""
  _nb_report "── VPS 基本信息 ──"
  _nb_report "测试时间       : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  _nb_report "目标(家宽) IP  : ${target}"
  _nb_report "VPS IPv4/IPv6  : ${vps4:-无} / ${vps6:-无}"
  _nb_report "系统 / 内核    : ${pretty} / ${kernel}"
  _nb_report "虚拟化/CPU/内存: ${virt} / ${cores}核 / ${mem_mb:-?}MB"
  _nb_report "默认网卡       : ${iface:-?} (本机 MTU ${mtu:-?})"
  _nb_report ""
  _nb_report "── VPS 当前网络参数（调参前基线）──"
  _nb_report "拥塞控制/qdisc : ${cc:-?} / ${qdisc:-?} (网卡实际: ${live_qdisc:-?})"
  _nb_report "rmem_max/wmem_max : ${rmax:-?} / ${wmax:-?}"
  _nb_report "tcp_rmem       : ${trmem:-?}"
  _nb_report "tcp_wmem       : ${twmem:-?}"
  _nb_report "notsent_lowat/initcwnd : ${notsent:-?} / ${icwnd:-未设置}"
  _nb_report "已应用调优档   : ${profile:-无（未跑过脚本 TCP 调优）}"

  echo -e "  ${D}已记录 VPS 基线参数（内核/拥塞算法/缓冲区等）${N}"
}

# ── 延迟/抖动/丢包：小包 100 发 + 大包 1400B 对照 ─────
# 大包丢包明显高于小包 = 路径存在 MTU/分片或大包限速问题，对隧道类协议致命。
# 返回 1 表示目标完全不响应 ICMP（后续 MTU 探测应跳过）
_nb_ping_suite(){
  local ip="$1"
  local out big stats rtt_parts big_txt

  NB_LOSS=""; NB_RTT_MIN=""; NB_RTT_AVG=""; NB_RTT_MAX=""; NB_RTT_MDEV=""; NB_BIG_LOSS=""

  _nb_section "延迟 / 抖动 / 丢包（ICMP ping）"
  echo -e "  ${D}小包 56B × 100 发，间隔 0.2s（约 25 秒）...${N}"
  out=$(_nb_ping "$ip" -c 100 -i 0.2 -W 1 -s 56)
  stats=$(printf '%s\n' "$out" | sed -n '/ping statistics/,$p')

  if [ -z "$stats" ]; then
    echo -e "  ${R}ping 无输出（目标不可达或系统缺 ping 工具）${N}"
    _nb_report "小包 56B × 100 发: 测试失败（ping 无输出）"
    return 1
  fi

  printf '%s\n' "$stats" | sed 's/^/  /'
  _nb_report "◆ 小包 56B × 100 发, 间隔 0.2s:"
  printf '%s\n' "$stats" >> "$NB_REPORT"

  NB_LOSS=$(printf '%s\n' "$out" | _nb_parse_loss)
  rtt_parts=$(printf '%s\n' "$out" | _nb_parse_rtt)
  [ -n "$rtt_parts" ] && read -r NB_RTT_MIN NB_RTT_AVG NB_RTT_MAX NB_RTT_MDEV <<< "$rtt_parts"

  case "$NB_LOSS" in
    100|100.*)
      echo ""
      echo -e "  ${Y}⚠ 目标完全不响应 ping：家用光猫/路由器常默认禁 WAN 口 ICMP${N}"
      echo -e "  ${D}  不影响结论：汇总会自动回退用 mtr 末端响应跳 + iperf 真实 TCP 流数据${N}"
      _nb_report "⚠ 目标 100% 不响应 ICMP —— 大概率是路由器禁 ping，而非线路真丢包（汇总已回退用 mtr 末端跳 / TCP 实测数据）"
      return 1
      ;;
  esac

  echo -e "  ${D}大包 1400B × 40 发（约 10 秒）...${N}"
  big=$(_nb_ping "$ip" -c 40 -i 0.2 -W 1 -s 1400)
  big_txt=$(printf '%s\n' "$big" | sed -n '/ping statistics/,$p')
  NB_BIG_LOSS=$(printf '%s\n' "$big" | _nb_parse_loss)

  _nb_report ""
  _nb_report "◆ 大包 1400B × 40 发, 间隔 0.2s:"
  if [ -n "$big_txt" ]; then
    printf '%s\n' "$big_txt" | sed 's/^/  /'
    printf '%s\n' "$big_txt" >> "$NB_REPORT"
  else
    echo -e "  ${Y}1400B 大包无响应（可能路径不允许该尺寸，见 MTU 探测）${N}"
    _nb_report "1400B 大包无响应（可能路径不允许该尺寸，参考 MTU 探测结果）"
  fi
  return 0
}

# ── 路径 MTU：DF 置位从 1500 对应载荷逐档往下探 ───────
_nb_mtu_probe(){
  local ip="$1" overhead=28 sizes size mtu=""

  # ICMP 头开销：v4 = 20 IP + 8 ICMP；v6 = 40 IPv6 + 8 ICMPv6。
  # 档位覆盖常见值：1500 原生 / 1492 PPPoE / 1480-1420 各类隧道 / 1280 v6 下限
  case "$ip" in
    *:*) overhead=48; sizes="1452 1444 1432 1420 1400 1380 1360 1340 1300 1232" ;;
    *)               sizes="1472 1464 1452 1440 1420 1400 1380 1360 1340 1300 1280 1252" ;;
  esac

  NB_PMTU=""
  _nb_section "路径 MTU 探测（DF 不分片 ping）"
  echo -e "  ${D}从 $(( ${sizes%% *} + overhead )) 起逐档探测...${N}"
  for size in $sizes; do
    if _nb_ping "$ip" -M do -c 2 -i 0.3 -W 1 -s "$size" >/dev/null; then
      mtu=$((size + overhead))
      break
    fi
  done

  if [ -n "$mtu" ]; then
    NB_PMTU="$mtu"
    echo -e "  路径 MTU ≈ ${C}${mtu}${N}（最大不分片载荷 ${size}B）"
    _nb_report "路径 MTU ≈ ${mtu}（最大不分片 ICMP 载荷 ${size}B + ${overhead}B 头）"
    if [ "$mtu" -lt 1500 ]; then
      _nb_report "提示: 路径 MTU < 1500，WireGuard/Hysteria2 等隧道协议的 MTU 建议 ≤ $((mtu - 80))"
    fi
  else
    echo -e "  ${Y}未能确定路径 MTU（各档大包均无响应）${N}"
    _nb_report "路径 MTU: 未能确定（DF 大包各档均无响应）"
  fi
}

# ── 逐跳丢包 / 延迟（mtr 报告模式）────────────────────
_nb_mtr(){
  local ip="$1" out parsed

  NB_MTR_IP=""; NB_MTR_LOSS=""; NB_MTR_BEST=""; NB_MTR_AVG=""; NB_MTR_WRST=""; NB_MTR_STDEV=""

  _nb_section "逐跳丢包 / 延迟（mtr, 50 循环）"
  if ! command -v mtr >/dev/null 2>&1; then
    echo -e "  ${Y}mtr 未安装（依赖安装失败），跳过${N}"
    _nb_report "mtr 未安装，跳过"
    return 1
  fi

  echo -e "  ${D}约 12 秒...${N}"
  # -r 报告 -w 宽输出 -n 纯 IP（反查 DNS 慢且对判断线路无用）；
  # 逐跳丢包看「最后一跳 + 连续多跳都掉」，中间单跳掉包多为路由器限 ICMP
  out=$(timeout 120 mtr -rwnc 50 -i 0.2 "$ip" 2>&1)
  printf '%s\n' "$out" | tee -a "$NB_REPORT" | sed 's/^/  /'
  _nb_report "（读法: 只有「从某跳起一直到最后一跳都丢」才算真丢包；中间孤立跳丢包是路由器限速 ICMP，无碍）"

  # 末端响应跳 = 最后一个有回应的路由器。目标禁 ping 时（家宽常态），
  # 它的丢包/RTT 就是「到家门口最后可见节点」的链路质量 —— 汇总判读
  # 靠它兜底，而不是把 ICMP 被禁误报成严重丢包
  # 报告行列序: hop.|-- IP Loss% Snt Last Avg Best Wrst StDev
  parsed=$(printf '%s\n' "$out" | awk '
    /^ *[0-9]+\.\|--/ {
      host = $2; loss = $3; sub(/%$/, "", loss)
      if (host != "???" && loss + 0 < 100) {
        ip = host; l = loss; avg = $6; best = $7; wrst = $8; sd = $9
      }
    }
    END { if (ip != "") printf "%s %s %s %s %s %s", ip, l, best, avg, wrst, sd }')
  if [ -n "$parsed" ]; then
    read -r NB_MTR_IP NB_MTR_LOSS NB_MTR_BEST NB_MTR_AVG NB_MTR_WRST NB_MTR_STDEV <<< "$parsed"
    _nb_report "末端响应跳: ${NB_MTR_IP} 丢包 ${NB_MTR_LOSS}% / RTT avg ${NB_MTR_AVG}ms（目标禁 ping 时以此跳作链路参考）"
  fi
}

# ── 回程路由 / 运营商线路（nexttrace）─────────────────
_nb_route(){
  local ip="$1" nt

  _nb_section "回程路由 / 运营商线路（nexttrace）"
  nt=$(_nb_nexttrace_bin)
  if [ -z "$nt" ]; then
    echo -e "  ${Y}nexttrace 不可用，线路判断请参考上方 mtr 的 IP 段${N}"
    _nb_report "nexttrace 不可用；线路判断参考上方 mtr 各跳 IP 段"
    return 1
  fi

  echo -e "  ${D}约 30-60 秒（联网查 ASN/归属地库）...${N}"
  # 每跳 1 次查询足够识别线路；输出带 ANSI 色，落报告前清洗
  timeout 150 "$nt" -q 1 "$ip" 2>&1 | _nb_strip_ansi | tee -a "$NB_REPORT" | sed 's/^/  /'
  _nb_report "（读法: 回程进大陆 59.43.*=电信 CN2, 202.97.*=电信 163；国际段 59.43 但国内段出现 202.97 = CN2 GT，全程 59.43 直落省网 = CN2 GIA；AS4837/AS9929 联通；AS9808/CMIN2 移动）"
}

# ── 实测 TCP 流内核采样（ss -ti）──────────────────────
# 家宽路由器普遍禁 WAN ping，ICMP 测不出 RTT/丢包/MTU；但 iperf 测试期间
# VPS ⇄ 家宽之间有真实 TCP 流 —— 从内核取这条流的 srtt/重传率/MSS/pmtu，
# 禁 ping 也测得准（重传率 ≈ VPS→家方向的真实丢包率）。
# 后台每 2s 采样、每次只留字节数最大的连接一行；bytes_acked 单调递增，
# 收尾时全文件取最大值即「数据量最大连接的最后一次采样」。若用户从家里
# SSH 连 VPS，采样也会扫到 SSH 连接，但 iperf 15s 就传几百 MB，必然胜出
_nb_tcp_probe_start(){
  local ip="$1" parent_pid=$$

  # 上一轮异常中断残留的采样器：先清掉再起新的
  [ -n "$NB_TCP_PROBE_PID" ] && kill "$NB_TCP_PROBE_PID" 2>/dev/null
  [ -n "$NB_TCP_PROBE_FILE" ] && rm -f "$NB_TCP_PROBE_FILE"

  NB_TCP_PROBE_FILE=$(mktemp)
  (
    # 双保险防孤儿：主脚本退出即停 + 最长 1 小时自灭
    n=0
    while [ "$n" -lt 1800 ] && kill -0 "$parent_pid" 2>/dev/null; do
      ss -tin dst "$ip" 2>/dev/null | awk '
        /rtt:/ {
          ba = 0
          for (i = 1; i <= NF; i++)
            if ($i ~ /^bytes_acked:/) ba = substr($i, 13) + 0
          if (ba >= best_ba) { best_ba = ba; best = $0 }
        }
        END { if (best != "") print best }
      ' >> "$NB_TCP_PROBE_FILE" 2>/dev/null
      sleep 2
      n=$((n + 1))
    done
  ) &
  NB_TCP_PROBE_PID=$!
}

# 停止采样并解析出 NB_TCP_*。幂等：trap 收尾和正常流程都会调，只生效一次
_nb_tcp_probe_stop(){
  local parsed

  [ -n "$NB_TCP_PROBE_PID" ] || return 0
  kill "$NB_TCP_PROBE_PID" 2>/dev/null || true
  wait "$NB_TCP_PROBE_PID" 2>/dev/null || true
  NB_TCP_PROBE_PID=""

  # 空字段用 "-" 占位，防止 printf 输出双空格被 read 折叠导致错位赋值
  parsed=$(awk '
    /rtt:/ {
      ba = 0
      for (i = 1; i <= NF; i++)
        if ($i ~ /^bytes_acked:/) ba = substr($i, 13) + 0
      if (ba >= best_ba) { best_ba = ba; best = $0 }
    }
    END {
      if (best == "") exit
      n = split(best, f, /[[:space:]]+/)
      rtt = ""; mss = "-"; pmtu = "-"; ret = 0; segs = 0
      for (i = 1; i <= n; i++) {
        if (f[i] ~ /^rtt:/)           rtt = substr(f[i], 5)
        else if (f[i] ~ /^mss:/)      mss = substr(f[i], 5)
        else if (f[i] ~ /^pmtu:/)     pmtu = substr(f[i], 6)
        else if (f[i] ~ /^segs_out:/) segs = substr(f[i], 10) + 0
        else if (f[i] ~ /^retrans:/)  { ret = f[i]; sub(/^retrans:[0-9]+\//, "", ret); ret += 0 }
      }
      if (rtt == "") exit
      split(rtt, r, "/")
      if (r[2] == "") r[2] = "-"
      printf "%s %s %s %s %s %s", r[1], r[2], mss, pmtu, ret, segs
    }' "$NB_TCP_PROBE_FILE" 2>/dev/null)
  rm -f "$NB_TCP_PROBE_FILE"
  NB_TCP_PROBE_FILE=""

  [ -n "$parsed" ] || return 0
  read -r NB_TCP_RTT NB_TCP_RTTVAR NB_TCP_MSS NB_TCP_PMTU NB_TCP_RETRANS NB_TCP_SEGS <<< "$parsed"
  [ "$NB_TCP_RTTVAR" = "-" ] && NB_TCP_RTTVAR=""
  [ "$NB_TCP_MSS" = "-" ] && NB_TCP_MSS=""
  [ "$NB_TCP_PMTU" = "-" ] && NB_TCP_PMTU=""
}

# 把采样结果写入报告（在带宽小节之后调用）。无有效样本时静默跳过
_nb_tcp_probe_report(){
  local target="$1" oh=40 est="" rate=""

  [ -n "$NB_TCP_RTT" ] || return 0

  # MSS 折算路径 MTU：v4 = MSS + 20 IP + 20 TCP；v6 = MSS + 40 IPv6 + 20 TCP。
  # 内核 pmtu 缓存起始就是本机路由 MTU，仅在收到 ICMP need-frag 后下调，
  # 中间 ICMP 被滤时会虚高 —— 取 min(MSS 折算, pmtu) 更接近真实
  case "$target" in *:*) oh=60 ;; esac
  if [ -n "$NB_TCP_MSS" ]; then
    est=$((NB_TCP_MSS + oh))
    [ -n "$NB_TCP_PMTU" ] && [ "$NB_TCP_PMTU" -lt "$est" ] && est="$NB_TCP_PMTU"
  elif [ -n "$NB_TCP_PMTU" ]; then
    est="$NB_TCP_PMTU"
  fi
  [ -n "$est" ] && NB_TCP_MTU_EST="$est"

  if [ "${NB_TCP_SEGS:-0}" -gt 0 ] 2>/dev/null; then
    rate=$(awk -v r="$NB_TCP_RETRANS" -v s="$NB_TCP_SEGS" 'BEGIN { printf "%.3f", r * 100 / s }')
  fi

  _nb_report ""
  _nb_report "◆ iperf 期间实测 TCP 流内核状态（ss -ti 采样，取数据量最大的连接）:"
  _nb_report "RTT srtt/rttvar : ${NB_TCP_RTT} / ${NB_TCP_RTTVAR:-?} ms"
  _nb_report "重传            : ${NB_TCP_RETRANS:-0} / ${NB_TCP_SEGS:-?} 段${rate:+ (${rate}%，≈ VPS→家方向真实丢包率)}"
  _nb_report "MSS / 内核 pmtu : ${NB_TCP_MSS:-?} / ${NB_TCP_PMTU:-?}${est:+ → 估算路径 MTU ≈ ${est}}"
  _nb_report "（读法: 真实 TCP 流的内核统计，不受目标禁 ping 影响；RTT/丢包/MTU 优先信这里）"

  echo ""
  echo -e "  ${B}实测 TCP 流${N}: RTT ${C}${NB_TCP_RTT}ms${N} | 重传率 ${C}${rate:-?}%${N} | 估算路径 MTU ${C}${est:-?}${N}"
}

# ── 带宽 / UDP：模式 A —— VPS 起服务端，家里跑客户端 ──
# VPS 单侧无法测「到家里」的真实带宽，必须家里有一端配合；此模式最通用：
# 家里任意 Windows/Mac/手机装个 iperf3 客户端即可，无需公网端口转发
# 服务端模式收尾：停 iperf3 + 撤防火墙。用 done 标记做成幂等 —— 正常流程和
# Ctrl+C / SSH 掉线的 trap 都会调它，防火墙规则已被持久化，绝不能留成后门端口
_nb_iperf_server_teardown(){
  local pid="$1" port="$2"
  [ -n "$_NB_TEARDOWN_DONE" ] && return 0
  _NB_TEARDOWN_DONE=1
  _nb_tcp_probe_stop
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo ""
  echo -e "${Y}==> 停止 iperf3 服务端并撤销临时防火墙放行...${N}"
  node_revoke_firewall_for_mode "$port" tcp dualstack
  node_revoke_firewall_for_mode "$port" udp dualstack
}

_nb_iperf_server_mode(){
  local ip="$1" port input vps_ip log pid=""

  if ! command -v iperf3 >/dev/null 2>&1; then
    echo -e "  ${Y}iperf3 未安装（依赖安装失败），无法带宽测试${N}"
    return 1
  fi

  while true; do
    read -p "  iperf3 监听端口 (回车默认 ${NETBENCH_IPERF_PORT_DEFAULT}): " input
    input="${input:-$NETBENCH_IPERF_PORT_DEFAULT}"
    if ! validate_port "$input"; then
      echo -e "  ${R}端口无效，需为 1-65535 之间的整数${N}"
      continue
    fi
    if check_port_in_use "$input"; then
      echo -e "  ${R}端口 ${input} 已被占用，请换一个${N}"
      continue
    fi
    port="$input"
    break
  done

  case "$ip" in
    *:*) vps_ip=$(detect_primary_ipv6) ;;
    *)   vps_ip=$(detect_primary_ipv4) ;;
  esac

  echo ""
  echo -e "${Y}==> 临时放行防火墙并启动 iperf3 服务端...${N}"
  node_apply_firewall_for_mode "$port" tcp dualstack
  node_apply_firewall_for_mode "$port" udp dualstack

  log=$(mktemp)
  # --forceflush: 结果实时落盘；极老版本不认此参数 → 秒退，去掉重试一次
  iperf3 -s -p "$port" --forceflush > "$log" 2>&1 &
  pid=$!
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    iperf3 -s -p "$port" > "$log" 2>&1 &
    pid=$!
    sleep 1
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    echo -e "  ${R}iperf3 服务端启动失败:${N}"
    sed 's/^/    /' "$log"
    rm -f "$log"
    node_revoke_firewall_for_mode "$port" tcp dualstack
    node_revoke_firewall_for_mode "$port" udp dualstack
    return 1
  fi

  echo ""
  echo -e "  ${G}服务端已就绪${N}。请在${B}家里的电脑${N}（连这条宽带）依次执行："
  render_divider
  echo -e "  ${C}iperf3 -c ${vps_ip} -p ${port} -R -t 15 -P 4${N}"
  echo -e "      ${D}↑ 下载方向（VPS → 家），最常用${N}"
  echo -e "  ${C}iperf3 -c ${vps_ip} -p ${port} -t 15 -P 4${N}"
  echo -e "      ${D}↑ 上传方向（家 → VPS）${N}"
  echo -e "  ${C}iperf3 -c ${vps_ip} -p ${port} -R -u -b 200M -t 10${N}"
  echo -e "      ${D}↑ UDP 下载方向丢包/抖动；200M 请改成你家下行带宽的 8 成${N}"
  echo -e "  ${C}iperf3 -c ${vps_ip} -p ${port} -u -b 30M -t 10${N}"
  echo -e "      ${D}↑ UDP 上传方向；30M 请改成你家上行带宽的 8 成${N}"
  render_divider
  echo -e "  ${Y}· 带 -R 的两条（下载方向），真实结果只打印在家里的屏幕上 —— 尤其 UDP${N}"
  echo -e "  ${Y}  的丢包/抖动，请把家里终端的输出也复制进给 AI 的内容里${N}"
  echo -e "  ${D}· Windows 装法: winget install iperf3，或 iperf.fr 下载解压后在该目录执行${N}"
  echo -e "  ${D}· 手机可用「HE.NET Network Tools」等含 iperf3 的 App${N}"
  echo -e "  ${D}· 云服务器(阿里/腾讯/AWS 等)还需在控制台安全组放行 ${port} 的 TCP+UDP${N}"
  echo ""
  # 等待期间后台采样真实 TCP 流（禁 ping 时的 RTT/丢包/MTU 数据源）
  _nb_tcp_probe_start "$ip"
  # 等待期间被 Ctrl+C / 掉线打断也要收尾（trap 里变量此刻已定型，直接展开）
  _NB_TEARDOWN_DONE=""
  # shellcheck disable=SC2064
  trap "_nb_iperf_server_teardown '$pid' '$port'; trap - INT TERM HUP" INT TERM HUP
  read -p "  家里全部测完后按回车收尾（自动停服务端并把结果写入报告）..." _
  trap - INT TERM HUP

  _nb_iperf_server_teardown "$pid" "$port"

  _nb_section "带宽 / UDP（iperf3，VPS 服务端视角）"
  if grep -q "Accepted connection" "$log" 2>/dev/null; then
    cat "$log" >> "$NB_REPORT"
    tail -n 40 "$log" | sed 's/^/  /'
    _nb_report "（读法: TCP 看 Bitrate；UDP 家→VPS 方向看本报告 receiver 行的 Lost/Total；UDP VPS→家(-R) 在本报告只有 sender 行，其 0% 只代表已发出、不代表真实丢包，真实丢包/抖动见家庭侧客户端屏幕输出）"
    echo -e "  ${G}带宽结果已写入报告${N}"
  else
    echo -e "  ${Y}未检测到家庭侧客户端连接，带宽部分留空${N}"
    _nb_report "（未检测到家庭侧 iperf3 客户端连接：可能云安全组未放行 ${port}，或家里未执行命令）"
  fi
  _nb_tcp_probe_report "$ip"
  rm -f "$log"
}

# ── 带宽 / UDP：模式 B —— 家里有 iperf3 服务端，全自动 ──
# 适合软路由/NAS 常驻 iperf3 -s 并做了端口转发的进阶用户；此模式还能顺带
# 测「满载下延迟」（bufferbloat），这是普通测速脚本给不了的关键调参数据
_nb_iperf_client_mode(){
  local ip="$1" port input bw udp_bw
  local idle_out load_avg ping_pid ping_tmp

  if ! command -v iperf3 >/dev/null 2>&1; then
    echo -e "  ${Y}iperf3 未安装（依赖安装失败），无法带宽测试${N}"
    return 1
  fi

  while true; do
    read -p "  家里 iperf3 服务端端口 (回车默认 5201): " input
    input="${input:-5201}"
    if validate_port "$input"; then
      port="$input"
      break
    fi
    echo -e "  ${R}端口无效，需为 1-65535 之间的整数${N}"
  done

  while true; do
    read -p "  家宽下行带宽 (Mbps，决定 UDP 打流速率，回车默认 300): " bw
    bw="${bw:-300}"
    case "$bw" in
      *[!0-9]*|???????*) echo -e "  ${R}必须为正整数 (1-10000)${N}"; continue ;;
    esac
    bw=$((10#$bw))
    if [ "$bw" -lt 1 ] || [ "$bw" -gt 10000 ]; then
      echo -e "  ${R}范围 1-10000 Mbps${N}"
      continue
    fi
    break
  done
  # UDP 按带宽 8 成打流：打满会自己制造丢包，测出来的就不是线路真实损耗了
  udp_bw=$((bw * 8 / 10))
  [ "$udp_bw" -lt 10 ] && udp_bw=10
  [ "$udp_bw" -gt 1000 ] && udp_bw=1000

  _nb_section "带宽 / UDP（iperf3，家庭侧为服务端）"

  echo -e "  ${D}连通性预检...${N}"
  if ! timeout 8 iperf3 -c "$ip" -p "$port" -t 1 >/dev/null 2>&1; then
    echo -e "  ${R}连不上家里的 iperf3 服务端（${ip}:${port}）${N}"
    echo -e "  ${D}请确认: 家里已运行 iperf3 -s；路由器已把该端口转发到该设备；其防火墙放行${N}"
    _nb_report "iperf3 连接失败（${ip}:${port} 不可达），带宽未测"
    return 1
  fi

  # 空载 RTT 基线：完整测评里 ping 套件已给出；带宽单测时快速补测 10 发
  if [ -z "$NB_RTT_AVG" ]; then
    idle_out=$(_nb_ping "$ip" -c 10 -i 0.2 -W 1)
    NB_RTT_AVG=$(printf '%s\n' "$idle_out" | _nb_parse_rtt | awk '{print $2}')
  fi

  echo -e "  ${D}① TCP 下载方向（VPS→家）4 并发 × 15s，同步采样满载延迟...${N}"
  # TCP 测试期间后台采样真实流内核状态（禁 ping 时的 RTT/丢包/MTU 数据源）
  _nb_tcp_probe_start "$ip"
  ping_tmp=$(mktemp)
  _nb_ping "$ip" -c 70 -i 0.2 -W 1 > "$ping_tmp" &
  ping_pid=$!
  _nb_report "◆ TCP VPS→家（家庭下载方向），4 并发 × 15s:"
  timeout 40 iperf3 -c "$ip" -p "$port" -t 15 -P 4 2>&1 \
    | tee -a "$NB_REPORT" | grep -E "SUM|error|busy" | sed 's/^/  /'
  wait "$ping_pid" 2>/dev/null || true
  load_avg=$(_nb_parse_rtt < "$ping_tmp" | awk '{print $2}')
  rm -f "$ping_tmp"

  echo -e "  ${D}② TCP 上传方向（家→VPS）4 并发 × 15s...${N}"
  _nb_report ""
  _nb_report "◆ TCP 家→VPS（家庭上传方向），4 并发 × 15s:"
  timeout 40 iperf3 -c "$ip" -p "$port" -R -t 15 -P 4 2>&1 \
    | tee -a "$NB_REPORT" | grep -E "SUM|error|busy" | sed 's/^/  /'
  _nb_tcp_probe_stop

  echo -e "  ${D}③ UDP 打流 ${udp_bw}Mbps × 10s（丢包/抖动）...${N}"
  _nb_report ""
  _nb_report "◆ UDP VPS→家 @ ${udp_bw}Mbps × 10s（看 Lost/Total 与 Jitter）:"
  timeout 30 iperf3 -c "$ip" -p "$port" -u -b "${udp_bw}M" -t 10 2>&1 \
    | tee -a "$NB_REPORT" | tail -n 4 | sed 's/^/  /'

  if [ -n "$load_avg" ] && [ -n "$NB_RTT_AVG" ]; then
    echo ""
    echo -e "  满载延迟: 空载 avg ${C}${NB_RTT_AVG}ms${N} → 满载 avg ${C}${load_avg}ms${N}"
    _nb_report ""
    _nb_report "满载下延迟: 空载 avg ${NB_RTT_AVG}ms → 满载 avg ${load_avg}ms（差值大 = 缓冲膨胀 bufferbloat，需调小缓冲或换 BBR）"
  fi
  _nb_tcp_probe_report "$ip"
}

_nb_iperf_wizard(){
  local ip="$1" ans

  echo ""
  echo -e "  ${B}带宽 / UDP 丢包测试（iperf3，需家里一端配合）${N}"
  render_menu_item 1 "VPS 起服务端，家里电脑跑命令 ${D}(通用，推荐)${N}"
  render_menu_item 2 "家里已有 iperf3 服务端 ${D}(软路由/NAS + 端口转发，全自动)${N}"
  render_menu_item 0 "跳过带宽测试"
  render_divider
  read -p "  请选择: " ans
  case "$ans" in
    1) _nb_iperf_server_mode "$ip" ;;
    2) _nb_iperf_client_mode "$ip" ;;
    *)
      _nb_report ""
      _nb_report "（本次未做 iperf3 带宽/UDP 测试）"
      ;;
  esac
}

# ── 关键指标汇总 + 简单判读 ───────────────────────────
_nb_summary(){
  local target="$1" big_txt note mtu_txt loss_txt rtt_console rtt_src

  [ -n "$NB_BIG_LOSS" ] && big_txt="${NB_BIG_LOSS}%" || big_txt="未测"

  _nb_section "关键指标汇总"
  _nb_report "目标: ${target}"

  # RTT 来源优先级: ICMP 直测 > iperf 真实 TCP 流 > mtr 末端响应跳。
  # 家宽禁 ping 是常态，后两者专为这种场景兜底 —— 不能因为 ICMP 被禁
  # 就把汇总写成「无数据」甚至误判成线路丢包
  if [ -n "$NB_RTT_AVG" ]; then
    rtt_src="ICMP 直测"
    _nb_report "RTT min/avg/max/mdev : ${NB_RTT_MIN:-?} / ${NB_RTT_AVG} / ${NB_RTT_MAX:-?} / ${NB_RTT_MDEV:-?} ms (${rtt_src})"
    rtt_console="${C}${NB_RTT_MIN:-?} / ${NB_RTT_AVG} / ${NB_RTT_MAX:-?}${N} ms ${D}(min/avg/max, 抖动 ${NB_RTT_MDEV:-?})${N}"
  elif [ -n "$NB_TCP_RTT" ]; then
    rtt_src="iperf 真实 TCP 流, 目标禁 ping"
    _nb_report "RTT srtt/rttvar      : ${NB_TCP_RTT} / ${NB_TCP_RTTVAR:-?} ms (${rtt_src})"
    rtt_console="${C}${NB_TCP_RTT}${N} ms ${D}(TCP srtt, rttvar ${NB_TCP_RTTVAR:-?})${N}"
  elif [ -n "$NB_MTR_AVG" ]; then
    rtt_src="mtr 末端响应跳 ${NB_MTR_IP}, 目标禁 ping"
    _nb_report "RTT best/avg/wrst/stdev : ${NB_MTR_BEST} / ${NB_MTR_AVG} / ${NB_MTR_WRST} / ${NB_MTR_STDEV} ms (${rtt_src})"
    rtt_console="${C}${NB_MTR_BEST} / ${NB_MTR_AVG} / ${NB_MTR_WRST}${N} ms ${D}(mtr 末端跳, 抖动 ${NB_MTR_STDEV})${N}"
  else
    rtt_src=""
    _nb_report "RTT min/avg/max/mdev : ? / ? / ? / ? ms"
    rtt_console="${C}?${N}"
  fi

  case "$NB_LOSS" in
    100|100.*) loss_txt="ICMP 全无响应（目标禁 ping，非线路丢包）" ;;
    *)         loss_txt="${NB_LOSS:-?}%" ;;
  esac
  _nb_report "小包丢包 (100 发)    : ${loss_txt}"
  _nb_report "大包 1400B 丢包      : ${big_txt}"

  if [ -n "$NB_PMTU" ]; then
    mtu_txt="$NB_PMTU"
  elif [ -n "$NB_TCP_MTU_EST" ]; then
    mtu_txt="≈ ${NB_TCP_MTU_EST}（由实测 TCP 流 MSS/pmtu 折算）"
  else
    mtu_txt="未测"
  fi
  _nb_report "路径 MTU             : ${mtu_txt}"

  render_info_line "RTT" "$rtt_console"
  render_info_line "丢包" "${C}${loss_txt}${N} ${D}(大包 ${big_txt})${N}"
  render_info_line "路径 MTU" "${C}${mtu_txt}${N}"

  if [ -n "$NB_LOSS" ]; then
    case "$NB_LOSS" in
      100|100.*)
        # 修复：以前这里会掉进「严重丢包(>=3%)，调参收益有限」的误判，
        # 与前文「大概率是路由器禁 ping」自相矛盾。现按数据源分级下结论：
        # 真实 TCP 流重传率（最准）> mtr 末端响应跳 > 提示开 WAN ping
        if [ "${NB_TCP_SEGS:-0}" -gt 0 ] 2>/dev/null; then
          note=$(awk -v r="${NB_TCP_RETRANS:-0}" -v s="$NB_TCP_SEGS" 'BEGIN {
            p = r * 100 / s
            if (p < 0.1)     printf "目标禁 ping（非线路丢包）；实测 TCP 流重传率 %.3f%%，链路干净", p
            else if (p < 1)  printf "目标禁 ping；实测 TCP 流重传率 %.3f%%，轻微丢包，属可用范围", p
            else             printf "目标禁 ping；实测 TCP 流重传率 %.2f%%，丢包明显，调参侧重抗丢包", p
          }')
        elif [ -n "$NB_MTR_IP" ]; then
          note=$(awk -v l="$NB_MTR_LOSS" -v ip="$NB_MTR_IP" 'BEGIN {
            if (l + 0 <= 1) printf "目标禁 ping（非线路丢包）；mtr 末端响应跳 %s 丢包 %s%%，链路本身干净", ip, l
            else            printf "目标禁 ping；mtr 末端响应跳 %s 丢包 %s%%（也可能是该跳限速 ICMP），建议开「允许 WAN ping」或补跑 iperf 后再下结论", ip, l
          }')
        else
          note="目标禁 ping 且无 TCP/mtr 回退数据，建议路由器开「允许 WAN ping」后重测"
        fi
        ;;
      *)
        note=$(awk -v l="$NB_LOSS" 'BEGIN {
          if (l == 0)      print "无丢包，链路干净"
          else if (l < 1)  print "轻微丢包(<1%)，属正常波动"
          else if (l < 3)  print "明显丢包(1-3%)，晚高峰大概率更差，调参侧重抗丢包"
          else             print "严重丢包(>=3%)，先考虑线路/时段问题，调参收益有限"
        }')
        ;;
    esac
    _nb_report "判读: ${note}"
    echo -e "  ${D}判读: ${note}${N}"
  fi
  if [ -n "$NB_LOSS" ] && [ -n "$NB_BIG_LOSS" ]; then
    note=$(awk -v s="$NB_LOSS" -v b="$NB_BIG_LOSS" 'BEGIN {
      if (b - s >= 3) print "大包丢包显著高于小包 → 疑似 MTU/分片受限，隧道类协议务必下调 MTU"
    }')
    if [ -n "$note" ]; then
      _nb_report "判读: ${note}"
      echo -e "  ${D}判读: ${note}${N}"
    fi
  fi

  _nb_report ""
  _nb_report "── 报告结束：请把全文（从「【给 AI 的说明】」起）复制给 AI 获取调参建议 ──"
}

# ── 主流程 ────────────────────────────────────────────
# mode: full = 全部测试 + 带宽引导；quick = 跳过带宽；iperf = 只测带宽
run_netbench(){
  local mode="${1:-full}"
  local saved ssh_ip default_ip input target ans src_label reachable=1

  if ! require_root; then return 1; fi

  render_section_header "本地链路测评（VPS ⇄ 家宽）"
  echo -e "  ${D}实测 VPS 到「你家公网 IP」的延迟/抖动/丢包/回程线路/MTU/带宽，${N}"
  echo -e "  ${D}生成纯文本报告，整段复制给 AI 即可辅助调参${N}"
  echo ""

  # ── 目标 IP：上次保存 > 当前 SSH 来源 > 手输 ──
  saved=$(_nb_load_target)
  if [ -n "$saved" ] && ! _tcp_autotune_valid_ip "$saved"; then
    saved=""
  fi
  ssh_ip=""
  [ -n "${SSH_CLIENT:-}" ] && ssh_ip=$(printf '%s' "$SSH_CLIENT" | awk '{print $1}')
  if [ -n "$saved" ]; then
    default_ip="$saved"; src_label="上次保存"
  else
    default_ip="$ssh_ip"; src_label="当前 SSH 来源"
  fi

  while true; do
    if [ -n "$default_ip" ]; then
      echo -e "  ${B}默认目标${N} : ${C}${default_ip}${N} ${D}(${src_label})${N}"
      read -p "  家庭公网 IP (回车用默认，0 返回): " input
      [ -z "$input" ] && input="$default_ip"
    else
      read -p "  家庭公网 IP (IPv4/IPv6，0 返回): " input
    fi
    [ "$input" = "0" ] && return 0
    if ! _tcp_autotune_valid_ip "$input"; then
      echo -e "  ${R}不是合法的 IPv4/IPv6 地址${N}"
      continue
    fi
    case "$input" in
      *:*) is_private_ipv6 "$input" && echo -e "  ${Y}⚠ 这是内网/链路本地地址，结果不能代表公网链路${N}" ;;
      *)   is_private_ipv4 "$input" && echo -e "  ${Y}⚠ 这是内网地址，请用家里的公网出口 IP（百度搜「IP」可查）${N}" ;;
    esac
    target="$input"
    break
  done
  _nb_save_target "$target" \
    || echo -e "  ${Y}目标 IP 本次可用，但未能保存到 ${NETBENCH_ENV_PATH}${N}" >&2

  echo ""
  _nb_ensure_tools || true
  [ "$mode" != "iperf" ] && { _nb_ensure_nexttrace || true; }

  NB_REPORT="${NETBENCH_REPORT_PREFIX}-$(date +%Y%m%d-%H%M%S).txt"
  : > "$NB_REPORT" || {
    echo -e "${R}无法写入报告文件 ${NB_REPORT}${N}"
    pause_screen
    return 1
  }
  NB_LOSS=""; NB_RTT_MIN=""; NB_RTT_AVG=""; NB_RTT_MAX=""; NB_RTT_MDEV=""
  NB_BIG_LOSS=""; NB_PMTU=""
  NB_MTR_IP=""; NB_MTR_LOSS=""; NB_MTR_BEST=""; NB_MTR_AVG=""; NB_MTR_WRST=""; NB_MTR_STDEV=""
  NB_TCP_RTT=""; NB_TCP_RTTVAR=""; NB_TCP_MSS=""; NB_TCP_PMTU=""
  NB_TCP_RETRANS=""; NB_TCP_SEGS=""; NB_TCP_MTU_EST=""
  NB_TCP_PROBE_PID=""; NB_TCP_PROBE_FILE=""

  _nb_sysinfo "$target"

  if [ "$mode" != "iperf" ]; then
    _nb_ping_suite "$target" || reachable=0
    [ "$reachable" = "1" ] && _nb_mtu_probe "$target"
    _nb_mtr "$target"
    _nb_route "$target"
  fi

  case "$mode" in
    full)  _nb_iperf_wizard "$target" ;;
    iperf)
      _nb_iperf_wizard "$target"
      ;;
  esac

  [ "$mode" != "iperf" ] && _nb_summary "$target"
  cleanup_old_backups "${NETBENCH_REPORT_PREFIX}-*.txt" 5

  echo ""
  echo -e "${G}✓ 测评完成${N}，报告: ${C}${NB_REPORT}${N}"
  read -p "  是否现在完整显示报告，方便整段复制给 AI？(Y/n): " ans
  if [ "$ans" != "n" ] && [ "$ans" != "N" ]; then
    echo ""
    render_divider
    cat "$NB_REPORT"
    render_divider
    echo -e "  ${D}↑ 从「【给 AI 的说明】」到这里全选复制即可；再次查看: cat ${NB_REPORT}${N}"
  fi
  pause_screen
}

show_netbench_report(){
  local last

  last=$(_nb_latest_report)
  if [ -z "$last" ] || [ ! -f "$last" ]; then
    echo ""
    echo -e "  ${Y}还没有测评报告，请先跑一次测评${N}"
    sleep 1
    return
  fi

  render_section_header "最近一次测评报告"
  echo -e "  ${D}${last}${N}"
  render_divider
  cat "$last"
  render_divider
  pause_screen
}

show_netbench_menu(){
  local choice last

  while true; do
    render_section_header "本地链路测评（VPS ⇄ 家宽）"
    echo -e "  ${D}测到你家 IP 的专业链路数据（通用测速脚本测不到），报告可直接喂 AI 调参${N}"
    last=$(_nb_latest_report)
    [ -n "$last" ] && echo -e "  ${D}最近报告: ${last}${N}"
    echo ""
    render_menu_item 1 "一键完整测评 ${D}(延迟/丢包/MTU/路由 + 可选带宽)${N}"
    render_menu_item 2 "快速测评 ${D}(不含带宽，约 2 分钟)${N}"
    render_menu_item 3 "仅带宽 / UDP 测试 (iperf3)"
    render_menu_item 4 "查看最近一次报告"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case "$choice" in
      1) run_netbench full ;;
      2) run_netbench quick ;;
      3) run_netbench iperf ;;
      4) show_netbench_report ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}
# ═══ source: 50-node-reality.sh ═══
install_reality_node(){
  local port_input="" sni_input=""
  local keypair="" private_key="" public_key=""
  local access_ip="" link="" ipv6_link=""
  local public_ipv4="" public_ipv6=""
  local install_mode="ipv4" mode_label=""
  local PORT SNI TAG LISTEN_CHOICE LISTEN_ADDR UUID SHORT_ID confirm
  local txn="" old_port="" old_mode="ipv4"

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
    old_port=$(get_node_value reality Port 2>/dev/null || true)
    old_mode=$(get_node_value reality Mode 2>/dev/null || echo ipv4)
  fi

  while true; do
    read -p "  端口 (8443): " port_input
    PORT="${port_input:-8443}"
    if ! validate_port "$PORT"; then
      echo -e "${R}端口必须是 1-65535 的数字${N}"
      continue
    fi
    PORT=$((10#$PORT))
    if [ "$PORT" != "$old_port" ] && check_port_in_use "$PORT" tcp; then
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
    read -p "  域名 (www.tesla.com): " sni_input
    sni_input="${sni_input:-www.tesla.com}"
    SNI=$(sanitize_sni "$sni_input")
    if [ -n "$SNI" ]; then
      break
    fi
    echo -e "${R}域名不能为空，且不能只包含引号或换行${N}"
  done

  read -p "  节点名称 (reality): " TAG
  TAG="${TAG:-reality}"

  echo -e "  监听模式："
  echo "    1) 仅 IPv4 入站 - 0.0.0.0（默认）"
  echo "    2) 双栈入站 - ::"
  echo "    3) 仅 IPv6 入站"
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
      echo -e "${R}未检测到可用的 IPv6 地址，无法使用“仅 IPv6 入站”模式${N}"
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
  txn=$(node_transaction_begin reality) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

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
    node_transaction_rollback "$txn"
    echo -e "${R}写入 inbound 失败${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 校验并启动...${N}"
  if ! config_check_and_restart "$PORT" tcp; then
    node_transaction_rollback "$txn"
    echo ""
    echo -e "${R}sing-box 校验或重启失败${N}"
    pause_screen
    return 1
  fi

  if ! node_apply_firewall_for_mode "$PORT" tcp "$install_mode"; then
    node_transaction_rollback "$txn"
    echo -e "${R}防火墙放行失败，节点配置已回滚${N}"
    pause_screen
    return 1
  fi
  print_firewall_hint "$PORT" tcp "Reality 节点入站"

  link=$(build_reality_link "$UUID" "$access_ip" "$PORT" "$SNI" "$public_key" "$SHORT_ID" "$TAG" 2>/dev/null || true)
  if [ "$install_mode" = "dualstack" ] && [ -n "$public_ipv6" ] && [ "$public_ipv6" != "$access_ip" ]; then
    ipv6_link=$(build_reality_link "$UUID" "$public_ipv6" "$PORT" "$SNI" "$public_key" "$SHORT_ID" "${TAG}-ipv6" 2>/dev/null || true)
  fi

  if ! write_node_info_file reality <<EOF
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
  then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if [ -n "$old_port" ] && [ "$old_port" != "$PORT" ]; then
    if ! node_revoke_firewall_for_mode "$old_port" tcp "$old_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧端口防火墙清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi
  node_transaction_commit "$txn"

  register_sb_command || true

  echo ""
  echo -e "  ${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "  ${G}║${N}  ${B}${W}${APP_NAME}${N}  ${G}Reality 节点创建完成${N}                       ${G}║${N}"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${N}"
  echo -e "  模式      : ${C}$mode_label${N}"
  echo -e "  UUID      : ${C}$UUID${N}"
  echo -e "  PublicKey : ${C}$public_key${N}"
  echo -e "  入口 IP   : ${C}${access_ip:-未知}${N}"
  echo -e "  出站策略  : ${C}双栈（跟随系统路由）${N}"
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
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  jq -er '(.inbounds // []) | length' "$CONFIG_PATH" 2>/dev/null
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
  remain=$(config_inbound_count) || return 1
  [[ "$remain" =~ ^[0-9]+$ ]] || return 1
  if [ "${remain:-0}" -eq 0 ]; then
    echo -e "${Y}==> 已无任何节点，停止 sing-box 服务...${N}"
    systemctl stop sing-box >/dev/null 2>&1 || return 1
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then
      systemctl disable sing-box >/dev/null 2>&1 || return 1
    fi
    systemctl is-active --quiet sing-box 2>/dev/null && return 1
    return 0
  fi
  config_check_and_restart
}

uninstall_node_transaction(){
  local type="$1" inbound_tag="$2" proto="$3"
  local txn port mode hop_enabled hop_start hop_end

  port=$(get_node_value "$type" Port 2>/dev/null || true)
  mode=$(get_node_value "$type" Mode 2>/dev/null || echo ipv4)
  txn=$(node_transaction_begin "$type") || return 1

  if [ "$type" = "hy2" ]; then
    hop_enabled=$(get_node_value hy2 PortHop 2>/dev/null || echo 0)
    hop_start=$(get_node_value hy2 PortHopStart 2>/dev/null || true)
    hop_end=$(get_node_value hy2 PortHopEnd 2>/dev/null || true)
    if [ "$hop_enabled" = "1" ] && [ -n "$hop_start" ] && [ -n "$hop_end" ]; then
      if ! port_hop_remove "$hop_start" "$hop_end" "$mode"; then
        node_transaction_rollback "$txn"
        return 1
      fi
    fi
  fi

  if [ -n "$port" ] && ! node_revoke_firewall_for_mode "$port" "$proto" "$mode"; then
    node_transaction_rollback "$txn"
    return 1
  fi
  if ! config_remove_inbound_by_tag "$inbound_tag" || ! remove_node_info "$type"; then
    node_transaction_rollback "$txn"
    return 1
  fi
  case "$type" in
    hy2|tuic)
      if ! rm -f -- "$CERTS_DIR/${type}.crt" "$CERTS_DIR/${type}.key"; then
        node_transaction_rollback "$txn"
        return 1
      fi
      ;;
  esac
  if ! post_uninstall_service_step; then
    node_transaction_rollback "$txn"
    return 1
  fi
  node_transaction_commit "$txn"
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

  if ! uninstall_node_transaction reality reality-in tcp; then
    echo -e "${R}Reality 节点卸载失败，已恢复原配置${N}"
    pause_screen
    return 1
  fi
  echo -e "${G}Reality 节点已卸载${N}"
  pause_screen
}

# 兼容入口：do_install 默认创建 Reality 节点
do_install(){ install_reality_node; }

# ─── 端口跳跃公共逻辑 ─────────────────────────────────
# ═══ source: 51-port-hop.sh ═══
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
# ═══ source: 52-node-hy2.sh ═══
generate_hy2_random_port(){
  local p attempts=0
  while [ $attempts -lt 30 ]; do
    p=$(( (RANDOM << 15 | RANDOM) % 45535 + 20000 ))
    if ! check_port_in_use "$p" udp; then
      printf '%s' "$p"
      return 0
    fi
    attempts=$((attempts + 1))
  done
  printf '%s' "$p"
}

# AnyTLS 默认端口生成：避开本机已占端口与已安装节点已用端口
generate_anytls_random_port(){
  local p attempts=0 t taken_ports=""
  for t in reality hy2 tuic ss2022; do
    if node_installed "$t"; then
      taken_ports="$taken_ports $(get_node_value "$t" Port 2>/dev/null || true)"
    fi
  done
  while [ $attempts -lt 30 ]; do
    p=$(( (RANDOM << 15 | RANDOM) % 45535 + 20000 ))
    attempts=$((attempts + 1))
    if printf '%s\n' $taken_ports | grep -qFx "$p"; then
      continue
    fi
    if ! check_port_in_use "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  printf '%s' "$p"
}

generate_self_signed_cert(){
  local type="$1" sni="$2"
  local crt="$CERTS_DIR/${type}.crt"
  local key="$CERTS_DIR/${type}.key"
  local workdir new_crt new_key

  ensure_nodes_dir || return 1
  if ! command -v openssl >/dev/null 2>&1; then
    echo -e "${R}未找到 openssl${N}"
    return 1
  fi
  workdir=$(mktemp -d "$CERTS_DIR/.${type}.XXXXXX") || return 1
  chmod 700 "$workdir" 2>/dev/null || { rm -rf -- "$workdir"; return 1; }
  new_crt="$workdir/${type}.crt"
  new_key="$workdir/${type}.key"
  if ! openssl ecparam -genkey -name prime256v1 -out "$new_key" 2>/dev/null; then
    if ! openssl genrsa -out "$new_key" 2048 >/dev/null 2>&1; then
      echo -e "${R}私钥生成失败${N}"
      rm -rf -- "$workdir"
      return 1
    fi
  fi
  if ! openssl req -new -x509 -days 3650 -key "$new_key" -out "$new_crt" \
       -subj "/CN=${sni}" >/dev/null 2>&1; then
    echo -e "${R}自签证书生成失败${N}"
    rm -rf -- "$workdir"
    return 1
  fi
  chmod 600 "$new_key" "$new_crt" 2>/dev/null || { rm -rf -- "$workdir"; return 1; }
  if [ -f "$key" ] && ! cp -a -- "$key" "$workdir/old.key"; then
    rm -rf -- "$workdir"
    return 1
  fi
  if [ -f "$crt" ] && ! cp -a -- "$crt" "$workdir/old.crt"; then
    rm -rf -- "$workdir"
    return 1
  fi
  if ! mv -f -- "$new_key" "$key" || ! mv -f -- "$new_crt" "$crt"; then
    local restore_ok=1
    if [ -f "$workdir/old.key" ]; then
      cp -a -- "$workdir/old.key" "$key" 2>/dev/null || restore_ok=0
    else
      rm -f -- "$key" || restore_ok=0
    fi
    if [ -f "$workdir/old.crt" ]; then
      cp -a -- "$workdir/old.crt" "$crt" 2>/dev/null || restore_ok=0
    else
      rm -f -- "$crt" || restore_ok=0
    fi
    rm -rf -- "$workdir"
    [ "$restore_ok" -eq 1 ] || echo -e "${R}证书替换失败且旧证书恢复不完整${N}" >&2
    return 1
  fi
  rm -rf -- "$workdir"
  printf '%s\n%s' "$crt" "$key"
}

generate_self_signed_cert_for_hy2(){
  generate_self_signed_cert hy2 "$1"
}

generate_self_signed_cert_for_tuic(){
  generate_self_signed_cert tuic "$1"
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
  local txn="" old_port="" old_mode="ipv4" old_hop="0" old_hop_start="" old_hop_end=""

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
    old_port=$(get_node_value hy2 Port 2>/dev/null || true)
    old_mode=$(get_node_value hy2 Mode 2>/dev/null || echo ipv4)
    old_hop=$(get_node_value hy2 PortHop 2>/dev/null || echo 0)
    old_hop_start=$(get_node_value hy2 PortHopStart 2>/dev/null || true)
    old_hop_end=$(get_node_value hy2 PortHopEnd 2>/dev/null || true)
  fi

  # 端口（默认随机高位 UDP）
  local default_port
  default_port=$(generate_hy2_random_port)
  while true; do
    read -p "  端口 (${default_port}, 回车随机): " port_input
    PORT="${port_input:-$default_port}"
    if validate_port "$PORT"; then
      PORT=$((10#$PORT))
      if [ "$PORT" != "$old_port" ] && check_port_in_use "$PORT" udp; then
        echo -e "${R}UDP 端口 ${PORT} 已被其他服务占用${N}"
        local force_port=""
        read -p "  仍然使用此端口？(y/N): " force_port
        if [ "$force_port" != "y" ] && [ "$force_port" != "Y" ]; then
          continue
        fi
      fi
      break
    fi
    echo -e "${R}端口必须是 1-65535 的数字${N}"
  done

  # 节点名
  read -p "  节点名称 (hy2): " TAG
  TAG="${TAG:-hy2}"

  # 监听模式
  echo -e "  监听模式："
  echo "    1) 仅 IPv4 入站 - 0.0.0.0（默认）"
  echo "    2) 双栈入站 - ::"
  echo "    3) 仅 IPv6 入站"
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
      echo -e "${R}未检测到可用的 IPv6 地址，无法使用“仅 IPv6 入站”模式${N}"
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
      read -r HOP_START HOP_END < <(port_hop_compute_range "$PORT")
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

  echo -e "${Y}==> 建立节点事务快照...${N}"
  ensure_jq || { pause_screen; return 1; }
  txn=$(node_transaction_begin hy2) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

  # 准备证书
  if [ "$cert_source" = "self" ]; then
    echo -e "${Y}==> 生成自签证书...${N}"
    if ! cert_paths=$(generate_self_signed_cert_for_hy2 "$SNI"); then
      node_transaction_rollback "$txn"
      pause_screen
      return 1
    fi
    cert_path=$(echo "$cert_paths" | sed -n '1p')
    key_path=$(echo "$cert_paths" | sed -n '2p')
  fi

  echo -e "${Y}==> 写入配置...${N}"

  local tls_json
  if [ "$cert_source" = "acme" ]; then
    if ! tls_json=$(jq -n --arg sni "$SNI" --arg email "$acme_email" '{
      enabled: true,
      server_name: $sni,
      alpn: ["h3"],
      certificate_provider: {type: "acme", domain: [$sni], email: $email}
    }'); then
      node_transaction_rollback "$txn"
      pause_screen
      return 1
    fi
  else
    if ! tls_json=$(jq -n --arg sni "$SNI" --arg crt "$cert_path" --arg key "$key_path" '{
      enabled: true,
      server_name: $sni,
      alpn: ["h3"],
      certificate_path: $crt,
      key_path: $key
    }'); then
      node_transaction_rollback "$txn"
      pause_screen
      return 1
    fi
  fi

  local obfs_json="null"
  if [ "$obfs_enable" = "1" ]; then
    if ! obfs_json=$(jq -n --arg pw "$obfs_password" '{type: "salamander", password: $pw}'); then
      node_transaction_rollback "$txn"
      pause_screen
      return 1
    fi
  fi

  # 构造 user 对象（Hysteria2 的 user 仅含 password；带宽限制 up_mbps/down_mbps 是 inbound 顶层字段）
  local user_obj
  if ! user_obj=$(jq -n --arg pw "$password" '{password: $pw}'); then
    node_transaction_rollback "$txn"
    pause_screen
    return 1
  fi

  local inbound_json
  if ! inbound_json=$(jq -n \
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
    + (if $up > 0 and $down > 0 then {up_mbps: $up, down_mbps: $down} else {} end)'); then
    node_transaction_rollback "$txn"
    pause_screen
    return 1
  fi

  if ! config_add_inbound "$inbound_json"; then
    node_transaction_rollback "$txn"
    echo -e "${R}写入 inbound 失败${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 校验并启动...${N}"
  if ! config_check_and_restart "$PORT" udp; then
    node_transaction_rollback "$txn"
    echo ""
    echo -e "${R}sing-box 校验或重启失败${N}"
    pause_screen
    return 1
  fi

  # 先撤掉旧节点的跳跃规则；后续任一步失败由节点事务恢复。
  if [ "$old_hop" = "1" ] && [ -n "$old_hop_start" ] && [ -n "$old_hop_end" ]; then
    if ! port_hop_remove "$old_hop_start" "$old_hop_end" "$old_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧端口跳跃规则清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
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
      if ! port_hop_apply "$PORT" "$HOP_START" "$HOP_END" "$install_mode" "$listen_v4" "$listen_v6"; then
        node_transaction_rollback "$txn"
        echo -e "${R}端口跳跃规则应用失败，已完整回滚${N}"
        pause_screen
        return 1
      fi
      echo -e "  ${G}端口跳跃已启用：${HOP_START}-${HOP_END} (UDP)${N}"
    fi
  fi

  if [ -n "$old_port" ] && { [ "$old_port" != "$PORT" ] || [ "$old_mode" != "$install_mode" ]; }; then
    if ! node_revoke_firewall_for_mode "$old_port" udp "$old_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧端口防火墙清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi
  if ! node_apply_firewall_for_mode "$PORT" udp "$install_mode"; then
    node_transaction_rollback "$txn"
    echo -e "${R}防火墙放行失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
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

  if ! write_node_info_file hy2 <<EOF
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
UpMbps=$([ "$up_mbps" -gt 0 ] && printf '%s' "$up_mbps")
DownMbps=$([ "$down_mbps" -gt 0 ] && printf '%s' "$down_mbps")
PortHop=$HOP_ENABLE
PortHopMode=$HOP_MODE
PortHopStart=$HOP_START
PortHopEnd=$HOP_END
Link=$link
EOF
  then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if [ "$cert_source" = "acme" ]; then
    if ! rm -f -- "$CERTS_DIR/hy2.crt" "$CERTS_DIR/hy2.key"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧自签证书清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi
  node_transaction_commit "$txn"

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
  echo -e "  出站策略  : ${C}双栈（跟随系统路由）${N}"
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

  if ! uninstall_node_transaction hy2 hy2-in udp; then
    echo -e "${R}Hysteria2 节点卸载失败，已恢复原配置${N}"
    pause_screen
    return 1
  fi
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
  local txn=""

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
    if validate_port "$new_port"; then
      new_port=$((10#$new_port))
      if [ "$new_port" != "$cur_port" ] && check_port_in_use "$new_port" udp; then
        local force_port=""
        echo -e "${R}端口 ${new_port} 已被其他 UDP 服务占用${N}"
        read -p "  仍然使用此端口？(y/N): " force_port
        if [ "$force_port" != "y" ] && [ "$force_port" != "Y" ]; then
          continue
        fi
      fi
      break
    fi
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
      read -r new_hop_start new_hop_end < <(port_hop_compute_range "$new_port")
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
          read -r new_hop_start new_hop_end < <(port_hop_compute_range "$new_port")
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

  ensure_jq || { pause_screen; return 1; }
  txn=$(node_transaction_begin hy2) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  if ! cp "$CONFIG_PATH" "$backup_path"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置备份失败${N}"
    pause_screen
    return 1
  fi

  # 自签时若 SNI 改变，重签证书
  if [ "$cur_cert_src" = "self" ] && [ "$new_sni" != "$cur_sni" ]; then
    echo -e "${Y}==> SNI 变更，重新生成自签证书...${N}"
    if ! generate_self_signed_cert_for_hy2 "$new_sni" >/dev/null; then
      node_transaction_rollback "$txn"
      echo -e "${R}自签证书生成失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi

  local jq_filter='(.inbounds[] | select(.tag == "hy2-in"))
    |= ( .listen_port = ($port | tonumber)
       | .tls.server_name = $sni
       | if (.tls.acme | type) == "object"
         then .tls.certificate_provider = ({type: "acme"} + .tls.acme) | del(.tls.acme)
         else . end
       | if $sni != "" and (.tls.certificate_provider | type) == "object"
         then .tls.certificate_provider.domain = [$sni]
         else . end
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
  trap 'rm -f "$tmp_file"' RETURN
  if ! jq --arg port "$new_port" --arg sni "$new_sni" \
       --arg pw "${new_pw:-}" --arg opw "${new_obfs_pw:-}" \
       --arg bw_action "$bw_action" --arg up "$new_up" --arg down "$new_down" \
       "$jq_filter" "$CONFIG_PATH" > "$tmp_file"; then
    rm -f "$tmp_file"
    node_transaction_rollback "$txn"
    echo -e "${R}配置写入失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  if ! mv "$tmp_file" "$CONFIG_PATH"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置替换失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if ! config_check_and_restart "$new_port" udp; then
    node_transaction_rollback "$txn"
    echo ""
    echo -e "${R}配置校验或服务健康检查失败，已完整回滚${N}"
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
    if ! port_hop_remove "$cur_hop_start" "$cur_hop_end" "$cur_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧端口跳跃规则清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    echo -e "  ${D}旧端口跳跃规则已清理${N}"
  fi
  if [ "$new_hop" = "1" ] && [ -n "$new_hop_start" ] && [ -n "$new_hop_end" ]; then
    local listen_v4="" listen_v6="" public_ipv6_now="" addrs_pair
    public_ipv6_now=$(detect_primary_ipv6 2>/dev/null || true)
    addrs_pair=$(port_hop_listen_addrs_for_mode "$cur_mode" "$public_ipv6_now")
    listen_v4="${addrs_pair%|*}"
    listen_v6="${addrs_pair#*|}"
    if ! port_hop_apply "$new_port" "$new_hop_start" "$new_hop_end" "$cur_mode" "$listen_v4" "$listen_v6"; then
      node_transaction_rollback "$txn"
      echo -e "${R}新端口跳跃规则应用失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    echo -e "  ${G}新端口跳跃规则已应用：${new_hop_start}-${new_hop_end}${N}"
  fi

  if [ -n "$new_port" ] && [ "$new_port" != "$cur_port" ]; then
    if [ -n "$cur_port" ] && ! node_revoke_firewall_for_mode "$cur_port" udp "$cur_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧防火墙端口清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    if ! node_apply_firewall_for_mode "$new_port" udp "$cur_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}防火墙端口切换失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    print_firewall_hint "$new_port" udp "Hysteria2 节点新端口"
  fi

  # 写回 hy2.info
  if ! set_node_value hy2 Port "$new_port" || ! set_node_value hy2 SNI "$new_sni"; then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  if [ -n "$new_pw" ] && ! set_node_value hy2 Password "$new_pw"; then
    node_transaction_rollback "$txn"
    echo -e "${R}节点密码保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  if [ -n "$new_obfs_pw" ] && ! set_node_value hy2 ObfsPassword "$new_obfs_pw"; then
    node_transaction_rollback "$txn"
    echo -e "${R}混淆密码保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  case "$bw_action" in
    set)
      if ! set_node_value hy2 UpMbps "$new_up" || ! set_node_value hy2 DownMbps "$new_down"; then
        node_transaction_rollback "$txn"
        echo -e "${R}带宽参数保存失败，已完整回滚${N}"
        pause_screen
        return 1
      fi
      ;;
    unset)
      # 清空（以空字符串覆盖；后续读取会判空）
      if ! set_node_value hy2 UpMbps "" || ! set_node_value hy2 DownMbps ""; then
        node_transaction_rollback "$txn"
        echo -e "${R}带宽参数保存失败，已完整回滚${N}"
        pause_screen
        return 1
      fi
      ;;
  esac
  if [ "$new_hop" = "1" ]; then
    if ! set_node_value hy2 PortHop "1" \
       || ! set_node_value hy2 PortHopMode "$new_hop_mode" \
       || ! set_node_value hy2 PortHopStart "$new_hop_start" \
       || ! set_node_value hy2 PortHopEnd "$new_hop_end"; then
      node_transaction_rollback "$txn"
      echo -e "${R}端口跳跃信息保存失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  else
    if ! set_node_value hy2 PortHop "0" \
       || ! set_node_value hy2 PortHopMode "" \
       || ! set_node_value hy2 PortHopStart "" \
       || ! set_node_value hy2 PortHopEnd ""; then
      node_transaction_rollback "$txn"
      echo -e "${R}端口跳跃信息保存失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
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
  if [ -n "$new_link" ] && ! set_node_value hy2 Link "$new_link"; then
    node_transaction_rollback "$txn"
    echo -e "${R}客户端链接保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  node_transaction_commit "$txn"
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

# ─── AnyTLS + Reality 节点（独立 Reality 密钥对） ────────
# 设计：
#   * 独立生成 private_key / public_key / short_id，与 reality 节点互不依赖
#   * 可与 reality 节点共存（端口独立）；也可单独安装，无前置依赖
#   * 默认 SNI 若检测到 reality 已装则沿用其 SNI（仅 UI 默认值，不影响协议）
#   * sing-box 1.12+ 才支持 type: "anytls"
#   * 不写 padding_scheme，使用 anytls-go 内置默认填充规则
# ═══ source: 53-nodes-anytls-tuic.sh ═══
install_anytls_node(){
  local port_input="" sni_input=""
  local access_ip="" link="" ipv6_link=""
  local public_ipv4="" public_ipv6=""
  local install_mode="ipv4" mode_label=""
  local PORT SNI TAG LISTEN_CHOICE LISTEN_ADDR PASSWORD confirm
  local default_port default_sni keypair private_key public_key short_id
  local txn="" old_port="" old_mode="ipv4"

  if ! require_root; then return 1; fi

  render_section_header "创建 AnyTLS 节点"
  echo -e "  ${Y}AnyTLS + Reality（独立 Reality 密钥对，与其他节点互不影响）${N}"
  echo -e "  ${Y}直接回车使用括号内默认值${N}"
  echo ""

  # ── sing-box 必须已安装且 >= 1.12
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
  if ! sb_version_at_least 1.12; then
    local cur_ver
    cur_ver=$(get_current_singbox_version)
    echo ""
    echo -e "${R}AnyTLS 协议需要 sing-box ≥ 1.12，当前版本: ${cur_ver:-未知}${N}"
    echo -e "${Y}请先在「主菜单 → 更新管理 → 升级 sing-box 内核」中升级后再创建 AnyTLS 节点${N}"
    pause_screen
    return 1
  fi

  if node_installed anytls; then
    echo -e "${Y}检测到已存在 AnyTLS 节点，继续将覆盖原节点配置${N}"
    read -p "  继续？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo -e "  已取消"
      return 0
    fi
    old_port=$(get_node_value anytls Port 2>/dev/null || true)
    old_mode=$(get_node_value anytls Mode 2>/dev/null || echo ipv4)
  fi

  # ── 端口（默认随机，避开 reality 端口与已占端口）
  default_port=$(generate_anytls_random_port)
  while true; do
    read -p "  端口 (${default_port}): " port_input
    PORT="${port_input:-$default_port}"
    if ! validate_port "$PORT"; then
      echo -e "${R}端口必须是 1-65535 的数字${N}"
      continue
    fi
    PORT=$((10#$PORT))
    local reality_port
    reality_port=$(get_node_value reality Port 2>/dev/null || true)
    if [ -n "$reality_port" ] && [ "$PORT" -eq "$reality_port" ]; then
      echo -e "${R}端口与 Reality 节点冲突（Reality 已使用 ${reality_port}）${N}"
      continue
    fi
    if [ "$PORT" != "$old_port" ] && check_port_in_use "$PORT" tcp; then
      echo -e "${R}端口 ${PORT} 已被其他服务占用${N}"
      local force_port=""
      read -p "  仍然使用此端口？(y/N): " force_port
      if [ "$force_port" != "y" ] && [ "$force_port" != "Y" ]; then
        continue
      fi
    fi
    break
  done

  # ── SNI（默认 tesla.com；若已装 Reality，沿用其 SNI 提升伪装一致性）
  default_sni=$(get_node_value reality SNI 2>/dev/null || true)
  default_sni="${default_sni:-www.tesla.com}"
  while true; do
    read -p "  域名 (${default_sni}): " sni_input
    sni_input="${sni_input:-$default_sni}"
    SNI=$(sanitize_sni "$sni_input")
    if [ -n "$SNI" ]; then
      break
    fi
    echo -e "${R}域名不能为空，且不能只包含引号或换行${N}"
  done

  read -p "  节点名称 (anytls): " TAG
  TAG="${TAG:-anytls}"

  echo -e "  监听模式："
  echo "    1) 仅 IPv4 入站 - 0.0.0.0（默认）"
  echo "    2) 双栈入站 - ::"
  echo "    3) 仅 IPv6 入站"
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
      echo -e "${R}未检测到可用的 IPv6 地址，无法使用“仅 IPv6 入站”模式${N}"
      pause_screen
      return 1
    fi
  fi

  echo -e "${Y}==> 生成 Reality 密钥对 / ShortID...${N}"
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
  short_id=$(openssl rand -hex 4)

  echo -e "${Y}==> 生成 AnyTLS 用户密码...${N}"
  PASSWORD=$(cat /proc/sys/kernel/random/uuid)

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
  txn=$(node_transaction_begin anytls) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

  local inbound_json
  inbound_json=$(jq -n \
    --arg listen "$LISTEN_ADDR" \
    --argjson port "$PORT" \
    --arg password "$PASSWORD" \
    --arg sni "$SNI" \
    --arg priv "$private_key" \
    --arg sid "$short_id" '{
      type: "anytls",
      tag: "anytls-in",
      listen: $listen,
      listen_port: $port,
      users: [{name: "default", password: $password}],
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
    node_transaction_rollback "$txn"
    echo -e "${R}写入 inbound 失败${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 校验并启动...${N}"
  if ! config_check_and_restart "$PORT" tcp; then
    node_transaction_rollback "$txn"
    echo ""
    echo -e "${R}sing-box 校验或重启失败${N}"
    pause_screen
    return 1
  fi

  if ! node_apply_firewall_for_mode "$PORT" tcp "$install_mode"; then
    node_transaction_rollback "$txn"
    echo -e "${R}防火墙放行失败，节点配置已回滚${N}"
    pause_screen
    return 1
  fi
  print_firewall_hint "$PORT" tcp "AnyTLS 节点入站"

  link=$(build_anytls_link "$PASSWORD" "$access_ip" "$PORT" "$SNI" "$public_key" "$short_id" "$TAG" 2>/dev/null || true)
  if [ "$install_mode" = "dualstack" ] && [ -n "$public_ipv6" ] && [ "$public_ipv6" != "$access_ip" ]; then
    ipv6_link=$(build_anytls_link "$PASSWORD" "$public_ipv6" "$PORT" "$SNI" "$public_key" "$short_id" "${TAG}-ipv6" 2>/dev/null || true)
  fi

  if ! write_node_info_file anytls <<EOF
Type=anytls
Tag=$TAG
Mode=$install_mode
ListenAddr=$LISTEN_ADDR
Port=$PORT
SNI=$SNI
Password=$PASSWORD
PublicKey=$public_key
PrivateKey=$private_key
ShortID=$short_id
IP=$access_ip
Link=$link
EOF
  then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if [ -n "$old_port" ] && [ "$old_port" != "$PORT" ]; then
    if ! node_revoke_firewall_for_mode "$old_port" tcp "$old_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧端口防火墙清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi
  node_transaction_commit "$txn"

  register_sb_command || true

  echo ""
  echo -e "  ${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "  ${G}║${N}  ${B}${W}${APP_NAME}${N}  ${G}AnyTLS 节点创建完成${N}                        ${G}║${N}"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${N}"
  echo -e "  模式      : ${C}$mode_label${N}"
  echo -e "  Password  : ${C}$PASSWORD${N}"
  echo -e "  PublicKey : ${C}$public_key${N}"
  echo -e "  IP        : ${C}$access_ip${N}"
  echo -e "  端口      : ${C}$PORT${N} ${D}(TCP)${N}"
  echo -e "  SNI       : ${C}$SNI${N}"
  if [ -n "$link" ]; then
    echo ""
    echo -e "  ${B}客户端链接：${N}"
    echo -e "  ${G}$link${N}"
    print_qrcode "$link"
  fi
  if [ -n "$ipv6_link" ]; then
    echo ""
    echo -e "  ${B}IPv6 客户端链接：${N}"
    echo -e "  ${G}$ipv6_link${N}"
    print_qrcode "$ipv6_link"
  fi
  echo ""
  echo -e "  ${Y}注意：AnyTLS + Reality 仅 sing-box 1.12+ / Xray-core 25.x+ 客户端支持${N}"
  echo -e "  ${D}      Mihomo / Clash 系客户端目前不支持${N}"
  echo -e "  信息已保存至 ${Y}$(node_info_path anytls)${N}"
  pause_screen
}

install_tuic_node(){
  local port_input="" sni_input=""
  local PORT SNI TAG LISTEN_CHOICE LISTEN_ADDR install_mode="ipv4"
  local cert_choice cert_source="self" acme_email=""
  local UUID PASSWORD cc_choice CC="bbr"
  local public_ipv4="" public_ipv6="" access_ip=""
  local link="" ipv6_link="" mode_label="" confirm
  local cert_paths cert_path key_path
  local txn="" old_port="" old_mode="ipv4"

  if ! require_root; then return 1; fi

  render_section_header "创建 TUIC v5 节点"
  echo -e "  ${Y}直接回车使用括号内默认值${N}"
  echo ""

  if node_installed tuic; then
    echo -e "${Y}检测到已存在 TUIC 节点，继续将覆盖原节点配置${N}"
    read -p "  继续？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo -e "  已取消"
      return 0
    fi
    old_port=$(get_node_value tuic Port 2>/dev/null || true)
    old_mode=$(get_node_value tuic Mode 2>/dev/null || echo ipv4)
  fi

  # 端口（默认随机高位 UDP，复用 hy2 的端口生成器）
  local default_port
  default_port=$(generate_hy2_random_port)
  while true; do
    read -p "  端口 (${default_port}, 回车随机): " port_input
    PORT="${port_input:-$default_port}"
    if validate_port "$PORT"; then
      PORT=$((10#$PORT))
      if [ "$PORT" != "$old_port" ] && check_port_in_use "$PORT" udp; then
        echo -e "${R}UDP 端口 ${PORT} 已被其他服务占用${N}"
        local force_port=""
        read -p "  仍然使用此端口？(y/N): " force_port
        if [ "$force_port" != "y" ] && [ "$force_port" != "Y" ]; then
          continue
        fi
      fi
      break
    fi
    echo -e "${R}端口必须是 1-65535 的数字${N}"
  done

  # 节点名
  read -p "  节点名称 (tuic): " TAG
  TAG="${TAG:-tuic}"

  # 监听模式
  echo -e "  监听模式："
  echo "    1) 仅 IPv4 入站 - 0.0.0.0（默认）"
  echo "    2) 双栈入站 - ::"
  echo "    3) 仅 IPv6 入站"
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
      echo -e "${R}未检测到可用的 IPv6 地址，无法使用“仅 IPv6 入站”模式${N}"
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

  # 拥塞控制
  echo -e "  拥塞控制算法："
  echo "    1) bbr   （默认，推荐，多数场景速度最快）"
  echo "    2) cubic （对 TCP 友好，与其他流量并存时更平稳）"
  read -p "  请选择 (1): " cc_choice
  case "$cc_choice" in
    2) CC="cubic" ;;
    *) CC="bbr" ;;
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
  UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
  if [ -z "$UUID" ] && command -v sing-box >/dev/null 2>&1; then
    UUID=$(sing-box generate uuid 2>/dev/null)
  fi
  if [ -z "$UUID" ]; then
    echo -e "${R}UUID 生成失败${N}"
    pause_screen
    return 1
  fi
  PASSWORD=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-22)

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

  echo -e "${Y}==> 建立节点事务快照...${N}"
  ensure_jq || { pause_screen; return 1; }
  txn=$(node_transaction_begin tuic) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

  # 准备证书
  if [ "$cert_source" = "self" ]; then
    echo -e "${Y}==> 生成自签证书...${N}"
    if ! cert_paths=$(generate_self_signed_cert_for_tuic "$SNI"); then
      node_transaction_rollback "$txn"
      pause_screen
      return 1
    fi
    cert_path=$(echo "$cert_paths" | sed -n '1p')
    key_path=$(echo "$cert_paths" | sed -n '2p')
  fi

  echo -e "${Y}==> 写入配置...${N}"

  local tls_json
  if [ "$cert_source" = "acme" ]; then
    if ! tls_json=$(jq -n --arg sni "$SNI" --arg email "$acme_email" '{
      enabled: true,
      server_name: $sni,
      alpn: ["h3"],
      certificate_provider: {type: "acme", domain: [$sni], email: $email}
    }'); then
      node_transaction_rollback "$txn"
      pause_screen
      return 1
    fi
  else
    if ! tls_json=$(jq -n --arg sni "$SNI" --arg crt "$cert_path" --arg key "$key_path" '{
      enabled: true,
      server_name: $sni,
      alpn: ["h3"],
      certificate_path: $crt,
      key_path: $key
    }'); then
      node_transaction_rollback "$txn"
      pause_screen
      return 1
    fi
  fi

  local user_obj
  if ! user_obj=$(jq -n --arg uuid "$UUID" --arg pw "$PASSWORD" '{uuid: $uuid, password: $pw}'); then
    node_transaction_rollback "$txn"
    pause_screen
    return 1
  fi

  local inbound_json
  if ! inbound_json=$(jq -n \
    --arg listen "$LISTEN_ADDR" \
    --argjson port "$PORT" \
    --argjson user "$user_obj" \
    --argjson tls "$tls_json" \
    --arg cc "$CC" '
    {
      type: "tuic",
      tag: "tuic-in",
      listen: $listen,
      listen_port: $port,
      users: [$user],
      congestion_control: $cc,
      auth_timeout: "3s",
      zero_rtt_handshake: false,
      heartbeat: "10s",
      tls: $tls
    }'); then
    node_transaction_rollback "$txn"
    pause_screen
    return 1
  fi

  if ! config_add_inbound "$inbound_json"; then
    node_transaction_rollback "$txn"
    echo -e "${R}写入 inbound 失败${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 校验并启动...${N}"
  if ! config_check_and_restart "$PORT" udp; then
    node_transaction_rollback "$txn"
    echo ""
    echo -e "${R}sing-box 校验或重启失败${N}"
    pause_screen
    return 1
  fi

  if [ -n "$old_port" ] && { [ "$old_port" != "$PORT" ] || [ "$old_mode" != "$install_mode" ]; }; then
    if ! node_revoke_firewall_for_mode "$old_port" udp "$old_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧端口防火墙清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi
  if ! node_apply_firewall_for_mode "$PORT" udp "$install_mode"; then
    node_transaction_rollback "$txn"
    echo -e "${R}防火墙放行失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  print_firewall_hint "$PORT" udp "TUIC v5 节点入站"
  if [ "$cert_source" = "acme" ]; then
    print_firewall_hint 80 tcp "ACME 证书签发与续期，签发期间必须可外部访问"
  fi

  local insecure="0"
  [ "$cert_source" = "self" ] && insecure="1"

  link=$(build_tuic_link "$UUID" "$PASSWORD" "$access_ip" "$PORT" "$SNI" "$insecure" "$CC" "$TAG" 2>/dev/null || true)
  if [ "$install_mode" = "dualstack" ] && [ -n "$public_ipv6" ] && [ "$public_ipv6" != "$access_ip" ]; then
    ipv6_link=$(build_tuic_link "$UUID" "$PASSWORD" "$public_ipv6" "$PORT" "$SNI" "$insecure" "$CC" "${TAG}-ipv6" 2>/dev/null || true)
  fi

  if ! write_node_info_file tuic <<EOF
Type=tuic
Tag=$TAG
Mode=$install_mode
ListenAddr=$LISTEN_ADDR
Port=$PORT
SNI=$SNI
CertSource=$cert_source
ACMEEmail=$acme_email
CertPath=${cert_path:-}
KeyPath=${key_path:-}
UUID=$UUID
Password=$PASSWORD
CongestionControl=$CC
Insecure=$insecure
IP=$access_ip
Link=$link
EOF
  then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if [ "$cert_source" = "acme" ]; then
    if ! rm -f -- "$CERTS_DIR/tuic.crt" "$CERTS_DIR/tuic.key"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧自签证书清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi
  node_transaction_commit "$txn"

  register_sb_command || true

  echo ""
  echo -e "  ${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "  ${G}║${N}  ${B}${W}${APP_NAME}${N}  ${G}TUIC v5 节点创建完成${N}                       ${G}║${N}"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${N}"
  echo -e "  模式      : ${C}$mode_label${N}"
  echo -e "  端口      : ${C}$PORT${N} ${D}(UDP)${N}"
  echo -e "  入口 IP   : ${C}${access_ip:-未知}${N}"
  echo -e "  SNI       : ${C}$SNI${N}"
  echo -e "  证书      : ${C}${cert_source}${N}$([ "$insecure" = "1" ] && echo "  ${Y}(客户端需 insecure=1)${N}")"
  echo -e "  UUID      : ${C}$UUID${N}"
  echo -e "  Password  : ${C}$PASSWORD${N}"
  echo -e "  拥塞控制  : ${C}$CC${N}"
  echo -e "  出站策略  : ${C}双栈（跟随系统路由）${N}"
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
  echo -e "  信息已保存至 ${Y}$(node_info_path tuic)${N}"
  echo -e "  输入 ${B}${COMMAND_NAME}${N} 进入管理菜单"
  pause_screen
}

uninstall_anytls_node(){
  local confirm
  if ! node_installed anytls; then
    echo -e "${Y}AnyTLS 节点未安装${N}"
    pause_screen
    return 0
  fi
  echo ""
  read -p "  确认卸载 AnyTLS 节点？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  if ! uninstall_node_transaction anytls anytls-in tcp; then
    echo -e "${R}AnyTLS 节点卸载失败，已恢复原配置${N}"
    pause_screen
    return 1
  fi
  echo -e "${G}AnyTLS 节点已卸载${N}"
  pause_screen
}

uninstall_tuic_node(){
  local confirm
  if ! node_installed tuic; then
    echo -e "${Y}TUIC 节点未安装${N}"
    pause_screen
    return 0
  fi
  echo ""
  read -p "  确认卸载 TUIC 节点？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  if ! uninstall_node_transaction tuic tuic-in udp; then
    echo -e "${R}TUIC 节点卸载失败，已恢复原配置${N}"
    pause_screen
    return 1
  fi
  echo -e "${G}TUIC 节点已卸载${N}"
  pause_screen
}

# ─── Shadowsocks-2022 ─────────────────────────────────
# 抗主动探测能力弱于 Reality / Hysteria2，菜单中标记为 [谨慎]
# ═══ source: 54-node-ss2022.sh ═══
generate_ss2022_random_port(){
  local p attempts=0
  while [ $attempts -lt 30 ]; do
    p=$(( (RANDOM << 15 | RANDOM) % 45535 + 20000 ))
    attempts=$((attempts + 1))
    if ! check_port_in_use "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  printf '%s' "$p"
}

# SS-2022 密钥长度由加密方式决定：
#   2022-blake3-aes-128-gcm        → 16 bytes
#   2022-blake3-aes-256-gcm        → 32 bytes
#   2022-blake3-chacha20-poly1305  → 32 bytes
generate_ss2022_password(){
  local method="${1:-2022-blake3-aes-128-gcm}"
  local bytes=16
  case "$method" in
    *aes-128-gcm)                       bytes=16 ;;
    *aes-256-gcm|*chacha20-poly1305)    bytes=32 ;;
  esac
  if ! command -v openssl >/dev/null 2>&1; then
    return 1
  fi
  openssl rand -base64 "$bytes" | tr -d '\r\n'
}

install_ss2022_node(){
  local port_input=""
  local access_ip="" link="" ipv6_link=""
  local public_ipv4="" public_ipv6=""
  local install_mode="ipv4" mode_label=""
  local PORT TAG LISTEN_CHOICE LISTEN_ADDR METHOD PASSWORD METHOD_CHOICE confirm
  local default_port
  local txn="" old_port="" old_mode="ipv4"

  if ! require_root; then return 1; fi

  render_section_header "创建 Shadowsocks-2022 节点"
  echo -e "  ${R}⚠ 谨慎：SS-2022 抗主动探测能力弱于 Reality / Hysteria2${N}"
  echo -e "  ${R}  在被高强度 GFW 主动探测的链路上更容易被识别${N}"
  echo -e "  ${D}  建议仅在低风险环境（落地中转 / 跨境企业线路）使用${N}"
  echo -e "  ${Y}直接回车使用括号内默认值${N}"
  echo ""

  if node_installed ss2022; then
    echo -e "${Y}检测到已存在 Shadowsocks-2022 节点，继续将覆盖原节点配置${N}"
    read -p "  继续？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo -e "  已取消"
      return 0
    fi
    old_port=$(get_node_value ss2022 Port 2>/dev/null || true)
    old_mode=$(get_node_value ss2022 Mode 2>/dev/null || echo ipv4)
  fi

  default_port=$(generate_ss2022_random_port)
  while true; do
    read -p "  端口 (${default_port}): " port_input
    PORT="${port_input:-$default_port}"
    if ! validate_port "$PORT"; then
      echo -e "${R}端口必须是 1-65535 的数字${N}"
      continue
    fi
    PORT=$((10#$PORT))
    if [ "$PORT" != "$old_port" ] && check_port_in_use "$PORT" tcp; then
      echo -e "${R}端口 ${PORT} 已被其他服务占用${N}"
      local force_port=""
      read -p "  仍然使用此端口？(y/N): " force_port
      if [ "$force_port" != "y" ] && [ "$force_port" != "Y" ]; then
        continue
      fi
    fi
    break
  done

  read -p "  节点名称 (ss2022): " TAG
  TAG="${TAG:-ss2022}"

  echo -e "  加密方式："
  echo -e "    1) 2022-blake3-aes-128-gcm        ${D}(默认，AES-NI 性能最佳)${N}"
  echo -e "    2) 2022-blake3-aes-256-gcm        ${D}(更高安全冗余，CPU 开销略增)${N}"
  echo -e "    3) 2022-blake3-chacha20-poly1305  ${D}(无 AES 硬件加速时更快)${N}"
  read -p "  请选择 (1): " METHOD_CHOICE
  case "$METHOD_CHOICE" in
    2) METHOD="2022-blake3-aes-256-gcm" ;;
    3) METHOD="2022-blake3-chacha20-poly1305" ;;
    *) METHOD="2022-blake3-aes-128-gcm" ;;
  esac

  echo -e "  监听模式："
  echo "    1) 仅 IPv4 入站 - 0.0.0.0（默认）"
  echo "    2) 双栈入站 - ::"
  echo "    3) 仅 IPv6 入站"
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
      echo -e "${R}未检测到可用的 IPv6 地址，无法使用“仅 IPv6 入站”模式${N}"
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

  echo -e "${Y}==> 生成 SS-2022 密钥...${N}"
  PASSWORD=$(generate_ss2022_password "$METHOD")
  if [ -z "$PASSWORD" ]; then
    echo ""
    echo -e "${R}密钥生成失败（缺少 openssl?）${N}"
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
  txn=$(node_transaction_begin ss2022) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

  # network=tcp 屏蔽 UDP relay：减小攻击面，单一 TCP 防火墙规则
  local inbound_json
  inbound_json=$(jq -n \
    --arg listen "$LISTEN_ADDR" \
    --argjson port "$PORT" \
    --arg method "$METHOD" \
    --arg password "$PASSWORD" '{
      type: "shadowsocks",
      tag: "ss2022-in",
      listen: $listen,
      listen_port: $port,
      network: "tcp",
      method: $method,
      password: $password
    }')

  if ! config_add_inbound "$inbound_json"; then
    node_transaction_rollback "$txn"
    echo -e "${R}写入 inbound 失败${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 校验并启动...${N}"
  if ! config_check_and_restart "$PORT" tcp; then
    node_transaction_rollback "$txn"
    echo ""
    echo -e "${R}sing-box 校验或重启失败${N}"
    pause_screen
    return 1
  fi

  if ! node_apply_firewall_for_mode "$PORT" tcp "$install_mode"; then
    node_transaction_rollback "$txn"
    echo -e "${R}防火墙放行失败，节点配置已回滚${N}"
    pause_screen
    return 1
  fi
  print_firewall_hint "$PORT" tcp "Shadowsocks-2022 节点入站"

  link=$(build_ss2022_link "$METHOD" "$PASSWORD" "$access_ip" "$PORT" "$TAG" 2>/dev/null || true)
  if [ "$install_mode" = "dualstack" ] && [ -n "$public_ipv6" ] && [ "$public_ipv6" != "$access_ip" ]; then
    ipv6_link=$(build_ss2022_link "$METHOD" "$PASSWORD" "$public_ipv6" "$PORT" "${TAG}-ipv6" 2>/dev/null || true)
  fi

  if ! write_node_info_file ss2022 <<EOF
Type=ss2022
Tag=$TAG
Mode=$install_mode
ListenAddr=$LISTEN_ADDR
Port=$PORT
Method=$METHOD
Password=$PASSWORD
IP=$access_ip
Link=$link
EOF
  then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if [ -n "$old_port" ] && [ "$old_port" != "$PORT" ]; then
    if ! node_revoke_firewall_for_mode "$old_port" tcp "$old_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}旧端口防火墙清理失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi
  node_transaction_commit "$txn"

  register_sb_command || true

  echo ""
  echo -e "  ${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "  ${G}║${N}  ${B}${W}${APP_NAME}${N}  ${G}Shadowsocks-2022 节点创建完成${N}              ${G}║${N}"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${N}"
  echo -e "  模式      : ${C}$mode_label${N}"
  echo -e "  加密方式  : ${C}$METHOD${N}"
  echo -e "  Password  : ${C}$PASSWORD${N}"
  echo -e "  入口 IP   : ${C}${access_ip:-未知}${N}"
  echo -e "  端口      : ${C}$PORT${N} ${D}(TCP)${N}"
  if [ -n "$link" ]; then
    echo ""
    echo -e "  ${B}客户端链接：${N}"
    echo -e "  ${G}$link${N}"
    print_qrcode "$link"
  fi
  if [ -n "$ipv6_link" ]; then
    echo ""
    echo -e "  ${B}IPv6 客户端链接：${N}"
    echo -e "  ${G}$ipv6_link${N}"
    print_qrcode "$ipv6_link"
  fi
  echo ""
  echo -e "  ${R}⚠ SS-2022 抗主动探测较弱，建议结合 CDN / 中转或仅在低风险环境使用${N}"
  echo -e "  ${D}  默认仅启用 TCP；如需 UDP relay 请手动编辑 /etc/sing-box/config.json${N}"
  echo -e "  信息已保存至 ${Y}$(node_info_path ss2022)${N}"
  echo -e "  输入 ${B}${COMMAND_NAME}${N} 进入管理菜单"
  pause_screen
}

uninstall_ss2022_node(){
  local confirm
  if ! node_installed ss2022; then
    echo -e "${Y}Shadowsocks-2022 节点未安装${N}"
    pause_screen
    return 0
  fi
  echo ""
  read -p "  确认卸载 Shadowsocks-2022 节点？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  if ! uninstall_node_transaction ss2022 ss2022-in tcp; then
    echo -e "${R}Shadowsocks-2022 节点卸载失败，已恢复原配置${N}"
    pause_screen
    return 1
  fi
  echo -e "${G}Shadowsocks-2022 节点已卸载${N}"
  pause_screen
}
# ═══ source: 56-modify-params.sh ═══
modify_ss2022_params(){
  local new_port="" new_method="" new_tag=""
  local cur_port cur_method cur_tag cur_password regen_choice
  local backup_path="" confirm new_password="" txn=""

  if ! require_root; then return 1; fi
  if ! require_singbox_installed; then return 1; fi
  if ! node_installed ss2022; then
    echo ""
    echo -e "${R}未发现 Shadowsocks-2022 节点信息${N}"
    pause_screen
    return 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到配置文件：$CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  cur_port=$(get_node_value ss2022 Port 2>/dev/null || true)
  cur_method=$(get_node_value ss2022 Method 2>/dev/null || echo 2022-blake3-aes-128-gcm)
  cur_tag=$(get_node_value ss2022 Tag 2>/dev/null || echo ss2022)
  cur_password=$(get_node_value ss2022 Password 2>/dev/null || true)

  render_section_header "修改 Shadowsocks-2022 节点"
  echo -e "  ${Y}留空回车则保留当前值${N}"
  echo ""

  while true; do
    read -p "  端口 (${cur_port}): " new_port
    new_port="${new_port:-$cur_port}"
    if ! validate_port "$new_port"; then
      echo -e "${R}端口必须是 1-65535 的数字${N}"
      continue
    fi
    new_port=$((10#$new_port))
    if [ "$new_port" != "$cur_port" ] && check_port_in_use "$new_port"; then
      echo -e "${R}端口 ${new_port} 已被其他服务占用${N}"
      local force_port=""
      read -p "  仍然使用此端口？(y/N): " force_port
      if [ "$force_port" != "y" ] && [ "$force_port" != "Y" ]; then
        continue
      fi
    fi
    break
  done

  echo -e "  加密方式 (当前: ${C}${cur_method}${N})："
  echo -e "    0) 保持不变（默认）"
  echo -e "    1) 2022-blake3-aes-128-gcm"
  echo -e "    2) 2022-blake3-aes-256-gcm"
  echo -e "    3) 2022-blake3-chacha20-poly1305"
  read -p "  请选择 (0): " METHOD_CHOICE
  case "$METHOD_CHOICE" in
    1) new_method="2022-blake3-aes-128-gcm" ;;
    2) new_method="2022-blake3-aes-256-gcm" ;;
    3) new_method="2022-blake3-chacha20-poly1305" ;;
    *) new_method="$cur_method" ;;
  esac

  read -p "  节点名称 (${cur_tag}): " new_tag
  new_tag="${new_tag:-$cur_tag}"

  # 改加密方式必须重新生成密钥（密钥长度可能变）
  if [ "$new_method" != "$cur_method" ]; then
    echo -e "  ${Y}加密方式已变更，将自动重新生成密钥${N}"
    regen_choice="y"
  else
    read -p "  重新生成密钥？(y/N): " regen_choice
  fi

  if [ "$regen_choice" = "y" ] || [ "$regen_choice" = "Y" ]; then
    new_password=$(generate_ss2022_password "$new_method")
    if [ -z "$new_password" ]; then
      echo -e "${R}密钥生成失败${N}"
      pause_screen
      return 1
    fi
  else
    new_password="$cur_password"
  fi

  echo ""
  echo -e "  即将写入："
  echo -e "    端口      : ${C}${new_port}${N}"
  echo -e "    加密方式  : ${C}${new_method}${N}"
  echo -e "    Tag       : ${C}${new_tag}${N}"
  if [ "$new_password" != "$cur_password" ]; then
    echo -e "    Password  : ${C}${new_password}${N} ${Y}(已更新)${N}"
  else
    echo -e "    Password  : ${D}保持不变${N}"
  fi
  read -p "  确认应用？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  ensure_jq || { pause_screen; return 1; }
  txn=$(node_transaction_begin ss2022) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }
  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
  if ! cp "$CONFIG_PATH" "$backup_path"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置备份失败${N}"
    pause_screen
    return 1
  fi

  local cur_listen cur_mode
  cur_listen=$(get_node_value ss2022 ListenAddr 2>/dev/null || echo "0.0.0.0")
  cur_mode=$(get_node_value ss2022 Mode 2>/dev/null || echo ipv4)

  local inbound_json
  if ! inbound_json=$(jq -n \
    --arg listen "$cur_listen" \
    --argjson port "$new_port" \
    --arg method "$new_method" \
    --arg password "$new_password" '{
      type: "shadowsocks",
      tag: "ss2022-in",
      listen: $listen,
      listen_port: $port,
      network: "tcp",
      method: $method,
      password: $password
    }'); then
    node_transaction_rollback "$txn"
    echo -e "${R}节点配置生成失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if ! config_add_inbound "$inbound_json"; then
    node_transaction_rollback "$txn"
    echo -e "${R}写入 inbound 失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if ! config_check_and_restart "$new_port" tcp; then
    node_transaction_rollback "$txn"
    echo -e "${R}sing-box 校验或健康检查失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  # 端口变化时同步防火墙
  if [ "$new_port" != "$cur_port" ]; then
    if ! node_revoke_firewall_for_mode "$cur_port" tcp "$cur_mode" \
       || ! node_apply_firewall_for_mode "$new_port" tcp "$cur_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}防火墙端口切换失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    print_firewall_hint "$new_port" tcp "Shadowsocks-2022 节点入站"
  fi

  if ! set_node_value ss2022 Port "$new_port" \
     || ! set_node_value ss2022 Method "$new_method" \
     || ! set_node_value ss2022 Tag "$new_tag" \
     || ! set_node_value ss2022 Password "$new_password"; then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  local cur_ip new_link ipv6_new_link
  cur_ip=$(get_node_value ss2022 IP 2>/dev/null || true)
  new_link=$(build_ss2022_link "$new_method" "$new_password" "$cur_ip" "$new_port" "$new_tag" 2>/dev/null || true)
  ipv6_new_link=$(build_dualstack_ipv6_link_for_node ss2022 2>/dev/null || true)
  if [ -n "$new_link" ] && ! set_node_value ss2022 Link "$new_link"; then
    node_transaction_rollback "$txn"
    echo -e "${R}客户端链接保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  node_transaction_commit "$txn"
  cleanup_old_backups "${CONFIG_PATH}.bak.*" 5 \
    || echo -e "${Y}旧配置备份自动清理失败，可稍后从备份菜单处理${N}"

  echo ""
  echo -e "  ${G}修改完成${N}"
  if [ -n "$new_link" ]; then
    echo ""
    echo -e "  ${B}新客户端链接：${N}"
    echo -e "  ${G}${new_link}${N}"
    print_qrcode "$new_link"
  fi
  if [ -n "$ipv6_new_link" ]; then
    echo ""
    echo -e "  ${B}新 IPv6 客户端链接：${N}"
    echo -e "  ${G}${ipv6_new_link}${N}"
    print_qrcode "$ipv6_new_link"
  fi
  echo ""
  echo -e "  备份: ${Y}${backup_path}${N}"
  pause_screen
}

modify_anytls_params(){
  local new_port="" new_sni="" new_pw="" new_tag=""
  local cur_port cur_sni cur_pw cur_tag backup_path="" confirm txn=""

  if ! require_root; then return 1; fi
  if ! require_singbox_installed; then return 1; fi
  if ! node_installed anytls; then
    echo ""
    echo -e "${R}未发现 AnyTLS 节点信息${N}"
    pause_screen
    return 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到配置文件：$CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  cur_port=$(get_node_value anytls Port 2>/dev/null || true)
  cur_sni=$(get_node_value anytls SNI 2>/dev/null || true)
  cur_pw=$(get_node_value anytls Password 2>/dev/null || true)
  cur_tag=$(get_node_value anytls Tag 2>/dev/null || echo anytls)

  echo ""
  echo -e "  ${B}${C}修改 AnyTLS 节点参数${N}  ${D}直接回车保留当前值${N}"
  echo -e "  ${D}（如需轮换密钥对 / ShortID，请卸载后重新安装节点）${N}"
  render_divider

  while true; do
    read -p "  端口 (${cur_port:-当前未知}): " new_port
    new_port="${new_port:-$cur_port}"
    if ! validate_port "$new_port"; then
      echo -e "${R}端口必须是 1-65535 的数字${N}"
      continue
    fi
    new_port=$((10#$new_port))
    if [ "$new_port" != "$cur_port" ] && check_port_in_use "$new_port" tcp; then
      local force_port=""
      echo -e "${R}端口 ${new_port} 已被其他 TCP 服务占用${N}"
      read -p "  仍然使用此端口？(y/N): " force_port
      if [ "$force_port" != "y" ] && [ "$force_port" != "Y" ]; then
        continue
      fi
    fi
    break
  done

  while true; do
    read -p "  SNI 域名 (${cur_sni:-当前未知}): " new_sni
    new_sni="${new_sni:-$cur_sni}"
    new_sni=$(sanitize_sni "$new_sni")
    if [ -n "$new_sni" ]; then break; fi
    echo -e "${R}SNI 不能为空${N}"
  done

  read -p "  Password (回车保留当前 / 输入 new 重新随机生成): " new_pw
  case "$new_pw" in
    new|NEW)
      new_pw=$(cat /proc/sys/kernel/random/uuid)
      echo -e "  ${D}新 Password：$new_pw${N}"
      ;;
    "") new_pw="$cur_pw" ;;
  esac
  if [ -z "$new_pw" ]; then
    echo -e "${R}Password 无效${N}"
    pause_screen
    return 1
  fi

  read -p "  节点名称 (${cur_tag}): " new_tag
  new_tag="${new_tag:-$cur_tag}"

  echo ""
  echo -e "  即将应用："
  echo -e "    端口     ${cur_port:-?} ${D}→${N} ${C}${new_port}${N}"
  echo -e "    SNI      ${cur_sni:-?} ${D}→${N} ${C}${new_sni}${N}"
  if [ "$new_pw" != "$cur_pw" ]; then
    echo -e "    Password ${cur_pw:-?} ${D}→${N} ${C}${new_pw}${N}"
  else
    echo -e "    Password ${D}保留${N}"
  fi
  if [ "$new_tag" != "$cur_tag" ]; then
    echo -e "    Tag      ${cur_tag} ${D}→${N} ${C}${new_tag}${N}"
  else
    echo -e "    Tag      ${D}保留${N}"
  fi
  read -p "  确认？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  ensure_jq || { pause_screen; return 1; }
  txn=$(node_transaction_begin anytls) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

  # 备份配置
  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
  if ! cp "$CONFIG_PATH" "$backup_path"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置备份失败${N}"
    pause_screen
    return 1
  fi

  local tmp jq_filter
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN
  jq_filter='(.inbounds[] | select(.tag == "anytls-in"))
       |= (.listen_port = ($port | tonumber)
           | .users[0].password = $pw
           | .tls.server_name = $sni
           | .tls.reality.handshake.server = $sni)'
  if ! jq --arg port "$new_port" \
          --arg sni "$new_sni" \
          --arg pw "$new_pw" \
          "$jq_filter" "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置写入失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  if ! mv "$tmp" "$CONFIG_PATH"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置替换失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if ! config_check_and_restart "$new_port" tcp; then
    node_transaction_rollback "$txn"
    echo ""
    echo -e "${R}sing-box 校验或健康检查失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  # 防火墙：撤旧放新
  local cur_mode
  cur_mode=$(get_node_value anytls Mode 2>/dev/null || echo ipv4)
  if [ -n "$cur_port" ] && [ "$cur_port" != "$new_port" ]; then
    if ! node_revoke_firewall_for_mode "$cur_port" tcp "$cur_mode" \
       || ! node_apply_firewall_for_mode "$new_port" tcp "$cur_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}防火墙端口切换失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    print_firewall_hint "$new_port" tcp "AnyTLS 节点新端口"
  fi

  # 更新 info
  if ! set_node_value anytls Port "$new_port" \
     || ! set_node_value anytls SNI "$new_sni" \
     || ! set_node_value anytls Password "$new_pw" \
     || ! set_node_value anytls Tag "$new_tag"; then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  # 重生成 Link
  local cur_ip pub sid new_link ipv6_new_link
  cur_ip=$(get_node_value anytls IP 2>/dev/null || true)
  pub=$(get_node_value anytls PublicKey 2>/dev/null || true)
  sid=$(get_node_value anytls ShortID 2>/dev/null || true)
  new_link=$(build_anytls_link "$new_pw" "$cur_ip" "$new_port" "$new_sni" "$pub" "$sid" "$new_tag" 2>/dev/null || true)
  ipv6_new_link=$(build_dualstack_ipv6_link_for_node anytls 2>/dev/null || true)
  if [ -n "$new_link" ] && ! set_node_value anytls Link "$new_link"; then
    node_transaction_rollback "$txn"
    echo -e "${R}客户端链接保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  node_transaction_commit "$txn"
  cleanup_old_backups "${CONFIG_PATH}.bak.*" 5 \
    || echo -e "${Y}旧配置备份自动清理失败，可稍后从备份菜单处理${N}"

  echo ""
  echo -e "${G}AnyTLS 节点参数已更新并重启服务${N}"
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

modify_tuic_params(){
  local new_port="" new_sni="" new_uuid="" new_pw="" new_cc="" new_tag=""
  local cur_port cur_sni cur_uuid cur_pw cur_cc cur_cert_src cur_email cur_mode cur_insecure cur_tag
  local cur_cert_path cur_key_path
  local backup_path="" confirm cc_choice regen_uuid regen_pw txn=""

  if ! require_root; then return 1; fi
  if ! require_singbox_installed; then return 1; fi
  if ! node_installed tuic; then
    echo ""
    echo -e "${R}未发现 TUIC 节点信息${N}"
    pause_screen
    return 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到配置文件：$CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  cur_port=$(get_node_value tuic Port 2>/dev/null || true)
  cur_sni=$(get_node_value tuic SNI 2>/dev/null || true)
  cur_uuid=$(get_node_value tuic UUID 2>/dev/null || true)
  cur_pw=$(get_node_value tuic Password 2>/dev/null || true)
  cur_cc=$(get_node_value tuic CongestionControl 2>/dev/null || echo bbr)
  cur_cert_src=$(get_node_value tuic CertSource 2>/dev/null || echo self)
  cur_email=$(get_node_value tuic ACMEEmail 2>/dev/null || true)
  cur_mode=$(get_node_value tuic Mode 2>/dev/null || echo ipv4)
  cur_insecure=$(get_node_value tuic Insecure 2>/dev/null || echo 0)
  cur_cert_path=$(get_node_value tuic CertPath 2>/dev/null || true)
  cur_key_path=$(get_node_value tuic KeyPath 2>/dev/null || true)
  cur_tag=$(get_node_value tuic Tag 2>/dev/null || echo tuic)

  echo ""
  echo -e "  ${B}${C}修改 TUIC v5 节点参数${N}  ${D}直接回车保留当前值${N}"
  echo -e "  ${D}（证书来源 ${cur_cert_src} 不可在此修改，需要切换请卸载重装）${N}"
  render_divider

  # 端口
  while true; do
    read -p "  端口 (${cur_port:-当前未知}): " new_port
    new_port="${new_port:-$cur_port}"
    if validate_port "$new_port"; then
      new_port=$((10#$new_port))
      if [ "$new_port" != "$cur_port" ] && check_port_in_use "$new_port" udp; then
        local force_port=""
        echo -e "${R}端口 ${new_port} 已被其他 UDP 服务占用${N}"
        read -p "  仍然使用此端口？(y/N): " force_port
        if [ "$force_port" != "y" ] && [ "$force_port" != "Y" ]; then
          continue
        fi
      fi
      break
    fi
    echo -e "${R}端口必须是 1-65535 的数字${N}"
  done

  # SNI
  while true; do
    if [ "$cur_cert_src" = "acme" ]; then
      read -p "  域名 (${cur_sni:-当前未知}, 改后会触发 ACME 重签): " new_sni
    else
      read -p "  SNI (${cur_sni:-当前未知}): " new_sni
    fi
    new_sni="${new_sni:-$cur_sni}"
    new_sni=$(sanitize_sni "$new_sni")
    if [ -n "$new_sni" ]; then break; fi
    echo -e "${R}SNI 不能为空${N}"
  done

  # UUID
  read -p "  UUID (回车保留当前 / 输入 new 重新生成): " regen_uuid
  case "$regen_uuid" in
    new|NEW)
      new_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
      if [ -z "$new_uuid" ] && command -v sing-box >/dev/null 2>&1; then
        new_uuid=$(sing-box generate uuid 2>/dev/null)
      fi
      if [ -z "$new_uuid" ]; then
        echo -e "${R}UUID 生成失败${N}"
        pause_screen
        return 1
      fi
      echo -e "  ${D}新 UUID：$new_uuid${N}"
      ;;
    *) new_uuid="$cur_uuid" ;;
  esac

  # Password
  read -p "  Password (回车保留当前 / 输入 new 重新随机生成): " regen_pw
  case "$regen_pw" in
    new|NEW)
      new_pw=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-22)
      echo -e "  ${D}新 Password：$new_pw${N}"
      ;;
    *) new_pw="$cur_pw" ;;
  esac

  # 拥塞控制
  echo -e "  拥塞控制算法 (当前: ${C}${cur_cc}${N})："
  echo "    1) 保留当前（默认）"
  echo "    2) bbr"
  echo "    3) cubic"
  read -p "  请选择 (1): " cc_choice
  case "$cc_choice" in
    2) new_cc="bbr" ;;
    3) new_cc="cubic" ;;
    *) new_cc="$cur_cc" ;;
  esac

  # 节点名称
  read -p "  节点名称 (${cur_tag}): " new_tag
  new_tag="${new_tag:-$cur_tag}"

  # 应用前确认
  echo ""
  echo -e "  即将应用："
  echo -e "    端口         ${cur_port:-?} ${D}→${N} ${C}${new_port}${N}"
  echo -e "    SNI          ${cur_sni:-?} ${D}→${N} ${C}${new_sni}${N}"
  if [ "$new_uuid" != "$cur_uuid" ]; then
    echo -e "    UUID         ${cur_uuid:-?} ${D}→${N} ${C}${new_uuid}${N}"
  else
    echo -e "    UUID         ${D}保留${N}"
  fi
  if [ "$new_pw" != "$cur_pw" ]; then
    echo -e "    Password     ${cur_pw:-?} ${D}→${N} ${C}${new_pw}${N}"
  else
    echo -e "    Password     ${D}保留${N}"
  fi
  if [ "$new_cc" != "$cur_cc" ]; then
    echo -e "    拥塞控制     ${cur_cc:-?} ${D}→${N} ${C}${new_cc}${N}"
  else
    echo -e "    拥塞控制     ${D}保留${N}"
  fi
  if [ "$new_tag" != "$cur_tag" ]; then
    echo -e "    Tag          ${cur_tag} ${D}→${N} ${C}${new_tag}${N}"
  else
    echo -e "    Tag          ${D}保留${N}"
  fi
  read -p "  确认？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  ensure_jq || { pause_screen; return 1; }
  txn=$(node_transaction_begin tuic) || { echo -e "${R}节点事务快照失败${N}"; pause_screen; return 1; }

  # 备份配置
  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
  if ! cp "$CONFIG_PATH" "$backup_path"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置备份失败${N}"
    pause_screen
    return 1
  fi

  # 自签证书：SNI 变了 → 重新自签
  if [ "$cur_cert_src" = "self" ] && [ "$new_sni" != "$cur_sni" ]; then
    echo -e "${Y}==> SNI 已修改，重新生成自签证书...${N}"
    if ! generate_self_signed_cert_for_tuic "$new_sni" >/dev/null; then
      node_transaction_rollback "$txn"
      echo -e "${R}自签证书生成失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
  fi

  # jq 修改 inbound
  local tmp jq_filter
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN
  jq_filter='(.inbounds[] | select(.tag == "tuic-in"))
       |= (.listen_port = ($port | tonumber)
           | .users[0].uuid = $uuid
           | .users[0].password = $pw
           | .congestion_control = $cc
           | .tls.server_name = $sni
           | if (.tls.acme | type) == "object"
             then .tls.certificate_provider = ({type: "acme"} + .tls.acme) | del(.tls.acme)
             else . end
           | if (.tls.certificate_provider | type) == "object"
             then .tls.certificate_provider.domain = [$sni]
             else . end))'
  if ! jq --arg port "$new_port" \
          --arg sni "$new_sni" \
          --arg uuid "$new_uuid" \
          --arg pw "$new_pw" \
          --arg cc "$new_cc" \
          "$jq_filter" "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置写入失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  if ! mv "$tmp" "$CONFIG_PATH"; then
    node_transaction_rollback "$txn"
    echo -e "${R}配置替换失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  if ! config_check_and_restart "$new_port" udp; then
    node_transaction_rollback "$txn"
    echo ""
    echo -e "${R}sing-box 校验或健康检查失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  # 防火墙：撤旧放新
  if [ -n "$cur_port" ] && [ "$cur_port" != "$new_port" ]; then
    if ! node_revoke_firewall_for_mode "$cur_port" udp "$cur_mode" \
       || ! node_apply_firewall_for_mode "$new_port" udp "$cur_mode"; then
      node_transaction_rollback "$txn"
      echo -e "${R}防火墙端口切换失败，已完整回滚${N}"
      pause_screen
      return 1
    fi
    print_firewall_hint "$new_port" udp "TUIC 节点新端口"
  fi

  # 更新 .info
  if ! set_node_value tuic Port "$new_port" \
     || ! set_node_value tuic SNI "$new_sni" \
     || ! set_node_value tuic UUID "$new_uuid" \
     || ! set_node_value tuic Password "$new_pw" \
     || ! set_node_value tuic CongestionControl "$new_cc" \
     || ! set_node_value tuic Tag "$new_tag"; then
    node_transaction_rollback "$txn"
    echo -e "${R}节点信息保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi

  # 重生成 Link
  local cur_ip new_link ipv6_new_link
  cur_ip=$(get_node_value tuic IP 2>/dev/null || true)
  new_link=$(build_tuic_link "$new_uuid" "$new_pw" "$cur_ip" "$new_port" "$new_sni" "$cur_insecure" "$new_cc" "$new_tag" 2>/dev/null || true)
  ipv6_new_link=$(build_dualstack_ipv6_link_for_node tuic 2>/dev/null || true)
  if [ -n "$new_link" ] && ! set_node_value tuic Link "$new_link"; then
    node_transaction_rollback "$txn"
    echo -e "${R}客户端链接保存失败，已完整回滚${N}"
    pause_screen
    return 1
  fi
  node_transaction_commit "$txn"
  cleanup_old_backups "${CONFIG_PATH}.bak.*" 5 \
    || echo -e "${Y}旧配置备份自动清理失败，可稍后从备份菜单处理${N}"

  echo ""
  echo -e "${G}TUIC 节点参数已更新并重启服务${N}"
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
# 清理范围：脚本固定 tag 的节点 inbound、节点信息/证书/防火墙端口、
#          WARP 与 sing-box 服务/软件包、脚本生成的配置备份、
#          legacy /root/proxy-info.txt、/usr/local/bin/sb。
# 保留：/etc/sing-box 内用户自定义 inbound、DNS、路由、outbound 与其它文件。
# 不动：SSH 端口/sshd 配置、用户账户、sudoers、自动更新策略、
#        IPv6 防火墙菜单规则、1Panel、apt 基础工具、
#        TCP 网络优化、QUIC 协议优化、initcwnd 持久化服务、本脚本创建的 SWAP。
# ═══ source: 60-uninstall-script.sh ═══
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
# ═══ source: 70-render-ui.sh ═══
CARD_INNER_WIDTH=52

# 计算字符串可见宽度（剥除 ANSI 颜色码）
# 直接看 UTF-8 字节头：ASCII 与 2 字节字符按 1 列、3 字节 / 4 字节按 2 列。
# 不依赖 wc -m 的 locale 行为，C / POSIX locale 下也能正确算 CJK 宽度。
# 例外：U+2500-U+27BF 这一段（box drawing / 几何 / 杂项符号 / 装饰符）
# 实际多为单倍宽，此处单独按 1 列计；其中 ✨ (U+2728) 是 emoji，仍按 2 列。
# od 加 -v 防止重复字节块折叠成 *；tr 把多行并成单行，
# 保证多字节字符不会跨 od 输出行导致 awk 取不到后续字节。
_card_visible(){
  local s
  s=$(printf '%b' "$1" | sed $'s/\x1b\\[[0-9;]*[a-zA-Z]//g')
  printf '%s' "$s" | od -An -v -tu1 | tr '\n' ' ' | awk '
    BEGIN { n = 0 }
    {
      for (i = 1; i <= NF; i++) {
        b = $i + 0
        if (b < 128) { n += 1; continue }
        if (b < 192) continue
        if (b < 224) { n += 1; continue }
        if (b < 240) {
          # 3 字节 UTF-8：默认 2 列；E2 94..9B / 9C 段中的非 emoji 字符按 1 列
          if (b == 226) {
            b2 = (i + 1 <= NF) ? $(i+1) + 0 : 0
            b3 = (i + 2 <= NF) ? $(i+2) + 0 : 0
            if (b2 >= 148 && b2 <= 155) { n += 1; continue }
            if (b2 == 156) {
              # ✨ U+2728 = E2 9C A8 是 emoji，按 2 列
              if (b3 == 168) { n += 2; continue }
              n += 1; continue
            }
          }
          n += 2
          continue
        }
        n += 2
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

# 卡片顶部：╭─★ TITLE ─...─ RIGHT ★─╮
render_card_top(){
  local title="$1" right="$2"
  local title_w right_w fill_w fill
  title_w=$(_card_visible "$title")
  right_w=$(_card_visible "$right")
  # 内宽 = 1(─) + 1(★) + 1(空) + title + 1(空) + N + 1(空) + right + 1(空) + 1(★) + 1(─)
  fill_w=$((CARD_INNER_WIDTH - 8 - title_w - right_w))
  [ "$fill_w" -lt 1 ] && fill_w=1
  fill=$(_card_dash_fill "$fill_w")
  echo -e "  ${L}╭─${N}${C}★${N} ${title} ${L}${fill}${N} ${right} ${C}★${N}${L}─╮${N}"
}

# 无标题卡片顶部
render_card_plain_top(){
  local fill
  fill=$(_card_dash_fill "$CARD_INNER_WIDTH")
  echo -e "  ${L}╭${fill}╮${N}"
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
    anytls)  label="AnyTLS     " ;;   # 11 可见列：6 + 5 sp
    tuic)    label="TUIC v5    " ;;   # 11 可见列：7 + 4 sp
    ss2022)  label="SS-2022    " ;;   # 11 可见列：7 + 4 sp
    *)       label=$(printf '%-11s' "$type") ;;
  esac

  if ! node_installed "$type"; then
    render_card_line " ${C}✦${N} ${C}${label}${N}${D}◌${N} ${Y}未安装${N}"
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

  # 附加信息：HY2 端口跳跃 / SS-2022 谨慎标记
  local extra=""
  if [ "$type" = "hy2" ]; then
    local hop_v
    hop_v=$(get_node_value "$type" PortHop 2>/dev/null || echo 0)
    [ "$hop_v" = "1" ] && extra="  ${C}+hop${N}"
  elif [ "$type" = "ss2022" ]; then
    extra="  ${R}[谨慎]${N}"
  fi

  # 第一行：✦ + 协议名 + ● + :端口 + IP + 附加
  render_card_line " ${C}✦${N} ${C}${label}${N}${G}●${N} :${C}${port:-?}${N}${gap_str}${C}${ip:-?}${N}${extra}"
  # 第二行：网络方向（缩进对齐到第一行的状态列）
  render_card_line "              ${D}${mode_label}${N}"

}

# TCP 调优行（单排）
render_tcp_card_line(){
  local label="TCP 调优   "  # 11 可见列
  if [ ! -f "$TCP_TUNING_PATH" ]; then
    render_card_line " ${C}✧${N} ${C}${label}${N}${D}未启用${N}"
    return
  fi
  local profile_line region="" mem_tier="" region_label="" mem_label=""
  profile_line=$(awk '/^# leyili-profile:/ { print; exit }' "$TCP_TUNING_PATH" 2>/dev/null)
  if [ -n "$profile_line" ]; then
    region=$(printf '%s\n' "$profile_line" | sed -n 's/.*region=\([a-z0-9-]\+\).*/\1/p')
    mem_tier=$(printf '%s\n' "$profile_line" | sed -n 's/.*mem_tier=\([a-z0-9]\+\).*/\1/p')
    case "$region" in
      # hk/jp/us-west/eu 为旧版固定地区档的存量 marker，仅保留展示映射
      hk)      region_label="香港" ;;
      jp)      region_label="日本" ;;
      us-west) region_label="美西" ;;
      us-west-100m) region_label="美西 100M" ;;
      eu)      region_label="欧洲" ;;
      custom)  region_label="自动实测" ;;
    esac
    case "$mem_tier" in
      512m) mem_label="512M" ;;
      1g) mem_label="1G"  ;;
      2g) mem_label="2G"  ;;
      4g) mem_label="4G"  ;;
      8g) mem_label="8G+" ;;
    esac
  fi
  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  if [ -n "$region_label" ] && [ -n "$mem_label" ]; then
    render_card_line " ${C}✧${N} ${C}${label}${N}${C}${region_label}/${mem_label}${N} ${D}·${N} ${D}cc=${cc}${N}"
  else
    render_card_line " ${C}✧${N} ${C}${label}${N}${D}cc=${cc}${N}"
  fi
}

# QUIC 调优行（单排）
render_quic_card_line(){
  local label="QUIC 调优  "  # 11 可见列
  if [ ! -f "$QUIC_TUNING_PATH" ]; then
    render_card_line " ${C}✧${N} ${C}${label}${N}${D}未启用${N}"
    return
  fi
  local profile_line region="" mem_tier="" region_label="" mem_label=""
  profile_line=$(awk '/^# leyili-quic-profile:/ { print; exit }' "$QUIC_TUNING_PATH" 2>/dev/null)
  if [ -n "$profile_line" ]; then
    region=$(printf '%s\n' "$profile_line" | sed -n 's/.*region=\([a-z0-9-]\+\).*/\1/p')
    mem_tier=$(printf '%s\n' "$profile_line" | sed -n 's/.*mem_tier=\([a-z0-9]\+\).*/\1/p')
    case "$region" in
      hk)      region_label="香港" ;;
      jp)      region_label="日本" ;;
      us-west) region_label="美西" ;;
      eu)      region_label="欧洲" ;;
    esac
    case "$mem_tier" in
      512m) mem_label="512M" ;;
      1g) mem_label="1G"  ;;
      2g) mem_label="2G"  ;;
      4g) mem_label="4G"  ;;
      8g) mem_label="8G+" ;;
    esac
  fi
  local rmem_max rmem_label="?"
  rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "")
  if [ -n "$rmem_max" ] && [ "$rmem_max" -gt 0 ] 2>/dev/null; then
    rmem_label="$((rmem_max / 1024 / 1024))M"
  fi
  if [ -n "$region_label" ] && [ -n "$mem_label" ]; then
    render_card_line " ${C}✧${N} ${C}${label}${N}${C}${region_label}/${mem_label}${N} ${D}·${N} ${D}rmem=${rmem_label}${N}"
  else
    render_card_line " ${C}✧${N} ${C}${label}${N}${D}rmem=${rmem_label}${N}"
  fi
}

# initcwnd 行（单排）
render_initcwnd_card_line(){
  local label="initcwnd   "  # 11 可见列
  if ! command -v ip >/dev/null 2>&1; then
    render_card_line " ${C}✧${N} ${C}${label}${N}${D}未知 (ip 命令缺失)${N}"
    return
  fi
  local route_line val persist
  route_line=$(ip route show default 2>/dev/null | head -n1)
  if [ -z "$route_line" ]; then
    render_card_line " ${C}✧${N} ${C}${label}${N}${D}无默认路由${N}"
    return
  fi
  val=$(printf '%s\n' "$route_line" | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i == "initcwnd") { print $(i + 1); exit }
    }
  }')
  if [ -z "$val" ]; then
    render_card_line " ${C}✧${N} ${C}${label}${N}${D}未设置${N}"
    return
  fi
  if [ -f "$INITCWND_SERVICE_PATH" ] \
     && systemctl is-enabled "$(basename "$INITCWND_SERVICE_PATH")" >/dev/null 2>&1; then
    persist="${D}(已持久化)${N}"
  else
    persist="${Y}(未持久化)${N}"
  fi
  render_card_line " ${C}✧${N} ${C}${label}${N}${C}${val}${N}  ${persist}"
}

# sing-box 内核版本行：当前版本 vs 最新稳定版（GitHub releases/latest 只返回稳定版）
# 最新版走带缓存的查询，首页反复刷新也不会每次都打 GitHub。
render_singbox_version_card_line(){
  local label="内核版本   "  # 11 可见列
  if ! is_singbox_installed; then
    return  # 未安装时标题栏已显示「未安装」，此处不再重复
  fi
  local cur latest
  cur=$(get_current_singbox_version 2>/dev/null)
  [ -z "$cur" ] && cur="?"
  latest=$(get_latest_singbox_version_cached 2>/dev/null)
  if [ -z "$latest" ]; then
    render_card_line " ${C}✦${N} ${C}${label}${N}${C}v${cur}${N} ${D}·${N} ${D}最新版待联网${N}"
  elif [ "$cur" = "$latest" ]; then
    render_card_line " ${C}✦${N} ${C}${label}${N}${C}v${cur}${N} ${D}·${N} ${G}已是最新${N}"
  elif _singbox_ver_lt "$cur" "$latest"; then
    render_card_line " ${C}✦${N} ${C}${label}${N}${C}v${cur}${N} ${Y}→${N} ${G}v${latest}${N} ${Y}可升级${N}"
  else
    # 当前版本比稳定版新（装了 alpha/beta 预览版）
    render_card_line " ${C}✦${N} ${C}${label}${N}${C}v${cur}${N} ${D}·${N} ${D}稳定版 v${latest}${N}"
  fi
  render_card_blank
}

# 主菜单卡片：精简节点概览
render_main_menu_card(){
  render_card_plain_top
  render_card_blank
  render_singbox_version_card_line
  render_node_card_block reality
  if node_installed ss2022; then
    render_card_blank
    render_node_card_block ss2022
  fi
  render_card_blank
  render_card_bottom
}
# ═══ source: 80-menu-node.sh ═══
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
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice
    case $choice in
      1) if node_installed reality; then uninstall_reality_node; return; else notify_invalid_choice; fi ;;
      2) if node_installed hy2;     then uninstall_hy2_node;     return; else notify_invalid_choice; fi ;;
      3) if node_installed anytls;  then uninstall_anytls_node;  return; else notify_invalid_choice; fi ;;
      4) if node_installed tuic;    then uninstall_tuic_node;    return; else notify_invalid_choice; fi ;;
      5) if node_installed ss2022;  then uninstall_ss2022_node;  return; else notify_invalid_choice; fi ;;
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
  else
    echo -e "${G}升级完成，配置与服务健康检查已通过${N}"
    sleep 1
  fi
}

show_update_menu(){
  local choice cur_ver kernel_label
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

    render_section_header "更新管理"
    render_menu_item 1 "更新脚本"
    render_menu_item 2 "$kernel_label"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice
    case $choice in
      1) update_self_script ;;
      2) upgrade_singbox_kernel ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

check_reality_dest_domain(){
  local domain ips ip ipn org cdn_match proto x25 pq alpn cipher
  local v4s v6s vps_has_v6 conn hs1 hs2 hs3
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
  # 深度测试优先用 IPv4：reality 握手由 VPS 发起，v4-only 机器上测 v6 地址只会误报
  v4s=$(echo "$ips" | grep -v ':' || true)
  v6s=$(echo "$ips" | grep ':' || true)
  ip=$(echo "$v4s" | head -1)
  [ -z "$ip" ] && ip=$(echo "$v6s" | head -1)
  vps_has_v6=$(detect_primary_ipv6 2>/dev/null || true)
  # openssl -connect 的 IPv6 地址必须带方括号
  case "$ip" in
    *:*) conn="[$ip]:443" ;;
    *)   conn="$ip:443" ;;
  esac
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

  # 3. TCP 443 通断（v4 全测；v6 仅在本机有 IPv6 时测，否则测了必失败、纯属误报）
  echo ""
  echo -e "  ${B}[3/6] TCP 443 通断${N}"
  for testip in $v4s; do
    if timeout 3 bash -c "echo > /dev/tcp/$testip/443" 2>/dev/null; then
      echo -e "    ${G}✓${N} $testip"
    else
      echo -e "    ${R}✗${N} $testip"
      any_fail=1
    fi
  done
  if [ -n "$v6s" ]; then
    if [ -n "$vps_has_v6" ]; then
      for testip in $v6s; do
        if timeout 3 bash -c "echo > /dev/tcp/$testip/443" 2>/dev/null; then
          echo -e "    ${G}✓${N} $testip"
        else
          echo -e "    ${R}✗${N} $testip"
          any_fail=1
        fi
      done
    else
      echo -e "    ${D}本机无 IPv6，跳过 $(echo "$v6s" | wc -l | tr -d ' ') 个 v6 地址（不影响判定）${N}"
    fi
  fi

  # 4. TLS 1.3 / X25519 / ALPN —— 分两次握手，才能区分「不支持 1.3」和「不支持 X25519」
  echo ""
  echo -e "  ${B}[4/6] TLS 1.3 + X25519 + ALPN（IP=${ip}）${N}"
  hs1=$(echo | timeout 5 openssl s_client -connect "$conn" -servername "$domain" \
          -tls1_3 -alpn h2,http/1.1 2>/dev/null)
  proto=$(echo "$hs1" | grep -m1 -oE 'TLSv1\.[0-9]+')
  alpn=$(echo "$hs1" | grep -m1 -oE 'ALPN protocol: \S+' | awk '{print $3}')
  cipher=$(echo "$hs1" | grep -m1 -oE 'Cipher\s*:\s*\S+' | awk -F'[: ]+' '{print $NF}')

  if [ "$proto" = "TLSv1.3" ]; then
    echo -e "    ${G}✓${N} Protocol: TLSv1.3"
  else
    echo -e "    ${R}✗${N} Protocol: ${proto:-握手失败} ${R}(reality 强制 TLS 1.3)${N}"
  fi

  # 只提供 X25519 一个组再握手：能协商成功即支持（比 grep 输出关键字可靠，
  # 不同 openssl 版本对协商组的输出格式不一致）
  x25=no
  if [ "$proto" = "TLSv1.3" ]; then
    hs2=$(echo | timeout 5 openssl s_client -connect "$conn" -servername "$domain" \
            -tls1_3 -groups X25519 2>/dev/null)
    echo "$hs2" | grep -qE 'New, TLSv1\.3|Protocol[[:space:]]*:[[:space:]]*TLSv1\.3' && x25=yes
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

  # 信息项：抗量子混合组（Chrome 已默认在 ClientHello 里带，dest 支持算伪装加分）
  # 不参与综合判定；本机 openssl < 3.5 不认识该组名时跳过
  pq=skip
  if [ "$proto" = "TLSv1.3" ]; then
    hs3=$(echo | timeout 5 openssl s_client -connect "$conn" -servername "$domain" \
            -tls1_3 -groups X25519MLKEM768 2>&1)
    if echo "$hs3" | grep -qE 'New, TLSv1\.3|Protocol[[:space:]]*:[[:space:]]*TLSv1\.3'; then
      pq=yes
    elif echo "$hs3" | grep -qiE 'no such group|unknown group|unknown option|invalid argument|Error with command|SSL_CONF_cmd|failed to set'; then
      pq=skip
    else
      pq=no
    fi
  fi
  case "$pq" in
    yes)  echo -e "    ${G}✓${N} 抗量子混合组 X25519MLKEM768 ${D}(加分项，更贴近真实 Chrome 流量)${N}" ;;
    no)   echo -e "    ${D}△ 抗量子混合组不支持（信息项，不影响判定）${N}" ;;
    skip) echo -e "    ${D}? 本机 openssl 过旧，无法检测抗量子组（不影响判定）${N}" ;;
  esac

  # 5. 证书 SAN
  echo ""
  echo -e "  ${B}[5/6] 证书 SAN 是否覆盖该域名${N}"
  cert_san=$(echo | timeout 5 openssl s_client -connect "$conn" -servername "$domain" 2>/dev/null \
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
  elif [ "$proto" != "TLSv1.3" ]; then
    echo -e "    ${R}✗ 不可用 — 不支持 TLS 1.3（reality 硬性要求）${N}"
  elif [ "$x25" != "yes" ]; then
    echo -e "    ${R}✗ 不可用 — 不支持 X25519 密钥交换（reality 硬性要求）${N}"
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
    render_menu_item 3 "查看状态 / 节点配置"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice
    case $choice in
      1) show_node_install_menu ;;
      2) show_node_uninstall_menu ;;
      3) show_status_menu ;;
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
# ═══ source: 90-warp.sh ═══
warp_log_ok()   { echo -e "  ${G}✓${N} $*" >&2; }
warp_log_info() { echo -e "  ${C}●${N} $*" >&2; }
warp_log_warn() { echo -e "  ${Y}⚠${N} $*" >&2; }
warp_log_err()  { echo -e "  ${R}✗${N} $*" >&2; }

warp_transaction_begin(){
  local txn
  txn=$(config_transaction_begin warp) || return 1
  if [ -d "$WARP_DIR" ]; then
    cp -a -- "$WARP_DIR" "$txn/warp-dir" || { config_transaction_rollback "$txn"; return 1; }
    : > "$txn/warp-dir.existed"
  fi
  if [ -f "$WARP_WGCF_BIN" ]; then
    cp -a -- "$WARP_WGCF_BIN" "$txn/wgcf-bin" || { config_transaction_rollback "$txn"; return 1; }
    : > "$txn/wgcf-bin.existed"
  fi
  printf '%s' "$txn"
}

warp_transaction_rollback(){
  local txn="$1" rc=0
  [ -d "$txn" ] || return 1
  config_transaction_restore "$txn" || rc=1

  if ! rm -rf -- "$WARP_DIR"; then
    rc=1
  elif [ -f "$txn/warp-dir.existed" ]; then
    if ! mkdir -p -- "$(dirname -- "$WARP_DIR")" \
       || ! cp -a -- "$txn/warp-dir" "$WARP_DIR"; then
      rc=1
    fi
  fi
  if [ -f "$txn/wgcf-bin.existed" ]; then
    if ! restore_file_snapshot "$txn/wgcf-bin" "$WARP_WGCF_BIN"; then
      rc=1
    fi
  else
    rm -f -- "$WARP_WGCF_BIN" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    rm -rf -- "$txn" || rc=1
  fi
  [ "$rc" -eq 0 ] || warp_log_err "WARP 事务回滚有步骤失败，请检查账号与 sing-box 配置；快照保留在 ${txn}"
  return "$rc"
}

warp_transaction_commit(){
  config_transaction_commit "$1"
}

# ── 账号注册：curl 直连 Cloudflare API（wgcf 方案已废弃）──────────────
# 旧版用 wgcf 二进制：要从 GitHub API 拿版本再下 release（VPS 上极易被限流/
# 阻断），且 Cloudflare 收紧注册接口后老版本 wgcf 频繁 403/429 —— 这就是旧版
# 「WARP 分流」装不上的根因。现改为主流脚本（fscarmen/warp、warp-reg）同款：
# openssl 生成 X25519 密钥对，curl 模拟官方安卓客户端注册，一次拿全 v4/v6
# 内网地址 + peer 公钥 + client_id，存成 ${WARP_DIR}/account.json。
# client_id 解码出的 3 字节即 WireGuard 报文头的 reserved 字段 —— 旧版写死
# [0,0,0]，部分 PoP 会「握手成功但无数据」，本次一并修正。

warp_gen_keypair(){
  local pem priv pub
  if command -v wg >/dev/null 2>&1; then
    priv=$(wg genkey 2>/dev/null)
    pub=$(printf '%s' "$priv" | wg pubkey 2>/dev/null)
  else
    pem=$(openssl genpkey -algorithm X25519 2>/dev/null)
    if [ -z "$pem" ]; then
      warp_log_err "openssl 生成 X25519 密钥失败（需要 openssl 1.1.0+，或安装 wireguard-tools）"
      return 1
    fi
    # PKCS8 私钥 / SPKI 公钥的 DER 最后 32 字节就是裸密钥（免依赖 xxd）
    priv=$(printf '%s\n' "$pem" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64)
    pub=$(printf '%s\n' "$pem" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64)
  fi
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    warp_log_err "生成 WireGuard 密钥对失败"
    return 1
  fi
  printf '%s %s\n' "$priv" "$pub"
}

warp_account_valid(){
  [ -s "$WARP_ACCOUNT_JSON" ] || return 1
  jq -e '
    (.private_key | type == "string" and length > 0)
    and (.config.interface.addresses.v4 | type == "string" and length > 0)
    and (.config.peers[0].public_key | type == "string" and length > 0)
  ' "$WARP_ACCOUNT_JSON" >/dev/null 2>&1
}

warp_register_account(){
  local force="${1:-0}"
  mkdir -p "$WARP_DIR" || return 1
  chmod 700 "$WARP_DIR" || return 1
  ensure_jq || return 1
  if [ -s "$WARP_ACCOUNT_JSON" ] && [ "$force" != "1" ]; then
    if ! warp_account_valid; then
      warp_log_err "现有 account.json 无效，已拒绝覆盖；请使用“重新注册账号”"
      return 1
    fi
    return 0
  fi

  local priv pub
  read -r priv pub <<< "$(warp_gen_keypair)"
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    return 1
  fi

  local install_id fcm_token body resp try tmp
  install_id=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 22)
  fcm_token="${install_id}:APA91b$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 134)"
  body=$(jq -nc --arg key "$pub" --arg iid "$install_id" --arg fcm "$fcm_token" \
        --arg tos "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
        '{key:$key, install_id:$iid, fcm_token:$fcm, tos:$tos,
          model:"PC", serial_number:$iid, locale:"zh_CN"}')

  warp_log_info "向 Cloudflare 注册 WARP 账号（直连 API，不下载任何二进制）..."
  resp=""
  for try in 1 2 3 4 5 6; do
    resp=$(curl --proto '=https' --proto-redir '=https' -sL --tlsv1.2 --max-time 20 -X POST "${WARP_API_BASE}/reg" \
      -H "User-Agent: ${WARP_API_UA}" \
      -H "CF-Client-Version: ${WARP_API_CLIENT_VER}" \
      -H 'Content-Type: application/json' \
      --data "$body" 2>/dev/null)
    if printf '%s' "$resp" | jq -e '(.result // .) | .config.peers[0].public_key' >/dev/null 2>&1; then
      break
    fi
    # error code: 1015 = Cloudflare 按 IP 限流，机房 IP 信誉差时常见，等一等再试
    warp_log_warn "第 ${try}/6 次注册未成功${resp:+：$(printf '%.80s' "$(printf '%s' "$resp" | tr -d '\n')")}"
    resp=""
    [ "$try" -lt 6 ] && sleep $((try * 5))
  done
  if [ -z "$resp" ]; then
    warp_log_err "注册失败（6 次尝试后放弃）"
    echo -e "  ${D}排查建议：${N}"
    echo -e "  ${D}1) 限流（error code: 1015 / 429）：此 IP 注册太频繁，等 10-30 分钟再试${N}"
    echo -e "  ${D}2) 一直无响应：跑 curl -sI --max-time 10 https://api.cloudflareclient.com${N}"
    echo -e "  ${D}   若不通说明本机到 Cloudflare API 被阻断，需在别处注册后拷贝 account.json 过来${N}"
    return 1
  fi

  # 兼容有无 .result 包裹两种返回，并把我们自己的私钥合进去一起落盘
  tmp=$(mktemp "${WARP_ACCOUNT_JSON}.tmp.XXXXXX") || return 1
  if ! printf '%s' "$resp" | jq --arg pk "$priv" '(.result // .) + {private_key: $pk}' \
       > "$tmp" 2>/dev/null \
     || ! jq -e '
          (.private_key | type == "string" and length > 0)
          and (.config.interface.addresses.v4 | type == "string" and length > 0)
          and (.config.peers[0].public_key | type == "string" and length > 0)
        ' "$tmp" >/dev/null 2>&1; then
    warp_log_err "写入 ${WARP_ACCOUNT_JSON} 失败"
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$WARP_ACCOUNT_JSON" || { rm -f -- "$tmp"; return 1; }
  warp_log_ok "WARP 账号已注册：${WARP_ACCOUNT_JSON}"
}

warp_reregister_account(){
  # 新账号先原子落盘；失败时旧 account.json 保持不变。
  warp_register_account 1 || return 1
  rm -f -- "${WARP_DIR}/wgcf-account.toml" "${WARP_DIR}/wgcf-profile.conf"
}

# 解析 account.json，直接写入调用者作用域中的 WARP_* 变量，避免 eval。
# WARP_RESERVED 为 client_id base64 解码出的 3 字节（逗号分隔），注入
# endpoint.peers[].reserved；解不出时回退 0,0,0 并靠端点优选兜底
warp_load_profile(){
  local f="$WARP_ACCOUNT_JSON"
  if [ ! -s "$f" ]; then
    if [ -f "${WARP_DIR}/wgcf-profile.conf" ]; then
      warp_log_err "检测到旧版 wgcf 账号；新版已改用 API 直注，请走「重新注册」生成 account.json"
    else
      warp_log_err "WARP 账号缺失：$f（请先安装/注册）"
    fi
    return 1
  fi
  ensure_jq || return 1
  local pk v4 v6 peerpk cid reserved v4_plain v6_plain
  pk=$(jq -r '.private_key // empty' "$f" 2>/dev/null)
  v4=$(jq -r '.config.interface.addresses.v4 // empty' "$f" 2>/dev/null)
  v6=$(jq -r '.config.interface.addresses.v6 // empty' "$f" 2>/dev/null)
  peerpk=$(jq -r '.config.peers[0].public_key // empty' "$f" 2>/dev/null)
  cid=$(jq -r '.config.client_id // empty' "$f" 2>/dev/null)
  v4_plain="${v4%%/*}"
  v6_plain="${v6%%/*}"
  if [ -z "$pk" ] || [ -z "$v4" ] \
     || ! printf '%s' "$pk" | grep -Eq '^[A-Za-z0-9+/]{43}=$' \
     || ! is_valid_ipv4 "$v4_plain" \
     || { [ -n "$v6" ] && ! is_valid_ipv6_text "$v6_plain"; }; then
    warp_log_err "解析 account.json 失败（缺 private_key 或 v4 地址），请「重新注册」"
    return 1
  fi
  # API 返回裸地址，sing-box endpoint.address 需要 CIDR
  case "$v4" in */*) ;; *) v4="${v4}/32" ;; esac
  case "$v6" in ''|*/*) ;; *) v6="${v6}/128" ;; esac
  reserved=""
  if [ -n "$cid" ]; then
    reserved=$(printf '%s' "$cid" | base64 -d 2>/dev/null | od -An -tu1 2>/dev/null \
      | awk 'NF >= 3 {printf "%d,%d,%d", $1, $2, $3; exit}')
  fi
  [ -n "$reserved" ] || reserved="0,0,0"
  WARP_PRIVATE_KEY="$pk"
  WARP_LOCAL_V4="$v4"
  WARP_LOCAL_V6="$v6"
  WARP_PEER_PK="${peerpk:-$WARP_PEER_PUBLIC_KEY}"
  WARP_RESERVED="$reserved"
}

# sing-box 版本护栏：endpoints 需 1.11+，本模块骨架用的新版 DNS/route 字段
# （default_domain_resolver、dns type local）需 1.12+。低版本 sing-box check
# 只会报一堆看不懂的字段错误，这里先把话说明白
warp_require_singbox_112(){
  local ver major minor
  ver=$(sing-box version 2>/dev/null | awk 'NR==1 {print $3}')
  major="${ver%%.*}"
  minor="${ver#*.}"; minor="${minor%%.*}"; minor="${minor%%[!0-9]*}"
  case "$major" in ''|*[!0-9]*) warp_log_warn "读不到 sing-box 版本号，跳过版本检查"; return 0 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 12 ]; }; then
    return 0
  fi
  warp_log_err "当前 sing-box ${ver} 过旧，WARP 分流需要 ≥ 1.12（endpoints + 新版 DNS 字段）"
  echo -e "  ${D}请先到「节点管理」把 sing-box 升到最新稳定版，再回来装 WARP${N}"
  return 1
}

# 安全编辑 sing-box 配置：写临时文件 → sing-box check 通过后才覆盖
warp_jq_apply(){
  local jq_filter="$1"
  shift
  local tmp
  tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX") || return 1
  if ! jq "$@" "$jq_filter" "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if ! sing-box check -c "$tmp" >/dev/null 2>&1; then
    warp_log_err "sing-box 校验未通过，已回滚"
    sing-box check -c "$tmp" 2>&1 | sed 's/^/    /'
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$CONFIG_PATH"
}

# 读当前配置里 WARP endpoint 实际使用的 host port（没有则回退默认值）
# 用途：重新注入/重新注册时保留「端点优选」选过的地址，不被默认值覆盖
warp_current_endpoint(){
  local ep=""
  if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_PATH" ]; then
    ep=$(jq -r --arg tag "$WARP_OUTBOUND_TAG" '
      (.endpoints // [])[] | select(.tag == $tag) | .peers[0] | "\(.address) \(.port)"
    ' "$CONFIG_PATH" 2>/dev/null | head -1)
  fi
  case "$ep" in
    *null*|"") printf '%s %s' "$WARP_ENDPOINT_HOST" "$WARP_ENDPOINT_PORT" ;;
    *)         printf '%s' "$ep" ;;
  esac
}

warp_managed_state_get(){
  local key="$1"
  [ -f "$WARP_MANAGED_STATE" ] || return 1
  grep -m1 "^${key}=" "$WARP_MANAGED_STATE" | cut -d= -f2-
}

warp_capture_managed_state(){
  local tmp cache_added=0 cache_path=""
  [ -f "$WARP_MANAGED_STATE" ] && return 0
  mkdir -p -- "$WARP_DIR" || return 1
  chmod 700 "$WARP_DIR" || return 1

  if jq -e '.experimental.cache_file != null' "$CONFIG_PATH" >/dev/null 2>&1; then
    cache_path=$(jq -r '.experimental.cache_file.path // empty' "$CONFIG_PATH" 2>/dev/null)
  else
    cache_added=1
    cache_path="$WARP_CACHE_DEFAULT"
  fi
  tmp=$(mktemp "${WARP_MANAGED_STATE}.tmp.XXXXXX") || return 1
  if ! printf 'CacheFileAdded=%s\nCachePath=%s\n' "$cache_added" "$cache_path" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$WARP_MANAGED_STATE"
}

warp_config_inject(){
  local v4="$1" v6="$2" pk="$3" peerpk="${4:-$WARP_PEER_PUBLIC_KEY}" reserved="${5:-0,0,0}"
  ensure_jq || return 1
  [ -f "$CONFIG_PATH" ] || { warp_log_err "config.json 不存在：$CONFIG_PATH"; return 1; }
  warp_capture_managed_state || return 1
  # 骨架兜底：保证 dns local 解析器 + route.default_domain_resolver 存在
  # （WireGuard endpoint 是用户态网络栈，拨域名必须有内部解析器，否则命中规则的流量全断）
  config_ensure_skeleton || return 1

  local addr_json
  if [ -n "$v6" ]; then
    addr_json=$(jq -nc --arg a "$v4" --arg b "$v6" '[$a, $b]')
  else
    addr_json=$(jq -nc --arg a "$v4" '[$a]')
  fi

  local host port
  read -r host port <<< "$(warp_current_endpoint)"

  warp_log_info "注入 WARP endpoint / 规则集 / 路由规则..."
  warp_jq_apply '
      def owned_sniff:
        ((.action // "") == "sniff")
        and (((.inbound // []) | sort) == (($sniff_inbounds | fromjson) | sort));
      .endpoints = ((.endpoints // []) | map(select(.tag != $tag)))
        + [{
            "type": "wireguard",
            "tag": $tag,
            "system": false,
            "mtu": ($mtu | tonumber),
            "address": ($addrs | fromjson),
            "private_key": $pk,
            "peers": [{
              "address": $host,
              "port": ($port | tonumber),
              "public_key": $peerpk,
              "allowed_ips": ["0.0.0.0/0", "::/0"],
              "persistent_keepalive_interval": 25,
              "reserved": ($reserved | split(",") | map(tonumber))
            }]
          }]
    | .route = (.route // {})
    | .route.rule_set = ((.route.rule_set // []) | map(select(.tag != $rs and .tag != $rsyt)))
        + [{
            "type": "remote",
            "tag": $rs,
            "format": "binary",
            "url": $rsurl,
            "download_detour": "direct-out",
            "update_interval": "168h0m0s"
          },
          {
            "type": "remote",
            "tag": $rsyt,
            "format": "binary",
            "url": $rsurlyt,
            "download_detour": "direct-out",
            "update_interval": "168h0m0s"
          }]
    | .route.rules = (
        [{"inbound": ($sniff_inbounds | fromjson), "action": "sniff"}]
        + ((.route.rules // []) | map(select(((.outbound // "") != $tag) and (owned_sniff | not))))
        + [{"rule_set": [$rs, $rsyt], "outbound": $tag}]
      )
    | .experimental = (.experimental // {})
    | .experimental.cache_file = (.experimental.cache_file // {"enabled": true, "path": "/var/lib/sing-box/cache.db"})
  ' \
    --arg tag     "$WARP_OUTBOUND_TAG" \
    --arg rs      "$WARP_RULESET_TAG" \
    --arg rsyt    "$WARP_RULESET_TAG_YT" \
    --arg rsurl   "$WARP_RULESET_URL" \
    --arg rsurlyt "$WARP_RULESET_URL_YT" \
    --arg host    "$host" \
    --arg port    "$port" \
    --arg mtu     "$WARP_MTU" \
    --arg pk      "$pk" \
    --arg peerpk  "$peerpk" \
    --arg reserved "$reserved" \
    --arg sniff_inbounds "$WARP_SNIFF_INBOUNDS_JSON" \
    --arg addrs   "$addr_json"
}

warp_config_remove(){
  local remove_cache="0" cache_path=""
  ensure_jq || return 1
  [ -f "$CONFIG_PATH" ] || return 0
  remove_cache=$(warp_managed_state_get CacheFileAdded 2>/dev/null || echo 0)
  cache_path=$(warp_managed_state_get CachePath 2>/dev/null || true)
  if ! warp_jq_apply '
      def owned_sniff:
        ((.action // "") == "sniff")
        and (((.inbound // []) | sort) == (($sniff_inbounds | fromjson) | sort));
      .endpoints = ((.endpoints // []) | map(select(.tag != $tag)))
    | .route = (.route // {})
    | .route.rule_set = ((.route.rule_set // []) | map(select(.tag != $rs and .tag != $rsyt)))
    | .route.rules = ((.route.rules // []) | map(select(((.outbound // "") != $tag) and (owned_sniff | not))))
    | if $remove_cache == "1" then .experimental |= del(.cache_file) else . end
    | if .experimental == {} then del(.experimental) else . end
  ' \
    --arg tag  "$WARP_OUTBOUND_TAG" \
    --arg rs   "$WARP_RULESET_TAG" \
    --arg rsyt "$WARP_RULESET_TAG_YT" \
    --arg sniff_inbounds "$WARP_SNIFF_INBOUNDS_JSON" \
    --arg remove_cache "$remove_cache"; then
    return 1
  fi
  if [ "$remove_cache" = "1" ] && [ -n "$cache_path" ]; then
    case "$cache_path" in
      /var/lib/sing-box/*|/var/cache/leyili/*)
        rm -f -- "$cache_path" || return 1
        ;;
    esac
  fi
  rm -f -- "$WARP_MANAGED_STATE"
}

warp_config_has_outbound(){
  [ -f "$CONFIG_PATH" ] || return 1
  jq -e --arg tag "$WARP_OUTBOUND_TAG" \
    '(.endpoints // []) | map(select(.tag == $tag)) | length > 0' \
    "$CONFIG_PATH" >/dev/null 2>&1
}

warp_config_has_rule(){
  [ -f "$CONFIG_PATH" ] || return 1
  jq -e --arg tag "$WARP_OUTBOUND_TAG" \
    '(.route.rules // []) | map(select((.outbound // "") == $tag)) | length > 0' \
    "$CONFIG_PATH" >/dev/null 2>&1
}

warp_do_install(){
  require_root || return 1
  require_singbox_installed || return 1
  ensure_jq || return 1

  render_section_header "${WARP_APP_NAME} - 安装"
  echo -e "  ${D}本模块只修改 /etc/sing-box/config.json，加一个 WireGuard 出站，${N}"
  echo -e "  ${D}并把 geosite google/youtube 命中的流量改走 Cloudflare WARP，其它保持直连。${N}"
  echo -e "  ${D}同时开启域名嗅探（QUIC/TLS SNI），保证按 IP 直连的流量也能命中规则。${N}"
  echo -e "  ${D}账号经 curl 直连 Cloudflare API 注册，不下载任何第三方二进制；${N}"
  echo -e "  ${D}不会动 iptables / 系统路由${N}"
  echo ""

  warp_require_singbox_112 || { pause_screen; return 1; }

  local txn WARP_PRIVATE_KEY WARP_LOCAL_V4 WARP_LOCAL_V6 WARP_PEER_PK WARP_RESERVED
  txn=$(warp_transaction_begin) || { warp_log_err "WARP 事务快照失败"; pause_screen; return 1; }
  if ! warp_register_account || ! warp_load_profile; then
    warp_transaction_rollback "$txn"
    pause_screen
    return 1
  fi

  if ! warp_config_inject "$WARP_LOCAL_V4" "$WARP_LOCAL_V6" "$WARP_PRIVATE_KEY" "$WARP_PEER_PK" "$WARP_RESERVED"; then
    warp_transaction_rollback "$txn"
    warp_log_err "写入 sing-box 配置失败，已恢复原状态"
    pause_screen
    return 1
  fi
  warp_log_ok "sing-box 配置已更新"

  warp_log_info "重启 sing-box..."
  if config_check_and_restart; then
    warp_log_ok "sing-box 已重启，WARP 分流生效"
  else
    warp_transaction_rollback "$txn"
    warp_log_err "sing-box 重启失败，已恢复原账号与配置"
    pause_screen
    return 1
  fi
  warp_transaction_commit "$txn"

  echo ""
  warp_do_test
  pause_screen
}

warp_do_uninstall(){
  require_root || return 1
  render_section_header "${WARP_APP_NAME} - 卸载"
  echo -e "  ${D}从 sing-box 配置中移除 WARP endpoint / 规则集 / 路由规则${N}"
  echo ""
  read -r -p "  确认卸载？[y/N]: " yn
  case "$yn" in [yY]*) ;; *) return ;; esac

  read -r -p "  是否同时删除账号目录 ${WARP_DIR}（含 account.json 与旧版 wgcf 残留）？[y/N]: " yn2

  local txn
  txn=$(warp_transaction_begin) || { warp_log_err "WARP 事务快照失败"; pause_screen; return 1; }
  if ! warp_config_remove || ! config_check_and_restart; then
    warp_transaction_rollback "$txn"
    warp_log_err "移除失败，已恢复原配置"
    pause_screen
    return 1
  fi
  case "$yn2" in
    [yY]*)
      if ! rm -f -- "$WARP_WGCF_BIN" || ! rm -rf -- "$WARP_DIR"; then
        warp_transaction_rollback "$txn"
        warp_log_err "账号文件清理失败，已恢复原状态"
        pause_screen
        return 1
      fi
      ;;
  esac
  warp_transaction_commit "$txn"
  warp_log_ok "已从 sing-box 配置中移除 WARP"
  case "$yn2" in [yY]*) warp_log_ok "账号文件与旧版 wgcf 残留已清理" ;; esac
  pause_screen
}

warp_do_reregister(){
  require_root || return 1
  require_singbox_installed || return 1
  ensure_jq || return 1
  render_section_header "${WARP_APP_NAME} - 重新注册账号"
  echo -e "  ${D}用途：当前 WARP IP 仍被识别为中国，或握手异常时使用${N}"
  echo -e "  ${D}流程：原子生成新账号 → 重新写配置 → 健康检查；失败自动恢复旧账号${N}"
  echo ""
  read -r -p "  确认重新注册？[y/N]: " yn
  case "$yn" in [yY]*) ;; *) return ;; esac

  local txn WARP_PRIVATE_KEY WARP_LOCAL_V4 WARP_LOCAL_V6 WARP_PEER_PK WARP_RESERVED
  txn=$(warp_transaction_begin) || { warp_log_err "WARP 事务快照失败"; pause_screen; return 1; }
  if ! warp_reregister_account \
     || ! warp_load_profile \
     || ! warp_config_inject "$WARP_LOCAL_V4" "$WARP_LOCAL_V6" "$WARP_PRIVATE_KEY" "$WARP_PEER_PK" "$WARP_RESERVED" \
     || ! config_check_and_restart; then
    warp_transaction_rollback "$txn"
    warp_log_err "重新注册失败，已恢复旧账号与配置"
    pause_screen
    return 1
  fi
  warp_transaction_commit "$txn"
  warp_log_ok "完成，已切到新的 WARP 账号"
  pause_screen
}

warp_do_status(){
  render_section_header "${WARP_APP_NAME} - 状态"

  if warp_config_has_outbound; then
    render_info_line "endpoint" "${G}已注入 (tag=${WARP_OUTBOUND_TAG})${N}"
  else
    render_info_line "endpoint" "${R}未注入${N}"
  fi

  if warp_config_has_rule; then
    render_info_line "路由规则" "${G}已生效（google/youtube → ${WARP_OUTBOUND_TAG}）${N}"
  else
    render_info_line "路由规则" "${R}未生效${N}"
  fi

  local ep_host ep_port
  read -r ep_host ep_port <<< "$(warp_current_endpoint)"
  render_info_line "端点" "${ep_host}:${ep_port}"

  if [ -s "$WARP_ACCOUNT_JSON" ]; then
    render_info_line "WARP 账号" "${G}已注册${N} ${D}($(stat -c %y "$WARP_ACCOUNT_JSON" 2>/dev/null | cut -d. -f1))${N}"
  elif [ -f "${WARP_DIR}/wgcf-profile.conf" ]; then
    render_info_line "WARP 账号" "${Y}旧版 wgcf 格式，请「重新注册」迁移${N}"
  else
    render_info_line "WARP 账号" "${R}未注册${N}"
  fi

  if systemctl is-active sing-box >/dev/null 2>&1; then
    render_info_line "sing-box" "${G}运行中${N}"
  else
    render_info_line "sing-box" "${R}未运行${N}"
  fi

  echo ""
  warp_log_info "config.json 中的 WARP 相关片段："
  if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_PATH" ]; then
    jq --arg tag "$WARP_OUTBOUND_TAG" --arg rs "$WARP_RULESET_TAG" --arg rsyt "$WARP_RULESET_TAG_YT" '
      {
        endpoint:  (.endpoints // [] | map(select(.tag == $tag)) | .[0] // null),
        rule_sets: (.route.rule_set // [] | map(select(.tag == $rs or .tag == $rsyt)) | map(.tag)),
        rule:      (.route.rules // [] | map(select((.outbound // "") == $tag)) | .[0] // null)
      }
    ' "$CONFIG_PATH" 2>/dev/null | sed 's/^/    /'
  fi

  pause_screen
}

# 真实隧道自检：起一个临时 sing-box 实例（socks 入站 + 同款 WireGuard endpoint），
# 经隧道 curl Cloudflare trace。成功把 trace 内容打到 stdout 并返回 0。
# 注意：与主进程共用同一 WARP 账号，并发握手会漂移，测试期间主配置分流可能短暂中断。
warp_probe_via_tunnel(){
  local host="$1" port="$2"
  local WARP_PRIVATE_KEY WARP_LOCAL_V4 WARP_LOCAL_V6 WARP_PEER_PK WARP_RESERVED
  warp_load_profile || return 1

  local addr_json
  if [ -n "$WARP_LOCAL_V6" ]; then
    addr_json=$(jq -nc --arg a "$WARP_LOCAL_V4" --arg b "$WARP_LOCAL_V6" '[$a, $b]')
  else
    addr_json=$(jq -nc --arg a "$WARP_LOCAL_V4" '[$a]')
  fi

  local tmpcfg plog sport pid="" try
  tmpcfg=$(mktemp)
  plog=$(mktemp)
  for try in 1 2 3; do
    sport=$(( (RANDOM % 20000) + 30000 ))
    jq -n \
      --arg host "$host" --arg port "$port" \
      --arg pk "$WARP_PRIVATE_KEY" --arg peerpk "$WARP_PEER_PK" \
      --arg reserved "$WARP_RESERVED" \
      --arg addrs "$addr_json" --arg mtu "$WARP_MTU" \
      --argjson sport "$sport" '
      {
        "log": {"disabled": false, "level": "error"},
        "dns": {"servers": [{"type": "local", "tag": "dns-local"}]},
        "inbounds": [{"type": "socks", "tag": "probe-in", "listen": "127.0.0.1", "listen_port": $sport}],
        "endpoints": [{
          "type": "wireguard", "tag": "warp-probe", "system": false,
          "mtu": ($mtu | tonumber), "address": ($addrs | fromjson), "private_key": $pk,
          "peers": [{
            "address": $host, "port": ($port | tonumber), "public_key": $peerpk,
            "allowed_ips": ["0.0.0.0/0", "::/0"],
            "reserved": ($reserved | split(",") | map(tonumber))
          }]
        }],
        "route": {"final": "warp-probe", "default_domain_resolver": "dns-local"}
      }' > "$tmpcfg" 2>/dev/null || { rm -f "$tmpcfg" "$plog"; return 1; }
    sing-box run -c "$tmpcfg" >"$plog" 2>&1 &
    pid=$!
    sleep 1
    kill -0 "$pid" 2>/dev/null && break
    pid=""   # 端口被占等启动失败，换个端口重试
  done
  if [ -z "$pid" ]; then
    warp_log_err "临时 sing-box 实例启动失败："
    tail -5 "$plog" | sed 's/^/    /' >&2
    rm -f "$tmpcfg" "$plog"
    return 1
  fi

  # socks5://（非 socks5h）让 curl 在本机解析域名，探测不依赖隧道内 DNS
  local trace rc
  trace=$(curl -4 -fsS --max-time 12 -x "socks5://127.0.0.1:${sport}" \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
  rc=$?
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  if [ "$rc" -ne 0 ] || [ -z "$trace" ]; then
    if [ -s "$plog" ]; then
      warp_log_warn "临时实例日志（最后几行）："
      tail -3 "$plog" | sed 's/^/    /' >&2
    fi
    rm -f "$tmpcfg" "$plog"
    return 1
  fi
  rm -f "$tmpcfg" "$plog"
  printf '%s\n' "$trace"
}

warp_do_test(){
  warp_log_info "sing-box 配置语法："
  if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
    warp_log_ok "通过"
  else
    warp_log_err "未通过：sing-box check -c $CONFIG_PATH"
    sing-box check -c "$CONFIG_PATH" 2>&1 | sed 's/^/    /'
  fi

  local host port
  read -r host port <<< "$(warp_current_endpoint)"

  echo ""
  warp_log_info "WARP 隧道自检：起临时实例，真实经 ${host}:${port} 走一次隧道（约 10 秒）..."
  echo -e "  ${D}与主服务共用同一 WARP 账号，测试期间分流可能短暂抖动，属正常${N}"
  local trace
  if trace=$(warp_probe_via_tunnel "$host" "$port"); then
    local w ip loc colo
    w=$(printf '%s\n' "$trace"    | awk -F= '/^warp=/ {print $2}')
    ip=$(printf '%s\n' "$trace"   | awk -F= '/^ip=/   {print $2}')
    loc=$(printf '%s\n' "$trace"  | awk -F= '/^loc=/  {print $2}')
    colo=$(printf '%s\n' "$trace" | awk -F= '/^colo=/ {print $2}')
    warp_log_ok "隧道可用：warp=${w:-?}  出口IP=${ip:-?}  区域=${loc:-?}  PoP=${colo:-?}"
    case "$loc" in
      CN|HK|MO|RU)
        warp_log_warn "出口区域 ${loc} 在 Gemini 的不服务名单里，Gemini 仍会拒绝（油管不受影响）"
        echo -e "  ${D}免费 WARP 出口 PoP 由 anycast 路由决定，「重新注册」基本换不了区域；${N}"
        echo -e "  ${D}想真正选区：上 Cloudflare Zero Trust（免费 50 用户）在 device profile 选 PoP，${N}"
        echo -e "  ${D}或用甬哥 warp-yg 的端点优选：https://github.com/yonggekkk/warp-yg${N}"
        ;;
    esac
  else
    warp_log_err "WARP 隧道不通（握手失败或无数据）"
    echo -e "  ${D}最常见原因：本机到 Cloudflare 的 UDP ${port} 被封或严重丢包${N}"
    echo -e "  ${D}处理：菜单「4 端点优选」自动扫描候选 IP:端口；若全部不通，${N}"
    echo -e "  ${D}说明本机 UDP 出网被封，WireGuard/WARP 方案在这台机器不可行${N}"
  fi

  echo ""
  warp_log_info "${B}如何确认 Google 解锁已生效${N}"
  echo -e "  ${D}1.${N} 用客户端（v2rayN/Stash 等）通过 Reality/Hy2 节点连进来"
  echo -e "  ${D}2.${N} 浏览器开 https://www.google.com/search?q=my+ip — Google 应显示 Cloudflare WARP 出口位置"
  echo -e "  ${D}3.${N} 浏览器开 https://gemini.google.com — 应能正常加载"
  echo -e "  ${D}4.${N} 看 sing-box 日志：journalctl -u sing-box -f  — 命中规则的请求会显示 outbound=${WARP_OUTBOUND_TAG}"
}

# 端点优选：逐个测试候选 IP:端口，第一个能通的写入配置并重启
# 适用：默认端点 162.159.192.1:2408 的 UDP 被封/丢包严重时
warp_do_endpoint_pick(){
  require_root || return 1
  render_section_header "${WARP_APP_NAME} - 端点优选"
  if ! warp_config_has_outbound; then
    warp_log_err "尚未安装 WARP 分流，请先安装"
    pause_screen
    return 1
  fi
  echo -e "  ${D}逐个真实测试候选端点（每个最多约 15 秒），第一个能通的写入配置${N}"
  echo -e "  ${D}测试期间 WARP 分流可能短暂中断，完成后自动恢复${N}"
  echo ""

  local cand host port trace txn
  for cand in $WARP_ENDPOINT_CANDIDATES; do
    host="${cand%:*}"
    port="${cand##*:}"
    warp_log_info "测试 ${cand} ..."
    if trace=$(warp_probe_via_tunnel "$host" "$port"); then
      warp_log_ok "可用：${cand}"
      txn=$(warp_transaction_begin) || { warp_log_err "WARP 事务快照失败"; pause_screen; return 1; }
      if ! warp_jq_apply '
          .endpoints = ((.endpoints // []) | map(
            if .tag == $tag
            then (.peers[0].address = $host | .peers[0].port = ($port | tonumber))
            else . end))
        ' --arg tag "$WARP_OUTBOUND_TAG" --arg host "$host" --arg port "$port"; then
        warp_transaction_rollback "$txn"
        warp_log_err "写入配置失败，已恢复原端点"
        pause_screen
        return 1
      fi
      if config_check_and_restart; then
        warp_transaction_commit "$txn"
        warp_log_ok "已切换端点为 ${cand} 并重启 sing-box"
      else
        warp_transaction_rollback "$txn"
        warp_log_err "sing-box 重启失败，已恢复原端点"
        pause_screen
        return 1
      fi
      pause_screen
      return 0
    fi
    warp_log_warn "不通：${cand}"
  done

  warp_log_err "所有候选端点都不通 —— 本机到 Cloudflare 的 UDP 大概率被整段封锁"
  echo -e "  ${D}WireGuard 只能走 UDP，没法换 TCP；这台机器上 WARP 方案基本不可行，${N}"
  echo -e "  ${D}建议换机，或改用「解锁 DNS / 落地中转」类方案${N}"
  pause_screen
}

# 重新注入分流规则：不动账号，只按当前版本的模板重写 endpoint/规则集/路由规则
# 适用：老版本装的 WARP（缺 YouTube 规则集、缺域名嗅探、缺 DNS 解析器）升级修复
warp_do_reinject(){
  require_root || return 1
  require_singbox_installed || return 1
  ensure_jq || return 1
  render_section_header "${WARP_APP_NAME} - 重新注入分流规则"
  echo -e "  ${D}用途：升级旧配置（补 YouTube 规则集 / 域名嗅探 / DNS 解析器 / reserved 字段）或修复被改坏的规则${N}"
  echo -e "  ${D}不改 WARP 账号，不改已优选的端点${N}"
  echo ""

  warp_require_singbox_112 || { pause_screen; return 1; }

  local txn WARP_PRIVATE_KEY WARP_LOCAL_V4 WARP_LOCAL_V6 WARP_PEER_PK WARP_RESERVED
  warp_load_profile || { pause_screen; return 1; }
  txn=$(warp_transaction_begin) || { warp_log_err "WARP 事务快照失败"; pause_screen; return 1; }
  if ! warp_config_inject "$WARP_LOCAL_V4" "$WARP_LOCAL_V6" "$WARP_PRIVATE_KEY" "$WARP_PEER_PK" "$WARP_RESERVED" \
     || ! config_check_and_restart; then
    warp_transaction_rollback "$txn"
    warp_log_err "重新注入失败，已恢复原配置"
    pause_screen
    return 1
  fi
  warp_transaction_commit "$txn"
  warp_log_ok "规则已重新注入，sing-box 已重启"
  pause_screen
}

show_warp_menu(){
  while true; do
    render_section_header "${WARP_APP_NAME}"

    if ! is_singbox_installed; then
      render_info_line "前置条件" "${R}sing-box 未安装${N}"
      render_divider
      echo -e "  请先到「节点管理 → 创建节点」安装 sing-box 与任一节点。"
      render_menu_item 0 "返回上级"
      render_divider
      local choice0
      read -r -p "  请输入序号: " choice0
      case "$choice0" in 0) return ;; *) notify_invalid_choice ;; esac
      continue
    fi

    local installed=0
    warp_config_has_outbound && installed=1

    if [ "$installed" = "1" ]; then
      render_info_line "状态" "${G}已启用（google/youtube → WARP）${N}"
    else
      render_info_line "状态" "${Y}未启用${N}"
    fi
    render_divider

    if [ "$installed" = "1" ]; then
      render_menu_item 1 "查看状态"
      render_menu_item 2 "测试连通性 ${D}（真实走一次 WARP 隧道）${N}"
      render_menu_item 3 "重新注册 WARP 账号 ${D}（换 WARP IP）${N}"
      render_menu_item 4 "端点优选 ${D}（隧道不通时自动换可用 IP:端口）${N}"
      render_menu_item 5 "重新注入分流规则 ${D}（升级旧配置 / 修复规则）${N}"
      render_menu_item 9 "卸载"
    else
      render_menu_item 1 "安装 ${WARP_APP_NAME}"
    fi
    render_menu_item 0 "返回上级"
    render_divider
    local choice
    read -r -p "  请输入序号: " choice

    if [ "$installed" = "0" ]; then
      case "$choice" in
        1) warp_do_install ;;
        0) return ;;
        *) notify_invalid_choice ;;
      esac
      continue
    fi

    case "$choice" in
      1) warp_do_status ;;
      2) render_section_header "${WARP_APP_NAME} - 测试"; warp_do_test; pause_screen ;;
      3) warp_do_reregister ;;
      4) warp_do_endpoint_pick ;;
      5) warp_do_reinject ;;
      9) warp_do_uninstall ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

# ─── 服务器状态面板 ───────────────────────────────────
# ═══ source: 92-status.sh ═══
status_format_bytes(){
  local b="${1:-0}"
  case "$b" in ''|*[!0-9]*) b=0 ;; esac
  if   [ "$b" -ge 1099511627776 ]; then awk -v n="$b" 'BEGIN{printf "%.2f TiB", n/1099511627776}'
  elif [ "$b" -ge 1073741824 ];    then awk -v n="$b" 'BEGIN{printf "%.2f GiB", n/1073741824}'
  elif [ "$b" -ge 1048576 ];       then awk -v n="$b" 'BEGIN{printf "%.2f MiB", n/1048576}'
  elif [ "$b" -ge 1024 ];          then awk -v n="$b" 'BEGIN{printf "%.2f KiB", n/1024}'
  else printf '%s B' "$b"
  fi
}

status_format_speed(){
  local bps="${1:-0}"
  case "$bps" in ''|*[!0-9]*) bps=0 ;; esac
  if   [ "$bps" -ge 1073741824 ]; then awk -v n="$bps" 'BEGIN{printf "%.2f GiB/s", n/1073741824}'
  elif [ "$bps" -ge 1048576 ];    then awk -v n="$bps" 'BEGIN{printf "%.2f MiB/s", n/1048576}'
  elif [ "$bps" -ge 1024 ];       then awk -v n="$bps" 'BEGIN{printf "%.2f KiB/s", n/1024}'
  else printf '%s B/s' "$bps"
  fi
}

status_progress_bar(){
  local pct="${1:-0}" width="${2:-22}"
  case "$pct" in ''|*[!0-9]*) pct=0 ;; esac
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ] && pct=0

  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local color="$G"
  [ "$pct" -ge 70 ] && color="$Y"
  [ "$pct" -ge 90 ] && color="$R"

  printf "${color}"
  [ "$filled" -gt 0 ] && printf '%.0s█' $(seq 1 "$filled")
  printf "${D}"
  [ "$empty" -gt 0 ] && printf '%.0s░' $(seq 1 "$empty")
  printf "${N}"
}

status_read_cpu(){
  awk '/^cpu / {
    total=$2+$3+$4+$5+$6+$7+$8+$9+$10+$11
    idle=$5+$6
    print total" "idle
    exit
  }' /proc/stat
}

status_sample_cpu(){
  local s1 s2 t1 t2 i1 i2 dt di
  s1=$(status_read_cpu); t1=${s1% *}; i1=${s1#* }
  sleep 1
  s2=$(status_read_cpu); t2=${s2% *}; i2=${s2#* }
  dt=$(( t2 - t1 ))
  di=$(( i2 - i1 ))
  if [ "$dt" -le 0 ]; then printf '0'; return; fi
  printf '%d' $(( (dt - di) * 100 / dt ))
}

status_default_iface(){
  ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}'
}

status_read_iface(){
  local iface="$1"
  awk -v key="${iface}:" '$1==key {print $2" "$10; exit}' /proc/net/dev
}

status_sample_speed(){
  local iface="$1" v rx1 tx1 rx2 tx2
  v=$(status_read_iface "$iface"); rx1=${v% *}; tx1=${v#* }
  sleep 1
  v=$(status_read_iface "$iface"); rx2=${v% *}; tx2=${v#* }
  printf '%s %s' "$(( rx2 - rx1 ))" "$(( tx2 - tx1 ))"
}

status_service_state(){
  local name="$1" bin="$2"
  if [ -n "$bin" ] && ! command -v "$bin" >/dev/null 2>&1 \
     && ! systemctl list-unit-files "${name}.service" >/dev/null 2>&1; then
    printf "${D}未安装${N}"
    return
  fi
  if systemctl is-active "$name" >/dev/null 2>&1; then
    printf "${G}running${N}"
  elif systemctl list-unit-files "${name}.service" >/dev/null 2>&1; then
    printf "${R}stopped${N}"
  else
    printf "${D}未安装${N}"
  fi
}

show_server_status(){
  render_section_header "服务器状态"

  local hostname_str distro_str kernel_str uptime_str load_str
  local cpu_model cpu_cores cpu_pct
  local mem_total mem_avail mem_used mem_pct
  local swap_total swap_free swap_used swap_pct
  local iface speeds rx tx ipv4 ipv6 tcp_count listen_count

  hostname_str=$(hostname 2>/dev/null || echo "unknown")
  kernel_str=$(uname -r 2>/dev/null || echo "unknown")
  if [ -r /etc/os-release ]; then
    distro_str=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-${NAME:-unknown}}")
  else
    distro_str="unknown"
  fi
  uptime_str=$(uptime -p 2>/dev/null | sed 's/^up //')
  [ -z "$uptime_str" ] && uptime_str=$(awk '{d=int($1/86400); h=int(($1%86400)/3600); m=int(($1%3600)/60); printf "%dd %dh %dm", d, h, m}' /proc/uptime 2>/dev/null)
  load_str=$(awk '{printf "%s, %s, %s", $1, $2, $3}' /proc/loadavg 2>/dev/null)

  cpu_model=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
  [ -z "$cpu_model" ] && cpu_model=$(awk -F': ' '/^Hardware/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
  [ -z "$cpu_model" ] && cpu_model="unknown"
  cpu_cores=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)
  [ -z "$cpu_cores" ] && cpu_cores="?"

  echo -e "  ${B}${C}›  系统${N}"
  printf "  ${L}●${N} %-10s : %s\n" "主机名"   "$hostname_str"
  printf "  ${L}●${N} %-10s : %s\n" "发行版"   "$distro_str"
  printf "  ${L}●${N} %-10s : %s\n" "内核"     "$kernel_str"
  printf "  ${L}●${N} %-10s : %s\n" "运行时长" "${uptime_str:-unknown}"
  printf "  ${L}●${N} %-10s : %s\n" "负载"     "${load_str:-unknown}"
  echo ""

  echo -e "  ${C}采样 CPU / 网络中（约 1 秒）...${N}"
  cpu_pct=$(status_sample_cpu)
  iface=$(status_default_iface)
  rx=0; tx=0
  if [ -n "$iface" ]; then
    speeds=$(status_sample_speed "$iface")
    rx=${speeds% *}; tx=${speeds#* }
  fi
  printf "\033[1A\033[2K"

  echo -e "  ${B}${C}›  CPU${N}"
  printf "  ${L}●${N} %-10s : %s × %s 核\n" "型号"   "$cpu_model" "$cpu_cores"
  printf "  ${L}●${N} %-10s : %3d%%  %s\n"  "使用率" "$cpu_pct" "$(status_progress_bar "$cpu_pct")"
  echo ""

  mem_total=$(awk '/^MemTotal:/ {print $2}'     /proc/meminfo)
  mem_avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  swap_total=$(awk '/^SwapTotal:/ {print $2}'   /proc/meminfo)
  swap_free=$(awk '/^SwapFree:/ {print $2}'     /proc/meminfo)
  : "${mem_total:=0}"; : "${mem_avail:=0}"; : "${swap_total:=0}"; : "${swap_free:=0}"
  mem_used=$(( mem_total - mem_avail ))
  swap_used=$(( swap_total - swap_free ))
  mem_pct=0;  [ "$mem_total"  -gt 0 ] && mem_pct=$((  mem_used  * 100 / mem_total  ))
  swap_pct=0; [ "$swap_total" -gt 0 ] && swap_pct=$(( swap_used * 100 / swap_total ))

  echo -e "  ${B}${C}›  内存${N}"
  printf "  ${L}●${N} %-10s : %s / %s  (%3d%%)  %s\n" "RAM" \
    "$(status_format_bytes $((mem_used*1024)))" \
    "$(status_format_bytes $((mem_total*1024)))" \
    "$mem_pct" "$(status_progress_bar "$mem_pct")"
  if [ "$swap_total" -gt 0 ]; then
    printf "  ${L}●${N} %-10s : %s / %s  (%3d%%)  %s\n" "SWAP" \
      "$(status_format_bytes $((swap_used*1024)))" \
      "$(status_format_bytes $((swap_total*1024)))" \
      "$swap_pct" "$(status_progress_bar "$swap_pct")"
  else
    printf "  ${L}●${N} %-10s : ${D}未启用${N}\n" "SWAP"
  fi
  echo ""

  echo -e "  ${B}${C}›  磁盘${N}"
  local disk_rows
  disk_rows=$(df -hP -x tmpfs -x devtmpfs -x squashfs -x overlay -x aufs 2>/dev/null \
              | awk 'NR>1 && $6 !~ /^\/(proc|sys|run|dev|var\/lib\/docker)/ {print $2"|"$3"|"$5"|"$6}')
  if [ -n "$disk_rows" ]; then
    local size used pct mount line
    while IFS='|' read -r size used pct mount; do
      [ -z "$mount" ] && continue
      pct=${pct%\%}
      case "$pct" in ''|*[!0-9]*) pct=0 ;; esac
      printf "  ${L}●${N} %-14s : %7s / %-7s  (%3d%%)  %s\n" \
        "$mount" "$used" "$size" "$pct" "$(status_progress_bar "$pct" 18)"
    done <<< "$disk_rows"
  else
    printf "  ${L}●${N} %-10s : ${D}未识别到挂载点${N}\n" "/"
  fi
  echo ""

  echo -e "  ${B}${C}›  网络${N}"
  ipv4=$(detect_primary_ipv4)
  ipv6=$(detect_primary_ipv6)
  printf "  ${L}●${N} %-10s : %s\n" "IPv4" "${ipv4:-${D}未检测到${N}}"
  printf "  ${L}●${N} %-10s : %s\n" "IPv6" "${ipv6:-${D}未检测到${N}}"
  if [ -n "$iface" ]; then
    printf "  ${L}●${N} %-10s : %s   ${G}↓${N} %s   ${C}↑${N} %s\n" \
      "实时速率" "$iface" "$(status_format_speed "$rx")" "$(status_format_speed "$tx")"
  fi
  if command -v ss >/dev/null 2>&1; then
    tcp_count=$(ss -tnH state established 2>/dev/null | wc -l)
    listen_count=$(ss -tlnH 2>/dev/null | wc -l)
    printf "  ${L}●${N} %-10s : %s   监听端口 %s\n" "TCP 连接" "$tcp_count" "$listen_count"
  fi
  echo ""

  echo -e "  ${B}${C}›  服务${N}"
  printf "  ${L}●${N} %-10s : %s\n" "sing-box" "$(status_service_state sing-box sing-box)"

  pause_screen
}

# ═══ source: 99-menu-main.sh ═══
show_firewall_menu(){
  while true; do
    render_section_header "防火墙管理"
    render_menu_item 1 "IPv4 防火墙管理"
    render_menu_item 2 "IPv6 防火墙管理"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        show_ipv4_firewall_menu
        ;;
      2)
        show_ipv6_firewall_menu
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

    if [ "$(count_installed_nodes)" -gt 0 ]; then
      main_action_label="节点管理"
    else
      main_action_label="创建节点"
    fi

    clear
    render_brand_banner
    render_main_menu_card
    render_menu_item 1 "管理员设置"
    render_menu_item 2 "系统基础设置"
    render_menu_item 3 "${main_action_label}"
    render_menu_item 4 "网络管理"
    render_menu_item 5 "防火墙管理"
    render_menu_item 6 "卸载脚本"
    render_menu_item 7 "更新管理"
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
        if [ "$(count_installed_nodes)" -eq 0 ]; then
          show_node_install_menu
        else
          show_node_manage_menu
        fi
        ;;
      4)
        show_network_menu
        ;;
      5)
        show_firewall_menu
        ;;
      6)
        uninstall_script_completely
        ;;
      7)
        show_update_menu
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
# 测试只加载函数时设置 LEYILI_SOURCE_ONLY=1，不执行菜单、写入口或获取全局锁。
if [ "${LEYILI_SOURCE_ONLY:-0}" != "1" ]; then
  if [ "${LEYILI_ALLOW_ANY_DISTRO:-0}" != "1" ] && ! require_debian_family; then
    exit 1
  fi
  if ! acquire_global_lock; then
    exit 1
  fi

  register_sb_command
  sb_install_rc=$?

  # curl … | bash 时 stdin 就是脚本自身，bash 读完只剩 EOF：
  # 菜单的 read 会立刻返回空值，一路掉进「无效选项」死循环。先把 stdin 接回控制终端。
  if attach_terminal_stdin; then
    # show_menu 第一件事就是 clear，安装失败的提示会被立刻抹掉；
    # 先停下来等回车，否则用户到下次敲 sb 才发现命令不存在。
    if [ "$sb_install_rc" -ne 0 ]; then
      read -r -p "  按回车继续进入菜单..." _ || true
    fi
    show_menu
  else
    # 真的没有终端（cron / CI / 无 tty 的管道）：装完入口就收工，不进交互菜单。
    echo ""
    if [ "$sb_install_rc" -ne 0 ]; then
      echo -e "  ${R}当前会话没有可用终端，且 ${COMMAND_NAME} 入口未安装成功${N}"
      exit 1
    fi
    echo -e "  ${G}${COMMAND_NAME} 命令已安装到 ${SCRIPT_PATH}${N}"
    echo -e "  当前会话没有可用终端，请在终端里执行 ${B}${COMMAND_NAME}${N} 打开菜单。"
  fi
fi
