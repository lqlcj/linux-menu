apply_tcp_tuning(){
  local region="${1:-us-west}"
  local mem_tier="${2:-2g}"
  local region_label notsent_lowat fin_timeout buffer_max mem_label

  if ! require_root; then return 1; fi

  case "$region" in
    hk)
      region_label="香港"
      notsent_lowat=16384
      fin_timeout=5
      ;;
    jp)
      region_label="日本"
      notsent_lowat=16384
      fin_timeout=5
      ;;
    us-west)
      region_label="美西"
      notsent_lowat=16384
      fin_timeout=10
      ;;
    eu)
      region_label="欧洲"
      notsent_lowat=16384
      fin_timeout=10
      ;;
    *)
      echo -e "${R}未知地区: $region${N}"
      return 1
      ;;
  esac

  case "${region}_${mem_tier}" in
    hk_512m)     buffer_max=4194304   ;;
    hk_1g)       buffer_max=8388608   ;;
    hk_2g)       buffer_max=16777216  ;;
    hk_4g)       buffer_max=16777216  ;;
    hk_8g)       buffer_max=33554432  ;;
    jp_512m)     buffer_max=6291456   ;;
    jp_1g)       buffer_max=12582912  ;;
    jp_2g)       buffer_max=16777216  ;;
    jp_4g)       buffer_max=25165824  ;;
    jp_8g)       buffer_max=33554432  ;;
    # us-west_512m: CloudCone LA 实测 185ms RTT，按 200Mbps × 1.5 ≈ 8M；
    # 512MB 总内存严格防 OOM，比 1GB 档（16M）小一档，单连接占用减半
    us-west_512m) buffer_max=8388608  ;;
    us-west_1g)  buffer_max=16777216  ;;
    us-west_2g)  buffer_max=33554432  ;;
    us-west_4g)  buffer_max=50331648  ;;
    us-west_8g)  buffer_max=67108864  ;;
    eu_512m)     buffer_max=8388608   ;;
    eu_1g)       buffer_max=16777216  ;;
    eu_2g)       buffer_max=33554432  ;;
    eu_4g)       buffer_max=50331648  ;;
    eu_8g)       buffer_max=67108864  ;;
    *)
      echo -e "${R}未知组合: ${region}/${mem_tier}${N}"
      return 1
      ;;
  esac

  case "$mem_tier" in
    512m) mem_label="512MB" ;;
    1g)  mem_label="1GB"  ;;
    2g)  mem_label="2GB"  ;;
    4g)  mem_label="4GB"  ;;
    8g)  mem_label="8GB+" ;;
    *)   mem_label="$mem_tier" ;;
  esac

  echo ""
  echo -e "${Y}==> 写入 ${region_label}/${mem_label} TCP 参数优化配置 (上限 $((buffer_max/1024/1024))M)...${N}"

  cat > "$TCP_TUNING_PATH" <<EOF
# leyili-profile: region=${region} mem_tier=${mem_tier}
# 由 leyili.sh 一键网络优化生成 (${region_label} / ${mem_label})
# 偏好：交互流（网页 / 社交 / 流媒体），非吞吐党

# --- 拥塞控制 + 调度 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# TFO = 1 仅客户端方向；服务端在国内出口常被运营商干扰 cookie，
# 首包失败比首包提前 1RTT 更常见，因此服务端关闭
net.ipv4.tcp_fastopen = 1

# --- 缓冲区 (按地区 BDP 与内存档计算) ---
# default 提到 512K：小连接也能直接进入有效拥塞窗口，不用等慢启动 grow
net.core.rmem_max = ${buffer_max}
net.core.wmem_max = ${buffer_max}
net.core.rmem_default = 524288
net.core.wmem_default = 524288
net.ipv4.tcp_rmem = 16384 524288 ${buffer_max}
net.ipv4.tcp_wmem = 16384 524288 ${buffer_max}
# 路径不稳时偏 receiver 应用层 buffer，跨境丢包场景更跟手
net.ipv4.tcp_adv_win_scale = 2

# --- 长连接 / 慢启动 / MTU ---
# 16K：NaiveProxy 实测值，TCP-in-TLS 隧道防 HoL 阻塞 / 顿挫感的关键
# (Cloudflare 早期推荐 128K 是面向 web server 吞吐场景，不适用代理转发)
net.ipv4.tcp_notsent_lowat = ${notsent_lowat}
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_no_pmtu_disc = 0

# --- 连接回收与高并发 ---
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = ${fin_timeout}
net.ipv4.tcp_max_tw_buckets = 65536
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_syncookies = 1
# 防止异常 orphan 吃内存（小机器场景）
net.ipv4.tcp_max_orphans = 16384

# --- 保活 (防中间设备踢空闲连接) ---
# 国内运营商 NAT 表常 5min 踢，缩短到 2min；切后台回来"第一下卡"主要由此引起
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5

