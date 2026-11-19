#!/usr/bin/env python3
"""egress_api_probe.py —— 通过 mihomo 控制 API 输出「策略组 -> 当前节点」表

用途：判断是否"双出口"（例如 Gemini 走 🤖 AI 组、账号鉴权走 🔍 Google 组，
两组选了不同节点）。这是诊断的关键证据。

用法：
    python3 egress_api_probe.py                      # 自动读 /etc/mesl 配置
    python3 egress_api_probe.py --url 127.0.0.1:9090 --secret-file /etc/mesl/controller_secret
    python3 egress_api_probe.py --json               # 机器可读
    python3 egress_api_probe.py --switch '🤖 AI' '🔍 Google'
                                                     # 把第一个组切到第二个组当前节点

退出码：
    0 正常 / 已执行切换
    1 无法连接控制 API
    2 参数错误或目标组不存在
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

GROUP_TYPES = {"Selector", "Fallback", "URLTest", "LoadBalance", "Relay"}
DEFAULT_CONFIGS = (
    "/dev/shm/mesl-0/runtime.yaml",
    "/etc/mihomo/config.yaml",
    "/etc/openclash/config.yaml",
)


def find_controller(configs: tuple[str, ...] = DEFAULT_CONFIGS) -> tuple[str, str | None]:
    """从运行配置里找 external-controller 与密钥文件。"""
    for cfg in configs:
        p = Path(cfg)
        if not p.is_file():
            continue
        try:
            text = p.read_text(errors="ignore")
        except OSError:
            continue
        m = re.search(r"^external-controller:\s*[\"']?([^\s\"']+)", text, re.M)
        if not m:
            continue
        addr = m.group(1)
        if addr.startswith("0.0.0.0:"):
            addr = "127.0.0.1:" + addr.split(":", 1)[1]
        secret_file = None
        for cand in ("/etc/mesl/controller_secret", "/etc/openclash/.secret"):
            if Path(cand).is_file():
                secret_file = cand
                break
        return addr, secret_file
    return "127.0.0.1:9090", None


def api(url: str, secret: str | None, method: str = "GET", payload: object | None = None):
    data = None
    headers = {"Accept": "application/json"}
    if secret:
        headers["Authorization"] = f"Bearer {secret}"
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=8) as resp:
        body = resp.read()
    if not body:
        return None
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return body.decode(errors="replace")


def load_proxies(base: str, secret: str | None) -> dict:
    data = api(f"{base}/proxies", secret)
    if not isinstance(data, dict) or "proxies" not in data:
        raise RuntimeError("控制 API 返回内容不是预期的 /proxies 结构")
    return data["proxies"]


def is_group(node: dict) -> bool:
    return bool(node.get("all")) or node.get("type") in GROUP_TYPES


def print_table(proxies: dict) -> None:
    groups = {k: v for k, v in proxies.items() if is_group(v)}
    kind_w = max([len(v.get("type", "")) for v in groups.values()] or [4])
    name_w = max([len(k) for k in groups] or [4])
    print(f"{'TYPE':<{kind_w}}  {'GROUP':<{name_w}}  NOW")
    print("-" * (kind_w + name_w + 12))
    for name, node in sorted(groups.items()):
        now = node.get("now") or node.get("displayNameFromConfig") or ""
        flag = ""
        if node.get("alive") is False:
            flag = "  [!dead]"
        print(f"{node.get('type',''):<{kind_w}}  {name:<{name_w}}  {now}{flag}")


def compare(proxies: dict, a: str | None, b: str | None) -> int:
    """对比两个组（默认自动找 AI / Google 组）当前出口是否一致。"""
    groups = {k: v for k, v in proxies.items() if is_group(v)}
    if a is None:
        a = next((k for k in groups if "AI" in k), None)
    if b is None:
        b = next((k for k in groups if "Google" in k), None)
    if not a or not b:
        print("无法自动确定要比对的两个策略组，请用 --pair A B 指定", file=sys.stderr)
        return 2
    for name in (a, b):
        if name not in groups:
            print(f"策略组不存在: {name!r}", file=sys.stderr)
            return 2
    now_a, now_b = groups[a].get("now"), groups[b].get("now")
    print(f"\n比对: {a!r} -> {now_a!r}")
    print(f"      {b!r} -> {now_b!r}")
    if now_a and now_a == now_b:
        print("结论: 两组出口一致（若仍报 IP A ≠ IP B，检查自动组内部切换 / QUIC / IPv6）")
        return 0
    print("结论: 双出口确诊 —— 两组指向不同节点，同一会话会以两个 IP 出现在 Google 侧")
    print("修复: 见 references/fix-strategies.md 方案 A（合并规则）或方案 B（对齐节点）")
    return 0


def switch(base: str, secret: str | None, group: str, node: str) -> int:
    enc = urllib.parse.quote(group, safe="")
    api(f"{base}/proxies/{enc}", secret, method="PUT", payload=node)
    after = api(f"{base}/proxies/{enc}", secret)
    now = after.get("now") if isinstance(after, dict) else "?"
    ok = "OK" if now == node else "未生效"
    print(f"切换 {group!r} -> {node!r}: {ok} (now={now!r})")
    return 0 if now == node else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="mihomo 策略组出口探测")
    ap.add_argument("--url", help="控制 API 地址，如 127.0.0.1:9090")
    ap.add_argument("--secret", help="控制 API 密钥（不推荐，优先用 --secret-file）")
    ap.add_argument("--secret-file", help="存放密钥的文件")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    ap.add_argument("--pair", nargs=2, metavar=("A", "B"), help="指定要比对的两个策略组")
    ap.add_argument(
        "--switch",
        nargs=2,
        metavar=("GROUP", "TARGET_GROUP"),
        help="把 GROUP 切到 TARGET_GROUP 当前节点（不改配置文件）",
    )
    args = ap.parse_args(argv)

    addr, secret_file = (args.url, args.secret_file)
    if not addr:
        addr, auto_secret_file = find_controller()
        secret_file = secret_file or auto_secret_file
    secret = args.secret
    if not secret and secret_file and Path(secret_file).is_file():
        secret = Path(secret_file).read_text().strip()

    base = addr if addr.startswith("http") else f"http://{addr}"

    try:
        proxies = load_proxies(base, secret)
    except (urllib.error.URLError, OSError, RuntimeError) as exc:
        print(f"无法访问控制 API {base}: {exc}", file=sys.stderr)
        print("提示: 路由器上确认 external-controller 与密钥；mesl 系列密钥在 /etc/mesl/controller_secret", file=sys.stderr)
        return 1

    if args.json:
        out = {
            name: {"type": v.get("type"), "now": v.get("now")}
            for name, v in proxies.items()
            if is_group(v)
        }
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0

    print_table(proxies)

    if args.switch:
        group, target = args.switch
        if target in proxies and is_group(proxies[target]):
            node = proxies[target].get("now")
            if not node:
                print(f"目标组 {target!r} 没有 now，无法取出节点", file=sys.stderr)
                return 2
        else:
            node = target  # 直接给节点名
        return switch(base, secret, group, node)

    return compare(proxies, *(args.pair or (None, None)))


if __name__ == "__main__":
    sys.exit(main())