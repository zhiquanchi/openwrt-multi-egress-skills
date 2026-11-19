#!/bin/sh
# diag-egress.sh —— OpenWrt 代理双出口诊断（一次性收集）
#
# 用法：
#   sh diag-egress.sh                 # 自动探测代理内核与配置
#   sh diag-egress.sh /path/to/cfg    # 指定运行时配置文件
#
# 兼容：OpenWrt / Kwrt / ImmortalWrt 的 busybox ash，只依赖 ps/ls/grep/awk/sed/curl。
# 安全：不会 echo 任何密钥内容，密钥只在子 shell 里以 $(cat ...) 形式使用。
# 输出：带 ===== 分隔符，尽量可以直接整段贴回给排障方。

set -u

CFG="${1:-}"

say() { printf '\n===== %s =====\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- 1. 系统
say "[1] 系统"
if [ -r /etc/openwrt_release ]; then
  grep -E 'DISTRIB_(ID|RELEASE|TARGET|ARCH)' /etc/openwrt_release 2>/dev/null
fi
uname -sr
[ -r /etc/os-release ] && grep -E '^PRETTY_NAME' /etc/os-release 2>/dev/null

# ---------------------------------------------------------------- 2. 内核进程
say "[2] 正在运行的代理进程（决定该改谁）"
ps 2>/dev/null | grep -Ei 'clash|mihomo|mesl|xray|sing-box|ssr-|shadowsocks|v2ray|trojan|hysteria|passwall|naive' \
  | grep -v ' grep ' | head -20

# ---------------------------------------------------------------- 3. 已装的插件
say "[3] 已安装的代理相关软件包（仅供参考，不代表在运行）"
if have opkg; then
  opkg list-installed 2>/dev/null | grep -Ei 'clash|mihomo|mesl|passwall|ssr|xray|sing-box|v2ray|trojan' | head -20
fi

# ---------------------------------------------------------------- 4. 定位配置文件
say "[4] 配置文件定位"
if [ -z "$CFG" ]; then
  # 优先从进程参数里抄 -f / --config / -c 后面跟的路径
  CFG=$(ps 2>/dev/null | grep -Ei 'mihomo|clash|sing-box|xray' | grep -v ' grep ' \
        | sed -n 's/.*[[:space:]]\(-f\|--config\|-c\)[[:space:]]\{1,\}\([^[:space:]]*\).*/\2/p' | head -1)
fi
if [ -n "$CFG" ] && [ -r "$CFG" ]; then
  echo "runtime config: $CFG"
  ls -la "$CFG"
else
  CFG=""
  echo "未从进程参数识别到运行配置，尝试常见路径："
  for f in /dev/shm/mesl-0/runtime.yaml \
           /etc/mihomo/config.yaml /etc/openclash/config.yaml \
           /etc/sing-box/config.json /etc/xray/config.json /usr/local/etc/xray/config.json; do
    [ -r "$f" ] && { echo "found: $f"; CFG="$f"; break; }
  done
fi

say "[4b] 数据目录 / 订阅源"
for d in /etc/mesl /etc/mihomo /etc/openclash /etc/sing-box /etc/xray; do
  [ -d "$d" ] && { echo "--- $d ---"; ls -la "$d" 2>/dev/null | head -30; }
done

[ -z "$CFG" ] && {
  say "结论"
  echo "没有找到运行时配置；请手动指定： sh $0 /path/to/runtime.yaml"
  exit 0
}

# ---------------------------------------------------------------- 5. 规则归属
say "[5] Gemini / AI 相关域名命中哪条规则"
grep -nE 'gemini|generativelanguage|aistudio|notebooklm|antigravity|cloudcode-pa|proactivebackend' "$CFG" 2>/dev/null | head -40

say "[5b] Google 通用域名命中哪条规则（抽头）"
grep -nE 'DOMAIN-SUFFIX,(google\.com|googleapis\.com|gstatic\.com|googleusercontent\.com)|GEOSITE,google' "$CFG" 2>/dev/null | head -15

# ---------------------------------------------------------------- 6. 策略组
say "[6] 策略组定义位置（YAML 里 emoji 是 \\U0001F916 转义形式）"
awk '/^[[:space:]]*- name:/ {print NR": "$0}' "$CFG" 2>/dev/null | head -60

# ---------------------------------------------------------------- 7. 控制 API
say "[7] 控制 API"
CTRL=$(grep -m1 -i 'external-controller:' "$CFG" 2>/dev/null | sed -e 's/.*external-controller:[[:space:]]*//' -e 's/["'\'']//g' | tr -d '\r')
SECRETFILE=""
for s in /etc/mesl/controller_secret /etc/openclash/.secret; do
  [ -r "$s" ] && SECRETFILE="$s" && break
done
echo "external-controller: ${CTRL:-未配置}"
if [ -n "$CTRL" ] && have curl; then
  CTRL=$(printf '%s' "$CTRL" | sed 's/^0\.0\.0\.0:/127.0.0.1:/; s/^:\([0-9]\)/127.0.0.1:\1/')
# 没有密钥文件时也照样请求：OpenClash 等控制 API 可能不设密钥
  API_TMP=/tmp/.egress.$$
  curl -s -m 8 ${SECRETFILE:+-H "Authorization: Bearer $(cat "$SECRETFILE")"} \
    "http://$CTRL/proxies" > "$API_TMP" 2>/dev/null

  if have python3; then
    echo "--- 策略组当前节点（由同一目录的 egress_api_probe.py 解析）---"
    SCRIPT_DIR=$(dirname "$0")
    if [ -f "$SCRIPT_DIR/egress_api_probe.py" ]; then
      python3 "$SCRIPT_DIR/egress_api_probe.py" --url "$CTRL" \
        ${SECRETFILE:+--secret-file "$SECRETFILE"} 2>&1 | head -40
    else
      echo "（找不到 egress_api_probe.py，退化为纯 shell 解析）"
      python3 - "$API_TMP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))["proxies"]
for name, v in sorted(d.items()):
    if v.get("all") or v.get("type") in ("Selector", "Fallback", "URLTest", "LoadBalance"):
        print(f'{v["type"]:<10} {name} -> {v.get("now", "")}')
PY
    fi
  else
    echo "--- 策略组（无 python3，粗粒度解析）---"
    tr '{' '\n' < "$API_TMP" | grep -E '"now"' | head -40
  fi
  rm -f "$API_TMP"
else
  echo "（curl 不可用或未配置 external-controller，跳过；改用 LuCI 面板查看策略组）"
fi

# ---------------------------------------------------------------- 8. 出口 IP
say "[8] 当前出口 IP（若客户端整机走代理，这个值应与浏览器所见一致）"
if have curl; then
  curl -s -m 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^(ip|loc|warp)=' || echo "取出口 IP 失败"
else
  echo "curl 不可用"
fi

# ---------------------------------------------------------------- 9. 自动判断
say "[9] 自动判断"
if have curl && have python3 && [ -n "$CTRL" ]; then
  TMP=/tmp/.egress.$$
  curl -s -m 8 ${SECRETFILE:+-H "Authorization: Bearer $(cat "$SECRETFILE")"} \
    "http://$CTRL/proxies" > "$TMP" 2>/dev/null
  PAIR=$(python3 - "$TMP" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))["proxies"]
