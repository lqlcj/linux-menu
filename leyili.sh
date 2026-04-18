#!/bin/bash
set -o pipefail

INSTALL_URL="https://sing-box.app/deb-install.sh"
CONFIG_PATH="/etc/sing-box/config.json"
INFO_PATH="/root/proxy-info.txt"
APP_NAME="Leyili"
COMMAND_NAME="sb"
SCRIPT_PATH="/usr/local/bin/${COMMAND_NAME}"
SELF_INSTALL_URL="${SELF_INSTALL_URL:-https://raw.githubusercontent.com/lqlcj/linux-menu/main/leyili.sh}"
TCP_TUNING_PATH="/etc/sysctl.d/99-proxy-optimized.conf"
INITCWND_SERVICE_PATH="/etc/systemd/system/initcwnd.service"
INITCWND_VALUE="20"
SWAPFILE_PATH="/swapfile"
SWAP_SIZE="2G"
SWAP_SIZE_MB="2048"
SWAP_SYSCTL_PATH="/etc/sysctl.d/99-swap-tuning.conf"
SWAPPINESS_VALUE="10"
ONEPANEL_INSTALL_URL="https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh"
NODEQUALITY_RUN_URL="https://run.NodeQuality.com"
SYSTEM_TIMEZONE="Asia/Shanghai"
BASIC_TOOLS_PACKAGES="curl wget git vim htop unzip net-tools"
SSHD_CONFIG_PATH="/etc/ssh/sshd_config"
SUDOERS_DROPIN_DIR="/etc/sudoers.d"
SSH_RANDOM_PORT_MIN="20000"
SSH_RANDOM_PORT_MAX="65535"

# ─── 颜色 ────────────────────────────────────────────
G="\033[32m" Y="\033[33m" C="\033[36m" R="\033[31m" B="\033[1m" N="\033[0m"
L="\033[94m" W="\033[97m" D="\033[2m"

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

render_divider(){
  echo -e "  ${D}──────────────────────────────────────────────────────${N}"
}

render_brand_banner(){
  echo ""
  echo -e "  ${L}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "  ${L}║${N}  ${B}${W}${APP_NAME}${N}  ${D}Linux Menu${N}"
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

  echo ""
  echo -e "${G}${success_message}${N}"
  echo -e "  备份文件: ${C}$backup_path${N}"
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
      printf '%s' 'IPv6 入站 + IPv4 出站'
      ;;
    dualstack)
      printf '%s' 'IPv4 + IPv6'
      ;;
    *)
      printf '%s' '仅 IPv4'
      ;;
  esac
}

is_singbox_installed(){
  command -v sing-box >/dev/null 2>&1
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

  if [ -f "$CONFIG_PATH" ]; then
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

    if [ -z "$MENU_MODE" ] && grep -Eq '"final":[[:space:]]*"v4-out"' "$CONFIG_PATH"; then
      MENU_MODE="ipv6-in-ipv4-out"
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

build_client_link(){
  local uuid="$1"
  local ip="$2"
  local port="$3"
  local sni="$4"
  local public_key="$5"
  local short_id="$6"
  local tag="${7:-reality}"
  local host="$ip"

  if [ -z "$uuid" ] || [ -z "$ip" ] || [ -z "$port" ] || [ -z "$sni" ] || [ -z "$public_key" ] || [ -z "$short_id" ]; then
    return 1
  fi

  case "$ip" in
    *:*)
      case "$ip" in
        \[*\]) ;;
        *) host="[$ip]" ;;
      esac
      ;;
  esac

  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
    "$uuid" "$host" "$port" "$sni" "$public_key" "$short_id" "$tag"
}

