#!/bin/bash
set -o pipefail
umask 077

LEYILI_DIR="/etc/leyili"
LEYILI_STATE_DIR="${LEYILI_DIR}/state"
LEYILI_LOCK_PATH="/run/lock/leyili.lock"
FIREWALL_PORT_STATE="${LEYILI_STATE_DIR}/firewall-ports.state"

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

# ─── 颜色 ────────────────────────────────────────────
G="\033[32m" Y="\033[33m" C="\033[36m" R="\033[31m" B="\033[1m" N="\033[0m"
L="\033[94m" W="\033[97m" D="\033[2m"

# ─── 通用辅助 ────────────────────────────────────────
