realm_is_installed(){
  [ -x "$REALM_BIN_PATH" ] && [ -f "$REALM_SERVICE_PATH" ]
}

realm_detect_arch(){
  local m
  m=$(uname -m 2>/dev/null || echo unknown)
  case "$m" in
    x86_64|amd64)   printf 'x86_64' ;;
    aarch64|arm64)  printf 'aarch64' ;;
    *)              return 1 ;;
  esac
}

realm_get_version(){
  if [ -x "$REALM_BIN_PATH" ]; then
    "$REALM_BIN_PATH" -v 2>/dev/null | head -1 | awk '{print $2}'
  fi
}

# 主菜单卡用：返回一行简短状态字符串（已含 ANSI 颜色）
realm_status_str(){
  local ver status status_str count
  if ! realm_is_installed; then
    return 1
  fi
  ver=$(realm_get_version 2>/dev/null)
  [ -z "$ver" ] && ver="?"
  status=$(systemctl is-active realm 2>/dev/null || echo unknown)
  if [ "$status" = "active" ]; then
    status_str="${G}运行中${N}"
  else
    status_str="${R}${status}${N}"
  fi
  count=$(realm_count_rules 2>/dev/null || echo 0)
  printf 'Realm 中转  · v%s · %s · %s 条规则' "$ver" "$status_str" "$count"
}

require_realm_installed(){
  if realm_is_installed; then
    return 0
  fi
  echo ""
  echo -e "${Y}realm 尚未安装，请先在本菜单选择"安装 Realm"${N}"
  pause_screen
  return 1
}

# ─── TOML 操作（纯 awk，不引入新依赖） ─────────────────
# config.toml 结构：
#   [network]          ← 全局，恒在
#   no_tcp = false
#   use_udp = true
#
#   [[endpoints]]      ← 第 1 条规则
#   listen = "[::]:6666"
#   remote = "1.2.3.4:443"
#
#   [[endpoints]]      ← 第 2 条规则
#   ...

realm_count_rules(){
  local n=0
  if [ -f "$REALM_CONFIG_PATH" ]; then
    n=$(grep -c '^\[\[endpoints\]\]' "$REALM_CONFIG_PATH" 2>/dev/null)
  fi
  printf '%s\n' "${n:-0}"
}

# 列出所有规则，输出: "INDEX|LISTEN|REMOTE"，从 1 开始
realm_list_rules(){
  [ -f "$REALM_CONFIG_PATH" ] || return 0
  awk '
    BEGIN { idx = 0; listen = ""; remote = "" }
    /^\[\[endpoints\]\]/ {
      if (idx > 0) printf "%d|%s|%s\n", idx, listen, remote
      idx++
      listen = ""; remote = ""
      next
    }
    /^[[:space:]]*listen[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, ""); gsub(/"/, ""); listen = $0
    }
    /^[[:space:]]*remote[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, ""); gsub(/"/, ""); remote = $0
    }
    END {
      if (idx > 0) printf "%d|%s|%s\n", idx, listen, remote
    }
  ' "$REALM_CONFIG_PATH"
}

# 写 [network] 骨架（首次安装时调用）
realm_config_skeleton(){
  mkdir -p "$REALM_CONFIG_DIR"
  if [ ! -f "$REALM_CONFIG_PATH" ]; then
    cat > "$REALM_CONFIG_PATH" <<'EOF'
[network]
no_tcp = false
use_udp = true
EOF
  fi
}

# realm_add_rule <listen_str> <remote_ip> <remote_port>
# listen_str: "[::]:6666" 或 "0.0.0.0:6666"
realm_add_rule(){
  local listen="$1" remote_ip="$2" remote_port="$3"
  realm_config_skeleton
  cat >> "$REALM_CONFIG_PATH" <<EOF

[[endpoints]]
listen = "${listen}"
remote = "${remote_ip}:${remote_port}"
EOF
}

