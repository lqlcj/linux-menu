# ─── 本地链路测评（VPS ⇄ 家宽）────────────────────────
# 从 VPS 侧实测「到用户家庭宽带公网 IP」的链路质量：延迟/抖动/丢包（ping）、
# 逐跳丢包（mtr）、回程线路识别（nexttrace，带 ASN/运营商）、路径 MTU（DF 探测）、
# 带宽与 UDP 丢包（iperf3）。产出纯文本报告，整段复制给 AI 即可结合数据调参。
# 网上通用测速脚本测的都是「VPS → 三网测速节点」，测不到用户自家 IP —— 这是
# 本模块存在的原因。
NETBENCH_ENV_PATH="/etc/leyili/netbench.env"
NETBENCH_REPORT_PREFIX="/root/netbench-report"
NETBENCH_IPERF_PORT_DEFAULT="15201"
# 与 xray-leyili 同思路用独立文件名：卸载时只删自己下载的，不动用户自装的 nexttrace
NETBENCH_NEXTTRACE_BIN="/usr/local/bin/nexttrace-leyili"
NETBENCH_NEXTTRACE_BASE="https://github.com/nxtrace/NTrace-core/releases/latest/download"

# 追加一行纯文本到报告（报告不带 ANSI 色与缩进，方便整段复制给 AI）
_nb_report(){
  printf '%s\n' "$1" >> "$NB_REPORT"
}

_nb_section(){
  local title="$1"
  echo ""
  echo -e "  ${B}${C}› ${title}${N}"
  _nb_report ""
  _nb_report "══════════ ${title} ══════════"
}

# 剥掉 ANSI 颜色码（nexttrace 输出带色，落报告前清洗）
_nb_strip_ansi(){
  sed 's/\x1b\[[0-9;]*[mK]//g'
}

# 统一 v4/v6 ping 入口；现代 iputils 用 `ping -6`，极老系统回落 ping6
_nb_ping(){
  local ip="$1"; shift
  case "$ip" in
    *:*)
      LC_ALL=C ping -6 -n "$@" "$ip" 2>/dev/null \
        || { command -v ping6 >/dev/null 2>&1 && LC_ALL=C ping6 -n "$@" "$ip" 2>/dev/null; }
      ;;
    *)
      LC_ALL=C ping -n "$@" "$ip" 2>/dev/null
      ;;
  esac
}

# 从 ping 汇总输出提取丢包率（"2" / "0.5"；空 = 无汇总行）。
# head -1 兜底：ping -6 失败回落 ping6 时理论上可能出现两段汇总
_nb_parse_loss(){
  sed -n 's/.*[ ,]\([0-9.]*\)% packet loss.*/\1/p' | head -n 1
}

# 提取 rtt 汇总，输出空格分隔的 "min avg max mdev"。
# 兼容 iputils（rtt min/avg/max/mdev = a/b/c/d ms）与
# busybox（round-trip min/avg/max = a/b/c ms，无 mdev → 第 4 列为空）
_nb_parse_rtt(){
  awk '
    /min\/avg/ {
      split($0, p, " = "); split(p[2], v, "/")
      gsub(/ .*/, "", v[3]); gsub(/ .*/, "", v[4])
      printf "%s %s %s %s", v[1], v[2], v[3], v[4]
      exit
    }'
}

# ── 目标 IP 持久化（家宽 IP 多为动态，但短期内复用省得每次手输）──
_nb_load_target(){
  [ -r "$NETBENCH_ENV_PATH" ] || return 0
  awk -F= '$1 == "NETBENCH_TARGET_IP" { print $2; exit }' "$NETBENCH_ENV_PATH" 2>/dev/null
}

_nb_save_target(){
  mkdir -p "$(dirname "$NETBENCH_ENV_PATH")" 2>/dev/null || true
  printf 'NETBENCH_TARGET_IP=%s\n' "$1" > "$NETBENCH_ENV_PATH" 2>/dev/null || true
}

_nb_latest_report(){
  find "$(dirname "$NETBENCH_REPORT_PREFIX")" -maxdepth 1 -type f \
       -name "$(basename "$NETBENCH_REPORT_PREFIX")-*.txt" -printf '%T@\t%p\n' 2>/dev/null \
    | LC_ALL=C sort -rn | head -n 1 | cut -f2-
}

# ── 依赖：mtr + iperf3（apt）───────────────────────────
_nb_ensure_tools(){
  local missing=""
  command -v mtr >/dev/null 2>&1 || missing="mtr-tiny"
  command -v iperf3 >/dev/null 2>&1 || missing="${missing:+$missing }iperf3"
  [ -z "$missing" ] && return 0

  echo -e "${Y}==> 安装测评依赖: ${C}${missing}${N}"
  # iperf3 的 debconf 会问「是否作为守护进程启动」，noninteractive 默认 No（正确）
  # shellcheck disable=SC2086
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y $missing >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y $missing >/dev/null 2>&1; then
      echo -e "${Y}    依赖安装失败（${missing}），对应测试将自动跳过${N}"
      return 1
    fi
  fi
  return 0
}

# nexttrace：带 ASN/运营商/归属地的路由追踪，能直接看出回程走的是
# 163 / CN2 / 4837 / 9929 / CMIN2 哪条线 —— AI 判断线路质量的关键输入。
# 下载失败不致命，回落到只看 mtr 的 IP 段。
_nb_ensure_nexttrace(){
  local arch tmp
  command -v nexttrace >/dev/null 2>&1 && return 0
  [ -x "$NETBENCH_NEXTTRACE_BIN" ] && return 0

  case "$(uname -m)" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l)        arch="armv7" ;;
    *)
      echo -e "${Y}    未适配的架构 $(uname -m)，跳过 nexttrace（仅用 mtr 看路由）${N}"
      return 1
      ;;
  esac

  echo -e "${Y}==> 下载 nexttrace（回程线路识别，仅首次）...${N}"
  tmp=$(mktemp)
  # dd 取 magic 校验是 ELF：GitHub 故障时可能拿到 HTML 报错页，不能直接 chmod 上岗
  if curl -fsSL --max-time 90 "${NETBENCH_NEXTTRACE_BASE}/nexttrace_linux_${arch}" -o "$tmp" \
     && [ "$(dd if="$tmp" bs=1 skip=1 count=3 2>/dev/null)" = "ELF" ]; then
    chmod +x "$tmp"
    if mv "$tmp" "$NETBENCH_NEXTTRACE_BIN"; then
      return 0
    fi
  fi
  rm -f "$tmp"
  echo -e "${Y}    nexttrace 下载失败，回程线路将只有 mtr 数据${N}"
  return 1
}

