# 现场实录：多 WAN / 指定出口配置全过程（含原始输出与失败尝试）

> 本文是 `openwrt-multi-wan-routing` 的事实来源。按时间顺序记录**真实发生了什么**，
> 包括三次明显的误判、两次失败的方案、以及最终为什么采用"uci + procd 保活"的组合。
>
> 环境：CMCC RAX3000M (NAND) / Kwrt 25.12.2 / MT7981 双频 / DSA / kernel 6.12.74。
> 文中 IP、SSID、密码、服务器地址均已替换为示例值，结构保持不变。

---

## 阶段一：USB 上网，一次彻底的"不是配置问题"

### 1.1 初始判断：硬件可以，固件不行

```
=== model ===
CMCC RAX3000M (NAND version)
cmcc,rax3000m-nand

=== usb devices ===
T:  Bus=01 ... Spd=480  MxCh= 1
D:  Ver= 2.00 Cls=09(hub  ) ...  Product=xHCI Host Controller
T:  Bus=02 ... Spd=10000 MxCh= 1
D:  Ver= 3.10 Cls=09(hub  ) ...  Product=xHCI Host Controller
```

USB 控制器正常（USB2 480Mbps + USB3 10Gbps 两条总线），但全树**只有 root hub**。
检查驱动后发现整个 usbnet 系列一个都没装，`/lib/netifd/proto/` 也只有
`dhcp / dhcpv6 / dslite / ppp / wireguard`，没有 qmi/ncm/mbim。

于是装了：

```sh
opkg install kmod-usb-net kmod-usb-net-rndis kmod-usb-net-cdc-ether kmod-usb-net-cdc-ncm usbutils
```

建了 `wanb`：

```
network.wanb=interface
  proto=dhcp
  device=usb0
  metric=20
firewall zone wan 的 network = wan wan6 wwan wanb
```

状态：

```
=== wanb ===
"errors": [ { "subsystem": "interface", "code": "NO_DEVICE" } ]
=== default routes ===
default via 192.168.0.1 dev phy1-sta0 proto static src 192.168.0.212
```

`NO_DEVICE` 是**预期的**（设备还没插）。

### 1.2 插上设备后：路由器看不到任何东西

```
=== lsusb ===
Bus 001 Device 001: ID 1d6b:0002 Linux Foundation 2.0 root hub
Bus 002 Device 001: ID 1d6b:0003 Linux Foundation 3.0 root hub
=== usb devices ===
1-0:1.0
2-0:1.0
usb1
usb2
```

**插上设备后，USB 树没有任何变化**——连一条枚举记录都没有。

### 1.3 在 Mac 上交叉验证（关键一步）

用户说"我链接到本机了你测试下"，于是同时观察两端：

- Mac 端：`ioreg -p IOUSB` 里只有 VIA hub、一台手机、一个 Realtek 网卡，**没有 ZTE 设备**；
- 路由器端：`logread -f` 监听 2 分钟，grep 结果 **0 条**。

两端都看不到 → **不是驱动问题、不是协议问题**，是物理层或设备工作模式问题。

### 1.4 用户最终自己确认

> 「不要在探测 USB 网卡了，线缆的问题」

这是整个会话里第一次"排查方向被用户纠正"。**教训**：当两个独立主机都看不到设备时，
不要再研究驱动/协议，应该立刻把问题交回物理层（线材、供电、设备屏幕上的模式开关）。

留存的配置（`kmod-*` + `wanb` 接口）没有删——换根线就能用，这是对的。

---

## 阶段二：「两个 WiFi 做双 WAN」——第一次误判

### 2.1 用户问"使用两个 WiFi 做为 LAN 可以吗"

当时的答案是"可以，硬件支持"，依据：

```
* #{ managed } <= 1, #{ AP, mesh point } <= 16,
  total <= 16, #channels <= 2
```

这行说明 **STA 与 AP 可以并存**（同一行内），但 `#{ managed } <= 1` 也说明
**同一 radio 同时只能有一个 STA**。

### 2.2 发现一个隐藏问题：2.4G AP 根本没起来

