# 拓扑与硬件上限

## 1. 枚举所有上行

```sh
ip -br link                        # 所有接口与状态
ip -4 -br addr                     # 谁拿到了地址
ip route show default              # 默认路由 + metric（metric 小的优先）
ubus call network.interface dump | head -60
```

上行类型速查：

| 接口特征 | 类型 | 备注 |
|---|---|---|
| `wan` / `eth1` | 有线 WAN | DSA 设备上常是独立 GMAC，可能是 2.5G |
| `phyX-sta0` 或 `wlan0` 且 `Mode: Client` | WiFi STA（中继） | 与同 radio 的 AP 抢空口 |
| `usb0` / `eth2`（`cdc_ether`） | USB 网络共享 | 设备侧需打开 "USB tethering" |
| `wwan0` + `qmi_wwan` | 4G/5G 模块 | 需要 `proto: qmi`/`mbim` |
| `pppoe-wan` | 拨号 | `proto: pppoe` |

## 2. 无线能否同时做多个 STA / STA+AP

这是"两个 WiFi 做双 WAN"能否成立的关键。

```sh
iw phy | grep -A6 'valid interface combinations'
```

判读**只看这一组**（其余是 P2P、mesh 的组合，与本问题无关）：

```
* #{ managed } <= 1, #{ AP, mesh point } <= 16,
  total <= 16, #channels <= 2
```

- `#{ managed } <= 1` → 这个 radio **同时只能有 1 个 STA**；
- `#{ managed } <= 1, #{ AP } <= 16, total <= 16` 是**同一行** → **STA 与 AP 可以并存**（MT7981 就是这种）；
- `#channels <= 2` → 最多 2 个信道。**两个 STA 连到同信道的两张网可以共存；连到不同信道会踢掉一个**。

实践结论：

| 需求 | 可行做法 |
|---|---|
| 两个 WiFi 上游做双 WAN | **两个 radio 各出一个 STA**（2.4G 连 A 网，5G 连 B 网） |
| 同一 radio 做中继 + AP | 可以，但共享同一空口，中继吞吐大约减半 |
| 同一 radio 连两个上游 | 只能连**同信道**的两个网，实际少见 |

检查当前状态：

```sh
iwinfo | grep -E '^[a-z]|ESSID|Mode|Channel'
```

`iwinfo` 里 `Channel: 0 (unknown)` + 无速率 + `DOWN` 通常表示该 AP 没起来（没分配到信道，常见于刚切过信道或 DFS）。

## 3. 有线：LAN 口能不能拆成 WAN2

```sh
ls -d /sys/class/net/*/dsa 2>/dev/null     # 有 dsa 目录说明是 DSA 架构
ls /sys/class/net/lan1/                     # DSA 端口下通常有 lan1_pvid 等
cat /etc/board.json
```

- DSA 架构（MT7530/MT7981 等）：`lan1/lan2/lan3` 是**独立端口**，可以随时把其中一个从 `br-lan` 移出，做成 `wan2`；
- 老式 swconfig：端口在硬件交换机里，拆分要改 switch 配置，麻烦且有风险。

拆法（示例，**会短暂断网**）：

```sh
uci del_list network.@device[@device='br-lan'].ports='lan3'
uci set network.wan2=interface
uci set network.wan2.device='lan3'
uci set network.wan2.proto='dhcp'
uci set network.wan2.metric='10'
uci add_list firewall.@zone[1].network='wan2'
uci commit
/etc/init.d/network reload && /etc/init.d/firewall reload
```

## 4. USB 网络共享（4G/5G 随身 WiFi）

整体是"标准 USB 网卡"模式的设备，主机侧只需要几个 kmod：

```sh
opkg update
opkg install kmod-usb-net kmod-usb-net-rndis kmod-usb-net-cdc-ether kmod-usb-net-cdc-ncm usbutils
```

判断设备到底以什么方式枚举：

```sh
lsusb
cat /sys/kernel/debug/usb/devices | grep -E 'Vendor|Product|I: If#'
```

- `Cls=02/0a`（CDC-ECM）/ `02/0d`（NCM）→ `cdc_ether` / `cdc_ncm`；
- `Cls=e0/01`（RNDIS 厂商接口）→ `rndis_host`；
- **只有 `Cls=08`（存储）或完全看不到设备** → 设备没进数据模式，或线是纯充电线。

> 排查顺序：先确认设备在别的主机（Mac/PC）上能被识别，再怀疑路由器。`lsusb` 里只有 root hub、`dmesg` 里没有枚举记录 = 物理层/设备模式问题，和驱动无关。

接口配法：

```sh
uci set network.wanb=interface
uci set network.wanb.proto='dhcp'
uci set network.wanb.device='usb0'      # 插入后 ip -br link 确认实际名字
uci set network.wanb.metric='20'
uci add_list firewall.@zone[1].network='wanb'
uci commit
```

设备没插时接口状态是 `NO_DEVICE`，属正常；插上后 netifd 自动拉起。

## 5. 要不要装 mwan3

| 需求 | 方案 |
|---|---|
| 只要"默认走主线路，主线路挂了走备线" | **不装**，靠 `metric` |
| 要多线路**负载均衡 / 按权重 / 掉线自动切换与回切** | 装 `mwan3-nft` |
| 要"**指定目标走指定线路**" | **mwan3 帮不上**，用本 skill 的静态路由 + ip rule + 代理例外 |

注意：

- 25.12 已是 fw4/nftables，**必须装 `mwan3-nft` + `luci-app-mwan3-nft`**，老的 iptables 版 `mwan3` 会冲突；
- `metric` 只影响默认路由优先级，切换靠默认路由失效，**没有连通性探测**；
- 如果某条上行是 WiFi 中继（`phyX-sta0`），它不是标准的 wan 接口，**mwan3 默认接管不到**，得先把它做成独立 interface。

## 6. 硬件上限小结

一台 DSA 架构双频路由器的出口上限通常是：

```
有线 WAN1 (2.5G) + 拆一个 LAN 当 WAN2 (千兆) + 2.4G STA + 5G STA + USB 网卡
```

实际能同时用几条，取决于**无线并发能力**（第 2 节）和**CPU**：多层加密或整机 NAT 吞吐会先撞 CPU，而不是链路带宽。