_nb_nexttrace_bin(){
  if command -v nexttrace >/dev/null 2>&1; then
    command -v nexttrace
  elif [ -x "$NETBENCH_NEXTTRACE_BIN" ]; then
    printf '%s' "$NETBENCH_NEXTTRACE_BIN"
  fi
}

# ── 报告头：VPS 基本信息 + 当前网络参数基线 ───────────
# 把「调参前的现状」一并写进报告，AI 不用追问就能给出增量修改建议
_nb_sysinfo(){
  local target="$1"
  local pretty kernel virt cores mem_mb vps4 vps6 iface mtu cc qdisc live_qdisc
  local rmax wmax trmem twmem notsent icwnd profile

  pretty=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}")
  kernel=$(uname -r 2>/dev/null || echo "?")
  virt=$(systemd-detect-virt 2>/dev/null || echo "unknown")
  cores=$(nproc 2>/dev/null || echo "?")
  mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
  vps4=$(detect_primary_ipv4)
  vps6=$(detect_primary_ipv6)
  iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
  [ -n "$iface" ] && mtu=$(cat "/sys/class/net/${iface}/mtu" 2>/dev/null)
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  if [ -n "$iface" ] && command -v tc >/dev/null 2>&1; then
    live_qdisc=$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1 {print $2}')
  fi
  rmax=$(sysctl -n net.core.rmem_max 2>/dev/null)
  wmax=$(sysctl -n net.core.wmem_max 2>/dev/null)
  trmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)
  twmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)
  notsent=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)
  icwnd=$(ip route show default 2>/dev/null \
          | awk '{for (i = 1; i <= NF; i++) if ($i == "initcwnd") {print $(i+1); exit}}')
  profile=$(awk '/^# leyili-profile:/ {sub(/^# leyili-profile: */, ""); print; exit}' "$TCP_TUNING_PATH" 2>/dev/null)

  _nb_report "【给 AI 的说明】"
  _nb_report "本报告由 ${APP_NAME} 脚本在 VPS 上自动实测生成，方向为「VPS → 家庭宽带公网 IP」。"
  _nb_report "请基于以下数据分析链路质量（延迟/抖动/丢包/回程线路/MTU/带宽），并给出"
  _nb_report "Linux 内核 sysctl 与代理协议（sing-box: Reality/Hysteria2/TUIC 等）的调参建议。"
  _nb_report ""
  _nb_report "── VPS 基本信息 ──"
  _nb_report "测试时间       : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  _nb_report "目标(家宽) IP  : ${target}"
  _nb_report "VPS IPv4/IPv6  : ${vps4:-无} / ${vps6:-无}"
  _nb_report "系统 / 内核    : ${pretty} / ${kernel}"
  _nb_report "虚拟化/CPU/内存: ${virt} / ${cores}核 / ${mem_mb:-?}MB"
  _nb_report "默认网卡       : ${iface:-?} (本机 MTU ${mtu:-?})"
  _nb_report ""
  _nb_report "── VPS 当前网络参数（调参前基线）──"
  _nb_report "拥塞控制/qdisc : ${cc:-?} / ${qdisc:-?} (网卡实际: ${live_qdisc:-?})"
  _nb_report "rmem_max/wmem_max : ${rmax:-?} / ${wmax:-?}"
  _nb_report "tcp_rmem       : ${trmem:-?}"
  _nb_report "tcp_wmem       : ${twmem:-?}"
  _nb_report "notsent_lowat/initcwnd : ${notsent:-?} / ${icwnd:-未设置}"
  _nb_report "已应用调优档   : ${profile:-无（未跑过脚本 TCP 调优）}"

  echo -e "  ${D}已记录 VPS 基线参数（内核/拥塞算法/缓冲区等）${N}"
}

# ── 延迟/抖动/丢包：小包 100 发 + 大包 1400B 对照 ─────
# 大包丢包明显高于小包 = 路径存在 MTU/分片或大包限速问题，对隧道类协议致命。
# 返回 1 表示目标完全不响应 ICMP（后续 MTU 探测应跳过）
_nb_ping_suite(){
  local ip="$1"
  local out big stats rtt_parts big_txt

  NB_LOSS=""; NB_RTT_MIN=""; NB_RTT_AVG=""; NB_RTT_MAX=""; NB_RTT_MDEV=""; NB_BIG_LOSS=""

  _nb_section "延迟 / 抖动 / 丢包（ICMP ping）"
  echo -e "  ${D}小包 56B × 100 发，间隔 0.2s（约 25 秒）...${N}"
  out=$(_nb_ping "$ip" -c 100 -i 0.2 -W 1 -s 56)
  stats=$(printf '%s\n' "$out" | sed -n '/ping statistics/,$p')

  if [ -z "$stats" ]; then
    echo -e "  ${R}ping 无输出（目标不可达或系统缺 ping 工具）${N}"
    _nb_report "小包 56B × 100 发: 测试失败（ping 无输出）"
    return 1
  fi

  printf '%s\n' "$stats" | sed 's/^/  /'
  _nb_report "◆ 小包 56B × 100 发, 间隔 0.2s:"
  printf '%s\n' "$stats" >> "$NB_REPORT"

  NB_LOSS=$(printf '%s\n' "$out" | _nb_parse_loss)
  rtt_parts=$(printf '%s\n' "$out" | _nb_parse_rtt)
  [ -n "$rtt_parts" ] && read -r NB_RTT_MIN NB_RTT_AVG NB_RTT_MAX NB_RTT_MDEV <<< "$rtt_parts"

  case "$NB_LOSS" in
    100|100.*)
      echo ""
      echo -e "  ${Y}⚠ 目标完全不响应 ping：家用光猫/路由器常默认禁 WAN 口 ICMP${N}"
      echo -e "  ${D}  不影响结论：汇总会自动回退用 mtr 末端响应跳 + iperf 真实 TCP 流数据${N}"
      _nb_report "⚠ 目标 100% 不响应 ICMP —— 大概率是路由器禁 ping，而非线路真丢包（汇总已回退用 mtr 末端跳 / TCP 实测数据）"
      return 1
      ;;
  esac

  echo -e "  ${D}大包 1400B × 40 发（约 10 秒）...${N}"
  big=$(_nb_ping "$ip" -c 40 -i 0.2 -W 1 -s 1400)
  big_txt=$(printf '%s\n' "$big" | sed -n '/ping statistics/,$p')
  NB_BIG_LOSS=$(printf '%s\n' "$big" | _nb_parse_loss)

  _nb_report ""
  _nb_report "◆ 大包 1400B × 40 发, 间隔 0.2s:"
  if [ -n "$big_txt" ]; then
    printf '%s\n' "$big_txt" | sed 's/^/  /'
    printf '%s\n' "$big_txt" >> "$NB_REPORT"
  else
    echo -e "  ${Y}1400B 大包无响应（可能路径不允许该尺寸，见 MTU 探测）${N}"
    _nb_report "1400B 大包无响应（可能路径不允许该尺寸，参考 MTU 探测结果）"
  fi
  return 0
}

