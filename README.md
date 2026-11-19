# openwrt-multi-egress-skills

一组面向 **OpenWrt / 软路由多出口排障**的 Agent Skill，通用 `SKILL.md` 格式（Claude Code / CodeBuddy / DeepSeek Harness 等均可直接加载）。

方法论来自两次真实的家庭 + 办公混合网络排障：一台 Kwrt 25.12.2 软路由，同时挂着家庭 5G 中继、办公 WiFi（门户认证）、USB 网卡，跑着 mesl 托管的 mihomo 透明代理。

## 包含两个 skill

| Skill | 解决什么 |
|---|---|
| [`openwrt-proxy-dual-egress`](skills/openwrt-proxy-dual-egress/SKILL.md) | 同一服务被分流规则拆成两个出口 → Gemini 报「异常流量」，页面显示 `IP A ≠ IP B` |
| [`openwrt-multi-wan-routing`](skills/openwrt-multi-wan-routing/SKILL.md) | 配置多条上行（双 WiFi / USB / 双有线），让**指定流量走指定 WAN**，并处理门户认证、代理劫持、持久化 |

两个 skill 共享同一套底层认知：**包的命运在 `prerouting` 就被代理决定了**，改路由之前先确认有没有被劫持。

## 安装

```bash
git clone https://github.com/zhiquanchi/openwrt-multi-egress-skills.git
cp -r openwrt-multi-egress-skills/skills/* ~/.claude/skills/       # Claude Code
# cp -r .../skills/* ~/.codebuddy/skills/                          # CodeBuddy
# cp -r .../skills/* ~/.dsh/skills/                                # DeepSeek Harness
```

目录名即 skill 名，Agent 依据 frontmatter 的 `description` 自动选择加载。

## 目录结构

```
skills/
  openwrt-proxy-dual-egress/
    SKILL.md
    references/   remote-diagnosis-playbook.md
                  mihomo-api-recipes.md
                  fix-strategies.md
                  symptom-triage.md
    scripts/      diag-egress.sh        # 路由器上一次性收集诊断信息
                  egress_api_probe.py   # 策略组 → 当前节点表，判定双出口
                  egress_verify.sh      # 修复后验证出口是否收敛

  openwrt-multi-wan-routing/
    SKILL.md
    references/   topology-and-limits.md
                  transparent-proxy-conflicts.md
                  portal-auth.md
                  persistence.md
    scripts/      topo_probe.sh         # 多 WAN 拓扑一次性采集
                  wan_check.sh          # 单条线路探测（OK/BLOCKED/LIMITED）
                  binding_guard.sh      # 出口绑定幂等保活
                  binding-guard.init    # procd 服务包装
```

## 核心结论速记

**双出口（Gemini 异常流量）**

- `IP A ≠ IP B` = 同一会话走了两条出口。常见成因：`gemini.google.com` 在 `🤖 AI` 组，`accounts.google.com` 在 `🔍 Google` 组。
- `select` 型策略组**各自记住选择**，两组 `proxies` 列表一样不代表出口一样。
- 先拿 `now` 证据（mihomo API `/proxies`）再改配置。

**多 WAN 指定出口**

- 一个接口一条上行；两个 STA 挂在同一个 interface 上不算双 WAN。
- 无线能否多 STA/STA+AP，看 `iw phy` 的 `valid interface combinations`，不是想当然。
- 透明代理在 `prerouting` 把流量 `redirect` 到本机端口，**静态路由和 `ip rule` 都不生效**。
- 代理规则里写 `DIRECT` **不等于**直连，出口网卡仍不受控。
- 代理的 nft 表是运行时创建的，`rc.local` 只跑一次会丢；用 procd 周期补。

## 实测环境

Kwrt 25.12.2（OpenWrt 衍生，mediatek/filogic，CMCC RAX3000M）+ mesl-cli 托管的 mihomo 透明网关 + 5G WiFi 中继 / 办公 WiFi（门户认证）/ USB 网卡三条上行。

文中的 IP、节点名、域名均为示例。

## 验证情况

脚本都在本机做过回归（模拟 mihomo API、模拟 `nft`/`ip` 状态机）：

- 双出口判定 → `--switch` 对齐 → 复判一致，闭环成立；
- 保活脚本连跑 3 次完全静默（幂等），删光后一轮自动恢复；
- 密钥泄漏检查：故意埋的密钥串在输出中出现 0 次。

**未在真实 OpenWrt 设备上实跑**——busybox ash 的差异已尽量规避（只用 POSIX 内建与 `nft/ip/curl/awk/grep`），但首次使用仍建议先跑只读的 `topo_probe.sh` 确认输出正常。

## 许可

[MIT](LICENSE)