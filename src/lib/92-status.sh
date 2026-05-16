status_format_bytes(){
  local b="${1:-0}"
  case "$b" in ''|*[!0-9]*) b=0 ;; esac
  if   [ "$b" -ge 1099511627776 ]; then awk -v n="$b" 'BEGIN{printf "%.2f TiB", n/1099511627776}'
  elif [ "$b" -ge 1073741824 ];    then awk -v n="$b" 'BEGIN{printf "%.2f GiB", n/1073741824}'
  elif [ "$b" -ge 1048576 ];       then awk -v n="$b" 'BEGIN{printf "%.2f MiB", n/1048576}'
  elif [ "$b" -ge 1024 ];          then awk -v n="$b" 'BEGIN{printf "%.2f KiB", n/1024}'
  else printf '%s B' "$b"
  fi
}

status_format_speed(){
  local bps="${1:-0}"
  case "$bps" in ''|*[!0-9]*) bps=0 ;; esac
  if   [ "$bps" -ge 1073741824 ]; then awk -v n="$bps" 'BEGIN{printf "%.2f GiB/s", n/1073741824}'
  elif [ "$bps" -ge 1048576 ];    then awk -v n="$bps" 'BEGIN{printf "%.2f MiB/s", n/1048576}'
  elif [ "$bps" -ge 1024 ];       then awk -v n="$bps" 'BEGIN{printf "%.2f KiB/s", n/1024}'
  else printf '%s B/s' "$bps"
  fi
}

status_progress_bar(){
  local pct="${1:-0}" width="${2:-22}"
  case "$pct" in ''|*[!0-9]*) pct=0 ;; esac
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ] && pct=0

  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local color="$G"
  [ "$pct" -ge 70 ] && color="$Y"
  [ "$pct" -ge 90 ] && color="$R"

  printf "${color}"
  [ "$filled" -gt 0 ] && printf '%.0s█' $(seq 1 "$filled")
  printf "${D}"
  [ "$empty" -gt 0 ] && printf '%.0s░' $(seq 1 "$empty")
  printf "${N}"
}

status_read_cpu(){
  awk '/^cpu / {
    total=$2+$3+$4+$5+$6+$7+$8+$9+$10+$11
    idle=$5+$6
    print total" "idle
    exit
  }' /proc/stat
}

