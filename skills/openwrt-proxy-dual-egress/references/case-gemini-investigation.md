# 现场实录：Gemini「异常流量」排查全过程（含原始输出）

> 本文是 `openwrt-proxy-dual-egress` 的事实来源。所有结论都来自下面这些**真实输出**，
> 包括失败的尝试、走错的方向、以及最终没能在当时完成的那一步。
>
> 环境：Kwrt 25.12.2（OpenWrt 衍生）/ CMCC RAX3000M (NAND) / mediatek-filogic / kernel 6.12.74 aarch64。
> 文中 IP、节点名已脱敏为示例值，结构保持不变。

## 0. 起点：用户贴回来的拦截页

```
https://www.google.com/sorry/index?continue=https://gemini.google.com/app&q=...

我们的系统检测到您的计算机网络中存在异常流量。请稍后重新发送请求。

IP 地址：216.236.32.1 ≠ 216.232.68.147
时间：2026-11-18T10:10:24Z
网址：https://gemini.google.com/app
```

**第一层误判风险**：看到这段话，很容易去查"216.236.32.1 是不是被 Google 拉黑了"，或去搜"Gemini 账号被封怎么办"。
实际上 `≠` 这个符号本身已经给出了答案：Google 在一次会话里**同时看到两个源 IP**。这不是 IP 信誉问题，是**出口不唯一**。

## 1. 卡住的两轮：试图直接访问路由器

### 1.1 WebFetch 被安全策略拦

```
WebFetch blocked by security center network policy —
host "192.168.5.1" resolves to a private/internal address.
```

### 1.2 改用 curl

```sh
curl -sS -m 8 -o /dev/null -w "HTTP:%{http_code} connect:%{time_connect}s\n" \
  http://192.168.5.1/cgi-bin/luci/admin/status
```

```
HTTP:403 connect:0.017829s
```

`connect` 只用了 17ms —— 说明**连接确实建立了**，不是网络不可达。再看响应头：

```
--- 代理环境变量 ---
CODEBUDDY_SERVICE_PROXY_URL=http://127.0.0.1:61790/internal/hooks/services/invoke
--- 响应头 ---
HTTP/1.1 403 Forbidden
Server: nginx/1.26.3
Date: Wed, 18 Nov 2026 10:22:04 GMT
x-luci-login-required: yes
<title>OpenWrt - LuCI</title>
```

结论：**能通，但缺 LuCI 登录凭据**。`x-luci-login-required: yes` 是关键证据。

### 1.3 用户提出"你申请下权限我给你"

这是一次**必须拒绝**的诱惑。理由要讲清楚，而不是简单说"做不到"：

- 没有可以"申请"的审批接口；
- 安全策略拦截不应绕过；
- 不建议让用户在对话里粘贴路由器 root 密码（对话会被记录/转发）。

**转折点**：放弃"远端直连"，改为"用户 ssh 执行 + 贴回输出"。这一步之后才开始有进展。

## 2. 第一份诊断输出暴露的关键信息

用户执行了诊断脚本，贴回：

```
===== 1. 系统信息 =====
DISTRIB_ID='Kwrt'
DISTRIB_RELEASE='25.12.2'
DISTRIB_TARGET='mediatek/filogic'
DISTRIB_ARCH='aarch64_cortex-a53'
Linux OpenWrt 6.12.74 #0 SMP Mon Mar 30 06:12:34 2026 aarch64 GNU/Linux

===== 2. 正在运行的代理进程 =====
10208 root     1301m S    /usr/bin/mesl-cli daemon --data-dir /etc/mesl --core /tmp/mesl-core/mihomo --transparent --m
10250 root     1237m S    /tmp/mesl-core/mihomo -d /etc/mesl -f /dev/shm/mesl-0/runtime.yaml

===== 3. 已安装的代理插件 =====
luci-app-passwall2 - 26.3.5-r1
sing-box - 1.13.4-r4
xray-core - 26.3.27-r2
shadowsocksr-libev-ssr-redir - 2.5.6-r1
...
```

**最容易走错的地方就在这里**：第 3 段列出了一堆代理插件（passwall2、sing-box、xray、SSR），
按直觉会去改这些。但**第 2 段才是真相**——真正在跑的只有 `mesl-cli` 拉起的 mihomo，
其余全是装了没启用的。**`ps` 决定改谁，`opkg` 列表不算数。**

同时注意到 `-f /dev/shm/mesl-0/runtime.yaml`：配置文件在 `/dev/shm`（内存文件系统）里，
这几乎必然是**运行时生成**的，不能直接改（第 6 节验证了这点）。

### 2.1 一个真实的命令翻车

第一版诊断脚本的第 5 段输出是：

```
===== 5. 含 Google 分流的规则行 =====
find: unpaired '('
```

原因：脚本里写了 `find /etc -type f \( -name '*.yaml' \)`，
用户从聊天窗口复制时反斜杠转义的括号被"智能"处理吃掉了。

教训（已写进 `remote-diagnosis-playbook.md`）：**给用户的命令不要用 `\( ... \)` 这类需要转义的结构**，
改用 `grep -E` 或分步执行。

## 3. 规则侧：Google 被拆成两组

