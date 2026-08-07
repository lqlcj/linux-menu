warp_log_ok()   { echo -e "  ${G}✓${N} $*" >&2; }
warp_log_info() { echo -e "  ${C}●${N} $*" >&2; }
warp_log_warn() { echo -e "  ${Y}⚠${N} $*" >&2; }
warp_log_err()  { echo -e "  ${R}✗${N} $*" >&2; }

warp_transaction_begin(){
  local txn
  txn=$(config_transaction_begin warp) || return 1
  if [ -d "$WARP_DIR" ]; then
    cp -a -- "$WARP_DIR" "$txn/warp-dir" || { config_transaction_rollback "$txn"; return 1; }
    : > "$txn/warp-dir.existed"
  fi
  if [ -f "$WARP_WGCF_BIN" ]; then
    cp -a -- "$WARP_WGCF_BIN" "$txn/wgcf-bin" || { config_transaction_rollback "$txn"; return 1; }
    : > "$txn/wgcf-bin.existed"
  fi
  printf '%s' "$txn"
}

warp_transaction_rollback(){
  local txn="$1" rc=0
  [ -d "$txn" ] || return 1
  config_transaction_restore "$txn" || rc=1

  if ! rm -rf -- "$WARP_DIR"; then
    rc=1
  elif [ -f "$txn/warp-dir.existed" ]; then
    if ! mkdir -p -- "$(dirname -- "$WARP_DIR")" \
       || ! cp -a -- "$txn/warp-dir" "$WARP_DIR"; then
      rc=1
    fi
  fi
  if [ -f "$txn/wgcf-bin.existed" ]; then
    if ! restore_file_snapshot "$txn/wgcf-bin" "$WARP_WGCF_BIN"; then
      rc=1
    fi
  else
    rm -f -- "$WARP_WGCF_BIN" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    rm -rf -- "$txn" || rc=1
  fi
  [ "$rc" -eq 0 ] || warp_log_err "WARP 事务回滚有步骤失败，请检查账号与 sing-box 配置；快照保留在 ${txn}"
  return "$rc"
}

warp_transaction_commit(){
  config_transaction_commit "$1"
}

# ── 账号注册：curl 直连 Cloudflare API（wgcf 方案已废弃）──────────────
# 旧版用 wgcf 二进制：要从 GitHub API 拿版本再下 release（VPS 上极易被限流/
# 阻断），且 Cloudflare 收紧注册接口后老版本 wgcf 频繁 403/429 —— 这就是旧版
# 「WARP 分流」装不上的根因。现改为主流脚本（fscarmen/warp、warp-reg）同款：
# openssl 生成 X25519 密钥对，curl 模拟官方安卓客户端注册，一次拿全 v4/v6
# 内网地址 + peer 公钥 + client_id，存成 ${WARP_DIR}/account.json。
# client_id 解码出的 3 字节即 WireGuard 报文头的 reserved 字段 —— 旧版写死
# [0,0,0]，部分 PoP 会「握手成功但无数据」，本次一并修正。

warp_gen_keypair(){
  local pem priv pub
  if command -v wg >/dev/null 2>&1; then
    priv=$(wg genkey 2>/dev/null)
    pub=$(printf '%s' "$priv" | wg pubkey 2>/dev/null)
  else
    pem=$(openssl genpkey -algorithm X25519 2>/dev/null)
    if [ -z "$pem" ]; then
      warp_log_err "openssl 生成 X25519 密钥失败（需要 openssl 1.1.0+，或安装 wireguard-tools）"
      return 1
    fi
    # PKCS8 私钥 / SPKI 公钥的 DER 最后 32 字节就是裸密钥（免依赖 xxd）
    priv=$(printf '%s\n' "$pem" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64)
    pub=$(printf '%s\n' "$pem" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64)
  fi
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    warp_log_err "生成 WireGuard 密钥对失败"
    return 1
  fi
  printf '%s %s\n' "$priv" "$pub"
}

warp_account_valid(){
  [ -s "$WARP_ACCOUNT_JSON" ] || return 1
  jq -e '
    (.private_key | type == "string" and length > 0)
    and (.config.interface.addresses.v4 | type == "string" and length > 0)
    and (.config.peers[0].public_key | type == "string" and length > 0)
  ' "$WARP_ACCOUNT_JSON" >/dev/null 2>&1
}

