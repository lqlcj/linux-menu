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
          firewall_apply_port_for_mode firewall_revoke_port_for_mode \
          update_self_script cleanup_config_backups show_server_status \
          uninstall_script_completely; do
  declare -F "$fn" >/dev/null || fail "missing function: ${fn}"
done

# 把菜单渲染成纯文本，验证最终层级和入口。
render_section_header(){ printf 'HEADER:%s\n' "$1"; }
render_menu_item(){ printf 'ITEM:%s:%b\n' "$1" "$2"; }
render_divider(){ :; }
render_brand_banner(){ :; }
clear(){ :; }
notify_invalid_choice(){ fail 'unexpected invalid menu choice'; }

main_output=$(printf '0\n' | show_menu 2>/dev/null)
assert_contains "$main_output" 'ITEM:2:系统基础设置' 'main menu'
assert_contains "$main_output" 'ITEM:1:管理员设置' 'main menu'
assert_contains "$main_output" 'ITEM:3:网络管理' 'main menu'
assert_contains "$main_output" 'ITEM:4:防火墙管理' 'main menu'
assert_contains "$main_output" 'ITEM:5:卸载脚本' 'main menu'
assert_contains "$main_output" 'ITEM:6:更新管理' 'main menu'
assert_not_contains "$main_output" '节点' 'main menu'
assert_not_contains "$main_output" '查看状态' 'main menu'

system_output=$(printf '0\n' | show_system_menu 2>/dev/null)
assert_contains "$system_output" 'ITEM:5:网络优化' 'system menu'
assert_contains "$system_output" 'ITEM:7:添加 SWAP' 'system menu'
assert_not_contains "$system_output" 'fail2ban' 'system menu'
assert_not_contains "$system_output" '服务器状态' 'system menu'
assert_not_contains "$system_output" '本地链路测评' 'system menu'

network_output=$(printf '0\n' | show_network_menu 2>/dev/null)
assert_contains "$network_output" 'ITEM:1:安装 / 配置 fail2ban (SSH 多端口防爆破)' 'network menu'
assert_contains "$network_output" 'ITEM:2:服务器状态' 'network menu'
assert_contains "$network_output" 'ITEM:3:本地链路测评' 'network menu'

update_output=$(printf '0\n' | show_update_menu 2>/dev/null)
assert_contains "$update_output" 'ITEM:1:更新脚本' 'update menu'
assert_contains "$update_output" 'ITEM:2:清理配置备份' 'update menu'

firewall_output=$(printf '0\n' | show_firewall_menu 2>/dev/null)
assert_contains "$firewall_output" 'ITEM:1:IPv4 防火墙管理' 'firewall menu'
assert_contains "$firewall_output" 'ITEM:2:IPv6 防火墙管理' 'firewall menu'

admin_output=$(printf '0\n' | show_admin_menu 2>/dev/null)
assert_contains "$admin_output" 'ITEM:7:关闭 SSH 密码登录 (仅密钥)' 'admin menu'

# Exercise nested menus and renumbered actions without changing the host.
navigation_output=$(
  show_server_status(){ printf 'ACTION:status\n'; }
  show_netbench_menu(){ printf 'ACTION:netbench\n'; }
  setup_fail2ban(){ printf 'ACTION:fail2ban\n'; }
  show_ipv4_firewall_menu(){ printf 'ACTION:ipv4\n'; }
  show_ipv6_firewall_menu(){ printf 'ACTION:ipv6\n'; }
  update_self_script(){ printf 'ACTION:update\n'; }
  cleanup_config_backups(){ printf 'ACTION:backups\n'; }
  uninstall_script_completely(){ printf 'ACTION:uninstall\n'; }
  printf '3\n1\n2\n3\n0\n4\n1\n2\n0\n6\n1\n2\n0\n5\n0\n' | show_menu
)
for action in fail2ban status netbench ipv4 ipv6 update backups uninstall; do
  assert_contains "$navigation_output" "ACTION:${action}" 'menu navigation'
done