# ── 路径 MTU：DF 置位从 1500 对应载荷逐档往下探 ───────
_nb_mtu_probe(){
  local ip="$1" overhead=28 sizes size mtu=""

  # ICMP 头开销：v4 = 20 IP + 8 ICMP；v6 = 40 IPv6 + 8 ICMPv6。
  # 档位覆盖常见值：1500 原生 / 1492 PPPoE / 1480-1420 各类隧道 / 1280 v6 下限
  case "$ip" in
    *:*) overhead=48; sizes="1452 1444 1432 1420 1400 1380 1360 1340 1300 1232" ;;
    *)               sizes="1472 1464 1452 1440 1420 1400 1380 1360 1340 1300 1280 1252" ;;
  esac

  NB_PMTU=""
  _nb_section "路径 MTU 探测（DF 不分片 ping）"
  echo -e "  ${D}从 $(( ${sizes%% *} + overhead )) 起逐档探测...${N}"
  for size in $sizes; do
    if _nb_ping "$ip" -M do -c 2 -i 0.3 -W 1 -s "$size" >/dev/null; then
      mtu=$((size + overhead))
      break
    fi
  done

  if [ -n "$mtu" ]; then
    NB_PMTU="$mtu"
    echo -e "  路径 MTU ≈ ${C}${mtu}${N}（最大不分片载荷 ${size}B）"
    _nb_report "路径 MTU ≈ ${mtu}（最大不分片 ICMP 载荷 ${size}B + ${overhead}B 头）"
    if [ "$mtu" -lt 1500 ]; then
      _nb_report "提示: 路径 MTU < 1500，WireGuard/Hysteria2 等隧道协议的 MTU 建议 ≤ $((mtu - 80))"
    fi
  else
    echo -e "  ${Y}未能确定路径 MTU（各档大包均无响应）${N}"
    _nb_report "路径 MTU: 未能确定（DF 大包各档均无响应）"
  fi
}

