#!/bin/bash
set -o pipefail

SAGERNET_KEY_URL="https://sing-box.app/gpg.key"
SAGERNET_KEYRING="/etc/apt/keyrings/sagernet.asc"
SAGERNET_SOURCES="/etc/apt/sources.list.d/sagernet.sources"
SAGERNET_REPO_URI="https://deb.sagernet.org/"
CONFIG_PATH="/etc/sing-box/config.json"
INFO_PATH="/root/proxy-info.txt"
NODES_DIR="/etc/sing-box/nodes"
CERTS_DIR="/etc/sing-box/certs"

# 首页展示「最新稳定版」用的缓存（避免每次刷新菜单都请求 GitHub）
SINGBOX_LATEST_CACHE="/tmp/.leyili-singbox-latest"
SINGBOX_LATEST_TTL="21600"     # 有效缓存 6 小时
SINGBOX_LATEST_NEG_TTL="300"   # 联网失败后 5 分钟内不再重试
APP_NAME="Leyili"
COMMAND_NAME="sb"
SCRIPT_PATH="/usr/local/bin/${COMMAND_NAME}"
SELF_INSTALL_URL="${SELF_INSTALL_URL:-https://raw.githubusercontent.com/lqlcj/linux-menu/main/leyili.sh}"
TCP_TUNING_PATH="/etc/sysctl.d/99-proxy-optimized.conf"
QUIC_TUNING_PATH="/etc/sysctl.d/99-quic-optimized.conf"
INITCWND_SERVICE_PATH="/etc/systemd/system/initcwnd.service"
INITCWND_VALUE="24"
SWAPFILE_PATH="/swapfile"
SWAP_SYSCTL_PATH="/etc/sysctl.d/99-swap-tuning.conf"
SWAPPINESS_VALUE="10"

SYSTEM_TIMEZONE="Asia/Shanghai"
BASIC_TOOLS_PACKAGES="curl wget git vim htop unzip net-tools"
SSHD_CONFIG_PATH="/etc/ssh/sshd_config"
SUDOERS_DROPIN_DIR="/etc/sudoers.d"
SSH_RANDOM_PORT_MIN="20000"
SSH_RANDOM_PORT_MAX="65535"
IP6_RULES_PATH_DEBIAN="/etc/iptables/rules.v6"
IP6_RULES_PATH_RHEL="/etc/sysconfig/ip6tables"
IP4_RULES_PATH_DEBIAN="/etc/iptables/rules.v4"
IP4_RULES_PATH_RHEL="/etc/sysconfig/iptables"

# ─── WARP 谷歌解锁分流 ───────────────────────────────
WARP_APP_NAME="WARP 谷歌解锁分流"
WARP_DIR="/etc/leyili/warp"
WARP_ACCOUNT_JSON="${WARP_DIR}/account.json"
# 旧版 wgcf 方案的遗留二进制路径：仅在卸载时清理用
WARP_WGCF_BIN="/usr/local/bin/wgcf"
# 模拟官方安卓客户端的注册 API（与 fscarmen/warp、warp-reg 同款参数）
WARP_API_BASE="https://api.cloudflareclient.com/v0a2158"
WARP_API_UA="okhttp/3.12.1"
WARP_API_CLIENT_VER="a-6.10-2158"
WARP_OUTBOUND_TAG="warp-out"
WARP_RULESET_TAG="geosite-google"
WARP_RULESET_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google.srs"
WARP_RULESET_TAG_YT="geosite-youtube"
WARP_RULESET_URL_YT="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-youtube.srs"
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