```
phy0-ap0 ESSID: "OpenWrt_2.4G"
         Mode: Master  Channel: 0 (unknown)
         Channel offset: none
```

`Channel: 0 (unknown)` + 无速率 = 2.4G AP 实际没工作。

### 2.3 关键判断：两个 STA 挂在同一个接口上，不算双 WAN

检查 `ubus call network.wireless status` 发现：

```
"section": "wifinet2"  →  device radio1(5G)  network ["wwan"]
"section": "wifinet3"  →  device radio0(2.4G) network ["wwan"]
```

**两个 STA 都挂在同一个 `wwan` 接口上**。这种配置 netifd 只会把它们当成一个逻辑接口，
只按其中一个算默认路由——**看起来有两个 WiFi，实际不是双 WAN**。

这是本 skill「一个接口一条上行」这条规则的来源。

---

## 阶段三：接入办公网，撞上门户认证

### 3.1 扫描时发现 SSID 名字和用户说的不一样

用户说连 `mgnewoffice`，实际扫描结果是：

```
ESSID: "migu_bangong"    Signal: -66 dBm
ESSID: "mg_newoffice"    Signal: -67 dBm    ← 有下划线
ESSID: unknown           Signal: -65 dBm
```

同一张网有多个 BSSID，最强的 -44dBm。**SSID 带下划线**，如果直接按用户口述的
`mgnewoffice` 去配，会连不上。

### 3.2 改配置：拆出独立接口 wwan2

```sh
uci set wireless.wifinet3.ssid='mg_newoffice'
uci set wireless.wifinet3.key='<密码>'
uci set wireless.wifinet3.encryption='psk2'
uci set wireless.wifinet3.network='wwan2'
uci commit wireless

uci set network.wwan2=interface
uci set network.wwan2.proto='dhcp'
uci set network.wwan2.metric='30'
uci commit network

uci add_list firewall.@zone[1].network='wwan2'
uci commit firewall
```

连接成功：

```
=== phy0-sta0 link ===
Connected to 0e:0d:9e:22:ca:74 (on phy0-sta0)
	SSID: mg_newoffice
	freq: 2472.0
	signal: -53 dBm
=== wwan2 status ===
	"metric": 30,
	"ipv4-address": [ { "address": "192.168.154.12", "mask": 19 } ]
```

默认路由变成两条（metric 小的优先）：

```
default via 192.168.0.1     dev phy1-sta0 proto static src 192.168.0.212
default via 192.168.159.254 dev phy0-sta0 proto static src 192.168.154.12 metric 30
```

### 3.3 门户认证被识别出来

```
2 packets transmitted, 0 packets received, 100% packet loss     ← ping 不通
```

```sh
curl -sSI --interface phy0-sta0 -m 8 http://www.baidu.com
```

```
HTTP/1.0 302 Moved Temporarily
Server: NetEngine Server 1.0
Location: http://172.16.210.18/a79.htm?wlanuserip=192.168.154.12&wlanacname=&wlanacip=192.168.254.2&wlanusermac=...
```

204 探测同样被劫持：

```
204test=302 redirect=http://172.16.210.18/a79.htm?wlanuserip=...
```

典型门户（华为 NetEngine）。**HTTP 被 302、ICMP 全丢包**是它的指纹。

---

## 阶段四：核心 bug —— 路由改对了，但流量没走路由

### 4.1 第一次尝试：加静态路由（失败）

```sh
ip route replace 172.16.210.18/32 dev phy0-sta0 src 192.168.154.12
ip route get 172.16.210.18
```

```
172.16.210.18 dev phy0-sta0 src 192.168.154.12 uid 0
    cache
```

路由**正确**。但实际访问：

```
=== portal reachable from router ===
curl: (7) Failed to connect to 172.16.210.18 port 80 after 3086 ms: Error
http=000
```

**路由表是对的，连接却失败。** 这是整个会话最重要的转折点。

### 4.2 用户反馈：登录页还是打不开

> 「持久化。 2 登录页无法访问」

### 4.3 找到真正原因：透明代理在 prerouting 劫持

```sh
nft list tables
```

```
table inet fw4
table inet passwall2
table inet mesl_v6dns
table inet mihomo          ← 关键
```

