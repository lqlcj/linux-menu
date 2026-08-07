# TCP 调优唯一入口是智能调参向导（实测 RTT × 带宽算 BDP），buffer_max 由向导
# 计算后传入。固定地区档（hk/jp/us-west/us-west-100m/eu × 内存档查表）已随
# 菜单一并移除；各内存档封顶值保留在 _tcp_autotune_ceiling（= 历史档位最大值），
# 老机器上 region=hk 等存量 marker 仅在状态页 / 首页卡片保留展示映射。
capture_live_qdisc(){
  local state_file="$1" iface qdisc
  [ -e "$state_file" ] && return 0
  command -v tc >/dev/null 2>&1 || return 0
  iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
  [ -n "$iface" ] || return 0
  qdisc=$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1 {print $2; exit}')
  [ -n "$qdisc" ] || return 0
  ensure_leyili_state_dir || return 1
  printf 'iface=%s\nqdisc=%s\n' "$iface" "$qdisc" > "$state_file" || return 1
  chmod 600 "$state_file" 2>/dev/null || { rm -f -- "$state_file"; return 1; }
}

restore_live_qdisc(){
  local state_file="$1" remove_after="${2:-0}" iface qdisc rc=0
  [ -r "$state_file" ] || return 0
  iface=$(awk -F= '$1 == "iface" {print $2; exit}' "$state_file")
  qdisc=$(awk -F= '$1 == "qdisc" {print $2; exit}' "$state_file")
  if [ -n "$iface" ] && [ -n "$qdisc" ] && command -v tc >/dev/null 2>&1; then
    tc qdisc replace dev "$iface" root "$qdisc" >/dev/null 2>&1 || rc=1
  elif [ -n "$iface" ] && [ -n "$qdisc" ]; then
    rc=1
  fi
  if [ "$remove_after" = "1" ] && [ "$rc" -eq 0 ]; then
    rm -f -- "$state_file" || rc=1
  fi
  [ "$rc" -eq 0 ] || echo -e "${R}qdisc 恢复失败，状态快照已保留：${state_file}${N}" >&2
  return "$rc"
}

tcp_tuning_abort(){
  local file_txn="$1" runtime_state="$2" runtime_qdisc="$3"
  local tcp_state_created="${4:-0}" qdisc_state_created="${5:-0}" rc=0

  [ -n "$runtime_state" ] && sysctl_state_restore "$runtime_state" || {
    [ -z "$runtime_state" ] || rc=1
  }
  [ -n "$runtime_qdisc" ] && restore_live_qdisc "$runtime_qdisc" 1 || {
    [ -z "$runtime_qdisc" ] || rc=1
  }
  managed_file_transaction_rollback "$TCP_TUNING_PATH" "$file_txn" || rc=1
  if [ "$rc" -eq 0 ]; then
    [ "$tcp_state_created" -eq 0 ] || rm -f -- "$TCP_TUNING_STATE" || rc=1
    [ "$qdisc_state_created" -eq 0 ] || rm -f -- "$TCP_QDISC_STATE" || rc=1
    rm -f -- "$runtime_state" "$runtime_qdisc" 2>/dev/null || rc=1
  fi
  [ "$rc" -eq 0 ] || echo -e "${R}TCP 调优回滚未完全成功，运行时/事务快照已尽量保留${N}" >&2
  return "$rc"
}

apply_tcp_tuning(){
  local mem_tier="${1:-2g}"
  local buffer_max="${2:-}"   # 按实测 BDP 算出的 buffer_max（字节）
  local rtt_ms="${3:-}"       # 实测 RTT（ms，决定 fin_timeout 分档并写入 marker）
  local bw_mbps="${4:-}"      # 有效带宽（Mbps，写入 marker 供状态页展示）
  local notsent_lowat fin_timeout mem_label
  local cc_algo qdisc_algo iface _q file_txn tmp_tuning runtime_state="" runtime_qdisc=""
  local tcp_state_created=0 qdisc_state_created=0

  if ! require_root; then return 1; fi

  notsent_lowat=16384
  # fin_timeout 按实测 RTT 分档：近程（≤150ms，原 hk/jp 档）5s，远程 10s
  fin_timeout=10
  # rtt/bw 只用于 fin_timeout 分档与 marker 展示：非法或超长值置空（marker
  # 不写），合法值强制十进制（"090" 这类前导零会被 $((...)) 按八进制解析）
  case "$rtt_ms" in
    ''|*[!0-9]*|???????*) rtt_ms="" ;;
    *)
      rtt_ms=$((10#$rtt_ms))
      [ "$rtt_ms" -le 150 ] && fin_timeout=5
      ;;
  esac
  case "$bw_mbps" in
    ''|*[!0-9]*|???????*) bw_mbps="" ;;
    *) bw_mbps=$((10#$bw_mbps)) ;;
  esac

  # buffer_max 防御性复检：保证该函数被直接调用时也不会把离谱值写进 sysctl
  #（范围 = 历史固定档位的上下限）。先卡长度（>10 位十进制必然越界，也防 10#
  # 归一化时溢出），再强制十进制归一化（前导零会被 $((...)) 与内核 sysctl
  # 解析双双当成八进制），最后卡范围
  case "$buffer_max" in
    ''|*[!0-9]*)
      echo -e "${R}缺少合法的 buffer_max 参数${N}"
      return 1
      ;;
  esac
  if [ "${#buffer_max}" -gt 10 ]; then
    echo -e "${R}buffer_max 超出安全范围 (4M-64M): ${buffer_max}${N}"
    return 1
  fi
  buffer_max=$((10#$buffer_max))
  if [ "$buffer_max" -lt 4194304 ] || [ "$buffer_max" -gt 67108864 ]; then
    echo -e "${R}buffer_max 超出安全范围 (4M-64M): ${buffer_max}${N}"
    return 1
  fi

  case "$mem_tier" in
    512m) mem_label="512MB" ;;
    1g)  mem_label="1GB"  ;;
    2g)  mem_label="2GB"  ;;
    4g)  mem_label="4GB"  ;;
    8g)  mem_label="8GB+" ;;
    *)   mem_label="$mem_tier" ;;
  esac

  file_txn=$(managed_file_transaction_begin "$TCP_TUNING_PATH" 'Managed by Leyili|leyili-profile') || {
    echo -e "${R}无法安全接管 ${TCP_TUNING_PATH}${N}"
    return 1
  }
  runtime_state=$(mktemp "${TMPDIR:-/tmp}/leyili-tcp-runtime.XXXXXX") || {
    managed_file_transaction_rollback "$TCP_TUNING_PATH" "$file_txn" || :
    return 1
  }
  rm -f -- "$runtime_state"
  runtime_qdisc=$(mktemp "${TMPDIR:-/tmp}/leyili-qdisc-runtime.XXXXXX") || {
    tcp_tuning_abort "$file_txn" "$runtime_state" "" 0 0 || :
    return 1
  }
  rm -f -- "$runtime_qdisc"
  sysctl_state_capture "$runtime_state" \
    net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.tcp_fastopen \
    net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default \
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_adv_win_scale \
    net.ipv4.tcp_notsent_lowat net.ipv4.tcp_slow_start_after_idle \
    net.ipv4.tcp_window_scaling net.ipv4.tcp_timestamps net.ipv4.tcp_sack \
    net.ipv4.tcp_mtu_probing net.ipv4.ip_no_pmtu_disc net.ipv4.tcp_tw_reuse \
    net.ipv4.tcp_fin_timeout net.ipv4.tcp_max_tw_buckets net.core.somaxconn \
    net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_syncookies \
    net.ipv4.tcp_max_orphans net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl \
    net.ipv4.tcp_keepalive_probes net.ipv4.tcp_no_metrics_save net.ipv4.tcp_ecn \
    net.ipv4.tcp_rfc1337 net.ipv4.tcp_retries2 net.ipv4.tcp_synack_retries \
    net.ipv4.tcp_orphan_retries net.ipv4.ip_local_port_range || {
      tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" 0 0 || :
      return 1
    }
  if [ ! -f "$TCP_TUNING_STATE" ]; then
    cp -a -- "$runtime_state" "$TCP_TUNING_STATE" || {
      managed_file_transaction_rollback "$TCP_TUNING_PATH" "$file_txn"
      rm -f -- "$runtime_state" "$runtime_qdisc"
      return 1
    }
    tcp_state_created=1
  fi
  if ! capture_live_qdisc "$runtime_qdisc"; then
    tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" \
      "$tcp_state_created" 0 || :
    echo -e "${R}qdisc 运行时快照失败，已中止 TCP 调优${N}" >&2
    return 1
  fi
  if [ ! -f "$TCP_QDISC_STATE" ]; then
    if ! capture_live_qdisc "$TCP_QDISC_STATE"; then
      tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" \
        "$tcp_state_created" 0 || :
      echo -e "${R}qdisc 持久快照失败，已中止 TCP 调优${N}" >&2
      return 1
    fi
    [ -f "$TCP_QDISC_STATE" ] && qdisc_state_created=1
  fi
  if [ ! -r "$runtime_state" ]; then
    tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" \
      "$tcp_state_created" "$qdisc_state_created" || :
    echo -e "${R}qdisc 状态快照失败，已中止 TCP 调优${N}" >&2
    return 1
  fi

  # --- 拥塞控制探测：BBR 不是所有内核都编译进去（精简内核 / 老 OpenVZ）---
  # 写死 bbr 会让 sysctl -p 在那一行静默报错后回落 cubic，用户以为开了 BBR。
  # 先尝试加载模块，再查 tcp_available_congestion_control，不可用时明确降级并告警。
  cc_algo="bbr"
  modprobe tcp_bbr >/dev/null 2>&1 || true
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    cc_algo="cubic"
    echo -e "${Y}==> 当前内核不支持 BBR，拥塞算法降级为 cubic${N}"
    echo -e "${D}    （精简内核 / 老 OpenVZ 常见；如需 BBR 请更换支持的内核后重跑）${N}"
  fi

  # --- qdisc 选择：fq 配合 BBR 的 pacing 效果最好，但同样可能未编译 ---
  # 用 sysctl -w 依次探测 fq → fq_codel（写成功即代表内核支持该 qdisc；
  # 这步顺带把全局 default_qdisc 设成选中值，与稍后写入配置文件的值一致）。
  # 两者都不支持时留空，不写该行、保持内核默认。
  qdisc_algo=""
  modprobe sch_fq >/dev/null 2>&1 || true
  for _q in fq fq_codel; do
    if sysctl -w "net.core.default_qdisc=${_q}" >/dev/null 2>&1; then
      qdisc_algo="$_q"
      break
    fi
  done

  echo ""
  echo -e "${Y}==> 写入 智能调参/${mem_label} TCP 参数优化配置 (上限 $((buffer_max/1024/1024))M)...${N}"

  tmp_tuning=$(mktemp "${TCP_TUNING_PATH}.tmp.XXXXXX") || {
    tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" \
      "$tcp_state_created" "$qdisc_state_created" || :
    return 1
  }
  if ! cat > "$tmp_tuning" <<EOF
