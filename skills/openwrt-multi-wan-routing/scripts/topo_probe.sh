#!/bin/sh
# topo_probe.sh —— OpenWrt 多 WAN 拓扑一次性采集
#
# 用法： sh topo_probe.sh
# 兼容： OpenWrt / Kwrt / ImmortalWrt 的 busybox ash
# 输出： 带 ===== 分隔，可直接整段贴回给排障方
#
# 只读取状态，不修改任何配置。

set -u

say() { printf '\n===== %s =====\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "[1] 系统"
[ -r /etc/openwrt_release ] && grep -E 'DISTRIB_(ID|RELEASE|TARGET|ARCH)' /etc/openwrt_release 2>/dev/null
uname -sr
[ -r /tmp/sysinfo/model ] && echo "model: $(cat /tmp/sysinfo/model)"
[ -r /tmp/sysinfo/board_name ] && echo "board: $(cat /tmp/sysinfo/board_name)"

say "[2] 接口与地址"
ip -br link 2>/dev/null | grep -v '^ifb' | grep -v '^Meta'
echo "--- IPv4 ---"
ip -4 -br addr 2>/dev/null | grep -v '^ifb' | grep -v '^Meta'

say "[3] 默认路由与 metric（metric 小 = 优先）"
ip route show default 2>/dev/null
echo "--- 全部路由表（非 main）---"
ip route show table all 2>/dev/null \
  | grep -vE '^(broadcast|local|unreachable|ff00|fe80)' \
  | awk '/table/ && $NF != "main" && !/ table main/ {print}' \
  | head -20
echo "--- 策略路由 ip rule ---"
ip rule show 2>/dev/null

say "[4] 上行类型判断"
for i in $(ip -br link 2>/dev/null | awk '{print $1}' | grep -vE '^(lo|ifb|Meta|br-|tap|veth)'); do
  printf ' %-14s ' "$i"
  [ -d "/sys/class/net/$i/wireless" ] && printf 'wireless ' 
  [ -d "/sys/class/net/$i/dsa" ] && printf 'dsa '
  [ -e "/sys/class/net/$i/device/uevent" ] && printf 'pci/usb '
  case "$i" in
    *-sta*) printf 'STA(客户端)';;
    *-ap*)  printf 'AP(内网接入)';;
    br-lan) printf 'bridge';;
  esac
  echo
done

say "[5] 无线：射频能力与当前连接"
if have iw; then
  for phy in /sys/class/ieee80211/*; do
    [ -e "$phy" ] || continue
    p=$(basename "$phy")
    echo "--- $p ---"
    iw phy "$p" info 2>/dev/null | grep -A5 'valid interface combinations' | head -8
    iw phy "$p" info 2>/dev/null | grep -E '^\s+\* [0-9]+ MHz' | head -4
  done
else
  echo "iw 未安装"
fi
echo "--- 当前无线状态 ---"
if have iwinfo; then
  iwinfo 2>/dev/null | grep -E '^\S|ESSID|Mode|Channel|Signal'
else
  ubus call network.wireless status 2>/dev/null | grep -E 'up|ssid|channel|mode|ifname' | head -30
fi

say "[6] 有线：DSA 端口与 bridge 成员"
ls -d /sys/class/net/*/dsa 2>/dev/null
echo "--- br-lan 成员 ---"
ls /sys/class/net/br-lan/brif 2>/dev/null

say "[7] WAN 协议族支持"
ls /lib/netifd/proto/ 2>/dev/null

say "[8] 已装的代理与多 WAN 相关包"
if have opkg; then
  opkg list-installed 2>/dev/null | grep -Ei 'clash|mihomo|mesl|passwall|sing-box|xray|mwan3|kmod-usb-net|usbutils' | head -20
fi

say "[9] 透明代理劫持检查（关键）"
echo "--- nft 表 ---"
have nft && nft list tables 2>/dev/null | head -20
echo "--- 各表 prerouting 是否有 redirect/tproxy ---"
if have nft; then
  for tbl in $(nft list tables 2>/dev/null | awk '{print $2" "$3}'); do
    fam=$(echo "$tbl" | awk '{print $1}')
    name=$(echo "$tbl" | awk '{print $2}')
    hit=$(nft list chain "$fam" "$name" prerouting 2>/dev/null | grep -cE 'redirect|tproxy')
    [ "$hit" -gt 0 ] 2>/dev/null && echo "  $fam $name: prerouting 中有 $hit 条 redirect/tproxy"
  done
fi
echo "--- 代理进程 ---"
ps 2>/dev/null | grep -Ei 'mihomo|clash|mesl|xray|sing-box' | grep -v ' grep ' | head -5

say "[10] 当前出口 IP（默认路线）"
have curl && { curl -s -m 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^(ip|loc)=' || echo "取出口失败"; }

say "完成"
echo "把整段贴回给排障方；公网 IP 可自行打码。"