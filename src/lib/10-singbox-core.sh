is_singbox_installed(){
  command -v sing-box >/dev/null 2>&1
}

ensure_sagernet_repo(){
  local pkg need=()
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

  if [ ! -s "$SAGERNET_KEYRING" ]; then
    if ! curl -fsSL --max-time 15 "$SAGERNET_KEY_URL" -o "$SAGERNET_KEYRING"; then
      echo -e "${R}下载 SagerNet GPG key 失败：$SAGERNET_KEY_URL${N}"
      rm -f "$SAGERNET_KEYRING"
      return 1
    fi
    chmod a+r "$SAGERNET_KEYRING"
  fi

  if [ ! -f "$SAGERNET_SOURCES" ]; then
    cat > "$SAGERNET_SOURCES" <<EOF
Types: deb
URIs: $SAGERNET_REPO_URI
Suites: *
Components: *
Enabled: yes
Signed-By: $SAGERNET_KEYRING
EOF
  fi

  return 0
}

install_singbox(){
  if ! ensure_sagernet_repo; then
    return 1
  fi

  # 关键：在 apt-get install 之前预写干净骨架，dpkg 看到 conffile 已存在
  # 配合 --force-confold 就不会落地 deb 自带的危险默认配置
  # （含端口 8080、固定密码 Gn1JUS14bLUHgv1cWDDp4A== 的 shadowsocks 入站）
  if ! config_ensure_skeleton; then
    echo -e "${R}写入 sing-box 配置骨架失败${N}"
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
    return 1
  fi

  if ! command -v sing-box >/dev/null 2>&1; then
    echo -e "${R}sing-box 安装后仍找不到可执行文件${N}"
    return 1
  fi

  # postinst 可能已拉起服务（虽然此时配置是空骨架，无监听）。停下来由业务流程后续 restart。
  systemctl stop sing-box >/dev/null 2>&1 || true
  return 0
}

upgrade_singbox(){
  if ! ensure_sagernet_repo; then
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
    return 1
  fi

  return 0
}

# ═══════════════════════════════════════════════════════════════════════
# Xray 附加内核管理（vless-xhttp-reality-enc 专用）
# ─────────────────────────────────────────────────────────────────────
# 为何要用 Xray：sing-box 不支持 VLESS Post-Quantum Encryption (ENC) 和
# xhttp 网络层，这两个都是 Xray 25.x 才有的新特性
# 隔离原则：独立 systemd 服务 / 独立配置 / 独立二进制路径，不污染 sing-box
# ═══════════════════════════════════════════════════════════════════════