warp_register_account(){
  local force="${1:-0}"
  mkdir -p "$WARP_DIR" || return 1
  chmod 700 "$WARP_DIR" || return 1
  ensure_jq || return 1
  if [ -s "$WARP_ACCOUNT_JSON" ] && [ "$force" != "1" ]; then
    if ! warp_account_valid; then
      warp_log_err "现有 account.json 无效，已拒绝覆盖；请使用“重新注册账号”"
      return 1
    fi
    return 0
  fi

  local priv pub
  read -r priv pub <<< "$(warp_gen_keypair)"
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    return 1
  fi

  local install_id fcm_token body resp try tmp
  install_id=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 22)
  fcm_token="${install_id}:APA91b$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 134)"
  body=$(jq -nc --arg key "$pub" --arg iid "$install_id" --arg fcm "$fcm_token" \
        --arg tos "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
        '{key:$key, install_id:$iid, fcm_token:$fcm, tos:$tos,
          model:"PC", serial_number:$iid, locale:"zh_CN"}')

  warp_log_info "向 Cloudflare 注册 WARP 账号（直连 API，不下载任何二进制）..."
  resp=""
  for try in 1 2 3 4 5 6; do
    resp=$(curl --proto '=https' --proto-redir '=https' -sL --tlsv1.2 --max-time 20 -X POST "${WARP_API_BASE}/reg" \
      -H "User-Agent: ${WARP_API_UA}" \
      -H "CF-Client-Version: ${WARP_API_CLIENT_VER}" \
      -H 'Content-Type: application/json' \
      --data "$body" 2>/dev/null)
    if printf '%s' "$resp" | jq -e '(.result // .) | .config.peers[0].public_key' >/dev/null 2>&1; then
      break
    fi
    # error code: 1015 = Cloudflare 按 IP 限流，机房 IP 信誉差时常见，等一等再试
    warp_log_warn "第 ${try}/6 次注册未成功${resp:+：$(printf '%.80s' "$(printf '%s' "$resp" | tr -d '\n')")}"
    resp=""
    [ "$try" -lt 6 ] && sleep $((try * 5))
  done
  if [ -z "$resp" ]; then
    warp_log_err "注册失败（6 次尝试后放弃）"
    echo -e "  ${D}排查建议：${N}"
    echo -e "  ${D}1) 限流（error code: 1015 / 429）：此 IP 注册太频繁，等 10-30 分钟再试${N}"
    echo -e "  ${D}2) 一直无响应：跑 curl -sI --max-time 10 https://api.cloudflareclient.com${N}"
    echo -e "  ${D}   若不通说明本机到 Cloudflare API 被阻断，需在别处注册后拷贝 account.json 过来${N}"
    return 1
  fi

  # 兼容有无 .result 包裹两种返回，并把我们自己的私钥合进去一起落盘
  tmp=$(mktemp "${WARP_ACCOUNT_JSON}.tmp.XXXXXX") || return 1
  if ! printf '%s' "$resp" | jq --arg pk "$priv" '(.result // .) + {private_key: $pk}' \
       > "$tmp" 2>/dev/null \
     || ! jq -e '
          (.private_key | type == "string" and length > 0)
          and (.config.interface.addresses.v4 | type == "string" and length > 0)
          and (.config.peers[0].public_key | type == "string" and length > 0)
        ' "$tmp" >/dev/null 2>&1; then
    warp_log_err "写入 ${WARP_ACCOUNT_JSON} 失败"
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$WARP_ACCOUNT_JSON" || { rm -f -- "$tmp"; return 1; }
  warp_log_ok "WARP 账号已注册：${WARP_ACCOUNT_JSON}"
}

warp_reregister_account(){
  # 新账号先原子落盘；失败时旧 account.json 保持不变。
  warp_register_account 1 || return 1
  rm -f -- "${WARP_DIR}/wgcf-account.toml" "${WARP_DIR}/wgcf-profile.conf"
}

# 解析 account.json，直接写入调用者作用域中的 WARP_* 变量，避免 eval。
# WARP_RESERVED 为 client_id base64 解码出的 3 字节（逗号分隔），注入
# endpoint.peers[].reserved；解不出时回退 0,0,0 并靠端点优选兜底
warp_load_profile(){
  local f="$WARP_ACCOUNT_JSON"
  if [ ! -s "$f" ]; then
    if [ -f "${WARP_DIR}/wgcf-profile.conf" ]; then
      warp_log_err "检测到旧版 wgcf 账号；新版已改用 API 直注，请走「重新注册」生成 account.json"
    else
      warp_log_err "WARP 账号缺失：$f（请先安装/注册）"
    fi
    return 1
  fi
  ensure_jq || return 1
  local pk v4 v6 peerpk cid reserved v4_plain v6_plain
  pk=$(jq -r '.private_key // empty' "$f" 2>/dev/null)
  v4=$(jq -r '.config.interface.addresses.v4 // empty' "$f" 2>/dev/null)
  v6=$(jq -r '.config.interface.addresses.v6 // empty' "$f" 2>/dev/null)
  peerpk=$(jq -r '.config.peers[0].public_key // empty' "$f" 2>/dev/null)
  cid=$(jq -r '.config.client_id // empty' "$f" 2>/dev/null)
  v4_plain="${v4%%/*}"
  v6_plain="${v6%%/*}"
  if [ -z "$pk" ] || [ -z "$v4" ] \
     || ! printf '%s' "$pk" | grep -Eq '^[A-Za-z0-9+/]{43}=$' \
     || ! is_valid_ipv4 "$v4_plain" \
     || { [ -n "$v6" ] && ! is_valid_ipv6_text "$v6_plain"; }; then
    warp_log_err "解析 account.json 失败（缺 private_key 或 v4 地址），请「重新注册」"
    return 1
  fi
  # API 返回裸地址，sing-box endpoint.address 需要 CIDR
  case "$v4" in */*) ;; *) v4="${v4}/32" ;; esac
  case "$v6" in ''|*/*) ;; *) v6="${v6}/128" ;; esac
  reserved=""
  if [ -n "$cid" ]; then
    reserved=$(printf '%s' "$cid" | base64 -d 2>/dev/null | od -An -tu1 2>/dev/null \
      | awk 'NF >= 3 {printf "%d,%d,%d", $1, $2, $3; exit}')
  fi
  [ -n "$reserved" ] || reserved="0,0,0"
  WARP_PRIVATE_KEY="$pk"
  WARP_LOCAL_V4="$v4"
  WARP_LOCAL_V6="$v6"
  WARP_PEER_PK="${peerpk:-$WARP_PEER_PUBLIC_KEY}"
  WARP_RESERVED="$reserved"
}