show_status_menu(){
  if ! require_singbox_installed; then
    return
  fi

  while true; do
    render_section_header "查看状态"
    render_menu_item 1 "查看运行状态"
    render_menu_item 2 "实时日志"
    render_menu_item 3 "重启服务"
    render_menu_item 4 "停止服务"
    render_menu_item 5 "启动服务"
    render_menu_item 6 "查看客户端链接"
    render_menu_item 7 "节点二维码"
    render_menu_item 8 "修改节点参数"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        systemctl status sing-box || true
        pause_screen
        ;;
      2)
        echo -e "${Y}按 Ctrl+C 退出日志${N}"
        journalctl -u sing-box -f || true
        ;;
      3)
        if systemctl restart sing-box; then
          echo -e "${G}服务已重启${N}"
        else
          echo -e "${R}重启失败，请检查上方输出${N}"
        fi
        sleep 1
        ;;
      4)
        if systemctl stop sing-box; then
          echo -e "${Y}服务已停止${N}"
        else
          echo -e "${R}停止失败，请检查上方输出${N}"
        fi
        sleep 1
        ;;
      5)
        if systemctl start sing-box; then
          echo -e "${G}服务已启动${N}"
        else
          echo -e "${R}启动失败，请检查上方输出${N}"
        fi
        sleep 1
        ;;
      6)
        show_client_link
        ;;
      7)
        show_qrcode
        ;;
      8)
        modify_node_params
        ;;
      0)
        return
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
    render_menu_item 5 "TCP 参数调优"
    render_menu_item 6 "initcwnd 优化"
    render_menu_item 7 "查看网络优化状态"
    render_menu_item 8 "添加 SWAP (2G)"
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
        apply_tcp_tuning
        ;;
      6)
        apply_initcwnd_optimization
        ;;
      7)
        show_network_optimization_status
        ;;
      8)
        configure_swap
        ;;
      0)
        return
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
    esac
  done
}

show_external_services_menu(){
  while true; do
    render_section_header "外部服务"
    render_menu_item 1 "安装 1Panel"
    render_menu_item 2 "NodeQuality 测评"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case $choice in
      1)
        install_1panel
        ;;
      2)
        run_nodequality_benchmark
        ;;
      0)
        return
        ;;
    esac
  done
}

create_regular_user(){
  local username=""

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
    if validate_port "$ssh_port"; then
      break
    fi
    echo -e "${R}端口必须是 1-65535 的数字${N}"
  done

  echo -e "${Y}警告：${N} 修改后请确认安全组和防火墙已放行新端口。"
  read -p "  确认将 SSH 端口修改为 ${ssh_port} 并重启 SSH 服务？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  if apply_sshd_setting "Port" "$ssh_port" "SSH 端口已更新并重启服务"; then
    load_proxy_context
    server_ip="${MENU_IP:-你的IP}"
    echo -e "  新登录方式: ${C}ssh 用户名@${server_ip} -p ${ssh_port}${N}"
    echo -e "  配置文件: ${C}$SSHD_CONFIG_PATH${N}"
    pause_screen
  fi
}