# realm_delete_rule <index>  (1-based)
realm_delete_rule(){
  local target="$1"
  case "$target" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -f "$REALM_CONFIG_PATH" ] || return 1

  local backup_path tmp
  backup_path="${REALM_CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$REALM_CONFIG_PATH" "$backup_path" 2>/dev/null || true
  tmp=$(mktemp)

  if ! awk -v target="$target" '
    BEGIN { idx = 0; skip = 0 }
    /^\[\[endpoints\]\]/ {
      idx++
      if (idx == target) { skip = 1; next }
      skip = 0
      print
      next
    }
    /^\[/ {                # 进入新顶级表 → 退出 skip 状态
      skip = 0
      print
      next
    }
    {
      if (skip) next
      print
    }
  ' "$REALM_CONFIG_PATH" > "$tmp"; then
    rm -f "$tmp"
    cp "$backup_path" "$REALM_CONFIG_PATH" 2>/dev/null || true
    return 1
  fi

  mv "$tmp" "$REALM_CONFIG_PATH"
  cleanup_old_backups "${REALM_CONFIG_PATH}.bak.*" 5 2>/dev/null || true
  return 0
}

# 清空所有规则，保留 [network]
realm_clear_rules(){
  local backup_path
  backup_path="${REALM_CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$REALM_CONFIG_PATH" "$backup_path" 2>/dev/null || true
  cat > "$REALM_CONFIG_PATH" <<'EOF'
[network]
no_tcp = false
use_udp = true
EOF
  cleanup_old_backups "${REALM_CONFIG_PATH}.bak.*" 5 2>/dev/null || true
}

# ─── 安装 / 卸载 ──────────────────────────────────────
realm_install(){
  if ! require_root; then return 1; fi

  if realm_is_installed; then
    echo -e "${Y}realm 已经安装。如需升级请先卸载再装${N}"
    return 0
  fi

  local arch download_url tmpdir tarball
  arch=$(realm_detect_arch) || {
    echo -e "${R}不支持的 CPU 架构: $(uname -m)${N}"
    return 1
  }
  download_url="${REALM_DOWNLOAD_BASE}/realm-${arch}-unknown-linux-gnu.tar.gz"

  echo -e "${Y}==> 准备依赖（curl / tar）...${N}"
  if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar >/dev/null 2>&1 || {
      echo -e "${R}curl / tar 安装失败，请手动安装后重试${N}"
      return 1
    }
  fi

  tmpdir=$(mktemp -d)
  tarball="${tmpdir}/realm.tar.gz"

  echo -e "${Y}==> 下载 realm (${arch})...${N}"
  echo -e "  ${D}${download_url}${N}"
  if ! curl -fsSL --max-time 60 "$download_url" -o "$tarball"; then
    echo -e "${R}下载失败，请检查网络（GitHub 访问是否正常）${N}"
    rm -rf "$tmpdir"
    return 1
  fi

  echo -e "${Y}==> 解压并安装到 ${REALM_BIN_PATH}...${N}"
  if ! tar -xzf "$tarball" -C "$tmpdir"; then
    echo -e "${R}解压失败，文件可能损坏${N}"
    rm -rf "$tmpdir"
    return 1
  fi
  if [ ! -f "${tmpdir}/realm" ]; then
    echo -e "${R}解压后未找到 realm 二进制${N}"
    rm -rf "$tmpdir"
    return 1
  fi
  install -m 0755 "${tmpdir}/realm" "$REALM_BIN_PATH"
  rm -rf "$tmpdir"

  if ! "$REALM_BIN_PATH" -h >/dev/null 2>&1; then
    echo -e "${R}realm 二进制无法执行（可能是 glibc 版本不匹配）${N}"
    rm -f "$REALM_BIN_PATH"
    return 1
  fi

  echo -e "${Y}==> 写入配置骨架 ${REALM_CONFIG_PATH}...${N}"
  realm_config_skeleton

  echo -e "${Y}==> 写入 systemd 服务 ${REALM_SERVICE_PATH}...${N}"
  cat > "$REALM_SERVICE_PATH" <<EOF
[Unit]
Description=Realm port forwarding service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=${REALM_BIN_PATH} -c ${REALM_CONFIG_PATH}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable realm >/dev/null 2>&1 || true
  # realm 2.9.x 强制要求至少一条 [[endpoints]]，没规则就启动会 panic 并触发 systemd
  # 重启风暴。这里只 enable 不 start，等用户加第一条规则时由 realm_menu_add
  # 里的 systemctl restart 拉起。
  echo -e "${G}realm 二进制 + systemd 单元已就位${N}"
  echo -e "  ${D}（realm 服务暂未启动：等待你添加第一条转发规则后自动拉起）${N}"

  echo ""
  echo -e "  ${G}已就绪。${N}下一步在本菜单\"添加转发规则\"中加第一条规则。"
  return 0
}

