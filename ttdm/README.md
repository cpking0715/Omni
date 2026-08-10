# ttdm — TikTok 私信触达工具（Go 重构版）

基于 [docs/TIKTOK-DM-FLOW.md](../docs/TIKTOK-DM-FLOW.md) 的协议梳理与 `docs/tiktok/TIKTOK-DESIGN.md` 重构方案，实现的 TikTok 私信群发工具（CLI）。
支持**强私筛选、话术库随机话术、多通道私信发送、结果导出**全链路，无第三方中转依赖。

## 技术栈

- Go 1.26，单文件二进制，无运行时依赖
- gorilla/websocket（WSS）、手写 protobuf wire 编解码、pierrec/lz4（LZ4 压缩）
- modernc.org/sqlite（纯 Go SQLite，无需 CGO）、golang.org/x/net/proxy（socks5/http 代理）
- 模拟通道浏览器底座：AdsPower Local API + CDP（账号与 AdsPower profile 1:1 绑定）

## 架构

```
cmd/ttdm/          CLI 入口 (account / screening / template / task / message / adspower 子命令)
internal/
  store/           SQLite 数据层 (accounts / tasks / messages / screenings / chat_templates)
  tiktokapi/       TikTok Web HTTP API (强私筛选 notice / Cookie 有效性, 证书校验+代理)
  protocol/        通道实现: AndroidClient(通道一) / WebClient(通道二) / BrowserClient(模拟) / AutoClient(降级)
  adspower/        AdsPower Local API + CDP 页面操作原语 (导航/等待/输入/点击/截图)
  task/            任务引擎 (多任务并发 / 同账号互斥 / 通道选择 / 话术渲染 / 遥测)
```

## 构建与测试

```bash
go build -o ttdm.exe ./cmd/ttdm
go test ./...
```

数据目录默认 `%LOCALAPPDATA%\ttdm\ttdm.db`，可用全局参数 `--data-dir <路径>` 覆盖（置于子命令之前）。

## 通道状态表

| 通道 | 状态 | 说明 |
|---|---|---|
| 通道一 Android WSS 协议 | ❌ 不可用 | 原反编译客户端 HTTP 400，仅作协议结构参考，不投入修复 |
| 通道二 Web 发送 (HTTP 协议) | ✅ 可用 (k1flkhdn 实测) | `POST im-api.tiktok.com/v1/message/send` + webmssdk 签名快照复用；**无签名直连可用**（M6-4/k1flkhdn 实测）；204=服务端静默响应（幂等/限流去重，视为成功），200+protobuf 业务响应（如 7193 消息请求限制） |
| 通道二 Web WSS 协议 | ⚠️ 部分可用 | `wss://im-ws.tiktok.com/ws/v2`（fws_1.0.0 / pbbp2）连接/信封/typing 已实测（k1flkhdn 实测握手通过）；消息发送改用同 aid=1988 的 HTTP send_text，不单独开放 |
| 模拟通道（AdsPower 浏览器） | ✅ 可用（当前主力，k1flkhdn 实测） | CDP 自动化操作 tiktok.com/messages，选择器集中管理于 `internal/protocol/selectors.go` |
| 通道三/四（厂商中转） | ❌ 已弃用 | 单点依赖 + 硬编码代理凭证，不实现 |
| `auto`（默认） | ✅ | 有 ttwid 时优先 Web 通道，连接失败或发送不可用自动降级浏览器 |

## 用法

### 1. 导入账号

```bash
# 支持 DESIGN 2.8 的 4 种 CK 格式: 完整 JSON / Cookie JSON 数组 / Cookie 字符串行 / ---- 分隔段
# ttwid 存在时自动提取设备 ID (通道二依赖)
ttdm account import --file ck.txt
ttdm account import --file ck.txt --ads-profile abc123   # 单账号绑定 AdsPower 浏览器配置(模拟通道需要)
ttdm account list
```

### 2. 强私筛选（判定目标可收信条数 0/1/3）