```sh
nft list table inet mihomo
```

```
table inet mihomo {
	set inet4_local_address_set {
		type ipv4_addr
		flags interval
		elements = { 127.0.0.0/8, 192.168.0.0/24,
			     192.168.5.0/24, 198.18.0.0/30 }
	}

	chain output {
		type nat hook output priority mangle; policy accept;
		oifname "Meta" ... redirect to :41287 return
	}

	chain prerouting {
		type nat hook prerouting priority dstnat + 1; policy accept;
		iifname "Meta" counter packets 2 bytes 146 return
		ip saddr @inet4_local_address_set ... th dport 53 ... dnat ip to 198.18.0.2
		ip daddr @inet4_local_address_set counter packets 394 bytes 28302 return
		meta nfproto ipv4 meta l4proto tcp counter packets 31613 bytes 2159162 redirect to :41287 return
	}
}
```

**最后一行**：`meta nfproto ipv4 meta l4proto tcp → redirect to :41287 return`。

含义：**所有 LAN 出站 TCP 都被无条件重定向到本机 41287**。包在 `prerouting`
（priority `dstnat+1`）就被劫走，**根本没进入转发路径**，静态路由和 `ip rule` 都不参与。

同时看到策略路由也在旁边加码：

```
=== ip rules ===
9000:	from all to 198.18.0.0/30 lookup 2022
9001:	not from all dport 53 lookup main suppress_prefixlength 0
9002:	not from all iif lo lookup 2022
9002:	from 0.0.0.0 iif lo lookup 2022
```

### 4.4 用户追问"这个具体原因是什么"，mihomo 日志给出铁证

```sh
grep -n '172.16.210' /etc/mesl/mihomo.log
```

```
14002: level=warning msg="[TCP] dial DIRECT (match IPCIDR/172.16.0.0/12) 192.168.5.110:54448 --> 172.16.210.18:80 error: connect failed: dial tcp 172.16.210.18:80: i/o timeout"
14003: ... 192.168.5.110:54458 --> 172.16.210.18:80 ... i/o timeout
14010: ... 192.168.5.110:55226 --> 172.16.210.18:80 ... i/o timeout
```

这行日志信息量极大：

- `dial DIRECT` → mihomo **匹配到了 DIRECT 规则**（`IPCIDR/172.16.0.0/12`）；
- 然后 `connect failed ... i/o timeout` → **它自己重新发起连接时失败了**。

**结论：`DIRECT` 不等于绕过代理。** 流量仍被 redirect 进内核，由内核重新建连，
而这个新连接的出口网卡/源地址**不受路由器路由表控制**（受 mihomo 自己的策略路由支配）。

### 4.5 修复：在代理表 prerouting **链首**插入 return

```sh
nft insert rule inet mihomo prerouting ip daddr 172.16.210.18 counter return
nft -a list chain inet mihomo prerouting
```

```
table inet mihomo {
	chain prerouting { # handle 4
		type nat hook prerouting priority dstnat + 1; policy accept;
		ip daddr 172.16.210.18 counter packets 0 bytes 0 return # handle 10   ← 插到最前面了
		iifname "Meta" counter packets 2 bytes 146 return # handle 5
		ip saddr @inet4_local_address_set ... dnat ip to 198.18.0.2 # handle 7
		ip daddr @inet4_local_address_set counter packets 401 bytes 28730 return # handle 8
		meta nfproto ipv4 meta l4proto tcp counter packets 32166 bytes 2201377 redirect to :41287 return # handle 9
	}
}
```

效果（规则计数器开始涨，说明流量真的走了这条）：

```
ip daddr 172.16.210.18 counter packets 4 bytes 256 return
```

门户登录页从 Mac 侧可访问了。**用户完成认证**后进入下一阶段。

---

## 阶段五：指定服务器走指定 WAN（三层叠加）

### 5.1 需求

用户指向 `H3-SERVICE.md`：这台服务器的 SSH **不走代理，只走 wwan2**。

### 5.2 第一版只加路由 + ip rule，`ip route get` 直接报不可达