# Managed by Leyili
# leyili-profile: region=custom mem_tier=${mem_tier}${rtt_ms:+ rtt=${rtt_ms}}${bw_mbps:+ bw=${bw_mbps}}
# 由 leyili.sh 智能 TCP 调参生成 (自动实测 / ${mem_label})
# 偏好：交互流（网页 / 社交 / 流媒体），非吞吐党

# --- 拥塞控制 + 调度 ---
${qdisc_algo:+net.core.default_qdisc = ${qdisc_algo}}
net.ipv4.tcp_congestion_control = ${cc_algo}
# TFO = 1 仅客户端方向；服务端在国内出口常被运营商干扰 cookie，
# 首包失败比首包提前 1RTT 更常见，因此服务端关闭
# 注意：本机 sing-box 入站也不要开 tcp_fast_open（服务端 accept 方向需 bit2，
# 即此值需为 3 才生效）；两侧保持一致，避免节点开了 TFO 但内核未支撑的空配
net.ipv4.tcp_fastopen = 1

# --- 缓冲区 (按地区 BDP 与内存档计算) ---
# default 提到 512K：小连接也能直接进入有效拥塞窗口，不用等慢启动 grow
net.core.rmem_max = ${buffer_max}
net.core.wmem_max = ${buffer_max}
net.core.rmem_default = 524288
net.core.wmem_default = 524288
net.ipv4.tcp_rmem = 16384 524288 ${buffer_max}
net.ipv4.tcp_wmem = 16384 524288 ${buffer_max}
# adv_win_scale=2：内核按 space-(space>>2) 把约 3/4 划给接收窗口、1/4 留应用层
# overhead（默认 1 是各半）。跨境高 BDP 下更大的接收窗口利于吃满带宽。
# 注：6.x 内核逐步弱化此旋钮，长期留意
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
  then
    rm -f -- "$tmp_tuning"
    tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" \
      "$tcp_state_created" "$qdisc_state_created" || :
    return 1
  fi

  if ! chmod 600 "$tmp_tuning" 2>/dev/null \
     || ! mv -f -- "$tmp_tuning" "$TCP_TUNING_PATH"; then
    rm -f -- "$tmp_tuning"
    tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" \
      "$tcp_state_created" "$qdisc_state_created" || :
    return 1
  fi

  echo -e "${Y}==> 应用 sysctl 配置...${N}"
  if ! sysctl -p "$TCP_TUNING_PATH"; then
    echo -e "${R}TCP 参数应用失败，请检查内核兼容性或 sysctl 输出${N}"
    tcp_tuning_abort "$file_txn" "$runtime_state" "$runtime_qdisc" \
      "$tcp_state_created" "$qdisc_state_created" || :
    return 1
  fi

  # default_qdisc 只在「网卡注册时」读取；系统启动时 eth0 早已建好，
  # 改这个值不会动现有网卡。这里对当前默认网卡手动 replace，让 fq 本次即生效
  # （否则要等重启，用户跑完却仍是 pfifo_fast）。BBR 自带 pacing，缺 fq 不致命，
  # 故 tc 失败只警告不算整体失败。
  if [ -n "$qdisc_algo" ] && command -v tc >/dev/null 2>&1; then
    iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    if [ -n "$iface" ]; then
      if tc qdisc replace dev "$iface" root "$qdisc_algo" >/dev/null 2>&1; then
        echo -e "${D}    已对 ${iface} 应用 ${qdisc_algo} qdisc（本次生效）${N}"
      else
        echo -e "${Y}    对 ${iface} 应用 ${qdisc_algo} qdisc 失败，重启后由 default_qdisc 生效${N}"
      fi
    fi
  fi

  rm -f -- "$runtime_state" "$runtime_qdisc"
  managed_file_transaction_commit "$file_txn"

  return 0
}

remove_tcp_tuning(){
  local confirm="" rc=0

  if ! require_root; then
    return 1
  fi

  if [ ! -f "$TCP_TUNING_PATH" ]; then
    echo ""
    echo -e "${Y}未检测到 TCP 优化配置，无需移除${N}"
    pause_screen
    return 0
  fi
  if ! grep -Eq 'Managed by Leyili|leyili-profile' "$TCP_TUNING_PATH" 2>/dev/null \
     && [ ! -e "${TCP_TUNING_PATH}.leyili-original" ] \
     && [ ! -f "$TCP_TUNING_STATE" ]; then
    echo -e "${R}${TCP_TUNING_PATH} 不是脚本托管文件，拒绝删除。${N}"
    pause_screen
    return 1
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

  managed_file_restore "$TCP_TUNING_PATH" || rc=1
  sysctl --system >/dev/null 2>&1 || rc=1
  sysctl_state_restore "$TCP_TUNING_STATE" || rc=1
  restore_live_qdisc "$TCP_QDISC_STATE" 1 || rc=1
  remove_initcwnd_managed 1 || rc=1

  echo ""
  if [ "$rc" -eq 0 ]; then
    echo -e "${G}TCP 优化已移除（部分参数重启后完全复位）${N}"
  else
    echo -e "${R}TCP 优化移除未完全成功，相关状态快照已尽量保留，请检查上方警告${N}"
  fi
  pause_screen
  return "$rc"
}

quic_tuning_abort(){
  local file_txn="$1" runtime_state="$2" state_created="${3:-0}" rc=0
  [ -n "$runtime_state" ] && sysctl_state_restore "$runtime_state" || {
    [ -z "$runtime_state" ] || rc=1
  }
  managed_file_transaction_rollback "$QUIC_TUNING_PATH" "$file_txn" || rc=1
  if [ "$rc" -eq 0 ]; then
    [ "$state_created" -eq 0 ] || rm -f -- "$QUIC_TUNING_STATE" || rc=1
    [ -z "$runtime_state" ] || rm -f -- "$runtime_state" 2>/dev/null || rc=1
  fi
  [ "$rc" -eq 0 ] || echo -e "${R}QUIC 调优回滚未完全成功，运行时/事务快照已尽量保留${N}" >&2
  return "$rc"
}

apply_quic_tuning(){
  local region="${1:-us-west}"
  local mem_tier="${2:-2g}"
  local region_label mem_label conntrack_max file_txn tmp_quic runtime_state=""
  local quic_state_created=0

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

  case "$mem_tier" in
    512m) mem_label="512MB"; conntrack_max=65536 ;;
    1g)  mem_label="1GB";   conntrack_max=65536 ;;
    2g)  mem_label="2GB";   conntrack_max=131072 ;;
    4g)  mem_label="4GB";   conntrack_max=262144 ;;
    8g)  mem_label="8GB+";  conntrack_max=524288 ;;
    *)   mem_label="$mem_tier"; conntrack_max=131072 ;;
  esac

  file_txn=$(managed_file_transaction_begin "$QUIC_TUNING_PATH" 'Managed by Leyili|leyili-quic-profile') || return 1
  runtime_state=$(mktemp "${TMPDIR:-/tmp}/leyili-quic-runtime.XXXXXX") || {
    managed_file_transaction_rollback "$QUIC_TUNING_PATH" "$file_txn" || :
    return 1
  }
  rm -f -- "$runtime_state"
  sysctl_state_capture "$runtime_state" \
    net.netfilter.nf_conntrack_max \
    net.netfilter.nf_conntrack_udp_timeout \
    net.netfilter.nf_conntrack_udp_timeout_stream || {
      quic_tuning_abort "$file_txn" "$runtime_state" 0 || :
      return 1
    }
  if [ ! -f "$QUIC_TUNING_STATE" ]; then
    cp -a -- "$runtime_state" "$QUIC_TUNING_STATE" || {
      managed_file_transaction_rollback "$QUIC_TUNING_PATH" "$file_txn"
      rm -f -- "$runtime_state"
      return 1
    }
    quic_state_created=1
  fi

  echo ""
  echo -e "${Y}==> 写入 ${region_label}/${mem_label} QUIC/UDP 参数优化配置 (仅 conntrack)...${N}"

  tmp_quic=$(mktemp "${QUIC_TUNING_PATH}.tmp.XXXXXX") || {
    quic_tuning_abort "$file_txn" "$runtime_state" "$quic_state_created" || :
    return 1
  }
  if ! cat > "$tmp_quic" <<EOF