# ── 逐跳丢包 / 延迟（mtr 报告模式）────────────────────
_nb_mtr(){
  local ip="$1" out parsed

  NB_MTR_IP=""; NB_MTR_LOSS=""; NB_MTR_BEST=""; NB_MTR_AVG=""; NB_MTR_WRST=""; NB_MTR_STDEV=""

  _nb_section "逐跳丢包 / 延迟（mtr, 50 循环）"
  if ! command -v mtr >/dev/null 2>&1; then
    echo -e "  ${Y}mtr 未安装（依赖安装失败），跳过${N}"
    _nb_report "mtr 未安装，跳过"
    return 1
  fi

  echo -e "  ${D}约 12 秒...${N}"
  # -r 报告 -w 宽输出 -n 纯 IP（反查 DNS 慢且对判断线路无用）；
  # 逐跳丢包看「最后一跳 + 连续多跳都掉」，中间单跳掉包多为路由器限 ICMP
  out=$(timeout 120 mtr -rwnc 50 -i 0.2 "$ip" 2>&1)
  printf '%s\n' "$out" | tee -a "$NB_REPORT" | sed 's/^/  /'
  _nb_report "（读法: 只有「从某跳起一直到最后一跳都丢」才算真丢包；中间孤立跳丢包是路由器限速 ICMP，无碍）"

  # 末端响应跳 = 最后一个有回应的路由器。目标禁 ping 时（家宽常态），
  # 它的丢包/RTT 就是「到家门口最后可见节点」的链路质量 —— 汇总判读
  # 靠它兜底，而不是把 ICMP 被禁误报成严重丢包
  # 报告行列序: hop.|-- IP Loss% Snt Last Avg Best Wrst StDev
  parsed=$(printf '%s\n' "$out" | awk '
    /^ *[0-9]+\.\|--/ {
      host = $2; loss = $3; sub(/%$/, "", loss)
      if (host != "???" && loss + 0 < 100) {
        ip = host; l = loss; avg = $6; best = $7; wrst = $8; sd = $9
      }
    }
    END { if (ip != "") printf "%s %s %s %s %s %s", ip, l, best, avg, wrst, sd }')
  if [ -n "$parsed" ]; then
    read -r NB_MTR_IP NB_MTR_LOSS NB_MTR_BEST NB_MTR_AVG NB_MTR_WRST NB_MTR_STDEV <<< "$parsed"
    _nb_report "末端响应跳: ${NB_MTR_IP} 丢包 ${NB_MTR_LOSS}% / RTT avg ${NB_MTR_AVG}ms（目标禁 ping 时以此跳作链路参考）"
  fi
}

# ── 回程路由 / 运营商线路（nexttrace）─────────────────
_nb_route(){
  local ip="$1" nt

  _nb_section "回程路由 / 运营商线路（nexttrace）"
  nt=$(_nb_nexttrace_bin)
  if [ -z "$nt" ]; then
    echo -e "  ${Y}nexttrace 不可用，线路判断请参考上方 mtr 的 IP 段${N}"
    _nb_report "nexttrace 不可用；线路判断参考上方 mtr 各跳 IP 段"
    return 1
  fi

  echo -e "  ${D}约 30-60 秒（联网查 ASN/归属地库）...${N}"
  # 每跳 1 次查询足够识别线路；输出带 ANSI 色，落报告前清洗
  timeout 150 "$nt" -q 1 "$ip" 2>&1 | _nb_strip_ansi | tee -a "$NB_REPORT" | sed 's/^/  /'
  _nb_report "（读法: 回程进大陆 59.43.*=电信 CN2, 202.97.*=电信 163；国际段 59.43 但国内段出现 202.97 = CN2 GT，全程 59.43 直落省网 = CN2 GIA；AS4837/AS9929 联通；AS9808/CMIN2 移动）"
}

# ── 实测 TCP 流内核采样（ss -ti）──────────────────────
# 家宽路由器普遍禁 WAN ping，ICMP 测不出 RTT/丢包/MTU；但 iperf 测试期间
# VPS ⇄ 家宽之间有真实 TCP 流 —— 从内核取这条流的 srtt/重传率/MSS/pmtu，
# 禁 ping 也测得准（重传率 ≈ VPS→家方向的真实丢包率）。
# 后台每 2s 采样、每次只留字节数最大的连接一行；bytes_acked 单调递增，
# 收尾时全文件取最大值即「数据量最大连接的最后一次采样」。若用户从家里
# SSH 连 VPS，采样也会扫到 SSH 连接，但 iperf 15s 就传几百 MB，必然胜出
_nb_tcp_probe_start(){
  local ip="$1" parent_pid=$$

  # 上一轮异常中断残留的采样器：先清掉再起新的
  [ -n "$NB_TCP_PROBE_PID" ] && kill "$NB_TCP_PROBE_PID" 2>/dev/null
  [ -n "$NB_TCP_PROBE_FILE" ] && rm -f "$NB_TCP_PROBE_FILE"

  NB_TCP_PROBE_FILE=$(mktemp)
  (
    # 双保险防孤儿：主脚本退出即停 + 最长 1 小时自灭
    n=0
    while [ "$n" -lt 1800 ] && kill -0 "$parent_pid" 2>/dev/null; do
      ss -tin dst "$ip" 2>/dev/null | awk '
        /rtt:/ {
          ba = 0
          for (i = 1; i <= NF; i++)
            if ($i ~ /^bytes_acked:/) ba = substr($i, 13) + 0
          if (ba >= best_ba) { best_ba = ba; best = $0 }
        }
        END { if (best != "") print best }
      ' >> "$NB_TCP_PROBE_FILE" 2>/dev/null
      sleep 2
      n=$((n + 1))
    done
  ) &
  NB_TCP_PROBE_PID=$!
}

# 停止采样并解析出 NB_TCP_*。幂等：trap 收尾和正常流程都会调，只生效一次
_nb_tcp_probe_stop(){
  local parsed

  [ -n "$NB_TCP_PROBE_PID" ] || return 0
  kill "$NB_TCP_PROBE_PID" 2>/dev/null || true
  wait "$NB_TCP_PROBE_PID" 2>/dev/null || true
  NB_TCP_PROBE_PID=""

  # 空字段用 "-" 占位，防止 printf 输出双空格被 read 折叠导致错位赋值
  parsed=$(awk '
    /rtt:/ {
      ba = 0
      for (i = 1; i <= NF; i++)
        if ($i ~ /^bytes_acked:/) ba = substr($i, 13) + 0
      if (ba >= best_ba) { best_ba = ba; best = $0 }
    }
    END {
      if (best == "") exit
      n = split(best, f, /[[:space:]]+/)
      rtt = ""; mss = "-"; pmtu = "-"; ret = 0; segs = 0
      for (i = 1; i <= n; i++) {
        if (f[i] ~ /^rtt:/)           rtt = substr(f[i], 5)
        else if (f[i] ~ /^mss:/)      mss = substr(f[i], 5)
        else if (f[i] ~ /^pmtu:/)     pmtu = substr(f[i], 6)
        else if (f[i] ~ /^segs_out:/) segs = substr(f[i], 10) + 0
        else if (f[i] ~ /^retrans:/)  { ret = f[i]; sub(/^retrans:[0-9]+\//, "", ret); ret += 0 }
      }
      if (rtt == "") exit
      split(rtt, r, "/")
      if (r[2] == "") r[2] = "-"
      printf "%s %s %s %s %s %s", r[1], r[2], mss, pmtu, ret, segs
    }' "$NB_TCP_PROBE_FILE" 2>/dev/null)
  rm -f "$NB_TCP_PROBE_FILE"
  NB_TCP_PROBE_FILE=""

  [ -n "$parsed" ] || return 0
  read -r NB_TCP_RTT NB_TCP_RTTVAR NB_TCP_MSS NB_TCP_PMTU NB_TCP_RETRANS NB_TCP_SEGS <<< "$parsed"
  [ "$NB_TCP_RTTVAR" = "-" ] && NB_TCP_RTTVAR=""
  [ "$NB_TCP_MSS" = "-" ] && NB_TCP_MSS=""
  [ "$NB_TCP_PMTU" = "-" ] && NB_TCP_PMTU=""
}

# 把采样结果写入报告（在带宽小节之后调用）。无有效样本时静默跳过
_nb_tcp_probe_report(){
  local target="$1" oh=40 est="" rate=""

  [ -n "$NB_TCP_RTT" ] || return 0

  # MSS 折算路径 MTU：v4 = MSS + 20 IP + 20 TCP；v6 = MSS + 40 IPv6 + 20 TCP。
  # 内核 pmtu 缓存起始就是本机路由 MTU，仅在收到 ICMP need-frag 后下调，
  # 中间 ICMP 被滤时会虚高 —— 取 min(MSS 折算, pmtu) 更接近真实
  case "$target" in *:*) oh=60 ;; esac
  if [ -n "$NB_TCP_MSS" ]; then
    est=$((NB_TCP_MSS + oh))
    [ -n "$NB_TCP_PMTU" ] && [ "$NB_TCP_PMTU" -lt "$est" ] && est="$NB_TCP_PMTU"
  elif [ -n "$NB_TCP_PMTU" ]; then
    est="$NB_TCP_PMTU"
  fi
  [ -n "$est" ] && NB_TCP_MTU_EST="$est"

  if [ "${NB_TCP_SEGS:-0}" -gt 0 ] 2>/dev/null; then
    rate=$(awk -v r="$NB_TCP_RETRANS" -v s="$NB_TCP_SEGS" 'BEGIN { printf "%.3f", r * 100 / s }')
  fi

  _nb_report ""
  _nb_report "◆ iperf 期间实测 TCP 流内核状态（ss -ti 采样，取数据量最大的连接）:"
  _nb_report "RTT srtt/rttvar : ${NB_TCP_RTT} / ${NB_TCP_RTTVAR:-?} ms"
  _nb_report "重传            : ${NB_TCP_RETRANS:-0} / ${NB_TCP_SEGS:-?} 段${rate:+ (${rate}%，≈ VPS→家方向真实丢包率)}"
  _nb_report "MSS / 内核 pmtu : ${NB_TCP_MSS:-?} / ${NB_TCP_PMTU:-?}${est:+ → 估算路径 MTU ≈ ${est}}"
  _nb_report "（读法: 真实 TCP 流的内核统计，不受目标禁 ping 影响；RTT/丢包/MTU 优先信这里）"

  echo ""
  echo -e "  ${B}实测 TCP 流${N}: RTT ${C}${NB_TCP_RTT}ms${N} | 重传率 ${C}${rate:-?}%${N} | 估算路径 MTU ${C}${est:-?}${N}"
}

# ── 带宽 / UDP：模式 A —— VPS 起服务端，家里跑客户端 ──
# VPS 单侧无法测「到家里」的真实带宽，必须家里有一端配合；此模式最通用：
# 家里任意 Windows/Mac/手机装个 iperf3 客户端即可，无需公网端口转发
# 服务端模式收尾：停 iperf3 + 撤防火墙。用 done 标记做成幂等 —— 正常流程和
# Ctrl+C / SSH 掉线的 trap 都会调它，防火墙规则已被持久化，绝不能留成后门端口
_nb_iperf_server_teardown(){
  local pid="$1" port="$2"
  [ -n "$_NB_TEARDOWN_DONE" ] && return 0
  _NB_TEARDOWN_DONE=1
  _nb_tcp_probe_stop
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo ""
  echo -e "${Y}==> 停止 iperf3 服务端并撤销临时防火墙放行...${N}"
  node_revoke_firewall_for_mode "$port" tcp dualstack
  node_revoke_firewall_for_mode "$port" udp dualstack
}

_nb_iperf_server_mode(){
  local ip="$1" port input vps_ip log pid=""

  if ! command -v iperf3 >/dev/null 2>&1; then
    echo -e "  ${Y}iperf3 未安装（依赖安装失败），无法带宽测试${N}"
    return 1
  fi

  while true; do
    read -p "  iperf3 监听端口 (回车默认 ${NETBENCH_IPERF_PORT_DEFAULT}): " input
    input="${input:-$NETBENCH_IPERF_PORT_DEFAULT}"
    if ! validate_port "$input"; then
      echo -e "  ${R}端口无效，需为 1-65535 之间的整数${N}"
      continue
    fi
    if check_port_in_use "$input"; then
      echo -e "  ${R}端口 ${input} 已被占用，请换一个${N}"
      continue
    fi
    port="$input"
    break
  done

  case "$ip" in
    *:*) vps_ip=$(detect_primary_ipv6) ;;
    *)   vps_ip=$(detect_primary_ipv4) ;;
  esac

  echo ""
  echo -e "${Y}==> 临时放行防火墙并启动 iperf3 服务端...${N}"
  node_apply_firewall_for_mode "$port" tcp dualstack
  node_apply_firewall_for_mode "$port" udp dualstack

  log=$(mktemp)
  # --forceflush: 结果实时落盘；极老版本不认此参数 → 秒退，去掉重试一次
  iperf3 -s -p "$port" --forceflush > "$log" 2>&1 &
  pid=$!
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    iperf3 -s -p "$port" > "$log" 2>&1 &
    pid=$!
    sleep 1
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    echo -e "  ${R}iperf3 服务端启动失败:${N}"
    sed 's/^/    /' "$log"
    rm -f "$log"
    node_revoke_firewall_for_mode "$port" tcp dualstack
    node_revoke_firewall_for_mode "$port" udp dualstack
    return 1
  fi

  echo ""
  echo -e "  ${G}服务端已就绪${N}。请在${B}家里的电脑${N}（连这条宽带）依次执行："
  render_divider
  echo -e "  ${C}iperf3 -c ${vps_ip} -p ${port} -R -t 15 -P 4${N}"
  echo -e "      ${D}↑ 下载方向（VPS → 家），最常用${N}"
  echo -e "  ${C}iperf3 -c ${vps_ip} -p ${port} -t 15 -P 4${N}"
  echo -e "      ${D}↑ 上传方向（家 → VPS）${N}"
  echo -e "  ${C}iperf3 -c ${vps_ip} -p ${port} -R -u -b 200M -t 10${N}"
  echo -e "      ${D}↑ UDP 下载方向丢包/抖动；200M 请改成你家下行带宽的 8 成${N}"
  echo -e "  ${C}iperf3 -c ${vps_ip} -p ${port} -u -b 30M -t 10${N}"
  echo -e "      ${D}↑ UDP 上传方向；30M 请改成你家上行带宽的 8 成${N}"
  render_divider
  echo -e "  ${Y}· 带 -R 的两条（下载方向），真实结果只打印在家里的屏幕上 —— 尤其 UDP${N}"
  echo -e "  ${Y}  的丢包/抖动，请把家里终端的输出也复制进给 AI 的内容里${N}"
  echo -e "  ${D}· Windows 装法: winget install iperf3，或 iperf.fr 下载解压后在该目录执行${N}"
  echo -e "  ${D}· 手机可用「HE.NET Network Tools」等含 iperf3 的 App${N}"
  echo -e "  ${D}· 云服务器(阿里/腾讯/AWS 等)还需在控制台安全组放行 ${port} 的 TCP+UDP${N}"
  echo ""
  # 等待期间后台采样真实 TCP 流（禁 ping 时的 RTT/丢包/MTU 数据源）
  _nb_tcp_probe_start "$ip"
  # 等待期间被 Ctrl+C / 掉线打断也要收尾（trap 里变量此刻已定型，直接展开）
  _NB_TEARDOWN_DONE=""
  # shellcheck disable=SC2064
  trap "_nb_iperf_server_teardown '$pid' '$port'; trap - INT TERM HUP" INT TERM HUP
  read -p "  家里全部测完后按回车收尾（自动停服务端并把结果写入报告）..." _
  trap - INT TERM HUP

  _nb_iperf_server_teardown "$pid" "$port"

  _nb_section "带宽 / UDP（iperf3，VPS 服务端视角）"
  if grep -q "Accepted connection" "$log" 2>/dev/null; then
    cat "$log" >> "$NB_REPORT"
    tail -n 40 "$log" | sed 's/^/  /'
    _nb_report "（读法: TCP 看 Bitrate；UDP 家→VPS 方向看本报告 receiver 行的 Lost/Total；UDP VPS→家(-R) 在本报告只有 sender 行，其 0% 只代表已发出、不代表真实丢包，真实丢包/抖动见家庭侧客户端屏幕输出）"
    echo -e "  ${G}带宽结果已写入报告${N}"
  else
    echo -e "  ${Y}未检测到家庭侧客户端连接，带宽部分留空${N}"
    _nb_report "（未检测到家庭侧 iperf3 客户端连接：可能云安全组未放行 ${port}，或家里未执行命令）"
  fi
  _nb_tcp_probe_report "$ip"
  rm -f "$log"
}

# ── 带宽 / UDP：模式 B —— 家里有 iperf3 服务端，全自动 ──
# 适合软路由/NAS 常驻 iperf3 -s 并做了端口转发的进阶用户；此模式还能顺带
# 测「满载下延迟」（bufferbloat），这是普通测速脚本给不了的关键调参数据
_nb_iperf_client_mode(){
  local ip="$1" port input bw udp_bw
  local idle_out load_avg ping_pid ping_tmp

  if ! command -v iperf3 >/dev/null 2>&1; then
    echo -e "  ${Y}iperf3 未安装（依赖安装失败），无法带宽测试${N}"
    return 1
  fi

  while true; do
    read -p "  家里 iperf3 服务端端口 (回车默认 5201): " input
    input="${input:-5201}"
    if validate_port "$input"; then
      port="$input"
      break
    fi
    echo -e "  ${R}端口无效，需为 1-65535 之间的整数${N}"
  done

  while true; do
    read -p "  家宽下行带宽 (Mbps，决定 UDP 打流速率，回车默认 300): " bw
    bw="${bw:-300}"
    case "$bw" in
      *[!0-9]*|???????*) echo -e "  ${R}必须为正整数 (1-10000)${N}"; continue ;;
    esac
    bw=$((10#$bw))
    if [ "$bw" -lt 1 ] || [ "$bw" -gt 10000 ]; then
      echo -e "  ${R}范围 1-10000 Mbps${N}"
      continue
    fi
    break
  done
  # UDP 按带宽 8 成打流：打满会自己制造丢包，测出来的就不是线路真实损耗了
  udp_bw=$((bw * 8 / 10))
  [ "$udp_bw" -lt 10 ] && udp_bw=10
  [ "$udp_bw" -gt 1000 ] && udp_bw=1000

  _nb_section "带宽 / UDP（iperf3，家庭侧为服务端）"

  echo -e "  ${D}连通性预检...${N}"
  if ! timeout 8 iperf3 -c "$ip" -p "$port" -t 1 >/dev/null 2>&1; then
    echo -e "  ${R}连不上家里的 iperf3 服务端（${ip}:${port}）${N}"
    echo -e "  ${D}请确认: 家里已运行 iperf3 -s；路由器已把该端口转发到该设备；其防火墙放行${N}"
    _nb_report "iperf3 连接失败（${ip}:${port} 不可达），带宽未测"
    return 1
  fi

  # 空载 RTT 基线：完整测评里 ping 套件已给出；带宽单测时快速补测 10 发
  if [ -z "$NB_RTT_AVG" ]; then
    idle_out=$(_nb_ping "$ip" -c 10 -i 0.2 -W 1)
    NB_RTT_AVG=$(printf '%s\n' "$idle_out" | _nb_parse_rtt | awk '{print $2}')
  fi

  echo -e "  ${D}① TCP 下载方向（VPS→家）4 并发 × 15s，同步采样满载延迟...${N}"
  # TCP 测试期间后台采样真实流内核状态（禁 ping 时的 RTT/丢包/MTU 数据源）
  _nb_tcp_probe_start "$ip"
  ping_tmp=$(mktemp)
  _nb_ping "$ip" -c 70 -i 0.2 -W 1 > "$ping_tmp" &
  ping_pid=$!
  _nb_report "◆ TCP VPS→家（家庭下载方向），4 并发 × 15s:"
  timeout 40 iperf3 -c "$ip" -p "$port" -t 15 -P 4 2>&1 \
    | tee -a "$NB_REPORT" | grep -E "SUM|error|busy" | sed 's/^/  /'
  wait "$ping_pid" 2>/dev/null || true
  load_avg=$(_nb_parse_rtt < "$ping_tmp" | awk '{print $2}')
  rm -f "$ping_tmp"

  echo -e "  ${D}② TCP 上传方向（家→VPS）4 并发 × 15s...${N}"
  _nb_report ""
  _nb_report "◆ TCP 家→VPS（家庭上传方向），4 并发 × 15s:"
  timeout 40 iperf3 -c "$ip" -p "$port" -R -t 15 -P 4 2>&1 \
    | tee -a "$NB_REPORT" | grep -E "SUM|error|busy" | sed 's/^/  /'
  _nb_tcp_probe_stop

  echo -e "  ${D}③ UDP 打流 ${udp_bw}Mbps × 10s（丢包/抖动）...${N}"
  _nb_report ""
  _nb_report "◆ UDP VPS→家 @ ${udp_bw}Mbps × 10s（看 Lost/Total 与 Jitter）:"
  timeout 30 iperf3 -c "$ip" -p "$port" -u -b "${udp_bw}M" -t 10 2>&1 \
    | tee -a "$NB_REPORT" | tail -n 4 | sed 's/^/  /'

  if [ -n "$load_avg" ] && [ -n "$NB_RTT_AVG" ]; then
    echo ""
    echo -e "  满载延迟: 空载 avg ${C}${NB_RTT_AVG}ms${N} → 满载 avg ${C}${load_avg}ms${N}"
    _nb_report ""
    _nb_report "满载下延迟: 空载 avg ${NB_RTT_AVG}ms → 满载 avg ${load_avg}ms（差值大 = 缓冲膨胀 bufferbloat，需调小缓冲或换 BBR）"
  fi
  _nb_tcp_probe_report "$ip"
}

_nb_iperf_wizard(){
  local ip="$1" ans

  echo ""
  echo -e "  ${B}带宽 / UDP 丢包测试（iperf3，需家里一端配合）${N}"
  render_menu_item 1 "VPS 起服务端，家里电脑跑命令 ${D}(通用，推荐)${N}"
  render_menu_item 2 "家里已有 iperf3 服务端 ${D}(软路由/NAS + 端口转发，全自动)${N}"
  render_menu_item 0 "跳过带宽测试"
  render_divider
  read -p "  请选择: " ans
  case "$ans" in
    1) _nb_iperf_server_mode "$ip" ;;
    2) _nb_iperf_client_mode "$ip" ;;
    *)
      _nb_report ""
      _nb_report "（本次未做 iperf3 带宽/UDP 测试）"
      ;;
  esac
}