# 开放端口展示必须追踪 INPUT 引用的子链，只列最终 ACCEPT 的 TCP/UDP 规则。
saved_firewall_rules='*raw
:PREROUTING ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT
*mangle
:INPUT ACCEPT [0:0]
-A INPUT -p tcp --dport 1234 -j ACCEPT
COMMIT
*filter
:INPUT DROP [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:LEYILI_INPUT - [0:0]
:UFW_USER_INPUT - [0:0]
:UNUSED_INPUT - [0:0]
-A INPUT -j LEYILI_INPUT
-A INPUT -j UFW_USER_INPUT
-A LEYILI_INPUT -p tcp -m tcp --dport 443 -j ACCEPT
-A LEYILI_INPUT -p udp -m multiport --dports 8443,9443 -j ACCEPT
-A UFW_USER_INPUT -p tcp --dport 22 -j ACCEPT
-A UFW_USER_INPUT -p tcp --dport 25 -j DROP
-A UNUSED_INPUT -p tcp --dport 9999 -j ACCEPT
COMMIT'
assert_eq 'DROP' "$(printf '%s\n' "$saved_firewall_rules" | firewall_policy_from_saved_rules INPUT)" 'firewall saved policy'
opened_ports=$(printf '%s\n' "$saved_firewall_rules" | firewall_list_opened_ports_from_saved_rules lines)
assert_contains "$opened_ports" 'TCP  443' 'managed-chain opened port'
assert_contains "$opened_ports" 'UDP  8443,9443' 'multiport opened ports'
assert_contains "$opened_ports" 'TCP  22' 'ufw-chain opened port'
assert_not_contains "$opened_ports" '25' 'rejected port filtering'
assert_not_contains "$opened_ports" '1234' 'non-filter table filtering'
assert_not_contains "$opened_ports" '9999' 'unreachable-chain filtering'
assert_eq 'TCP 443, 22  UDP 8443,9443' \
  "$(printf '%s\n' "$saved_firewall_rules" | firewall_list_opened_ports_from_saved_rules compact)" \
  'compact opened ports'

# fail2ban 支持去重后的 SSH 多端口列表，且最多 15 个。
ports=$(normalize_fail2ban_port_list '22, 2222 ； 2200,22')
assert_eq '22,2222,2200' "$ports" 'fail2ban multi-port normalization'
set +e
normalize_fail2ban_port_list '1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16' >/dev/null
port_rc=$?
set -e
assert_eq '2' "$port_rc" 'fail2ban 15-port limit'

# 白名单：地址/CIDR 去重、滤掉回环、拒绝非法项，"-" 清空。
assert_eq '203.0.113.7,2001:db8::/32,198.51.100.0/24' \
  "$(normalize_fail2ban_ignoreip_list '203.0.113.7 ，2001:db8::/32; 127.0.0.1/8 ::1 198.51.100.0/24,203.0.113.7')" \
  'fail2ban ignoreip normalization'
assert_eq '' "$(normalize_fail2ban_ignoreip_list '-')" 'fail2ban ignoreip clear'
for bad_ip in '1.2.3.256' '1.2.3.4/33' '2001:db8::/129' 'example.com' '1.2.3.4/' '1.2.3.4/8/8' '1.2.3.4/abc'; do
  set +e
  normalize_fail2ban_ignoreip_list "$bad_ip" >/dev/null
  ip_rc=$?
  set -e
  assert_eq '1' "$ip_rc" "fail2ban ignoreip rejects ${bad_ip}"
done

# jail 渲染：严格参数、aggressive、累进封禁、recidive 全端口，白名单写进两个 jail。
jail_text=$(fail2ban_render_jail '22,2222' '203.0.113.7,198.51.100.0/24' '/var/log/fail2ban.log' 1)
assert_contains "$jail_text" 'port         = 22,2222' 'fail2ban jail port'
assert_contains "$jail_text" 'mode         = aggressive' 'fail2ban jail mode'
assert_contains "$jail_text" "maxretry     = ${FAIL2BAN_MAXRETRY}" 'fail2ban jail maxretry'
assert_contains "$jail_text" 'bantime.increment = true' 'fail2ban jail increment'
assert_contains "$jail_text" "journalmatch = ${FAIL2BAN_SSHD_JOURNALMATCH}" 'fail2ban jail journalmatch'
assert_contains "$jail_text" '[recidive]' 'fail2ban recidive jail'
assert_contains "$jail_text" 'banaction = %(banaction_allports)s' 'fail2ban recidive allports'
assert_contains "$jail_text" 'logpath   = /var/log/fail2ban.log' 'fail2ban recidive logpath'
[ "$(printf '%s\n' "$jail_text" | grep -c '^ignoreip.*= 127.0.0.1/8 ::1 203.0.113.7 198.51.100.0/24$')" = '2' ] \
  || fail 'fail2ban ignoreip must be applied to both jails'
assert_not_contains "$(fail2ban_render_jail 22 '' /x 0)" 'bantime.increment' 'fail2ban old version skips increment'
[ "$FAIL2BAN_DBPURGEAGE" -gt "$FAIL2BAN_BANTIME_MAXTIME" ] || fail 'dbpurgeage must exceed bantime.maxtime'
assert_contains "$(fail2ban_render_daemon_conf '')" "dbpurgeage = ${FAIL2BAN_DBPURGEAGE}" 'fail2ban daemon conf'
assert_not_contains "$(fail2ban_render_daemon_conf '')" 'logtarget' 'fail2ban daemon conf keeps file logtarget'
assert_contains "$(fail2ban_render_daemon_conf /var/log/fail2ban.log)" 'logtarget = /var/log/fail2ban.log' 'fail2ban daemon conf logtarget'

# 通用托管文件事务必须同时恢复当前文件和预先存在的 original 备份。
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM

# 已保存配置读取只看 [sshd] 段，兼容旧版单段文件。
f2b_etc="${test_dir}/fail2ban"
mkdir -p "$f2b_etc/jail.d" "$f2b_etc/fail2ban.d"
(
  FAIL2BAN_ETC_DIR="$f2b_etc"
  FAIL2BAN_JAIL_PATH="$f2b_etc/jail.d/leyili-sshd.local"
  FAIL2BAN_DAEMON_CONF_PATH="$f2b_etc/fail2ban.d/leyili.local"
  printf '[sshd]\nenabled  = true\nport     = 22,2222\nmaxretry = 5\n' > "$FAIL2BAN_JAIL_PATH"
  assert_eq '22,2222' "$(fail2ban_saved_jail_value port)" 'legacy jail port'
  assert_eq '' "$(fail2ban_saved_jail_value ignoreip)" 'legacy jail ignoreip'
  fail2ban_render_jail '2200' '203.0.113.7' /x 1 > "$FAIL2BAN_JAIL_PATH"
  assert_eq '2200' "$(fail2ban_saved_jail_value port)" 'new jail port'
  assert_eq '127.0.0.1/8 ::1 203.0.113.7' "$(fail2ban_saved_jail_value ignoreip)" 'new jail ignoreip'
  assert_eq '203.0.113.7' "$(normalize_fail2ban_ignoreip_list "$(fail2ban_saved_jail_value ignoreip)")" 'saved ignoreip round trip'

  # logtarget 取最后生效的值，并忽略脚本自己的文件。
  printf '[DEFAULT]\nlogtarget = /var/log/fail2ban.log\n' > "$f2b_etc/fail2ban.conf"
  assert_eq '/var/log/fail2ban.log' "$(fail2ban_effective_logtarget)" 'fail2ban default logtarget'
  printf '[Definition]\nlogtarget = SYSTEMD-JOURNAL\n' > "$f2b_etc/fail2ban.local"
  printf '[Definition]\nlogtarget = /tmp/should-be-ignored\n' > "$FAIL2BAN_DAEMON_CONF_PATH"
  assert_eq 'SYSTEMD-JOURNAL' "$(fail2ban_effective_logtarget)" 'fail2ban overridden logtarget'

  # 事务回滚：恢复旧 jail，删除本次新建的守护配置，并按快照恢复服务状态。
  systemctl(){ printf 'SYSTEMCTL:%s\n' "$*" >> "$test_dir/f2b-systemctl.log"; [ "$1" != is-enabled ] && [ "$1" != is-active ]; }
  rm -f -- "$FAIL2BAN_DAEMON_CONF_PATH"
  printf 'old-jail\n' > "$FAIL2BAN_JAIL_PATH"
  f2b_txn=$(TMPDIR="$test_dir" fail2ban_transaction_begin)
  printf 'new-jail\n' > "$FAIL2BAN_JAIL_PATH"
  printf 'new-daemon\n' > "$FAIL2BAN_DAEMON_CONF_PATH"
  fail2ban_transaction_restore "$f2b_txn"
  assert_eq 'old-jail' "$(tr -d '\r\n' < "$FAIL2BAN_JAIL_PATH")" 'fail2ban jail rollback'
  [ ! -e "$FAIL2BAN_DAEMON_CONF_PATH" ] || fail 'fail2ban rollback kept a newly created daemon conf'
  [ ! -d "$f2b_txn" ] || fail 'fail2ban rollback left its transaction directory'
  assert_contains "$(cat "$test_dir/f2b-systemctl.log")" 'SYSTEMCTL:disable fail2ban' 'fail2ban rollback disables'
  assert_contains "$(cat "$test_dir/f2b-systemctl.log")" 'SYSTEMCTL:stop fail2ban' 'fail2ban rollback stops'
)

# Uninstall must restore firewall snapshots on failure and retain the entry.
# All writable paths are temporary; host service and firewall calls are mocked.
uninstall_probe="${test_dir}/uninstall-entry"
printf '#!/bin/bash\n' > "$uninstall_probe"
uninstall_rc=0
uninstall_output=$(
  TMPDIR="$test_dir"
  SCRIPT_PATH="$uninstall_probe"
  FIREWALL_PORT_STATE="${test_dir}/absent-port-state"
  require_root(){ return 0; }
  pause_screen(){ :; }
  iptables(){ fail 'unexpected live IPv4 mutation'; }
  ip6tables(){ fail 'unexpected live IPv6 mutation'; }
  systemctl(){ fail 'uninstall must not manage external services'; }
  firewall_transaction_begin(){ printf '%s/fw%s' "$test_dir" "$1"; }
  firewall_transaction_rollback(){ printf 'ROLLBACK:%s\n' "$1"; }
  firewall_owned_ports_restore(){ printf 'RESTORE:ports\n'; }
  firewall_remove_all_owned_ports(){ return 1; }
  uninstall_script_completely <<< 'y'
) || uninstall_rc=$?
assert_eq '1' "$uninstall_rc" 'uninstall firewall failure'
assert_contains "$uninstall_output" 'ROLLBACK:4' 'uninstall IPv4 rollback'
assert_contains "$uninstall_output" 'ROLLBACK:6' 'uninstall IPv6 rollback'
assert_contains "$uninstall_output" 'RESTORE:ports' 'uninstall ownership rollback'
[ -f "$uninstall_probe" ] || fail 'failed uninstall removed the entry'

uninstall_rc=0
uninstall_output=$(
  TMPDIR="$test_dir"
  SCRIPT_PATH="$uninstall_probe"
  FIREWALL_PORT_STATE="${test_dir}/absent-port-state"
  NETBENCH_ENV_PATH="${test_dir}/absent-netbench-env"
  NETBENCH_NEXTTRACE_BIN="${test_dir}/absent-nexttrace"
  require_root(){ return 0; }
  pause_screen(){ :; }
  iptables(){ fail 'unexpected live IPv4 mutation'; }
  ip6tables(){ fail 'unexpected live IPv6 mutation'; }
  systemctl(){ fail 'uninstall must not manage external services'; }
  firewall_transaction_begin(){ printf '%s/fw%s' "$test_dir" "$1"; }
  firewall_transaction_commit(){ return 0; }
  firewall_remove_all_owned_ports(){ return 0; }
  firewall_managed_chain_exists(){ return 1; }
  _nb_latest_report(){ :; }
  uninstall_script_completely <<< 'y'
) || uninstall_rc=$?
assert_eq '0' "$uninstall_rc" 'uninstall success'
[ ! -e "$uninstall_probe" ] || fail 'successful uninstall left the entry'

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

# sb 入口：文件写进去了不等于命令可用，PATH 解析不到时必须报错并给出修复办法。
sb_probe_dir="${test_dir}/sbbin"
mkdir -p "$sb_probe_dir"
SCRIPT_PATH="${sb_probe_dir}/${COMMAND_NAME}"
printf '#!/bin/bash\n' > "$SCRIPT_PATH"
chmod 755 "$SCRIPT_PATH"

set +e
sb_path_output=$(PATH="/usr/bin:/bin"; sb_registration_done 2>&1)
sb_path_rc=$?
set -e
assert_eq '1' "$sb_path_rc" 'sb entry outside PATH'
assert_contains "$sb_path_output" 'PATH' 'sb PATH hint'
assert_contains "$sb_path_output" "$SCRIPT_PATH" 'sb PATH hint'

sb_ok_rc=0
( PATH="${sb_probe_dir}:${PATH}"; sb_registration_done >/dev/null 2>&1 ) || sb_ok_rc=$?
assert_eq '0' "$sb_ok_rc" 'sb entry inside PATH'

# 安装失败要给出可直接粘贴的下一步，而不是一句笼统的警告。
assert_contains "$(report_sb_install_failure pipe)" 'mktemp' 'sb pipe hint'
assert_contains "$(report_sb_install_failure pipe)" "$SELF_INSTALL_URL" 'sb pipe hint'
assert_contains "$(report_sb_install_failure noroot)" 'root' 'sb noroot hint'

# 脚本正文校验：自更新和入口安装共用同一套判据，真脚本必须过，垃圾内容必须挡。
leyili_payload_has_markers "$SCRIPT_UNDER_TEST" || fail 'real script failed marker validation'
leyili_payload_size_ok "$SCRIPT_UNDER_TEST" || fail 'real script failed size validation'

payload_probe="${test_dir}/payload"
printf '<html>404: Not Found</html>\n' > "$payload_probe"
! leyili_payload_has_markers "$payload_probe" || fail 'error page passed marker validation'
! leyili_payload_size_ok "$payload_probe" || fail 'tiny file passed size validation'

# 只有 shebang 和结构标记、但被截断的内容也必须挡下（大小下限）。
{ printf '#!/bin/bash\n'; printf 'APP_NAME="Leyili"\nshow_menu\nacquire_global_lock\n'; } > "$payload_probe"
leyili_payload_has_markers "$payload_probe" || fail 'marker check rejected a valid marker set'
! leyili_payload_size_ok "$payload_probe" || fail 'truncated payload passed size validation'

# 非 HTTPS 来源必须直接拒绝，不允许发起任何请求。
curl(){ fail 'fetch_leyili_payload issued a request for a non-HTTPS URL'; }
wget(){ fail 'fetch_leyili_payload issued a request for a non-HTTPS URL'; }
fetch_rc=0
( SELF_INSTALL_URL="http://example.com/leyili.sh"; fetch_leyili_payload "${test_dir}/never" ) || fetch_rc=$?
assert_eq '1' "$fetch_rc" 'non-HTTPS self-install URL'
unset -f curl wget

# 管道运行（无本地文件可复制）时必须自动装好入口，不再要求用户复制命令。
# 校验后的正文来自 fetch_leyili_payload，这里桩掉网络只验证安装链路。
sb_pipe_dir="${test_dir}/sbpipe"
mkdir -p "$sb_pipe_dir"
SCRIPT_PATH="${sb_pipe_dir}/${COMMAND_NAME}"
detect_self_source_path(){ printf '%s' ''; }
fetch_leyili_payload(){ printf '#!/bin/bash\n# fetched\n' > "$1"; }
sb_pipe_rc=0
( PATH="${sb_pipe_dir}:${PATH}"; register_sb_command >/dev/null 2>&1 ) || sb_pipe_rc=$?
assert_eq '0' "$sb_pipe_rc" 'pipe-mode auto install'
[ -x "$SCRIPT_PATH" ] || fail 'pipe-mode auto install did not produce an executable entry'
assert_contains "$(cat "$SCRIPT_PATH")" '# fetched' 'pipe-mode entry content'

# 获取失败时不能假装成功，且要报出管道 / 获取失败的原因。
rm -f -- "$SCRIPT_PATH"
fetch_leyili_payload(){ return 1; }
sb_fail_rc=0
sb_fail_output=$( ( PATH="${sb_pipe_dir}:${PATH}"; register_sb_command ) 2>&1 ) || sb_fail_rc=$?
assert_eq '1' "$sb_fail_rc" 'pipe-mode fetch failure'
assert_contains "$sb_fail_output" "$SELF_INSTALL_URL" 'pipe-mode fetch failure hint'
[ ! -e "$SCRIPT_PATH" ] || fail 'failed fetch still wrote an entry'

# 入口是符号链接时一律拒绝覆盖，管道路径也不例外。
ln -s /dev/null "$SCRIPT_PATH"
fetch_leyili_payload(){ fail 'symlink entry should be refused before fetching'; }
sb_link_rc=0
( register_sb_command >/dev/null 2>&1 ) || sb_link_rc=$?
assert_eq '1' "$sb_link_rc" 'symlink entry refused'
rm -f -- "$SCRIPT_PATH"
unset -f detect_self_source_path fetch_leyili_payload

# Removed deployment features must stay out of the generated script.
for forbidden in 'sing-box' 'singbox' 'SAGERNET' 'WARP' 'reality' 'hy2' 'tuic' \
                 'anytls' 'ss2022' 'node_' 'NODES_DIR' 'CERTS_DIR' 'INFO_PATH' \
                 'port_hop' 'config_transaction_' 'qrencode' 'acme.sh' \
                 'schedule_iptables''_rollback' '/tmp/.leyili''-' 'latest/''download'; do
  if grep -Fiq -- "$forbidden" "$SCRIPT_UNDER_TEST"; then
    fail "removed feature or forbidden legacy pattern remains: ${forbidden}"
  fi
done

duplicates=$(grep -hEo '^[A-Za-z_][A-Za-z0-9_]*\(\)\{' \
  "$ROOT_DIR"/src/_header.sh "$ROOT_DIR"/src/lib/*.sh "$ROOT_DIR"/src/_entry.sh \
  | sed 's/(){$//' | sort | uniq -d)
[ -z "$duplicates" ] || fail "duplicate function definitions: ${duplicates}"

printf 'smoke: ok\n'
