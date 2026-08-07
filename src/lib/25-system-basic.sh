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
FAIL2BAN_JAIL_PATH="/etc/fail2ban/jail.d/leyili-sshd.local"
FAIL2BAN_MAXRETRY="5"
FAIL2BAN_BANTIME="600"
FAIL2BAN_FINDTIME="300"

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

setup_fail2ban(){
  if ! require_root; then return 1; fi
  if ! require_debian_family; then
    pause_screen
    return 1
  fi

  render_section_header "安装 / 配置 fail2ban (SSH 多端口)"

  local current_ssh_port default_ports saved_ports input_ports ports normalize_status
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

  mkdir -p "$(dirname -- "$FAIL2BAN_JAIL_PATH")"

  if [ -f "$FAIL2BAN_JAIL_PATH" ]; then
    cp -a "$FAIL2BAN_JAIL_PATH" "${FAIL2BAN_JAIL_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    cleanup_old_backups "${FAIL2BAN_JAIL_PATH}.bak.*" 5
  fi

  cat > "$FAIL2BAN_JAIL_PATH" <<EOF
# Managed by ${APP_NAME} — do not edit by hand, it will be overwritten.
[sshd]
enabled  = true
port     = ${ports}
backend  = systemd
maxretry = ${FAIL2BAN_MAXRETRY}
bantime  = ${FAIL2BAN_BANTIME}
findtime = ${FAIL2BAN_FINDTIME}
EOF

  systemctl enable fail2ban >/dev/null 2>&1 || true
  if ! systemctl restart fail2ban; then
    echo ""
    echo -e "${R}fail2ban 启动失败，请运行 systemctl status fail2ban 查看原因${N}"
    pause_screen
    return 1
  fi

  # 等待 socket 就绪再调用 fail2ban-client，避免首次启动竞争
  local i
  for i in 1 2 3 4 5; do
    if fail2ban-client ping >/dev/null 2>&1; then break; fi
    sleep 1
  done

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
