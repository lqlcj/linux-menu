update_self_script(){
  local tmp_file=""
  local confirm=""
  local actual_sha="" size="" stage_file="" backup_path=""

  if ! require_root; then
    return 1
  fi

  if [ -z "$SELF_INSTALL_URL" ]; then
    echo ""
    echo -e "${R}未配置 SELF_INSTALL_URL，无法自更新${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${Y}==> 下载最新脚本...${N}"
  tmp_file=$(mktemp)
  trap 'rm -f "$tmp_file"' RETURN
  case "$SELF_INSTALL_URL" in
    https://*) ;;
    *)
      echo -e "${R}自更新地址必须使用 HTTPS：$SELF_INSTALL_URL${N}"
      pause_screen
      return 1
      ;;
  esac
  if ! curl --proto '=https' --tlsv1.2 -fsSL --max-time 30 "$SELF_INSTALL_URL" -o "$tmp_file"; then
    rm -f "$tmp_file"
    echo -e "${R}下载失败，请检查网络或 SELF_INSTALL_URL${N}"
    pause_screen
    return 1
  fi

  size=$(wc -c < "$tmp_file" 2>/dev/null | tr -d ' ')
  if ! leyili_payload_size_ok "$tmp_file"; then
    echo -e "${R}新脚本大小异常（${size:-未知} 字节），已放弃更新${N}"
    pause_screen
    return 1
  fi

  if ! leyili_payload_has_markers "$tmp_file"; then
    echo -e "${R}下载内容缺少 Leyili 脚本结构标记，已放弃更新${N}"
    pause_screen
    return 1
  fi

  if ! bash -n "$tmp_file"; then
    rm -f "$tmp_file"
    echo -e "${R}新脚本语法校验失败，已放弃更新${N}"
    pause_screen
    return 1
  fi

  actual_sha=$(sha256sum "$tmp_file" 2>/dev/null | awk '{print $1}')
  if [ -n "$SELF_INSTALL_SHA256" ]; then
    if [ "$(printf '%s' "$actual_sha" | tr 'A-F' 'a-f')" != "$(printf '%s' "$SELF_INSTALL_SHA256" | tr 'A-F' 'a-f')" ]; then
      echo -e "${R}新脚本 SHA-256 不匹配，已放弃更新${N}"
      echo -e "  预期: ${C}${SELF_INSTALL_SHA256}${N}"
      echo -e "  实际: ${C}${actual_sha:-无法计算}${N}"
      pause_screen
      return 1
    fi
  fi

  if [ -f "$SCRIPT_PATH" ] && cmp -s "$tmp_file" "$SCRIPT_PATH"; then
    rm -f "$tmp_file"
    echo -e "${G}当前已是最新版本${N}"
    pause_screen
    return 0
  fi

  echo -e "  来源: ${C}$SELF_INSTALL_URL${N}"
  echo -e "  SHA-256: ${C}${actual_sha:-无法计算}${N}"
  if [ -z "$SELF_INSTALL_SHA256" ]; then
    echo -e "  ${Y}未配置 SELF_INSTALL_SHA256，来源身份无法做固定哈希校验。${N}"
    read -p "  如已人工核对上方哈希，输入 UNVERIFIED 继续: " confirm
    if [ "$confirm" != "UNVERIFIED" ]; then
      echo -e "  已取消"
      sleep 1
      return 0
    fi
  else
    read -p "  哈希校验通过，确认覆盖 ${SCRIPT_PATH}？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo -e "  已取消"
      sleep 1
      return 0
    fi
  fi
  if [ -z "$confirm" ]; then
    rm -f "$tmp_file"
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  if [ -L "$SCRIPT_PATH" ]; then
    echo -e "${R}拒绝覆盖符号链接脚本入口：${SCRIPT_PATH}${N}"
    pause_screen
    return 1
  fi
  mkdir -p -- "$(dirname -- "$SCRIPT_PATH")" || return 1
  stage_file=$(mktemp "${SCRIPT_PATH}.new.XXXXXX") || return 1
  if ! install -m 0755 "$tmp_file" "$stage_file"; then
    rm -f -- "$stage_file"
    echo -e "${R}准备新脚本失败${N}"
    pause_screen
    return 1
  fi
  if [ -f "$SCRIPT_PATH" ]; then
    backup_path="${SCRIPT_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    if ! cp -a -- "$SCRIPT_PATH" "$backup_path"; then
      rm -f -- "$stage_file"
      echo -e "${R}旧脚本备份失败，已取消覆盖${N}"
      pause_screen
      return 1
    fi
    cleanup_old_backups "${SCRIPT_PATH}.bak.*" 3 \
      || echo -e "${Y}旧脚本备份轮转失败，新版本仍会继续安装${N}" >&2
  fi

  if ! mv -f -- "$stage_file" "$SCRIPT_PATH"; then
    rm -f -- "$stage_file"
    rm -f "$tmp_file"
    echo -e "${R}原子替换 $SCRIPT_PATH 失败，旧入口保持不变${N}"
    pause_screen
    return 1
  fi
  rm -f "$tmp_file"

  echo ""
  echo -e "${G}脚本已更新，请重新运行 ${B}${COMMAND_NAME}${N}"
  pause_screen
  exit 0
}

cleanup_config_backups(){
  local count=0 keep=""
  local confirm=""

  if ! require_root; then
    return 1
  fi

  count=$((count + $(ls -1 "${SSHD_CONFIG_PATH}".bak.* 2>/dev/null | wc -l)))
  count=$((count + $(ls -1 "${FAIL2BAN_JAIL_PATH}".bak.* 2>/dev/null | wc -l)))
  count=$((count + $(ls -1 "${SCRIPT_PATH}".bak.* 2>/dev/null | wc -l)))

  echo ""
  echo -e "  ${B}当前备份文件${N}"
  ls -1 "${SSHD_CONFIG_PATH}".bak.* "${FAIL2BAN_JAIL_PATH}".bak.* \
        "${SCRIPT_PATH}".bak.* 2>/dev/null || true
  echo ""
  if [ "$count" -eq 0 ]; then
    echo -e "${Y}无需清理${N}"
    pause_screen
    return 0
  fi

  read -p "  保留最近几份备份？(默认 3): " keep
  keep="${keep:-3}"
  case "$keep" in
    ''|*[!0-9]*)
      echo -e "${R}必须为非负整数${N}"
      pause_screen
      return 1
      ;;
  esac

  read -p "  确认按此规则清理？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  if ! cleanup_old_backups "${SSHD_CONFIG_PATH}.bak.*" "$keep" \
     || ! cleanup_old_backups "${FAIL2BAN_JAIL_PATH}.bak.*" "$keep" \
     || ! cleanup_old_backups "${SCRIPT_PATH}.bak.*" "$keep"; then
    echo -e "${R}部分备份删除失败，请检查文件权限${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${G}备份已清理${N}"
  pause_screen
}
