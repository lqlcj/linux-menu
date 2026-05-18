xray_detect_arch(){
  case "$(uname -m)" in
    x86_64|amd64)    printf '64' ;;
    aarch64|arm64)   printf 'arm64-v8a' ;;
    armv7l|armv7)    printf 'arm32-v7a' ;;
    *)               printf 'unknown' ;;
  esac
}

is_xray_installed(){
  [ -x "$XRAY_BIN_PATH" ]
}

get_current_xray_version(){
  if ! is_xray_installed; then
    return 1
  fi
  "$XRAY_BIN_PATH" version 2>/dev/null | awk '/^Xray/{print $2; exit}'
}

get_latest_xray_version(){
  local tag
  tag=$(curl -fsSL --max-time 10 "$XRAY_RELEASE_API" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
  if [ -z "$tag" ] || [ "$tag" = "null" ]; then
    tag="$XRAY_FALLBACK_VERSION"
  fi
  printf '%s' "$tag"
}

install_xray(){
  local arch tag url tmpdir tmpzip
  arch=$(xray_detect_arch)
  if [ "$arch" = "unknown" ]; then
    echo -e "${R}不支持的架构：$(uname -m)${N}"
    return 1
  fi

  # unzip 是必装依赖（Xray release 是 zip 包）
  if ! command -v unzip >/dev/null 2>&1; then
    echo -e "${Y}==> 安装 unzip...${N}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y unzip >/dev/null 2>&1 || {
      DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y unzip >/dev/null 2>&1 || {
        echo -e "${R}unzip 安装失败，请手动执行：apt install unzip${N}"
        return 1
      }
    }
  fi
  ensure_jq || return 1

  tag=$(get_latest_xray_version)
  url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${arch}.zip"
  echo -e "${Y}==> 下载 Xray 内核 ${tag} (${arch})...${N}"

  tmpdir=$(mktemp -d)
  tmpzip="${tmpdir}/xray.zip"
  if ! curl -fsSL --max-time 120 "$url" -o "$tmpzip"; then
    echo -e "${R}下载失败：$url${N}"
    rm -rf "$tmpdir"
    return 1
  fi

  if ! unzip -o "$tmpzip" -d "$tmpdir" >/dev/null 2>&1; then
    echo -e "${R}解压失败${N}"
    rm -rf "$tmpdir"
    return 1
  fi

  if [ ! -f "${tmpdir}/xray" ]; then
    echo -e "${R}解压后未找到 xray 二进制${N}"
    rm -rf "$tmpdir"
    return 1
  fi

  mkdir -p "$(dirname "$XRAY_BIN_PATH")"
  if ! install -m 0755 "${tmpdir}/xray" "$XRAY_BIN_PATH"; then
    echo -e "${R}写入 ${XRAY_BIN_PATH} 失败${N}"
    rm -rf "$tmpdir"
    return 1
  fi
  rm -rf "$tmpdir"

  local ver
  ver=$(get_current_xray_version || echo unknown)
  echo -e "${G}已安装 Xray 内核：v${ver}${N}"
  return 0
}

upgrade_xray(){
  # 与 install_xray 等价（直接覆盖二进制），单独命名是为了和 upgrade_singbox 对称
  install_xray
}

xray_install_systemd_unit(){
  if [ -f "$XRAY_SERVICE_PATH" ]; then
    return 0
  fi
  cat > "$XRAY_SERVICE_PATH" <<EOF
[Unit]
Description=${XRAY_SERVICE_NAME} (Xray-core for vless-xhttp-reality)
After=network.target nss-lookup.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=${XRAY_BIN_PATH} run -c ${XRAY_CONFIG_PATH}
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || true
  return 0
}

# Xray 配置骨架：空 inbounds + freedom direct outbound
xray_config_ensure_skeleton(){
  ensure_jq || return 1
  mkdir -p "$XRAY_DIR"
  if [ ! -f "$XRAY_CONFIG_PATH" ] || ! jq empty "$XRAY_CONFIG_PATH" >/dev/null 2>&1; then
    cat > "$XRAY_CONFIG_PATH" <<'EOF'
{
  "log": {"loglevel": "warning"},
  "inbounds": [],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"}
  ]
}
EOF
  fi
  return 0
}

xray_config_add_inbound(){
  local inbound="$1"
  ensure_jq || return 1
  xray_config_ensure_skeleton || return 1
  local tmp tag
  tag=$(printf '%s' "$inbound" | jq -r '.tag // empty' 2>/dev/null)
  if [ -z "$tag" ]; then
    echo -e "${R}内部错误：xray inbound 缺少 tag${N}"
    return 1
  fi
  tmp=$(mktemp)
  if ! jq --argjson nb "$inbound" --arg tag "$tag" '
    .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) + [$nb]
  ' "$XRAY_CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$XRAY_CONFIG_PATH"
}

xray_config_remove_inbound_by_tag(){
  local tag="$1"
  ensure_jq || return 1
  [ -f "$XRAY_CONFIG_PATH" ] || return 0
  local tmp
  tmp=$(mktemp)
  if ! jq --arg tag "$tag" '
    .inbounds = ((.inbounds // []) | map(select(.tag != $tag)))
  ' "$XRAY_CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$XRAY_CONFIG_PATH"
}

xray_config_inbound_count(){
  if [ ! -f "$XRAY_CONFIG_PATH" ] || ! command -v jq >/dev/null 2>&1; then
    printf '0'
    return
  fi
  jq '(.inbounds // []) | length' "$XRAY_CONFIG_PATH" 2>/dev/null || printf '0'
}

xray_config_check_and_restart(){
  if ! is_xray_installed; then
    echo -e "${R}xray 二进制不存在：$XRAY_BIN_PATH${N}"
    return 1
  fi
  if ! "$XRAY_BIN_PATH" run -test -c "$XRAY_CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${R}Xray 配置校验失败，下面是详细错误：${N}"
    "$XRAY_BIN_PATH" run -test -c "$XRAY_CONFIG_PATH" 2>&1 | sed 's/^/    /' || true
    return 1
  fi
  if ! systemctl restart "$XRAY_SERVICE_NAME" 2>/dev/null; then
    echo -e "${R}Xray 服务重启失败${N}"
    systemctl status "$XRAY_SERVICE_NAME" --no-pager 2>&1 | tail -20 | sed 's/^/    /' || true
    return 1
  fi
  return 0
}

# 卸载某 xhr 节点后：剩 0 个 inbound 就停服，否则校验+重启
post_uninstall_xray_step(){
  if ! is_xray_installed || [ ! -f "$XRAY_CONFIG_PATH" ]; then
    return 0
  fi
  local remain
  remain=$(xray_config_inbound_count)
  if [ "${remain:-0}" -eq 0 ]; then
    echo -e "${Y}==> 已无 Xray 节点，停止 ${XRAY_SERVICE_NAME} 服务...${N}"
    systemctl stop "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || true
    return 0
  fi
  "$XRAY_BIN_PATH" run -test -c "$XRAY_CONFIG_PATH" >/dev/null 2>&1 \
    && systemctl restart "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || true
}