# Managed by Leyili
# leyili-quic-profile: region=${region} mem_tier=${mem_tier}
# 由 leyili.sh QUIC/UDP 协议优化生成 (${region_label} / ${mem_label})
# 用户偏好：Reality TCP 主用、UDP 仅备用 → 本文件不写 net.core.* 通用键，
# 避免字典序在后覆盖 TCP 调优。QUIC/UDP socket 缓冲沿用 99-proxy-optimized
# 设置的 net.core.rmem_max / wmem_max；如出现 sing-box "failed to sufficiently
# increase receive buffer size" 警告，再考虑单独提升 TCP 那份的 rmem_max。
# 不跑 TUIC / Hysteria2 时无需此文件，可在菜单 "移除 QUIC 调优" 删除

# --- conntrack（按内存档限制，避免小内存机器被固定 1M 条目拖垮）---
# 容器/LXC 内可能写不进去，sysctl -p 失败时由上层提示
net.netfilter.nf_conntrack_max = ${conntrack_max}
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
EOF
  then
    rm -f -- "$tmp_quic"
    quic_tuning_abort "$file_txn" "$runtime_state" "$quic_state_created" || :
    return 1
  fi

  if ! chmod 600 "$tmp_quic" 2>/dev/null \
     || ! mv -f -- "$tmp_quic" "$QUIC_TUNING_PATH"; then
    rm -f -- "$tmp_quic"
    quic_tuning_abort "$file_txn" "$runtime_state" "$quic_state_created" || :
    return 1
  fi

  echo -e "${Y}==> 应用 sysctl 配置...${N}"
  if ! sysctl -p "$QUIC_TUNING_PATH" 2>/dev/null; then
    echo -e "${R}conntrack 参数未能完整应用，已恢复应用前状态${N}"
    quic_tuning_abort "$file_txn" "$runtime_state" "$quic_state_created" || :
    return 1
  fi

  rm -f -- "$runtime_state"
  managed_file_transaction_commit "$file_txn"

  return 0
}

remove_quic_tuning(){
  local confirm="" rc=0

  if ! require_root; then
    return 1
  fi

  if [ ! -f "$QUIC_TUNING_PATH" ]; then
    echo ""
    echo -e "${Y}未检测到 QUIC 优化配置，无需移除${N}"
    pause_screen
    return 0
  fi
  if ! grep -Eq 'Managed by Leyili|leyili-quic-profile' "$QUIC_TUNING_PATH" 2>/dev/null \
     && [ ! -e "${QUIC_TUNING_PATH}.leyili-original" ] \
     && [ ! -f "$QUIC_TUNING_STATE" ]; then
    echo -e "${R}${QUIC_TUNING_PATH} 不是脚本托管文件，拒绝删除。${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${Y}==> 即将移除 ${C}$QUIC_TUNING_PATH${N}${Y}，并通过 sysctl --system 复位参数${N}"
  read -p "  确认继续？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  managed_file_restore "$QUIC_TUNING_PATH" || rc=1
  sysctl --system >/dev/null 2>&1 || rc=1
  sysctl_state_restore "$QUIC_TUNING_STATE" || rc=1

  echo ""
  if [ "$rc" -eq 0 ]; then
    echo -e "${G}QUIC 优化已移除（UDP 缓冲区将回落至 99-proxy-optimized.conf 或内核默认值）${N}"
  else
    echo -e "${R}QUIC 优化移除未完全成功，状态快照已尽量保留，请检查上方警告${N}"
  fi
  pause_screen
  return "$rc"
}

apply_quic_optimization(){
  local region="$1"
  local mem_tier="$2"
  local region_label mem_label

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

  echo ""
  echo -e "${G}✓ QUIC/UDP 协议优化完成${N}"
  echo -e "  地区        : ${C}$region_label${N}"
  echo -e "  内存档位    : ${C}$mem_label${N}"
  echo -e "  说明        : ${C}仅写 conntrack，net.core.* 沿用 TCP 调优${N}"
  echo -e "  配置文件    : ${C}$QUIC_TUNING_PATH${N}"
  echo ""
  echo -e "  ${D}提示：调优生效后建议重启 sing-box 让 TUIC/HY2 重新分配缓冲区${N}"
  echo -e "  ${D}      systemctl restart sing-box${N}"
  pause_screen
}

initcwnd_apply_rollback(){
  local route_line="$1" service_name="$2" helper_txn="$3" service_txn="$4"
  local was_enabled="$5" was_active="$6" state_created="$7" stop_service="${8:-0}"
  local rc=0

  if [ "$stop_service" = "1" ] \
     && { systemctl is-active --quiet "$service_name" 2>/dev/null \
          || systemctl is-enabled --quiet "$service_name" 2>/dev/null; }; then
    systemctl disable --now "$service_name" >/dev/null 2>&1 || rc=1
  fi
  if [ -n "$route_line" ]; then
    # shellcheck disable=SC2086
    ip route replace $route_line >/dev/null 2>&1 || rc=1
  fi
  managed_file_transaction_rollback "$INITCWND_HELPER_PATH" "$helper_txn" || rc=1
  managed_file_transaction_rollback "$INITCWND_SERVICE_PATH" "$service_txn" || rc=1
  if [ "$stop_service" = "1" ]; then
    systemctl daemon-reload >/dev/null 2>&1 || rc=1
    if [ "$was_enabled" -eq 1 ]; then systemctl enable "$service_name" >/dev/null 2>&1 || rc=1; fi
    if [ "$was_active" -eq 1 ]; then systemctl start "$service_name" >/dev/null 2>&1 || rc=1; fi
  fi
  if [ "$state_created" -eq 1 ] && [ "$rc" -eq 0 ]; then
    rm -f -- "$INITCWND_STATE_PATH" || rc=1
  fi
  [ "$rc" -eq 0 ] || echo -e "${R}initcwnd 回滚未完全成功，状态文件/事务快照已保留，请立即检查路由与服务${N}" >&2
  return "$rc"
}

