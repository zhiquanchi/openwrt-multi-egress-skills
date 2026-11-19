# 透明代理劫持：为什么"路由改对了却不生效"

这是多 WAN 分流里最耗时、最容易误判的问题。现象是：路由、`ip rule` 都配了，`ip route get` 也显示正确，但流量就是不走你要的那条线。

## 1. 机理

以 mihomo / Clash.Meta 系列（mesl、OpenClash、nikki、shellcrash 都是这一套）为例，它们在 `inet mihomo` 表里建一条 `prerouting` 链，priority 一般是 `dstnat+1`：

```
table inet mihomo {
    chain prerouting {
        type filter hook prerouting priority dstnat + 1; policy accept;
        ...
        meta nfproto ipv4 meta l4proto tcp counter redirect to :41287
    }
}
```

含义：**除本地网段外，所有 LAN 发出的 TCP 都被重定向到本机 41287 端口**，交给代理内核处理。

后果有两层：

1. **静态路由、`ip rule` 完全不起作用** —— 包在 `prerouting` 就被 `redirect`，根本没有进入转发路径，路由决策发生在内核的 `tproxy`/`redirect` 套接字之后。
2. **即使代理规则写 `DIRECT`，出口也不受你控制** —— `DIRECT` 只是"不用代理节点"，流量仍被重定向到代理内核，再由**代理内核自己**发起一次新连接。这个新连接的出口取决于代理内核自身进程的路由/策略路由，往往命中代理自己的表（例如 `ip rule ... lookup 2022`，表 2022 的默认路由是 `dev Meta`）。

日志上能直接看到：

```
[TCP] dial DIRECT (match IPCIDR/172.16.0.0/12) 192.168.5.110:54448 --> 172.16.210.18:80
      error: connect failed: dial tcp 172.16.210.18:80: i/o timeout
```

"匹配了 DIRECT，然后 connect 失败"——因为它是从错误的网卡/源地址出去的。

## 2. 先确认是否被劫持

```sh
nft list tables
nft list chain inet <代理表> prerouting | head -20
ip rule show
ip route show table all | grep -v '^broadcast'
```

判断标志：

- 代理表 `prerouting` 里有 `redirect to :<端口>` 或 `tproxy`；
- `ip rule` 里有 `not from all iif lo lookup <表号>` 这类规则；
- 该表号的默认路由指向 `dev Meta` / `utun` / `tun0`。

## 3. 四种解法

### 解法 A：在代理表链首插入 `return`（推荐，唯一可靠）

```sh
# 单目标
nft insert rule inet mihomo prerouting ip daddr 172.16.210.18 counter return

# 网段集合
nft insert rule inet mihomo prerouting ip daddr { 192.168.128.0/19, 172.16.0.0/12, 120.255.1.167 } counter return
```

`return` 让这类流量立刻退出代理链，回到正常转发路径，此后静态路由与 `ip rule` 就都生效了。

验证：

```sh
nft list chain inet mihomo prerouting | head -5     # 规则在最前面
nft -a list chain inet mihomo prerouting | grep -F '<目标>' # 看 counter 在涨
grep -c '<目标IP>' /etc/mesl/mihomo.log              # 应为 0，代理从未碰过
```

> 这条规则**必须插在链首**。追加到链尾没有意义——链尾往往是 `redirect ... return`，后面的规则永远不会被命中。

### 解法 B：只改代理规则（`IPCIDR,...,DIRECT`）

```yaml
rules:
  - IPCIDR,172.16.0.0/12,DIRECT
  - IPCIDR,192.168.128.0/19,DIRECT
```

**能做什么**：让这些流量不经过代理节点（省流量、省延迟）。
**不能做什么**：不能让它们绕开劫持，也**不能固定出口网卡**。

实测对照（同一个目标、同一台路由器）：

| 配置 | 结果 |
|---|---|
| 只有 `DIRECT` 规则 | `ssh: Connection closed by <目标> port 31009`（TCP 建上了但被对端断） |
| 链首 `return` 例外 | 正常，且服务器侧看到的是预期源地址 |

结论：需要**固定出口**或**门户认证**时，B 不能替代 A。

### 解法 C：改成按 mark 分流（复杂，不推荐）

在 mangle 里给特定流量打 mark，再让代理的 `ip rule` 忽略带 mark 的包。可行但：

- 依赖代理的具体实现细节（表号、mark 值），升级就可能变；
- 对 `redirect`（nat 阶段）型劫持，mark 无法阻止 `prerouting` 的重定向，还得配合 `return`。

### 解法 D：换掉代理封装（治本）

mesl / OpenClash 这类"加密订阅 + 运行时生成配置"的封装，配置不可静态注入，只能用运行时插规则。改用 **nikki / 官方 mihomo 包**自己维护配置时，可以把 `bypass-masq.nft` 这类例外交给 fw4 include 管理，从根本上解决。

代价：要自己维护订阅和分流规则。

## 4. 为什么 `fw4` 的 include 救不了

firewall4 支持这些自定义入口：

```
/usr/share/nftables.d/ruleset-pre/        在 table inet fw4 之前
/usr/share/nftables.d/ruleset-post/       在 table inet fw4 之后
/usr/share/nftables.d/table-pre|post/     在 fw4 表内首/末条链前后
/usr/share/nftables.d/chain-post/<链>/     在某条链最后一条规则之后
```

```uci
config include
    option type 'nftables'
    option path '/etc/my_rules.nft'
    option position 'table-post'
```

限制：**include 只能作用于 `fw4` 自己的表**。代理的表（`inet mihomo`）是代理进程运行时创建的，既不归 fw4 管，也没有"链首插入"的 include 位置。所以：

| 目标 | 能否静态写死 |
|---|---|
| 走不走代理（DIRECT） | 能（代理自己的规则表） |
| 绕过 `redirect` 劫持 | **不能**，必须运行时链首插入 |
| 固定从某接口出口 | 能（uci 静态路由 + `ip rule`） |

## 5. 顺序与优先级备忘

```
prerouting (priority dstnat+1)  ← 代理在这里决定命运
        ↓（若 return）
路由决策 / ip rule / 策略路由     ← 你配的静态路由在这里生效
        ↓
forward → masq（wan 区域）→ 出口
```

所以排查顺序永远是：**先看 prerouting 有没有被 `redirect`，再看路由**。

## 6. 其他代理实现的差异

| 实现 | 劫持方式 | 例外插入点 |
|---|---|---|
| mihomo / Clash.Meta（TProxy 模式） | `inet mihomo` 表 `prerouting` | `nft insert rule inet mihomo prerouting ...` |
| OpenClash（redirect 模式） | 同上（或 iptables mangle，老版本） | 优先用 LuCI 的"绕过"列表；脚本插规则要对应表名 |
| sing-box (auto_route) | 自己管理 nft/ip rule，表名随版本变 | 用 `route.rules` 的 `ip_is_private` / `geoip` 排除 |
| passwall2 | iptables/nft 二选一，随 fw4 | 界面里有"直连"列表，优先用界面 |

通用原则：**能通过代理自己的规则/界面排除的，优先用它**；只有需要"绕开劫持本身"时，才去插 nft 规则。