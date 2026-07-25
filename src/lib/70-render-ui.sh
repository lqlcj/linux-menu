CARD_INNER_WIDTH=52

# 计算字符串可见宽度（剥除 ANSI 颜色码）
# 直接看 UTF-8 字节头：ASCII 与 2 字节字符按 1 列、3 字节 / 4 字节按 2 列。
# 不依赖 wc -m 的 locale 行为，C / POSIX locale 下也能正确算 CJK 宽度。
# 例外：U+2500-U+27BF 这一段（box drawing / 几何 / 杂项符号 / 装饰符）
# 实际多为单倍宽，此处单独按 1 列计；其中 ✨ (U+2728) 是 emoji，仍按 2 列。
_card_visible(){
  local s
  s=$(printf '%b' "$1" | sed $'s/\x1b\\[[0-9;]*[a-zA-Z]//g')
  printf '%s' "$s" | od -An -tu1 | awk '
    BEGIN { n = 0 }
    {
      for (i = 1; i <= NF; i++) {
        b = $i + 0
        if (b < 128) { n += 1; continue }
        if (b < 192) continue
        if (b < 224) { n += 1; continue }
        if (b < 240) {
          # 3 字节 UTF-8：默认 2 列；E2 94..9B / 9C 段中的非 emoji 字符按 1 列
          if (b == 226) {
            b2 = (i + 1 <= NF) ? $(i+1) + 0 : 0
            b3 = (i + 2 <= NF) ? $(i+2) + 0 : 0
            if (b2 >= 148 && b2 <= 155) { n += 1; continue }
            if (b2 == 156) {
              # ✨ U+2728 = E2 9C A8 是 emoji，按 2 列
              if (b3 == 168) { n += 2; continue }
              n += 1; continue
            }
          }
          n += 2
          continue
        }
        n += 2
      }
    }
    END { print n }
  '
}

# 卡片空白行
render_card_blank(){
  echo -e "  ${L}│${N}$(printf '%*s' "$CARD_INNER_WIDTH" '')${L}│${N}"
}

# 拼接 N 个 ─（避开 tr ' ' '─'：多数 tr 实现只能单字节替换，会把 ─ 截成 0xE2 乱码）
_card_dash_fill(){
  local n="$1" out="" i
  for ((i = 0; i < n; i++)); do out+='─'; done
  printf '%s' "$out"
}

# 卡片普通行（自动右侧补空格到内宽）
render_card_line(){
  local content="$1" visible pad
  visible=$(_card_visible "$content")
  pad=$((CARD_INNER_WIDTH - visible))
  [ "$pad" -lt 0 ] && pad=0
  echo -e "  ${L}│${N}${content}$(printf '%*s' "$pad" '')${L}│${N}"
}

# 卡片顶部：╭─★ TITLE ─...─ RIGHT ★─╮
render_card_top(){
  local title="$1" right="$2"
  local title_w right_w fill_w fill
  title_w=$(_card_visible "$title")
  right_w=$(_card_visible "$right")
  # 内宽 = 1(─) + 1(★) + 1(空) + title + 1(空) + N + 1(空) + right + 1(空) + 1(★) + 1(─)
  fill_w=$((CARD_INNER_WIDTH - 8 - title_w - right_w))
  [ "$fill_w" -lt 1 ] && fill_w=1
  fill=$(_card_dash_fill "$fill_w")
  echo -e "  ${L}╭─${N}${C}★${N} ${title} ${L}${fill}${N} ${right} ${C}★${N}${L}─╮${N}"
}

# 卡片底部
render_card_bottom(){
  local fill
  fill=$(_card_dash_fill "$CARD_INNER_WIDTH")
  echo -e "  ${L}╰${fill}╯${N}"
}

# ─── 节点行（占两排：状态/端口/IP + 网络方向；未安装时只占一排） ───
render_node_card_block(){
  local type="$1" label
  case "$type" in
    reality) label="Reality    " ;;   # 11 可见列：7 + 4 sp
    hy2)     label="Hysteria2  " ;;   # 11 可见列：9 + 2 sp
    anytls)  label="AnyTLS     " ;;   # 11 可见列：6 + 5 sp
    tuic)    label="TUIC v5    " ;;   # 11 可见列：7 + 4 sp
    ss2022)  label="SS-2022    " ;;   # 11 可见列：7 + 4 sp
    xhr)     label="VLESS-XHR  " ;;   # 11 可见列：9 + 2 sp（vless-xhttp-reality）
    *)       label=$(printf '%-11s' "$type") ;;
  esac

  if ! node_installed "$type"; then
    render_card_line " ${C}✦${N} ${C}${label}${N}${D}◌${N} ${Y}未安装${N}"
    return
  fi

  local port ip mode_label
  port=$(get_node_value "$type" Port 2>/dev/null || true)
  ip=$(get_node_value "$type" IP 2>/dev/null || true)
  mode_label=$(describe_install_mode "$(get_node_value "$type" Mode 2>/dev/null || echo ipv4)")

  # 让短端口和长端口的 IP 起始列尽量对齐
  local port_len gap gap_str
  port_len=${#port}
  gap=$((7 - port_len))
  [ "$gap" -lt 1 ] && gap=1
  gap_str=$(printf '%*s' "$gap" '')

  # 附加信息：HY2 端口跳跃 / SS-2022 谨慎标记 / XHR 量子加密
  local extra=""
  if [ "$type" = "hy2" ]; then
    local hop_v
    hop_v=$(get_node_value "$type" PortHop 2>/dev/null || echo 0)
    [ "$hop_v" = "1" ] && extra="  ${C}+hop${N}"
  elif [ "$type" = "ss2022" ]; then
    extra="  ${R}[谨慎]${N}"
  elif [ "$type" = "xhr" ]; then
    extra="  ${C}+xray${N}"
  fi

  # 第一行：✦ + 协议名 + ● + :端口 + IP + 附加
  render_card_line " ${C}✦${N} ${C}${label}${N}${G}●${N} :${C}${port:-?}${N}${gap_str}${C}${ip:-?}${N}${extra}"
  # 第二行：网络方向（缩进对齐到第一行的状态列）
  render_card_line "              ${D}${mode_label}${N}"

}

