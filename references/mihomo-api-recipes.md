# mihomo / Clash.Meta 控制 API 速查

mihomo 的 `external-controller` 提供一个 HTTP API，是**判断"某个策略组此刻走哪个节点"最可靠的方式**——比翻 `state.json`、比看 YAML 都准。

## 拿到地址与密钥

```sh
# 常见保管位置（mesl 系列）
cat /etc/mesl/controller_secret
grep -m1 -i 'external-controller:' /dev/shm/mesl-0/runtime.yaml

# OpenClash
grep -A3 'external-controller' /etc/openclash/config.yaml
# 默认在 127.0.0.1:9090，密钥可能是空
```

把下面三个变量设好，后续命令都能直接用：

```sh
SECRET=$(cat /etc/mesl/controller_secret)
CTRL=$(grep -m1 -i 'external-controller:' /dev/shm/mesl-0/runtime.yaml | grep -oE '[0-9.]+:[0-9]+')
H="Authorization: Bearer $SECRET"
```

> `external-controller` 有时写成 `0.0.0.0:9090`，从路由器本机访问改用 `127.0.0.1:9090`。

## 核心接口

| 用途 | 方法与路径 |
|---|---|
| 全局状态（含版本、规则数） | `GET /` |
| 全部代理与策略组，含 `now` 当前节点 | `GET /proxies` |
| 单个组的详情（含所有可选节点） | `GET /proxies/{组名}` |
| 切换策略组选定节点 | `PUT /proxies/{组名}`，body 为 `"节点名"`（带引号的 JSON 字符串） |
| 连通性测试 | `GET /proxies/{组名}/delay?url=https://www.gstatic.com/generate_204&timeout=3000` |
| 当前连接（谁走了哪条规则） | `GET /connections` |
| 关闭所有连接 | `DELETE /connections` |
| 重载/替换配置 | `PUT /configs?force=true`，body `{"path": "..."}` |
| 刷新 geo 数据 | `POST /configs/geo` |
| 实时日志 | `GET /logs?level=info`（流式） |
| 规则列表 | `GET /rules` |

## 最常用三条

### 1. 看所有策略组 → 当前节点

```sh
curl -s -H "$H" "http://$CTRL/proxies" \
  | python3 -c 'import json,sys;d=json.load(sys.stdin)["proxies"];print("\n".join(f"{v[\"type\"]:>10}  {k}  ->  {v.get(\"now\",\"\")}" for k,v in d.items() if v["type"] in ("Selector","Fallback","URLTest","LoadBalance")))'
```

（路由器上没有 python 时，用 `tr ',' '\n' | grep -E '"now"|"name"'` 粗看，见下条。）

### 2. 进程内无 python 的粗看版本

```sh
curl -s -H "$H" "http://$CTRL/proxies" \
  | tr '{' '\n' | grep -E '"name":"(.*AI|.*Google).*"|"now":"' | head -40
```

### 3. 把 `🤖 AI` 组切到与 `🔍 Google` 相同的节点

```sh
# 精确取出 Google 组当前节点（含 emoji，不要手工复制）
NODE=$(curl -s -H "$H" "http://$CTRL/proxies" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["proxies"]["🔍 Google"]["now"])')

# 组名要做 URL 编码
ENC=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' '🤖 AI')

curl -s -X PUT -H "$H" \
  "http://$CTRL/proxies/$ENC" \
  -d "\"$NODE\""
```

纯 shell 编码：`printf '%s' '🤖 AI' | od -An -tx1 | tr -d ' \n' | sed 's/../%&/g'`。

> 注意 `PUT /proxies/{name}` 的 body 是 JSON 字符串（带引号），不是 `{"name": ...}`。切错了组，用同样的接口再切回来即可，**不会改配置文件**。

### 4. 看某个域名到底命中哪条规则

```sh
curl -s -H "$H" "http://$CTRL/connections" \
  | tr '{' '\n' | grep -E 'gemini|google|gstatic' | head -20
```

`/connections` 里每条连接带 `chains`（命中链路：节点 ← 策略组）与 `rule` + `rulePayload`，是验证"改完规则是否归组"的直接证据。

## 持久化注意事项

- API 切换**只影响运行态**，但 mihomo 通常会把 `select` 组的选择写进 cache（mesl 系列在 `/etc/mesl/cache.db`），重启后一般能保留；
- 刷新订阅 / 换配置后，若组名不变通常仍保留选择；若订阅模板改了组名，选择会丢；
- **真正要长期生效**，要么在面板里点选（面板会写进它自己的状态），要么改订阅侧的规则/组定义。

## OpenClash 的差异

- 配置文件在 `/etc/openclash/config/*.yaml`，下发到 `/etc/openclash/*.yaml` 再生成运行配置 `/etc/openclash/core/...`；
- 优先用 LuCI 界面改，脚本改文件后要么在界面点"应用配置"，要么 `/etc/init.d/openclash restart`；
- 运行日志：`/tmp/openclash.log`，界面里也有实时日志页。

## 安全提醒

- 控制 API 不要监听 `0.0.0.0` 且暴露到 LAN/公网；密钥只在路由器本地 `cat` 引用，不要 `echo` 到日志或贴进对话；
- 本文档所有命令都在路由器本机执行，不涉及把密钥传出局域网。