```sh
ip route replace 120.255.1.167/32 via 192.168.159.254 dev phy0-sta0 src 192.168.154.12
ip rule add to 120.255.1.167/32 lookup main pref 8800
ip route get 120.255.1.167 from 192.168.5.110
```

```
RTNETLINK answers: Network unreachable
```

但 `ip rule` 确实加上了：

```
0:	from all lookup local
8800:	from all to 120.255.1.167 lookup main
9000:	from all to 198.18.0.0/30 lookup 2022
```

紧接着复查路由却是在的：

```
120.255.1.167 via 192.168.159.254 dev phy0-sta0 src 192.168.154.12
--- get ---
120.255.1.167 via 192.168.159.254 dev phy0-sta0 src 192.168.154.12 uid 0
    cache
```

即 **`ip route get ... from <另一个源地址>` 会报不可达，用默认源就正常**——
这是一个容易误导的观察，说明"route get 不可达"不等于"路由没配好"。

### 5.3 最终配置：三层，缺一不可

```
1. 路由   120.255.1.167/32 via 192.168.159.254 dev phy0-sta0 src 192.168.154.12
           （uci: network.h3route）
2. 策略路由 ip rule 8800: to 120.255.1.167 lookup main
3. 代理例外 ip daddr { 192.168.128.0/19, 172.16.0.0/12, 120.255.1.167 } counter return
```

第 1 层的 uci 写法（`network.h3route`）：

```
network.h3route=route
network.h3route.interface='wwan2'
network.h3route.target='120.255.1.167'
network.h3route.netmask='255.255.255.255'
network.h3route.gateway='192.168.159.254'
```

第 3 层在链首：

```
ip daddr { 120.255.1.167, 172.16.0.0/12, 192.168.128.0/19 } counter packets 0 bytes 0 return # handle 14
```

---

## 阶段六：两次失败的方案（重要，别重走）

### 6.1 失败方案 A：只靠 mihomo 的 `DIRECT` 规则

撤掉 nft 例外，只保留 `IPCIDR,...,DIRECT`，实测：

```
ssh result: Connection closed by 120.255.1.167 port 31009 exit 0
```

TCP **建起来了**，但**被对端关闭**。恢复 nft 例外后立刻恢复：

```
restored: ip daddr { 120.255.1.167, 172.16.0.0/12, 192.168.128.0/19 } counter packets 0 bytes 0 return
```

这就是"`DIRECT` 不能替代 `return`"的硬证据。

### 6.2 失败方案 B：用 fw4 的自定义 include

查了 OpenWrt 官方机制：

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

**不行**，原因：include 只能作用于 `fw4` 自己的表；`inet mihomo` 是代理进程运行时创建的，
而且**没有任何"插到别人链首"的 include 位置**。而 mihomo 的链尾就是 `redirect ... return`，
追加到后面的规则永远命中不了。

### 6.3 关于 USB 的结论（保留但不深入）

设备始终没在 Mac 和路由器任何一端枚举，`dmesg` 无记录。用户最终确认是线缆问题。
**这条分支没有结论，也不需要结论**——它和分流无关。

---

## 阶段七：诊断过程中的几个工具坑

| 坑 | 原始现象 |
|---|---|
| `timeout` 在 busybox 里不存在 | `sh: timeout: not found` |
| `nc` 参数被 busybox 简化 | `Usage: nc [IPADDR PORT]`，`-w/-s` 全不支持 |
| `curl` 对非 HTTP 端口报 0.9 | `Received HTTP/0.9` 其实是 SSH banner，说明 TCP 通了 |
| `ip route get ... from <src>` 误报 | `RTNETLINK answers: Network unreachable`，换源地址就正常 |

---

## 阶段八：持久化，以及为什么最终选 procd

### 8.1 先踩了 rc.local 的坑

第一版把脚本挂到 `/etc/rc.local`：

```
# migu 办公网直连（不经过 mihomo 代理）
[ -x /etc/migu-bypass.sh ] && /etc/migu-bypass.sh >/dev/null 2>&1 &
```

问题：**只跑一次**，且与代理启动并行，表还没建好就失败，失败无重试。

用户追问「这些配置不能写入到路由器里面吗」，于是查了 init.d：

