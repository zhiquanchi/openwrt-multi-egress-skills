#!/bin/sh
# wan_check.sh —— 逐条上行探测：通不通、是不是被门户拦
#
# 用法：
#   sh wan_check.sh                 # 自动探测所有疑似上行
#   sh wan_check.sh phy0-sta0       # 只测指定接口
#
# 判定四种状态：
#   DOWN    接口不存在/没地址
#   BLOCKED 能到网关，但上网被拦（多为门户认证未完成）
#   LIMITED 能 ping 通但 HTTPS 不通（DNS/防火墙/MTU 问题）
#   OK      正常
#
# 兼容 busybox ash；只读取 + 发探测包，不改配置。

set -u

have() { command -v "$1" >/dev/null 2>&1; }

# 自动收集疑似上行
collect() {
  if [ $# -gt 0 ]; then
    echo "$@"
    return
  fi
  ip -br link 2>/dev/null | awk '{print $1}' \
    | grep -vE '^(lo|ifb|Meta|br-|tap|veth|wlan.*-ap|.*-ap.*)$' \
    | while read -r i; do
        # 只保留有默认路由或属于 wan/sta 类别的接口
        if ip route show default dev "$i" 2>/dev/null | grep -q . || echo "$i" | grep -qE '^(wan|wwan|phy.*-sta|usb|eth[0-9]+$)'; then
          echo "$i"
        fi
      done
}

check_one() {
  iface="$1"
  printf '\n--- %s ---\n' "$iface"

  # 用 /sys/class/net 判断接口是否存在：不依赖 `ip` 的退出码（不同系统不一致）
  if [ ! -d "/sys/class/net/$iface" ]; then
    # 没有 /sys（非 Linux）时退回到 `ip link`
    if ! ip link show "$iface" >/dev/null 2>&1; then
      echo "  状态: DOWN（接口不存在）"
      return
    fi
  fi

  addr=$(ip -4 -br addr show "$iface" 2>/dev/null | awk '{print $3}')
  if [ -z "$addr" ]; then
    echo "  状态: DOWN（没有 IPv4 地址）"
    return
  fi
  echo "  地址: $addr"

  gw=$(ip route show default dev "$iface" 2>/dev/null | awk '{print $3; exit}')
  echo "  网关: ${gw:-未学到}"

  # 1) 网关可达？
  if [ -n "$gw" ]; then
    if ping -c 2 -W 2 -I "$iface" "$gw" >/dev/null 2>&1; then
      echo "  网关: 可达"
    else
      echo "  网关: 不可达（链路层或对端问题）"
    fi
  fi

  # 2) 公网 ICMP
  if ping -c 2 -W 2 -I "$iface" 8.8.8.8 >/dev/null 2>&1; then
    echo "  公网ICMP: 通"
    icmp=1
  else
    echo "  公网ICMP: 不通（门户拦截很常见，继续测 HTTP）"
    icmp=0
  fi

  # 3) HTTP 是否被重定向到门户
  http=$(curl -s -m 6 -I --interface "$iface" http://connect.rom.miui.com/generate_204 2>/dev/null | head -1)
  case "$http" in
    *" 204"*) echo "  HTTP 204探测: 正常"; http_ok=1 ;;
    *" 302"*|*" 301"*)
      loc=$(curl -s -m 6 -I --interface "$iface" http://connect.rom.miui.com/generate_204 2>/dev/null \
            | grep -i '^location:' | head -1 | tr -d '\r')
      echo "  HTTP 204探测: 被重定向（疑似门户）"
      echo "  ${loc:-}"
      http_ok=0 ;;
    "") echo "  HTTP 204探测: 无响应（端口被拦或超时）"; http_ok=0 ;;
    *) echo "  HTTP 204探测: $http"; http_ok=0 ;;
  esac

  # 4) HTTPS
  https=$(curl -s -m 8 -o /dev/null -w '%{http_code}' --interface "$iface" https://www.baidu.com 2>/dev/null)
  case "$https" in
    200|301|302) echo "  HTTPS: 正常 ($https)"; https_ok=1 ;;
    "") echo "  HTTPS: 超时/被拦"; https_ok=0 ;;
    *) echo "  HTTPS: 异常 ($https)"; https_ok=0 ;;
  esac

  # 5) 出口 IP（如果能出去）
  if [ "$https_ok" = 1 ]; then
    eip=$(curl -s -m 8 --interface "$iface" https://api.ipify.org 2>/dev/null)
    echo "  出口IP: ${eip:-未知}"
  fi

  # 汇总结论
  printf '  >>> '
  if [ "$https_ok" = 1 ] && [ "$http_ok" = 1 ]; then
    echo "OK（线路正常）"
  elif [ "$https_ok" = 0 ] && echo "$http" | grep -q ' 302'; then
    echo "BLOCKED（需要门户认证：从 LAN 侧浏览器打开上面的登录页）"
  elif [ "$icmp" = 0 ] && [ "$https_ok" = 0 ]; then
    echo "BLOCKED（完全无法上网：门户未认证 / 对端限制 / 账号问题）"
  else
    echo "LIMITED（部分可用：检查 DNS、MTU、对端 ACL）"
  fi
}

echo "=================================================="
echo " 上行线路探测  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="

if ! have curl; then
  echo "需要 curl：opkg install curl"
  exit 1
fi

if ! have ip; then
  echo "需要 iproute2 的 ip 命令（OpenWrt 自带；macOS 请先 brew install iproute2mac）"
  exit 1
fi

for i in $(collect "$@"); do
  check_one "$i"
done

echo
echo "=================================================="
echo "说明："
echo "  BLOCKED + 有 location 头 = 门户认证未完成，先去浏览器登录"
echo "  BLOCKED + HTTPS 全超时    = 该线路根本没出口，别在分流上找原因"
echo "  OK 但指定流量仍不通        = 问题在分流/代理劫持，见 references/"
echo "=================================================="