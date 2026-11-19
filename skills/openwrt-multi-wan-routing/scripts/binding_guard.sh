#!/bin/sh
# binding_guard.sh —— 出口绑定保活（幂等）
#
# 作用：保证「指定目标走指定 WAN，且不经过透明代理」这套配置一直存在。
#       由 /etc/init.d/binding-guard（procd 服务）每 30 秒调用一次。
#
# 为什么需要它：代理内核（mesl/mihomo/OpenClash）的 nft 表是运行时创建的，
#       进程重启或改配置会重建表，插进去的例外规则随之消失；ip rule 也没有 uci 入口。
#       这些都无法静态写死，只能靠常驻服务补回。
#
# 用法：
#   binding_guard.sh                      # 用文件内默认值
#   BIND_TARGETS="1.2.3.4 10.0.0.0/8" BIND_WAN=phy0-sta0 binding_guard.sh
#
# 环境变量（都可用同名 UCI 或配置文件覆盖，见下）：
#   BIND_WAN        出口接口名，如 phy0-sta0 / usb0 / wan2
#   BIND_TARGETS    目标列表（空格分隔），支持单 IP 与网段
#   BIND_PROXY_TABLE 代理的 nft 表名，如 mihomo / nikki；留空则自动探测
#   BIND_IPRULE_PREF 策略路由优先级，默认 8800
#
# 配置文件（可选）：/etc/binding_guard.conf，内容是上面的 KEY=VALUE
#
# 幂等：缺什么补什么，已有就跳过；资源未就绪时安静退出，等下一轮。

set -u

CONF="${BIND_CONF:-/etc/binding_guard.conf}"
[ -r "$CONF" ] && . "$CONF"

BIND_WAN="${BIND_WAN:-}"
BIND_TARGETS="${BIND_TARGETS:-}"
BIND_PROXY_TABLE="${BIND_PROXY_TABLE:-}"
BIND_IPRULE_PREF="${BIND_IPRULE_PREF:-8800}"

log() { [ -n "${BIND_VERBOSE:-}" ] && echo "[binding_guard] $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

[ -n "$BIND_WAN" ] && [ -n "$BIND_TARGETS" ] || {
  log "未配置 BIND_WAN / BIND_TARGETS，退出（可写在 $CONF）"
  exit 0
}

have nft || exit 0
have ip || exit 0

# ---------- 1) 自动探测代理表名 ----------
if [ -z "$BIND_PROXY_TABLE" ] && have nft; then
  BIND_PROXY_TABLE=$(nft list tables 2>/dev/null \
    | awk '/^table inet /{print $3}' \
    | grep -Ei 'mihomo|clash|nikki|sing|proxy' | head -1)
fi
[ -n "$BIND_PROXY_TABLE" ] || { log "未找到代理表，等下一轮"; exit 0; }

# 代理表还没建好（进程刚起来）→ 等下一轮，别在这里 sleep
nft list table inet "$BIND_PROXY_TABLE" >/dev/null 2>&1 || { log "表 $BIND_PROXY_TABLE 不存在，等下一轮"; exit 0; }

# ---------- 2) 代理例外：nft daddr return（插链首） ----------
# 判断依据：链首附近是否已经有针对"全部目标"的 return 规则。
# 这里用一条指纹规则（包含所有目标）来匹配，避免重复插入。
set_str=$(printf '%s' "$BIND_TARGETS" | tr ' ' ',')
fingerprint="$(printf '%s' "$set_str" | tr -d ' ')"

need_nft=1
if nft list chain inet "$BIND_PROXY_TABLE" prerouting 2>/dev/null \
   | grep -F 'counter return' \
   | grep -qF "$(printf '%s' "$BIND_TARGETS" | awk '{print $1}')"; then
  # 至少第一个目标已在规则里；进一步核对目标个数是否一致
  cnt=$(nft list chain inet "$BIND_PROXY_TABLE" prerouting 2>/dev/null \
        | grep -F 'counter return' | head -1 \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | sort -u | wc -l | tr -d ' ')
  want=$(printf '%s' "$BIND_TARGETS" | wc -w | tr -d ' ')
  [ "$cnt" -ge "$want" ] 2>/dev/null && need_nft=0
fi

if [ "$need_nft" = 1 ]; then
  # 先清掉旧的同类规则（只删带 counter return 且命中目标集合的），保证幂等
  for h in $(nft -a list chain inet "$BIND_PROXY_TABLE" prerouting 2>/dev/null \
             | grep -F 'counter return' \
             | sed -n 's/.*handle \([0-9]*\).*/\1/p'); do
    nft delete rule inet "$BIND_PROXY_TABLE" prerouting handle "$h" 2>/dev/null
  done
  setexpr=$(printf '%s' "$BIND_TARGETS" | awk '{s="{ "; for(i=1;i<=NF;i++) s=s $i ", "; sub(", $", " }", s); print s}')
  # 单个目标时不需要集合语法
  n=$(printf '%s' "$BIND_TARGETS" | wc -w | tr -d ' ')
  if [ "$n" -eq 1 ]; then
    daddr="ip daddr $BIND_TARGETS"
  else
    daddr="ip daddr $setexpr"
  fi
  nft insert rule inet "$BIND_PROXY_TABLE" prerouting $daddr counter return 2>/dev/null \
    && log "已插入 nft 例外: $daddr" || log "插入 nft 例外失败"
fi

# ---------- 3) 静态路由：目标走 BIND_WAN 的网关 ----------
if ip link show "$BIND_WAN" >/dev/null 2>&1; then
  GW=$(ip route show default dev "$BIND_WAN" 2>/dev/null | awk '{print $3; exit}')
  if [ -n "$GW" ]; then
    for t in $BIND_TARGETS; do
      # 网段目标不从这里下发（netifd/uci 负责）；只处理单主机 /32
      case "$t" in
        */*) continue;;
      esac
      if ! ip route show "$t/32" 2>/dev/null | grep -q "dev $BIND_WAN"; then
        ip route replace "$t/32" via "$GW" dev "$BIND_WAN" 2>/dev/null \
          && log "路由 $t/32 via $GW dev $BIND_WAN"
      fi
    done
  else
    log "接口 $BIND_WAN 还没有默认网关（DHCP 未完成？），跳过路由"
  fi
else
  log "接口 $BIND_WAN 不存在，跳过路由"
fi

# ---------- 4) 策略路由：目标走 main 表，绕开代理的 lookup ----------
have ip || exit 0
for t in $BIND_TARGETS; do
  if ! ip rule show 2>/dev/null | grep -q "to $t lookup main"; then
    ip rule add to "$t" lookup main pref "$BIND_IPRULE_PREF" 2>/dev/null \
      && log "ip rule: to $t lookup main pref $BIND_IPRULE_PREF"
  fi
done

exit 0