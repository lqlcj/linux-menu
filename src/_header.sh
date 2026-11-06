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
FAIL2BAN_ETC_DIR="/etc/fail2ban"
FAIL2BAN_JAIL_PATH="${FAIL2BAN_ETC_DIR}/jail.d/leyili-sshd.local"
FAIL2BAN_DAEMON_CONF_PATH="${FAIL2BAN_ETC_DIR}/fail2ban.d/leyili.local"
FAIL2BAN_DEFAULT_LOGFILE="/var/log/fail2ban.log"
# sshd：1 小时内失败 3 次封 1 天，再犯翻倍（bantime.increment），封禁上限 4 周
FAIL2BAN_MAXRETRY="3"
FAIL2BAN_FINDTIME="3600"
FAIL2BAN_BANTIME="86400"
FAIL2BAN_BANTIME_MAXTIME="2419200"
# recidive：1 周内被任意 jail 封 2 次，全端口封 2 周
FAIL2BAN_RECIDIVE_MAXRETRY="2"
FAIL2BAN_RECIDIVE_FINDTIME="604800"
FAIL2BAN_RECIDIVE_BANTIME="1209600"
# 封禁记录保留期，必须长于封禁上限，否则累进封禁会"忘记"老惯犯（默认仅 1 天）
FAIL2BAN_DBPURGEAGE="3024000"
FAIL2BAN_IGNOREIP_MAX="20"
# OpenSSH 9.8+ 把认证日志移到 sshd-session 进程，Debian 的单元名是 ssh.service；
# 按单元匹配为主（_SYSTEMD_UNIT 由 cgroup 决定、普通用户无法伪造），按进程名兜底。
FAIL2BAN_SSHD_JOURNALMATCH="_SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd + _COMM=sshd-session"
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
