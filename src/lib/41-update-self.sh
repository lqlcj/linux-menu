get_latest_singbox_version(){
  local ver=""
  ver=$(curl -fsSL --max-time 5 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name":[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)
  printf '%s' "$ver"
}

# 带缓存的「最新稳定版」查询：首页每次刷新都会调用它，不能每次都打 GitHub。
# 命中且未过期 → 直接读缓存；过期/不存在 → 拉一次并写回。
# 拉取失败时写空内容作为「负缓存」，短 TTL 内不再重试，避免每次刷新都卡 5 秒。
get_latest_singbox_version_cached(){
  local now mtime age content ttl ver cache_ok=0 tmp_cache
  if [ ! -L "$LEYILI_CACHE_DIR" ] && ! [ -L "$SINGBOX_LATEST_CACHE" ]; then
    if [ "$(id -u)" -eq 0 ]; then
      ensure_private_dir "$LEYILI_CACHE_DIR" 700 >/dev/null 2>&1 && cache_ok=1
    elif [ -d "$LEYILI_CACHE_DIR" ] && [ -r "$SINGBOX_LATEST_CACHE" ]; then
      cache_ok=1
    fi
  fi
  if [ "$cache_ok" = "1" ] && [ -f "$SINGBOX_LATEST_CACHE" ]; then
    now=$(date +%s 2>/dev/null || echo 0)
    mtime=$(stat -c %Y "$SINGBOX_LATEST_CACHE" 2>/dev/null || echo 0)
    age=$((now - mtime))
    content=$(cat "$SINGBOX_LATEST_CACHE" 2>/dev/null)
    if [ -n "$content" ]; then ttl="$SINGBOX_LATEST_TTL"; else ttl="$SINGBOX_LATEST_NEG_TTL"; fi
    if [ "$now" -gt 0 ] && [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; then
      printf '%s' "$content"
      return 0
    fi
  fi
  ver=$(get_latest_singbox_version)
  if [ "$cache_ok" = "1" ] && [ -w "$LEYILI_CACHE_DIR" ]; then
    tmp_cache=$(mktemp "${SINGBOX_LATEST_CACHE}.tmp.XXXXXX" 2>/dev/null || true)
    if [ -n "$tmp_cache" ]; then
      printf '%s' "$ver" > "$tmp_cache" 2>/dev/null \
        && chmod 600 "$tmp_cache" 2>/dev/null \
        && mv -f -- "$tmp_cache" "$SINGBOX_LATEST_CACHE" 2>/dev/null \
        || rm -f -- "$tmp_cache"
    fi
  fi
  printf '%s' "$ver"
}

# 版本严格小于比较：$1 < $2 返回 0（真）。依赖 sort -V（coreutils，Debian/Ubuntu 自带）。
_singbox_ver_lt(){
  [ "$1" = "$2" ] && return 1
  local first
  first=$(printf '%s\n%s\n' "$1" "$2" | sort -V 2>/dev/null | head -1)
  [ "$first" = "$1" ]
}

get_current_singbox_version(){
  if ! command -v sing-box >/dev/null 2>&1; then
    printf '%s' ""
    return
  fi
  sing-box version 2>/dev/null | head -1 | awk '{print $3}'
}

# 当前 sing-box 主.次版本是否 >= 给定阈值
# 用法：sb_version_at_least 1.12  → 0 表示满足，1 表示不满足
sb_version_at_least(){
  local required="$1" cur major_req minor_req major_cur minor_cur
  cur=$(get_current_singbox_version)
  [ -n "$cur" ] || return 1
  cur="${cur#v}"
  major_req=$(printf '%s' "$required" | cut -d. -f1)
  minor_req=$(printf '%s' "$required" | cut -d. -f2)
  major_cur=$(printf '%s' "$cur" | cut -d. -f1)
  minor_cur=$(printf '%s' "$cur" | cut -d. -f2)
  case "$major_cur" in ''|*[!0-9]*) return 1 ;; esac
  case "$minor_cur" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$major_cur" -gt "$major_req" ]; then return 0; fi
  if [ "$major_cur" -eq "$major_req" ] && [ "$minor_cur" -ge "$minor_req" ]; then return 0; fi
  return 1
}

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

view_singbox_config(){
  if ! require_singbox_installed; then
    return 1
  fi

  if [ ! -f "$CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到配置文件：$CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "  ${B}${C}$CONFIG_PATH${N}"
  render_divider
  if command -v jq >/dev/null 2>&1; then
    jq . "$CONFIG_PATH" 2>/dev/null || cat "$CONFIG_PATH"
  else
    cat "$CONFIG_PATH"
  fi
  pause_screen
}

edit_singbox_config(){
  local editor_bin=""
  local backup_path=""
  local txn="" rollback="" rollback_ok=1 editor_rc=0

  if ! require_root; then
    return 1
  fi
  if ! require_singbox_installed; then
    return 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    echo ""
    echo -e "${R}未找到配置文件：$CONFIG_PATH${N}"
    pause_screen
    return 1
  fi

  editor_bin="${EDITOR:-}"
  if [ -z "$editor_bin" ] || ! command -v "$editor_bin" >/dev/null 2>&1; then
    for candidate in nano vim vi; do
      if command -v "$candidate" >/dev/null 2>&1; then
        editor_bin="$candidate"
        break
      fi
    done
  fi

  if [ -z "$editor_bin" ]; then
    echo ""
    echo -e "${R}未找到可用的编辑器（nano/vim/vi），请先安装或设置 EDITOR${N}"
    pause_screen
    return 1
  fi

  backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  if ! cp "$CONFIG_PATH" "$backup_path"; then
    echo -e "${R}配置备份失败${N}"
    pause_screen
    return 1
  fi

  txn=$(config_transaction_begin manual-edit) || {
    echo -e "${R}配置事务快照失败${N}"
    pause_screen
    return 1
  }

  "$editor_bin" "$CONFIG_PATH" || editor_rc=$?
  if [ "$editor_rc" -ne 0 ]; then
    echo -e "${Y}编辑器退出码为 ${editor_rc}，继续以配置校验结果为准${N}"
  fi

  if ! sing-box check -c "$CONFIG_PATH"; then
    echo ""
    read -p "  配置校验失败，是否回滚到编辑前备份？(Y/n): " rollback
    if [ "$rollback" != "n" ] && [ "$rollback" != "N" ]; then
      config_transaction_rollback "$txn" || rollback_ok=0
      if [ "$rollback_ok" -eq 1 ]; then
        echo -e "${G}已回滚配置与服务状态${N}"
      else
        echo -e "${R}回滚未完全成功，请立即检查；事务快照已保留${N}"
      fi
    else
      config_transaction_commit "$txn"
      echo -e "${Y}已保留有问题的配置（备份：$backup_path）${N}"
    fi
    pause_screen
    return 1
  fi

  if ! systemctl restart sing-box; then
    config_transaction_rollback "$txn" || rollback_ok=0
    if [ "$rollback_ok" -eq 1 ]; then
      echo -e "${R}服务重启失败，已回滚配置与服务状态${N}"
    else
      echo -e "${R}服务重启失败，且回滚未完全成功，请立即检查 sing-box${N}"
    fi
    pause_screen
    return 1
  fi

  config_transaction_commit "$txn"

  cleanup_old_backups "${CONFIG_PATH}.bak.*" 5 \
    || echo -e "${Y}旧配置备份轮转失败，本次配置已正常生效${N}" >&2

  echo ""
  echo -e "${G}配置已更新并重启服务${N}"
  echo -e "  备份文件: ${C}$backup_path${N}"
  pause_screen
}

cleanup_config_backups(){
  local count=0
  local confirm=""

  if ! require_root; then
    return 1
  fi

  count=$(ls -1 "${CONFIG_PATH}".bak.* 2>/dev/null | wc -l)
  count=$((count + $(ls -1 "${CONFIG_PATH}".*.bak 2>/dev/null | wc -l)))
  count=$((count + $(ls -1 "${SSHD_CONFIG_PATH}".bak.* 2>/dev/null | wc -l)))
  count=$((count + $(ls -1 "${FAIL2BAN_JAIL_PATH}".bak.* 2>/dev/null | wc -l)))
  count=$((count + $(ls -1 "${SCRIPT_PATH}".bak.* 2>/dev/null | wc -l)))

  echo ""
  echo -e "  ${B}当前备份文件${N}"
  ls -1 "${CONFIG_PATH}".bak.* "${CONFIG_PATH}".*.bak \
        "${SSHD_CONFIG_PATH}".bak.* "${FAIL2BAN_JAIL_PATH}".bak.* \
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

  if ! cleanup_old_backups "${CONFIG_PATH}.bak.*" "$keep" \
     || ! cleanup_old_backups "${CONFIG_PATH}.*.bak" "$keep" \
     || ! cleanup_old_backups "${SSHD_CONFIG_PATH}.bak.*" "$keep" \
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

# ─── 首次安装入口 ─────────────────────────────────────
