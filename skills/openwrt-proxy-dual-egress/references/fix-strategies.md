# 修复方案：让同一个服务只有一个出口

四种方案，按"治本程度 / 持久性 / 改动成本"排序。**动手前先备份**，并把"当前选择的节点"记录一下，方便回滚。

```sh
cp /dev/shm/mesl-0/runtime.yaml /root/runtime.yaml.bak.$(date +%s)   # 视实际路径调整
```

## 方案 A：合并规则，一个服务一个出口（长期最优）

把 Gemini / AI 相关域名全部并到**同一个策略组**，从结构上消除双出口。有两种做法：

### A1 订阅侧覆写（推荐）

在订阅转换 / 面板的"覆写 / 自定义规则 / rule-provider"里，把 AI 相关域名提前插入到 Google 组之前：

```yaml
rules:
  # 显式把 Gemini 全家桶并入 Google 组（顺序在 AI 组之前生效）
  - DOMAIN-SUFFIX,gemini.google.com,🔍 Google
  - DOMAIN-SUFFIX,gemini.gstatic.com,🔍 Google
  - DOMAIN-SUFFIX,generativelanguage.googleapis.com,🔍 Google
  - DOMAIN-SUFFIX,aistudio.google.com,🔍 Google
  - DOMAIN-SUFFIX,notebooklm.google.com,🔍 Google
  - DOMAIN-SUFFIX,antigravity.google,🔍 Google
  - DOMAIN-SUFFIX,cloudcode-pa.googleapis.com,🔍 Google
  - DOMAIN-SUFFIX,geminiweb-pa.clients6.google.com,🔍 Google
  - DOMAIN-SUFFIX,signaler-pa.clients6.google.com,🔍 Google
  - GEOSITE,google,🔍 Google
  - DOMAIN-SUFFIX,googleapis.com,🔍 Google
  - DOMAIN-SUFFIX,gstatic.com,🔍 Google
  - DOMAIN-SUFFIX,googleusercontent.com,🔍 Google
```

为什么是"并入 Google 组"而不是反向并入 AI 组：Google 组的域名覆盖面大得多（`google.com`、`gstatic.com`、`1e100.net` 等），把少数 AI 域名并进去只需少量规则；反过来要并几百条。

> 规则是**先命中先生效**：覆写规则必须排在订阅自带的 `DOMAIN-SUFFIX,gemini.google.com,🤖 AI` 之前。

### A2 直接改运行时文件（临时验证用）

```sh
F=/dev/shm/mesl-0/runtime.yaml
sed -i 's#,\(\\U0001F916 AI\)$,#\U0001F50D Google#' "$F"   # 把所有 AI 组规则改指 Google 组
```

改完必须让内核重载才生效，且**下次重启/刷新订阅会被覆盖**。只用于验证根因。

## 方案 B：对齐节点（最快止血）

规则不动，把两个策略组都固定到**同一个具体节点**：

- 面板：策略组页分别点 `🤖 AI` 和 `🔍 Google`，选同一个节点（如都选「香港 01」）；
- 命令行：见 `references/mihomo-api-recipes.md` 的 `PUT /proxies/{name}`。

要点：

1. **不要选 `Auto` / `Fallback` / `MESL` 这类自动组**——它们内部会各自按延迟切换，IP 仍会飘；
2. 选具体节点后，若节点挂了需要手动换，或改用"两组共享同一个 `url-test` 子组"的结构；
3. 选同一个**落地 IP** 的节点，而不只是同一个机场——同一机场的不同节点落地 IP 通常不同。

## 方案 C：全量对照（只用于验证根因）

临时把**所有** Google 域名统一走直连，或统一走代理：

```yaml
rules:
  - GEOSITE,google,DIRECT   # 或 DIRECT 换成一个固定节点组
```

- 若 sorry 页消失 ⇒ 确证是"双出口"问题，回到方案 A/B；
- 若仍是 sorry 页 ⇒ 换 `references/symptom-triage.md` 排查（IP 信誉、账号地区、DNS）。

验证完务必还原。

## 方案 D：单出口兜底

不想维护细粒度分流时，把出口收敛成两个：`DIRECT`（国内）+ 一个固定代理组（其余全部）。

```yaml
rules:
  - GEOIP,CN,DIRECT
  - MATCH,🔍 Google      # 或任意"固定节点"组
```

代价：所有境外流量共用一条链，流媒体 / 低延迟需求会受影响。适合"只求能用"的办公或临时环境。

## 其他内核的等价做法

### Xray（含 VLESS-Reality + WARP）

```json
{
  "type": "field",
  "outboundTag": "warp",
  "domain": [
    "geosite:google",
    "domain:google.com",
    "domain:gstatic.com",
    "domain:googleusercontent.com",
    "domain:googleapis.com"
  ]
}
```

并确保**没有**更靠前的规则把 Google 子域送进 `direct`（顺序敏感）。改完先校验再重启：

```bash
xray -test -config /usr/local/etc/xray/config.json && systemctl restart xray
# OpenWrt 上：/etc/init.d/xray restart
```

刷新 WARP 出口（出口 IP 被 Google 标记时）：

```bash
warp-cli --accept-tos disconnect && warp-cli --accept-tos connect
```

### sing-box

```json
{
  "route": {
    "rules": [
      {
        "domain_suffix": [".google.com", ".gstatic.com", ".googleapis.com", ".googleusercontent.com"],
        "outbound": "warp"
      }
    ]
  }
}
```

`sing-box check -c /etc/sing-box/config.json` 后再 `rc-service`/`/etc/init.d/sing-box restart`。

### passwall2 / SSR Plus+（LuCI 界面）

把 Google 相关域名**全部放进同一个节点/策略**，不要一部分在"代理"列表、一部分在"直连"列表。改完点"保存并应用"，观察 `/tmp/log/passwall.log` 里的规则命中。

## 辅助手段：禁 QUIC（不是根因修复）

浏览器对同一域名可能同时走 UDP/443（QUIC）与 TCP，如果 UDP 被另一条链处理（例如 UDP 无法过代理直连出去），出口也会分裂。禁掉 UDP/443 可消除这一类：

```sh
# nftables（OpenWrt 22.03+ / 25.x 默认）
nft add rule inet fw4 forward ip saddr 192.168.0.0/16 udp dport 443 drop
```

注意：

- 要**排除不该被影响的网段**（例如需要 QUIC 的办公网、视频会议）；
- 规则需持久化（写进 `/etc/nftables.d/*.nft` 或防火墙的自定义规则），否则重启即失效；
- 它只是减少变量，不能替代方案 A/B。

## 改完怎么确认真的只有一个出口

```sh
# 1) 路由器上：三组应该指向同一个节点
sh scripts/egress_verify.sh --api            # 或 references/mihomo-api-recipes.md 第 1 条

# 2) 客户端上：分别取出口 IP，应完全相同
curl -s https://www.cloudflare.com/cdn-cgi/trace | grep ^ip=
dig +short gemini.google.com | head -3

# 3) 浏览器：无痕窗口重开 gemini.google.com/app，不再出现 sorry 页；
#    并在面板「连接」页确认 gemini.google.com / accounts.google.com / ssl.gstatic.com
#    的 chains 字段完全一致
```

> 通过代理访问 `ipinfo.io` / `whoer.net` 返回 429/403 属于正常现象（这些域名本身被分流到了共享 WARP IP），不代表出问题。