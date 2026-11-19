#!/bin/sh
# egress_verify.sh —— 修复后的出口一致性验证
#
# 作用：连续多次、针对不同目标取"出口 IP"，确认它们一致；
#       再把本应走同一组出口的域名逐个解析，人工/脚本比对是否落到同一策略组。
#
# 用法：
#   sh egress_verify.sh                     # 默认：取 5 次出口 IP + 解析 Google 域名
#   sh egress_verify.sh --proxy 127.0.0.1:7890
#   sh egress_verify.sh --ip 8.8.8.8        # 指定走某个 DNS 解析
#
# 说明：
#   - 出口 IP 用 cloudflare trace / ipify 两个独立端点交叉验证；
#   - 域名解析结果只用于观察是否分流到不同 CDN/不同落地（fake-ip 环境下会显示 198.18.x.x，属正常）；
#   - 不探测 QUIC；TCP 出口一致后仍有问题，多半是 UDP/443 或 IPv6 路径不同。

set -u

PROXY=""
DNS_SERVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --proxy) PROXY="$2"; shift 2 ;;
    --ip) DNS_SERVER="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

PROXY_ARGS=""
[ -n "$PROXY" ] && PROXY_ARGS="--proxy http://$PROXY"

probe_ip() {  # $1 = 额外 curl 参数（如 -4 / -6），$2 = url
  curl -s -m 10 $PROXY_ARGS $1 "$2" 2>/dev/null
}

resolve() {  # $1 = domain
  if [ -n "$DNS_SERVER" ] && command -v nslookup >/dev/null 2>&1; then
    nslookup "$1" "$DNS_SERVER" 2>/dev/null | awk '/^Address: */{print $2}' | grep -v '#' | head -3 | tr '\n' ' '
  elif command -v getent >/dev/null 2>&1; then
    getent hosts "$1" 2>/dev/null | awk '{print $1}' | head -3 | tr '\n' ' '
  elif command -v nslookup >/dev/null 2>&1; then
    nslookup "$1" 2>/dev/null | awk '/^Address: */{print $2}' | grep -v '#' | head -3 | tr '\n' ' '
  else
    echo "(缺少 getent/nslookup)"
  fi
}

echo "=================================================="
echo " 出口一致性验证$( [ -n "$PROXY" ] && echo "（经代理 $PROXY）" )"
echo " 时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="
echo
echo "[1] 出口 IP（两个独立端点 + 连续采样，应始终相同）"
echo "--------------------------------------------------"

# IPv4 与 IPv6 分开统计：同一时刻两者都不是同一个 IP，混在一起必然误报
V4_IPS=""
for i in 1 2 3; do
  ip=$(probe_ip "-4" "https://api.ipify.org")
  [ -n "$ip" ] && V4_IPS="$V4_IPS $ip"
done
V6_IPS=""
for i in 1 2; do
  ip=$(probe_ip "-6" "https://api.ipify.org")
  [ -n "$ip" ] && V6_IPS="$V6_IPS $ip"
done
# 不信任 curl 的 -4/-6（代理或系统可能静默回退），统一按地址形态归类
is_v6() { case "$1" in *:*) return 0;; *) return 1;; esac; }

ALL_IPS=""
for i in 1 2 3; do
  ip=$(probe_ip "-4" "https://api.ipify.org")
  [ -n "$ip" ] && ALL_IPS="$ALL_IPS $ip"
done
for i in 1 2; do
  ip=$(probe_ip "-6" "https://api.ipify.org")
  [ -n "$ip" ] && ALL_IPS="$ALL_IPS $ip"
done
for i in 1 2; do
  ip=$(probe_ip "" "https://www.cloudflare.com/cdn-cgi/trace" | grep -E '^ip=' | cut -d= -f2)
  [ -n "$ip" ] && ALL_IPS="$ALL_IPS $ip"
done

V4_IPS=""
V6_IPS=""
for ip in $ALL_IPS; do
  if is_v6 "$ip"; then V6_IPS="$V6_IPS $ip"; else V4_IPS="$V4_IPS $ip"; fi
done

echo " 采集到的出口 IP  :${ALL_IPS:- (失败)}"
echo " 其中 IPv4        :${V4_IPS:- (无)}"
echo " 其中 IPv6        :${V6_IPS:- (无)}"

UNIQ_V4=$(printf '%s\n' "$V4_IPS" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
COUNT_V4=$(printf '%s' "$UNIQ_V4" | wc -w | tr -d ' ')
UNIQ_V6=$(printf '%s\n' "$V6_IPS" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
COUNT_V6=$(printf '%s' "$UNIQ_V6" | wc -w | tr -d ' ')

echo
echo " IPv4 去重后     : ${UNIQ_V4:- (无)}  [协议内唯一=${COUNT_V4}]"
echo " IPv6 去重后     : ${UNIQ_V6:- (无)}  [协议内唯一=${COUNT_V6}]"
echo
echo " 注意：IPv4 与 IPv6 是两个不同的出口地址，不能互相比较；"
echo "       若 Google 页面里两串 IP 一个是 IPv4 一个是 IPv6（如 1.2.3.4 ≠ 2a09:...），"
echo "       那是 IPv6 绕过了代理，属于另一类问题，见 references/symptom-triage.md 第四节。"

echo
echo "[2] 本应同组出口的域名解析（fake-ip 环境显示 198.18.x.x 属正常）"
echo "--------------------------------------------------"
for d in gemini.google.com accounts.google.com ssl.gstatic.com www.googleapis.com generativelanguage.googleapis.com; do
  printf ' %-42s %s\n' "$d" "$(resolve "$d")"
done

echo
echo "================== 结论 =================="
if [ -z "$UNIQ_V4" ] && [ -z "$UNIQ_V6" ]; then
  echo "一个出口 IP 都没取到：网络不通或代理不可用，先修连通性再看分流。"
  exit 1
elif [ "$COUNT_V4" -gt 1 ] || [ "$COUNT_V6" -gt 1 ]; then
  echo "同一协议内出口 IP 不一致（同时出现多个）："
  [ "$COUNT_V4" -gt 1 ] && echo "  IPv4: $UNIQ_V4"
  [ "$COUNT_V6" -gt 1 ] && echo "  IPv6: $UNIQ_V6"
  echo "说明同一台机器在不同时刻/不同连接上走了不同出口，属持续双出口状态。"
  echo "回 references/fix-strategies.md 检查策略组与规则归属。"
  exit 2
else
  echo "各协议内出口唯一：IPv4=${UNIQ_V4:-无} IPv6=${UNIQ_V6:-无}"
  echo "同协议内 TCP 出口已收敛。若浏览器仍报 IP A ≠ IP B，请依次排查："
  echo "  1) QUIC（UDP/443）是否走了另一条链 —— 临时禁 UDP/443 复测"
  echo "  2) IPv6 是否绕过代理（页面里 A 是 IPv4、B 是 IPv6 即属此类）"
  echo "  3) 之前打开的长连接是否还挂在旧出口 —— 无痕窗口重开、面板里关掉旧连接"
  echo "  4) 是否是多上行（双 WAN/双 WiFi）在按目的地址选路"
  exit 0
fi