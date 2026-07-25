is_private_ipv4(){
  case "$1" in
    10.*|127.*|192.168.*|0.0.0.0|169.254.*) return 0 ;;
    172.16.*|172.17.*|172.18.*|172.19.*) return 0 ;;
    172.2[0-9].*|172.3[01].*) return 0 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
  esac
  return 1
}

# 判断 IPv6 是否属于 ULA / link-local / loopback / unspecified
is_private_ipv6(){
  local ip
  ip=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$ip" in
    ::1|::|fe8?:*|fe9?:*|fea?:*|feb?:*) return 0 ;;
    fc??:*|fd??:*) return 0 ;;
  esac
  return 1
}

detect_primary_ipv4(){
  local detected="" local_fallback=""

  if command -v ip >/dev/null 2>&1; then
    detected=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i == "src") {
          print $(i + 1)
          exit
        }
      }
    }')
    if [ -n "$detected" ] && is_private_ipv4 "$detected"; then
      local_fallback="$detected"
      detected=""
    fi

    if [ -z "$detected" ]; then
      detected=$(ip -4 addr show scope global up 2>/dev/null | awk '/inet / {
        split($2, parts, "/")
        print parts[1]
        exit
      }')
      if [ -n "$detected" ] && is_private_ipv4 "$detected"; then
        [ -z "$local_fallback" ] && local_fallback="$detected"
        detected=""
      fi
    fi
  fi

  if [ -z "$detected" ]; then
    detected=$(curl -s4 --max-time 3 ip.sb 2>/dev/null || true)
  fi

  # curl 也失败时，宁可返回先前探到的内网 IP 也别返回空——
  # 至少能让用户在节点信息里看到检测结果，避免上层卡在「未检测到可用的 IPv4 地址」
  if [ -z "$detected" ]; then
    detected="$local_fallback"
  fi

  printf '%s' "$detected"
}

detect_primary_ipv6(){
  local detected="" local_fallback=""

  if command -v ip >/dev/null 2>&1; then
    detected=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i == "src") {
          print $(i + 1)
          exit
        }
      }
    }')
    if [ -n "$detected" ] && is_private_ipv6 "$detected"; then
      local_fallback="$detected"
      detected=""
    fi

    if [ -z "$detected" ]; then
      detected=$(ip -6 addr show scope global up 2>/dev/null | awk '/inet6 / {
        split($2, parts, "/")
        print parts[1]
        exit
      }')
      if [ -n "$detected" ] && is_private_ipv6 "$detected"; then
        [ -z "$local_fallback" ] && local_fallback="$detected"
        detected=""
      fi
    fi
  fi

  if [ -z "$detected" ]; then
    detected=$(curl -s6 --max-time 3 ip.sb 2>/dev/null || true)
  fi

  if [ -z "$detected" ]; then
    detected="$local_fallback"
  fi

  printf '%s' "$detected"
}

describe_install_mode(){
  case "$1" in
    ipv6-in-ipv4-out)
      printf '%s' '仅 IPv6 入站'
      ;;
    dualstack)
      printf '%s' '双栈入站'
      ;;
    *)
      printf '%s' '仅 IPv4 入站'
      ;;
  esac
}