# --- 代理服务器专用 ---
# 不缓存上次连接的 RTT/cwnd 指纹 (面对全球客户端必加)
net.ipv4.tcp_no_metrics_save = 1
# ECN: 2 = 被动接受不主动发起 (RFC 8311 推荐，避开国内运营商对 ECN 标记的误判)
net.ipv4.tcp_ecn = 2
# TIME-WAIT 状态下抑制迷路 RST/重复 FIN 干扰 (RFC 1337)
net.ipv4.tcp_rfc1337 = 1
# 异常连接重试 8≈100s：交互流场景下烂连接早点放弃让应用层重连
# (默认 15≈924s 太久；之前 10≈280s 对刷网页/社交仍偏长)
net.ipv4.tcp_retries2 = 8
# SYN+ACK 重试 (Cloudflare/Red Hat 主流推荐 3≈45s，比默认 5≈63s 更稳健)
net.ipv4.tcp_synack_retries = 3
# 孤儿连接重试 (HAProxy/Nginx 生产标配；默认 8 在高并发下消耗内存，3≈25s 释放)
net.ipv4.tcp_orphan_retries = 3

# --- 临时端口范围 (避开常用服务端口) ---
net.ipv4.ip_local_port_range = 10000 65535
EOF

  echo -e "${Y}==> 应用 sysctl 配置...${N}"
  if ! sysctl -p "$TCP_TUNING_PATH"; then
    echo -e "${R}TCP 参数应用失败，请检查内核兼容性或 sysctl 输出${N}"
    return 1
  fi

  return 0
}

remove_tcp_tuning(){
  local confirm=""
  local service_name route_line route_spec

  if ! require_root; then
    return 1
  fi

  if [ ! -f "$TCP_TUNING_PATH" ]; then
    echo ""
    echo -e "${Y}未检测到 TCP 优化配置，无需移除${N}"
    pause_screen
    return 0
  fi

  echo ""
  echo -e "${Y}==> 即将移除 ${C}$TCP_TUNING_PATH${N}${Y}，并恢复默认 qdisc / 拥塞算法${N}"
  echo -e "${Y}    同时撤销配套的 initcwnd 持久化服务（若存在）${N}"
  read -p "  确认继续？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  rm -f "$TCP_TUNING_PATH"

  sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || true

  # 配套撤销 initcwnd（apply_network_optimization 是把 TCP+initcwnd 当一组应用的，对称地撤）
  service_name=$(basename "$INITCWND_SERVICE_PATH")
  if [ -f "$INITCWND_SERVICE_PATH" ] || systemctl cat "$service_name" >/dev/null 2>&1; then
    systemctl disable --now "$service_name" >/dev/null 2>&1 || true
    rm -f "$INITCWND_SERVICE_PATH"
    systemctl daemon-reload >/dev/null 2>&1 || true
    if command -v ip >/dev/null 2>&1; then
      route_line=$(ip route show default 2>/dev/null | head -1)
      if [ -n "$route_line" ]; then
        route_spec=$(printf '%s\n' "$route_line" | awk '{
          sep=""
          for (i = 1; i <= NF; i++) {
            if ($i == "initcwnd" || $i == "initrwnd") { i++; next }
            printf "%s%s", sep, $i
            sep=" "
          }
        }')
        # shellcheck disable=SC2086
        ip route replace $route_spec >/dev/null 2>&1 || true
      fi
    fi
    echo -e "  ${D}initcwnd 持久化服务已移除${N}"
  fi

  echo ""
  echo -e "${G}TCP 优化已移除（部分参数重启后完全复位）${N}"
  pause_screen
}

apply_quic_tuning(){
  local region="${1:-us-west}"
  local mem_tier="${2:-2g}"
  local region_label buffer_max mem_label

  if ! require_root; then return 1; fi

  case "$region" in
    hk)      region_label="香港" ;;
    jp)      region_label="日本" ;;
    us-west) region_label="美西" ;;
    eu)      region_label="欧洲" ;;
    *)
      echo -e "${R}未知地区: $region${N}"
      return 1
      ;;
  esac

  case "${region}_${mem_tier}" in
    hk_512m)     buffer_max=8388608   ;;
    hk_1g)       buffer_max=16777216  ;;
    hk_2g)       buffer_max=33554432  ;;
    hk_4g)       buffer_max=33554432  ;;
    hk_8g)       buffer_max=67108864  ;;
    jp_512m)     buffer_max=12582912  ;;
    jp_1g)       buffer_max=16777216  ;;
    jp_2g)       buffer_max=33554432  ;;
    jp_4g)       buffer_max=67108864  ;;
    jp_8g)       buffer_max=67108864  ;;
    us-west_512m) buffer_max=16777216 ;;
    us-west_1g)  buffer_max=25165824  ;;
    us-west_2g)  buffer_max=67108864  ;;
    us-west_4g)  buffer_max=100663296 ;;
    us-west_8g)  buffer_max=134217728 ;;
    eu_512m)     buffer_max=16777216  ;;
    eu_1g)       buffer_max=33554432  ;;
    eu_2g)       buffer_max=67108864  ;;
    eu_4g)       buffer_max=134217728 ;;
    eu_8g)       buffer_max=134217728 ;;
    *)
      echo -e "${R}未知组合: ${region}/${mem_tier}${N}"
      return 1
      ;;
  esac

  case "$mem_tier" in
    512m) mem_label="512MB" ;;
    1g)  mem_label="1GB"  ;;
    2g)  mem_label="2GB"  ;;
    4g)  mem_label="4GB"  ;;
    8g)  mem_label="8GB+" ;;
    *)   mem_label="$mem_tier" ;;
  esac

  echo ""
  echo -e "${Y}==> 写入 ${region_label}/${mem_label} QUIC/UDP 参数优化配置 (上限 $((buffer_max/1024/1024))M)...${N}"

  cat > "$QUIC_TUNING_PATH" <<EOF
