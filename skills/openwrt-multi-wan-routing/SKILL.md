---
name: openwrt-multi-wan-routing
description: 在 OpenWrt / 软路由上配置多条上行（双 WiFi 客户端/中继、USB 网络共享、双有线 WAN、双 WAN + 办公网），并让指定流量走指定出口——按目标 IP/网段、按服务分别绑定不同 WAN，同时处理门户认证（Portal）、透明代理劫持导致的"路由改对了却不生效"、以及 mesl/mihomo 重建 nft 表冲掉自定义规则的持久化问题。当用户问"能不能两个 WAN""让某个 SSH/域名走某条线路""办公网 WiFi 不经过代理""多网卡分流""换个 exit 只对某些站点生效""门户认证页打不开""nft 规则重启就丢"时使用。包含拓扑探测脚本、通道验证脚本、幂等保活（procd）方案与硬件上限判断。
---

# OpenWrt 多 WAN 与指定出口分流

## 这个 skill 解决什么

一条路由器上同时挂多条上行（家庭宽带 + 办公 WiFi + 4G/5G USB 网卡 + 有线 WAN），要求**不同流量走不同出口**：

- 办公网资源走办公 WiFi，公网走家庭宽带；
- 某个服务器/IP 固定从某条线路出去（因为对方只放行那条线的源地址）；
- 办公 WiFi 上来的流量不经过透明代理；
- 多条线路做主备或按权重。

（完整原始输出、两次失败方案、以及被否决的思路见 `references/case-multi-wan-investigation.md`——
**建议先读它**，里面每个结论都附了当时真实命令的输出。）

真正难的地方**不是配置，而是三个隐形陷阱**（本 skill 的核心）：

1. **出口数量受硬件限制**（无线 STA 是否能在同一射频上共存、LAN 口是否独立）。
2. **透明代理先于路由**：代理在 `prerouting` 就把包 `redirect` 到本机端口，你在 `network` 里加的静态路由和 `ip rule` 对它**完全无效**——流量被劫走后，再由代理内核自己重新发起连接，出口不受你控制。
3. **代理内核的 nft 表是运行时创建的**：它的表一重建（进程重启、改配置），你插进去的例外规则就没了，而这类插入**没有任何 uci / include 入口可以静态写死**。

## 开始前必须先测的三件事

**不要**在不知道拓扑的情况下就给配置。先跑 `scripts/topo_probe.sh`（在路由器上执行），它一次性回答：

- 有几条上行、各自是什么类型、当前 metric 谁优先；
- 无线：哪些 radio 能开 STA、能否与 AP 并存、当前 STA 连的是哪个 SSID；
- 有线：LAN 口是否 DSA 独立（能否拆一个当 WAN2）；
- `/lib/netifd/proto/` 支持哪些 WAN 协议（dhcp / pppoe / qmi / ncm / mbim）；
- **是否存在透明代理劫持**（`nft list tables` 里有没有代理自建表、`ip rule` 里有没有策略路由）。

对应关系与判断标准见 `references/topology-and-limits.md`。

## 标准流程（六步）

### 第 1 步：枚举上行，确认硬件上限

```sh
ip -br link                       # 所有接口
ip route show default             # 当前默认路由与 metric
iwinfo | grep -E 'ESSID|Mode|Channel'   # 无线状态
iw phy phyX info | grep -A3 'valid interface combinations'
```

无线关键判据（详见 `references/topology-and-limits.md` 第 2 节）：

- 同一 radio 若写着 `#{ managed } <= 1`，那么**一个 STA + 一个 AP 只能二选一**；
- 有 `#channels <= 2` 的双频设备，两个 STA 连到**同信道**的两张网时才能共存，连不同信道会踢掉一个；
- 因此"两个 WiFi 做双 WAN"通常要**两个 radio 各出一个 STA**，而不是同一 radio 开两个。

### 第 2 步：把每条上行做成独立接口

关键是**一个接口一条上行**，别把两个 STA 塞进同一个 `wwan`（那样 netifd 只会按其中一个算默认路由，等于没有双 WAN）。

