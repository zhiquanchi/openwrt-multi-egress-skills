# 工具陷阱清单：busybox、curl、ip、nft 里那些会骗人的输出

> 来源说明：本清单合并了两次真实排障的产物——
> - 多 WAN 与指定出口（`case-multi-wan-investigation.md`）：`timeout` 缺失、`nc` 简化、
>   `ip route get ... from` 误报、`redirect to :41287` 等；
> - Gemini 双出口（兄弟 skill 的 `case-gemini-investigation.md`）：`find: unpaired '('`、
>   `x-luci-login-required: yes`、`ip -br` 列序等。

> 这份清单全部来自实战遇到的**具体报错**。每条都给出"看起来像什么"和"实际是什么"，
> 用来避免把工具行为误判成配置问题。

## 1. busybox 与 OpenWrt 的差异

### 1.1 没有 `timeout`

```sh
timeout 10 curl http://x
```

```
sh: timeout: not found
```

OpenWrt 的 busybox 默认不编 `timeout`。替代：

```sh
# 用 curl 自带的超时
curl -m 10 ...
# 或后台 + kill
( sleep 10; kill $$ ) & 
```

### 1.2 `nc` 被大幅简化

```sh
nc -w 6 -s 192.168.154.12 120.255.1.167 31009
```

```
BusyBox v1.37.0 ... multi-call binary.
Usage: nc [IPADDR PORT]
```

**不支持 `-w`、`-s`、`-z`**。测端口连通性改用 `curl` 绑定接口/源地址：

```sh
curl -sS --interface phy0-sta0 -m 8 http://<host>:<port>/
```

### 1.3 `find` 的括号转义在聊天窗口里会被吃掉

```sh
find /etc -type f \( -name '*.yaml' \)
```

```
find: unpaired '('
```

用户从聊天窗口复制时，`\(` 的反斜杠被"智能"处理。**给用户的命令不要用这种结构**，
改用 `grep -E`、`awk`，或分步执行。

### 1.4 `sed` 的 `[[:space:]]` 和 emoji

在 BSD/macOS 的 `sed` 上，`sed -e 's/.*"name":[[:space:]]*//'` 对含多字节 emoji 的行**静默不匹配**，
输出原样（不报错、不改）。这是本仓库 `diag-egress.sh` 改成"结构化解析交给 python"的起因。

安全的 sed 写法（同时兼容 busybox / GNU / BSD）：

```sh
sed -e 's/.*"name": *"\([^"]*\)".*"now": *"\([^"]*\)".*/\1 -> \2/'
```

用字面空格 ` *` 而不是 `[[:space:]]*`，并且**先 sed 再去 grep 标记**，不要在 sed 之前用 grep 预过滤。

### 1.5 `awk` 不支持 Perl 的正则扩展

```sh
awk '/table (?!main)/'      # 错误：awk 没有负向环视
```

正确的写法：

```sh
awk '/table/ && $NF != "main" && !/ table main/ {print}'
```

## 2. curl 的误导性返回

### 2.1 `HTTP/0.9` 其实是"TCP 通了"

```sh
curl -sS --interface phy0-sta0 -m 8 http://120.255.1.167:31009/
```

```
curl: (1) Received HTTP/0.9 when not allowed
```

对 SSH 端口发 HTTP 请求，对端回的是 SSH banner（`SSH-2.0-...`），curl 当成了 HTTP/0.9。
**这不是失败，反而证明 TCP 建连成功**。

判断方法：看返回内容是不是 `SSH-`，或用 `curl -v` 看连接阶段。

### 2.2 `Remote IP` 不是出口 IP

`curl -w '%{remote_ip}'` 给的是 **TCP 对端地址**（通常是 CDN 边缘节点），
**不是你的出口 IP**。取出口 IP 要用回显服务：

```sh
curl -s https://www.cloudflare.com/cdn-cgi/trace | grep '^ip='
curl -s https://api.ipify.org
```

### 2.3 `-4` / `-6` 会静默回退

走代理或系统支持双栈时，`curl -6` 可能仍然返回 IPv4 地址。**不要信任这个标志**，
应拿到结果后**按地址形态判断**（含 `:` 是 IPv6）：

```sh
is_v6() { case "$1" in *:*) return 0;; *) return 1;; esac; }
```

### 2.4 通过代理访问 ipinfo.io / whoer.net 返回 429/403 是正常的