except Exception:
    print("\t"); raise SystemExit

def now(k):
    return d.get(k, {}).get("now", "")

groups = [k for k, v in d.items() if v.get("all")]
ai = next((k for k in groups if "AI" in k), "")
go = next((k for k in groups if "Google" in k), "")
print(f"{ai}\t{now(ai) if ai else ''}\t{go}\t{now(go) if go else ''}")
PY
)
  rm -f "$TMP"
  AI_NAME=$(printf '%s' "$PAIR" | cut -f1)
  AI_NOW=$(printf '%s' "$PAIR" | cut -f2)
  G_NAME=$(printf '%s' "$PAIR" | cut -f3)
  G_NOW=$(printf '%s' "$PAIR" | cut -f4)
  echo "AI 组当前节点     : ${AI_NAME:-?} -> ${AI_NOW:-?}"
  echo "Google 组当前节点 : ${G_NAME:-?} -> ${G_NOW:-?}"
  if [ -n "$AI_NOW" ] && [ -n "$G_NOW" ]; then
    if [ "$AI_NOW" = "$G_NOW" ]; then
      echo "→ 两组出口一致（若仍报 IP A ≠ IP B，检查自动组内部切换 / QUIC / IPv6）"
    else
      echo "→ 确诊双出口：两组指向不同节点，同一会话来自两个 IP"
    fi
  else
    echo "→ 未能从控制 API 取到节点名（凭据或组名不匹配），请人工对比 [7]"
  fi
else
  echo "缺少 curl/python3/控制 API，无法自动比对；请人工对比 [7]，或装 python3 后重跑"
fi

say "完成"
echo "把以上整段输出贴回给排障方；如包含公网 IP 等敏感信息，可自行打码后再外发。"