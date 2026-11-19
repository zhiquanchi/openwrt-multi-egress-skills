# 脚本开发记录：这些脚本为什么长成现在这样

> 本仓库的脚本不是一次写成的。每一处"奇怪的写法"背后都有一次真实失败。
> 这份记录说明：**遇到过什么 bug、怎么发现的、怎么修的、哪些还没修**。
>
> 验证方式说明：所有回归都在 macOS 本机 + 模拟的 mihomo API / 假 `nft` / 假 `ip` 上完成，
> **没有在真实 OpenWrt 设备上跑过**。这既是限制，也是下面很多 bug 的来源。

---

## 一、`openwrt-proxy-dual-egress` 的脚本

### 1.1 `egress_api_probe.py`：一次就基本成型

用 `http.server` 搭了个假 mihomo API，覆盖 6 个场景：

| 场景 | 期望 | 结果 |
|---|---|---|
| 两组指向不同节点 | 判定双出口 | ✅ |
| `--switch` 用 emoji 组名对齐 | 成功后复判一致 | ✅ |
| `--json` | 机器可读 | ✅ |
| API 连不上 | 退出码 1 | ✅ |
| 组名不存在 | 退出码 2 | ✅ |
| 目标组没有 `now` | 报错退出 | ✅ |

第一次跑就全过。**唯一值得记的点**：`PUT /proxies/{name}` 的 body 是**带引号的 JSON 字符串**（`"节点名"`），
不是 `{"name": "节点名"}`。组名要做 URL 编码（emoji 必须先编码）。

### 1.2 `diag-egress.sh`：改了四轮

这是本仓库**改动最多**的脚本。

#### 第一轮：`fi` 重复

改代码时替换块的结尾已经包含 `fi`，外面的 `fi` 没删，直接语法错误：

```
diag-egress.sh: line 132: syntax error near unexpected token `fi'
```

**教训**：用脚本批量改 shell 文件后，必须 `sh -n` + `bash -n` 双检。

#### 第二轮：没有密钥文件时整段跳过

原逻辑是"有密钥才请求 API"，结果遇到 OpenClash 这种**不设密钥**的控制 API 时，
整段输出为空，什么也看不到。改成**无论有没有密钥都请求**，只在有密钥时带 header：

```sh
curl -s -m 8 ${SECRETFILE:+-H "Authorization: Bearer $(cat "$SECRETFILE")"} ...
```

#### 第三轮：sed 在 macOS 上静默不匹配（最隐蔽）

用 JSON 解析策略组时，最初的写法：

```sh
... | grep -E '"type":"(Selector|...)"' | sed -e 's/.*"name":"\([^"]*\)".*"now":"\([^"]*\)".*/\1 -> \2/'
```

API 返回 200，`grep` 单独也能命中，但整条流水线**输出为空**。逐段调试：

```sh
curl ... > /tmp/proxies.json
tr '{' '\n' < /tmp/proxies.json | sed -e 's/.*"name": *"\([^"]*\)".*"now": *"\([^"]*\)".*/\1 -> \2/'
```

```
"proxies":
"MESL":
"type": "Selector", "all": ["Auto"], "now": "Auto"}, "Auto":
```

**sed 什么都没做，也没报错。** 原因：macOS 的 BSD sed 在处理含多字节字符（emoji）的行时，
`.*` 的匹配行为与 GNU sed 不同，导致整个表达式匹配失败，且**静默返回原文**。

中间还试过一版"先用 `grep -E '"type":...'` 过滤再 sed"，也是空的——
因为真实 API 的 JSON 是紧凑格式（`"type":"Selector"`），而测试用的假 API 输出带空格（`"type": "Selector"`），
两种格式都要兼容。

**最终方案**：不跟 sed 死磕。**把结构化解析整体交给 python**，
纯 shell 只作为"没有 python3 时的粗略兜底"：

```sh
if have python3; then
  python3 "$SCRIPT_DIR/egress_api_probe.py" --url "$CTRL" ...
else
  tr '{' '\n' < "$API_TMP" | grep -E '"now"' | head -40    # 只求能看到，不求精确