realm_uninstall(){
  if ! require_root; then return 1; fi
  if ! realm_is_installed; then
    echo -e "${Y}realm 未安装${N}"
    return 0
  fi

  echo -e "${Y}==> 撤销所有规则的防火墙端口...${N}"
  local rule listen_str port
  while IFS='|' read -r _ listen_str _; do
    port=$(printf '%s' "$listen_str" | awk -F: '{print $NF}')
    if [ -n "$port" ] && [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null; then
      node_revoke_firewall_for_mode "$port" tcp dualstack >/dev/null 2>&1 || true
      node_revoke_firewall_for_mode "$port" udp dualstack >/dev/null 2>&1 || true
    fi
  done < <(realm_list_rules)

  echo -e "${Y}==> 停止并禁用 realm 服务...${N}"
  systemctl stop realm >/dev/null 2>&1 || true
  systemctl disable realm >/dev/null 2>&1 || true

  echo -e "${Y}==> 清理文件...${N}"
  rm -f "$REALM_SERVICE_PATH"
  rm -f "$REALM_BIN_PATH"
  rm -rf "$REALM_CONFIG_DIR"
  systemctl daemon-reload

  echo -e "${G}realm 已彻底卸载${N}"
  return 0
}

# ─── 子菜单交互 ───────────────────────────────────────
realm_menu_add(){
  if ! require_realm_installed; then return 1; fi

  local listen_port remote_ip remote_port listen_mode listen_str
  local my_v4 my_v6 remote_is_v6
  echo ""
  echo -e "  ${B}添加转发规则${N}"
  echo -e "  ${D}（中转机本地监听 → 落地机 IP:端口）${N}"
  echo ""
  echo -e "  ${B}${C}小白须知${N}"
  echo -e "  ${D}• 监听端口 = 客户端最终连本机的端口（A 对外暴露的）${N}"
  echo -e "  ${D}• 落地 IP / 端口 = B 落地机自己的 IP 和节点端口${N}"
  echo -e "  ${D}• 落地是 v4 还是 v6 都行，realm 自动转换${N}"
  echo -e "  ${D}• realm 不参与加密，客户端的 SNI/UUID/pbk 全部用落地机的${N}"
  echo ""

  read -p "  本机监听端口 (1-65535): " listen_port
  if ! validate_port "$listen_port"; then
    echo -e "${R}端口非法${N}"
    return 1
  fi

  # 端口占用检测（事前拦截）
  if command -v ss >/dev/null 2>&1; then
    if ss -tlnH "( sport = :$listen_port )" 2>/dev/null | grep -q . \
       || ss -ulnH "( sport = :$listen_port )" 2>/dev/null | grep -q .; then
      echo -e "${R}端口 ${listen_port} 已被本机其它进程占用，请换一个${N}"
      return 1
    fi
  fi

  echo ""
  echo -e "  ${D}落地机 IP 输入示例：${N}"
  echo -e "  ${D}  IPv4 : 1.2.3.4${N}"
  echo -e "  ${D}  IPv6 : 2001:db8::1   ${L}（不用加方括号，脚本会自动加）${N}"
  read -p "  落地机 IP: " remote_ip
  remote_ip=$(printf '%s' "$remote_ip" | tr -d '[:space:]' | tr -d '[]')
  if [ -z "$remote_ip" ]; then
    echo -e "${R}落地机 IP 不能为空${N}"
    return 1
  fi
  # 判定 IPv6（含冒号且非纯数字端口形式）
  remote_is_v6=0
  if [ "${remote_ip#*:}" != "$remote_ip" ]; then
    remote_is_v6=1
  fi

  # 自连环检查（落地 IP 不能等于本机的 v4 / v6）
  my_v4=$(detect_primary_ipv4 2>/dev/null || true)
  my_v6=$(detect_primary_ipv6 2>/dev/null || true)
  if [ -n "$my_v4" ] && [ "$remote_ip" = "$my_v4" ]; then
    echo -e "${R}落地 IP ${remote_ip} 与本机 IPv4 相同，会形成自连环${N}"
    echo -e "${Y}realm 会把流量转给本机自己，CPU 跑满${N}"
    return 1
  fi
  if [ -n "$my_v6" ] && [ "$remote_ip" = "$my_v6" ]; then
    echo -e "${R}落地 IP ${remote_ip} 与本机 IPv6 相同，会形成自连环${N}"
    return 1
  fi

  # IPv6 加方括号
  if [ "$remote_is_v6" = "1" ]; then
    remote_ip="[${remote_ip}]"
  fi

  read -p "  落地机端口 (1-65535): " remote_port
  if ! validate_port "$remote_port"; then
    echo -e "${R}端口非法${N}"
    return 1
  fi

  echo ""
  echo -e "  ${B}本机监听地址${N}  ${D}（决定客户端能用什么 IP 连进来）${N}"
  echo -e "  ${L}1)${N} ${C}[::]:${listen_port}${N}      ${D}双栈，v4 和 v6 客户端都能进（推荐）${N}"
  echo -e "  ${L}2)${N} ${C}0.0.0.0:${listen_port}${N}   ${D}仅 v4，IPv6 客户端连不上${N}"
  if [ "$remote_is_v6" = "1" ]; then
    echo -e "  ${D}提示：落地是 IPv6 不影响监听类型，本机有 v4 公网选 1 即可${N}"
  fi
  read -p "  选择 (默认 1): " listen_mode
  case "${listen_mode:-1}" in
    1) listen_str="[::]:${listen_port}" ;;
    2) listen_str="0.0.0.0:${listen_port}" ;;
    *) echo -e "${R}选择无效${N}"; return 1 ;;
  esac

  echo ""
  echo -e "${Y}==> 写入规则...${N}"
  if ! realm_add_rule "$listen_str" "$remote_ip" "$remote_port"; then
    echo -e "${R}写入失败${N}"
    return 1
  fi

  echo -e "${Y}==> 放行防火墙端口 ${listen_port} (TCP+UDP, v4+v6)...${N}"
  node_apply_firewall_for_mode "$listen_port" tcp dualstack
  node_apply_firewall_for_mode "$listen_port" udp dualstack

  echo -e "${Y}==> 重启 realm 服务...${N}"
  if systemctl restart realm; then
    echo -e "${G}规则已生效${N}"
  else
    echo -e "${R}realm 重启失败，请用 journalctl -u realm 查看${N}"
    return 1
  fi

  echo ""
  echo -e "  ${G}✓${N} 客户端连接 ${C}本机IP:${listen_port}${N} 会被转发到 ${C}${remote_ip}:${remote_port}${N}"
  if [ "$remote_is_v6" = "1" ]; then
    echo -e "  ${D}（落地是 IPv6，确认本机能 ping 通 ${remote_ip}：${C}ping6 ${remote_ip#[}${N}${D} 去掉方括号试一下）${N}"
  fi
  echo -e "  ${D}提示：客户端的 SNI / UUID / pbk / 密码等加密参数请按${B}落地机${N}${D}配置填${N}"
  return 0
}