# sing-box 版本护栏：endpoints 需 1.11+，本模块骨架用的新版 DNS/route 字段
# （default_domain_resolver、dns type local）需 1.12+。低版本 sing-box check
# 只会报一堆看不懂的字段错误，这里先把话说明白
warp_require_singbox_112(){
  local ver major minor
  ver=$(sing-box version 2>/dev/null | awk 'NR==1 {print $3}')
  major="${ver%%.*}"
  minor="${ver#*.}"; minor="${minor%%.*}"; minor="${minor%%[!0-9]*}"
  case "$major" in ''|*[!0-9]*) warp_log_warn "读不到 sing-box 版本号，跳过版本检查"; return 0 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 12 ]; }; then
    return 0
  fi
  warp_log_err "当前 sing-box ${ver} 过旧，WARP 分流需要 ≥ 1.12（endpoints + 新版 DNS 字段）"
  echo -e "  ${D}请先到「节点管理」把 sing-box 升到最新稳定版，再回来装 WARP${N}"
  return 1
}

# 安全编辑 sing-box 配置：写临时文件 → sing-box check 通过后才覆盖
warp_jq_apply(){
  local jq_filter="$1"
  shift
  local tmp
  tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX") || return 1
  if ! jq "$@" "$jq_filter" "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if ! sing-box check -c "$tmp" >/dev/null 2>&1; then
    warp_log_err "sing-box 校验未通过，已回滚"
    sing-box check -c "$tmp" 2>&1 | sed 's/^/    /'
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$CONFIG_PATH"
}

# 读当前配置里 WARP endpoint 实际使用的 host port（没有则回退默认值）
# 用途：重新注入/重新注册时保留「端点优选」选过的地址，不被默认值覆盖
warp_current_endpoint(){
  local ep=""
  if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_PATH" ]; then
    ep=$(jq -r --arg tag "$WARP_OUTBOUND_TAG" '
      (.endpoints // [])[] | select(.tag == $tag) | .peers[0] | "\(.address) \(.port)"
    ' "$CONFIG_PATH" 2>/dev/null | head -1)
  fi
  case "$ep" in
    *null*|"") printf '%s %s' "$WARP_ENDPOINT_HOST" "$WARP_ENDPOINT_PORT" ;;
    *)         printf '%s' "$ep" ;;
  esac
}

warp_managed_state_get(){
  local key="$1"
  [ -f "$WARP_MANAGED_STATE" ] || return 1
  grep -m1 "^${key}=" "$WARP_MANAGED_STATE" | cut -d= -f2-
}

warp_capture_managed_state(){
  local tmp cache_added=0 cache_path=""
  [ -f "$WARP_MANAGED_STATE" ] && return 0
  mkdir -p -- "$WARP_DIR" || return 1
  chmod 700 "$WARP_DIR" || return 1

  if jq -e '.experimental.cache_file != null' "$CONFIG_PATH" >/dev/null 2>&1; then
    cache_path=$(jq -r '.experimental.cache_file.path // empty' "$CONFIG_PATH" 2>/dev/null)
  else
    cache_added=1
    cache_path="$WARP_CACHE_DEFAULT"
  fi
  tmp=$(mktemp "${WARP_MANAGED_STATE}.tmp.XXXXXX") || return 1
  if ! printf 'CacheFileAdded=%s\nCachePath=%s\n' "$cache_added" "$cache_path" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$WARP_MANAGED_STATE"
}