# leyili-quic-profile: region=${region} mem_tier=${mem_tier}
# 由 leyili.sh QUIC/UDP 协议优化生成 (${region_label} / ${mem_label})
# 与 99-proxy-optimized.conf 配合使用，互不冲突；服务对象：TUIC / Hysteria2

# --- UDP socket 缓冲区 (QUIC 性能命根子) ---
# QUIC 在用户态做拥塞控制，内核缓冲区只负责暂存，过小直接 packet drop
# sing-box 启动若日志出现 "failed to sufficiently increase receive buffer size"
# 说明这两个值未生效
net.core.rmem_max = ${buffer_max}
net.core.wmem_max = ${buffer_max}
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576

# --- 网卡入队深度 (TCP/UDP 共享，取较大值兼容) ---
net.core.netdev_max_backlog = 32768

# --- conntrack (NAT 环境下 UDP 流易爆表，1M 条目 ≈ 200MB 内存) ---
# 容器/LXC 内可能写不进去，sysctl -p 失败时由上层提示
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
EOF

  echo -e "${Y}==> 应用 sysctl 配置...${N}"
  if ! sysctl -p "$QUIC_TUNING_PATH"; then
    echo -e "${R}QUIC 参数应用失败，请检查内核兼容性或 sysctl 输出${N}"
    echo -e "${D}（容器/LXC 环境下 nf_conntrack_* 可能不可写，属正常现象）${N}"
    return 1
  fi

  return 0
}

remove_quic_tuning(){
  local confirm=""

  if ! require_root; then
    return 1
  fi

  if [ ! -f "$QUIC_TUNING_PATH" ]; then
    echo ""
    echo -e "${Y}未检测到 QUIC 优化配置，无需移除${N}"
    pause_screen
    return 0
  fi

  echo ""
  echo -e "${Y}==> 即将移除 ${C}$QUIC_TUNING_PATH${N}${Y}，并通过 sysctl --system 复位参数${N}"
  read -p "  确认继续？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  rm -f "$QUIC_TUNING_PATH"

  sysctl --system >/dev/null 2>&1 || true

  echo ""
  echo -e "${G}QUIC 优化已移除（UDP 缓冲区将回落至 99-proxy-optimized.conf 或内核默认值）${N}"
  pause_screen
}

apply_quic_optimization(){
  local region="$1"
  local mem_tier="$2"
  local region_label mem_label
  local buffer_max

  if ! require_root; then return 1; fi

  case "$region" in
    hk)      region_label="香港" ;;
    jp)      region_label="日本" ;;
    us-west) region_label="美西" ;;
    eu)      region_label="欧洲" ;;
    *)
      echo -e "${R}未知地区: $region${N}"
      pause_screen
      return 1
      ;;
  esac

  case "$mem_tier" in
    512m) mem_label="512MB" ;;
    1g)  mem_label="1GB"  ;;
    2g)  mem_label="2GB"  ;;
    4g)  mem_label="4GB"  ;;
    8g)  mem_label="8GB+" ;;
    *)
      echo -e "${R}未知内存档: $mem_tier${N}"
      pause_screen
      return 1
      ;;
  esac

  if ! apply_quic_tuning "$region" "$mem_tier"; then
    echo -e "${R}QUIC 调优失败，已中止${N}"
    pause_screen
    return 1
  fi

  buffer_max=$(awk -F'=' '/^[[:space:]]*net\.core\.rmem_max/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$QUIC_TUNING_PATH" 2>/dev/null)

  echo ""
  echo -e "${G}✓ QUIC/UDP 协议优化完成${N}"
  echo -e "  地区        : ${C}$region_label${N}"
  echo -e "  内存档位    : ${C}$mem_label${N}"
  if [ -n "$buffer_max" ] && [ "$buffer_max" -gt 0 ] 2>/dev/null; then
    echo -e "  rmem/wmem   : ${C}$((buffer_max / 1024 / 1024))M${N}"
  fi
  echo -e "  配置文件    : ${C}$QUIC_TUNING_PATH${N}"
  echo ""
  echo -e "  ${D}提示：调优生效后建议重启 sing-box 让 TUIC/HY2 重新分配缓冲区${N}"
  echo -e "  ${D}      systemctl restart sing-box${N}"
  pause_screen
}

