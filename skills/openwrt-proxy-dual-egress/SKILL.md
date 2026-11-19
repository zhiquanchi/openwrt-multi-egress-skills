---
name: openwrt-proxy-dual-egress
description: 诊断并修复 OpenWrt / 软路由上「同一个服务被分流规则拆成两个出口，导致 Google Gemini 报异常流量（页面显示 IP 地址 A ≠ IP 地址 B）」以及同类的会话割裂问题。适用于 mihomo/Clash 系（含 mesl-cli、OpenClash、Clash Verge Remote）、passwall2、xray/VLESS-Reality+WARP、sing-box 等透明网关。当用户贴出 google.com/sorry 页面、Gemini 提示"检测到异常流量"、登录后提示地区不支持、或问"为什么同一个网站的请求走了两个节点""怎么让 Google 域名走同一个出口""runtime.yaml 改了重启就被覆盖"时使用。包含远程排障的信息回流套路、诊断脚本、四种修复方案与验证步骤。
---

# OpenWrt 代理双出口（Gemini 异常流量）诊断与修复

## 这个 skill 解决什么

Google 在**同一个用户会话**里看到两个不同出口 IP 时，会判定为"双出口 IP 割裂 / 异常自动化流量"并拦截，页面原文形如：

```
我们的系统检测到您的计算机网络中存在异常流量。请稍后重新发送请求。
IP 地址：216.236.32.1 ≠ 216.232.68.147
时间：2026-11-18T10:10:24Z
网址：https://gemini.google.com/app
```

（完整原始输出与排查过程见 `references/case-gemini-investigation.md`——**建议先读它**，
它记录了哪一步卡住、哪条结论还没被验证。）

`≠` 两边的 IP 就是"同一会话、两条出口"的铁证。绝大多数是路由器分流规则把 `gemini.google.com`（AI 策略组）和 `accounts.google.com` / `gstatic.com`（通用 Google 策略组或直连）拆到了不同出口。

同类症状（同一根因）：

- Gemini / NotebookLM / AI Studio 登录后被拦或提示地区不支持；
- Google 账号页、reCAPTCHA、OAuth 回调偶发失败；
- 问"为什么我的流量一会儿是 A 国 IP 一会儿是 B 国 IP"。

不适用：单纯"打不开 Google"（节点不通 / DNS 污染）、商业流媒体解锁失败、账号地区本身被限制（那是账号侧问题，见 `references/symptom-triage.md` 第 6 节）。

## 铁律：先拿到出口证据，再改配置

**不要**在没有确认"当前两组各自选了哪个节点"的情况下就让用户改规则或换节点。规则拆组只说明"可能"有两个出口，`select` 型策略组也可能碰巧都选了同一个节点。判定顺序：

1. 确认代理内核与真实配置文件路径（`ps` 看进程，别信装了哪些包）；
2. 拿到策略组 → 当前节点映射（mihomo API `/proxies` 最准）；
3. 找到 Gemini 相关域名命中的规则行 → 归属哪个策略组；
4. 对比两组的 `now`，不同即确诊；
5. 才给修复方案，改完同法验证。

## AI 跑在远程、路由器在用户局域网时怎么干活

这是本 skill 最常见的失败点：AI 的沙箱通常**不在用户局域网**，`192.168.x.1` 这类私有地址访问不到；`WebFetch` 类工具还会被安全策略直接拦掉私有地址（报 `blocked ... private/internal address`），`curl` 能连上但拿到的是 LuCI 登录页（`x-luci-login-required: yes`）。

**不要**让用户在对话里贴路由器密码，也**不要**尝试绕过 LuCI 登录认证。正确做法是"信息回流"：

- 让用户在 Mac/PC 终端 `ssh root@192.168.x.1`（密码 = LuCI 后台密码）；
- 把 `scripts/diag-egress.sh` 上传或粘贴到路由器执行，把输出整段贴回来；
- 或者落地 `scripts/egress_api_probe.py` 到路由器（需要 python3），一条命令直接输出"策略组 → 当前节点"表。

详细套路、常见翻车点（括号在传输中被吃掉导致 `find: unpaired '('`、`grep` 输出被 `head` 截断、emoji 组名在 YAML 里是 `"\U0001F916 AI"` 转义形式）见 `references/remote-diagnosis-playbook.md`。

## 五步标准流程

### 第 1 步：确认真正的代理内核

```sh
ps | grep -Ei 'clash|mihomo|mesl|xray|sing-box|passwall' | grep -v grep
```

装了 `luci-app-passwall2`、`xray-core`、`sing-box` 不代表它们在跑——**正在运行的进程决定该改谁的配置**。典型输出：

```
/usr/bin/mesl-cli daemon --data-dir /etc/mesl --core /tmp/mesl-core/mihomo --transparent
/tmp/mesl-core/mihomo -d /etc/mesl -f /dev/shm/mesl-0/runtime.yaml
```

=> 改 mihomo 的配置，改 passwall2/xray/sing-box 无效。

### 第 2 步：区分"源配置"与"运行时生成配置"

`-f` 指向的文件如果是 `/dev/shm/...`、`/tmp/...`，基本可以断定它是**每次启动重新生成的**（mesl / 订阅转换类前端都是这样）。直接改它会在重启或刷新订阅后丢。