fi
```

这个决定是对的：**JSON 该用 JSON 解析器处理，不要用 sed 硬啃**。

#### 第四轮：`[[:space:]]` 改为字面空格

即使在 python 兜底之下，仍保留了纯 shell 路径。把 `[[:space:]]*` 全面替换为 ` *`，
因为前者在 BSD/busybox 的 sed 上表现不一致。

### 1.3 `egress_verify.sh`：一个逻辑错误，两次修正

#### 最初版本：把 IPv4 和 IPv6 当成两个出口

第一版同时用 `cdn-cgi/trace`（可能走 IPv6）和 `api.ipify.org`（可能走 IPv4）取出口 IP，
然后"去重"判断是否唯一。实测输出：

```
 cloudflare trace : 2404:c140:... 2404:c140:...
 api.ipify.org    : 216.236.32.1 216.236.32.1

 去重后的出口 IP  : 216.236.32.1 2404:c140:...

==== 结论 ====
出口 IP 不一致（同时出现多个）
说明同一台机器在不同时刻/不同连接上走了不同出口，属持续双出口状态。
```

**这是一次彻头彻尾的误报**——IPv4 和 IPv6 本来就是两个不同的地址，
网络完全正常却报告"双出口"。更讽刺的是，这和本 skill 要修的 Gemini 问题
是**同一类误判的镜像**：那边是把"一个会话两个 IP"误判成正常，这边是把"两个正常 IP"误判成故障。

#### 第二次修正：按协议分开统计

改成 IPv4 / IPv6 分两栏各自去重、各自判断唯一性：

```
 IPv4 去重后     : 216.236.32.1   [协议内唯一=1]
 IPv6 去重后     : 2404:c140:...  [协议内唯一=1]
 注意：IPv4 与 IPv6 是两个不同的出口地址，不能互相比较
```

#### 第三次修正：`-4`/`-6` 也信不过

发现 `curl -6` 在走代理时**静默回退返回 IPv4**，于是干脆不信标志，改为
**拿到所有结果后按地址形态分类**（含 `:` 即 IPv6）：

```sh
is_v6() { case "$1" in *:*) return 0;; *) return 1;; esac; }
```

这一版才真正稳定。

### 1.4 一个没改掉的中间过程（记录备查）

`egress_verify.sh` 曾经有一版试图"用 `--resolve` 把 `verify.egress.test` 指向目标域名的 IP"，
以此来测"每个 Google 域名各自从哪个出口出去"。这个方法**不成立**：
CDN 的 IP 不是出口 IP，用 `--resolve` 只是改变了 TCP 对端，
并不改变出口路径。已删除，改为"多次采样出口 IP 是否稳定 + 列域名解析结果供人工判断"。

---

## 二、`openwrt-multi-wan-routing` 的脚本

### 2.1 `binding_guard.sh`：幂等性反复调了三轮

#### 第 0 轮：假 stub 自己写错了，导致结论不可信

第一版桩里写：

```sh
"insert rule")
  shift 4; echo "		ip daddr { $* } # handle 10" >> $S/rules ;;
```

没意识到参数是 `nft insert rule inet <tbl> prerouting <daddr...> counter return`——
**`shift 4` 之后 `$*` 还包含 `prerouting` 和真实参数**，输出变成：

```
ip daddr { prerouting ip daddr { 192.168.128.0/19, ... } counter return } # handle 10
```

看起来像"脚本生成的 daddr 语法坏了"，实际是**测试桩的 bug**。
这类问题最危险：会让你去改一个本来正确的实现。

#### 第 1 轮：假 `ip` 桩的参数位错

```sh
"rule add") echo "$5 to $3 lookup main" >> ...   # 错
```

真实调用是 `ip rule add to <t> lookup main pref 8800`，
于是 `$5` 是 `lookup`、`$3` 是 `to`，记录变成 `lookup to to lookup main`。

同时 `ip -4 -br addr show <if>` 的 `$2` 是 **`-br`** 而不是 `-4`，
用 `case "$1 $2"` 分派会全部落空。

**教训**：写桩之前先用 `echo "$@"` 把真实参数打出来确认。

#### 第 2 轮：路由那条不幂等

假 `ip` 没有真正保存路由状态，`ip route show <t>/32` 永远返回空，
于是每一轮都执行 `ip route replace`。这不一定是脚本 bug（真机上会返回已有路由），
但为了验证幂等，桩必须真的"记住"状态：

```sh
"route show") grep -F "$3" /tmp/fakestate/iproute 2>/dev/null; exit 0 ;;
```

修好后最终验证：

```
### 第1次 ###
[binding_guard] 已插入 nft 例外: ip daddr { 192.168.128.0/19, 172.16.0.0/12, 120.255.1.167 }
[binding_guard] 路由 120.255.1.167/32 via 192.168.159.254 dev phy0-sta0
[binding_guard] ip rule: to 192.168.128.0/19 lookup main pref 8800
...
### 第2次（应完全静默）###
(无输出)
### 第3次 ###
(无输出)
--- 最终状态 ---
nft: 1 条
route: 1 条
iprule: 3 条
```

**这才是幂等的证据**：连跑不产生新条目、不产生输出。

#### 第 3 轮：自愈验证

```sh
rm -f /tmp/fakestate/rules /tmp/fakestate/iprule /tmp/fakestate/iproute   # 模拟代理重建表
sh binding_guard.sh
```

```
[binding_guard] 已插入 nft 例外: ...
[binding_guard] 路由 ...
[binding_guard] ip rule: ... (3 条)
恢复后: nft=1 route=1 iprule=3
```

也验证了单目标模式不走集合语法：

```
ip daddr 120.255.1.167 counter return # handle 10
```

### 2.2 `topo_probe.sh`：两个死代码

#### 死循环残留

```sh
for t in $(have nft && nft list tables 2>/dev/null | awk '{print $3, $2}'); do :; done
```

这是编辑过程中留下的空操作，什么都没做。已删除。

#### awk 用了 Perl 语法

```sh
| grep -E 'table (?!main)'      # awk 没有负向环视
```

改为 `awk '/table/ && $NF != "main" && !/ table main/ {print}'`。

**注意**：这一行本来是 `grep -E`，但 `grep -E` 同样不支持 `(?!)`，所以必须换成 awk 条件表达式。

### 2.3 `wan_check.sh`：一个会把人带偏的误判

#### 最初的 bug：`en0` 被报成"接口不存在"

在本机 macOS 上测真实存在的 `en0`，输出：

```
--- en0 ---
  状态: DOWN（接口不存在）