apply_initcwnd_optimization(){
  local route_line route_spec current_route service_name
  local initcwnd_value="${1:-$INITCWND_VALUE}"
  local quiet="${2:-0}"
  local service_txn helper_txn tmp_service tmp_helper
  local was_active=0 was_enabled=0 state_created=0

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

  case "$initcwnd_value" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$initcwnd_value" -lt 2 ] || [ "$initcwnd_value" -gt 128 ]; then
    echo -e "${R}initcwnd 必须在 2-128 之间${N}"
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
  service_name=$(basename "$INITCWND_SERVICE_PATH")
  systemctl is-active --quiet "$service_name" 2>/dev/null && was_active=1
  systemctl is-enabled --quiet "$service_name" 2>/dev/null && was_enabled=1

  ensure_leyili_state_dir || return 1
  if [ ! -f "$INITCWND_STATE_PATH" ]; then
    {
      printf 'original_active=%s\n' "$was_active"
      printf 'original_enabled=%s\n' "$was_enabled"
    } > "$INITCWND_STATE_PATH" || return 1
    chmod 600 "$INITCWND_STATE_PATH" 2>/dev/null \
      || { rm -f -- "$INITCWND_STATE_PATH"; return 1; }
    state_created=1
  fi

  service_txn=$(managed_file_transaction_begin "$INITCWND_SERVICE_PATH" 'Managed by Leyili|Description=Set TCP initcwnd/initrwnd') || return 1
  helper_txn=$(managed_file_transaction_begin "$INITCWND_HELPER_PATH" 'Managed by Leyili') || {
    if managed_file_transaction_rollback "$INITCWND_SERVICE_PATH" "$service_txn"; then
      [ "$state_created" -eq 1 ] && rm -f -- "$INITCWND_STATE_PATH"
    fi
    return 1
  }

  echo -e "${Y}==> 当前默认路由:${N} ${C}$route_line${N}"
  echo -e "${Y}==> 应用 initcwnd/initrwnd ${initcwnd_value}...${N}"
  if ! ip route replace $route_spec initcwnd $initcwnd_value initrwnd $initcwnd_value; then
    echo -e "${R}默认路由优化失败，请检查路由权限或当前网络环境${N}"
    [ "$quiet" != "1" ] && pause_screen
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  fi

  echo -e "${Y}==> 写入动态路由 helper 与 systemd 持久化服务...${N}"
  if ! mkdir -p "$(dirname -- "$INITCWND_HELPER_PATH")"; then
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  fi
  tmp_helper=$(mktemp "${INITCWND_HELPER_PATH}.tmp.XXXXXX") || {
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  }
  if ! cat > "$tmp_helper" <<'EOF'
#!/bin/bash
# Managed by Leyili. 每次启动读取当前默认路由，避免固化旧网关/网卡。
set -euo pipefail
value="${1:?missing initcwnd value}"
ip_bin=$(command -v ip)
route_line=$($ip_bin route show default | head -n 1)
[ -n "$route_line" ]
route_spec=$(printf '%s\n' "$route_line" | awk '{
  sep=""
  for (i = 1; i <= NF; i++) {
    if ($i == "initcwnd" || $i == "initrwnd") { i++; next }
    printf "%s%s", sep, $i
    sep=" "
  }
}')
# shellcheck disable=SC2086
$ip_bin route replace $route_spec initcwnd "$value" initrwnd "$value"
EOF
  then
    rm -f -- "$tmp_helper"
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  fi
  if ! chmod 755 "$tmp_helper" \
     || ! mv -f -- "$tmp_helper" "$INITCWND_HELPER_PATH"; then
    rm -f -- "$tmp_helper"
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  fi

  tmp_service=$(mktemp "${INITCWND_SERVICE_PATH}.tmp.XXXXXX") || {
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  }
  if ! cat > "$tmp_service" << EOF
# Managed by Leyili
[Unit]
Description=Set TCP initcwnd/initrwnd
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INITCWND_HELPER_PATH $initcwnd_value
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  then
    rm -f -- "$tmp_service"
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  fi
  if ! chmod 644 "$tmp_service" 2>/dev/null \
     || ! mv -f -- "$tmp_service" "$INITCWND_SERVICE_PATH"; then
    rm -f -- "$tmp_service"
    initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
      "$was_enabled" "$was_active" "$state_created" 0 || :
    return 1
  fi

  if ! systemctl daemon-reload \
     || ! systemctl enable --now "$service_name"; then
    if initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
         "$was_enabled" "$was_active" "$state_created" 1; then
      echo -e "${R}initcwnd 持久化服务启用失败，已恢复原文件、路由与服务状态${N}"
    else
      echo -e "${R}initcwnd 持久化服务启用失败，且回滚未完全成功${N}"
    fi
    [ "$quiet" != "1" ] && pause_screen
    return 1
  fi

  current_route=$(ip route show default 2>/dev/null | head -1)
  if ! printf '%s\n' "$current_route" | grep -Eq "(^| )initcwnd ${initcwnd_value}( |$)"; then
    if initcwnd_apply_rollback "$route_line" "$service_name" "$helper_txn" "$service_txn" \
         "$was_enabled" "$was_active" "$state_created" 1; then
      echo -e "${R}initcwnd 健康检查失败，已恢复原状态${N}"
    else
      echo -e "${R}initcwnd 健康检查失败，且回滚未完全成功${N}"
    fi
    return 1
  fi

  managed_file_transaction_commit "$helper_txn"
  managed_file_transaction_commit "$service_txn"

  if [ "$quiet" = "1" ]; then
    return 0
  fi

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

remove_initcwnd_managed(){
  local quiet="${1:-0}" service_name
  local route_line route_spec
  local original_active=0 original_enabled=0 managed=0 rc=0

  service_name=$(basename "$INITCWND_SERVICE_PATH")
  if grep -Fq 'Managed by Leyili' "$INITCWND_SERVICE_PATH" 2>/dev/null \
     || [ -e "${INITCWND_SERVICE_PATH}.leyili-original" ] \
     || [ -f "$INITCWND_STATE_PATH" ]; then
    managed=1
  fi
  [ "$managed" -eq 1 ] || return 0

  original_active=$(awk -F= '$1 == "original_active" {print $2; exit}' "$INITCWND_STATE_PATH" 2>/dev/null)
  original_enabled=$(awk -F= '$1 == "original_enabled" {print $2; exit}' "$INITCWND_STATE_PATH" 2>/dev/null)
  if systemctl is-active --quiet "$service_name" 2>/dev/null \
     || systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
    systemctl disable --now "$service_name" >/dev/null 2>&1 || rc=1
  fi
  managed_file_restore "$INITCWND_SERVICE_PATH" || rc=1
  managed_file_restore "$INITCWND_HELPER_PATH" || rc=1
  systemctl daemon-reload >/dev/null 2>&1 || rc=1

  if [ "$original_enabled" = "1" ]; then systemctl enable "$service_name" >/dev/null 2>&1 || rc=1; fi
  if [ "$original_active" = "1" ]; then systemctl start "$service_name" >/dev/null 2>&1 || rc=1; fi

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
      ip route replace $route_spec >/dev/null 2>&1 || rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    rm -f -- "$INITCWND_STATE_PATH" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    [ "$quiet" = "1" ] || echo -e "  ${G}initcwnd 优化已移除${N}"
  else
    echo -e "${R}initcwnd 移除/恢复未完全成功，状态文件已保留：${INITCWND_STATE_PATH}${N}" >&2
  fi
  return "$rc"
}

remove_initcwnd_optimization(){
  local confirm=""

  if ! require_root; then return 1; fi
  if ! grep -Fq 'Managed by Leyili' "$INITCWND_SERVICE_PATH" 2>/dev/null \
     && [ ! -e "${INITCWND_SERVICE_PATH}.leyili-original" ] \
     && [ ! -f "$INITCWND_STATE_PATH" ]; then
    echo ""
    echo -e "${Y}未检测到脚本管理的 initcwnd 服务，无需移除${N}"
    pause_screen
    return 0
  fi

  echo ""
  read -p "  确认移除 initcwnd 持久化服务并恢复原文件/当前路由？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  if ! remove_initcwnd_managed 0; then
    pause_screen
    return 1
  fi

  echo ""
  pause_screen
}

apply_network_optimization(){
  local mem_tier="$1"
  local buffer_max="${2:-}"   # 向导按实测 BDP 算出，透传给 apply_tcp_tuning
  local rtt_ms="${3:-}"
  local bw_mbps="${4:-}"
  local initcwnd_value=32
  local mem_label
  local notsent_lowat fin_timeout
  local live_cc live_iface live_qdisc
  local rollback_rc=0

  if ! require_root; then return 1; fi

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

  if ! apply_tcp_tuning "$mem_tier" "$buffer_max" "$rtt_ms" "$bw_mbps"; then
    echo -e "${R}TCP 调优失败，已中止${N}"
    pause_screen
    return 1
  fi

  if ! apply_initcwnd_optimization "$initcwnd_value" 1; then
    managed_file_restore "$TCP_TUNING_PATH" || rollback_rc=1
    sysctl --system >/dev/null 2>&1 || rollback_rc=1
    sysctl_state_restore "$TCP_TUNING_STATE" || rollback_rc=1
    restore_live_qdisc "$TCP_QDISC_STATE" 1 || rollback_rc=1
    if [ "$rollback_rc" -eq 0 ]; then
      echo -e "${R}initcwnd 优化失败，TCP 调优也已回滚，避免留下半套配置${N}"
    else
      echo -e "${R}initcwnd 优化失败，且 TCP 调优回滚未完全成功，请检查上方快照提示${N}"
    fi
    pause_screen
    return 1
  fi

  # 展示用：回读实际落盘 / 生效的值（buffer_max 可能被 apply 侧归一化）
  buffer_max=$(awk -F'=' '/^[[:space:]]*net\.core\.rmem_max/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$TCP_TUNING_PATH" 2>/dev/null)
  notsent_lowat=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo "?")
  fin_timeout=$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null || echo "?")

  echo ""
  echo -e "${G}✓ 网络优化完成${N}"
  echo -e "  模式        : ${C}智能调参（自动实测）${N}"
  echo -e "  内存档位    : ${C}$mem_label${N}"
  if [ -n "$rtt_ms" ]; then
    echo -e "  实测 RTT    : ${C}${rtt_ms} ms${N}"
    echo -e "  有效带宽    : ${C}${bw_mbps} Mbps${N}"
  fi
  if [ -n "$buffer_max" ] && [ "$buffer_max" -gt 0 ] 2>/dev/null; then
    echo -e "  rmem/wmem   : ${C}$((buffer_max / 1024 / 1024))M${N}"
  fi
  echo -e "  notsent     : ${C}$notsent_lowat${N}"
  echo -e "  fin_timeout : ${C}$fin_timeout${N}"
  echo -e "  initcwnd    : ${C}$initcwnd_value${N}"
  # 显示「实际生效」的拥塞算法与网卡 qdisc：cc 读运行值可反映 BBR 是否降级；
  # qdisc 读 tc 实际值（而非全局 default_qdisc），避免误报 fq 已生效
  live_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  live_iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
  if [ -n "$live_iface" ] && command -v tc >/dev/null 2>&1; then
    live_qdisc=$(tc qdisc show dev "$live_iface" 2>/dev/null | awk 'NR==1 {print $2; exit}')
  fi
  [ -z "$live_qdisc" ] && live_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
  echo -e "  qdisc / cc  : ${C}${live_qdisc} / ${live_cc}${N}${live_iface:+ ${D}(${live_iface})${N}}"
  echo -e "  配置文件    : ${C}$TCP_TUNING_PATH${N}"
  pause_screen
}