```
===== runtime.yaml 里所有 Google 相关规则 =====
3719:    - name: "\U0001F50D Google"
7891:    - "DOMAIN-SUFFIX,gemini.google.com,\U0001F916 AI"
7892:    - "DOMAIN-SUFFIX,proactivebackend-pa.googleapis.com,\U0001F916 AI"
7898:    - "DOMAIN-SUFFIX,generativelanguage.googleapis.com,\U0001F916 AI"
7899:    - "DOMAIN-SUFFIX,alkalicore-pa.clients6.google.com,\U0001F916 AI"
7907:    - "DOMAIN-SUFFIX,geminiweb-pa.clients.google.com,\U0001F916 AI"
7909:    - "DOMAIN-SUFFIX,gemini.gstatic.com,\U0001F916 AI"
7912:    - "DOMAIN-SUFFIX,notebooklm.google.com,\U0001F916 AI"
...
9091:    - "DOMAIN,voice.telephony.goog,\U0001F50D Google"
9093:    - "DOMAIN-SUFFIX,1e100.net,\U0001F50D Google"
9100:    - "DOMAIN-SUFFIX,adgoogle.net,\U0001F50D Google"
...
9122:    - "DOMAIN-SUFFIX,apigee.com,\U0001F50D Google"
```

**注意 emoji 是转义写法**：`🤖 AI` 在 YAML 里是 `"\U0001F916 AI"`，`🔍 Google` 是 `"\U0001F50D Google"`。
如果直接拿真 emoji 去 grep，在路由器终端里可能匹配不到。

结构确认：Gemini 全家桶 → `🤖 AI` 组；通用 Google 域名 → `🔍 Google` 组。
**这就是双出口的规则基础**，但还不足以定罪——两组可能碰巧选了同一个节点。

## 4. 策略组列表（证明这是订阅转换模板）

```
===== 所有策略组名称与行号 =====
2290:     - name: MESL
2467:     - name: "\U0001F916 AI"
2645:     - name: "\U0001F34E Apple"
2824:     - name: "\U0001F5A5 Microsoft"
3003:     - name: "\U0001F4B3 Paypal"
3182:     - name: "\U0001F4FD️ Bilibili"
3361:     - name: "\U0001F459 TikTok"
3540:     - name: "\U0001F3AE Steam"
3719:     - name: "\U0001F50D Google"
3897:     - name: "\U0001F3B5 Spotify"
...
7280:     - name: Final
```

每个服务一个策略组，是典型的机场订阅转换模板。**这意味着规则是订阅方生成的，
直接改 runtime.yaml 会被下次订阅刷新覆盖**。

## 5. 两组定义（近乎相同）

```
===== AI 组定义 =====
    - name: "\U0001F916 AI"
      proxies:
        - MESL
        - Fallback
        - Auto
        - "\U0001F1ED\U0001F1F0 香港 01"
        - "\U0001F1ED\U0001F1F0 香港 02"
        - "\U0001F1ED\U0001F1F0 香港 03 [0.3X]"
        - "\U0001F1ED\U0001F1F0 香港 04"
        ...
===== Google 组定义 =====
    - name: "\U0001F50D Google"
      proxies:
        - MESL
        - Fallback
        - Auto
        - "\U0001F1ED\U0001F1F0 香港 01"
        ...
```

**两组的 proxies 列表完全一样**。这里有一个反直觉的点，很多人（包括当时的排查）会误判：

> "列表一样，所以出口一定一样。"

错。`select` 型策略组会**各自记住用户选中的那一项**。列表相同只说明"可选集合"相同，
不代表"当前选中"相同。而当时 `state.json` 里 grep 不到选中项：

```
===== 当前选中的出口(state) =====
（无输出）
```

所以**到这里为止，双出口只是"高度可能"，还没拿到证据**。

## 6. 卡在哪：试图从 state.json 取选中节点

`/etc/mesl/state.json` 里 grep 不到节点名，说明它不含这项状态（可能是二进制/加密/字段名不同）。

正确的下一步是查 mihomo 控制 API `/proxies`（见 `mihomo-api-recipes.md`）。
**但这一步在原始会话里没有完成**——会话在给出 API 查询命令后就结束了，
用户始终没有把 `"now"` 字段的输出贴回来。

这是本 skill 把"先拿 `now` 证据"写成**强制前置步骤**的原因（见 SKILL.md「铁律」一节）。

## 7. 最终没有验证的结论（诚实标注）

| 结论 | 证据等级 |
|---|---|
| Google 域名被拆进 `🤖 AI` 与 `🔍 Google` 两个组 | **已确认**（第 3 节原始规则） |
| 两组 proxies 可选集合相同 | **已确认**（第 5 节） |
| 真正在跑的是 mesl/mihomo，不是 passwall2/xray | **已确认**（`ps` 输出） |
| runtime.yaml 是运行时生成、不可直接改 | **已确认**（`/dev/shm` 路径 + `profile.enc`/`enckey` 等文件） |
| **两组当前选中了不同节点** | **未验证**（`state.json` 无结果，API 未执行） |
| 修复方案 B（对齐节点）能解决该问题 | **未验证**（未执行修复） |

**不要**把最后一栏当成已验证事实。如果想快速确认，用本 skill 的：

```sh
python3 scripts/egress_api_probe.py        # 自动比对 AI 组与 Google 组的 now
```

## 8. 从这次排查提炼出的清单

1. 看到 `IP A ≠ IP B`，先想"出口不唯一"，不要先想"IP 被封"。
2. 远程 AI 进不了用户局域网时，立刻转入"用户 ssh 执行 + 贴回输出"，不要反复尝试直连。
3. 改代理配置前，用 `ps` 确认**谁在跑**，别信已装列表。
4. 配置文件在 `/dev/shm` 或 `/tmp` → 是运行时生成的，改了会丢。
5. YAML 里的 emoji 是 `\U0001F916` 转义形式。
6. 策略组列表相同 ≠ 当前选中相同；**必须查 `now`**。
7. 拿到 `now` 之前，任何修复方案都只是猜测。