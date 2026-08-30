# ─── 脚本正文校验 ─────────────────────────────────────
# 自更新和入口安装都要判断「这坨下载内容是不是 Leyili 脚本」，
# 两处必须用同一套判据，否则改了一处另一处会悄悄放行。

leyili_payload_size_ok(){
  local size
  size=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
  case "$size" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$size" -ge "$SELF_PAYLOAD_MIN_BYTES" ] && [ "$size" -le "$SELF_PAYLOAD_MAX_BYTES" ]
}

leyili_payload_has_markers(){
  local file="$1"

  [ -f "$file" ] || return 1
  head -n 1 "$file" | grep -Eq '^#!/(usr/)?bin/(env )?bash' || return 1
  grep -Fq 'APP_NAME="Leyili"' "$file" || return 1
  grep -Fq 'show_menu' "$file" || return 1
  grep -Fq 'acquire_global_lock' "$file"
}

# 从 SELF_INSTALL_URL 取一份脚本正文到 $1，逐项校验后才算成功。
# 校验强度与自更新一致：HTTPS、大小、结构标记、Bash 语法；
# 配了 SELF_INSTALL_SHA256 时再强制哈希匹配。
fetch_leyili_payload(){
  local dest="$1" actual_sha expect_sha

  [ -n "$dest" ] || return 1
  case "$SELF_INSTALL_URL" in
    https://*) ;;
    *) return 1 ;;
  esac

  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --max-time 30 \
      "$SELF_INSTALL_URL" -o "$dest" || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only --secure-protocol=TLSv1_2 -q -T 30 -O "$dest" "$SELF_INSTALL_URL" || return 1
  else
    return 1
  fi

  leyili_payload_size_ok "$dest" || return 1
  leyili_payload_has_markers "$dest" || return 1
  bash -n "$dest" >/dev/null 2>&1 || return 1

  if [ -n "$SELF_INSTALL_SHA256" ]; then
    actual_sha=$(sha256sum "$dest" 2>/dev/null | awk '{print tolower($1)}')
    expect_sha=$(printf '%s' "$SELF_INSTALL_SHA256" | tr 'A-F' 'a-f')
    [ -n "$actual_sha" ] || return 1
    [ "$actual_sha" = "$expect_sha" ] || return 1
  fi
  return 0
}

# 管道运行时 stdin 是脚本自身，bash 读完就是 EOF：菜单的 read 会立刻返回空值，
# 一路掉进「无效选项」死循环。能拿到控制终端就把 stdin 接回去。
# 先在子 shell 里试开一次，避免 /dev/tty 不可用时把当前 shell 的 stdin 弄坏。
attach_terminal_stdin(){
  [ -t 0 ] && return 0
  ( exec 0</dev/tty ) >/dev/null 2>&1 || return 1
  exec 0</dev/tty || return 1
  [ -t 0 ]
}

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
      echo -e "  ${Y}原因：${N}脚本以管道 / 进程替换方式运行，没有可复制的本地文件，"
      echo -e "        改从 ${C}${SELF_INSTALL_URL}${N} 自动获取也失败了"
      echo -e "        （网络不通、地址不可用，或内容未通过大小 / 结构 / 语法校验）。"
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

# 当前进程可以复制的本地脚本文件；管道 / 进程替换运行时为空字符串。
detect_self_source_path(){
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    printf '%s' "${BASH_SOURCE[0]}"
    return 0
  fi
  if [ -n "${0:-}" ] && [ -f "$0" ]; then
    printf '%s' "$0"
    return 0
  fi
  printf '%s' ""
}

register_sb_command(){
  local source_path="" src_real dst_real tmp_file="" fail_reason="write" bin_dir

  source_path=$(detect_self_source_path)

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

  if [ -L "$SCRIPT_PATH" ]; then
    echo -e "${Y}警告：拒绝覆盖符号链接脚本入口 ${SCRIPT_PATH}${N}" >&2
    return 1
  fi

  if [ -n "$source_path" ]; then
    if ! bash -n "$source_path" >/dev/null 2>&1; then
      fail_reason="syntax"
    elif atomic_replace_file "$source_path" "$SCRIPT_PATH" 755; then
      sb_registration_done
      return $?
    fi
  else
    fail_reason="pipe"
  fi

  # 到这里要么在管道里跑（没有本地文件可复制），要么本地文件已损坏。
  # 唯一剩下的来源是脚本内置的 SELF_INSTALL_URL —— 用户刚刚执行的就是这个地址的内容，
  # 再取一次装进入口不引入新的信任对象，所以这里不再强求 SELF_INSTALL_SHA256；
  # 校验仍然逐项做足，配了固定哈希则继续强制匹配。
  # fail_reason=write 时本地文件本身没问题，只是写不进去（只读挂载 / 磁盘已满），
  # 重新下载同一份内容也救不了，直接跳过这次网络请求。
  bin_dir=$(dirname -- "$SCRIPT_PATH")
  if [ "$fail_reason" != "write" ] && { [ "$(id -u)" -eq 0 ] || [ -w "$bin_dir" ]; }; then
    if tmp_file=$(mktemp); then
      if fetch_leyili_payload "$tmp_file" \
         && atomic_replace_file "$tmp_file" "$SCRIPT_PATH" 755; then
        rm -f -- "$tmp_file"
        sb_registration_done
        return $?
      fi
      rm -f -- "$tmp_file"
    fi
  fi

  # 非 root 且目标目录写不进去时，权限才是真正的拦路虎，比「管道运行」更贴近事实。
  if [ "$fail_reason" != "syntax" ] && [ "$(id -u)" -ne 0 ] && [ ! -w "$bin_dir" ]; then
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
