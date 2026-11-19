# 远程排障手册：AI 不在用户局域网时怎么办

## 为什么"直接访问路由器"行不通

AI 的代码执行沙箱和用户的 Mac 一般处在两个不同网络：

- **跑在云端**：`192.168.5.1`、`10.x`、`172.16-31.x` 在沙箱里没有路由，物理上到不了；
- **跑在用户本机但用了网络策略**：`WebFetch` 这类抓取工具会命中安全策略，报

  ```
  WebFetch blocked by security center network policy —
  host "192.168.5.1" resolves to a private/internal address
  ```

- **`curl` 能连通但全是 403**：连上的其实是本地网关/出口代理，或者 LuCI 直接返回登录页：

  ```
  HTTP/1.1 403 Forbidden
  Server: nginx/1.26.3
  x-luci-login-required: yes
  <title>OpenWrt - LuCI</title>
  ```

结论：**远程 AI 拿不到路由器上的信息，只能"指导 + 回流"**。同时遵守三条红线：

1. 不要让用户在对话里粘贴路由器 root 密码（对话可能被记录/转发）；
2. 不要尝试绕过 LuCI 登录认证、不要暴力猜测凭据；
3. 不要把"申请权限"说成可行路径——如果确实需要放宽安全策略，明确告知这是用户自己设置里的开关，由用户决定，而不是 AI 的技术方案。

## 用户侧操作模板（可直接转述）

### 路线 A：SSH（首选，信息最全）

```bash
ssh root@192.168.5.1
```

- 密码 = LuCI 后台密码（不是 WiFi 密码）；
- 连不上先查 LuCI → 系统 → 管理权 → SSH 是否启用；
- 连上后执行本 skill 的 `scripts/diag-egress.sh`，把整段输出贴回来。

如果用户不方便上传脚本，把脚本内容整段粘贴进 ssh 会话也能跑（脚本只用了 POSIX sh + busybox 命令）。

### 路线 B：LuCI 网页（不想用命令行的用户）

只需三个答案就能推进一半：

1. LuCI 左侧「服务」菜单里装了哪个代理插件（OpenClash / PassWall / SSR Plus+ / Hello World / Nikki / 无插件只有自定义守护）；
2. 插件的「运行状态」页显示的当前节点名；
3. 「规则配置」或「策略组」页里有没有 `🤖 AI`、`🔍 Google` 这类分组，各自选中的节点是什么。

## 命令回流时最容易翻车的五个点

| 现象 | 原因 | 正确做法 |
|---|---|---|
| `find: unpaired '('` | 用户从聊天窗口复制时，反斜杠转义的括号 `\(` 被"智能"处理吃掉 | 命令里不要写 `\( ... \)`，改用 `awk` / `grep -E` / 单文件多次执行 |
| `grep` 结果缺行 | 用户在粘贴时把命令拼错（例如输出开头出现 ` | head -80`，说明上一段被截断） | 提示用户"整段复制、不要把行首的管道符带进来"，并让脚本输出带分隔符，便于判断是否完整 |
| 输出含 emoji 组名对不上 | YAML 里 emoji 写成 `"\U0001F916 AI"`，终端/剪贴板显示成真 emoji | 用 `-name:` 列表拿行号，再用 `sed -n 'A,Bp'` 取原文 |
| `state.json` 里 grep 不到节点 | 运行时状态不在 state.json（可能是二进制/被加密） | 改用 mihomo 控制 API `/proxies` |
| 改完重启又变回去 | 改的是 `/dev/shm`、`/tmp` 下的运行时生成文件 | 改来源配置（面板 / 订阅覆写），或直接用 API 切换并接受它会被面板记住 |

## 一次典型的成功回流（真实案例，已脱敏）

1. 用户贴出 sorry 页：`216.236.32.1 ≠ 216.232.68.147`；
2. AI 让用户 ssh 进来跑诊断脚本，拿到：系统是 Kwrt 25.12.2（OpenWrt 衍生），**真正在跑的是 `mesl-cli` 拉起的 mihomo**，配置 `/dev/shm/mesl-0/runtime.yaml`，装了 passwall2 / xray / sing-box 但都没跑；
3. 规则侧拿到两类命中：
   - `gemini.google.com`、`generativelanguage.googleapis.com`、`aistudio.google.com` … → `🤖 AI` 组（YAML 写作 `"\U0001F916 AI"`）；
   - `google.com`、`googleapis.com` … → `🔍 Google` 组（`"\U0001F50D Google"`）；
4. 两组 `proxies` 列表完全一致（MESL / Fallback / Auto / 香港 01-07），但 `select` 组各自记住选择 ⇒ 出口不同 ⇒ 双 IP；
5. 修复：把两组固定到同一具体节点（方案 B），并从订阅侧把 Gemini 域名并入 Google 组（方案 A）做长期收敛。

## 提示词的写法

给用户的指令要满足：**一整段可直接粘贴**、**每段输出有 `===== 标题 =====` 分隔**、**不依赖交互输入**、**不输出任何密钥**（用 `$(cat ...)` 引用而不是 `echo`）。

反例（会翻车）：

```sh
grep -niE 'google|gemini' $(find /etc \( -name '*.yaml' \) )
```

正例：

```sh
echo "===== [1] 内核 ====="
ps | grep -Ei 'mihomo|clash|mesl|xray|sing-box' | grep -v grep

echo "===== [2] 配置 ====="
ls -la /etc/mesl 2>/dev/null
```