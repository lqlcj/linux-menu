warp_log_ok()   { echo -e "  ${G}✓${N} $*" >&2; }
warp_log_info() { echo -e "  ${C}●${N} $*" >&2; }
warp_log_warn() { echo -e "  ${Y}⚠${N} $*" >&2; }
warp_log_err()  { echo -e "  ${R}✗${N} $*" >&2; }

warp_detect_arch(){
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l|armv7) printf 'armv7' ;;
    *) printf 'unknown' ;;
  esac
}

warp_install_wgcf(){
  if [ -x "$WARP_WGCF_BIN" ]; then
    return 0
  fi
  local arch tag url
  arch=$(warp_detect_arch)
  if [ "$arch" = "unknown" ]; then
    warp_log_err "不支持的架构：$(uname -m)"
    return 1
  fi
  warp_log_info "下载 wgcf（${arch}）..."
  tag=$(curl -fsSL --max-time 10 "$WARP_WGCF_RELEASE_API" 2>/dev/null | jq -r '.tag_name' 2>/dev/null)
  if [ -z "$tag" ] || [ "$tag" = "null" ]; then
    warp_log_warn "GitHub API 取版本失败，回退固定版本 v2.2.19"
    tag="v2.2.19"
  fi
  url="https://github.com/ViRb3/wgcf/releases/download/${tag}/wgcf_${tag#v}_linux_${arch}"
  if ! curl -fsSL --max-time 60 "$url" -o "$WARP_WGCF_BIN"; then
    warp_log_err "wgcf 下载失败：$url"
    return 1
  fi
  chmod +x "$WARP_WGCF_BIN"
  warp_log_ok "wgcf 安装完成（${tag}）"
}

warp_register_account(){
  mkdir -p "$WARP_DIR"
  # 三种状态：
  #  - 两个文件都在  → 跳过
  #  - 只有 account 在 → 只跑 generate
  #  - 都没有         → register + generate
  if [ -f "$WARP_WGCF_ACCOUNT" ] && [ -f "$WARP_WGCF_PROFILE" ]; then
    return 0
  fi

  local log
  log=$(mktemp)

  if [ ! -f "$WARP_WGCF_ACCOUNT" ]; then
    warp_log_info "向 Cloudflare 注册 WARP 账号..."
    if ! ( cd "$WARP_DIR" && "$WARP_WGCF_BIN" register --accept-tos ) >"$log" 2>&1; then
      warp_log_err "wgcf register 失败，原始输出："
      sed 's/^/    /' "$log"
      echo ""
      echo -e "  ${D}排查建议：${N}"
      echo -e "  ${D}1) 手动跑：cd ${WARP_DIR} && ${WARP_WGCF_BIN} register --accept-tos${N}"
      echo -e "  ${D}2) 若提示 429/Too Many Requests，等 5 分钟再试（Cloudflare 限流）${N}"
      echo -e "  ${D}3) 若提示 TLS/handshake 错误，检查时间是否同步：date${N}"
      rm -f "$log"
      return 1
    fi
    warp_log_ok "账号已注册：${WARP_WGCF_ACCOUNT}"
  else
    warp_log_info "已存在 wgcf-account.toml，跳过 register"
  fi

  warp_log_info "生成 WireGuard 配置..."
  if ! ( cd "$WARP_DIR" && "$WARP_WGCF_BIN" generate ) >"$log" 2>&1; then
    warp_log_err "wgcf generate 失败，原始输出："
    sed 's/^/    /' "$log"
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
  warp_log_ok "WARP 账号已生成：${WARP_WGCF_PROFILE}"
}

warp_reregister_account(){
  rm -f "$WARP_WGCF_ACCOUNT" "$WARP_WGCF_PROFILE"
  warp_register_account
}