```bash
ttdm screening run --account 1 --targets @uids.txt --threads 10 --proxy "socks5://u:p@host:1080" --label batch1
ttdm screening list --label batch1
ttdm screening export --label batch1 > screening.csv
```

- 并发上限可配置（默认 10，1-100）；代理轮询分配；TLS 证书校验强制启用
- 判定依据 `GET /tiktok/v1/im/chat/notice/`：chat_stranger_check=3 条 / chat_request_start=1 条 / 其他=0

### 3. 话术库（支持 {变量} 插值，重构新增特性）

```bash
ttdm template add --text "hi {用户名}, 看看 {链接}" --tag en
ttdm template add --file lines.txt        # 每行一条批量导入
ttdm template list
ttdm template delete 3
```

可用变量：`{用户名}`（接收者 uid）、`{链接}`（链接池随机）、`{日期}`、`{时间}`、`{时间全}`。

### 4. 创建私信任务

```bash
# 固定文本 (风控默认: 间隔≥30s + 随机抖动 10s, 可用 --interval/--jitter 调整)
ttdm task create --senders 1,2 --receivers @targets.txt --text "Hi" \
  --interval 30 --jitter 10 --max-sent 30 --max-fail 5 --concurrency 4

# 单账号每日发送上限 (按本地自然日统计, 0=不限制)
ttdm task create --senders 1 --receivers @targets.txt --text hi --daily-max 50

# 话术库随机话术 + 随机表情 + 当前时间 + 链接随机池
ttdm task create --senders 1 --receivers @targets.txt \
  --templates 1,2,3 --random-emoji --datetime --links "https://a.com,https://b.com"

# 通道选择 (默认 auto = Web 优先失败降级浏览器)
ttdm task create --senders 1 --receivers 123 --templates 1 --channel browser --ads-key <AdsPower API Key>

# 代理（http/https/socks5，逗号分隔多个则轮询分配）
ttdm task create --senders 1 --receivers 123 --text hi --proxy "socks5://u:p@host:1080"

# 链接卡 / 视频 / 图片 / 主页卡 (仅 Android/Web 协议通道支持)
ttdm task create --senders 1 --receivers 123 --text "check" --link-url "https://..." --link-title "T" --link-desc "D"

# 查询与导出
ttdm task list
ttdm task show 1        # 含通道、话术模板、失败原因分布
ttdm message export 1 > result.csv
```

任务引擎支持多任务并发（同账号互斥）、接收者轮询分配、每账号上限与连续失败退出；发送遥测按任务落库（成功/失败/失败原因分布）。

### 5. AdsPower 绑定

```bash
ttdm adspower list --key <API Key>     # 列出本机浏览器配置
ttdm adspower sync --key <API Key>     # 按名称匹配写入账号的 ads_profile_id
```

### 6. 本地浏览器直连（非指纹浏览器）

不依赖 AdsPower 时，可直接驱动本机 Chrome/Edge（经 CDP 调试端口）。账号绑定 `ads_profile_id` 填 `local:<端口>` 即可，**无需 `--ads-key`**（AdsPower 配置 ID 是 8 位字母数字，与 `local:` 前缀不会冲突）。

```bash
# 1) 用独立用户目录启动本地浏览器（勿用日常浏览的默认目录）
#    Chrome:  chrome --remote-debugging-port=9222 --user-data-dir="D:\\ttdm-browser"
#    Edge:    msedge --remote-debugging-port=9222 --user-data-dir="D:\\ttdm-browser"

# 2) 在浏览器中登录 TikTok 并保持浏览器运行
# 3) 导入账号时绑定 local:<端口>
ttdm account import --file ck.txt --ads-profile local:9222

# 4) 创建任务（browser / auto 通道均可，不需要 --ads-key）
ttdm task create --senders 1 --receivers @targets.txt --text hi --channel browser
```

注意事项：

