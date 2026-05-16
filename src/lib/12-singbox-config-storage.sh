require_singbox_installed(){
  if is_singbox_installed; then
    return 0
  fi

  echo ""
  echo -e "${Y}sing-box 尚未安装，请先在主菜单选择“安装 sing-box”。${N}"
  pause_screen
  return 1
}

get_info_value(){
  local key="$1"

  if [ ! -f "$INFO_PATH" ]; then
    return 1
  fi

  grep -m1 "^${key}=" "$INFO_PATH" | cut -d= -f2-
}

set_info_value(){
  local key="$1"
  local value="$2"
  local tmp_file

  if [ ! -f "$INFO_PATH" ]; then
    printf '%s=%s\n' "$key" "$value" > "$INFO_PATH"
    return 0
  fi

  tmp_file=$(mktemp)
  awk -v key="$key" -v value="$value" '
    BEGIN { updated = 0 }
    index($0, key "=") == 1 {
      print key "=" value
      updated = 1
      next
    }
    { print }
    END {
      if (!updated) {
        print key "=" value
      }
    }
  ' "$INFO_PATH" > "$tmp_file"
  mv "$tmp_file" "$INFO_PATH"
}

# ─── 节点存储 (per-node info file) ──────────────────
ensure_nodes_dir(){
  mkdir -p "$NODES_DIR" "$CERTS_DIR" 2>/dev/null || true
}

node_info_path(){
  printf '%s' "$NODES_DIR/$1.info"
}

node_installed(){
  [ -f "$(node_info_path "$1")" ]
}

