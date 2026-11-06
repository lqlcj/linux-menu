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

# 白名单：IPv4/IPv6 地址或 CIDR，逗号/空格分隔，自动去重。
# 回环地址总会写入配置，这里直接滤掉；单独输入 "-" 表示清空。
# 返回 0=成功（结果可为空）/ 1=格式错误 / 2=超过 FAIL2BAN_IGNOREIP_MAX 项
normalize_fail2ban_ignoreip_list(){
  local raw="${1:-}" item addr mask max out="" count=0
  local -a items=()

  [ "$raw" = "-" ] && return 0
  raw="${raw//，/,}"
  raw="${raw//；/,}"
  raw="${raw//;/,}"
  raw="${raw//$'\t'/,}"
  raw="${raw// /,}"
  IFS=',' read -r -a items <<< "$raw"

  for item in "${items[@]}"; do
    [ -n "$item" ] || continue
    addr="${item%%/*}"
    mask=""
    case "$item" in
      */*/*) return 1 ;;
      */*)
        mask="${item#*/}"
        case "$mask" in ''|*[!0-9]*) return 1 ;; esac
        [ "${#mask}" -le 3 ] || return 1
        ;;
    esac
    if is_valid_ipv4 "$addr"; then
      max=32
    elif is_valid_ipv6_text "$addr"; then
      max=128
    else
      return 1
    fi
    if [ -n "$mask" ] && [ "$((10#$mask))" -gt "$max" ]; then
      return 1
    fi

    case "$item" in
      127.0.0.1|127.0.0.1/8|::1|::1/128) continue ;;
    esac
    case ",${out}," in
      *",${item},"*) continue ;;
    esac

    count=$((count + 1))
    [ "$count" -le "$FAIL2BAN_IGNOREIP_MAX" ] || return 2
    out="${out:+${out},}${item}"
  done

  printf '%s' "$out"
}