show_network_optimization_menu(){
  local choice

  while true; do
    render_section_header "网络优化"
    render_menu_item 1 "TCP 智能调优 + initcwnd ${D}(实测 RTT × 带宽算 BDP)${N}"
    render_menu_item 2 "QUIC/UDP 协议优化"
    render_menu_item 3 "移除 TCP 调优"
    render_menu_item 4 "移除 QUIC 调优"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case "$choice" in
      1) show_tcp_auto_tune_wizard ;;
      2) show_quic_optimization_picker ;;
      3) remove_tcp_tuning ;;
      4) remove_quic_tuning ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

# ── 智能 TCP 调参（自动实测）──────────────────────────────────────────
# TCP 调优的唯一入口（固定地区档 2026-08 移除，全部机器统一走实测）。
# 思路：RTT 用两条独立通道实测取小 —— ss 直接读「本机与目标 IP 现有 TCP 连接」
# 的内核统计（用户正 SSH 在线，天然有一条到家里的活连接，ICMP 被禁也能测）；
# ping 5 发取 min 作交叉验证。带宽让用户报套餐值（VPS 侧无法单方面测出家宽
# 下行）。BDP = 带宽 × RTT，buffer_max ≈ 3×BDP 留 BBR 探测与晚高峰余量，再按
# 内存档封顶防 OOM，最后经 apply_network_optimization 落盘。

# 读内核对「与目标 IP 的既有 TCP 连接」的实测 RTT（输出整数 ms；空 = 无数据）。
# 优先 minrtt（连接存续期最小值，最接近纯传播时延），退化用 rtt: 平滑均值；
# 多条连接取最小。
_tcp_autotune_rtt_from_ss(){
  local ip="$1" dst
  case "$ip" in
    *:*) dst="[$ip]" ;;   # ss 过滤器里 IPv6 字面量需要方括号
    *)   dst="$ip" ;;
  esac
  ss -tin state established dst "$dst" 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^rtt:[0-9.]+\//) {            # 锚定 ^rtt: 避免误吞 minrtt:
          split($i, a, /[:\/]/); v = a[2] + 0
          if (v > 0 && (avg == 0 || v < avg)) avg = v
        } else if ($i ~ /^minrtt:[0-9.]+$/) {
          split($i, a, ":"); v = a[2] + 0
          if (v > 0 && (mn == 0 || v < mn)) mn = v
        }
      }
    }
    END {
      v = (mn > 0) ? mn : avg
      if (v > 0) { if (v < 1) v = 1; printf "%d", v + 0.5 }
    }'
}

# ping 5 发取 min（输出整数 ms；空 = 不通/被禁）。按 " = " 切汇总行，
# 同时兼容 iputils（rtt min/avg/max/mdev）与 busybox（round-trip min/avg/max）。
_tcp_autotune_rtt_from_ping(){
  local ip="$1" out=""
  case "$ip" in
    *:*)
      out=$(LC_ALL=C ping -6 -n -c 5 -i 0.2 -W 1 "$ip" 2>/dev/null) \
        || out=$(LC_ALL=C ping6 -n -c 5 -i 0.2 -W 1 "$ip" 2>/dev/null) || true
      ;;
    *)
      out=$(LC_ALL=C ping -n -c 5 -i 0.2 -W 1 "$ip" 2>/dev/null) || true
      ;;
  esac
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | awk '
    /min\/avg/ {
      split($0, p, " = "); split(p[2], v, "/")
      m = v[1] + 0
      if (m > 0) { if (m < 1) m = 1; printf "%d", m + 0.5 }
      exit
    }'
}

# 按 MemTotal 自动定内存档（仅用于 buffer 封顶，不再让用户手选）。
# 阈值给标称容量的实报值留裕量：512M/1G/2G/4G 实报约 480/970/1950/3900 MB。
_tcp_autotune_mem_tier(){
  local kb mb
  kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
  case "$kb" in ''|*[!0-9]*) echo "2g"; return ;; esac
  mb=$((kb / 1024))
  if [ "$mb" -lt 768 ]; then echo "512m"
  elif [ "$mb" -lt 1500 ]; then echo "1g"
  elif [ "$mb" -lt 3000 ]; then echo "2g"
  elif [ "$mb" -lt 6000 ]; then echo "4g"
  else echo "8g"
  fi
}

# 每档 buffer 上限 = 旧版固定地区档（hk/jp/us-west/eu 查表，已移除）在该内存档
# 曾交付过的最大值，保证自动模式的产出不超出以往实机验证过的范围
_tcp_autotune_ceiling(){
  case "$1" in
    512m) echo 8388608   ;;
    1g)   echo 16777216  ;;
    2g)   echo 33554432  ;;
    4g)   echo 50331648  ;;
    *)    echo 67108864  ;;
  esac
}

# BDP → buffer_max：3×BDP，向上取整到 2MiB，floor 8M，按内存档封顶。
# 乘数取 3：BBR cwnd 上限 = 2×BDP（cwnd_gain），内核 sndbuf 自动扩容又按
# 「在途 ×2 + skb 开销」定目标，2×BDP 会让 ProbeBW 阶段被发送缓冲卡住；
# 且晚高峰入国方向排队会让实际 RTT 高于实测 minRTT，3× 把这些余量都包进来。
# floor 8M 来自 100M 跨洋线的历史实测（原 us-west-100m 档：8M 比 4M/16M 稳）。
_tcp_autotune_calc_buffer(){
  local rtt_ms="$1" bw_mbps="$2" mem_tier="$3"
  local raw buf ceiling
  raw=$((bw_mbps * 125 * rtt_ms * 3))
  buf=$(( (raw + 2097151) / 2097152 * 2097152 ))
  [ "$buf" -lt 8388608 ] && buf=8388608
  ceiling=$(_tcp_autotune_ceiling "$mem_tier")
  [ "$buf" -gt "$ceiling" ] && buf="$ceiling"
  echo "$buf"
}

# 目标 IP 结构校验。此前只查字符集，"deadbeef" 这类纯 hex 串会被当合法 IP
# 收下，双路实测必然落空后又把用户绕去手动输 RTT，提示有误导。
# IPv4 严格校验点分四段 0-255；IPv6 宽松校验（字符集、"::" 至多一个、
# 组数 ≤8、单组 ≤4 个 hex、v4 结尾段递归校验）——拦明显垃圾即可，
# 可达性最终由 ss/ping 实测判定。
_tcp_autotune_valid_ip(){
  local ip="$1" seg
  case "$ip" in
    *:*)
      case "$ip" in
        *[!0-9a-fA-F:.]*|*:::*) return 1 ;;
      esac
      case "$ip" in
        *[0-9a-fA-F]*) : ;;
        *) return 1 ;;   # 只有冒号（":" / "::"），不是可测目标
      esac
      seg="${ip#*::}"
      case "$seg" in *::*) return 1 ;; esac
      local IFS=:
      # shellcheck disable=SC2086
      set -- $ip
      [ $# -le 8 ] || return 1
      for seg in "$@"; do
        case "$seg" in
          '') ;;                                             # "::" 压缩产生的空组
          *.*) _tcp_autotune_valid_ip "$seg" || return 1 ;;  # v4 结尾段
          ?????*) return 1 ;;                                # 单组超过 4 个 hex
        esac
      done
      return 0
      ;;
    *)
      case "$ip" in ''|*[!0-9.]*|.*|*.|*..*) return 1 ;; esac
      local IFS=.
      # shellcheck disable=SC2086
      set -- $ip
      [ $# -eq 4 ] || return 1
      for seg in "$@"; do
        case "$seg" in ''|????*) return 1 ;; esac
        [ "$((10#$seg))" -le 255 ] || return 1
      done
      return 0
      ;;
  esac
}