# ── 关键指标汇总 + 简单判读 ───────────────────────────
_nb_summary(){
  local target="$1" big_txt note mtu_txt loss_txt rtt_console rtt_src

  [ -n "$NB_BIG_LOSS" ] && big_txt="${NB_BIG_LOSS}%" || big_txt="未测"

  _nb_section "关键指标汇总"
  _nb_report "目标: ${target}"

  # RTT 来源优先级: ICMP 直测 > iperf 真实 TCP 流 > mtr 末端响应跳。
  # 家宽禁 ping 是常态，后两者专为这种场景兜底 —— 不能因为 ICMP 被禁
  # 就把汇总写成「无数据」甚至误判成线路丢包
  if [ -n "$NB_RTT_AVG" ]; then
    rtt_src="ICMP 直测"
    _nb_report "RTT min/avg/max/mdev : ${NB_RTT_MIN:-?} / ${NB_RTT_AVG} / ${NB_RTT_MAX:-?} / ${NB_RTT_MDEV:-?} ms (${rtt_src})"
    rtt_console="${C}${NB_RTT_MIN:-?} / ${NB_RTT_AVG} / ${NB_RTT_MAX:-?}${N} ms ${D}(min/avg/max, 抖动 ${NB_RTT_MDEV:-?})${N}"
  elif [ -n "$NB_TCP_RTT" ]; then
    rtt_src="iperf 真实 TCP 流, 目标禁 ping"
    _nb_report "RTT srtt/rttvar      : ${NB_TCP_RTT} / ${NB_TCP_RTTVAR:-?} ms (${rtt_src})"
    rtt_console="${C}${NB_TCP_RTT}${N} ms ${D}(TCP srtt, rttvar ${NB_TCP_RTTVAR:-?})${N}"
  elif [ -n "$NB_MTR_AVG" ]; then
    rtt_src="mtr 末端响应跳 ${NB_MTR_IP}, 目标禁 ping"
    _nb_report "RTT best/avg/wrst/stdev : ${NB_MTR_BEST} / ${NB_MTR_AVG} / ${NB_MTR_WRST} / ${NB_MTR_STDEV} ms (${rtt_src})"
    rtt_console="${C}${NB_MTR_BEST} / ${NB_MTR_AVG} / ${NB_MTR_WRST}${N} ms ${D}(mtr 末端跳, 抖动 ${NB_MTR_STDEV})${N}"
  else
    rtt_src=""
    _nb_report "RTT min/avg/max/mdev : ? / ? / ? / ? ms"
    rtt_console="${C}?${N}"
  fi

  case "$NB_LOSS" in
    100|100.*) loss_txt="ICMP 全无响应（目标禁 ping，非线路丢包）" ;;
    *)         loss_txt="${NB_LOSS:-?}%" ;;
  esac
  _nb_report "小包丢包 (100 发)    : ${loss_txt}"
  _nb_report "大包 1400B 丢包      : ${big_txt}"

  if [ -n "$NB_PMTU" ]; then
    mtu_txt="$NB_PMTU"
  elif [ -n "$NB_TCP_MTU_EST" ]; then
    mtu_txt="≈ ${NB_TCP_MTU_EST}（由实测 TCP 流 MSS/pmtu 折算）"
  else
    mtu_txt="未测"
  fi
  _nb_report "路径 MTU             : ${mtu_txt}"

  render_info_line "RTT" "$rtt_console"
  render_info_line "丢包" "${C}${loss_txt}${N} ${D}(大包 ${big_txt})${N}"
  render_info_line "路径 MTU" "${C}${mtu_txt}${N}"

  if [ -n "$NB_LOSS" ]; then
    case "$NB_LOSS" in
      100|100.*)
        # 修复：以前这里会掉进「严重丢包(>=3%)，调参收益有限」的误判，
        # 与前文「大概率是路由器禁 ping」自相矛盾。现按数据源分级下结论：
        # 真实 TCP 流重传率（最准）> mtr 末端响应跳 > 提示开 WAN ping
        if [ "${NB_TCP_SEGS:-0}" -gt 0 ] 2>/dev/null; then
          note=$(awk -v r="${NB_TCP_RETRANS:-0}" -v s="$NB_TCP_SEGS" 'BEGIN {
            p = r * 100 / s
            if (p < 0.1)     printf "目标禁 ping（非线路丢包）；实测 TCP 流重传率 %.3f%%，链路干净", p
            else if (p < 1)  printf "目标禁 ping；实测 TCP 流重传率 %.3f%%，轻微丢包，属可用范围", p
            else             printf "目标禁 ping；实测 TCP 流重传率 %.2f%%，丢包明显，调参侧重抗丢包", p
          }')
        elif [ -n "$NB_MTR_IP" ]; then
          note=$(awk -v l="$NB_MTR_LOSS" -v ip="$NB_MTR_IP" 'BEGIN {
            if (l + 0 <= 1) printf "目标禁 ping（非线路丢包）；mtr 末端响应跳 %s 丢包 %s%%，链路本身干净", ip, l
            else            printf "目标禁 ping；mtr 末端响应跳 %s 丢包 %s%%（也可能是该跳限速 ICMP），建议开「允许 WAN ping」或补跑 iperf 后再下结论", ip, l
          }')
        else
          note="目标禁 ping 且无 TCP/mtr 回退数据，建议路由器开「允许 WAN ping」后重测"
        fi
        ;;
      *)
        note=$(awk -v l="$NB_LOSS" 'BEGIN {
          if (l == 0)      print "无丢包，链路干净"
          else if (l < 1)  print "轻微丢包(<1%)，属正常波动"
          else if (l < 3)  print "明显丢包(1-3%)，晚高峰大概率更差，调参侧重抗丢包"
          else             print "严重丢包(>=3%)，先考虑线路/时段问题，调参收益有限"
        }')
        ;;
    esac
    _nb_report "判读: ${note}"
    echo -e "  ${D}判读: ${note}${N}"
  fi
  if [ -n "$NB_LOSS" ] && [ -n "$NB_BIG_LOSS" ]; then
    note=$(awk -v s="$NB_LOSS" -v b="$NB_BIG_LOSS" 'BEGIN {
      if (b - s >= 3) print "大包丢包显著高于小包 → 疑似 MTU/分片受限，隧道类协议务必下调 MTU"
    }')
    if [ -n "$note" ]; then
      _nb_report "判读: ${note}"
      echo -e "  ${D}判读: ${note}${N}"
    fi
  fi

  _nb_report ""
  _nb_report "── 报告结束：请把全文（从「【给 AI 的说明】」起）复制给 AI 获取调参建议 ──"
}