```sh
# 以 2.4G 的 STA 为例（radio0 → wifinet3）
uci set wireless.wifinet3.ssid='<SSID>'
uci set wireless.wifinet3.key='<密码>'
uci set wireless.wifinet3.encryption='psk2'
uci set wireless.wifinet3.network='wwan2'
uci commit wireless

uci set network.wwan2=interface
uci set network.wwan2.proto='dhcp'
uci set network.wwan2.metric='30'        # 大 = 优先级低
uci commit network

# 加入 wan 防火墙区域，否则没有 masq，LAN 出去没 NAT
uci add_list firewall.@zone[1].network='wwan2'
uci commit firewall
/etc/init.d/firewall reload
```

> `metric` 只决定**默认路由的优先级**，不决定"谁的流量走谁"。指定出口要靠第 4 步。

### 第 3 步：确认这条上行真的能上网

新加的上行经常卡在：

- **门户认证（Portal / 网页认证）**：能拿到 IP、能 ping 通网关，但 HTTP 被 302 到认证页，HTTPS 全断；
- **MAC 绑定 / 需要 DHCP 选项**；
- **国际漫游 / 需要 APN**（蜂窝类）。

用 `scripts/wan_check.sh <接口名>` 逐个探测，它会区分"完全不通"、"只到网关"、"被门户拦截"、"正常"四种状态。

门户认证页通常要**从 LAN 侧用浏览器打开**，这时会遇到第 4 步的代理劫持问题。

### 第 4 步：处理透明代理（最容易踩的坑）

**先确认代理是否在抢包**：

```sh
nft list tables                          # 有没有 inet mihomo / inet nikki / inet clash 之类
nft list chain inet <代理表> prerouting   # 有没有 redirect to :端口
ip rule show                             # 有没有 fwmark / lookup <表号> 的策略路由
ip route show table all | head           # 表 2022 / 1002 之类是不是代理的默认路由
```

典型症状：**路由改对了却不生效**。代理在 `prerouting`（priority `dstnat+1`）把 LAN 出站 TCP 全部 `redirect` 到本机端口，包根本没进转发路径，`ip rule` / 静态路由都不参与。

两条处理路线（详见 `references/transparent-proxy-conflicts.md`）：

| 路线 | 做法 | 适用 |
|---|---|---|
| **A 绕过劫持**（唯一可靠） | 在代理表 `prerouting` **链首**插入 `ip daddr {<网段/主机>} counter return` | 必须保证这类流量完全不经代理 |
| **B 只改代理规则** | 在 mihomo/Clash 规则里写 `IPCIDR,<网段>,DIRECT` | 只是不想走节点，**仍被劫持**；出口网卡与源地址不受控 |

实测结论：**B 不能替代 A**。`DIRECT` 只是"不用节点"，流量仍被 redirect 到内核、由内核重新发起连接，因此：
- 需要**固定出口网卡**的（比如"这个 IP 必须从办公 WiFi 出去"）→ 必须 A；
- 门户认证页打不开 → 必须 A。

### 第 5 步：为目标指定出口（三层，缺一不可）

以"`<目标IP>` 必须从 `wwan2` 出去，且不走代理"为例：

```sh
# 1) 静态路由：该目标走 wwan2 的网关
uci -q delete network.h3route
uci set network.h3route=route
uci set network.h3route.interface='wwan2'
uci set network.h3route.target='<目标IP>'
uci set network.h3route.netmask='255.255.255.255'
uci commit network

# 2) 策略路由：绕开代理的 lookup <表号>，强制走 main 表（否则命中代理的默认路由）
ip rule add to <目标IP>/32 lookup main pref 8800

# 3) 代理例外：在代理表 prerouting 链首 return（见第 4 步）
nft insert rule inet <代理表> prerouting ip daddr <目标IP> counter return
```

顺序很重要：**包在 prerouting 就被决定命运，所以第 3 层必须在第 1、2 层之前生效**（第 3 层不生效时，前两层看起来"配置写着但没用"）。

