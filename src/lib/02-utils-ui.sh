register_sb_command(){
  local source_path="" src_real dst_real

  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    source_path="${BASH_SOURCE[0]}"
  elif [ -n "${0:-}" ] && [ -f "$0" ]; then
    source_path="$0"
  fi

  # 已经位于 SCRIPT_PATH（用户用 sb 命令再次进入菜单）：什么都不做
  # 否则 cp same-file 必失败，会回落到 curl 重新下载，导致每次运行都偷偷自动更新
  if [ -n "$source_path" ] && [ -f "$SCRIPT_PATH" ]; then
    src_real=$(readlink -f "$source_path" 2>/dev/null || printf '%s' "$source_path")
    dst_real=$(readlink -f "$SCRIPT_PATH" 2>/dev/null || printf '%s' "$SCRIPT_PATH")
    if [ -n "$src_real" ] && [ "$src_real" = "$dst_real" ]; then
      chmod +x "$SCRIPT_PATH" 2>/dev/null || true
      return 0
    fi
  fi

  if [ -n "$source_path" ]; then
    if cp "$source_path" "$SCRIPT_PATH" 2>/dev/null && chmod +x "$SCRIPT_PATH" 2>/dev/null; then
      return 0
    fi
  fi

  if [ -n "$SELF_INSTALL_URL" ]; then
    if curl -fsSL --max-time 15 "$SELF_INSTALL_URL" -o "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"; then
      return 0
    fi
  fi

  echo -e "${Y}警告：${N} 无法自动安装 ${B}${APP_NAME}${N} 到 ${SCRIPT_PATH}。"
  echo -e "  请从本地文件运行脚本，或在安装前设置 ${B}SELF_INSTALL_URL${N}。"
  return 1
}

pause_screen(){
  echo ""
  read -p "按回车返回..." _
}

notify_invalid_choice(){
  echo ""
  echo -e "  ${Y}无效选项，请重新输入${N}"
  sleep 1
}

render_divider(){
  echo -e "  ${D}──────────────────────────────────────────────────────${N}"
}

render_brand_banner(){
  # 星空横幅：· ✦ · ─ · ✧ · ─ 重复 3 次 + · ✦ ·，共 53 可见列
  local sky="" i
  for ((i = 0; i < 3; i++)); do
    sky+="${L}·${N} ${C}✦${N} ${L}·${N} ${L}─${N} ${L}·${N} ${C}✧${N} ${L}·${N} ${L}─${N} "
  done
  sky+="${L}·${N} ${C}✦${N} ${L}·${N}"
  echo ""
  echo -e "  ${sky}"
  echo -e "          ✨  ${B}${W}${APP_NAME}${N}  ${C}Linux Menu${N}  ✨"
  echo -e "  ${sky}"
}

render_section_header(){
  local title="$1"

  clear
  render_brand_banner
  echo -e "  ${B}${C}›  ${title}${N}"
  render_divider
}

render_menu_item(){
  local key="$1"
  local label="$2"

  echo -e "  ${D}│${N}  ${Y}${B}${key}${N}  ${label}"
}

render_info_line(){
  local label="$1"
  local value="$2"

  printf "  ${L}●${N} %-10s : %b\n" "$label" "$value"
}

validate_port(){
  local port="$1"

  case "$port" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac

  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

sanitize_sni(){
  printf '%s' "$1" | tr -d '\r\n' | tr -d '"'
}