# 解析 wgcf-profile.conf，输出 KEY=VALUE 行供 eval 使用
# 兼容两种格式：
#   - 旧版：两条独立 Address 行（v4 一条、v6 一条）
#   - wgcf v2.2.30+：一条 Address 行，v4/v6 用逗号分隔
warp_parse_profile(){
  local f="$WARP_WGCF_PROFILE"
  [ -f "$f" ] || { warp_log_err "wgcf 配置缺失：$f"; return 1; }
  local pk addr_blob v4 v6 one
  pk=$(awk '/^[[:space:]]*PrivateKey[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' "$f" | tr -d ' \r')
  # 收集所有 Address 行（不带 ; exit），合并后按逗号拆，逐段按是否含 ':' 分流到 v4/v6
  addr_blob=$(awk '/^[[:space:]]*Address[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); print}' "$f" | tr -d '\r')
  while IFS= read -r one; do
    one="${one//[[:space:]]/}"
    [ -z "$one" ] && continue
    if [[ "$one" == *:* ]]; then
      [ -z "$v6" ] && v6="$one"
    else
      [ -z "$v4" ] && v4="$one"
    fi
  done < <(printf '%s\n' "$addr_blob" | tr ',' '\n')
  if [ -z "$pk" ] || [ -z "$v4" ]; then
    warp_log_err "解析 wgcf 配置失败（缺 PrivateKey 或 IPv4 Address）"
    warp_log_err "请检查：cat $f"
    return 1
  fi
  printf 'WARP_PRIVATE_KEY=%s\n' "$pk"
  printf 'WARP_LOCAL_V4=%s\n'    "$v4"
  printf 'WARP_LOCAL_V6=%s\n'    "$v6"
}

