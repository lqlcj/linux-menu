#!/bin/bash
# 临时测试：验证 42-net-bench.sh 的解析与判读逻辑（跑完即删）
cd "$(dirname "$0")"

bash -n src/lib/42-net-bench.sh || { echo "SYNTAX FAIL"; exit 1; }

B=""; C=""; N=""; Y=""; R=""; G=""; D=""
render_info_line(){ printf '  %s: %s\n' "$1" "$2"; }
render_divider(){ :; }
timeout(){ shift; "$@"; }
mtr(){ cat <<'EOF'
Start: 2026-08-02T01:28:11+0800
HOST: leyili        Loss%   Snt   Last   Avg  Best  Wrst StDev
  1.|-- 103.99.179.1   0.0%    50    0.6   1.0   0.6   5.0   1.0
  2.|-- 172.16.0.5    90.0%    50    0.6   0.6   0.5   0.9   0.1
 11.|-- 222.85.122.2   0.0%    50  159.3 159.9 159.1 165.8   1.4
 12.|-- ???           100.0    50    0.0   0.0   0.0   0.0   0.0
EOF
}
source src/lib/42-net-bench.sh

NB_REPORT=$(mktemp)

echo "== 1. mtr 末端响应跳解析 =="
_nb_mtr 1.193.122.235 >/dev/null
echo "   IP=$NB_MTR_IP LOSS=$NB_MTR_LOSS BEST=$NB_MTR_BEST AVG=$NB_MTR_AVG WRST=$NB_MTR_WRST SD=$NB_MTR_STDEV"
if [ "$NB_MTR_IP" = "222.85.122.2" ] && [ "$NB_MTR_AVG" = "159.9" ] && [ "$NB_MTR_STDEV" = "1.4" ]; then
  echo "   PASS"; else echo "   FAIL"; fi

echo "== 2. ss 采样解析（两连接取字节数最大的）=="
NB_TCP_PROBE_FILE=$(mktemp)
cat > "$NB_TCP_PROBE_FILE" <<'EOF'
	 bbr wscale:7,7 rto:364 rtt:12.0/3.0 ato:40 mss:1448 pmtu:1500 cwnd:10 bytes_acked:52341 segs_out:900 retrans:0/2 minrtt:11
	 bbr wscale:7,7 rto:364 rtt:159.2/1.8 ato:40 mss:1440 pmtu:1500 advmss:1448 cwnd:512 bytes_sent:375000000 bytes_acked:374000000 segs_out:259000 segs_in:120000 retrans:0/123 rcv_space:14480 minrtt:158.1
EOF
NB_TCP_PROBE_PID=99999999
_nb_tcp_probe_stop
echo "   RTT=$NB_TCP_RTT VAR=$NB_TCP_RTTVAR MSS=$NB_TCP_MSS PMTU=$NB_TCP_PMTU RET=$NB_TCP_RETRANS SEGS=$NB_TCP_SEGS"
if [ "$NB_TCP_RTT" = "159.2" ] && [ "$NB_TCP_MSS" = "1440" ] && [ "$NB_TCP_RETRANS" = "123" ] && [ "$NB_TCP_SEGS" = "259000" ]; then
  echo "   PASS"; else echo "   FAIL"; fi

echo "== 3. probe report + MTU 折算 (min(1440+40, 1500)=1480) =="
_nb_tcp_probe_report 1.193.122.235 >/dev/null
echo "   MTU_EST=$NB_TCP_MTU_EST"
if [ "$NB_TCP_MTU_EST" = "1480" ]; then echo "   PASS"; else echo "   FAIL"; fi

echo "== 4. 禁 ping + TCP 数据 → 判读走重传率 =="
: > "$NB_REPORT"
NB_LOSS=100; NB_RTT_MIN=""; NB_RTT_AVG=""; NB_RTT_MAX=""; NB_RTT_MDEV=""; NB_BIG_LOSS=""; NB_PMTU=""
_nb_summary 1.193.122.235 >/dev/null
grep '判读:' "$NB_REPORT" | sed 's/^/   /'
if grep -q '实测 TCP 流重传率 0.047' "$NB_REPORT" && ! grep -q '严重丢包' "$NB_REPORT"; then
  echo "   PASS"; else echo "   FAIL"; fi

echo "== 5. 禁 ping 仅 mtr → 判读走末端跳 =="
: > "$NB_REPORT"
NB_TCP_RTT=""; NB_TCP_RTTVAR=""; NB_TCP_SEGS=""; NB_TCP_RETRANS=""; NB_TCP_MTU_EST=""
_nb_summary 1.193.122.235 >/dev/null
grep -E '判读:|RTT' "$NB_REPORT" | sed 's/^/   /'
if grep -q '222.85.122.2 丢包 0.0%，链路本身干净' "$NB_REPORT" && grep -q 'mtr 末端响应跳' "$NB_REPORT"; then
  echo "   PASS"; else echo "   FAIL"; fi

echo "== 6. 正常 ping 路径不受影响 =="
: > "$NB_REPORT"
NB_LOSS=0; NB_RTT_MIN=1.2; NB_RTT_AVG=2.3; NB_RTT_MAX=5.6; NB_RTT_MDEV=0.4; NB_BIG_LOSS=0
_nb_summary 1.193.122.235 >/dev/null
grep -E '判读:|RTT' "$NB_REPORT" | sed 's/^/   /'
if grep -q '无丢包，链路干净' "$NB_REPORT" && grep -q 'ICMP 直测' "$NB_REPORT"; then
  echo "   PASS"; else echo "   FAIL"; fi

rm -f "$NB_REPORT"