status_sample_cpu(){
  local s1 s2 t1 t2 i1 i2 dt di
  s1=$(status_read_cpu); t1=${s1% *}; i1=${s1#* }
  sleep 1
  s2=$(status_read_cpu); t2=${s2% *}; i2=${s2#* }
  dt=$(( t2 - t1 ))
  di=$(( i2 - i1 ))
  if [ "$dt" -le 0 ]; then printf '0'; return; fi
  printf '%d' $(( (dt - di) * 100 / dt ))
}

status_default_iface(){
  ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}'
}

status_read_iface(){
  local iface="$1"
  awk -v key="${iface}:" '$1==key {print $2" "$10; exit}' /proc/net/dev
}

status_sample_speed(){
  local iface="$1" v rx1 tx1 rx2 tx2
  v=$(status_read_iface "$iface"); rx1=${v% *}; tx1=${v#* }
  sleep 1
  v=$(status_read_iface "$iface"); rx2=${v% *}; tx2=${v#* }
  printf '%s %s' "$(( rx2 - rx1 ))" "$(( tx2 - tx1 ))"
}

status_service_state(){
  local name="$1" bin="$2"
  if [ -n "$bin" ] && ! command -v "$bin" >/dev/null 2>&1 \
     && ! systemctl list-unit-files "${name}.service" >/dev/null 2>&1; then
    printf "${D}未安装${N}"
    return
  fi
  if systemctl is-active "$name" >/dev/null 2>&1; then
    printf "${G}running${N}"
  elif systemctl list-unit-files "${name}.service" >/dev/null 2>&1; then
    printf "${R}stopped${N}"
  else
    printf "${D}未安装${N}"
  fi
}

show_server_status(){
  render_section_header "服务器状态"

  local hostname_str distro_str kernel_str uptime_str load_str
  local cpu_model cpu_cores cpu_pct
  local mem_total mem_avail mem_used mem_pct
  local swap_total swap_free swap_used swap_pct
  local iface speeds rx tx ipv4 ipv6 tcp_count listen_count

  hostname_str=$(hostname 2>/dev/null || echo "unknown")
  kernel_str=$(uname -r 2>/dev/null || echo "unknown")
  if [ -r /etc/os-release ]; then
    distro_str=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-${NAME:-unknown}}")
  else
    distro_str="unknown"
  fi
  uptime_str=$(uptime -p 2>/dev/null | sed 's/^up //')
  [ -z "$uptime_str" ] && uptime_str=$(awk '{d=int($1/86400); h=int(($1%86400)/3600); m=int(($1%3600)/60); printf "%dd %dh %dm", d, h, m}' /proc/uptime 2>/dev/null)
  load_str=$(awk '{printf "%s, %s, %s", $1, $2, $3}' /proc/loadavg 2>/dev/null)

  cpu_model=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
  [ -z "$cpu_model" ] && cpu_model=$(awk -F': ' '/^Hardware/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
  [ -z "$cpu_model" ] && cpu_model="unknown"
  cpu_cores=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)
  [ -z "$cpu_cores" ] && cpu_cores="?"

  echo -e "  ${B}${C}›  系统${N}"
  printf "  ${L}●${N} %-10s : %s\n" "主机名"   "$hostname_str"
  printf "  ${L}●${N} %-10s : %s\n" "发行版"   "$distro_str"
  printf "  ${L}●${N} %-10s : %s\n" "内核"     "$kernel_str"
  printf "  ${L}●${N} %-10s : %s\n" "运行时长" "${uptime_str:-unknown}"
  printf "  ${L}●${N} %-10s : %s\n" "负载"     "${load_str:-unknown}"
  echo ""

  echo -e "  ${C}采样 CPU / 网络中（约 1 秒）...${N}"
  cpu_pct=$(status_sample_cpu)
  iface=$(status_default_iface)
  rx=0; tx=0
  if [ -n "$iface" ]; then
    speeds=$(status_sample_speed "$iface")
    rx=${speeds% *}; tx=${speeds#* }
  fi
  printf "\033[1A\033[2K"

  echo -e "  ${B}${C}›  CPU${N}"
  printf "  ${L}●${N} %-10s : %s × %s 核\n" "型号"   "$cpu_model" "$cpu_cores"
  printf "  ${L}●${N} %-10s : %3d%%  %s\n"  "使用率" "$cpu_pct" "$(status_progress_bar "$cpu_pct")"
  echo ""

  mem_total=$(awk '/^MemTotal:/ {print $2}'     /proc/meminfo)
  mem_avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  swap_total=$(awk '/^SwapTotal:/ {print $2}'   /proc/meminfo)
  swap_free=$(awk '/^SwapFree:/ {print $2}'     /proc/meminfo)
  : "${mem_total:=0}"; : "${mem_avail:=0}"; : "${swap_total:=0}"; : "${swap_free:=0}"
  mem_used=$(( mem_total - mem_avail ))
  swap_used=$(( swap_total - swap_free ))
  mem_pct=0;  [ "$mem_total"  -gt 0 ] && mem_pct=$((  mem_used  * 100 / mem_total  ))
  swap_pct=0; [ "$swap_total" -gt 0 ] && swap_pct=$(( swap_used * 100 / swap_total ))

  echo -e "  ${B}${C}›  内存${N}"
  printf "  ${L}●${N} %-10s : %s / %s  (%3d%%)  %s\n" "RAM" \
    "$(status_format_bytes $((mem_used*1024)))" \
    "$(status_format_bytes $((mem_total*1024)))" \
    "$mem_pct" "$(status_progress_bar "$mem_pct")"
  if [ "$swap_total" -gt 0 ]; then
    printf "  ${L}●${N} %-10s : %s / %s  (%3d%%)  %s\n" "SWAP" \
      "$(status_format_bytes $((swap_used*1024)))" \
      "$(status_format_bytes $((swap_total*1024)))" \
      "$swap_pct" "$(status_progress_bar "$swap_pct")"
  else
    printf "  ${L}●${N} %-10s : ${D}未启用${N}\n" "SWAP"
  fi
  echo ""

  echo -e "  ${B}${C}›  磁盘${N}"
  local disk_rows
  disk_rows=$(df -hP -x tmpfs -x devtmpfs -x squashfs -x overlay -x aufs 2>/dev/null \
              | awk 'NR>1 && $6 !~ /^\/(proc|sys|run|dev|var\/lib\/docker)/ {print $2"|"$3"|"$5"|"$6}')
  if [ -n "$disk_rows" ]; then
    local size used pct mount line
    while IFS='|' read -r size used pct mount; do
      [ -z "$mount" ] && continue
      pct=${pct%\%}
      case "$pct" in ''|*[!0-9]*) pct=0 ;; esac
      printf "  ${L}●${N} %-14s : %7s / %-7s  (%3d%%)  %s\n" \
        "$mount" "$used" "$size" "$pct" "$(status_progress_bar "$pct" 18)"
    done <<< "$disk_rows"
  else
    printf "  ${L}●${N} %-10s : ${D}未识别到挂载点${N}\n" "/"
  fi
  echo ""

  echo -e "  ${B}${C}›  网络${N}"
  ipv4=$(detect_primary_ipv4)
  ipv6=$(detect_primary_ipv6)
  printf "  ${L}●${N} %-10s : %s\n" "IPv4" "${ipv4:-${D}未检测到${N}}"
  printf "  ${L}●${N} %-10s : %s\n" "IPv6" "${ipv6:-${D}未检测到${N}}"
  if [ -n "$iface" ]; then
    printf "  ${L}●${N} %-10s : %s   ${G}↓${N} %s   ${C}↑${N} %s\n" \
      "实时速率" "$iface" "$(status_format_speed "$rx")" "$(status_format_speed "$tx")"
  fi
  if command -v ss >/dev/null 2>&1; then
    tcp_count=$(ss -tnH state established 2>/dev/null | wc -l)
    listen_count=$(ss -tlnH 2>/dev/null | wc -l)
    printf "  ${L}●${N} %-10s : %s   监听端口 %s\n" "TCP 连接" "$tcp_count" "$listen_count"
  fi
  echo ""

  echo -e "  ${B}${C}›  服务${N}"
  printf "  ${L}●${N} %-10s : %s\n" "sing-box" "$(status_service_state sing-box sing-box)"
  printf "  ${L}●${N} %-10s : %s\n" "realm"    "$(status_service_state realm    "$REALM_BIN_PATH")"

  pause_screen
}