realm_menu_view(){
  if ! require_realm_installed; then return 1; fi

  echo ""
  echo -e "  ${B}当前转发规则${N}"
  local count
  count=$(realm_count_rules)
  if [ "$count" -eq 0 ]; then
    echo -e "  ${D}（暂无规则，请先"添加转发规则"）${N}"
  else
    printf "  ${L}│${N}  %-4s %-26s  %s\n" "ID" "本机监听" "落地"
    local idx listen_str remote_str
    while IFS='|' read -r idx listen_str remote_str; do
      printf "  ${L}│${N}  ${Y}%-4s${N} ${C}%-26s${N}  ${C}%s${N}\n" "$idx" "$listen_str" "$remote_str"
    done < <(realm_list_rules)
  fi

  echo ""
  echo -e "  ${B}服务状态${N}"
  local status
  status=$(systemctl is-active realm 2>/dev/null || echo unknown)
  if [ "$status" = "active" ]; then
    echo -e "  ${L}│${N}  ${G}● realm 运行中${N}"
  else
    echo -e "  ${L}│${N}  ${R}● realm ${status}${N}  ${D}（用 journalctl -u realm 看日志）${N}"
  fi

  echo ""
  echo -e "  ${D}配置文件: ${REALM_CONFIG_PATH}${N}"
  return 0
}