disable_root_ssh_login(){
  local confirm=""

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

  if apply_sshd_setting "PermitRootLogin" "no" "root SSH 登录已禁用"; then
    echo -e "  当前设置: ${C}PermitRootLogin no${N}"
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

update_system_packages(){
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

configure_system_time(){
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

show_client_link(){
  local current_link=""
  local mode_label=""

  echo ""
  if [ ! -f "$INFO_PATH" ] && [ ! -f "$CONFIG_PATH" ]; then
    echo -e "  ${R}未找到节点信息，请先安装 sing-box${N}"
    pause_screen
    return 1
  fi

  load_proxy_context
  current_link=$(build_client_link "$MENU_UUID" "$MENU_IP" "$MENU_PORT" "$MENU_SNI" "$MENU_PUBLIC_KEY" "$MENU_SHORT_ID" "$MENU_TAG" 2>/dev/null || true)

  if [ -n "$current_link" ]; then
    set_info_value "Link" "$current_link"
    MENU_LINK="$current_link"
  fi

  mode_label=$(describe_install_mode "${MENU_MODE:-ipv4}")

  echo -e "  UUID      : ${C}${MENU_UUID:-未知}${N}"
  echo -e "  PublicKey : ${C}${MENU_PUBLIC_KEY:-未知}${N}"
  echo -e "  模式      : ${C}${mode_label}${N}"
  echo -e "  IP        : ${C}${MENU_IP:-未知}${N}"
  echo -e "  端口      : ${C}${MENU_PORT:-未知}${N}"
  echo -e "  SNI       : ${C}${MENU_SNI:-未知}${N}"
  if [ -n "$MENU_BIND_IPV4" ]; then
    echo -e "  出站 IPv4 : ${C}${MENU_BIND_IPV4}${N}"
  fi
  echo ""
  echo -e "  ${B}客户端链接：${N}"
  echo -e "  ${G}${current_link:-${MENU_LINK:-未找到}}${N}"
  print_qrcode "${current_link:-$MENU_LINK}"
  pause_screen
}

modify_node_params(){
  local new_port=""
  local new_sni=""
  local new_uuid=""
  local regen_keypair="n"
  local new_pri="" new_pub="" keypair=""
  local cur_port cur_sni cur_uuid
  local backup_path=""

  if ! require_root; then return 1; fi
  if ! require_singbox_installed; then return 1; fi

  if [ ! -f "$CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到配置文件：$CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  load_proxy_context
  cur_port="${MENU_PORT:-}"
  cur_sni="${MENU_SNI:-}"
  cur_uuid="${MENU_UUID:-}"

  echo ""
  echo -e "  ${B}${C}修改节点参数${N}  ${D}直接回车保留当前值${N}"
  render_divider

  # 端口
  while true; do
    read -p "  端口 (${cur_port:-当前未知}): " new_port
    new_port="${new_port:-$cur_port}"
    if validate_port "$new_port"; then
      break
    fi
    echo -e "${R}端口必须是 1-65535 的数字${N}"
  done

  # SNI
  while true; do
    read -p "  SNI 域名 (${cur_sni:-当前未知}): " new_sni
    new_sni="${new_sni:-$cur_sni}"
    new_sni=$(sanitize_sni "$new_sni")
    if [ -n "$new_sni" ]; then
      break
    fi
    echo -e "${R}SNI 不能为空${N}"
  done

  # UUID
  read -p "  UUID (回车保留当前 / 输入 new 随机生成新 UUID): " new_uuid
  case "$new_uuid" in
    new|NEW)
      new_uuid=$(cat /proc/sys/kernel/random/uuid)
      echo -e "  ${D}新 UUID：$new_uuid${N}"
      ;;
    "")
      new_uuid="$cur_uuid"
      ;;
  esac

  if [ -z "$new_uuid" ]; then
    echo -e "${R}UUID 无效${N}"
    pause_screen
    return 1
  fi

  # 是否同时重新生成密钥对
  read -p "  同时重新生成 Reality 密钥对？(y/N): " regen_keypair
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
    echo -e "  ${D}新 PublicKey：$new_pub${N}"
  fi

  echo ""
  echo -e "  将写入：端口 ${C}$new_port${N}  SNI ${C}$new_sni${N}  UUID ${C}$new_uuid${N}"
  if [ -n "$new_pub" ]; then
    echo -e "  PublicKey  : ${C}$new_pub${N}  ${Y}(记得更新客户端 pbk 参数)${N}"
  fi
  read -p "  确认修改？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  # 备份
  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  if ! cp "$CONFIG_PATH" "$backup_path"; then
    echo -e "${R}配置备份失败${N}"
    pause_screen
    return 1
  fi

  # 用 jq 安全修改 JSON
  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${Y}==> 安装 jq...${N}"
    if ! apt-get install -y jq 2>/dev/null; then
      echo -e "${R}jq 安装失败，请手动执行：apt install jq${N}"
      pause_screen
      return 1
    fi
  fi

  local jq_filter='.inbounds[0].listen_port = ($port | tonumber)
    | .inbounds[0].users[0].uuid = $uuid
    | .inbounds[0].tls.server_name = $sni
    | .inbounds[0].tls.reality.handshake.server = $sni'

  if [ -n "$new_pri" ]; then
    jq_filter="$jq_filter | .inbounds[0].tls.reality.private_key = \"$new_pri\""
  fi

  local tmp_file
  tmp_file=$(mktemp)
  if ! jq --arg port "$new_port" --arg sni "$new_sni" --arg uuid "$new_uuid"        "$jq_filter" "$CONFIG_PATH" > "$tmp_file"; then
    rm -f "$tmp_file"
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    echo -e "${R}配置写入失败，已恢复备份${N}"
    pause_screen
    return 1
  fi
  mv "$tmp_file" "$CONFIG_PATH"

  # 校验
  if ! sing-box check -c "$CONFIG_PATH"; then
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    echo ""
    echo -e "${R}配置校验失败，已恢复备份${N}"
    pause_screen
    return 1
  fi

  # 重启
  if ! systemctl restart sing-box; then
    cp "$backup_path" "$CONFIG_PATH" 2>/dev/null || true
    echo ""
    echo -e "${R}服务重启失败，已恢复备份${N}"
    pause_screen
    return 1
  fi

  # 同步 info 文件
  load_proxy_context
  local final_pub="${new_pub:-$MENU_PUBLIC_KEY}"
  local new_link
  new_link=$(build_client_link "$new_uuid" "$MENU_IP" "$new_port" "$new_sni" "$final_pub" "$MENU_SHORT_ID" "${MENU_TAG:-reality}" 2>/dev/null || true)
  set_info_value "Port" "$new_port"
  set_info_value "SNI"  "$new_sni"
  set_info_value "UUID" "$new_uuid"
  if [ -n "$new_pub" ]; then
    set_info_value "PublicKey"  "$new_pub"
    set_info_value "PrivateKey" "$new_pri"
  fi
  [ -n "$new_link" ] && set_info_value "Link" "$new_link"

  echo ""
  echo -e "${G}节点参数已更新并重启服务${N}"
  echo -e "  备份文件：${D}$backup_path${N}"
  if [ -n "$new_link" ]; then
    echo ""
    echo -e "  ${B}新客户端链接：${N}"
    echo -e "  ${G}$new_link${N}"
    print_qrcode "$new_link"
  fi
  pause_screen
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

show_qrcode(){
  local link=""

  if ! require_singbox_installed; then return 1; fi

  load_proxy_context
  link=$(build_client_link "$MENU_UUID" "$MENU_IP" "$MENU_PORT" "$MENU_SNI" "$MENU_PUBLIC_KEY" "$MENU_SHORT_ID" "${MENU_TAG:-reality}" 2>/dev/null || true)

  if [ -z "$link" ]; then
    echo ""
    echo -e "${R}节点信息不完整，无法生成二维码${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "  ${B}客户端链接：${N}"
  echo -e "  ${G}$link${N}"
  print_qrcode "$link"
  pause_screen
}

apply_tcp_tuning(){
  echo ""
  echo -e "${Y}==> 写入 TCP 参数优化配置...${N}"
  cat > "$TCP_TUNING_PATH" << 'EOF'
# --- 核心网络吞吐优化 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3

# --- 缓冲区设置 (适配高带宽长距离链路) ---
net.core.rmem_max = 402653184
net.core.wmem_max = 402653184
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 262144 402653184
net.ipv4.tcp_wmem = 4096 262144 402653184

# --- 延迟与公平性 ---
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_no_pmtu_disc = 0

# --- 连接回收与高并发处理 ---
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_max_orphans = 32768
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1

# --- 保活设置 (防止代理连接被防火墙踢掉) ---
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# --- 端口范围 ---
net.ipv4.ip_local_port_range = 1024 65535
EOF

  echo -e "${Y}==> 应用 sysctl 配置...${N}"
  if ! sysctl -p "$TCP_TUNING_PATH"; then
    echo -e "${R}TCP 参数应用失败，请检查内核兼容性或 sysctl 输出${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "  ${B}${C}TCP 参数校验${N}"
  sysctl net.ipv4.tcp_congestion_control
  sysctl net.ipv4.tcp_notsent_lowat
  sysctl net.ipv4.tcp_fin_timeout
  sysctl net.ipv4.tcp_keepalive_time
  echo ""
  echo -e "  配置文件: ${C}$TCP_TUNING_PATH${N}"
  pause_screen
}

apply_initcwnd_optimization(){
  local route_line route_spec ip_bin current_route

  echo ""

  if ! command -v ip &>/dev/null; then
    echo -e "${R}未找到 ip 命令，无法配置 initcwnd${N}"
    pause_screen
    return 1
  fi

  route_line=$(ip route show default 2>/dev/null | head -1)
  if [ -z "$route_line" ]; then
    echo -e "${R}未检测到默认路由，无法自动配置 initcwnd${N}"
    pause_screen
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
  echo -e "${Y}==> 应用 initcwnd/initrwnd ${INITCWND_VALUE}...${N}"
  if ! ip route replace $route_spec initcwnd $INITCWND_VALUE initrwnd $INITCWND_VALUE; then
    echo -e "${R}默认路由优化失败，请检查路由权限或当前网络环境${N}"
    pause_screen
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
ExecStart=$ip_bin route replace $route_spec initcwnd $INITCWND_VALUE initrwnd $INITCWND_VALUE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  if ! systemctl daemon-reload; then
    echo -e "${R}systemd 重新加载失败${N}"
    pause_screen
    return 1
  fi

  if ! systemctl enable --now "$(basename "$INITCWND_SERVICE_PATH")"; then
    echo -e "${R}initcwnd 持久化服务启用失败${N}"
    pause_screen
    return 1
  fi

  current_route=$(ip route show default 2>/dev/null | head -1)
  echo ""
  echo -e "${G}initcwnd 优化已生效${N}"
  echo -e "  当前默认路由: ${C}$current_route${N}"
  if printf '%s\n' "$current_route" | grep -Eq "(^| )initcwnd ${INITCWND_VALUE}( |$)"; then
    echo -e "  initcwnd: ${C}${INITCWND_VALUE}${N}"
  fi
  if printf '%s\n' "$current_route" | grep -Eq "(^| )initrwnd ${INITCWND_VALUE}( |$)"; then
    echo -e "  initrwnd: ${C}${INITCWND_VALUE}${N}"
  fi
  echo -e "  持久化服务: ${C}$(basename "$INITCWND_SERVICE_PATH")${N}"
  pause_screen
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

  if [ -f "$TCP_TUNING_PATH" ]; then
    tcp_config_status="已存在"
  else
    tcp_config_status="未写入"
  fi

  echo -e "  ${B}TCP 参数状态${N}"
  echo -e "  配置文件  : ${C}$tcp_config_status${N} (${TCP_TUNING_PATH})"
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

install_1panel(){
  local tmp_script

  echo ""
  echo -e "${Y}==> 下载 1Panel 安装脚本...${N}"
  tmp_script=$(mktemp)

  if ! curl -fsSL "$ONEPANEL_INSTALL_URL" -o "$tmp_script"; then
    rm -f "$tmp_script"
    echo -e "${R}1Panel 安装脚本下载失败${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 开始安装 1Panel...${N}"
  if ! bash "$tmp_script"; then
    rm -f "$tmp_script"
    echo ""
    echo -e "${R}1Panel 安装过程返回错误，请检查上方输出${N}"
    pause_screen
    return 1
  fi

  rm -f "$tmp_script"
  echo ""
  echo -e "${G}1Panel 安装脚本执行完成${N}"
  pause_screen
}

run_nodequality_benchmark(){
  local tmp_script

  echo ""
  echo -e "${Y}==> 下载 NodeQuality 测评脚本...${N}"
  tmp_script=$(mktemp)

  if ! curl -fsSL "$NODEQUALITY_RUN_URL" -o "$tmp_script"; then
    rm -f "$tmp_script"
    echo -e "${R}NodeQuality 测评脚本下载失败${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 开始执行 NodeQuality 测评，耗时可能较长...${N}"
  if ! bash "$tmp_script"; then
    rm -f "$tmp_script"
    echo ""
    echo -e "${R}NodeQuality 测评执行失败，请检查上方输出${N}"
    pause_screen
    return 1
  fi

  rm -f "$tmp_script"
  echo ""
  echo -e "${G}NodeQuality 测评执行完成${N}"
  pause_screen
}

# ─── 首次安装入口 ─────────────────────────────────────
do_install(){
  local port_input=""
  local sni_input=""
  local keypair=""
  local private_key=""
  local public_key=""
  local access_ip=""
  local link=""
  local public_ipv4=""
  local public_ipv6=""
  local outbound_bind_ip=""
  local install_mode="ipv4"
  local mode_label=""

  render_section_header "Leyili Sing-box 安装向导"
  echo -e "  ${Y}直接回车使用括号内默认值${N}"
  echo ""

  while true; do
    read -p "  端口 (8443): " port_input
    PORT="${port_input:-8443}"
    if validate_port "$PORT"; then
      break
    fi
    echo -e "${R}端口必须是 1-65535 的数字${N}"
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
  echo "    1) 仅 IPv4 - 0.0.0.0（默认）"
  echo "    2) IPv4 + IPv6 - ::"
  echo "    3) IPv6 入站 + IPv4 出站"
  read -p "  请选择 (1): " LISTEN_CHOICE
  case "$LISTEN_CHOICE" in
    2)
      LISTEN_ADDR="::"
      install_mode="dualstack"
      ;;
    3)
      LISTEN_ADDR="::"
      install_mode="ipv6-in-ipv4-out"
      ;;
    *)
      LISTEN_ADDR="0.0.0.0"
      install_mode="ipv4"
      ;;
  esac

  if [ "$install_mode" = "ipv6-in-ipv4-out" ]; then
    public_ipv4=$(detect_primary_ipv4)
    public_ipv6=$(detect_primary_ipv6)

    if [ -z "$public_ipv6" ]; then
      echo ""
      echo -e "${R}未检测到可用的 IPv6 地址，无法使用“IPv6 入站 + IPv4 出站”模式${N}"
      pause_screen
      return 1
    fi

    if [ -z "$public_ipv4" ]; then
      echo ""
      echo -e "${R}未检测到可用的 IPv4 地址，无法强制 IPv4 出站${N}"
      pause_screen
      return 1
    fi
  fi

  echo ""
  echo -e "${Y}==> 安装 sing-box...${N}"
  if ! bash <(curl -fsSL "$INSTALL_URL"); then
    echo ""
    echo -e "${R}sing-box 安装失败，请检查上方输出${N}"
    pause_screen
    return 1
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

  if [ -z "$public_ipv4" ]; then
    public_ipv4=$(detect_primary_ipv4)
  fi
  if [ -z "$public_ipv6" ]; then
    public_ipv6=$(detect_primary_ipv6)
  fi

  case "$install_mode" in
    ipv6-in-ipv4-out)
      access_ip="$public_ipv6"
      outbound_bind_ip="$public_ipv4"
      if [ -z "$access_ip" ]; then
        echo ""
        echo -e "${R}未检测到可用的 IPv6 地址，无法使用“IPv6 入站 + IPv4 出站”模式${N}"
        pause_screen
        return 1
      fi
      if [ -z "$outbound_bind_ip" ]; then
        echo ""
        echo -e "${R}未检测到可用的 IPv4 地址，无法强制 IPv4 出站${N}"
        pause_screen
        return 1
      fi
      ;;
    dualstack)
      access_ip="$public_ipv4"
      if [ -z "$access_ip" ]; then
        access_ip="$public_ipv6"
      fi
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
  mkdir -p /etc/sing-box
  if [ "$install_mode" = "ipv6-in-ipv4-out" ]; then
    cat > "$CONFIG_PATH" << EOF
{
  "log": {"disabled": false, "level": "warn", "timestamp": true},
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "$LISTEN_ADDR",
    "listen_port": $PORT,
    "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
    "tls": {
      "enabled": true,
      "server_name": "$SNI",
      "reality": {
        "enabled": true,
        "handshake": {"server": "$SNI", "server_port": 443},
        "private_key": "$private_key",
        "short_id": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{
    "type": "direct",
    "tag": "v4-out",
    "inet4_bind_address": "$outbound_bind_ip"
  }],
  "route": {
    "final": "v4-out"
  }
}
EOF
  else
    cat > "$CONFIG_PATH" << EOF
{
  "log": {"disabled": false, "level": "warn", "timestamp": true},
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "$LISTEN_ADDR",
    "listen_port": $PORT,
    "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
    "tls": {
      "enabled": true,
      "server_name": "$SNI",
      "reality": {
        "enabled": true,
        "handshake": {"server": "$SNI", "server_port": 443},
        "private_key": "$private_key",
        "short_id": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{"type": "direct"}]
}
EOF
  fi

  echo -e "${Y}==> 校验配置...${N}"
  if ! sing-box check -c "$CONFIG_PATH"; then
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 启动服务...${N}"
  if ! systemctl enable sing-box; then
    echo ""
    echo -e "${R}sing-box 开机自启设置失败${N}"
    pause_screen
    return 1
  fi
  if ! systemctl restart sing-box; then
    echo ""
    echo -e "${R}sing-box 启动失败${N}"
    pause_screen
    return 1
  fi

  link=$(build_client_link "$UUID" "$access_ip" "$PORT" "$SNI" "$public_key" "$SHORT_ID" "$TAG" 2>/dev/null || true)

  write_proxy_info \
    "$UUID" \
    "$public_key" \
    "$private_key" \
    "$access_ip" \
    "$PORT" \
    "$SNI" \
    "$SHORT_ID" \
    "$TAG" \
    "$LISTEN_ADDR" \
    "$link" \
    "$install_mode" \
    "$outbound_bind_ip"

  # 注册 sb 快捷命令
  register_sb_command || true

  echo ""
  echo -e "  ${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "  ${G}║${N}  ${B}${W}${APP_NAME}${N}  ${G}Sing-box 安装完成${N}"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${N}"
  echo -e "  模式      : ${C}$mode_label${N}"
  echo -e "  UUID      : ${C}$UUID${N}"
  echo -e "  PublicKey : ${C}$public_key${N}"
  echo -e "  入口 IP   : ${C}${access_ip:-未知}${N}"
  if [ -n "$outbound_bind_ip" ]; then
    echo -e "  出站 IPv4 : ${C}$outbound_bind_ip${N}"
  fi
  echo -e "  端口      : ${C}$PORT${N}"
  echo -e "  SNI       : ${C}$SNI${N}"
  echo ""
  echo -e "  ${B}客户端链接：${N}"
  echo -e "  ${G}${link:-未生成}${N}"
  print_qrcode "${link:-}"
  echo ""
  echo -e "  信息已保存至 ${Y}$INFO_PATH${N}"
  echo -e "  输入 ${B}${COMMAND_NAME}${N} 进入管理菜单"
  pause_screen
}

# ─── 管理菜单 ─────────────────────────────────────────
show_menu(){
  local ver=""
  local status=""
  local status_str=""
  local singbox_action_label=""
  local mode_label=""

  while true; do
    load_proxy_context

    if is_singbox_installed; then
      ver=$(sing-box version 2>/dev/null | head -1 | awk '{print $3}' || echo "未知")
      status=$(systemctl is-active sing-box 2>/dev/null || echo "未知")
      if [ "$status" = "active" ]; then
        status_str="${G}运行中${N}"
      else
        status_str="${R}$status${N}"
      fi
      singbox_action_label="升级 sing-box 内核"
      mode_label=$(describe_install_mode "${MENU_MODE:-ipv4}")
    else
      ver="未安装"
      status_str="${Y}未安装${N}"
      singbox_action_label="安装 sing-box"
      mode_label="未安装"
    fi

    render_section_header "管理菜单"
    echo -e "  ${L}│${N}  版本      ${D}·${N}  ${C}$ver${N}"
    echo -e "  ${L}│${N}  状态      ${D}·${N}  $status_str"
    echo -e "  ${L}│${N}  模式      ${D}·${N}  ${C}$mode_label${N}"
    echo -e "  ${L}│${N}  端口      ${D}·${N}  ${C}${MENU_PORT:-未知}${N}"
    echo -e "  ${L}│${N}  域名      ${D}·${N}  ${C}${MENU_SNI:-未知}${N}"
    echo -e "  ${L}│${N}  IP        ${D}·${N}  ${C}${MENU_IP:-未知}${N}"
    render_divider
    render_menu_item 1 "管理员设置"
    render_menu_item 2 "系统基础设置"
    render_menu_item 3 "${singbox_action_label}"
    render_menu_item 4 "查看状态"
    render_menu_item 5 "外部服务"
    render_menu_item 6 "卸载 sing-box"
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
        if is_singbox_installed; then
          echo -e "${Y}==> 升级内核（不覆盖配置）...${N}"
          if ! bash <(curl -fsSL "$INSTALL_URL"); then
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
        else
          do_install
        fi
        ;;
      4)
        show_status_menu
        ;;
      5)
        show_external_services_menu
        ;;
      6)
        echo ""
        read -p "  确认卸载 sing-box 并删除 ${COMMAND_NAME} 菜单入口？保留系统优化与 1Panel (y/N): " CONFIRM
        if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
          echo -e "${Y}==> 停止并禁用服务...${N}"
          systemctl stop sing-box 2>/dev/null || true
          systemctl disable sing-box 2>/dev/null || true
          echo -e "${Y}==> 卸载软件包...${N}"
          apt-get remove --purge -y sing-box 2>/dev/null || true
          echo -e "${Y}==> 清理文件...${N}"
          rm -rf /etc/sing-box
          rm -f "$INFO_PATH"
          rm -f "$SCRIPT_PATH"
          echo -e "${G}卸载完成${N}"
          exit 0
        fi
        echo -e "  已取消"
        sleep 1
        ;;
      0)
        exit 0
        ;;
    esac
  done
}

# ─── 入口判断 ─────────────────────────────────────────
register_sb_command || true
show_menu
