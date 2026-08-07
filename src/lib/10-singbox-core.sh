is_singbox_installed(){
  command -v sing-box >/dev/null 2>&1
}

sagernet_repo_state_get(){
  local key="$1"
  [ -f "$SAGERNET_REPO_STATE" ] || return 1
  grep -m1 "^${key}=" "$SAGERNET_REPO_STATE" | cut -d= -f2-
}

sagernet_repo_capture_state(){
  local source_existed=0 key_existed=0 tmp
  [ -f "$SAGERNET_REPO_STATE" ] && return 0
  ensure_leyili_state_dir || return 1

  [ -e "$SAGERNET_SOURCES" ] && source_existed=1
  [ -e "$SAGERNET_KEYRING" ] && key_existed=1
  # 兼容旧版脚本：带明确托管标记的 sources 及其配套 key 视为脚本创建。
  if grep -Fq '# Managed by Leyili' "$SAGERNET_SOURCES" 2>/dev/null; then
    source_existed=0
    key_existed=0
  fi

  tmp=$(mktemp "${SAGERNET_REPO_STATE}.tmp.XXXXXX") || return 1
  if ! printf 'SourceExisted=%s\nKeyExisted=%s\n' "$source_existed" "$key_existed" > "$tmp" \
     || ! chmod 600 "$tmp" \
     || ! mv -f -- "$tmp" "$SAGERNET_REPO_STATE"; then
    rm -f -- "$tmp"
    return 1
  fi
}

sagernet_repo_restore(){
  local source_existed key_existed rc=0
  source_existed=$(sagernet_repo_state_get SourceExisted 2>/dev/null || true)
  key_existed=$(sagernet_repo_state_get KeyExisted 2>/dev/null || true)

  case "$source_existed" in
    0)
      rm -f -- "$SAGERNET_SOURCES" "${SAGERNET_SOURCES}.leyili-original" || rc=1
      ;;
    1)
      if [ -e "${SAGERNET_SOURCES}.leyili-original" ]; then
        managed_file_restore "$SAGERNET_SOURCES" || rc=1
      fi
      ;;
    *)
      if [ -e "${SAGERNET_SOURCES}.leyili-original" ]; then
        managed_file_restore "$SAGERNET_SOURCES" || rc=1
      elif grep -Fq '# Managed by Leyili' "$SAGERNET_SOURCES" 2>/dev/null; then
        rm -f -- "$SAGERNET_SOURCES" || rc=1
      fi
      ;;
  esac

  case "$key_existed" in
    0)
      rm -f -- "$SAGERNET_KEYRING" "${SAGERNET_KEYRING}.leyili-original" || rc=1
      ;;
    1)
      if [ -e "${SAGERNET_KEYRING}.leyili-original" ]; then
        managed_file_restore "$SAGERNET_KEYRING" || rc=1
      fi
      ;;
    *)
      # 无所有权记录时宁可保留未知 key；只有明确备份存在才恢复。
      if [ -e "${SAGERNET_KEYRING}.leyili-original" ]; then
        managed_file_restore "$SAGERNET_KEYRING" || rc=1
      fi
      ;;
  esac

  if [ "$rc" -eq 0 ]; then
    rm -f -- "$SAGERNET_REPO_STATE" || rc=1
  fi
  return "$rc"
}