# 读取脚本自己管理的 jail 文件里 [sshd] 段的某个键（兼容旧版只有 [sshd] 段的文件）
fail2ban_saved_jail_value(){
  local key="$1"
  [ -f "$FAIL2BAN_JAIL_PATH" ] || return 0
  awk -v k="$key" '
    /^[[:space:]]*\[/ {
      s = $0
      sub(/^[[:space:]]*\[/, "", s)
      sub(/\].*$/, "", s)
      gsub(/[[:space:]]/, "", s)
      in_sshd = (s == "sshd")
      next
    }
    in_sshd && $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") {
      v = $0
      sub(/^[^=]*=/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      print v
      exit
    }
  ' "$FAIL2BAN_JAIL_PATH" 2>/dev/null
}

# 0.11 起才有 bantime.increment；识别不了版本时按新版处理，交给 fail2ban-client -t 兜底
fail2ban_supports_increment(){
  local version
  version=$(fail2ban-client --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1)
  [ -n "$version" ] || return 0
  [ "$(printf '%s\n%s\n' 0.11 "$version" | sort -V | head -n 1)" = "0.11" ]
}

# 按 fail2ban 的读取顺序找出 logtarget 的最终值（跳过脚本自己的文件）
fail2ban_effective_logtarget(){
  local f v value=""
  for f in "$FAIL2BAN_ETC_DIR"/fail2ban.conf "$FAIL2BAN_ETC_DIR"/fail2ban.d/*.conf \
           "$FAIL2BAN_ETC_DIR"/fail2ban.local "$FAIL2BAN_ETC_DIR"/fail2ban.d/*.local; do
    [ -f "$f" ] || continue
    [ "$f" = "$FAIL2BAN_DAEMON_CONF_PATH" ] && continue
    v=$(awk '
      /^[[:space:]]*logtarget[[:space:]]*=/ {
        v = $0
        sub(/^[^=]*=/, "", v)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        last = v
      }
      END { print last }
    ' "$f" 2>/dev/null)
    [ -n "$v" ] && value="$v"
  done
  printf '%s' "$value"
}

fail2ban_format_duration(){
  local s="$1"
  if [ "$s" -ge 86400 ] && [ $((s % 86400)) -eq 0 ]; then
    printf '%s 天' $((s / 86400))
  elif [ "$s" -ge 3600 ] && [ $((s % 3600)) -eq 0 ]; then
    printf '%s 小时' $((s / 3600))
  elif [ "$s" -ge 60 ] && [ $((s % 60)) -eq 0 ]; then
    printf '%s 分钟' $((s / 60))
  else
    printf '%s 秒' "$s"
  fi
}

# 生成 jail 文件正文。参数：端口列表、白名单（逗号分隔，可空）、recidive 日志路径、是否启用累进(1/0)
fail2ban_render_jail(){
  local ports="$1" ignoreips="$2" recidive_log="$3" increment="$4"
  local ignore_line="127.0.0.1/8 ::1"

  [ -n "$ignoreips" ] && ignore_line="${ignore_line} ${ignoreips//,/ }"

  printf '# Managed by %s — do not edit by hand, it will be overwritten.\n' "$APP_NAME"
  printf '[sshd]\n'
  printf 'enabled      = true\n'
  printf 'port         = %s\n' "$ports"
  printf 'backend      = systemd\n'
  printf 'journalmatch = %s\n' "$FAIL2BAN_SSHD_JOURNALMATCH"
  # aggressive = normal + ddos + extra：连只握手不输密码、协商失败断开的扫描也计入
  printf 'mode         = aggressive\n'
  printf 'maxretry     = %s\n' "$FAIL2BAN_MAXRETRY"
  printf 'findtime     = %s\n' "$FAIL2BAN_FINDTIME"
  printf 'bantime      = %s\n' "$FAIL2BAN_BANTIME"
  if [ "$increment" = "1" ]; then
    printf 'bantime.increment = true\n'
    printf 'bantime.maxtime   = %s\n' "$FAIL2BAN_BANTIME_MAXTIME"
  fi
  printf 'ignoreip     = %s\n' "$ignore_line"
  printf '\n'
  printf '# 惯犯：一段时间内被任意 jail 多次封禁，改为全端口封禁\n'
  printf '[recidive]\n'
  printf 'enabled   = true\n'
  printf 'backend   = auto\n'
  printf 'logpath   = %s\n' "$recidive_log"
  printf 'banaction = %%(banaction_allports)s\n'
  printf 'maxretry  = %s\n' "$FAIL2BAN_RECIDIVE_MAXRETRY"
  printf 'findtime  = %s\n' "$FAIL2BAN_RECIDIVE_FINDTIME"
  printf 'bantime   = %s\n' "$FAIL2BAN_RECIDIVE_BANTIME"
  printf 'ignoreip  = %s\n' "$ignore_line"
}

# 生成守护进程配置正文。第二个参数非空时同时指定 logtarget（原配置不是写文件时 recidive 无日志可读）
fail2ban_render_daemon_conf(){
  local logtarget="$1"
  printf '# Managed by %s — do not edit by hand, it will be overwritten.\n' "$APP_NAME"
  printf '[Definition]\n'
  printf 'dbpurgeage = %s\n' "$FAIL2BAN_DBPURGEAGE"
  [ -n "$logtarget" ] && printf 'logtarget = %s\n' "$logtarget"
  return 0
}

# 从标准输入原子写入受管文件
fail2ban_write_managed_file(){
  local target="$1" target_dir tmp

  target_dir=$(dirname -- "$target")
  if [ -L "$target" ] || [ -L "$target_dir" ]; then
    echo -e "${R}拒绝写入符号链接：${target}${N}" >&2
    return 1
  fi
  mkdir -p -- "$target_dir" || return 1
  tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
  if ! cat > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$target"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# 事务快照：两个受管文件 + 服务启用/运行状态，全部记在私有临时目录里
fail2ban_transaction_begin(){
  local txn_dir

  txn_dir=$(mktemp -d "${TMPDIR:-/tmp}/leyili-fail2ban.XXXXXX") || return 1
  if ! chmod 700 "$txn_dir"; then
    rm -rf -- "$txn_dir"
    return 1
  fi
  if [ -f "$FAIL2BAN_JAIL_PATH" ]; then
    { cp -a -- "$FAIL2BAN_JAIL_PATH" "$txn_dir/jail" && : > "$txn_dir/jail.existed"; } \
      || { rm -rf -- "$txn_dir"; return 1; }
  fi
  if [ -f "$FAIL2BAN_DAEMON_CONF_PATH" ]; then
    { cp -a -- "$FAIL2BAN_DAEMON_CONF_PATH" "$txn_dir/daemon" && : > "$txn_dir/daemon.existed"; } \
      || { rm -rf -- "$txn_dir"; return 1; }
  fi
  systemctl is-active --quiet fail2ban 2>/dev/null && : > "$txn_dir/was_active"
  systemctl is-enabled --quiet fail2ban 2>/dev/null && : > "$txn_dir/was_enabled"
  printf '%s' "$txn_dir"
}

fail2ban_transaction_restore(){
  local txn_dir="$1" rc=0

  if [ -f "$txn_dir/jail.existed" ]; then
    restore_file_snapshot "$txn_dir/jail" "$FAIL2BAN_JAIL_PATH" || rc=1
  else
    rm -f -- "$FAIL2BAN_JAIL_PATH" || rc=1
  fi
  if [ -f "$txn_dir/daemon.existed" ]; then
    restore_file_snapshot "$txn_dir/daemon" "$FAIL2BAN_DAEMON_CONF_PATH" || rc=1
  else
    rm -f -- "$FAIL2BAN_DAEMON_CONF_PATH" || rc=1
  fi
  if [ -f "$txn_dir/was_enabled" ]; then
    systemctl enable fail2ban >/dev/null 2>&1 || rc=1
  else
    systemctl disable fail2ban >/dev/null 2>&1 || rc=1
  fi
  if [ -f "$txn_dir/was_active" ]; then
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

# backend=systemd 需要 python3-systemd；Debian 12 起没有 auth.log，缺它 sshd jail 直接起不来
fail2ban_install_packages(){
  local -a missing=()

  command -v fail2ban-client >/dev/null 2>&1 || missing+=(fail2ban)
  dpkg -s python3-systemd >/dev/null 2>&1 || missing+=(python3-systemd)
  if [ "${#missing[@]}" -eq 0 ]; then
    echo -e "  ${L}●${N} fail2ban 与 python3-systemd 已安装，跳过安装步骤"
    return 0
  fi

  echo -e "${Y}==> 安装 ${missing[*]}...${N}"
  if DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"; then
    return 0
  fi
  echo -e "${Y}==> 安装失败，刷新 apt 索引后重试...${N}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

# 自检：fail2ban 跑着不代表真在封——sshd 不记日志或 journalmatch 对不上时，它一条失败也看不到
fail2ban_sshd_logging_check(){
  local level recent
  local -a match_args=()

  level=$(get_effective_sshd_value LogLevel)
  case "$level" in
    quiet|fatal|error)
      echo -e "  ${R}✗${N} sshd LogLevel=${level}，不会记录认证失败，fail2ban 无从封禁"
      echo -e "    ${D}请在 sshd_config 中改为 LogLevel INFO 或 VERBOSE${N}"
      return 1
      ;;
  esac

  command -v journalctl >/dev/null 2>&1 || return 0
  read -r -a match_args <<< "$FAIL2BAN_SSHD_JOURNALMATCH"
  recent=$(journalctl -q --no-pager -o cat --since=-7d -n 1 "${match_args[@]}" 2>/dev/null)
  if [ -z "$recent" ]; then
    echo -e "  ${Y}!${N} 近 7 天 journal 里没有匹配到任何 sshd 日志，fail2ban 可能读不到 SSH 失败记录"
    echo -e "    ${D}排查：journalctl -u ssh -n 20；确认 sshd 日志写进了 journal${N}"
    return 1
  fi
  echo -e "  ${G}✓${N} journal 中能读到 sshd 日志"
  return 0
}

setup_fail2ban(){
  if ! require_root; then return 1; fi
  if ! require_debian_family; then
    pause_screen
    return 1
  fi

  render_section_header "安装 / 配置 fail2ban (SSH 多端口)"

  local current_ssh_port default_ports saved_ports input_ports ports normalize_status
  local client_ip saved_ignore default_ignore input_ignore ignoreips
  local logtarget recidive_log daemon_logtarget="" increment=1
  local txn_dir ping_ok=0 i rollback_ok
  current_ssh_port=$(get_current_ssh_port)
  default_ports="$current_ssh_port"

  saved_ports=$(fail2ban_saved_jail_value port)
  if [ -n "$saved_ports" ] && ports=$(normalize_fail2ban_port_list "$saved_ports"); then
    default_ports="$ports"
  fi

  # 白名单默认值：沿用已保存的；首次配置时建议当前 SSH 客户端 IP
  saved_ignore=$(fail2ban_saved_jail_value ignoreip)
  default_ignore=""
  if [ -n "$saved_ignore" ]; then
    default_ignore=$(normalize_fail2ban_ignoreip_list "$saved_ignore" 2>/dev/null) || default_ignore=""
  elif [ -n "${SSH_CLIENT:-}" ]; then
    client_ip=$(printf '%s' "$SSH_CLIENT" | awk '{print $1}')
    client_ip="${client_ip#::ffff:}"
    default_ignore=$(normalize_fail2ban_ignoreip_list "$client_ip" 2>/dev/null) || default_ignore=""
  fi

  echo -e "  ${L}●${N} 当前检测到的 SSH 端口: ${C}${current_ssh_port}${N}"
  if [ "$default_ports" != "$current_ssh_port" ]; then
    echo -e "  ${L}●${N} 当前 fail2ban 保护端口: ${C}${default_ports}${N}"
  fi
  echo -e "  ${L}●${N} sshd 规则: ${C}$(fail2ban_format_duration "$FAIL2BAN_FINDTIME")内失败 ${FAIL2BAN_MAXRETRY} 次 → 封 $(fail2ban_format_duration "$FAIL2BAN_BANTIME")，再犯翻倍，最长 $(fail2ban_format_duration "$FAIL2BAN_BANTIME_MAXTIME")${N}"
  echo -e "  ${L}●${N} 惯犯规则: ${C}$(fail2ban_format_duration "$FAIL2BAN_RECIDIVE_FINDTIME")内被封 ${FAIL2BAN_RECIDIVE_MAXRETRY} 次 → 全端口封 $(fail2ban_format_duration "$FAIL2BAN_RECIDIVE_BANTIME")${N}"
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
  echo -e "  ${Y}规则变严后，自己输错几次密码也会被封。${N}建议把常用的固定 IP / 网段加入白名单。"
  echo -e "  ${D}支持 IPv4/IPv6 地址或 CIDR（如 203.0.113.7, 198.51.100.0/24），逗号或空格分隔；输入 - 清空。${N}"
  echo -e "  ${D}家宽动态 IP 不必填；被误封时可在 VPS 控制台执行 fail2ban-client unban <IP>。${N}"
  while :; do
    read -p "  白名单 IP (回车使用 ${default_ignore:-无}): " input_ignore
    input_ignore="${input_ignore:-$default_ignore}"
    if ignoreips=$(normalize_fail2ban_ignoreip_list "$input_ignore"); then
      break
    else
      normalize_status=$?
    fi
    if [ "$normalize_status" -eq 2 ]; then
      echo -e "  ${R}白名单最多 ${FAIL2BAN_IGNOREIP_MAX} 项${N}"
    else
      echo -e "  ${R}白名单无效：每项需为 IPv4/IPv6 地址或 CIDR${N}"
    fi
  done

  echo ""
  if ! fail2ban_install_packages; then
    echo -e "${R}fail2ban 安装失败，请检查上方输出${N}"
    pause_screen
    return 1
  fi

  if ! fail2ban_supports_increment; then
    increment=0
    echo -e "  ${Y}当前 fail2ban 版本低于 0.11，不支持累进封禁，仅使用固定封禁时长${N}"
  fi

  # recidive 读 fail2ban 自己的日志；原 logtarget 不是文件（SYSTEMD-JOURNAL / SYSLOG 等）时改写到文件
  logtarget=$(fail2ban_effective_logtarget)
  case "$logtarget" in
    /*) recidive_log="$logtarget" ;;
    *)
      recidive_log="$FAIL2BAN_DEFAULT_LOGFILE"
      daemon_logtarget="$FAIL2BAN_DEFAULT_LOGFILE"
      ;;
  esac
  # logpath 指向不存在的文件时 fail2ban 会拒绝启动 recidive
  if [ ! -e "$recidive_log" ] && ! { mkdir -p -- "$(dirname -- "$recidive_log")" && : >> "$recidive_log"; }; then
    echo -e "${R}无法创建 fail2ban 日志文件：${recidive_log}${N}"
    pause_screen
    return 1
  fi

  txn_dir=$(fail2ban_transaction_begin) || {
    echo -e "${R}fail2ban 配置快照失败，未做任何修改${N}"
    pause_screen
    return 1
  }

  if [ -f "$FAIL2BAN_JAIL_PATH" ]; then
    if ! cp -a -- "$FAIL2BAN_JAIL_PATH" "${FAIL2BAN_JAIL_PATH}.bak.$(date +%Y%m%d%H%M%S)"; then
      rm -rf -- "$txn_dir"
      echo -e "${R}fail2ban 旧配置备份失败，未做任何修改${N}"
      pause_screen
      return 1
    fi
    cleanup_old_backups "${FAIL2BAN_JAIL_PATH}.bak.*" 5 \
      || echo -e "${Y}旧 fail2ban 备份清理失败，本次配置仍会继续${N}" >&2
  fi

  if ! fail2ban_render_jail "$ports" "$ignoreips" "$recidive_log" "$increment" \
         | fail2ban_write_managed_file "$FAIL2BAN_JAIL_PATH" \
     || ! fail2ban_render_daemon_conf "$daemon_logtarget" \
         | fail2ban_write_managed_file "$FAIL2BAN_DAEMON_CONF_PATH" \
     || ! fail2ban-client -t >/dev/null 2>&1 \
     || ! systemctl enable fail2ban >/dev/null 2>&1 \
     || ! systemctl restart fail2ban; then
    echo ""
    echo -e "${R}fail2ban 配置校验输出：${N}"
    fail2ban-client -t 2>&1 | tail -n 15 | sed 's/^/    /'
    rollback_ok=1
    fail2ban_transaction_restore "$txn_dir" || rollback_ok=0
    echo ""
    if [ "$rollback_ok" -eq 1 ]; then
      echo -e "${R}fail2ban 配置校验或启动失败，已恢复旧配置与服务状态${N}"
    else
      echo -e "${R}fail2ban 配置失败，且回滚未完全成功，请立即检查服务状态${N}"
    fi
    pause_screen
    return 1
  fi

  # 等待 socket 就绪且两个 jail 都已加载，避免首次启动竞争
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if fail2ban-client status sshd >/dev/null 2>&1 \
       && fail2ban-client status recidive >/dev/null 2>&1; then
      ping_ok=1
      break
    fi
    sleep 1
  done
  if [ "$ping_ok" -ne 1 ]; then
    rollback_ok=1
    fail2ban_transaction_restore "$txn_dir" || rollback_ok=0
    if [ "$rollback_ok" -eq 1 ]; then
      echo -e "${R}fail2ban 已启动但 sshd / recidive jail 未加载，已恢复旧配置与服务状态${N}"
    else
      echo -e "${R}fail2ban jail 未加载，且回滚未完全成功，请立即检查服务状态${N}"
    fi
    echo -e "${Y}排查：journalctl -u fail2ban -n 30${N}"
    pause_screen
    return 1
  fi
  if ! rm -rf -- "$txn_dir"; then
    echo -e "${Y}fail2ban 已生效，但事务临时目录清理失败：${txn_dir}${N}" >&2
  fi

  echo ""
  echo -e "${G}fail2ban 已配置并启动${N}"
  echo -e "  ${L}●${N} jail 配置 : ${C}${FAIL2BAN_JAIL_PATH}${N}"
  echo -e "  ${L}●${N} 守护配置 : ${C}${FAIL2BAN_DAEMON_CONF_PATH}${N}  ${D}(封禁记录保留 $(fail2ban_format_duration "$FAIL2BAN_DBPURGEAGE"))${N}"
  echo -e "  ${L}●${N} 保护端口 : ${C}${ports}${N}"
  echo -e "  ${L}●${N} 白名单   : ${C}127.0.0.1/8 ::1${ignoreips:+ ${ignoreips//,/ }}${N}"
  echo -e "  ${L}●${N} 检测模式 : ${C}aggressive${N}"
  if [ "$increment" -eq 1 ]; then
    echo -e "  ${L}●${N} 封禁时长 : ${C}首次 $(fail2ban_format_duration "$FAIL2BAN_BANTIME")，累进翻倍，最长 $(fail2ban_format_duration "$FAIL2BAN_BANTIME_MAXTIME")${N}"
  else
    echo -e "  ${L}●${N} 封禁时长 : ${C}$(fail2ban_format_duration "$FAIL2BAN_BANTIME")${N}"
  fi
  echo -e "  ${L}●${N} 惯犯日志 : ${C}${recidive_log}${N}"
  echo ""
  echo -e "  ${B}${C}›  日志自检${N}"
  fail2ban_sshd_logging_check || true
  echo ""
  echo -e "  ${B}${C}›  当前 sshd jail 状态${N}"
  fail2ban-client status sshd 2>/dev/null || echo -e "  ${Y}sshd jail 暂未就绪，可稍后执行: fail2ban-client status sshd${N}"

  pause_screen
}
