#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_UNDER_TEST="${ROOT_DIR}/leyili.sh"

fail(){
  printf 'smoke: %s\n' "$*" >&2
  exit 1
}

assert_eq(){
  local expected="$1" actual="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "${label}: expected '${expected}', got '${actual}'"
}

assert_contains(){
  local text_value="$1" needle="$2" label="$3"
  printf '%s\n' "$text_value" | grep -Fq -- "$needle" \
    || fail "${label}: missing '${needle}'"
}

assert_not_contains(){
  local text_value="$1" needle="$2" label="$3"
  if printf '%s\n' "$text_value" | grep -Fq -- "$needle"; then
    fail "${label}: unexpectedly contains '${needle}'"
  fi
}

[ -s "$SCRIPT_UNDER_TEST" ] || fail "leyili.sh is missing"
export LEYILI_SOURCE_ONLY=1
# shellcheck disable=SC1090
source "$SCRIPT_UNDER_TEST"

for fn in show_menu show_network_menu show_firewall_menu setup_fail2ban \
          firewall_transaction_begin firewall_transaction_rollback \
          config_transaction_begin config_transaction_rollback \
          uninstall_script_completely; do
  declare -F "$fn" >/dev/null || fail "missing function: ${fn}"
done

# 首页卡片只保留 Reality 概览，以及已安装时的 SS-2022；不再列 Hy2/AnyTLS/TUIC/调优状态。
render_card_plain_top(){ :; }
render_card_blank(){ :; }
render_card_bottom(){ :; }
render_singbox_version_card_line(){ :; }
render_node_card_block(){ printf 'NODE:%s\n' "$1"; }
node_installed(){ [ "$1" = "ss2022" ]; }
card_output=$(render_main_menu_card)
assert_contains "$card_output" 'NODE:reality' 'main card'
assert_contains "$card_output" 'NODE:ss2022' 'main card'
assert_not_contains "$card_output" 'hy2' 'main card'
assert_not_contains "$card_output" 'anytls' 'main card'
assert_not_contains "$card_output" 'tuic' 'main card'

# 把菜单渲染成纯文本，验证最终层级和入口。
render_section_header(){ printf 'HEADER:%s\n' "$1"; }
render_menu_item(){ printf 'ITEM:%s:%b\n' "$1" "$2"; }
render_divider(){ :; }
render_brand_banner(){ :; }
render_main_menu_card(){ :; }
migrate_legacy_info(){ :; }
clear(){ :; }
notify_invalid_choice(){ fail 'unexpected invalid menu choice'; }
count_installed_nodes(){ printf '0'; }

main_output=$(printf '0\n' | show_menu 2>/dev/null)
assert_contains "$main_output" 'ITEM:2:系统基础设置' 'main menu'
assert_contains "$main_output" 'ITEM:3:创建节点' 'main menu'
assert_contains "$main_output" 'ITEM:4:网络管理' 'main menu'
assert_contains "$main_output" 'ITEM:5:防火墙管理' 'main menu'
assert_not_contains "$main_output" '查看状态' 'main menu'

system_output=$(printf '0\n' | show_system_menu 2>/dev/null)
assert_contains "$system_output" 'ITEM:5:网络优化' 'system menu'
assert_contains "$system_output" 'ITEM:7:添加 SWAP' 'system menu'
assert_not_contains "$system_output" 'fail2ban' 'system menu'
assert_not_contains "$system_output" 'Reality 域名检测' 'system menu'
assert_not_contains "$system_output" 'WARP 谷歌解锁' 'system menu'
assert_not_contains "$system_output" '服务器状态' 'system menu'
assert_not_contains "$system_output" '本地链路测评' 'system menu'

network_output=$(printf '0\n' | show_network_menu 2>/dev/null)
assert_contains "$network_output" 'ITEM:1:安装 / 配置 fail2ban (SSH 多端口防爆破)' 'network menu'
assert_contains "$network_output" 'ITEM:2:Reality 域名检测工具' 'network menu'
assert_contains "$network_output" 'ITEM:3:WARP 谷歌解锁分流' 'network menu'
assert_contains "$network_output" 'ITEM:4:服务器状态' 'network menu'
assert_contains "$network_output" 'ITEM:5:本地链路测评' 'network menu'