```

排查发现 **macOS 根本没有 `ip` 命令**：

```
bash: ip: command not found        # exit 127
```

原代码的判断是：

```sh
if ! ip link show "$iface" >/dev/null 2>&1; then
  echo "  状态: DOWN（接口不存在）"
```

`ip` 不存在 → 退出码 127 → `! 127` 为真 → 判定"接口不存在"。
**把"工具缺失"误判成"接口不存在"**，这在真实排障里会让人去查硬件。

修正：优先用 `/sys/class/net/<if>` 判断（Linux 上永远可靠），没有 `/sys` 才退回 `ip link`：

```sh
if [ ! -d "/sys/class/net/$iface" ]; then
  if ! ip link show "$iface" >/dev/null 2>&1; then
    echo "  状态: DOWN（接口不存在）"
    return
  fi
fi
```

并在入口显式检查 `ip` 是否存在，缺失时给出明确提示而不是继续跑。

#### 第二个 bug：地址取错列

假 `ip` 桩输出 `3: phy1-sta0    UP   192.0.2.10/24` 时，`awk '{print $3}'` 取到的是 `UP`。
一度以为脚本 bug，实际是**桩的格式不对**——真实 `ip -br addr` 输出是：

```
phy1-sta0    UP   192.0.2.10/24
```

三列分别是 IFNAME / STATE / ADDR，`$3` 确实是地址。**修的是桩，不是脚本**。

这个例子说明：**看到异常先怀疑测试环境，再怀疑被测代码**，但最终必须用真实格式验证。

---

## 三、跨脚本的共性经验

1. **JSON 不要用 sed/awk 解析**，交给 python 或 jq；sed 在 BSD 上对多字节字符会静默失败。
2. **幂等的证据是"连跑无输出、无新增"**，不是"看起来没报错"。
3. **测试桩必须真实保存状态**，否则测不出幂等。
4. **`sh -n` + `bash -n` 双检**，批量改 shell 后必做。
5. **路径类判断不要依赖工具退出码**（`ip`/`ls`/`grep` 在"工具缺失"和"目标不存在"时可能同码）。
6. **给用户的脚本要能贴进聊天窗口**：避免 `\( \)`、避免多行续行符、每段输出带 `===== 分隔符 =====`。
7. **先确认工具存在再判断结果**，`command -v` 是最便宜的保护。

## 四、明确未验证的部分

- 所有脚本**未在真实 OpenWrt / busybox ash 上执行**；
- `binding-guard.init` 未在真实 procd 上加载过（只做了 `sh -n` 语法检查）；
- 真机上 `nft list tables` 的输出格式、`ip rule show` 的字段对齐若有差异，可能需要微调解析；
- **建议首次使用顺序**：先跑只读的 `topo_probe.sh` 确认输出正常 → 再跑 `wan_check.sh` →
  最后才装 `binding_guard.sh`。

如果实际使用中发现某段解析对不上，优先检查**该命令在当前设备上的原始输出**，
而不是直接改逻辑。