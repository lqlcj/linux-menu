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

# 判断 IPv4 是否属于私有 / CGNAT / 链路本地 / loopback / 0.0.0.0
# NAT 型 VPS（阿里云国际轻量、腾讯云轻量、AWS Lightsail、各种 NAT 套餐）网卡绑的是
# 内网 IP，公网 IP 在云厂商 NAT 网关上做映射；本地探测会拿到内网段，需要回退到外部接口。
