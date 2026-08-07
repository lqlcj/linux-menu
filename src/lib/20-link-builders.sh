url_encode_host(){
  # 给 IPv6 地址套 [] ，IPv4 / 域名原样返回
  local ip="$1"
  case "$ip" in
    \[*\]) printf '%s' "$ip" ;;
    *:*)   printf '[%s]' "$ip" ;;
    *)     printf '%s' "$ip" ;;
  esac
}

url_encode_component(){
  local value="${1:-}"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$value" | jq -sRr @uri
    return
  fi
  # 节点创建流程本身依赖 jq；这里只在手工调用链接函数时给出明确失败。
  return 1
}

build_reality_link(){
  local uuid="$1"
  local ip="$2"
  local port="$3"
  local sni="$4"
  local public_key="$5"
  local short_id="$6"
  local tag="${7:-reality}"

  if [ -z "$uuid" ] || [ -z "$ip" ] || [ -z "$port" ] || [ -z "$sni" ] || [ -z "$public_key" ] || [ -z "$short_id" ]; then
    return 1
  fi

  local host enc_sni enc_pub enc_sid enc_tag
  host=$(url_encode_host "$ip")
  enc_sni=$(url_encode_component "$sni") || return 1
  enc_pub=$(url_encode_component "$public_key") || return 1
  enc_sid=$(url_encode_component "$short_id") || return 1
  enc_tag=$(url_encode_component "$tag") || return 1
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
    "$uuid" "$host" "$port" "$enc_sni" "$enc_pub" "$enc_sid" "$enc_tag"
}

build_anytls_link(){
  # build_anytls_link <password> <ip> <port> <sni> <public_key> <short_id> <tag>
  # AnyTLS 标准 URI（anytls-go uri_scheme.md）只定义 sni/insecure；
  # 这里增加 reality 扩展参数（security/pbk/sid/fp），与 v2rayN / sing-box GUI / Shadowrocket 的事实标准兼容。
  local password="$1"
  local ip="$2"
  local port="$3"
  local sni="$4"
  local public_key="$5"
  local short_id="$6"
  local tag="${7:-anytls}"

  if [ -z "$password" ] || [ -z "$ip" ] || [ -z "$port" ] || [ -z "$sni" ] || [ -z "$public_key" ] || [ -z "$short_id" ]; then
    return 1
  fi

  local host enc_pw enc_sni enc_pub enc_sid enc_tag
  host=$(url_encode_host "$ip")
  enc_pw=$(url_encode_component "$password") || return 1
  enc_sni=$(url_encode_component "$sni") || return 1
  enc_pub=$(url_encode_component "$public_key") || return 1
  enc_sid=$(url_encode_component "$short_id") || return 1
  enc_tag=$(url_encode_component "$tag") || return 1
  printf 'anytls://%s@%s:%s/?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&insecure=0#%s\n' \
    "$enc_pw" "$host" "$port" "$enc_sni" "$enc_pub" "$enc_sid" "$enc_tag"
}

build_hy2_link(){
  # build_hy2_link <password> <ip> <port> <sni> <insecure 0|1> <obfs_type|""> <obfs_password|""> <tag> [hop_start] [hop_end]
  local password="$1"
  local ip="$2"
  local port="$3"
  local sni="$4"
  local insecure="${5:-0}"
  local obfs_type="$6"
  local obfs_password="$7"
  local tag="${8:-hy2}"
  local hop_start="${9:-}"
  local hop_end="${10:-}"

  if [ -z "$password" ] || [ -z "$ip" ] || [ -z "$port" ]; then
    return 1
  fi

  local host enc_password enc_sni enc_obfs_type enc_obfs_password enc_tag
  host=$(url_encode_host "$ip")
  enc_password=$(url_encode_component "$password") || return 1
  enc_sni=$(url_encode_component "${sni:-}") || return 1
  enc_tag=$(url_encode_component "$tag") || return 1
  local query="sni=${enc_sni}&insecure=${insecure}"
  if [ -n "$obfs_type" ]; then
    enc_obfs_type=$(url_encode_component "$obfs_type") || return 1
    enc_obfs_password=$(url_encode_component "$obfs_password") || return 1
    query="${query}&obfs=${enc_obfs_type}&obfs-password=${enc_obfs_password}"
  fi

  local server_part
  if [ -n "$hop_start" ] && [ -n "$hop_end" ]; then
    server_part="${host}:${port},${hop_start}-${hop_end}"
  else
    server_part="${host}:${port}"
  fi
  printf 'hysteria2://%s@%s?%s#%s\n' \
    "$enc_password" "$server_part" "$query" "$enc_tag"
}

build_tuic_link(){
  # build_tuic_link <uuid> <password> <ip> <port> <sni> <insecure 0|1> <congestion_control> <tag>
  local uuid="$1"
  local password="$2"
  local ip="$3"
  local port="$4"
  local sni="$5"
  local insecure="${6:-0}"
  local cc="${7:-bbr}"
  local tag="${8:-tuic}"

  if [ -z "$uuid" ] || [ -z "$password" ] || [ -z "$ip" ] || [ -z "$port" ]; then
    return 1
  fi

  local host enc_password enc_sni enc_cc enc_tag
  host=$(url_encode_host "$ip")
  enc_password=$(url_encode_component "$password") || return 1
  enc_sni=$(url_encode_component "${sni:-}") || return 1
  enc_cc=$(url_encode_component "$cc") || return 1
  enc_tag=$(url_encode_component "$tag") || return 1
  printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=%s&allow_insecure=%s#%s\n' \
    "$uuid" "$enc_password" "$host" "$port" "$enc_sni" "$enc_cc" "$insecure" "$enc_tag"
}