```
boot bootcount cron dnsmasq done dropbear firewall fstab ... mesl ... passwall2 ...
```

发现 mesl 自己的 init 脚本注释写明它用 **mihomo TUN（auto-route + auto-redirect）**
接管流量——也就是说这个 nft 表是它每次启动重建的，外部无法静态注入。

### 8.2 改成 procd 常驻

```
/etc/init.d/migu-bypass   开机自启（S95），崩溃自动拉起
/etc/migu-bypass.sh       幂等校验：缺什么补什么，每 30 秒一轮
```

`rc.local` 还原成默认内容，不再依赖它。

### 8.3 自愈验证（决定性证据）

手动删掉三项，等 35 秒：

```
删除规则 handle=16
=== 删除后 ===
0        ← nft 规则没了
0        ← 路由没了
=== 等 35 秒 ===
=== 恢复情况 ===
		ip daddr { 120.255.1.167, 172.16.0.0/12, 192.168.128.0/19 } counter packets 0 bytes 0 return
120.255.1.167 via 192.168.159.254 dev phy0-sta0
8800:	from all to 120.255.1.167 lookup main
```

**三项全部自动恢复**，证明持久化有效。

---

## 阶段九：最终验收

认证完成后的对照测试：

| 路径 | 到 31009 | 到公网 443 |
|---|---|---|
| 经 wwan2（办公网） | 超时（未认证时） | 超时（80 被门户 302） |
| 经 5G 中继 | 超时 | 200 正常 |

认证后：

```
ssh: OK
ip daddr { 120.255.1.167, 172.16.0.0/12, 192.168.128.0/19 } counter packets 1 bytes 64 return
```

规则计数器涨到 27 packets / 2289 bytes，同时：

```
--- mihomo log hits ---
0
```

**代理日志里对目标的命中数为 0** —— 证明代理从未接触过这条连接。

服务器侧看到的源地址是办公网 NAT 后的地址（不是路由器的 `192.168.154.12`），
说明 NAT 发生在办公网侧，与路由器无关。

---

## 阶段十：被否决的两种思路（记录下来避免重复讨论）

### 10.1 两层代理

用户问"是否可以用两层代理"。当时的结论是**可以但不建议叠加透明代理**：
两个都开透明代理会在 `nat prerouting` 抢包，先命中的全接管，容易回环、断流、UDP 全废。
正确做法是只让一层做透明，另一层只开 socks。

### 10.2 VLAN

用户问"按现在的规则 VLAN 比现在要好吗"。结论：**没有必要**。
当时的网络只有一个 `192.168.5.0/24`，真正复杂的是**出口**而不是**网段**；
VLAN 是二层隔离工具，不是分流工具，用它解决代理分流属于用错工具。
而且 `vlan_filtering` 一旦打开，所有端口必须显式归属，漏一个就断网。

---

## 从这次会话提炼的规则（已并入 SKILL.md 与各 references）

1. **一个接口一条上行**：两个 STA 挂同一个 `wwan` 不算双 WAN。
2. **看谁在跑，不看装了什么**：`ps` 优先于 `opkg list-installed`。
3. **路由改对了却没生效 → 先查 prerouting**。
4. **`DIRECT` ≠ 绕过劫持**：要固定出口必须链首 `return`。
5. **fw4 include 插不进代理的表**：没有"链首"入口。
6. **rc.local 不够**：代理表重建就丢，要用 procd 周期补。
7. **两端都看不到设备 → 物理层问题**，别再查驱动。
8. **先确认线路能上网，再查分流**，否则所有失败都长得一样。

## 未在本机验证的部分（诚实标注）

- 本文的配置在真实设备上由当时会话执行并验证过（见计数器、自愈、日志证据）；
- 但本仓库的 `topo_probe.sh` / `wan_check.sh` / `binding_guard.sh` 是**重新实现**的，
  只在模拟的 `nft`/`ip` 环境里回归过，**没有在原设备上重跑**；
- 原会话的脚本是临时手写的（`/etc/migu-bypass.sh`），本仓库版本增加了配置外置、
  自动探测表名、单目标/多目标两种语法。