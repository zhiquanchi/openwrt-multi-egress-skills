# openwrt-proxy-dual-egress

一个 **Agent Skill**（Claude Code / CodeBuddy / DeepSeek Harness 等通用 `SKILL.md` 格式），用于诊断并修复：

> **OpenWrt 软路由上，同一个服务被分流规则拆成两个出口，导致 Google Gemini 报「检测到异常流量」，页面上写着 `IP 地址 A ≠ IP 地址 B`。**

顺带覆盖同根因的一类问题：Google 账号页 / reCAPTCHA / OAuth 偶发失败、登录后提示地区不支持、以及"为什么同一个网站的请求走了两个节点"。

## 问题长什么样

打开 `https://gemini.google.com/app`，被拦：

```
我们的系统检测到您的计算机网络中存在异常流量。请稍后重新发送请求。
IP 地址：216.236.32.1 ≠ 216.232.68.147
时间：2026-11-18T10:10:24Z
网址：https://gemini.google.com/app
```

`≠` 两边的 IP 是"同一会话、两条出口"的铁证。原因是路由器按域名分流时，把 `gemini.google.com`（`🤖 AI` 策略组）和登录鉴权 `accounts.google.com`、静态资源 `ssl.gstatic.com`（`🔍 Google` 策略组或直连）送进了**不同出口**。Google 的前端网关校验会话时发现来源 IP 割裂，判定为异常自动化流量。

## 这个 skill 包含什么

```
SKILL.md                                   # 触发描述 + 五步标准流程 + 常见误判
references/
  remote-diagnosis-playbook.md             # AI 不在用户局域网时怎么"信息回流"
  mihomo-api-recipes.md                     # mihomo 控制 API 速查（查/切/验证）
  fix-strategies.md                         # 四种修复方案 + Xray/sing-box/passwall 等价做法
  symptom-triage.md                         # 现象 ↔ 根因对照，区分双出口/地区/DNS/QUIC/IPv6
scripts/
  diag-egress.sh                            # 路由器上一键收集诊断信息（busybox 兼容）
  egress_api_probe.py                       # 输出「策略组 → 当前节点」表并判定双出口
  egress_verify.sh                          # 修复后验证出口 IP 是否收敛
```

## 安装

把整个目录放到你所用 Agent 的 skills 目录下即可（目录名即 skill 名）：

```bash
git clone https://github.com/zhiquanchi/openwrt-proxy-dual-egress.git ~/.claude/skills/openwrt-proxy-dual-egress
# CodeBuddy:  ~/.codebuddy/skills/
# DSH:        ~/.dsh/skills/
```

Agent 会根据 `SKILL.md` frontmatter 里的 `description` 自动选择是否加载。

## 手动使用（不装 skill 也能用）

在路由器上（`ssh root@192.168.x.1`）：

```sh
sh scripts/diag-egress.sh          # 一次跑完：内核识别、配置路径、规则归属、策略组
```

看两组出口是否一致：

```sh
python3 scripts/egress_api_probe.py            # AI 组 vs Google 组
python3 scripts/egress_api_probe.py --json     # 机器可读
```

最快止血（把 AI 组切到 Google 组当前节点，不改配置文件）：

```sh
python3 scripts/egress_api_probe.py --switch '🤖 AI' '🔍 Google'
```

修复后验证：

```sh
sh scripts/egress_verify.sh                    # 连续取出口 IP，唯一即收敛
```

## 修复思路速览

| 方案 | 做法 | 适用 |
|---|---|---|
| **A 合并规则**（长期） | 把 Gemini 域名并入 `🔍 Google` 组，一个服务一个出口 | 订阅侧支持覆写规则 |
| **B 对齐节点**（止血） | 两个策略组固定到同一个**具体节点**（别用 Auto/Fallback） | 面板能改，最省事 |
| **C 全量对照**（验证） | 临时让全部 Google 走直连或全部走代理 | 只为确认根因 |
| **D 单出口兜底** | `GEOIP,CN,DIRECT` + `MATCH,固定组` | 不想维护细分规则 |

细节、配置片段、验证清单见 [`references/fix-strategies.md`](references/fix-strategies.md)。

## 实测环境

本 skill 的方法论来自一次真实排障：Kwrt 25.12.2（OpenWrt 衍生，mediatek/filogic）+ `mesl-cli` 托管的 mihomo 透明网关。

关键踩坑（都已写进 skill）：

- **装了 ≠ 在跑**：`luci-app-passwall2`、`xray-core`、`sing-box` 都装了，但真正在跑的是 `mesl-cli` 拉起的 mihomo，改别的插件毫无作用；
- **运行时配置不是源配置**：`/dev/shm/mesl-0/runtime.yaml` 每次启动重建，直接改它会在重启/刷新订阅后被覆盖；
- **YAML 里的 emoji 是转义形式**：`🤖 AI` 写作 `"\U0001F916 AI"`，`🔍 Google` 写作 `"\U0001F50D Google"`；
- **列表一样 ≠ 出口一样**：`select` 型策略组各自记住用户选择；
- **远程 AI 进不了局域网**：`WebFetch` 被安全策略拦私有地址，`curl` 只能拿到 LuCI 登录页——必须靠"用户 ssh 执行 + 贴回输出"的信息回流。

## 许可

[MIT](LICENSE)

文中出现的 IP、节点名、域名均为示例，与任何具体厂商无关。