批量/按网段：把第 3 层的 `ip daddr` 换成集合 `{ 192.168.128.0/19, 172.16.0.0/12, <目标IP> }`。

### 第 6 步：持久化（能进 uci 的进 uci，不能的交给 procd）

| 内容 | 放哪 |
|---|---|
| 接口、metric、静态路由、防火墙区域 | `/etc/config/network`、`/etc/config/firewall`（uci，天然持久） |
| 代理表里的 nft 例外、`ip rule` | **无 uci 入口**，必须运行时插入 → procd 常驻服务 |

`scripts/binding_guard.sh` + `scripts/binding-guard.init` 是可直接用的幂等保活实现：每 30 秒校验一次，缺什么补什么；代理表还没建好时安静跳过。**不要**用 `rc.local`，它只跑一次，代理表重建后就失效了。

## 验收（必须做）

`scripts/wan_check.sh` 逐条线路探测，再加三项针对性验证：

```sh
# 1) 目标确实从指定线路出去（路由器上强制绑源地址测试）
curl -s --interface <该WAN的接口名> -m 8 -o /dev/null -w '%{http_code}\n' http://<目标>/

# 2) 代理确实没碰它
grep -c '<目标IP>' /etc/mesl/mihomo.log 2>/dev/null     # 应为 0
nft list chain inet <代理表> prerouting | grep '<目标IP>'  # 命中计数在涨

# 3) 从 LAN 侧客户端实际验证
ssh -p <端口> <用户>@<目标> 'echo $SSH_CLIENT'          # 源地址应是该 WAN 的地址（或对端 NAT 后）
```

**自愈验证**（证明持久化真的有效）：手动删掉 nft 例外 / 路由 / ip rule，等 35 秒，三项应自动恢复。

## 常见误判

- **"两条 WiFi 都配了就是双 WAN"** —— 两个 STA 挂在同一个 interface 上就不是；必须拆成 `wwan`/`wwan2` 两个接口。
- **"加了路由就生效"** —— 有透明代理时，`prerouting` 的 redirect 先于路由。
- **"mihomo 规则里写 DIRECT 就等于直连"** —— 不等于，见第 4 步。
- **"rc.local 挂一下就行"** —— 代理表重建后失效；用 procd。
- **"改了 dst 地址规则就能按接口分流"** —— `prerouting` 阶段还没做路由决策，拿不到出口网卡；按接口分流要用 `ip rule`/`fwmark` 或 mangle 标记。
- **"装 mwan3 解决一切"** —— mwan3 管的是"默认出口的负载均衡/故障切换"，不管"指定目标走指定线路"；而且 fw4 环境必须装 `mwan3-nft`，老的 iptables 版会冲突。

## 附带脚本

- `scripts/topo_probe.sh` — 一次性采集拓扑：上行、无线能力、DSA、WAN 协议、代理劫持情况。
- `scripts/wan_check.sh <ifname>` — 探测单条线路通不通、是不是被门户拦。
- `scripts/binding_guard.sh` — 幂等保活脚本（nft 例外 + 静态路由 + ip rule），供 procd 周期调用。
- `scripts/binding-guard.init` — procd 服务包装，`enable` 后开机自启并自动拉起。

## 参考文档

- `references/case-multi-wan-investigation.md` — **现场实录**：十个阶段、原始输出、两次失败方案
  （只靠 DIRECT / 只靠 fw4 include）、被否决的思路（两层代理、VLAN）。先读这篇再读结论。
- `references/tooling-gotchas.md` — busybox/curl/ip/nft 的误导性输出清单，每条都带真实报错。
- `references/script-development-notes.md` — 本 skill 脚本的开发记录：改过几轮、每个 bug 怎么发现的。
- `references/topology-and-limits.md` — 上行枚举、无线并发能力、DSA、mwan3 选择、硬件上限。
- `references/transparent-proxy-conflicts.md` — 代理劫持的完整机理与四种解法。
- `references/portal-auth.md` — 门户认证网络的识别、放行、持久化。
- `references/persistence.md` — uci 能做/不能做的清单，procd 保活的正确写法与自愈验证。