build_ss2022_link(){
  # build_ss2022_link <method> <password> <ip> <port> <tag>
  # SIP002 标准：ss://<base64url(method:password)>@host:port#tag
  local method="$1"
  local password="$2"
  local ip="$3"
  local port="$4"
  local tag="${5:-ss2022}"

  if [ -z "$method" ] || [ -z "$password" ] || [ -z "$ip" ] || [ -z "$port" ]; then
    return 1
  fi

  local host userinfo enc_tag
  host=$(url_encode_host "$ip")
  userinfo=$(printf '%s:%s' "$method" "$password" | base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '=')
  enc_tag=$(url_encode_component "$tag") || return 1
  printf 'ss://%s@%s:%s#%s\n' \
    "$userinfo" "$host" "$port" "$enc_tag"
}

# 由节点 info 文件构造链接（dispatcher）
build_link_for_node(){
  local type="$1"
  local ip_override="${2:-}"
  local tag_override="${3:-}"

  local node_type tag ip port sni
  node_type=$(get_node_value "$type" Type 2>/dev/null || echo "$type")
  tag=$(get_node_value "$type" Tag 2>/dev/null || echo "$type")
  [ -n "$tag_override" ] && tag="$tag_override"
  ip=${ip_override:-$(get_node_value "$type" IP 2>/dev/null || true)}
  port=$(get_node_value "$type" Port 2>/dev/null || true)
  sni=$(get_node_value "$type" SNI 2>/dev/null || true)

  case "$node_type" in
    reality)
      local uuid pubk sid
      uuid=$(get_node_value "$type" UUID 2>/dev/null || true)
      pubk=$(get_node_value "$type" PublicKey 2>/dev/null || true)
      sid=$(get_node_value "$type" ShortID 2>/dev/null || true)
      build_reality_link "$uuid" "$ip" "$port" "$sni" "$pubk" "$sid" "$tag"
      ;;
    hy2)
      local password insecure obfs_type obfs_pw hop_enabled hop_start hop_end
      password=$(get_node_value "$type" Password 2>/dev/null || true)
      insecure=$(get_node_value "$type" Insecure 2>/dev/null || echo 0)
      obfs_type=$(get_node_value "$type" Obfs 2>/dev/null || true)
      [ "$obfs_type" = "none" ] && obfs_type=""
      obfs_pw=$(get_node_value "$type" ObfsPassword 2>/dev/null || true)
      hop_enabled=$(get_node_value "$type" PortHop 2>/dev/null || echo 0)
      if [ "$hop_enabled" = "1" ]; then
        hop_start=$(get_node_value "$type" PortHopStart 2>/dev/null || true)
        hop_end=$(get_node_value "$type" PortHopEnd 2>/dev/null || true)
      fi
      build_hy2_link "$password" "$ip" "$port" "$sni" "$insecure" "$obfs_type" "$obfs_pw" "$tag" "${hop_start:-}" "${hop_end:-}"
      ;;
    anytls)
      local password pubk sid
      password=$(get_node_value "$type" Password 2>/dev/null || true)
      pubk=$(get_node_value "$type" PublicKey 2>/dev/null || true)
      sid=$(get_node_value "$type" ShortID 2>/dev/null || true)
      build_anytls_link "$password" "$ip" "$port" "$sni" "$pubk" "$sid" "$tag"
      ;;
    tuic)
      local uuid password insecure cc
      uuid=$(get_node_value "$type" UUID 2>/dev/null || true)
      password=$(get_node_value "$type" Password 2>/dev/null || true)
      insecure=$(get_node_value "$type" Insecure 2>/dev/null || echo 0)
      cc=$(get_node_value "$type" CongestionControl 2>/dev/null || echo bbr)
      build_tuic_link "$uuid" "$password" "$ip" "$port" "$sni" "$insecure" "$cc" "$tag"
      ;;
    ss2022)
      local method password
      method=$(get_node_value "$type" Method 2>/dev/null || true)
      password=$(get_node_value "$type" Password 2>/dev/null || true)
      build_ss2022_link "$method" "$password" "$ip" "$port" "$tag"
      ;;
    *)
      return 1
      ;;
  esac
}

# 兼容旧调用（少数仍以 7 个参数调用 build_client_link 的地方）
build_client_link(){
  build_reality_link "$@"
}

# 双栈模式下，节点的 IPv6 副链接（如果与主 IP 不同）
build_dualstack_ipv6_link_for_node(){
  local type="$1"
  local mode ipv6 main_ip tag
  mode=$(get_node_value "$type" Mode 2>/dev/null || true)
  if [ "$mode" != "dualstack" ]; then
    return 1
  fi
  ipv6=$(detect_primary_ipv6)
  main_ip=$(get_node_value "$type" IP 2>/dev/null || true)
  if [ -z "$ipv6" ] || [ "$ipv6" = "$main_ip" ]; then
    return 1
  fi
  tag=$(get_node_value "$type" Tag 2>/dev/null || echo "$type")
  build_link_for_node "$type" "$ipv6" "${tag}-ipv6"
}

# 旧名兼容（仍被部分老代码调用，但新代码请用 build_dualstack_ipv6_link_for_node）
build_dualstack_ipv6_link(){
  local uuid="$1"
  local port="$2"
  local sni="$3"
  local public_key="$4"
  local short_id="$5"
  local tag="${6:-reality}"
  local ipv6=""

  if [ "${MENU_MODE:-}" != "dualstack" ]; then
    return 1
  fi

  ipv6=$(detect_primary_ipv6)
  if [ -z "$ipv6" ] || [ "$ipv6" = "$MENU_IP" ]; then
    return 1
  fi

  build_reality_link "$uuid" "$ipv6" "$port" "$sni" "$public_key" "$short_id" "${tag}-ipv6"
}