```sh
ls -la /etc/mesl/                    # 或 /etc/openclash / /etc/mihomo / /etc/sing-box
grep -n 'external-controller\|secret' /dev/shm/mesl-0/runtime.yaml
```

看到 `profile.enc`（加密订阅）、`state.json`（选择的节点）、`controller_secret`（API 密钥）就说明配置由面板/守护进程托管。

### 第 3 步：定位规则与策略组

```sh
# 所有 Gemini/AI 相关域名及其归属策略组
grep -nE 'gemini|generativelanguage|aistudio|notebooklm|antigravity' /dev/shm/mesl-0/runtime.yaml

# 所有策略组定义位置
awk '/- name:/ {print NR": "$0}' /dev/shm/mesl-0/runtime.yaml
```

YAML 里 emoji 会写成 `"\U0001F916 AI"`（🤖 AI）、`"\U0001F50D Google"`（🔍 Google）——搜索时不要用裸 emoji。

### 第 4 步：确认两组的当前出口（关键证据）

首选 mihomo 控制 API（见 `scripts/egress_api_probe.py`，或 `references/mihomo-api-recipes.md` 里的 curl 版本）：

```sh
SECRET=$(cat /etc/mesl/controller_secret)
CTRL=$(grep -m1 -i 'external-controller:' /dev/shm/mesl-0/runtime.yaml | grep -oE '[0-9.]+:[0-9]+')
curl -s -H "Authorization: Bearer $SECRET" "http://$CTRL/proxies" | tr ',' '\n' | grep '"now"'
```

拿到 `🤖 AI → 香港 01`、`🔍 Google → Auto` 这类映射，即确诊双出口。

### 第 5 步：按方案修复并验证

四种方案按"治本程度 / 持久性 / 改动成本"排序，详见 `references/fix-strategies.md`：

| 方案 | 做法 | 何时用 |
|---|---|---|
| A 合并规则 | 把 Gemini 域名规则从 `🤖 AI` 组搬到 `🔍 Google` 组（或反之），一个服务一个出口 | 长期最优；需要订阅侧的规则覆写能力 |
| B 对齐节点 | 两个策略组都固定到**同一个具体节点** | 面板能改、订阅更新不易冲掉；最快的止血 |
| C 全量直连/全量代理对照 | 临时让全部 Google 走直连或全部走代理 | 只为验证根因，不适合长期 |
| D 单出口兜底 | 用 `MATCH,某固定组` + 全局统一出口，牺牲细粒度分流 | 节点质量稳定、不想维护复杂规则时 |

验证（任何方案都必须做）：

1. 无痕窗口打开 `https://gemini.google.com/app`，不再出现 sorry 页；
2. 同一浏览器里连续访问 `gemini.google.com`、`accounts.google.com`、`ssl.gstatic.com`，在代理面板连接列表里确认三者命中**相同出口节点**；
3. 用 `scripts/egress_verify.sh` 打印各域名实际出口 IP，确认只有一个 IP。

## 常见误判

- **"改了 runtime.yaml 没生效/又变回去了"** —— 运行时文件会被守护进程重建，改它等于白改。
- **"两组 proxies 列表一模一样，所以没问题"** —— `select` 组会各自记住用户选择；列表相同不代表当前出口相同。
- **"两组都选了 Auto/Fallback"** —— 自动组内部会按延迟各自切换，IP 会飘；要固定到具体节点。
- **"把 QUIC 全禁掉就能解决"** —— 禁 UDP/443 能避免 QUIC 与 TCP 出口不一致（同一域名的 UDP 走了另一条链），是**辅助手段**，不是根因修复；而且要排除办公网等不该被影响的网段。
- **"换一个节点就好"** —— 如果规则仍拆成两个出口，换节点只是换了两个不同的 IP。

## 附带脚本

- `scripts/diag-egress.sh` — 纯 sh + busybox 兼容，一次跑完：内核识别、配置路径、规则归属、策略组定位。在路由器上执行。
- `scripts/egress_api_probe.py` — 通过 mihomo 控制 API 输出「策略组 → 当前节点 → 出口 IP」表，需要路由器上有 python3（`opkg install python3`）。
- `scripts/egress_verify.sh` — 用 curl 通过指定出口检查多个 Google 域名解析到的实际出口 IP，做修复后验证。

## 参考文档

- `references/case-gemini-investigation.md` — **现场实录**：完整原始输出（拦截页、ps、规则行、两组定义），
  以及卡在哪里、哪些结论已确认、哪些没验证。先读这篇再读结论。
- `references/remote-diagnosis-playbook.md` — AI 不在局域网时的信息回流套路与翻车点。
- `references/mihomo-api-recipes.md` — 查策略组、切节点、刷新订阅、读日志的完整 API 用法。
- `references/fix-strategies.md` — 四种方案的精确配置片段（mihomo / xray / sing-box）。
- `references/symptom-triage.md` — 现象 ↔ 根因对照表，含账号地区、DNS、QUIC 的区分方法。
- 工具陷阱（`find: unpaired '('`、sed 对 emoji 静默失败、`ip route get ... from` 误报等）
  汇总在兄弟 skill 的 `../openwrt-multi-wan-routing/references/tooling-gotchas.md`。