firewall_output=$(printf '0\n' | show_firewall_menu 2>/dev/null)
assert_contains "$firewall_output" 'ITEM:1:IPv4 防火墙管理' 'firewall menu'
assert_contains "$firewall_output" 'ITEM:2:IPv6 防火墙管理' 'firewall menu'

node_output=$(printf '0\n' | show_node_manage_menu 2>/dev/null)
assert_contains "$node_output" 'ITEM:3:查看状态 / 节点配置' 'node menu'

# fail2ban 支持去重后的 SSH 多端口列表，且最多 15 个。
ports=$(normalize_fail2ban_port_list '22, 2222 ； 2200,22')
assert_eq '22,2222,2200' "$ports" 'fail2ban multi-port normalization'
set +e
normalize_fail2ban_port_list '1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16' >/dev/null
port_rc=$?
set -e
assert_eq '2' "$port_rc" 'fail2ban 15-port limit'

# 通用托管文件事务必须同时恢复当前文件和预先存在的 original 备份。
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
managed_path="${test_dir}/managed.conf"
printf 'user-current\n' > "$managed_path"
txn=$(managed_file_transaction_begin "$managed_path" '^# Managed by Leyili$')
printf '# Managed by Leyili\n' > "$managed_path"
managed_file_transaction_rollback "$managed_path" "$txn"
assert_eq 'user-current' "$(tr -d '\r\n' < "$managed_path")" 'managed file rollback'
[ ! -e "${managed_path}.leyili-original" ] || fail 'new original backup was not removed on rollback'

printf 'managed-current\n' > "$managed_path"
printf 'user-original\n' > "${managed_path}.leyili-original"
txn=$(managed_file_transaction_begin "$managed_path" 'managed-current')
managed_file_restore "$managed_path"
managed_file_transaction_rollback "$managed_path" "$txn"
assert_eq 'managed-current' "$(tr -d '\r\n' < "$managed_path")" 'preexisting current rollback'
assert_eq 'user-original' "$(tr -d '\r\n' < "${managed_path}.leyili-original")" 'preexisting original rollback'

# 防火墙回滚是同步执行：恢复活动规则及持久化文件后才删除快照。
iptables-restore(){ cat >/dev/null; }
fw_txn="${test_dir}/fw-txn"
mkdir -p "$fw_txn"
printf '*filter\nCOMMIT\n' > "$fw_txn/active.rules"
persistent_file="${test_dir}/rules.v4"
printf '%s\n' "$persistent_file" > "$fw_txn/persistent.path"
printf 'old-rules\n' > "$fw_txn/persistent.rules"
: > "$fw_txn/persistent.existed"
printf 'new-rules\n' > "$persistent_file"
firewall_transaction_rollback 4 "$fw_txn"
assert_eq 'old-rules' "$(tr -d '\r\n' < "$persistent_file")" 'firewall immediate rollback'
[ ! -d "$fw_txn" ] || fail 'successful firewall rollback left its transaction directory'
unset -f iptables-restore

# 固定供应链标识与已废弃的危险逻辑。
assert_eq '2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C' "$SAGERNET_KEY_FINGERPRINT" 'SagerNet key fingerprint'
assert_eq 'db558913a68c00c07524b211472b968231874b5f' "$WARP_RULESET_COMMIT" 'WARP ruleset commit'

for forbidden in 'schedule_iptables''_rollback' '/tmp/.leyili''-' 'latest/''download' 'rm -rf /etc/''sing-box'; do
  if grep -Fq -- "$forbidden" "$SCRIPT_UNDER_TEST"; then
    fail "forbidden legacy pattern remains: ${forbidden}"
  fi
done
if grep -Eq 'eval[[:space:]].*WARP' "$SCRIPT_UNDER_TEST"; then
  fail 'WARP account parsing still uses eval'
fi

duplicates=$(grep -hEo '^[A-Za-z_][A-Za-z0-9_]*\(\)\{' \
  "$ROOT_DIR"/src/_header.sh "$ROOT_DIR"/src/lib/*.sh "$ROOT_DIR"/src/_entry.sh \
  | sed 's/(){$//' | sort | uniq -d)
[ -z "$duplicates" ] || fail "duplicate function definitions: ${duplicates}"

printf 'smoke: ok\n'