这些站本身常被分流到共享出口 IP，被限流属于正常，不代表网络故障。

## 3. `ip` 命令的陷阱

### 3.1 `ip route get ... from <别的源地址>` 会误报不可达

```sh
ip route get 120.255.1.167 from 192.168.5.110
```

```
RTNETLINK answers: Network unreachable
```

但同一时刻 `ip route | grep` 和 `ip route get 120.255.1.167`（不指定源）都正常。
**不要用指定源地址的 `route get` 来判断路由是否存在**。

### 3.2 `ip -br` 的输出列顺序

```
phy1-sta0    UP   192.0.2.10/24
```

`IFNAME  STATE  ADDR`，地址是**第 3 列**。取地址要 `awk '{print $3}'`。

### 3.3 判断接口是否存在，别信 `ip link` 的退出码

不同系统的 `ip` 实现（iproute2 / iproute2mac / busybox ip）对"接口不存在"的退出码不一致。
Linux 上用 `/sys/class/net/<if>` 判断最可靠：

```sh
[ -d "/sys/class/net/$iface" ] || echo "接口不存在"
```

## 4. nft 的陷阱

### 4.1 `insert` 与 `add` 的区别

- `nft insert rule` → 插到链**首**（这才是我们需要的）
- `nft add rule` → 追加到链**尾**（永远命中不了，因为链尾之前就有 `redirect ... return`）

### 4.2 重复插入不会报错，只会越插越多

每轮都 `nft insert` 而不检查，规则会无限堆叠。必须先 `grep -q` 判断，或先按 handle 删旧。

### 4.3 取 handle 删规则的写法

```sh
H=$(nft -a list chain inet mihomo prerouting | grep -F '<目标>' | sed 's/.*handle \([0-9]*\).*/\1/')
nft delete rule inet mihomo prerouting handle "$H"
```

注意 `grep -F` 匹配的是**规则里的目标字符串**，如果目标做了脱敏（例如 IP 被替换），
要同步改这里，否则删不掉。

### 4.4 表的创建者决定它何时消失

`inet mihomo` 是代理进程创建的。`nft list tables` 里能列出多个表时，要分清哪个属于谁：

```
table inet fw4           ← firewall4（有 uci 管理）
table inet passwall2     ← passwall2（装了但没跑）
table inet mesl_v6dns    ← mesl
table inet mihomo        ← mesl 拉起的 mihomo 内核，运行时创建
```

**只有 fw4 的表能用 uci/include 静态管理**，其余都是运行时的。

## 5. 无线相关的观察陷阱

### 5.1 `Channel: 0 (unknown)` 表示 AP 没起来

```
phy0-ap0 ESSID: "OpenWrt_2.4G"
         Mode: Master  Channel: 0 (unknown)
```

不是"信道 0 合法"，而是**没拿到信道**。常见于刚切过信道、DFS 等待、或射频刚重启。

### 5.2 SSID 里有下划线 / 空格，按用户口述配置会连不上

实际扫描：

```
ESSID: "mg_newoffice"     ← 有下划线
```

用户口述"mgnewoffice"。**必须用扫描到的字面量**，包括下划线、空格、大小写。

### 5.3 `valid interface combinations` 要整行读

```

* #{ managed } <= 1, #{ AP, mesh point } <= 16, total <= 16, #channels <= 2
```

这行要整体理解：**STA 最多 1 个**，但**可以和 AP 并存**（因为写在同一行），
`#channels <= 2` 意味着两个 STA 必须同信道才能共存。只看一半就会得出错误结论。

## 6. 会话/交互类陷阱

| 现象 | 真相 |
|---|---|
| `curl` 返回 403 + `Server: nginx` + `x-luci-login-required: yes` | 是 LuCI 登录页，不是网络问题 |
| `connect` 时间极短（17ms）却 403 | 连接建立了，被应用层拒绝，**不是不可达** |
| WebFetch 报 `resolves to a private/internal address` | 安全策略拦截，不是网络问题 |
| 用户输出开头出现 `| head -80` | 上一段命令被截断拼接，**输出不完整**，不要据此判断 |
| 用户贴回的内容含 `<system-reminder>` / `<task-notification>` | 系统注入，不是用户说话，不要当成确认 |

## 7. 一句话总结

> **工具的沉默和误报，比配置错误更容易把人带偏。**
> 遇到"配了但没效果"，先确认三件事：命令真的执行了吗？输出完整吗？这个字段真的是我以为的意思吗？