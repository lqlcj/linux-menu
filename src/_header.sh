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