apply_initcwnd_optimization(){
  local route_line route_spec ip_bin current_route
  local initcwnd_value="${1:-$INITCWND_VALUE}"
  local quiet="${2:-0}"


  if ! require_root; then return 1; fi

  echo ""

  if ! command -v ip &>/dev/null; then
    echo -e "${R}未找到 ip 命令，无法配置 initcwnd${N}"
    [ "$quiet" != "1" ] && pause_screen
    return 1
  fi

  route_line=$(ip route show default 2>/dev/null | head -1)
  if [ -z "$route_line" ]; then
    echo -e "${R}未检测到默认路由，无法自动配置 initcwnd${N}"
    [ "$quiet" != "1" ] && pause_screen
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
  echo -e "${Y}==> 应用 initcwnd/initrwnd ${initcwnd_value}...${N}"
  if ! ip route replace $route_spec initcwnd $initcwnd_value initrwnd $initcwnd_value; then
    echo -e "${R}默认路由优化失败，请检查路由权限或当前网络环境${N}"
    [ "$quiet" != "1" ] && pause_screen
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
ExecStart=$ip_bin route replace $route_spec initcwnd $initcwnd_value initrwnd $initcwnd_value
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  if ! systemctl daemon-reload; then
    echo -e "${R}systemd 重新加载失败${N}"
    [ "$quiet" != "1" ] && pause_screen
    return 1
  fi

  if ! systemctl enable --now "$(basename "$INITCWND_SERVICE_PATH")"; then
    echo -e "${R}initcwnd 持久化服务启用失败${N}"
    [ "$quiet" != "1" ] && pause_screen
    return 1
  fi

  if [ "$quiet" = "1" ]; then
    return 0
  fi

  current_route=$(ip route show default 2>/dev/null | head -1)
  echo ""
  echo -e "${G}initcwnd 优化已生效${N}"
  echo -e "  当前默认路由: ${C}$current_route${N}"
  if printf '%s\n' "$current_route" | grep -Eq "(^| )initcwnd ${initcwnd_value}( |$)"; then
    echo -e "  initcwnd: ${C}${initcwnd_value}${N}"
  fi
  if printf '%s\n' "$current_route" | grep -Eq "(^| )initrwnd ${initcwnd_value}( |$)"; then
    echo -e "  initrwnd: ${C}${initcwnd_value}${N}"
  fi
  echo -e "  持久化服务: ${C}$(basename "$INITCWND_SERVICE_PATH")${N}"
  pause_screen
}

remove_initcwnd_optimization(){
  local confirm=""
  local service_name
  local route_line route_spec

  if ! require_root; then
    return 1
  fi

  service_name=$(basename "$INITCWND_SERVICE_PATH")
  if [ ! -f "$INITCWND_SERVICE_PATH" ] && ! systemctl cat "$service_name" >/dev/null 2>&1; then
    echo ""
    echo -e "${Y}未检测到 initcwnd 持久化服务，无需移除${N}"
    pause_screen
    return 0
  fi

  echo ""
  read -p "  确认移除 initcwnd 持久化服务并恢复默认路由？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  systemctl disable --now "$service_name" >/dev/null 2>&1 || true
  rm -f "$INITCWND_SERVICE_PATH"
  systemctl daemon-reload >/dev/null 2>&1 || true

  if command -v ip >/dev/null 2>&1; then
    route_line=$(ip route show default 2>/dev/null | head -1)
    if [ -n "$route_line" ]; then
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
      }')
      # shellcheck disable=SC2086
      ip route replace $route_spec >/dev/null 2>&1 || true
    fi
  fi

  echo ""
  echo -e "${G}initcwnd 优化已移除${N}"
  pause_screen
}

_buffer_label_for(){
  local r="$1" m="$2"
  case "${r}_${m}" in
    hk_512m)     echo "4M"  ;;
    hk_1g)       echo "16M" ;;
    hk_2g)       echo "32M" ;;
    hk_4g)       echo "32M" ;;
    hk_8g)       echo "64M" ;;
    jp_512m)     echo "6M"  ;;
    jp_1g)       echo "16M" ;;
    jp_2g)       echo "32M" ;;
    jp_4g)       echo "64M" ;;
    jp_8g)       echo "64M" ;;
    us-west_512m) echo "8M" ;;
    us-west_1g)  echo "24M" ;;
    us-west_2g)  echo "64M" ;;
    us-west_4g)  echo "96M" ;;
    us-west_8g)  echo "128M" ;;
    eu_512m)     echo "8M"  ;;
    eu_1g)       echo "32M" ;;
    eu_2g)       echo "64M" ;;
    eu_4g)       echo "128M" ;;
    eu_8g)       echo "128M" ;;
    *)           echo "?" ;;
  esac
}