# 安全编辑 sing-box 配置：写临时文件 → sing-box check 通过后才覆盖
warp_jq_apply(){
  local jq_filter="$1"
  shift
  local tmp
  tmp=$(mktemp) || return 1
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
  mv "$tmp" "$CONFIG_PATH"
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

warp_config_inject(){
  local v4="$1" v6="$2" pk="$3"
  ensure_jq || return 1
  [ -f "$CONFIG_PATH" ] || { warp_log_err "config.json 不存在：$CONFIG_PATH"; return 1; }
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
              "reserved": [0, 0, 0]
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
        [{"action": "sniff"}]
        + ((.route.rules // []) | map(select(((.outbound // "") != $tag) and ((.action // "") != "sniff"))))
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
    --arg peerpk  "$WARP_PEER_PUBLIC_KEY" \
    --arg addrs   "$addr_json"
}

warp_config_remove(){
  ensure_jq || return 1
  [ -f "$CONFIG_PATH" ] || return 0
  warp_jq_apply '
      .endpoints = ((.endpoints // []) | map(select(.tag != $tag)))
    | .route = (.route // {})
    | .route.rule_set = ((.route.rule_set // []) | map(select(.tag != $rs and .tag != $rsyt)))
    | .route.rules = ((.route.rules // []) | map(select(((.outbound // "") != $tag) and ((.action // "") != "sniff"))))
  ' \
    --arg tag  "$WARP_OUTBOUND_TAG" \
    --arg rs   "$WARP_RULESET_TAG" \
    --arg rsyt "$WARP_RULESET_TAG_YT"
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
  echo -e "  ${D}不会动 iptables / 系统路由${N}"
  echo ""

  warp_install_wgcf     || { pause_screen; return 1; }
  warp_register_account || { pause_screen; return 1; }

  local kv
  kv=$(warp_parse_profile) || { pause_screen; return 1; }
  eval "$kv"

  warp_config_inject "$WARP_LOCAL_V4" "$WARP_LOCAL_V6" "$WARP_PRIVATE_KEY" \
    || { warp_log_err "写入 sing-box 配置失败"; pause_screen; return 1; }
  warp_log_ok "sing-box 配置已更新"

  warp_log_info "重启 sing-box..."
  if config_check_and_restart; then
    warp_log_ok "sing-box 已重启，WARP 分流生效"
  else
    warp_log_err "sing-box 重启失败，请用 journalctl -u sing-box 查看"
    pause_screen
    return 1
  fi

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

  warp_config_remove || { warp_log_err "移除失败"; pause_screen; return 1; }
  config_check_and_restart >/dev/null 2>&1 || true
  warp_log_ok "已从 sing-box 配置中移除 WARP"

  read -r -p "  是否同时删除 wgcf 二进制 与 ${WARP_DIR}（含账号）？[y/N]: " yn2
  case "$yn2" in
    [yY]*)
      rm -f "$WARP_WGCF_BIN"
      rm -rf "$WARP_DIR"
      warp_log_ok "wgcf 与账号文件已清理"
      ;;
  esac
  pause_screen
}

warp_do_reregister(){
  require_root || return 1
  render_section_header "${WARP_APP_NAME} - 重新注册账号"
  echo -e "  ${D}用途：当前 WARP IP 仍被识别为中国，或握手异常时使用${N}"
  echo -e "  ${D}流程：删旧账号 → 重新 register → 重新写 sing-box 配置 → 重启 sing-box${N}"
  echo ""
  read -r -p "  确认重新注册？[y/N]: " yn
  case "$yn" in [yY]*) ;; *) return ;; esac

  warp_reregister_account || { pause_screen; return 1; }

  local kv
  kv=$(warp_parse_profile) || { pause_screen; return 1; }
  eval "$kv"

  warp_config_inject "$WARP_LOCAL_V4" "$WARP_LOCAL_V6" "$WARP_PRIVATE_KEY" \
    || { pause_screen; return 1; }
  config_check_and_restart && warp_log_ok "完成，已切到新的 WARP 账号" \
                          || warp_log_err "sing-box 重启失败"
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

  if [ -f "$WARP_WGCF_ACCOUNT" ]; then
    render_info_line "WARP 账号" "${G}已注册${N} ${D}($(stat -c %y "$WARP_WGCF_ACCOUNT" 2>/dev/null | cut -d. -f1))${N}"
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
  local kv
  kv=$(warp_parse_profile) || return 1
  local WARP_PRIVATE_KEY WARP_LOCAL_V4 WARP_LOCAL_V6
  eval "$kv"

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
      --arg pk "$WARP_PRIVATE_KEY" --arg peerpk "$WARP_PEER_PUBLIC_KEY" \
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
            "allowed_ips": ["0.0.0.0/0", "::/0"], "reserved": [0, 0, 0]
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

  local cand host port trace
  for cand in $WARP_ENDPOINT_CANDIDATES; do
    host="${cand%:*}"
    port="${cand##*:}"
    warp_log_info "测试 ${cand} ..."
    if trace=$(warp_probe_via_tunnel "$host" "$port"); then
      warp_log_ok "可用：${cand}"
      if ! warp_jq_apply '
          .endpoints = ((.endpoints // []) | map(
            if .tag == $tag
            then (.peers[0].address = $host | .peers[0].port = ($port | tonumber))
            else . end))
        ' --arg tag "$WARP_OUTBOUND_TAG" --arg host "$host" --arg port "$port"; then
        warp_log_err "写入配置失败"
        pause_screen
        return 1
      fi
      if config_check_and_restart; then
        warp_log_ok "已切换端点为 ${cand} 并重启 sing-box"
      else
        warp_log_err "sing-box 重启失败，请用 journalctl -u sing-box 查看"
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
  render_section_header "${WARP_APP_NAME} - 重新注入分流规则"
  echo -e "  ${D}用途：升级旧配置（补 YouTube 规则集 / 域名嗅探 / DNS 解析器）或修复被改坏的规则${N}"
  echo -e "  ${D}不改 WARP 账号，不改已优选的端点${N}"
  echo ""

  local kv
  kv=$(warp_parse_profile) || { pause_screen; return 1; }
  eval "$kv"

  warp_config_inject "$WARP_LOCAL_V4" "$WARP_LOCAL_V6" "$WARP_PRIVATE_KEY" \
    || { pause_screen; return 1; }
  config_check_and_restart && warp_log_ok "规则已重新注入，sing-box 已重启" \
                          || warp_log_err "sing-box 重启失败，请用 journalctl -u sing-box 查看"
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

# ═══════════════════════════════════════════════════════════════════════
# Realm 中转管理模块
# ─────────────────────────────────────────────────────────────────────
# 用途   : 在中转机上跑纯端口转发（透传，不解密），把流量原样送到落地机
# 二进制 : zhboner/realm（Rust 实现，支持 TCP+UDP）
# 配置   : /etc/realm/config.toml ，TOML 格式，[[endpoints]] 数组
# 服务   : realm.service（独立 systemd unit，与 sing-box 互不干扰）
# 边界   : 不做加密隧道 / 负载均衡 / 端口段转发；这些进阶功能请用 realm-xwPF
# 适用   : 客户端 → 中转机(realm) → 落地机(sing-box) → 互联网
#          客户端 SNI/UUID/pbk 全部用落地机的，realm 不参与加密握手
# ═══════════════════════════════════════════════════════════════════════

# ─── 底层探测 ─────────────────────────────────────────