ensure_sagernet_repo(){
  local pkg need=() tmp_key actual_fpr installed_fpr="" key_existed
  local source_txn tmp_sources
  for pkg in curl gnupg ca-certificates; do
    command -v "$pkg" >/dev/null 2>&1 || dpkg -s "$pkg" >/dev/null 2>&1 || need+=("$pkg")
  done
  if [ "${#need[@]}" -gt 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" >/dev/null 2>&1; then
      echo -e "${R}依赖安装失败：${need[*]}${N}"
      return 1
    fi
  fi

  mkdir -p /etc/apt/keyrings || { echo -e "${R}无法创建 /etc/apt/keyrings${N}"; return 1; }
  sagernet_repo_capture_state || { echo -e "${R}无法记录 SagerNet 仓库文件所有权${N}"; return 1; }

  if [ -s "$SAGERNET_KEYRING" ]; then
    installed_fpr=$(gpg --batch --show-keys --with-colons --fingerprint "$SAGERNET_KEYRING" 2>/dev/null \
      | awk -F: '$1 == "fpr" {print toupper($10); exit}')
  fi
  if [ "$installed_fpr" != "$SAGERNET_KEY_FINGERPRINT" ]; then
    tmp_key=$(mktemp) || return 1
    if ! curl --proto '=https' --tlsv1.2 -fsSL --max-time 20 "$SAGERNET_KEY_URL" -o "$tmp_key"; then
      echo -e "${R}下载 SagerNet GPG key 失败：$SAGERNET_KEY_URL${N}"
      rm -f -- "$tmp_key"
      return 1
    fi
    actual_fpr=$(gpg --batch --show-keys --with-colons --fingerprint "$tmp_key" 2>/dev/null \
      | awk -F: '$1 == "fpr" {print toupper($10); exit}')
    if [ "$actual_fpr" != "$SAGERNET_KEY_FINGERPRINT" ]; then
      echo -e "${R}SagerNet GPG key 指纹不匹配，拒绝安装${N}"
      echo -e "  预期: ${C}${SAGERNET_KEY_FINGERPRINT}${N}"
      echo -e "  实际: ${C}${actual_fpr:-无法解析}${N}"
      rm -f -- "$tmp_key"
      return 1
    fi
    key_existed=$(sagernet_repo_state_get KeyExisted 2>/dev/null || echo 0)
    if [ "$key_existed" = "1" ] && [ -e "$SAGERNET_KEYRING" ] \
       && [ ! -e "${SAGERNET_KEYRING}.leyili-original" ]; then
      cp -a -- "$SAGERNET_KEYRING" "${SAGERNET_KEYRING}.leyili-original" \
        || { rm -f -- "$tmp_key"; return 1; }
    fi
    if ! atomic_replace_file "$tmp_key" "$SAGERNET_KEYRING" 644; then
      rm -f -- "$tmp_key"
      return 1
    fi
    rm -f -- "$tmp_key"
  fi

  source_txn=$(managed_file_transaction_begin "$SAGERNET_SOURCES" 'Managed by Leyili|URIs:[[:space:]]*https://deb\.sagernet\.org/') \
    || return 1
  tmp_sources=$(mktemp "${SAGERNET_SOURCES}.tmp.XXXXXX") || {
    managed_file_transaction_rollback "$SAGERNET_SOURCES" "$source_txn"
    return 1
  }
  if ! cat > "$tmp_sources" <<EOF
# Managed by Leyili
Types: deb
URIs: $SAGERNET_REPO_URI
Suites: *
Components: *
Enabled: yes
Signed-By: $SAGERNET_KEYRING
EOF
  then
    rm -f -- "$tmp_sources"
    managed_file_transaction_rollback "$SAGERNET_SOURCES" "$source_txn"
    return 1
  fi
  if ! chmod 644 "$tmp_sources" \
     || ! mv -f -- "$tmp_sources" "$SAGERNET_SOURCES"; then
    rm -f -- "$tmp_sources"
    managed_file_transaction_rollback "$SAGERNET_SOURCES" "$source_txn"
    return 1
  fi
  managed_file_transaction_commit "$source_txn"

  return 0
}

install_singbox(){
  local txn
  if ! ensure_sagernet_repo; then
    return 1
  fi

  txn=$(config_transaction_begin singbox-install) || return 1

  # 关键：在 apt-get install 之前预写干净骨架，dpkg 看到 conffile 已存在
  # 配合 --force-confold 就不会落地 deb 自带的危险默认配置
  # （含端口 8080、固定密码 Gn1JUS14bLUHgv1cWDDp4A== 的 shadowsocks 入站）
  if ! config_ensure_skeleton; then
    echo -e "${R}写入 sing-box 配置骨架失败${N}"
    config_transaction_rollback "$txn"
    return 1
  fi

  if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
    echo -e "${Y}apt-get update 出错，继续尝试安装...${N}"
  fi

  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        sing-box; then
    echo -e "${R}apt-get install sing-box 失败${N}"
    config_transaction_rollback "$txn"
    return 1
  fi

  if ! command -v sing-box >/dev/null 2>&1; then
    echo -e "${R}sing-box 安装后仍找不到可执行文件${N}"
    config_transaction_rollback "$txn"
    return 1
  fi

  # postinst 可能已拉起服务（虽然此时配置是空骨架，无监听）。停下来由业务流程后续 restart。
  if systemctl is-active --quiet sing-box 2>/dev/null \
     && ! systemctl stop sing-box >/dev/null 2>&1; then
    echo -e "${R}sing-box 安装后自动启动，但无法安全停止${N}"
    config_transaction_rollback "$txn"
    return 1
  fi
  config_transaction_commit "$txn"
  return 0
}

upgrade_singbox(){
  local old_pkg_version txn upgrade_ok=0
  if ! ensure_sagernet_repo; then
    return 1
  fi

  old_pkg_version=$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)
  txn=$(config_transaction_begin singbox-upgrade) || {
    echo -e "${R}升级前配置快照失败${N}"
    return 1
  }
  if [ -f "$CONFIG_PATH" ] && ! sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${R}当前配置本身未通过校验，已拒绝升级${N}"
    config_transaction_rollback "$txn"
    return 1
  fi

  if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
    echo -e "${Y}apt-get update 出错，继续尝试升级...${N}"
  fi

  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        sing-box; then
    echo -e "${R}apt-get install --only-upgrade sing-box 失败${N}"
    config_transaction_rollback "$txn"
    return 1
  fi

  if [ -f "$CONFIG_PATH" ]; then
    if [ -f "$txn/service.active" ]; then
      config_check_and_restart && upgrade_ok=1
    elif sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
      if ! systemctl is-active --quiet sing-box 2>/dev/null \
         || systemctl stop sing-box >/dev/null 2>&1; then
        upgrade_ok=1
      fi
    fi
  else
    upgrade_ok=1
  fi

  if [ "$upgrade_ok" = "1" ]; then
    config_transaction_commit "$txn"
    return 0
  fi

  echo -e "${R}新版未通过配置/服务健康检查，开始回滚${N}"
  if [ -n "$old_pkg_version" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      "sing-box=${old_pkg_version}" >/dev/null 2>&1 || \
      echo -e "${Y}旧版本 ${old_pkg_version} 已不在仓库，请人工安装后再启动服务${N}"
  fi
  config_transaction_rollback "$txn"
  return 1
}