show_tcp_auto_tune_wizard(){
  local ssh_ip="" target_ip="" input
  local rtt_ss="" rtt_ping="" rtt_ms="" rtt_src=""
  local down_bw="" vps_bw="" eff_bw=""
  local mem_tier mem_label bdp buffer_max bdp_mb buf_mb ceiling_mb

  if ! require_root; then return 1; fi

  render_section_header "智能 TCP 调参（自动实测）"
  echo -e "  ${D}实测到你本地的 RTT + 你输入的带宽 → 按 BDP 自动计算缓冲区上限${N}"
  echo ""

  # --- 1/4 目标 IP：默认取当前 SSH 客户端 ---
  [ -n "${SSH_CLIENT:-}" ] && ssh_ip=$(printf '%s' "$SSH_CLIENT" | awk '{print $1}')
  while true; do
    if [ -n "$ssh_ip" ]; then
      echo -e "  ${B}检测到 SSH 客户端 IP${N} : ${C}${ssh_ip}${N}"
      read -p "  测速目标 IP (回车用上面的，可手输 IPv4/IPv6，0 返回): " input
      [ -z "$input" ] && input="$ssh_ip"
    else
      echo -e "  ${Y}未检测到 SSH 客户端 IP（可能经 su / 串口控制台进入）${N}"
      read -p "  请输入测速目标 IP (IPv4/IPv6，0 返回): " input
    fi
    [ "$input" = "0" ] && return 1
    if ! _tcp_autotune_valid_ip "$input"; then
      echo -e "  ${R}不是合法的 IPv4/IPv6 地址${N}"
      continue
    fi
    case "$input" in
      *:*) is_private_ipv6 "$input" && echo -e "  ${Y}⚠ 这是内网/链路本地地址，测出的 RTT 不能代表公网路径${N}" ;;
      *)   is_private_ipv4 "$input" && echo -e "  ${Y}⚠ 这是内网地址，如需测到你家里请用本地网络的公网出口 IP${N}" ;;
    esac
    target_ip="$input"
    break
  done

  # --- 2/4 双路实测 RTT ---
  echo ""
  echo -e "${Y}==> 测量到 ${target_ip} 的 RTT (ss 读现有连接 + ping 5 发)...${N}"
  rtt_ss=$(_tcp_autotune_rtt_from_ss "$target_ip")
  rtt_ping=$(_tcp_autotune_rtt_from_ping "$target_ip")
  [ -n "$rtt_ss" ]   && echo -e "  ${D}ss   (内核连接实测) : ${rtt_ss} ms${N}"
  [ -n "$rtt_ping" ] && echo -e "  ${D}ping (5 发取 min)   : ${rtt_ping} ms${N}"

  # 两条通道都只会高估、不会低估传播 RTT，故取可用结果的最小值
  if [ -n "$rtt_ss" ] && [ -n "$rtt_ping" ]; then
    if [ "$rtt_ping" -le "$rtt_ss" ]; then
      rtt_ms="$rtt_ping"; rtt_src="ping·双路取小"
    else
      rtt_ms="$rtt_ss"; rtt_src="ss(tcp)·双路取小"
    fi
  elif [ -n "$rtt_ss" ]; then
    rtt_ms="$rtt_ss"; rtt_src="ss(tcp)"
  elif [ -n "$rtt_ping" ]; then
    rtt_ms="$rtt_ping"; rtt_src="ping"
  else
    echo -e "  ${Y}两种方式都未测到（该 IP 无现存连接且 ICMP 不通）${N}"
    while true; do
      read -p "  请手动输入到该 IP 的 RTT (ms，1-2000，0 返回): " input
      [ "$input" = "0" ] && return 1
      case "$input" in
        ''|*[!0-9]*|???????*) echo -e "  ${R}必须为正整数${N}"; continue ;;
      esac
      input=$((10#$input))   # 强制十进制，防 "090" 这类前导零被按八进制解析
      if [ "$input" -lt 1 ] || [ "$input" -gt 2000 ]; then
        echo -e "  ${R}范围 1-2000 ms${N}"
        continue
      fi
      rtt_ms="$input"; rtt_src="手动输入"
      break
    done
  fi
  if [ "$rtt_ms" -gt 800 ]; then
    echo -e "  ${Y}⚠ RTT 超过 800ms，疑似测量异常，请确认目标 IP 是否正确${N}"
  fi

  # --- 3/4 带宽（家宽下行 VPS 侧测不了，报套餐值即可）---
  echo ""
  while true; do
    read -p "  你本地的下载带宽 (Mbps，如 300 / 500 / 1000): " down_bw
    case "$down_bw" in
      ''|*[!0-9]*|???????*) echo -e "  ${R}必须为正整数 (1-10000)${N}"; continue ;;
    esac
    down_bw=$((10#$down_bw))   # 强制十进制，防 "0300" 这类前导零被按八进制解析
    if [ "$down_bw" -lt 1 ] || [ "$down_bw" -gt 10000 ]; then
      echo -e "  ${R}范围 1-10000 Mbps${N}"
      continue
    fi
    break
  done
  # 共享带宽/超售机型：按「端口峰值」填或直接回车 —— buffer_max 是自动调节的
  # 上限、不预占内存，高峰跌速交给 BBR 自己收敛；反之填了高峰实测的低值，
  # 会把离峰时段的吞吐也一起钉死。只有硬限速套餐（如 100M）才填限速值。
  echo -e "  ${D}提示：共享带宽/不确定就直接回车按峰值算，只有硬限速套餐才填限速值${N}"
  while true; do
    read -p "  VPS 出口带宽 (Mbps，回车默认 1000): " vps_bw
    vps_bw="${vps_bw:-1000}"
    case "$vps_bw" in
      *[!0-9]*|???????*) echo -e "  ${R}必须为正整数 (1-40000)${N}"; continue ;;
    esac
    vps_bw=$((10#$vps_bw))
    if [ "$vps_bw" -lt 1 ] || [ "$vps_bw" -gt 40000 ]; then
      echo -e "  ${R}范围 1-40000 Mbps${N}"
      continue
    fi
    break
  done
  eff_bw=$(( down_bw < vps_bw ? down_bw : vps_bw ))

  # --- 4/4 计算 + 确认 ---
  mem_tier=$(_tcp_autotune_mem_tier)
  case "$mem_tier" in
    512m) mem_label="512MB" ;;
    1g)   mem_label="1GB"   ;;
    2g)   mem_label="2GB"   ;;
    4g)   mem_label="4GB"   ;;
    *)    mem_label="8GB+"  ;;
  esac
  bdp=$((eff_bw * 125 * rtt_ms))
  buffer_max=$(_tcp_autotune_calc_buffer "$rtt_ms" "$eff_bw" "$mem_tier")
  bdp_mb=$(awk -v b="$bdp" 'BEGIN { printf "%.1f", b / 1048576 }')
  buf_mb=$((buffer_max / 1024 / 1024))
  ceiling_mb=$(( $(_tcp_autotune_ceiling "$mem_tier") / 1024 / 1024 ))

  echo ""
  echo -e "  ${B}${C}推荐方案${N}"
  render_divider
  echo -e "  实测 RTT    : ${C}${rtt_ms} ms${N} ${D}(${rtt_src})${N}"
  echo -e "  有效带宽    : ${C}${eff_bw} Mbps${N} ${D}(本地 ${down_bw} / VPS ${vps_bw} 取小)${N}"
  echo -e "  BDP         : ${C}${bdp_mb} MB${N} ${D}(带宽 × RTT)${N}"
  echo -e "  buffer_max  : ${C}${buf_mb}M${N} ${D}(≈3×BDP 留探测余量; floor 8M, ${mem_label} 档顶 ${ceiling_mb}M)${N}"
  echo -e "  rmem/wmem   : ${C}16384 524288 ${buffer_max}${N}"
  echo -e "  拥塞 / 队列 : ${C}BBR + fq${N} ${D}(内核不支持时自动降级 cubic / fq_codel)${N}"
  echo -e "  initcwnd    : ${C}32${N}"
  echo -e "  内存档位    : ${C}${mem_label}${N} ${D}(自动检测，仅用于封顶)${N}"
  render_divider
  read -p "  确认应用以上参数? (y/N): " input
  if [ "$input" != "y" ] && [ "$input" != "Y" ]; then
    echo -e "  ${Y}已取消，未做任何修改${N}"
    sleep 1
    return 1
  fi

  if apply_network_optimization "$mem_tier" "$buffer_max" "$rtt_ms" "$eff_bw"; then
    return 0
  fi
  return 1
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

      render_menu_item 1 "512 MB"
      render_menu_item 2 "1 GB"
      render_menu_item 3 "2 GB"
      render_menu_item 4 "4 GB"
      render_menu_item 5 "8 GB+"
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
  local tcp_config_status tcp_qdisc_live status_iface

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

  # 默认网卡上「实际生效」的 qdisc（区别于全局 default_qdisc；后者改了不动现有网卡）
  status_iface=$(printf '%s\n' "$route_line" | awk '/^default/ {print $5; exit}')
  if [ -n "$status_iface" ] && command -v tc >/dev/null 2>&1; then
    tcp_qdisc_live=$(tc qdisc show dev "$status_iface" 2>/dev/null | awk 'NR==1 {print $2; exit}')
  fi

  local tcp_profile_text="未配置"
  local tcp_rmem_max
  tcp_rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "")
  if [ -f "$TCP_TUNING_PATH" ]; then
    tcp_config_status="已存在"
    local profile_line region mem_tier region_label="" mem_label=""
    profile_line=$(awk '/^# leyili-profile:/ { print; exit }' "$TCP_TUNING_PATH" 2>/dev/null)
    if [ -n "$profile_line" ]; then
      region=$(printf '%s\n' "$profile_line" | sed -n 's/.*region=\([a-z0-9-]\+\).*/\1/p')
      mem_tier=$(printf '%s\n' "$profile_line" | sed -n 's/.*mem_tier=\([a-z0-9]\+\).*/\1/p')
      case "$region" in
        # hk/jp/us-west/eu 为旧版固定地区档的存量 marker，仅保留展示映射
        hk)      region_label="香港" ;;
        jp)      region_label="日本" ;;
        us-west) region_label="美西" ;;
        us-west-100m) region_label="美西 100M" ;;
        eu)      region_label="欧洲" ;;
        custom)  region_label="自动实测" ;;
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
        # custom 档补充展示当时的实测输入（marker 里的 rtt=/bw= 附加 token）
        if [ "$region" = "custom" ]; then
          local rtt_tok bw_tok
          rtt_tok=$(printf '%s\n' "$profile_line" | sed -n 's/.*rtt=\([0-9]\+\).*/\1/p')
          bw_tok=$(printf '%s\n' "$profile_line" | sed -n 's/.*bw=\([0-9]\+\).*/\1/p')
          [ -n "$rtt_tok" ] && tcp_profile_text="${tcp_profile_text} (${rtt_tok}ms × ${bw_tok:-?}Mbps)"
        fi
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
  echo -e "  qdisc     : ${C}$tcp_qdisc${N}${tcp_qdisc_live:+ ${D}(${status_iface} 实际: ${tcp_qdisc_live})${N}}"
  echo -e "  拥塞算法  : ${C}$tcp_cc${N}$([ "$tcp_cc" = "bbr" ] && printf ' %b(BBR)%b' "$G" "$N")"
  echo -e "  Fast Open : ${C}$tcp_fastopen${N}"
  echo -e "  notsent   : ${C}$tcp_notsent${N}"
  echo -e "  fin_timeout : ${C}$tcp_fin_timeout${N}"
  echo -e "  keepalive : ${C}$tcp_keepalive${N}"
  echo ""

  local quic_config_status quic_profile_text="未配置"
  local quic_rmem_max
  local conntrack_max conntrack_count
  if [ -f "$QUIC_TUNING_PATH" ]; then
    quic_config_status="已存在"
    local quic_profile_line region mem_tier region_label="" mem_label=""
    quic_profile_line=$(awk '/^# leyili-quic-profile:/ { print; exit }' "$QUIC_TUNING_PATH" 2>/dev/null)
    if [ -n "$quic_profile_line" ]; then
      region=$(printf '%s\n' "$quic_profile_line" | sed -n 's/.*region=\([a-z0-9-]\+\).*/\1/p')
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

  echo -e "  ${B}QUIC/UDP 参数状态${N}"
  echo -e "  配置文件  : ${C}$quic_config_status${N} (${QUIC_TUNING_PATH})"
  echo -e "  配置档位  : ${C}$quic_profile_text${N}"
  if [ -n "$quic_rmem_max" ] && [ "$quic_rmem_max" -gt 0 ] 2>/dev/null; then
    echo -e "  rmem_max  : ${C}$((quic_rmem_max / 1024 / 1024))M${N} ${D}(共用 TCP)${N}"
  fi
  if [ -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
    conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "?")
    conntrack_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "?")
    echo -e "  conntrack : ${C}${conntrack_count}${N} / ${C}${conntrack_max}${N}"
  fi
  pause_screen
}