apply_network_optimization(){
  local region="$1"
  local mem_tier="$2"
  local region_label initcwnd_value mem_label
  local buffer_max notsent_lowat fin_timeout

  if ! require_root; then return 1; fi

  case "$region" in
    hk)      region_label="香港"; initcwnd_value=32 ;;
    jp)      region_label="日本"; initcwnd_value=32 ;;
    us-west) region_label="美西"; initcwnd_value=32 ;;
    eu)      region_label="欧洲"; initcwnd_value=32 ;;
    *)
      echo -e "${R}未知地区: $region${N}"
      pause_screen
      return 1
      ;;
  esac

  case "$mem_tier" in
    512m) mem_label="512MB" ;;
    1g)  mem_label="1GB"  ;;
    2g)  mem_label="2GB"  ;;
    4g)  mem_label="4GB"  ;;
    8g)  mem_label="8GB+" ;;
    *)
      echo -e "${R}未知内存档: $mem_tier${N}"
      pause_screen
      return 1
      ;;
  esac

  if ! apply_tcp_tuning "$region" "$mem_tier"; then
    echo -e "${R}TCP 调优失败，已中止${N}"
    pause_screen
    return 1
  fi

  if ! apply_initcwnd_optimization "$initcwnd_value" 1; then
    echo -e "${R}initcwnd 优化失败（TCP 调优已生效，但 initcwnd 未应用）${N}"
    pause_screen
    return 1
  fi

  buffer_max=$(awk -F'=' '/^[[:space:]]*net\.core\.rmem_max/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$TCP_TUNING_PATH" 2>/dev/null)
  notsent_lowat=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo "?")
  fin_timeout=$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null || echo "?")

  echo ""
  echo -e "${G}✓ 网络优化完成${N}"
  echo -e "  地区        : ${C}$region_label${N}"
  echo -e "  内存档位    : ${C}$mem_label${N}"
  if [ -n "$buffer_max" ] && [ "$buffer_max" -gt 0 ] 2>/dev/null; then
    echo -e "  rmem/wmem   : ${C}$((buffer_max / 1024 / 1024))M${N}"
  fi
  echo -e "  notsent     : ${C}$notsent_lowat${N}"
  echo -e "  fin_timeout : ${C}$fin_timeout${N}"
  echo -e "  initcwnd    : ${C}$initcwnd_value${N}"
  echo -e "  qdisc / cc  : ${C}$(sysctl -n net.core.default_qdisc 2>/dev/null) / $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${N}"
  echo -e "  配置文件    : ${C}$TCP_TUNING_PATH${N}"
  pause_screen
}

show_network_optimization_menu(){
  local choice

  while true; do
    render_section_header "网络优化"
    render_menu_item 1 "TCP 调优 + initcwnd"
    render_menu_item 2 "QUIC/UDP 协议优化"
    render_menu_item 3 "移除 TCP 调优"
    render_menu_item 4 "移除 QUIC 调优"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case "$choice" in
      1) show_tcp_optimization_picker ;;
      2) show_quic_optimization_picker ;;
      3) remove_tcp_tuning ;;
      4) remove_quic_tuning ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

show_tcp_optimization_picker(){
  local region region_choice region_label mem_choice mem_tier
  local detected_mem_kb detected_mem_gb

  while true; do
    render_section_header "TCP 调优 + initcwnd"
    render_menu_item 1 "香港   ${D}(RTT≈80ms,  BDP≈10M)${N}"
    render_menu_item 2 "日本   ${D}(RTT≈120ms, BDP≈15M)${N}"
    render_menu_item 3 "美西   ${D}(RTT≈200ms, BDP≈25M)${N}"
    render_menu_item 4 "欧洲   ${D}(RTT≈280ms, BDP≈35M)${N}"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请选择地区: " region_choice

    case "$region_choice" in
      1) region="hk";      region_label="香港" ;;
      2) region="jp";      region_label="日本" ;;
      3) region="us-west"; region_label="美西" ;;
      4) region="eu";      region_label="欧洲" ;;
      0) return ;;
      *) notify_invalid_choice; continue ;;
    esac

    while true; do
      render_section_header "${region_label} · 选择内存档位"

      detected_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
      if [ -n "$detected_mem_kb" ] && [ "$detected_mem_kb" -gt 0 ]; then
        detected_mem_gb=$(awk -v kb="$detected_mem_kb" 'BEGIN { printf "%.1f", kb / 1024 / 1024 }')
        echo -e "  ${D}当前检测到内存: ${detected_mem_gb} GB（仅供参考，请按实际选择）${N}"
        echo ""
      fi

      render_menu_item 1 "512 MB   ${D}缓冲上限 $(_buffer_label_for "$region" 512m)${N}"
      render_menu_item 2 "1 GB     ${D}缓冲上限 $(_buffer_label_for "$region" 1g)${N}"
      render_menu_item 3 "2 GB     ${D}缓冲上限 $(_buffer_label_for "$region" 2g)${N}"
      render_menu_item 4 "4 GB     ${D}缓冲上限 $(_buffer_label_for "$region" 4g)${N}"
      render_menu_item 5 "8 GB+    ${D}缓冲上限 $(_buffer_label_for "$region" 8g)${N}"
      render_menu_item 0 "返回选择地区"
      render_divider
      read -p "  请选择内存档位: " mem_choice

      case "$mem_choice" in
        1) mem_tier="512m" ;;
        2) mem_tier="1g" ;;
        3) mem_tier="2g" ;;
        4) mem_tier="4g" ;;
        5) mem_tier="8g" ;;
        0) break ;;
        *) notify_invalid_choice; continue ;;
      esac

      apply_network_optimization "$region" "$mem_tier"
      return
    done
  done
}