# ── 主流程 ────────────────────────────────────────────
# mode: full = 全部测试 + 带宽引导；quick = 跳过带宽；iperf = 只测带宽
run_netbench(){
  local mode="${1:-full}"
  local saved ssh_ip default_ip input target ans src_label reachable=1

  if ! require_root; then return 1; fi

  render_section_header "本地链路测评（VPS ⇄ 家宽）"
  echo -e "  ${D}实测 VPS 到「你家公网 IP」的延迟/抖动/丢包/回程线路/MTU/带宽，${N}"
  echo -e "  ${D}生成纯文本报告，整段复制给 AI 即可辅助调参${N}"
  echo ""

  # ── 目标 IP：上次保存 > 当前 SSH 来源 > 手输 ──
  saved=$(_nb_load_target)
  if [ -n "$saved" ] && ! _tcp_autotune_valid_ip "$saved"; then
    saved=""
  fi
  ssh_ip=""
  [ -n "${SSH_CLIENT:-}" ] && ssh_ip=$(printf '%s' "$SSH_CLIENT" | awk '{print $1}')
  if [ -n "$saved" ]; then
    default_ip="$saved"; src_label="上次保存"
  else
    default_ip="$ssh_ip"; src_label="当前 SSH 来源"
  fi

  while true; do
    if [ -n "$default_ip" ]; then
      echo -e "  ${B}默认目标${N} : ${C}${default_ip}${N} ${D}(${src_label})${N}"
      read -p "  家庭公网 IP (回车用默认，0 返回): " input
      [ -z "$input" ] && input="$default_ip"
    else
      read -p "  家庭公网 IP (IPv4/IPv6，0 返回): " input
    fi
    [ "$input" = "0" ] && return 0
    if ! _tcp_autotune_valid_ip "$input"; then
      echo -e "  ${R}不是合法的 IPv4/IPv6 地址${N}"
      continue
    fi
    case "$input" in
      *:*) is_private_ipv6 "$input" && echo -e "  ${Y}⚠ 这是内网/链路本地地址，结果不能代表公网链路${N}" ;;
      *)   is_private_ipv4 "$input" && echo -e "  ${Y}⚠ 这是内网地址，请用家里的公网出口 IP（百度搜「IP」可查）${N}" ;;
    esac
    target="$input"
    break
  done
  _nb_save_target "$target"

  echo ""
  _nb_ensure_tools || true
  [ "$mode" != "iperf" ] && { _nb_ensure_nexttrace || true; }

  NB_REPORT="${NETBENCH_REPORT_PREFIX}-$(date +%Y%m%d-%H%M%S).txt"
  : > "$NB_REPORT" || {
    echo -e "${R}无法写入报告文件 ${NB_REPORT}${N}"
    pause_screen
    return 1
  }
  NB_LOSS=""; NB_RTT_MIN=""; NB_RTT_AVG=""; NB_RTT_MAX=""; NB_RTT_MDEV=""
  NB_BIG_LOSS=""; NB_PMTU=""
  NB_MTR_IP=""; NB_MTR_LOSS=""; NB_MTR_BEST=""; NB_MTR_AVG=""; NB_MTR_WRST=""; NB_MTR_STDEV=""
  NB_TCP_RTT=""; NB_TCP_RTTVAR=""; NB_TCP_MSS=""; NB_TCP_PMTU=""
  NB_TCP_RETRANS=""; NB_TCP_SEGS=""; NB_TCP_MTU_EST=""
  NB_TCP_PROBE_PID=""; NB_TCP_PROBE_FILE=""

  _nb_sysinfo "$target"

  if [ "$mode" != "iperf" ]; then
    _nb_ping_suite "$target" || reachable=0
    [ "$reachable" = "1" ] && _nb_mtu_probe "$target"
    _nb_mtr "$target"
    _nb_route "$target"
  fi

  case "$mode" in
    full)  _nb_iperf_wizard "$target" ;;
    iperf)
      _nb_iperf_wizard "$target"
      ;;
  esac

  [ "$mode" != "iperf" ] && _nb_summary "$target"
  cleanup_old_backups "${NETBENCH_REPORT_PREFIX}-*.txt" 5

  echo ""
  echo -e "${G}✓ 测评完成${N}，报告: ${C}${NB_REPORT}${N}"
  read -p "  是否现在完整显示报告，方便整段复制给 AI？(Y/n): " ans
  if [ "$ans" != "n" ] && [ "$ans" != "N" ]; then
    echo ""
    render_divider
    cat "$NB_REPORT"
    render_divider
    echo -e "  ${D}↑ 从「【给 AI 的说明】」到这里全选复制即可；再次查看: cat ${NB_REPORT}${N}"
  fi
  pause_screen
}