- 一个本地浏览器实例同一时刻只跑一个发送账号；多账号请用多个端口 + 多个 `--user-data-dir`（如 `local:9222` / `local:9223`）
- 浏览器需保持运行（ttdm 只连接不启动）；连接/流程与 AdsPower 模式完全一致（选择器统一在 `internal/protocol/selectors.go`）
- 无指纹隔离/代理隔离，建议用于测试与小规模发送；正式批量仍建议 AdsPower（`adspower sync` 绑定）

## 错误码与退出策略

- `7174 / 7178 / 7192`：陌生 3 条上限已到，**视为成功**（消息已送达）
- `7180`：整账号退出（当前账号停止发送）
- `7193`：对方尚未接受消息请求，仅能发送有限条数 → 终止该目标（M6-4 实测）
- `200001`：Cookie 失效（筛选时计入失败原因）
- Web 发送 204：服务端静默响应（幂等/限流去重，浏览器抓包同样出现），视为成功
- 模拟通道：too fast 警告 → 账号退出；"最多发送 3 条"提示 → 视为成功

## 协议实现要点

- **通道一**（骨架）：`wss://{frontier.tiktokv.*}/ws/v2` pbbp，Type 609 建会话 → 411 预发 → 100 发送；非文本 LZ4 压缩信封
- **通道二**：fws_1.0.0 信封 f1:sn / f2:ts / f3:service=33554513 / f4:method=2 / f7:"2" / f8:body{设备块,消息块}；access_key 素材 = ttwid 内 19 位设备 ID；typing 帧 = 文本 "hi"
- **通道二 Web 发送 (M6-3/4 抓包逆向)**：`POST https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc&X-Dynosaur=<签名>&msToken=<token>&X-Bogus=1&X-Gnarly=<签名>`；参数顺序固定、签名值不转义（`+/=` 原样保留——`url.Values.Encode()` 的字母序排序+转义会导致签名校验失败静默 204）；body protobuf：f1=100/f2=10033/f3="1.7.0"/f8.f100{conv_id "0:1:{to}:{self}", f4 JSON text, s:client_message_id}/f15 设备上下文 KV/f18=1；签名由浏览器 webmssdk.js 2.0.0.514 生成、快照可复用（`internal/protocol/websend.go`），响应 200 信封 f3=0/f4="OK"/f6.f100.f6 JSON{status_code}
- **模拟通道**：导航 `https://www.tiktok.com/messages?lang=en&u={uid}` → 等待 `div[data-e2e=message-input-area] div.DraftEditor-root` → 校验 `p[data-e2e=chat-uniqueid]` → 输入 → 点击 `[data-e2e=message-send]` → DOM 探测结果；DOM 选择器失效只需改 `selectors.go` 一处

## 与原客户端的差异

| 项 | 原 Juytu | ttdm |
|---|---|---|
| 通道一（Android 协议） | 主力通道 | 保留骨架，服务端已拒绝（HTTP 400），不修复 |
| 通道二（Web） | 支持 | 连接层已打通；发送改用 HTTP send_text + 签名快照（M6 已打通） |
| 浏览器模拟通道 | WebView2 自动化 | AdsPower + CDP（账号-环境 1:1） |
| 通道三/四（厂商中转） | 依赖中转服务器 | **不做** |
| 强私筛选 | 硬编码并发、无代理、禁证书校验 | 并发可配置、代理轮询、强制证书校验 |
| 话术变量 | 无插值 | `{用户名}/{链接}/{日期}/{时间}` 插值 + 随机表情/链接池 |
| 试用限制/云端功能 | 厂商授权 + 云端 AI | 全部移除，纯本地 CLI |

## 已知限制 / 后续路线

1. Web 通道发送依赖签名快照（`webmssdk.js` 生成，`bin/m6/sign_snapshot.json` 实测可复用；过期后需从已登录浏览器重新抓取）；消息请求限制（7193）时目标无法继续发送
2. Web 发送仅文本消息；卡片类消息仅协议通道支持（当前协议通道未打通）
3. 后续：AI 生成话术（直连 DeepSeek，用户自带 Key）、数据采集（粉丝/评论/用户搜索）