show_quic_optimization_picker(){
  local region region_choice region_label mem_choice mem_tier
  local detected_mem_kb detected_mem_gb

  while true; do
    render_section_header "QUIC/UDP 协议优化"
    echo -e "  ${D}面向 TUIC / Hysteria2，调整 UDP 缓冲区与 conntrack${N}"
    echo ""
    render_menu_item 1 "香港   ${D}(亚洲低延迟)${N}"
    render_menu_item 2 "日本   ${D}(亚洲低延迟)${N}"
    render_menu_item 3 "美西   ${D}(跨太平洋高 BDP)${N}"
    render_menu_item 4 "欧洲   ${D}(欧亚高延迟)${N}"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请选择地区: " region_choice

    case "$region_choice" in
      1) region="hk";      region_label="香港" ;;
      2) region="jp";      region_label="日本" ;;
      3) region="us-west"; region_label="美西" ;;
      4) region="eu";      region_label="欧洲" ;;
      0) return ;;
      *) notify_invalid_choice; continue ;;
    esac

    while true; do
      render_section_header "${region_label} · 选择内存档位"

      detected_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
      if [ -n "$detected_mem_kb" ] && [ "$detected_mem_kb" -gt 0 ]; then
        detected_mem_gb=$(awk -v kb="$detected_mem_kb" 'BEGIN { printf "%.1f", kb / 1024 / 1024 }')
        echo -e "  ${D}当前检测到内存: ${detected_mem_gb} GB（仅供参考，请按实际选择）${N}"
        echo ""
      fi

      render_menu_item 1 "512 MB   ${D}缓冲上限 $(_buffer_label_for "$region" 512m)${N}"
      render_menu_item 2 "1 GB     ${D}缓冲上限 $(_buffer_label_for "$region" 1g)${N}"
      render_menu_item 3 "2 GB     ${D}缓冲上限 $(_buffer_label_for "$region" 2g)${N}"
      render_menu_item 4 "4 GB     ${D}缓冲上限 $(_buffer_label_for "$region" 4g)${N}"
      render_menu_item 5 "8 GB+    ${D}缓冲上限 $(_buffer_label_for "$region" 8g)${N}"
      render_menu_item 0 "返回选择地区"
      render_divider
      read -p "  请选择内存档位: " mem_choice

      case "$mem_choice" in
        1) mem_tier="512m" ;;
        2) mem_tier="1g" ;;
        3) mem_tier="2g" ;;
        4) mem_tier="4g" ;;
        5) mem_tier="8g" ;;
        0) break ;;
        *) notify_invalid_choice; continue ;;
      esac

      apply_quic_optimization "$region" "$mem_tier"
      return
    done
  done
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

  local tcp_profile_text="未配置"
  local tcp_rmem_max
  tcp_rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "")
  if [ -f "$TCP_TUNING_PATH" ]; then
    tcp_config_status="已存在"
    local profile_line region mem_tier region_label="" mem_label=""
    profile_line=$(awk '/^# leyili-profile:/ { print; exit }' "$TCP_TUNING_PATH" 2>/dev/null)
    if [ -n "$profile_line" ]; then
      region=$(printf '%s\n' "$profile_line" | sed -n 's/.*region=\([a-z-]\+\).*/\1/p')
      mem_tier=$(printf '%s\n' "$profile_line" | sed -n 's/.*mem_tier=\([a-z0-9]\+\).*/\1/p')
      case "$region" in
        hk)      region_label="香港" ;;
        jp)      region_label="日本" ;;
        us-west) region_label="美西" ;;
        eu)      region_label="欧洲" ;;
      esac
      case "$mem_tier" in
        512m) mem_label="512MB" ;;
        1g) mem_label="1GB"  ;;
        2g) mem_label="2GB"  ;;
        4g) mem_label="4GB"  ;;
        8g) mem_label="8GB+" ;;
      esac
      if [ -n "$region_label" ] && [ -n "$mem_label" ]; then
        tcp_profile_text="${region_label} / ${mem_label}"
      fi
    fi
  else
    tcp_config_status="未写入"
  fi

  echo -e "  ${B}TCP 参数状态${N}"
  echo -e "  配置文件  : ${C}$tcp_config_status${N} (${TCP_TUNING_PATH})"
  echo -e "  配置档位  : ${C}$tcp_profile_text${N}"
  if [ -n "$tcp_rmem_max" ] && [ "$tcp_rmem_max" -gt 0 ] 2>/dev/null; then
    echo -e "  rmem_max  : ${C}$((tcp_rmem_max / 1024 / 1024))M${N}"
  fi
  echo -e "  qdisc     : ${C}$tcp_qdisc${N}"
  echo -e "  BBR       : ${C}$tcp_cc${N}"
  echo -e "  Fast Open : ${C}$tcp_fastopen${N}"
  echo -e "  notsent   : ${C}$tcp_notsent${N}"
  echo -e "  fin_timeout : ${C}$tcp_fin_timeout${N}"
  echo -e "  keepalive : ${C}$tcp_keepalive${N}"
  echo ""

  local quic_config_status quic_profile_text="未配置"
  local quic_rmem_max quic_wmem_max
  local conntrack_max conntrack_count
  if [ -f "$QUIC_TUNING_PATH" ]; then
    quic_config_status="已存在"
    local quic_profile_line region mem_tier region_label="" mem_label=""
    quic_profile_line=$(awk '/^# leyili-quic-profile:/ { print; exit }' "$QUIC_TUNING_PATH" 2>/dev/null)
    if [ -n "$quic_profile_line" ]; then
      region=$(printf '%s\n' "$quic_profile_line" | sed -n 's/.*region=\([a-z-]\+\).*/\1/p')
      mem_tier=$(printf '%s\n' "$quic_profile_line" | sed -n 's/.*mem_tier=\([a-z0-9]\+\).*/\1/p')
      case "$region" in
        hk)      region_label="香港" ;;
        jp)      region_label="日本" ;;
        us-west) region_label="美西" ;;
        eu)      region_label="欧洲" ;;
      esac
      case "$mem_tier" in
        512m) mem_label="512MB" ;;
        1g) mem_label="1GB"  ;;
        2g) mem_label="2GB"  ;;
        4g) mem_label="4GB"  ;;
        8g) mem_label="8GB+" ;;
      esac
      if [ -n "$region_label" ] && [ -n "$mem_label" ]; then
        quic_profile_text="${region_label} / ${mem_label}"
      fi
    fi
  else
    quic_config_status="未写入"
  fi

  quic_rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "")
  quic_wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "")

  echo -e "  ${B}QUIC/UDP 参数状态${N}"
  echo -e "  配置文件  : ${C}$quic_config_status${N} (${QUIC_TUNING_PATH})"
  echo -e "  配置档位  : ${C}$quic_profile_text${N}"
  if [ -n "$quic_rmem_max" ] && [ "$quic_rmem_max" -gt 0 ] 2>/dev/null; then
    echo -e "  rmem_max  : ${C}$((quic_rmem_max / 1024 / 1024))M${N}"
  fi
  if [ -n "$quic_wmem_max" ] && [ "$quic_wmem_max" -gt 0 ] 2>/dev/null; then
    echo -e "  wmem_max  : ${C}$((quic_wmem_max / 1024 / 1024))M${N}"
  fi
  if [ -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
    conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "?")
    conntrack_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "?")
    echo -e "  conntrack : ${C}${conntrack_count}${N} / ${C}${conntrack_max}${N}"
  fi
  pause_screen
}

