# 安装入口失败时说清原因和下一步。提示随后会被 show_menu 的 clear 抹掉，
# 所以 _entry.sh 会在进菜单前停下来等回车。
report_sb_install_failure(){
  local reason="$1"
  local bin_dir

  bin_dir=$(dirname -- "$SCRIPT_PATH")
  echo ""
  echo -e "  ${R}${B}✗ ${COMMAND_NAME} 命令未安装到 ${SCRIPT_PATH}${N}"
  case "$reason" in
    pipe)
      echo -e "  ${Y}原因：${N}脚本以管道 / 进程替换方式运行，没有可复制的本地文件。"
      echo -e "  ${Y}解决：${N}用 root 先下载为临时文件再执行："
      echo -e "    ${C}tmp_script=\$(mktemp)${N}"
      echo -e "    ${C}curl --proto '=https' --tlsv1.2 -fsSL \"${SELF_INSTALL_URL}\" -o \"\$tmp_script\"${N}"
      echo -e "    ${C}bash \"\$tmp_script\"; rm -f -- \"\$tmp_script\"${N}"
      ;;
    noroot)
      echo -e "  ${Y}原因：${N}当前用户（UID $(id -u)）无权写入 ${bin_dir}。"
      echo -e "  ${Y}解决：${N}切换到 root 再运行一次本脚本。"
      ;;
    syntax)
      echo -e "  ${Y}原因：${N}本机 bash 未通过脚本语法检查（版本过旧或文件已损坏）。"
      echo -e "  ${Y}排查：${N}${C}bash --version | head -1${N}"
      ;;
    path)
      echo -e "  ${Y}原因：${N}文件已写入，但 ${bin_dir} 不在当前 PATH 中。"
      echo -e "  ${Y}解决：${N}用绝对路径 ${C}${SCRIPT_PATH}${N} 启动，或把目录加进 PATH："
      echo -e "    ${C}echo 'export PATH=\$PATH:${bin_dir}' >> ~/.bashrc && . ~/.bashrc${N}"
      ;;
    *)
      echo -e "  ${Y}原因：${N}写入失败（只读挂载 / 磁盘已满 / 目录不可写）。"
      echo -e "  ${Y}排查：${N}${C}df -h ${bin_dir}; ls -ld ${bin_dir}${N}"
      ;;
  esac
  echo ""
}

# 文件到位不等于命令可用：PATH 里解析不到入口时，用户敲 sb 仍然是 command not found。
sb_registration_done(){
  local resolved real_resolved real_target

  hash -r 2>/dev/null || true
  resolved=$(command -v "$COMMAND_NAME" 2>/dev/null)
  if [ -n "$resolved" ]; then
    real_resolved=$(readlink -f "$resolved" 2>/dev/null || printf '%s' "$resolved")
    real_target=$(readlink -f "$SCRIPT_PATH" 2>/dev/null || printf '%s' "$SCRIPT_PATH")
    if [ "$real_resolved" = "$real_target" ]; then
      return 0
    fi
  fi
  report_sb_install_failure path
  return 1
}

register_sb_command(){
  local source_path="" src_real dst_real tmp_file="" actual_sha="" fail_reason="write"

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
      # 已可执行就不再 chmod：非 root 用 sb 进菜单时 chmod 必失败，那不是错误
      if [ -x "$SCRIPT_PATH" ] || chmod 755 "$SCRIPT_PATH" 2>/dev/null; then
        sb_registration_done
        return $?
      fi
      echo -e "${Y}警告：无法修正 ${SCRIPT_PATH} 的执行权限${N}" >&2
      return 1
    fi
  fi

  if [ -n "$source_path" ]; then
    if [ -L "$SCRIPT_PATH" ]; then
      echo -e "${Y}警告：拒绝覆盖符号链接脚本入口 ${SCRIPT_PATH}${N}" >&2
      return 1
    fi
    if ! bash -n "$source_path" >/dev/null 2>&1; then
      fail_reason="syntax"
    elif atomic_replace_file "$source_path" "$SCRIPT_PATH" 755; then
      sb_registration_done
      return $?
    fi
  else
    fail_reason="pipe"
  fi

  # 无本地源时不静默执行可变 URL。只有显式提供固定 SHA-256 才允许下载安装。
  if [ -n "$SELF_INSTALL_URL" ] && [ -n "$SELF_INSTALL_SHA256" ] \
     && [ "${SELF_INSTALL_URL#https://}" != "$SELF_INSTALL_URL" ] \
     && tmp_file=$(mktemp); then
    if curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --max-time 15 \
         "$SELF_INSTALL_URL" -o "$tmp_file" \
       && bash -n "$tmp_file" >/dev/null 2>&1; then
      actual_sha=$(sha256sum "$tmp_file" 2>/dev/null | awk '{print tolower($1)}')
      if [ -n "$actual_sha" ] \
         && [ "$actual_sha" = "$(printf '%s' "$SELF_INSTALL_SHA256" | tr 'A-F' 'a-f')" ] \
         && atomic_replace_file "$tmp_file" "$SCRIPT_PATH" 755; then
        rm -f -- "$tmp_file"
        sb_registration_done
        return $?
      fi
    fi
    rm -f -- "$tmp_file"
  fi

  if [ "$fail_reason" = "write" ] && [ "$(id -u)" -ne 0 ]; then
    fail_reason="noroot"
  fi
  report_sb_install_failure "$fail_reason"
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