show_netbench_report(){
  local last

  last=$(_nb_latest_report)
  if [ -z "$last" ] || [ ! -f "$last" ]; then
    echo ""
    echo -e "  ${Y}还没有测评报告，请先跑一次测评${N}"
    sleep 1
    return
  fi

  render_section_header "最近一次测评报告"
  echo -e "  ${D}${last}${N}"
  render_divider
  cat "$last"
  render_divider
  pause_screen
}

show_netbench_menu(){
  local choice last

  while true; do
    render_section_header "本地链路测评（VPS ⇄ 家宽）"
    echo -e "  ${D}测到你家 IP 的专业链路数据（通用测速脚本测不到），报告可直接喂 AI 调参${N}"
    last=$(_nb_latest_report)
    [ -n "$last" ] && echo -e "  ${D}最近报告: ${last}${N}"
    echo ""
    render_menu_item 1 "一键完整测评 ${D}(延迟/丢包/MTU/路由 + 可选带宽)${N}"
    render_menu_item 2 "快速测评 ${D}(不含带宽，约 2 分钟)${N}"
    render_menu_item 3 "仅带宽 / UDP 测试 (iperf3)"
    render_menu_item 4 "查看最近一次报告"
    render_menu_item 0 "返回上级"
    render_divider
    read -p "  请输入序号: " choice

    case "$choice" in
      1) run_netbench full ;;
      2) run_netbench quick ;;
      3) run_netbench iperf ;;
      4) show_netbench_report ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