configure_swap(){
  local swap_size_mb="${1:-2048}"
  local size_label="${2:-${swap_size_mb} MB}"
  local swap_active="false"

  if ! require_root; then return 1; fi

  echo ""
  echo -e "  ${B}${C}当前内存 / SWAP 状态${N}"
  free -h
  echo ""

  if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAPFILE_PATH"; then
    swap_active="true"
  fi

  if [ "$swap_active" = "true" ]; then
    echo -e "${Y}==> 检测到 ${SWAPFILE_PATH} 已启用，跳过创建${N}"
    echo -e "${D}    如需更换大小，请先在 shell 执行：swapoff ${SWAPFILE_PATH} && rm -f ${SWAPFILE_PATH}${N}"
  else
    if [ -f "$SWAPFILE_PATH" ]; then
      echo -e "${Y}==> 检测到已有 ${SWAPFILE_PATH}，继续复用（不重建）${N}"
      echo -e "${D}    如需更换大小，请先 rm -f ${SWAPFILE_PATH} 后重新运行此项${N}"
    else
      echo -e "${Y}==> 创建 ${size_label} SWAP 文件...${N}"
      if ! fallocate -l "${swap_size_mb}M" "$SWAPFILE_PATH"; then
        echo -e "${Y}==> fallocate 失败（可能文件系统不支持，如 tmpfs/zfs），改用 dd 创建...${N}"
        dd if=/dev/zero of="$SWAPFILE_PATH" bs=1M count="$swap_size_mb" status=progress || {
          echo -e "${R}SWAP 文件创建失败${N}"
          rm -f "$SWAPFILE_PATH"
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

# SWAP 档位选择器：根据用户内存档位推荐 SWAP 大小
show_swap_picker(){
  local detected_mem_kb detected_mem_mb detected_mem_label
  local suggested=2 swap_size_mb=0 size_label="" choice
  local existing_size_mb=""

  if ! require_root; then return 1; fi

  detected_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
  if [ -n "$detected_mem_kb" ] && [ "$detected_mem_kb" -gt 0 ]; then
    detected_mem_mb=$((detected_mem_kb / 1024))
    if   [ "$detected_mem_mb" -lt 768 ];  then suggested=1; detected_mem_label="${detected_mem_mb} MB ${D}(≤ 512 MB 档)${N}"
    elif [ "$detected_mem_mb" -lt 1500 ]; then suggested=2; detected_mem_label="${detected_mem_mb} MB ${D}(1 GB 档)${N}"
    else                                       suggested=3; detected_mem_label="${detected_mem_mb} MB ${D}(≥ 2 GB 档)${N}"
    fi
  else
    detected_mem_label="未知"
  fi

  render_section_header "添加 SWAP"
  echo -e "  ${B}当前检测到内存${N} : ${C}${detected_mem_label}${N}"
  echo ""
  free -h
  echo ""

  if [ -f "$SWAPFILE_PATH" ]; then
    existing_size_mb=$(stat -c%s "$SWAPFILE_PATH" 2>/dev/null)
    if [ -n "$existing_size_mb" ] && [ "$existing_size_mb" -gt 0 ] 2>/dev/null; then
      existing_size_mb=$((existing_size_mb / 1024 / 1024))
      echo -e "  ${Y}⚠ 检测到已存在 ${SWAPFILE_PATH}（约 ${existing_size_mb} MB），后续步骤会复用、不重建${N}"
      echo -e "  ${D}  如需更换大小：先 ${C}swapoff ${SWAPFILE_PATH} && rm -f ${SWAPFILE_PATH}${D}，再回此菜单${N}"
      echo ""
    fi
  fi

  echo -e "  ${B}选择内存档位（脚本按档位推荐 SWAP 大小）：${N}"
  render_menu_item 1 "≤ 512 MB    ${D}→ SWAP 1 GB    (小机器跑 apt/编译必需)${N}"
  render_menu_item 2 "1 GB        ${D}→ SWAP 2 GB    (主流入门套餐推荐)${N}"
  render_menu_item 3 "≥ 2 GB      ${D}→ SWAP 2 GB    (跑代理/转发足够)${N}"
  render_menu_item 4 "自定义大小（MB）"
  render_menu_item 0 "返回"
  render_divider
  read -p "  请选择 (默认 ${suggested}): " choice
  choice="${choice:-$suggested}"

  case "$choice" in
    1) swap_size_mb=1024; size_label="1 GB" ;;
    2) swap_size_mb=2048; size_label="2 GB" ;;
    3) swap_size_mb=2048; size_label="2 GB" ;;
    4)
      while true; do
        read -p "  自定义大小（MB，512-8192）: " swap_size_mb
        case "$swap_size_mb" in
          ''|*[!0-9]*)
            echo -e "${R}必须为正整数${N}"
            continue
            ;;
        esac
        if [ "$swap_size_mb" -lt 512 ] || [ "$swap_size_mb" -gt 8192 ]; then
          echo -e "${R}范围必须在 512-8192 MB 之间${N}"
          continue
        fi
        if [ "$swap_size_mb" -ge 1024 ] && [ $((swap_size_mb % 1024)) -eq 0 ]; then
          size_label="$((swap_size_mb / 1024)) GB"
        else
          size_label="${swap_size_mb} MB"
        fi
        break
      done
      ;;
    0) return 0 ;;
    *) notify_invalid_choice; return 0 ;;
  esac

  configure_swap "$swap_size_mb" "$size_label"
}