list_installed_nodes(){
  ensure_nodes_dir
  local f base
  for f in "$NODES_DIR"/*.info; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf '%s\n' "${base%.info}"
  done
}

count_installed_nodes(){
  local n
  n=$(list_installed_nodes | wc -l)
  printf '%s' "$(echo "$n" | tr -d ' \t\n\r')"
}

get_node_value(){
  local type="$1" key="$2" f
  f=$(node_info_path "$type")
  [ -f "$f" ] || return 1
  grep -m1 "^${key}=" "$f" | cut -d= -f2-
}

set_node_value(){
  local type="$1" key="$2" value="$3" f tmp
  f=$(node_info_path "$type")
  ensure_nodes_dir
  if [ ! -f "$f" ]; then
    printf '%s=%s\n' "$key" "$value" > "$f"
    return 0
  fi
  tmp=$(mktemp)
  awk -v key="$key" -v value="$value" '
    BEGIN { updated = 0 }
    index($0, key "=") == 1 { print key "=" value; updated = 1; next }
    { print }
    END { if (!updated) print key "=" value }
  ' "$f" > "$tmp"
  mv "$tmp" "$f"
}

remove_node_info(){
  rm -f "$(node_info_path "$1")"
}

# 在多节点情况下让用户选一个节点；仅 1 个时直接回显；0 个返回 1
select_node_interactive(){
  local prompt_label="${1:-选择节点}"
  local nodes count input n i
  local arr=()
  while IFS= read -r n; do
    [ -n "$n" ] && arr+=("$n")
  done < <(list_installed_nodes)
  count=${#arr[@]}
  if [ "$count" -eq 0 ]; then
    return 1
  fi
  if [ "$count" -eq 1 ]; then
    printf '%s' "${arr[0]}"
    return 0
  fi
  {
    echo ""
    echo "  ${prompt_label}："
    i=1
    for n in "${arr[@]}"; do
      echo "    $i) $n"
      i=$((i + 1))
    done
  } >&2
  read -p "  请输入序号 (1): " input >&2
  input="${input:-1}"
  if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "$count" ]; then
    printf '%s' "${arr[$((input - 1))]}"
    return 0
  fi
  return 1
}

# ─── 配置文件 (jq 增量编辑) ─────────────────────────
ensure_jq(){
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  echo -e "${Y}==> 安装 jq...${N}"
  if ! apt-get install -y jq 2>/dev/null; then
    # 第一次跑的全新 VPS 可能 apt 缓存为空，先 update 再重试
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    if ! apt-get install -y jq 2>/dev/null; then
      echo -e "${R}jq 安装失败，请手动执行：apt install jq${N}"
      return 1
    fi
  fi
  return 0
}

config_ensure_skeleton(){
  ensure_jq || return 1
  mkdir -p /etc/sing-box
  if [ ! -f "$CONFIG_PATH" ] || ! jq empty "$CONFIG_PATH" >/dev/null 2>&1; then
    cat > "$CONFIG_PATH" <<'EOF'
{
  "log": {"disabled": false, "level": "warn", "timestamp": true},
  "inbounds": [],
  "outbounds": [{
    "type": "direct",
    "tag": "direct-out"
  }],
  "route": {
    "final": "direct-out"
  }
}
EOF
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  # 透明升级（不再托管 DNS，交给系统 resolv.conf）：
  # 1) 清理老脚本残留的 dns 块、hijack-dns 规则、domain_resolver 字段
  # 2) 若没 outbounds 或为空，建一条 tagged direct-out
  # 3) 若 direct outbound 没 tag，加上 tag=direct-out
  # 4) 确保 route 块存在，final 默认 direct-out
  if jq '
      .log = (.log // {"disabled": false, "level": "warn", "timestamp": true})
    | del(.dns)
    | .inbounds = ((.inbounds // []) | map(select(.tag == "reality-in" or .tag == "hy2-in" or .tag == "anytls-in" or .tag == "tuic-in")))
    | .outbounds = (if ((.outbounds // []) | length) == 0
                    then [{"type":"direct","tag":"direct-out"}]
                    else (.outbounds | map(
                        if .type == "direct" and (.tag // "") == ""
                        then .tag = "direct-out"
                        else . end)
                      | map(del(.domain_resolver)))
                    end)
    | .route = (.route // {})
    | del(.route.default_domain_resolver)
    | .route.rules = ((.route.rules // []) | map(select(.action != "hijack-dns" and (.port // null) != 53)))
    | .route.final = (.route.final // "direct-out")
  ' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$CONFIG_PATH"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

config_add_inbound(){
  local inbound="$1"
  ensure_jq || return 1
  config_ensure_skeleton || return 1
  local tmp tag
  tag=$(printf '%s' "$inbound" | jq -r '.tag // empty' 2>/dev/null)
  if [ -z "$tag" ]; then
    echo -e "${R}内部错误：inbound 缺少 tag${N}"
    return 1
  fi
  tmp=$(mktemp)
  if ! jq --argjson nb "$inbound" --arg tag "$tag" '
    .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) + [$nb]
  ' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$CONFIG_PATH"
}

config_remove_inbound_by_tag(){
  local tag="$1"
  ensure_jq || return 1
  [ -f "$CONFIG_PATH" ] || return 0
  local tmp
  tmp=$(mktemp)
  if ! jq --arg tag "$tag" '.inbounds = ((.inbounds // []) | map(select(.tag != $tag)))' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$CONFIG_PATH"
}

config_add_outbound(){
  local outbound="$1"
  ensure_jq || return 1
  config_ensure_skeleton || return 1
  local tmp tag
  tag=$(printf '%s' "$outbound" | jq -r '.tag // empty' 2>/dev/null)
  if [ -z "$tag" ]; then
    echo -e "${R}内部错误：outbound 缺少 tag${N}"
    return 1
  fi
  tmp=$(mktemp)
  if ! jq --argjson nb "$outbound" --arg tag "$tag" '
    .outbounds = ((.outbounds // []) | map(select(.tag != $tag))) + [$nb]
  ' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$CONFIG_PATH"
}

config_remove_outbound_by_tag(){
  local tag="$1"
  ensure_jq || return 1
  [ -f "$CONFIG_PATH" ] || return 0
  # 不允许移除 direct-out
  if [ "$tag" = "direct-out" ]; then
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  if ! jq --arg tag "$tag" '.outbounds = ((.outbounds // []) | map(select(.tag != $tag)))' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$CONFIG_PATH"
}

config_check_and_restart(){
  if ! sing-box check -c "$CONFIG_PATH"; then
    return 1
  fi
  systemctl enable sing-box >/dev/null 2>&1 || true
  if ! systemctl restart sing-box; then
    return 1
  fi
  return 0
}

# 旧 /root/proxy-info.txt 迁移到 /etc/sing-box/nodes/reality.info
migrate_legacy_info(){
  # 旧配置里 reality inbound 的 tag 是 vless-in，统一重命名为 reality-in
  if [ -f "$CONFIG_PATH" ] && grep -q '"vless-in"' "$CONFIG_PATH" 2>/dev/null; then
    if command -v jq >/dev/null 2>&1; then
      local tmp
      tmp=$(mktemp)
      if jq '(.inbounds[]? | select(.tag == "vless-in") | .tag) = "reality-in"' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$CONFIG_PATH"
      else
        rm -f "$tmp"
      fi
    fi
  fi

  if node_installed reality; then
    return 0
  fi
  [ -f "$INFO_PATH" ] || return 0

  local uuid pubk prik ip port sni sid tag listen link mode bind4
  uuid=$(get_info_value UUID 2>/dev/null || true)
  pubk=$(get_info_value PublicKey 2>/dev/null || true)
  prik=$(get_info_value PrivateKey 2>/dev/null || true)
  ip=$(get_info_value IP 2>/dev/null || true)
  port=$(get_info_value Port 2>/dev/null || true)
  sni=$(get_info_value SNI 2>/dev/null || true)
  sid=$(get_info_value ShortID 2>/dev/null || true)
  tag=$(get_info_value Tag 2>/dev/null || true)
  listen=$(get_info_value ListenAddr 2>/dev/null || true)
  link=$(get_info_value Link 2>/dev/null || true)
  mode=$(get_info_value Mode 2>/dev/null || true)
  bind4=$(get_info_value BindIPv4 2>/dev/null || true)

  if [ -z "$uuid" ] && [ -z "$pubk" ]; then
    return 0
  fi

  ensure_nodes_dir
  local f
  f=$(node_info_path reality)
  cat > "$f" <<EOF
Type=reality
Tag=${tag:-reality}
Mode=${mode:-ipv4}
ListenAddr=${listen}
Port=${port}
SNI=${sni}
UUID=${uuid}
PublicKey=${pubk}
PrivateKey=${prik}
ShortID=${sid}
IP=${ip}
BindIPv4=${bind4}
Link=${link}
EOF
}

write_proxy_info(){
  local uuid="$1"
  local public_key="$2"
  local private_key="$3"
  local ip="$4"
  local port="$5"
  local sni="$6"
  local short_id="$7"
  local tag="$8"
  local listen_addr="$9"
  local link="${10}"
  local mode="${11:-ipv4}"
  local bind_ipv4="${12:-}"

  cat > "$INFO_PATH" << EOF
UUID=$uuid
PublicKey=$public_key
PrivateKey=$private_key
IP=$ip
Port=$port
SNI=$sni
ShortID=$short_id
Tag=$tag
ListenAddr=$listen_addr
Link=$link
Mode=$mode
BindIPv4=$bind_ipv4
EOF
}

load_proxy_context(){
  MENU_UUID=$(get_info_value UUID 2>/dev/null || true)
  MENU_PUBLIC_KEY=$(get_info_value PublicKey 2>/dev/null || true)
  MENU_PRIVATE_KEY=$(get_info_value PrivateKey 2>/dev/null || true)
  MENU_IP=$(get_info_value IP 2>/dev/null || true)
  MENU_PORT=$(get_info_value Port 2>/dev/null || true)
  MENU_SNI=$(get_info_value SNI 2>/dev/null || true)
  MENU_SHORT_ID=$(get_info_value ShortID 2>/dev/null || true)
  MENU_TAG=$(get_info_value Tag 2>/dev/null || true)
  MENU_LISTEN_ADDR=$(get_info_value ListenAddr 2>/dev/null || true)
  MENU_LINK=$(get_info_value Link 2>/dev/null || true)
  MENU_MODE=$(get_info_value Mode 2>/dev/null || true)
  MENU_BIND_IPV4=$(get_info_value BindIPv4 2>/dev/null || true)

  if [ -f "$CONFIG_PATH" ] && command -v jq >/dev/null 2>&1; then
    # 用 jq 解析 reality-in inbound（多行/缩进/空格都能正确处理）
    local jq_inbound='(.inbounds // [])
      | map(select(.tag == "reality-in" or .type == "vless"))
      | (.[0] // {})'

    if [ -z "$MENU_UUID" ]; then
      MENU_UUID=$(jq -r "${jq_inbound} | (.users[0].uuid // \"\")" "$CONFIG_PATH" 2>/dev/null)
    fi

    if [ -z "$MENU_PRIVATE_KEY" ]; then
      MENU_PRIVATE_KEY=$(jq -r "${jq_inbound} | (.tls.reality.private_key // \"\")" "$CONFIG_PATH" 2>/dev/null)
    fi

    if [ -z "$MENU_PORT" ]; then
      MENU_PORT=$(jq -r "${jq_inbound} | (.listen_port // empty)" "$CONFIG_PATH" 2>/dev/null)
    fi

    if [ -z "$MENU_SNI" ]; then
      MENU_SNI=$(jq -r "${jq_inbound} | (.tls.server_name // \"\")" "$CONFIG_PATH" 2>/dev/null)
    fi

    if [ -z "$MENU_SHORT_ID" ]; then
      MENU_SHORT_ID=$(jq -r "${jq_inbound} | (.tls.reality.short_id[0] // \"\")" "$CONFIG_PATH" 2>/dev/null)
    fi

    if [ -z "$MENU_LISTEN_ADDR" ]; then
      MENU_LISTEN_ADDR=$(jq -r "${jq_inbound} | (.listen // \"\")" "$CONFIG_PATH" 2>/dev/null)
    fi

    if [ -z "$MENU_BIND_IPV4" ]; then
      MENU_BIND_IPV4=$(jq -r '
        (.outbounds // [])
        | map(select(.type == "direct"))
        | (.[0].inet4_bind_address // "")
      ' "$CONFIG_PATH" 2>/dev/null)
    fi

    if [ -z "$MENU_MODE" ]; then
      case "$MENU_LISTEN_ADDR" in
        ::)
          MENU_MODE="dualstack"
          ;;
        *:*)
          MENU_MODE="ipv6-in-ipv4-out"
          ;;
        *)
          local final_route
          final_route=$(jq -r '.route.final // ""' "$CONFIG_PATH" 2>/dev/null)
          [ "$final_route" = "v4-out" ] && MENU_MODE="ipv6-in-ipv4-out"
          ;;
      esac
    fi
  elif [ -f "$CONFIG_PATH" ]; then
    # jq 不可用时，沿用旧的 sed 兜底（容错差但避免完全失效）
    if [ -z "$MENU_UUID" ]; then
      MENU_UUID=$(sed -n 's/.*"uuid":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_PATH" | head -1)
    fi
    if [ -z "$MENU_PRIVATE_KEY" ]; then
      MENU_PRIVATE_KEY=$(sed -n 's/.*"private_key":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_PATH" | head -1)
    fi
    if [ -z "$MENU_PORT" ]; then
      MENU_PORT=$(sed -n 's/.*"listen_port":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CONFIG_PATH" | head -1)
    fi
    if [ -z "$MENU_SNI" ]; then
      MENU_SNI=$(sed -n 's/.*"server_name":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_PATH" | head -1)
    fi
    if [ -z "$MENU_SHORT_ID" ]; then
      MENU_SHORT_ID=$(sed -n 's/.*"short_id":[[:space:]]*\["\([^"]*\)"\].*/\1/p' "$CONFIG_PATH" | head -1)
    fi
    if [ -z "$MENU_LISTEN_ADDR" ]; then
      MENU_LISTEN_ADDR=$(sed -n 's/.*"listen":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_PATH" | head -1)
    fi
    if [ -z "$MENU_BIND_IPV4" ]; then
      MENU_BIND_IPV4=$(sed -n 's/.*"inet4_bind_address":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_PATH" | head -1)
    fi
    if [ -z "$MENU_MODE" ]; then
      case "$MENU_LISTEN_ADDR" in
        ::)
          MENU_MODE="dualstack"
          ;;
        *:*)
          MENU_MODE="ipv6-in-ipv4-out"
          ;;
        *)
          if grep -Eq '"final":[[:space:]]*"v4-out"' "$CONFIG_PATH"; then
            MENU_MODE="ipv6-in-ipv4-out"
          fi
          ;;
      esac
    fi
  fi

  if [ -z "$MENU_IP" ]; then
    if [ "$MENU_MODE" = "ipv6-in-ipv4-out" ]; then
      MENU_IP=$(detect_primary_ipv6)
    else
      MENU_IP=$(detect_primary_ipv4)
    fi
  fi

  if [ -z "$MENU_IP" ]; then
    MENU_IP=$(detect_primary_ipv6)
  fi

  if [ -z "$MENU_TAG" ]; then
    MENU_TAG="reality"
  fi

  if [ -z "$MENU_LINK" ]; then
    MENU_LINK=$(build_client_link "$MENU_UUID" "$MENU_IP" "$MENU_PORT" "$MENU_SNI" "$MENU_PUBLIC_KEY" "$MENU_SHORT_ID" "$MENU_TAG" 2>/dev/null || true)
  fi
}

# ─── 链接构造（按协议） ───────────────────────────────