realm_menu_delete(){
  if ! require_realm_installed; then return 1; fi

  local count target listen_str port
  count=$(realm_count_rules)
  if [ "$count" -eq 0 ]; then
    echo -e "${Y}当前没有规则${N}"
    return 0
  fi

  echo ""
  echo -e "  ${B}选择要删除的规则${N}"
  local idx ls rs
  while IFS='|' read -r idx ls rs; do
    printf "    ${Y}%s)${N} %s → %s\n" "$idx" "$ls" "$rs"
  done < <(realm_list_rules)
  echo ""
  read -p "  请输入编号 (1-${count}, 回车取消): " target
  [ -z "$target" ] && { echo -e "  已取消"; return 0; }
  case "$target" in
    ''|*[!0-9]*) echo -e "${R}编号非法${N}"; return 1 ;;
  esac
  if [ "$target" -lt 1 ] || [ "$target" -gt "$count" ]; then
    echo -e "${R}编号超出范围${N}"
    return 1
  fi

  # 提前抓出该规则的端口，便于撤防火墙
  listen_str=$(realm_list_rules | awk -F'|' -v t="$target" '$1==t{print $2}')
  port=$(printf '%s' "$listen_str" | awk -F: '{print $NF}')

  echo -e "${Y}==> 从配置移除规则 ${target}...${N}"
  if ! realm_delete_rule "$target"; then
    echo -e "${R}删除失败${N}"
    return 1
  fi

  if [ -n "$port" ] && [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null; then
    echo -e "${Y}==> 撤销防火墙端口 ${port}...${N}"
    node_revoke_firewall_for_mode "$port" tcp dualstack
    node_revoke_firewall_for_mode "$port" udp dualstack
  fi

  echo -e "${Y}==> 重启 realm 服务...${N}"
  systemctl restart realm >/dev/null 2>&1 || true
  echo -e "${G}规则 ${target} 已删除${N}"
  return 0
}