swap_transaction_rollback(){
  local created_this_run="${1:-0}"
  local fstab_backup="${2:-}"
  local sysctl_txn="${3:-}"
  local rc=0

  if [ -n "$sysctl_txn" ] && [ -d "$sysctl_txn" ]; then
    managed_file_transaction_rollback "$SWAP_SYSCTL_PATH" "$sysctl_txn" || rc=1
  fi
  if [ -n "$fstab_backup" ] && [ -f "$fstab_backup" ]; then
    restore_file_snapshot "$fstab_backup" /etc/fstab || rc=1
  fi
  if [ "$created_this_run" = "1" ]; then
    if awk -v p="$SWAPFILE_PATH" 'NR > 1 && $1 == p {found=1} END {exit !found}' /proc/swaps 2>/dev/null; then
      swapoff "$SWAPFILE_PATH" >/dev/null 2>&1 || rc=1
    fi
    if ! awk -v p="$SWAPFILE_PATH" 'NR > 1 && $1 == p {found=1} END {exit !found}' /proc/swaps 2>/dev/null; then
      rm -f -- "$SWAPFILE_PATH" || rc=1
    else
      rc=1
    fi
  fi
  sysctl --system >/dev/null 2>&1 || rc=1
  if [ "$rc" -eq 0 ]; then
    [ -z "$fstab_backup" ] || rm -f -- "$fstab_backup" || rc=1
  else
    echo -e "${R}SWAP 事务回滚未完全成功${fstab_backup:+，fstab 快照保留在 ${fstab_backup}}${N}" >&2
  fi
  return "$rc"
}

