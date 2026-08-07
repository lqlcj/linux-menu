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