# TCP 调优行（单排）
render_tcp_card_line(){
  local label="TCP 调优   "  # 11 可见列
  if [ ! -f "$TCP_TUNING_PATH" ]; then
    render_card_line " ${C}✧${N} ${C}${label}${N}${D}未启用${N}"
    return
  fi
  local profile_line region="" mem_tier="" region_label="" mem_label=""
  profile_line=$(awk '/^# leyili-profile:/ { print; exit }' "$TCP_TUNING_PATH" 2>/dev/null)
  if [ -n "$profile_line" ]; then
    region=$(printf '%s\n' "$profile_line" | sed -n 's/.*region=\([a-z0-9-]\+\).*/\1/p')
    mem_tier=$(printf '%s\n' "$profile_line" | sed -n 's/.*mem_tier=\([a-z0-9]\+\).*/\1/p')
    case "$region" in
      hk)      region_label="香港" ;;
      jp)      region_label="日本" ;;
      us-west) region_label="美西" ;;
      us-west-100m) region_label="美西 100M" ;;
      eu)      region_label="欧洲" ;;
      custom)  region_label="自定义" ;;
    esac
    case "$mem_tier" in
      512m) mem_label="512M" ;;
      1g) mem_label="1G"  ;;
      2g) mem_label="2G"  ;;
      4g) mem_label="4G"  ;;
      8g) mem_label="8G+" ;;
    esac
  fi
  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  if [ -n "$region_label" ] && [ -n "$mem_label" ]; then
    render_card_line " ${C}✧${N} ${C}${label}${N}${C}${region_label}/${mem_label}${N} ${D}·${N} ${D}cc=${cc}${N}"
  else
    render_card_line " ${C}✧${N} ${C}${label}${N}${D}cc=${cc}${N}"
  fi
}

# QUIC 调优行（单排）
render_quic_card_line(){
  local label="QUIC 调优  "  # 11 可见列
  if [ ! -f "$QUIC_TUNING_PATH" ]; then
    render_card_line " ${C}✧${N} ${C}${label}${N}${D}未启用${N}"
    return
  fi
  local profile_line region="" mem_tier="" region_label="" mem_label=""
  profile_line=$(awk '/^# leyili-quic-profile:/ { print; exit }' "$QUIC_TUNING_PATH" 2>/dev/null)
  if [ -n "$profile_line" ]; then
    region=$(printf '%s\n' "$profile_line" | sed -n 's/.*region=\([a-z0-9-]\+\).*/\1/p')
    mem_tier=$(printf '%s\n' "$profile_line" | sed -n 's/.*mem_tier=\([a-z0-9]\+\).*/\1/p')
    case "$region" in
      hk)      region_label="香港" ;;
      jp)      region_label="日本" ;;
      us-west) region_label="美西" ;;
      eu)      region_label="欧洲" ;;
    esac
    case "$mem_tier" in
      512m) mem_label="512M" ;;
      1g) mem_label="1G"  ;;
      2g) mem_label="2G"  ;;
      4g) mem_label="4G"  ;;
      8g) mem_label="8G+" ;;
    esac
  fi
  local rmem_max rmem_label="?"
  rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "")
  if [ -n "$rmem_max" ] && [ "$rmem_max" -gt 0 ] 2>/dev/null; then
    rmem_label="$((rmem_max / 1024 / 1024))M"
  fi
  if [ -n "$region_label" ] && [ -n "$mem_label" ]; then
    render_card_line " ${C}✧${N} ${C}${label}${N}${C}${region_label}/${mem_label}${N} ${D}·${N} ${D}rmem=${rmem_label}${N}"
  else
    render_card_line " ${C}✧${N} ${C}${label}${N}${D}rmem=${rmem_label}${N}"
  fi
}