configure_swap(){
  local swap_size_mb="${1:-2048}"
  local size_label="${2:-${swap_size_mb} MB}"
  local swap_active="false"
  local state_created_file=0 adopted=0 fstab_added=0 created_this_run=0
  local swap_tmp="" fstab_backup="" fstab_tmp="" sysctl_txn="" tmp_sysctl="" tmp_state="" adopt_choice=""

  if ! require_root; then return 1; fi

  echo ""
  echo -e "  ${B}${C}当前内存 / SWAP 状态${N}"
  free -h
  echo ""

  if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAPFILE_PATH"; then
    swap_active="true"
  fi

  if [ "$swap_active" = "true" ]; then
    if [ ! -f "$SWAP_STATE_PATH" ]; then
      echo -e "${Y}检测到已启用但无法确认由本脚本创建的 ${SWAPFILE_PATH}${N}"
      echo -e "${D}默认不会接管、格式化或删除该文件。输入 ADOPT 仅接管 swappiness；文件与既有 fstab 行仍归用户。${N}"
      read -p "  输入 ADOPT 接管设置，其它输入取消: " adopt_choice
      if [ "$adopt_choice" != "ADOPT" ]; then
        echo -e "  已取消，现有 SWAP 未作任何修改"
        pause_screen
        return 0
      fi
      adopted=1
    else
      adopted=$(awk -F= '$1 == "adopted" {print $2; exit}' "$SWAP_STATE_PATH" 2>/dev/null)
      state_created_file=$(awk -F= '$1 == "created_file" {print $2; exit}' "$SWAP_STATE_PATH" 2>/dev/null)
      fstab_added=$(awk -F= '$1 == "fstab_added" {print $2; exit}' "$SWAP_STATE_PATH" 2>/dev/null)
    fi
    echo -e "${Y}==> ${SWAPFILE_PATH} 已启用，不重新格式化${N}"
  else
    if [ -f "$SWAPFILE_PATH" ]; then
      echo -e "${R}检测到未启用的现有文件 ${SWAPFILE_PATH}，拒绝执行 mkswap（会破坏原内容）。${N}"
      echo -e "${Y}请先人工确认并移动/删除该文件，再重新运行。${N}"
      pause_screen
      return 1
    fi

    echo -e "${Y}==> 创建 ${size_label} SWAP 文件...${N}"
    swap_tmp=$(mktemp "${SWAPFILE_PATH}.leyili.XXXXXX") || return 1
    if ! fallocate -l "${swap_size_mb}M" "$swap_tmp"; then
      echo -e "${Y}==> fallocate 失败，改用 dd 创建...${N}"
      if ! dd if=/dev/zero of="$swap_tmp" bs=1M count="$swap_size_mb" status=progress; then
        rm -f -- "$swap_tmp"
        echo -e "${R}SWAP 文件创建失败${N}"
        pause_screen
        return 1
      fi
    fi
    chmod 600 "$swap_tmp" || { rm -f -- "$swap_tmp"; return 1; }
    if ! mkswap "$swap_tmp" >/dev/null \
       || ! mv -f -- "$swap_tmp" "$SWAPFILE_PATH" \
       || ! swapon "$SWAPFILE_PATH"; then
      rm -f -- "$swap_tmp" "$SWAPFILE_PATH"
      echo -e "${R}SWAP 格式化或启用失败，已删除本次新建文件${N}"
      pause_screen
      return 1
    fi
    created_this_run=1
    state_created_file=1
  fi

  fstab_backup=$(mktemp "${TMPDIR:-/tmp}/leyili-fstab.XXXXXX") || {
    swap_transaction_rollback "$created_this_run" "" ""
    return 1
  }
  cp -a -- /etc/fstab "$fstab_backup" || {
    swap_transaction_rollback "$created_this_run" "$fstab_backup" ""
    return 1
  }
  if ! awk -v p="$SWAPFILE_PATH" '$1 == p && $3 == "swap" {found=1} END {exit !found}' /etc/fstab; then
    fstab_tmp=$(mktemp /etc/fstab.tmp.XXXXXX) || {
      swap_transaction_rollback "$created_this_run" "$fstab_backup" ""
      return 1
    }
    if ! { cat /etc/fstab; printf '\n# Managed by Leyili SWAP\n%s none swap sw 0 0\n' "$SWAPFILE_PATH"; } > "$fstab_tmp"; then
      rm -f -- "$fstab_tmp"
      swap_transaction_rollback "$created_this_run" "$fstab_backup" ""
      return 1
    fi
    if ! chmod --reference=/etc/fstab "$fstab_tmp" 2>/dev/null \
       || ! chown --reference=/etc/fstab "$fstab_tmp" 2>/dev/null \
       || ! mv -f -- "$fstab_tmp" /etc/fstab; then
      rm -f -- "$fstab_tmp"
      swap_transaction_rollback "$created_this_run" "$fstab_backup" ""
      return 1
    fi
    fstab_added=1
  fi

  echo -e "${Y}==> 设置 swappiness = ${SWAPPINESS_VALUE}...${N}"
  sysctl_txn=$(managed_file_transaction_begin "$SWAP_SYSCTL_PATH" 'Managed by Leyili') || {
    swap_transaction_rollback "$created_this_run" "$fstab_backup" ""
    return 1
  }
  tmp_sysctl=$(mktemp "${SWAP_SYSCTL_PATH}.tmp.XXXXXX") || {
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    return 1
  }
  if ! cat > "$tmp_sysctl" << EOF
# Managed by Leyili
vm.swappiness = $SWAPPINESS_VALUE
EOF
  then
    rm -f -- "$tmp_sysctl"
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    return 1
  fi
  if ! chmod 600 "$tmp_sysctl" 2>/dev/null \
     || ! mv -f -- "$tmp_sysctl" "$SWAP_SYSCTL_PATH"; then
    rm -f -- "$tmp_sysctl"
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    return 1
  fi

  if ! sysctl -p "$SWAP_SYSCTL_PATH" 2>/dev/null; then
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    echo -e "${R}swappiness 应用失败，已恢复 fstab、sysctl 与本次新建 SWAP${N}"
    pause_screen
    return 1
  fi

  if ! ensure_leyili_state_dir; then
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    return 1
  fi
  tmp_state=$(mktemp "${SWAP_STATE_PATH}.tmp.XXXXXX") || {
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    return 1
  }
  {
    printf 'path=%s\n' "$SWAPFILE_PATH"
    printf 'created_file=%s\n' "${state_created_file:-0}"
    printf 'adopted=%s\n' "${adopted:-0}"
    printf 'fstab_added=%s\n' "${fstab_added:-0}"
  } > "$tmp_state" || {
    rm -f -- "$tmp_state"
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    return 1
  }
  if ! chmod 600 "$tmp_state" 2>/dev/null \
     || ! mv -f -- "$tmp_state" "$SWAP_STATE_PATH"; then
    rm -f -- "$tmp_state"
    swap_transaction_rollback "$created_this_run" "$fstab_backup" "$sysctl_txn"
    return 1
  fi
  managed_file_transaction_commit "$sysctl_txn"
  rm -f -- "$fstab_backup"

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
      if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAPFILE_PATH"; then
        echo -e "  ${Y}⚠ 检测到已启用 ${SWAPFILE_PATH}（约 ${existing_size_mb} MB），不会重新格式化${N}"
        [ -f "$SWAP_STATE_PATH" ] || echo -e "  ${D}  因缺少所有权记录，后续仅在输入 ADOPT 后接管 swappiness，不会接管或删除文件${N}"
      else
        echo -e "  ${R}⚠ 检测到未启用的现有 ${SWAPFILE_PATH}（约 ${existing_size_mb} MB），脚本会拒绝 mkswap 以保护原内容${N}"
      fi
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
  local tmp_file="" fstab_backup="" sysctl_txn=""
  local created_file=0 adopted=0 fstab_added=0
  local was_active=0 rollback_ok=1 rc=0

  if ! require_root; then
    return 1
  fi

  if [ ! -f "$SWAP_STATE_PATH" ]; then
    echo ""
    echo -e "${Y}没有找到 ${SWAP_STATE_PATH}，无法证明 ${SWAPFILE_PATH} 归脚本所有。${N}"
    echo -e "${D}为避免删除用户文件，本菜单不会关闭、删除或改写现有 SWAP/fstab。${N}"
    pause_screen
    return 0
  fi

  created_file=$(awk -F= '$1 == "created_file" {print $2; exit}' "$SWAP_STATE_PATH" 2>/dev/null)
  adopted=$(awk -F= '$1 == "adopted" {print $2; exit}' "$SWAP_STATE_PATH" 2>/dev/null)
  fstab_added=$(awk -F= '$1 == "fstab_added" {print $2; exit}' "$SWAP_STATE_PATH" 2>/dev/null)

  echo ""
  if [ "$created_file" = "1" ]; then
    echo -e "${Y}==> 即将关闭并删除脚本创建的 ${C}$SWAPFILE_PATH${N}${Y}，并恢复原 swappiness 文件${N}"
  else
    echo -e "${Y}==> 此 SWAP 为显式接管项：仅恢复脚本设置，保留文件、启用状态和既有 fstab 行${N}"
  fi
  read -p "  确认继续？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  fstab_backup=$(mktemp "${TMPDIR:-/tmp}/leyili-fstab-remove.XXXXXX") || return 1
  cp -a -- /etc/fstab "$fstab_backup" || { rm -f -- "$fstab_backup"; return 1; }
  if [ "$fstab_added" = "1" ]; then
    tmp_file=$(mktemp /etc/fstab.tmp.XXXXXX) || { rm -f -- "$fstab_backup"; return 1; }
    if ! awk -v p="$SWAPFILE_PATH" '
      /^# Managed by Leyili SWAP$/ {pending=1; next}
      pending && $1 == p && $3 == "swap" {pending=0; next}
      {if (pending) {print "# Managed by Leyili SWAP"; pending=0} print}
      END {if (pending) print "# Managed by Leyili SWAP"}
    ' /etc/fstab > "$tmp_file"; then
      rm -f -- "$tmp_file" "$fstab_backup"
      return 1
    fi
    if ! chmod --reference=/etc/fstab "$tmp_file" 2>/dev/null \
       || ! chown --reference=/etc/fstab "$tmp_file" 2>/dev/null \
       || ! mv -f -- "$tmp_file" /etc/fstab; then
      rm -f -- "$tmp_file" "$fstab_backup"
      return 1
    fi
  fi

  sysctl_txn=$(managed_file_transaction_begin "$SWAP_SYSCTL_PATH" 'Managed by Leyili') || {
    if restore_file_snapshot "$fstab_backup" /etc/fstab; then
      rm -f -- "$fstab_backup"
    else
      echo -e "${R}SWAP sysctl 快照失败，且 fstab 恢复失败；快照保留在 ${fstab_backup}${N}" >&2
    fi
    return 1
  }
  if ! managed_file_restore "$SWAP_SYSCTL_PATH" \
     || ! sysctl --system >/dev/null 2>&1; then
    managed_file_transaction_rollback "$SWAP_SYSCTL_PATH" "$sysctl_txn" || rollback_ok=0
    restore_file_snapshot "$fstab_backup" /etc/fstab || rollback_ok=0
    [ "$rollback_ok" -eq 1 ] && rm -f -- "$fstab_backup"
    echo -e "${R}恢复原 swappiness 失败，已尝试回滚，SWAP 文件未删除${N}"
    pause_screen
    return 1
  fi

  if [ "$created_file" = "1" ] \
     && awk -v p="$SWAPFILE_PATH" 'NR > 1 && $1 == p {found=1} END {exit !found}' /proc/swaps 2>/dev/null; then
    was_active=1
    echo -e "${Y}==> 关闭 SWAP...${N}"
    if ! swapoff "$SWAPFILE_PATH"; then
      managed_file_transaction_rollback "$SWAP_SYSCTL_PATH" "$sysctl_txn" || rollback_ok=0
      restore_file_snapshot "$fstab_backup" /etc/fstab || rollback_ok=0
      [ "$rollback_ok" -eq 1 ] && rm -f -- "$fstab_backup"
      echo -e "${R}关闭 SWAP 失败，已尝试恢复 fstab 与 swappiness，文件未删除${N}"
      pause_screen
      return 1
    fi
  fi

  if [ "$created_file" = "1" ] && [ -f "$SWAPFILE_PATH" ]; then
    if ! rm -f -- "$SWAPFILE_PATH"; then
      [ "$was_active" -eq 1 ] && swapon "$SWAPFILE_PATH" >/dev/null 2>&1 || {
        [ "$was_active" -eq 0 ] || rollback_ok=0
      }
      managed_file_transaction_rollback "$SWAP_SYSCTL_PATH" "$sysctl_txn" || rollback_ok=0
      restore_file_snapshot "$fstab_backup" /etc/fstab || rollback_ok=0
      [ "$rollback_ok" -eq 1 ] && rm -f -- "$fstab_backup"
      echo -e "${R}删除 SWAP 文件失败，已尝试恢复启用状态、fstab 与 swappiness${N}"
      pause_screen
      return 1
    fi
  fi

  managed_file_transaction_commit "$sysctl_txn" || rc=1
  rm -f -- "$SWAP_STATE_PATH" || rc=1
  rm -f -- "$fstab_backup" || rc=1

  echo ""
  if [ "$rc" -ne 0 ]; then
    echo -e "${R}SWAP 已按确认执行，但状态/临时文件清理不完整，请检查 ${SWAP_STATE_PATH}${N}"
  elif [ "$created_file" = "1" ]; then
    echo -e "${G}脚本创建的 SWAP 已删除（不可恢复）；原 swappiness 文件已恢复${N}"
  else
    echo -e "${G}脚本的 SWAP 设置已移除；接管前的 SWAP 文件与挂载保持不变${N}"
  fi
  free -h
  pause_screen
  return "$rc"
}

# ─── 脚本自更新 / 配置管理 ────────────────────────────
