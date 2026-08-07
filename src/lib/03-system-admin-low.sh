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