warp_config_inject(){
  local v4="$1" v6="$2" pk="$3" peerpk="${4:-$WARP_PEER_PUBLIC_KEY}" reserved="${5:-0,0,0}"
  ensure_jq || return 1
  [ -f "$CONFIG_PATH" ] || { warp_log_err "config.json 不存在：$CONFIG_PATH"; return 1; }
  warp_capture_managed_state || return 1
  # 骨架兜底：保证 dns local 解析器 + route.default_domain_resolver 存在
  # （WireGuard endpoint 是用户态网络栈，拨域名必须有内部解析器，否则命中规则的流量全断）
  config_ensure_skeleton || return 1

  local addr_json
  if [ -n "$v6" ]; then
    addr_json=$(jq -nc --arg a "$v4" --arg b "$v6" '[$a, $b]')
  else
    addr_json=$(jq -nc --arg a "$v4" '[$a]')
  fi

  local host port
  read -r host port <<< "$(warp_current_endpoint)"

  warp_log_info "注入 WARP endpoint / 规则集 / 路由规则..."
  warp_jq_apply '
      def owned_sniff:
        ((.action // "") == "sniff")
        and (((.inbound // []) | sort) == (($sniff_inbounds | fromjson) | sort));
      .endpoints = ((.endpoints // []) | map(select(.tag != $tag)))
        + [{
            "type": "wireguard",
            "tag": $tag,
            "system": false,
            "mtu": ($mtu | tonumber),
            "address": ($addrs | fromjson),
            "private_key": $pk,
            "peers": [{
              "address": $host,
              "port": ($port | tonumber),
              "public_key": $peerpk,
              "allowed_ips": ["0.0.0.0/0", "::/0"],
              "persistent_keepalive_interval": 25,
              "reserved": ($reserved | split(",") | map(tonumber))
            }]
          }]
    | .route = (.route // {})
    | .route.rule_set = ((.route.rule_set // []) | map(select(.tag != $rs and .tag != $rsyt)))
        + [{
            "type": "remote",
            "tag": $rs,
            "format": "binary",
            "url": $rsurl,
            "download_detour": "direct-out",
            "update_interval": "168h0m0s"
          },
          {
            "type": "remote",
            "tag": $rsyt,
            "format": "binary",
            "url": $rsurlyt,
            "download_detour": "direct-out",
            "update_interval": "168h0m0s"
          }]
    | .route.rules = (
        [{"inbound": ($sniff_inbounds | fromjson), "action": "sniff"}]
        + ((.route.rules // []) | map(select(((.outbound // "") != $tag) and (owned_sniff | not))))
        + [{"rule_set": [$rs, $rsyt], "outbound": $tag}]
      )
    | .experimental = (.experimental // {})
    | .experimental.cache_file = (.experimental.cache_file // {"enabled": true, "path": "/var/lib/sing-box/cache.db"})
  ' \
    --arg tag     "$WARP_OUTBOUND_TAG" \
    --arg rs      "$WARP_RULESET_TAG" \
    --arg rsyt    "$WARP_RULESET_TAG_YT" \
    --arg rsurl   "$WARP_RULESET_URL" \
    --arg rsurlyt "$WARP_RULESET_URL_YT" \
    --arg host    "$host" \
    --arg port    "$port" \
    --arg mtu     "$WARP_MTU" \
    --arg pk      "$pk" \
    --arg peerpk  "$peerpk" \
    --arg reserved "$reserved" \
    --arg sniff_inbounds "$WARP_SNIFF_INBOUNDS_JSON" \
    --arg addrs   "$addr_json"
}

warp_config_remove(){
  local remove_cache="0" cache_path=""
  ensure_jq || return 1
  [ -f "$CONFIG_PATH" ] || return 0
  remove_cache=$(warp_managed_state_get CacheFileAdded 2>/dev/null || echo 0)
  cache_path=$(warp_managed_state_get CachePath 2>/dev/null || true)
  if ! warp_jq_apply '
      def owned_sniff:
        ((.action // "") == "sniff")
        and (((.inbound // []) | sort) == (($sniff_inbounds | fromjson) | sort));
      .endpoints = ((.endpoints // []) | map(select(.tag != $tag)))
    | .route = (.route // {})
    | .route.rule_set = ((.route.rule_set // []) | map(select(.tag != $rs and .tag != $rsyt)))
    | .route.rules = ((.route.rules // []) | map(select(((.outbound // "") != $tag) and (owned_sniff | not))))
    | if $remove_cache == "1" then .experimental |= del(.cache_file) else . end
    | if .experimental == {} then del(.experimental) else . end
  ' \
    --arg tag  "$WARP_OUTBOUND_TAG" \
    --arg rs   "$WARP_RULESET_TAG" \
    --arg rsyt "$WARP_RULESET_TAG_YT" \
    --arg sniff_inbounds "$WARP_SNIFF_INBOUNDS_JSON" \
    --arg remove_cache "$remove_cache"; then
    return 1
  fi
  if [ "$remove_cache" = "1" ] && [ -n "$cache_path" ]; then
    case "$cache_path" in
      /var/lib/sing-box/*|/var/cache/leyili/*)
        rm -f -- "$cache_path" || return 1
        ;;
    esac
  fi
  rm -f -- "$WARP_MANAGED_STATE"
}

warp_config_has_outbound(){
  [ -f "$CONFIG_PATH" ] || return 1
  jq -e --arg tag "$WARP_OUTBOUND_TAG" \
    '(.endpoints // []) | map(select(.tag == $tag)) | length > 0' \
    "$CONFIG_PATH" >/dev/null 2>&1
}

warp_config_has_rule(){
  [ -f "$CONFIG_PATH" ] || return 1
  jq -e --arg tag "$WARP_OUTBOUND_TAG" \
    '(.route.rules // []) | map(select((.outbound // "") == $tag)) | length > 0' \
    "$CONFIG_PATH" >/dev/null 2>&1
}

warp_do_install(){
  require_root || return 1
  require_singbox_installed || return 1
  ensure_jq || return 1

  render_section_header "${WARP_APP_NAME} - 安装"
  echo -e "  ${D}本模块只修改 /etc/sing-box/config.json，加一个 WireGuard 出站，${N}"
  echo -e "  ${D}并把 geosite google/youtube 命中的流量改走 Cloudflare WARP，其它保持直连。${N}"
  echo -e "  ${D}同时开启域名嗅探（QUIC/TLS SNI），保证按 IP 直连的流量也能命中规则。${N}"
  echo -e "  ${D}账号经 curl 直连 Cloudflare API 注册，不下载任何第三方二进制；${N}"
  echo -e "  ${D}不会动 iptables / 系统路由${N}"
  echo ""

  warp_require_singbox_112 || { pause_screen; return 1; }

  local txn WARP_PRIVATE_KEY WARP_LOCAL_V4 WARP_LOCAL_V6 WARP_PEER_PK WARP_RESERVED
  txn=$(warp_transaction_begin) || { warp_log_err "WARP 事务快照失败"; pause_screen; return 1; }
  if ! warp_register_account || ! warp_load_profile; then
    warp_transaction_rollback "$txn"
    pause_screen
    return 1
  fi

  if ! warp_config_inject "$WARP_LOCAL_V4" "$WARP_LOCAL_V6" "$WARP_PRIVATE_KEY" "$WARP_PEER_PK" "$WARP_RESERVED"; then
    warp_transaction_rollback "$txn"
    warp_log_err "写入 sing-box 配置失败，已恢复原状态"
    pause_screen
    return 1
  fi
  warp_log_ok "sing-box 配置已更新"

  warp_log_info "重启 sing-box..."
  if config_check_and_restart; then
    warp_log_ok "sing-box 已重启，WARP 分流生效"
  else
    warp_transaction_rollback "$txn"
    warp_log_err "sing-box 重启失败，已恢复原账号与配置"
    pause_screen
    return 1
  fi
  warp_transaction_commit "$txn"

  echo ""
  warp_do_test
  pause_screen
}

warp_do_uninstall(){
  require_root || return 1
  render_section_header "${WARP_APP_NAME} - 卸载"
  echo -e "  ${D}从 sing-box 配置中移除 WARP endpoint / 规则集 / 路由规则${N}"
  echo ""
  read -r -p "  确认卸载？[y/N]: " yn
  case "$yn" in [yY]*) ;; *) return ;; esac

  read -r -p "  是否同时删除账号目录 ${WARP_DIR}（含 account.json 与旧版 wgcf 残留）？[y/N]: " yn2

  local txn
  txn=$(warp_transaction_begin) || { warp_log_err "WARP 事务快照失败"; pause_screen; return 1; }
  if ! warp_config_remove || ! config_check_and_restart; then
    warp_transaction_rollback "$txn"
    warp_log_err "移除失败，已恢复原配置"
    pause_screen
    return 1
  fi
  case "$yn2" in
    [yY]*)
      if ! rm -f -- "$WARP_WGCF_BIN" || ! rm -rf -- "$WARP_DIR"; then
        warp_transaction_rollback "$txn"
        warp_log_err "账号文件清理失败，已恢复原状态"
        pause_screen
        return 1
      fi
      ;;
  esac
  warp_transaction_commit "$txn"
  warp_log_ok "已从 sing-box 配置中移除 WARP"
  case "$yn2" in [yY]*) warp_log_ok "账号文件与旧版 wgcf 残留已清理" ;; esac
  pause_screen
}

warp_do_reregister(){
  require_root || return 1
  require_singbox_installed || return 1
  ensure_jq || return 1
  render_section_header "${WARP_APP_NAME} - 重新注册账号"
  echo -e "  ${D}用途：当前 WARP IP 仍被识别为中国，或握手异常时使用${N}"
  echo -e "  ${D}流程：原子生成新账号 → 重新写配置 → 健康检查；失败自动恢复旧账号${N}"
  echo ""
  read -r -p "  确认重新注册？[y/N]: " yn
  case "$yn" in [yY]*) ;; *) return ;; esac

  local txn WARP_PRIVATE_KEY WARP_LOCAL_V4 WARP_LOCAL_V6 WARP_PEER_PK WARP_RESERVED
  txn=$(warp_transaction_begin) || { warp_log_err "WARP 事务快照失败"; pause_screen; return 1; }
  if ! warp_reregister_account \
     || ! warp_load_profile \
     || ! warp_config_inject "$WARP_LOCAL_V4" "$WARP_LOCAL_V6" "$WARP_PRIVATE_KEY" "$WARP_PEER_PK" "$WARP_RESERVED" \
     || ! config_check_and_restart; then
    warp_transaction_rollback "$txn"
    warp_log_err "重新注册失败，已恢复旧账号与配置"
    pause_screen
    return 1
  fi
  warp_transaction_commit "$txn"
  warp_log_ok "完成，已切到新的 WARP 账号"
  pause_screen
}

warp_do_status(){
  render_section_header "${WARP_APP_NAME} - 状态"

  if warp_config_has_outbound; then
    render_info_line "endpoint" "${G}已注入 (tag=${WARP_OUTBOUND_TAG})${N}"
  else
    render_info_line "endpoint" "${R}未注入${N}"
  fi

  if warp_config_has_rule; then
    render_info_line "路由规则" "${G}已生效（google/youtube → ${WARP_OUTBOUND_TAG}）${N}"
  else
    render_info_line "路由规则" "${R}未生效${N}"
  fi

  local ep_host ep_port
  read -r ep_host ep_port <<< "$(warp_current_endpoint)"
  render_info_line "端点" "${ep_host}:${ep_port}"

  if [ -s "$WARP_ACCOUNT_JSON" ]; then
    render_info_line "WARP 账号" "${G}已注册${N} ${D}($(stat -c %y "$WARP_ACCOUNT_JSON" 2>/dev/null | cut -d. -f1))${N}"
  elif [ -f "${WARP_DIR}/wgcf-profile.conf" ]; then
    render_info_line "WARP 账号" "${Y}旧版 wgcf 格式，请「重新注册」迁移${N}"
  else
    render_info_line "WARP 账号" "${R}未注册${N}"
  fi

  if systemctl is-active sing-box >/dev/null 2>&1; then
    render_info_line "sing-box" "${G}运行中${N}"
  else
    render_info_line "sing-box" "${R}未运行${N}"
  fi

  echo ""
  warp_log_info "config.json 中的 WARP 相关片段："
  if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_PATH" ]; then
    jq --arg tag "$WARP_OUTBOUND_TAG" --arg rs "$WARP_RULESET_TAG" --arg rsyt "$WARP_RULESET_TAG_YT" '
      {
        endpoint:  (.endpoints // [] | map(select(.tag == $tag)) | .[0] // null),
        rule_sets: (.route.rule_set // [] | map(select(.tag == $rs or .tag == $rsyt)) | map(.tag)),
        rule:      (.route.rules // [] | map(select((.outbound // "") == $tag)) | .[0] // null)
      }
    ' "$CONFIG_PATH" 2>/dev/null | sed 's/^/    /'
  fi

  pause_screen
}

# 真实隧道自检：起一个临时 sing-box 实例（socks 入站 + 同款 WireGuard endpoint），
# 经隧道 curl Cloudflare trace。成功把 trace 内容打到 stdout 并返回 0。
# 注意：与主进程共用同一 WARP 账号，并发握手会漂移，测试期间主配置分流可能短暂中断。
warp_probe_via_tunnel(){
  local host="$1" port="$2"
  local WARP_PRIVATE_KEY WARP_LOCAL_V4 WARP_LOCAL_V6 WARP_PEER_PK WARP_RESERVED
  warp_load_profile || return 1

  local addr_json
  if [ -n "$WARP_LOCAL_V6" ]; then
    addr_json=$(jq -nc --arg a "$WARP_LOCAL_V4" --arg b "$WARP_LOCAL_V6" '[$a, $b]')
  else
    addr_json=$(jq -nc --arg a "$WARP_LOCAL_V4" '[$a]')
  fi

  local tmpcfg plog sport pid="" try
  tmpcfg=$(mktemp)
  plog=$(mktemp)
  for try in 1 2 3; do
    sport=$(( (RANDOM % 20000) + 30000 ))
    jq -n \
      --arg host "$host" --arg port "$port" \
      --arg pk "$WARP_PRIVATE_KEY" --arg peerpk "$WARP_PEER_PK" \
      --arg reserved "$WARP_RESERVED" \
      --arg addrs "$addr_json" --arg mtu "$WARP_MTU" \
      --argjson sport "$sport" '
      {
        "log": {"disabled": false, "level": "error"},
        "dns": {"servers": [{"type": "local", "tag": "dns-local"}]},
        "inbounds": [{"type": "socks", "tag": "probe-in", "listen": "127.0.0.1", "listen_port": $sport}],
        "endpoints": [{
          "type": "wireguard", "tag": "warp-probe", "system": false,
          "mtu": ($mtu | tonumber), "address": ($addrs | fromjson), "private_key": $pk,
          "peers": [{
            "address": $host, "port": ($port | tonumber), "public_key": $peerpk,
            "allowed_ips": ["0.0.0.0/0", "::/0"],
            "reserved": ($reserved | split(",") | map(tonumber))
          }]
        }],
        "route": {"final": "warp-probe", "default_domain_resolver": "dns-local"}
      }' > "$tmpcfg" 2>/dev/null || { rm -f "$tmpcfg" "$plog"; return 1; }
    sing-box run -c "$tmpcfg" >"$plog" 2>&1 &
    pid=$!
    sleep 1
    kill -0 "$pid" 2>/dev/null && break
    pid=""   # 端口被占等启动失败，换个端口重试
  done
  if [ -z "$pid" ]; then
    warp_log_err "临时 sing-box 实例启动失败："
    tail -5 "$plog" | sed 's/^/    /' >&2
    rm -f "$tmpcfg" "$plog"
    return 1
  fi

  # socks5://（非 socks5h）让 curl 在本机解析域名，探测不依赖隧道内 DNS
  local trace rc
  trace=$(curl -4 -fsS --max-time 12 -x "socks5://127.0.0.1:${sport}" \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
  rc=$?
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  if [ "$rc" -ne 0 ] || [ -z "$trace" ]; then
    if [ -s "$plog" ]; then
      warp_log_warn "临时实例日志（最后几行）："
      tail -3 "$plog" | sed 's/^/    /' >&2
    fi
    rm -f "$tmpcfg" "$plog"
    return 1
  fi
  rm -f "$tmpcfg" "$plog"
  printf '%s\n' "$trace"
}

warp_do_test(){
  warp_log_info "sing-box 配置语法："
  if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
    warp_log_ok "通过"
  else
    warp_log_err "未通过：sing-box check -c $CONFIG_PATH"
    sing-box check -c "$CONFIG_PATH" 2>&1 | sed 's/^/    /'
  fi

  local host port
  read -r host port <<< "$(warp_current_endpoint)"

  echo ""
  warp_log_info "WARP 隧道自检：起临时实例，真实经 ${host}:${port} 走一次隧道（约 10 秒）..."
  echo -e "  ${D}与主服务共用同一 WARP 账号，测试期间分流可能短暂抖动，属正常${N}"
  local trace
  if trace=$(warp_probe_via_tunnel "$host" "$port"); then
    local w ip loc colo
    w=$(printf '%s\n' "$trace"    | awk -F= '/^warp=/ {print $2}')
    ip=$(printf '%s\n' "$trace"   | awk -F= '/^ip=/   {print $2}')
    loc=$(printf '%s\n' "$trace"  | awk -F= '/^loc=/  {print $2}')
    colo=$(printf '%s\n' "$trace" | awk -F= '/^colo=/ {print $2}')
    warp_log_ok "隧道可用：warp=${w:-?}  出口IP=${ip:-?}  区域=${loc:-?}  PoP=${colo:-?}"
    case "$loc" in
      CN|HK|MO|RU)
        warp_log_warn "出口区域 ${loc} 在 Gemini 的不服务名单里，Gemini 仍会拒绝（油管不受影响）"
        echo -e "  ${D}免费 WARP 出口 PoP 由 anycast 路由决定，「重新注册」基本换不了区域；${N}"
        echo -e "  ${D}想真正选区：上 Cloudflare Zero Trust（免费 50 用户）在 device profile 选 PoP，${N}"
        echo -e "  ${D}或用甬哥 warp-yg 的端点优选：https://github.com/yonggekkk/warp-yg${N}"
        ;;
    esac
  else
    warp_log_err "WARP 隧道不通（握手失败或无数据）"
    echo -e "  ${D}最常见原因：本机到 Cloudflare 的 UDP ${port} 被封或严重丢包${N}"
    echo -e "  ${D}处理：菜单「4 端点优选」自动扫描候选 IP:端口；若全部不通，${N}"
    echo -e "  ${D}说明本机 UDP 出网被封，WireGuard/WARP 方案在这台机器不可行${N}"
  fi

  echo ""
  warp_log_info "${B}如何确认 Google 解锁已生效${N}"
  echo -e "  ${D}1.${N} 用客户端（v2rayN/Stash 等）通过 Reality/Hy2 节点连进来"
  echo -e "  ${D}2.${N} 浏览器开 https://www.google.com/search?q=my+ip — Google 应显示 Cloudflare WARP 出口位置"
  echo -e "  ${D}3.${N} 浏览器开 https://gemini.google.com — 应能正常加载"
  echo -e "  ${D}4.${N} 看 sing-box 日志：journalctl -u sing-box -f  — 命中规则的请求会显示 outbound=${WARP_OUTBOUND_TAG}"
}

# 端点优选：逐个测试候选 IP:端口，第一个能通的写入配置并重启
# 适用：默认端点 162.159.192.1:2408 的 UDP 被封/丢包严重时
warp_do_endpoint_pick(){
  require_root || return 1
  render_section_header "${WARP_APP_NAME} - 端点优选"
  if ! warp_config_has_outbound; then
    warp_log_err "尚未安装 WARP 分流，请先安装"
    pause_screen
    return 1
  fi
  echo -e "  ${D}逐个真实测试候选端点（每个最多约 15 秒），第一个能通的写入配置${N}"
  echo -e "  ${D}测试期间 WARP 分流可能短暂中断，完成后自动恢复${N}"
  echo ""

  local cand host port trace txn
  for cand in $WARP_ENDPOINT_CANDIDATES; do
    host="${cand%:*}"
    port="${cand##*:}"
    warp_log_info "测试 ${cand} ..."
    if trace=$(warp_probe_via_tunnel "$host" "$port"); then
      warp_log_ok "可用：${cand}"
      txn=$(warp_transaction_begin) || { warp_log_err "WARP 事务快照失败"; pause_screen; return 1; }
      if ! warp_jq_apply '
          .endpoints = ((.endpoints // []) | map(
            if .tag == $tag
            then (.peers[0].address = $host | .peers[0].port = ($port | tonumber))
            else . end))
        ' --arg tag "$WARP_OUTBOUND_TAG" --arg host "$host" --arg port "$port"; then
        warp_transaction_rollback "$txn"
        warp_log_err "写入配置失败，已恢复原端点"
        pause_screen
        return 1
      fi
      if config_check_and_restart; then
        warp_transaction_commit "$txn"
        warp_log_ok "已切换端点为 ${cand} 并重启 sing-box"
      else
        warp_transaction_rollback "$txn"
        warp_log_err "sing-box 重启失败，已恢复原端点"
        pause_screen
        return 1
      fi
      pause_screen
      return 0
    fi
    warp_log_warn "不通：${cand}"
  done

  warp_log_err "所有候选端点都不通 —— 本机到 Cloudflare 的 UDP 大概率被整段封锁"
  echo -e "  ${D}WireGuard 只能走 UDP，没法换 TCP；这台机器上 WARP 方案基本不可行，${N}"
  echo -e "  ${D}建议换机，或改用「解锁 DNS / 落地中转」类方案${N}"
  pause_screen
}

# 重新注入分流规则：不动账号，只按当前版本的模板重写 endpoint/规则集/路由规则
# 适用：老版本装的 WARP（缺 YouTube 规则集、缺域名嗅探、缺 DNS 解析器）升级修复
warp_do_reinject(){
  require_root || return 1
  require_singbox_installed || return 1
  ensure_jq || return 1
  render_section_header "${WARP_APP_NAME} - 重新注入分流规则"
  echo -e "  ${D}用途：升级旧配置（补 YouTube 规则集 / 域名嗅探 / DNS 解析器 / reserved 字段）或修复被改坏的规则${N}"
  echo -e "  ${D}不改 WARP 账号，不改已优选的端点${N}"
  echo ""

  warp_require_singbox_112 || { pause_screen; return 1; }

  local txn WARP_PRIVATE_KEY WARP_LOCAL_V4 WARP_LOCAL_V6 WARP_PEER_PK WARP_RESERVED
  warp_load_profile || { pause_screen; return 1; }
  txn=$(warp_transaction_begin) || { warp_log_err "WARP 事务快照失败"; pause_screen; return 1; }
  if ! warp_config_inject "$WARP_LOCAL_V4" "$WARP_LOCAL_V6" "$WARP_PRIVATE_KEY" "$WARP_PEER_PK" "$WARP_RESERVED" \
     || ! config_check_and_restart; then
    warp_transaction_rollback "$txn"
    warp_log_err "重新注入失败，已恢复原配置"
    pause_screen
    return 1
  fi
  warp_transaction_commit "$txn"
  warp_log_ok "规则已重新注入，sing-box 已重启"
  pause_screen
}

show_warp_menu(){
  while true; do
    render_section_header "${WARP_APP_NAME}"

    if ! is_singbox_installed; then
      render_info_line "前置条件" "${R}sing-box 未安装${N}"
      render_divider
      echo -e "  请先到「节点管理 → 创建节点」安装 sing-box 与任一节点。"
      render_menu_item 0 "返回上级"
      render_divider
      local choice0
      read -r -p "  请输入序号: " choice0
      case "$choice0" in 0) return ;; *) notify_invalid_choice ;; esac
      continue
    fi

    local installed=0
    warp_config_has_outbound && installed=1

    if [ "$installed" = "1" ]; then
      render_info_line "状态" "${G}已启用（google/youtube → WARP）${N}"
    else
      render_info_line "状态" "${Y}未启用${N}"
    fi
    render_divider

    if [ "$installed" = "1" ]; then
      render_menu_item 1 "查看状态"
      render_menu_item 2 "测试连通性 ${D}（真实走一次 WARP 隧道）${N}"
      render_menu_item 3 "重新注册 WARP 账号 ${D}（换 WARP IP）${N}"
      render_menu_item 4 "端点优选 ${D}（隧道不通时自动换可用 IP:端口）${N}"
      render_menu_item 5 "重新注入分流规则 ${D}（升级旧配置 / 修复规则）${N}"
      render_menu_item 9 "卸载"
    else
      render_menu_item 1 "安装 ${WARP_APP_NAME}"
    fi
    render_menu_item 0 "返回上级"
    render_divider
    local choice
    read -r -p "  请输入序号: " choice

    if [ "$installed" = "0" ]; then
      case "$choice" in
        1) warp_do_install ;;
        0) return ;;
        *) notify_invalid_choice ;;
      esac
      continue
    fi

    case "$choice" in
      1) warp_do_status ;;
      2) render_section_header "${WARP_APP_NAME} - 测试"; warp_do_test; pause_screen ;;
      3) warp_do_reregister ;;
      4) warp_do_endpoint_pick ;;
      5) warp_do_reinject ;;
      9) warp_do_uninstall ;;
      0) return ;;
      *) notify_invalid_choice ;;
    esac
  done
}

# ─── 服务器状态面板 ───────────────────────────────────
