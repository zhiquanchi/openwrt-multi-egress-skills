# 持久化：uci 能做什么、不能做什么

## 1. 先分类：三类东西，三种归宿

| 配置内容 | 有 uci 入口吗 | 放哪 |
|---|---|---|
| 接口（`network.wwan2`）、proto、metric、device | 有 | `/etc/config/network` |
| 静态路由（`network.<name>=route`） | 有 | `/etc/config/network` |
| 防火墙区域归属（把接口加进 wan 区） | 有 | `/etc/config/firewall` |
| 无线 STA 的 SSID/密码/所属网络 | 有 | `/etc/config/wireless` |
| **代理表里的 nft 例外规则** | **没有** | procd 常驻服务，运行时插入 |
| **`ip rule`（策略路由）** | **没有**（OpenWrt 无对应 uci） | procd 常驻服务 |
| **按接口名绑定源地址的动态路由**（网关是 DHCP 下发的） | 部分（用 `ip route replace` 更稳） | procd 常驻服务 |

> 固件升级时 `/etc` 默认保留，所以 `/etc/config/*` 和 procd 服务都会保留；`/dev/shm`、`/tmp` 下的一律会丢。

## 2. 为什么不能用 `rc.local`

`rc.local` 只在开机时执行**一次**。问题是：

- 代理内核（mesl / OpenClash）在**自己重启时**会重建它的 nft 表，`rc.local` 插进去的规则随之消失；
- 整机重启时，`rc.local` 与代理启动是并行的，谁先谁后不确定，插规则时表可能还没建好，直接失败；
- 失败后没有任何重试。

所以 `rc.local` 只能做"一次性动作"，做不了"保证某状态一直存在"。

## 3. procd 保活的正确写法

一个幂等的 `ensure` 脚本 + 一个每 30 秒调用它的 procd 服务。

`binding_guard.sh` 的要点：

```sh
# 1) 资源没就绪就安静退出，等下一轮（不要 sleep 在这里，会堆积进程）
nft list table inet <代理表> >/dev/null 2>&1 || exit 0
ip link show <WAN接口> >/dev/null 2>&1 || exit 0

# 2) 幂等：先查再补
nft list chain inet <代理表> prerouting | grep -q '<目标>' || \
  nft insert rule inet <代理表> prerouting ip daddr { ... } counter return

ip rule show | grep -q '<目标> lookup main' || \
  ip rule add to <目标>/32 lookup main pref 8800

GW=$(ip route show default dev <WAN接口> | awk '{print $3; exit}')
[ -n "$GW" ] && { ip route show <目标>/32 | grep -q . || \
  ip route replace <目标>/32 via "$GW" dev <WAN接口>; }
```

`binding-guard.init`：

```sh
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command /bin/sh -c 'while true; do /bin/sh /etc/binding_guard.sh; sleep 30; done'
	procd_set_param respawn 3600 5 0
	procd_close_instance
}
```

装法与启用：

```sh
cp binding_guard.sh  /etc/binding_guard.sh
cp binding-guard.init /etc/init.d/binding-guard
chmod +x /etc/binding_guard.sh /etc/init.d/binding-guard
/etc/init.d/binding-guard enable     # 开机自启（S95）
/etc/init.d/binding-guard start
/etc/init.d/binding-guard status     # 应有 running/pending 输出
ls /etc/rc.d/ | grep binding         # 应有 S95binding-guard
```

## 4. 自愈验证（必做）

**手动破坏，然后等，看它自己恢复**——这是唯一能证明持久化真有效的办法。

```sh
# 删掉三项
H=$(nft -a list chain inet <代理表> prerouting | grep -F '<目标>' | sed 's/.*handle \([0-9]*\).*/\1/')
nft delete rule inet <代理表> prerouting handle $H
ip route del <目标>/32
ip rule del to <目标>/32 lookup main pref 8800

# 等一轮（30 秒 + 余量）
sleep 35

# 三项应全部回来
nft list chain inet <代理表> prerouting | grep '<目标>'
ip route | grep '<目标>'
ip rule show | grep '<目标>'
```

同时确认业务没断：从 LAN 侧复测那个需要走该线路的服务。

## 5. 常见坑

| 坑 | 说明 |
|---|---|
| **多插了重复规则** | `nft insert` 每次都插入，不做 `grep -q` 判断会越插越多 |
| **插到了链尾** | 必须 `insert`（链首），`add` 是追加 |
| **守护进程把日志刷爆** | `procd_set_param stdout 0 / stderr 0`，且 ensure 脚本正常路径不要输出 |
| **脚本在 `nft` 不可用时死循环报错** | 开头就 `command -v nft >/dev/null \|\| exit 0` |
| **rc.local 和 init.d 同时挂** | 二选一，否则开机会跑两遍；切到 procd 后把 `rc.local` 还原 |
| **固件升级后服务没了** | `/etc` 保留的话不会丢；用了"保留配置"升级就没事，全新刷机则需重新部署 |
| **门户认证过期被误判为配置失效** | 认证过期后所有流量被拦，看起来像规则坏了，先确认链路（见 `portal-auth.md`） |

## 6. 更彻底的方案

如果不想依赖守护进程，唯一办法是换成**配置可静态维护**的代理（nikki / 官方 mihomo 包），把 bypass 规则交给 `fw4` include 或代理自己的 `tun.route-exclude-address` 管理。代价是要自己维护订阅与分流规则，见 `transparent-proxy-conflicts.md` 解法 D。