remove_swap(){
  local confirm=""
  local tmp_file=""

  if ! require_root; then
    return 1
  fi

  if [ ! -f "$SWAPFILE_PATH" ] && [ ! -f "$SWAP_SYSCTL_PATH" ] \
     && ! grep -Eq "^[[:space:]]*${SWAPFILE_PATH}[[:space:]]" /etc/fstab 2>/dev/null; then
    echo ""
    echo -e "${Y}未检测到脚本创建的 SWAP，无需移除${N}"
    pause_screen
    return 0
  fi

  echo ""
  echo -e "${Y}==> 即将关闭并删除 ${C}$SWAPFILE_PATH${N}${Y}，并移除 swappiness 配置${N}"
  read -p "  确认继续？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAPFILE_PATH"; then
    echo -e "${Y}==> 关闭 SWAP...${N}"
    if ! swapoff "$SWAPFILE_PATH"; then
      echo -e "${R}关闭 SWAP 失败，可能存在占用${N}"
      pause_screen
      return 1
    fi
  fi

  if [ -f "$SWAPFILE_PATH" ]; then
    rm -f "$SWAPFILE_PATH"
  fi

  if grep -Eq "^[[:space:]]*${SWAPFILE_PATH}[[:space:]]" /etc/fstab 2>/dev/null; then
    tmp_file=$(mktemp)
    awk -v p="$SWAPFILE_PATH" '$1 != p {print}' /etc/fstab > "$tmp_file" && mv "$tmp_file" /etc/fstab
  fi

  if [ -f "$SWAP_SYSCTL_PATH" ]; then
    rm -f "$SWAP_SYSCTL_PATH"
    sysctl --system >/dev/null 2>&1 || true
  fi

  echo ""
  echo -e "${G}SWAP 已移除${N}"
  free -h
  pause_screen
}

# ─── 脚本自更新 / 配置管理 ────────────────────────────