# initcwnd 行（单排）
render_initcwnd_card_line(){
  local label="initcwnd   "  # 11 可见列
  if ! command -v ip >/dev/null 2>&1; then
    render_card_line " ${C}✧${N} ${C}${label}${N}${D}未知 (ip 命令缺失)${N}"
    return
  fi
  local route_line val persist
  route_line=$(ip route show default 2>/dev/null | head -n1)
  if [ -z "$route_line" ]; then
    render_card_line " ${C}✧${N} ${C}${label}${N}${D}无默认路由${N}"
    return
  fi
  val=$(printf '%s\n' "$route_line" | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i == "initcwnd") { print $(i + 1); exit }
    }
  }')
  if [ -z "$val" ]; then
    render_card_line " ${C}✧${N} ${C}${label}${N}${D}未设置${N}"
    return
  fi
  if [ -f "$INITCWND_SERVICE_PATH" ] \
     && systemctl is-enabled "$(basename "$INITCWND_SERVICE_PATH")" >/dev/null 2>&1; then
    persist="${D}(已持久化)${N}"
  else
    persist="${Y}(未持久化)${N}"
  fi
  render_card_line " ${C}✧${N} ${C}${label}${N}${C}${val}${N}  ${persist}"
}

# 主菜单卡片：标题栏 + 协议块 + 系统调优行
render_realm_card_line(){
  local label="Realm 中转 "  # 11 可见列
  if ! realm_is_installed; then
    return  # 未安装时不显示这一行（保持卡片简洁）
  fi
  local ver status status_str count
  ver=$(realm_get_version 2>/dev/null | head -n1)
  [ -z "$ver" ] && ver="?"
  status=$(systemctl is-active realm 2>/dev/null | head -n1)
  [ -z "$status" ] && status="未知"
  case "$status" in
    active)              status_str="${G}运行中${N}" ;;
    activating|reloading) status_str="${Y}${status}${N}" ;;
    *)                   status_str="${R}${status}${N}" ;;
  esac
  count=$(realm_count_rules 2>/dev/null | head -n1)
  [ -z "$count" ] && count=0
  render_card_line " ${C}✧${N} ${C}${label}${N}${C}v${ver}${N} ${D}·${N} ${status_str} ${D}·${N} ${C}${count}${N} ${D}条规则${N}"
}

# sing-box 内核版本行：当前版本 vs 最新稳定版（GitHub releases/latest 只返回稳定版）
# 最新版走带缓存的查询，首页反复刷新也不会每次都打 GitHub。
render_singbox_version_card_line(){
  local label="内核版本   "  # 11 可见列
  if ! is_singbox_installed; then
    return  # 未安装时标题栏已显示「未安装」，此处不再重复
  fi
  local cur latest
  cur=$(get_current_singbox_version 2>/dev/null)
  [ -z "$cur" ] && cur="?"
  latest=$(get_latest_singbox_version_cached 2>/dev/null)
  if [ -z "$latest" ]; then
    render_card_line " ${C}✦${N} ${C}${label}${N}${C}v${cur}${N} ${D}·${N} ${D}最新版待联网${N}"
  elif [ "$cur" = "$latest" ]; then
    render_card_line " ${C}✦${N} ${C}${label}${N}${C}v${cur}${N} ${D}·${N} ${G}已是最新${N}"
  elif _singbox_ver_lt "$cur" "$latest"; then
    render_card_line " ${C}✦${N} ${C}${label}${N}${C}v${cur}${N} ${Y}→${N} ${G}v${latest}${N} ${Y}可升级${N}"
  else
    # 当前版本比稳定版新（装了 alpha/beta 预览版）
    render_card_line " ${C}✦${N} ${C}${label}${N}${C}v${cur}${N} ${D}·${N} ${D}稳定版 v${latest}${N}"
  fi
  render_card_blank
}

render_main_menu_card(){
  local ver status status_str title
  if is_singbox_installed; then
    ver=$(sing-box version 2>/dev/null | head -1 | awk '{print $3}')
    [ -z "$ver" ] && ver="未知"
    status=$(systemctl is-active sing-box 2>/dev/null || echo "未知")
    if [ "$status" = "active" ]; then
      status_str="${G}运行中${N}"
    else
      status_str="${R}${status}${N}"
    fi
  else
    ver="未安装"
    status_str="${Y}未安装${N}"
  fi

  title="${B}${C}管理菜单${N} ${D}·${N} ${C}v${ver}${N}"
  render_card_top "$title" "$status_str"
  render_card_blank
  render_singbox_version_card_line
  render_node_card_block reality
  render_card_blank
  render_node_card_block hy2
  render_card_blank
  render_node_card_block anytls
  render_card_blank
  render_node_card_block tuic
  if node_installed ss2022; then
    render_card_blank
    render_node_card_block ss2022
  fi
  if node_installed xhr; then
    render_card_blank
    render_node_card_block xhr
  fi
  render_card_blank
  render_tcp_card_line
  render_quic_card_line
  render_initcwnd_card_line
  render_realm_card_line
  render_card_blank
  render_card_bottom
}