realm_menu_clear(){
  if ! require_realm_installed; then return 1; fi
  local count
  count=$(realm_count_rules)
  if [ "$count" -eq 0 ]; then
    echo -e "${Y}当前没有规则${N}"
    return 0
  fi

  echo ""
  echo -e "  ${R}${B}此操作将清空所有 ${count} 条规则${N}"
  read -p "  确认？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    return 0
  fi

  # 收集所有端口先撤防火墙
  echo -e "${Y}==> 撤销所有规则的防火墙端口...${N}"
  local listen_str port
  while IFS='|' read -r _ listen_str _; do
    port=$(printf '%s' "$listen_str" | awk -F: '{print $NF}')
    if [ -n "$port" ] && [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null; then
      node_revoke_firewall_for_mode "$port" tcp dualstack >/dev/null 2>&1 || true
      node_revoke_firewall_for_mode "$port" udp dualstack >/dev/null 2>&1 || true
    fi
  done < <(realm_list_rules)

  echo -e "${Y}==> 清空配置...${N}"
  realm_clear_rules

  echo -e "${Y}==> 重启 realm 服务...${N}"
  systemctl restart realm >/dev/null 2>&1 || true
  echo -e "${G}已清空全部规则${N}"
  return 0
}

# ─── 自检诊断 ─────────────────────────────────────────
# 一次性把 7 类常见故障点的实际状态打印出来，快速定位"链路不通"
realm_menu_diagnose(){
  if ! require_realm_installed; then return 1; fi

  local count
  count=$(realm_count_rules)

  echo ""
  echo -e "  ${B}${C}Realm 一键自检诊断${N}"
  render_divider

  # ── [1] 服务状态
  echo -e "  ${B}[1/7] 服务状态${N}"
  local status
  status=$(systemctl is-active realm 2>/dev/null || echo unknown)
  if [ "$status" = "active" ]; then
    echo -e "    ${G}● realm: active${N}"
  else
    echo -e "    ${R}● realm: ${status}${N}  ${D}(以下是 systemctl status 摘要)${N}"
    systemctl status realm --no-pager -l 2>&1 | head -12 | sed 's/^/      /'
  fi
  echo ""

  # ── [2] 配置文件
  echo -e "  ${B}[2/7] 配置文件 ${C}${REALM_CONFIG_PATH}${N}"
  if [ -f "$REALM_CONFIG_PATH" ]; then
    sed 's/^/      /' "$REALM_CONFIG_PATH"
  else
    echo -e "      ${R}配置文件不存在${N}"
  fi
  echo ""

  if [ "$count" -eq 0 ]; then
    echo -e "  ${Y}[3-6] 无转发规则，跳过端口/防火墙/出站连通性检查${N}"
    echo ""
  fi

  # ── [3-6] 逐条规则
  local idx listen_str remote_str listen_port r_host r_port
  while IFS='|' read -r idx listen_str remote_str; do
    listen_port=$(printf '%s' "$listen_str" | awk -F: '{print $NF}')
    # remote 格式：IPv4 = 1.2.3.4:443，IPv6 = [2001:db8::1]:443
    if [[ "$remote_str" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
      r_host="${BASH_REMATCH[1]}"
      r_port="${BASH_REMATCH[2]}"
    else
      r_host="${remote_str%:*}"
      r_port="${remote_str##*:}"
    fi

    echo -e "  ${B}━━━ 规则 ${Y}${idx}${B}: ${C}${listen_str}${N} ${B}→${N} ${C}${remote_str}${N} ${B}━━━${N}"

    # [3] 监听端口
    echo -e "  ${B}[3/7] 端口监听情况${N}"
    local tcp_listen udp_listen
    tcp_listen=$(ss -tlnH 2>/dev/null | awk -v p=":${listen_port}\$" '$4 ~ p { print "      " $0 }')
    udp_listen=$(ss -ulnH 2>/dev/null | awk -v p=":${listen_port}\$" '$4 ~ p { print "      " $0 }')
    if [ -n "$tcp_listen" ]; then
      echo -e "    ${G}TCP ✓ 已监听${N}"
      echo "$tcp_listen"
    else
      echo -e "    ${R}TCP ✗ 未监听 ${listen_port}${N}  ${D}(realm 未起来 / 配置没生效)${N}"
    fi
    if [ -n "$udp_listen" ]; then
      echo -e "    ${G}UDP ✓ 已监听${N}"
      echo "$udp_listen"
    else
      echo -e "    ${Y}UDP ✗ 未监听 ${listen_port}${N}  ${D}(Hy2/QUIC 必需; Reality/AnyTLS 不需要)${N}"
    fi

    # [4] v4 防火墙
    echo -e "  ${B}[4/7] IPv4 INPUT 防火墙${N}"
    local v4_pol v4_match
    v4_pol=$(ip4_get_input_policy)
    if [ "$v4_pol" = "ACCEPT" ]; then
      echo -e "    ${G}默认策略 ACCEPT，无需显式放行${N}"
    elif [ "$v4_pol" = "DROP" ]; then
      v4_match=$(iptables -nL INPUT 2>/dev/null | awk -v p="dpt:${listen_port}\$" '$0 ~ p { print "      " $0 }')
      if [ -n "$v4_match" ]; then
        echo -e "    ${G}默认 DROP, 已显式放行 ${listen_port}${N}"
        echo "$v4_match"
      else
        echo -e "    ${R}默认 DROP 但未放行 ${listen_port}/tcp${N}"
      fi
    else
      echo -e "    ${Y}默认策略未知: ${v4_pol:-?}${N}"
    fi

    # [5] v6 防火墙
    echo -e "  ${B}[5/7] IPv6 INPUT 防火墙${N}"
    local v6_pol v6_match
    v6_pol=$(ip6_get_input_policy)
    if [ "$v6_pol" = "ACCEPT" ]; then
      echo -e "    ${G}默认策略 ACCEPT，无需显式放行${N}"
    elif [ "$v6_pol" = "DROP" ]; then
      v6_match=$(ip6tables -nL INPUT 2>/dev/null | awk -v p="dpt:${listen_port}\$" '$0 ~ p { print "      " $0 }')
      if [ -n "$v6_match" ]; then
        echo -e "    ${G}默认 DROP, 已显式放行 ${listen_port}${N}"
        echo "$v6_match"
      else
        echo -e "    ${R}默认 DROP 但未放行 ${listen_port}/tcp${N}  ${D}(v6 客户端进不来)${N}"
      fi
    else
      echo -e "    ${Y}默认策略未知: ${v6_pol:-?}${N}"
    fi

    # [6] 出站连通性
    echo -e "  ${B}[6/7] 中转机 → 落地机 ${C}${r_host}:${r_port}${N} ${B}TCP 出站${N}"
    if command -v nc >/dev/null 2>&1; then
      if timeout 6 nc -z -w 5 "$r_host" "$r_port" >/dev/null 2>&1; then
        echo -e "    ${G}✓ TCP 出站可达 (落地机端口能接受)${N}"
      else
        echo -e "    ${R}✗ TCP 出站不通${N}  ${D}(落地机 sing-box 没起 / 落地防火墙 / 路由 / 安全组)${N}"
      fi
    else
      echo -e "    ${Y}nc 命令不可用，跳过出站连通性检查${N}"
    fi
    echo ""

  done < <(realm_list_rules)

  # ── [7] 日志
  echo -e "  ${B}[7/7] realm 最近 30 行日志${N}"
  if journalctl -u realm --no-pager -n 30 2>/dev/null | sed 's/^/      /'; then
    :
  else
    echo -e "      ${Y}journalctl 读取失败${N}"
  fi
  echo ""

  echo -e "  ${D}诊断完成。把以上输出全部贴给开发者即可定位问题。${N}"
  return 0
}

# ─── 顶级菜单 ─────────────────────────────────────────
show_realm_menu(){
  while true; do
    render_section_header "Realm 中转管理"

    echo -e "  ${B}${C}什么是 Realm 中转？${N}"
    echo -e "  ${D}客户端 → ${C}中转机(realm 透传)${D} → ${C}落地机(sing-box)${D} → 互联网${N}"
    echo -e "  ${D}realm 只搬运字节，不解密；加密握手在客户端 ↔ 落地机之间端到端完成。${N}"
    echo ""
    echo -e "  ${B}${C}使用流程${N}"
    echo -e "  ${Y}①${N} 落地机 B：装 sing-box 节点 → 复制客户端链接"
    echo -e "  ${Y}②${N} 中转机 A（本机）：本菜单 ${C}1)${N} 安装 → ${C}2)${N} 加规则（监听端口 → B 的 IP:端口）"
    echo -e "  ${Y}③${N} 客户端配置：把 IP 改成 A 的，${R}${B}SNI/UUID/pbk 全部用 B 的${N}"
    echo -e "  ${Y}④${N} 连上访问 ipify.org 应看到 B 的 IP，搞定"
    echo ""
    echo -e "  ${B}${C}IPv6 / 双栈场景（不用懵，看一眼就懂）${N}"
    echo -e "  ${D}落地机 IP 是 ${C}IPv4${D} 还是 ${C}IPv6${D} 都行，加规则时直接填进去即可。${N}"
    echo -e "  ${D}监听类型决定客户端能用什么 IP 进来：${C}[::]${D} 双栈通吃，${C}0.0.0.0${D} 仅 v4。${N}"
    echo -e "  ${D}两件事独立——比如本机选 ${C}[::]${D}（v4+v6 客户端都进）落地写 IPv6，OK。${N}"
    echo ""
    echo -e "  ${D}详细教程见 realm-中转落地指南.md（含 IPv6 场景表）${N}"
    render_divider

    if realm_is_installed; then
      local ver count status
      ver=$(realm_get_version 2>/dev/null)
      [ -z "$ver" ] && ver="?"
      count=$(realm_count_rules)
      status=$(systemctl is-active realm 2>/dev/null || echo unknown)
      echo -e "  状态     : ${G}已安装${N}  ${D}v${ver}${N}"
      if [ "$status" = "active" ]; then
        echo -e "  服务     : ${G}运行中${N}"
      else
        echo -e "  服务     : ${R}${status}${N}"
      fi
      echo -e "  规则数量 : ${C}${count}${N} 条"
    else
      echo -e "  状态     : ${Y}未安装${N}  ${D}（请先选 1 安装）${N}"
    fi
    render_divider

    render_menu_item 1 "安装 Realm"
    render_menu_item 2 "添加转发规则"
    render_menu_item 3 "查看规则 / 服务状态"
    render_menu_item 4 "删除单条规则"
    render_menu_item 5 "清空全部规则"
    render_menu_item 6 "重启 realm 服务"
    render_menu_item 7 "查看实时日志"
    render_menu_item 8 "一键自检诊断"
    render_menu_item 9 "卸载 Realm"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice
    case "$choice" in
      1) realm_install; pause_screen ;;
      2) realm_menu_add; pause_screen ;;
      3) realm_menu_view; pause_screen ;;
      4) realm_menu_delete; pause_screen ;;
      5) realm_menu_clear; pause_screen ;;
      6)
        if require_realm_installed; then
          if systemctl restart realm; then
            echo -e "${G}realm 已重启${N}"
          else
            echo -e "${R}重启失败，请用 journalctl -u realm 查看${N}"
          fi
        fi
        pause_screen
        ;;
      7)
        if require_realm_installed; then
          echo -e "${D}（按 Ctrl+C 退出日志）${N}"
          journalctl -u realm -f --no-pager 2>/dev/null || true
        fi
        ;;
      8) realm_menu_diagnose; pause_screen ;;
      9) realm_uninstall; pause_screen ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

# ─── 服务器状态面板 ───────────────────────────────────
