# 门户认证（Portal / 网页认证）网络

办公网、酒店、校园网常见：**能连上、能拿到 IP、能 ping 通网关，但上网被强制跳到登录页**。这类网络做上游时，坑比普通 DHCP 网多。

## 1. 识别

```sh
ip -4 -br addr show <STA接口>            # 拿到地址了
ip route show default                    # 有默认路由，指向对端网关
ping -c 2 -I <STA接口> <网关>             # 网关能通
curl -sS --interface <STA接口> -m 8 http://connect.rom.miui.com/generate_204 -o /dev/null \
     -w 'code=%{http_code} redirect=%{redirect_url}\n'
```

典型返回：

```
code=302 redirect=http://172.16.210.18/a79.htm
```

或直接访问任意 HTTP 站点被 302 到 `http://<门户>/...`（华为 NetEngine 系列常见 `a79.htm`、`webauth.do`）。

判断标志：

- **HTTP 被 302** 到内网地址的登录页；
- **HTTPS 与 ping 外网全部超时**（不只是失败，是丢包）；
- `curl --interface <STA接口> https://www.baidu.com` 超时，但 `http://www.baidu.com` 返回 302。

`scripts/wan_check.sh <接口名>` 会自动打这个分。

## 2. 先放通登录页本身

登录页在门户内网，**必须能先从 LAN 侧访问到它**，否则用户根本打不开。

```sh
# 1) 给门户地址加一条走该 WAN 的静态路由（多数情况能自动学到，因为门户在 WAN 的子网内）
uci -q delete network.portalmgw
uci set network.portalmgw=route
uci set network.portalmgw.interface='wwan2'
uci set network.portalmgw.target='172.16.210.18'
uci set network.portalmgw.netmask='255.255.255.255'
uci commit network

# 2) 让它绕过透明代理劫持（关键，见 transparent-proxy-conflicts.md）
nft insert rule inet mihomo prerouting ip daddr 172.16.210.18 counter return
```

只做第 1 步时，现象是"路由写着，但浏览器还是打不开"——因为包在 `prerouting` 就被代理劫走了。**这是最常见的误判**。

## 3. 认证

认证必须在**浏览器里**完成（需要 JS / 重定向链），不能在路由器上脚本化。让用户在连着该路由器的电脑上打开门户地址登录。

认证成功后复测：

```sh
curl -sS --interface <STA接口> -m 8 -o /dev/null -w 'https=%{http_code}\n' https://www.baidu.com
```

应返回 200。

## 4. 认证后续

| 事项 | 说明 |
|---|---|
| **会话有效期** | 多数办公网有超时（几小时到一天），过期后所有流量再次被拦，需要重新登录。无法自动化，除非门户支持 API |
| **网关地址会变** | 门户网关是 DHCP 下发的，换了网段后静态路由要跟着改。用脚本从 `ip route show default dev <if>` 动态取网关，别写死 |
| **DNS** | 有些门户会下发自己的 DNS（如 `172.16.210.19/20`），认证前只解析内网。认证后建议仍由主 WAN 的 DNS 解析，否则会被门户 DNS 污染 |
| **多设备 / 多 MAC** | 有些门户按 MAC 计费或限连接数，路由器的 MAC 被绑定后，后面所有设备共享它 |
| **802.1X / 企业级加密** | 那是 `wpa_supplicant` 层的认证，和网页门户是两回事；`iw` 侧能连上就说明过了 802.1X |

## 5. 不要把"门户认证"当成分流问题

排查顺序很重要：

1. 先确认这条 WAN **本身能上网**（认证完成，`wan_check.sh` 返回"正常"）；
2. 再确认**指定流量**能走这条 WAN 出去（路由 + 代理例外）；
3. 最后才排查代理/规则。

反过来做会浪费大量时间——链路根本不通时，任何分流配置的验证结果都是"超时"，无法区分是配置错还是没认证。

## 6. 认证前后对照表

| 测试 | 认证前 | 认证后 |
|---|---|---|
| ping 对端网关 | 通 | 通 |
| ping 8.8.8.8 | 丢包 | 通 |
| HTTP 任意站点 | 302 到门户 | 200 |
| HTTPS 任意站点 | 超时 | 200 |
| 目标端口（如 31009） | 超时 | 通 |

这张表也是判断"认证到底生效没有"的依据。