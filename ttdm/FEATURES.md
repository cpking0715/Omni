# ttdm 已实现功能清单

> TikTok 私信触达工具 (Go 重构版) — 截至 2026-08-10 完成状态
> 协议逆向依据: docs/TIKTOK-DM-FLOW.md | 设计: docs/tiktok/TIKTOK-DESIGN.md

## 〇、端到端实测 (2026-08-10, AdsPower k1flkhdn)

浏览器配置: **k1flkhdn** (tiktok-2, 非 k1fan6kh) · uid=7664958044560016398 · device_id=7672...1997 · store_idc=useast5

| 通道 | 实测结果 | 闭环证据 |
|---|---|---|
| 通道二 Web HTTP (无签名直连) | ✅ 发送成功 561ms, 无业务拒绝 | 浏览器会话可见 `e2e-web-http-test-01` |
| 模拟通道 BrowserClient (CDP) | ✅ 任务成功 1/1 | 页面可见 `e2e-browser-test-02` |
| auto (Web 优先) | ✅ 任务成功 1/1 | 页面可见 `e2e-auto-test-03` |
| 通道二 Web WSS (im-ws) | ✅ pbbp2 握手通过, 保持 5s | access_key 有效, typing 帧发送 |

测试全程间隔 ≥30s (interval=30 + jitter 随机), 共 3 条自会话消息, 未触发限频。

## 一、通道能力

| 通道 | 状态 | 说明 |
|---|---|---|
| 通道二: Web HTTP (im-api message/send) | ✅ 已跑通 | `POST im-api.tiktok.com/v1/message/send`, **无签名直连可用** (M6-4 + 2026-08-10 k1flkhdn 实测) |
| 通道二: Web WSS (im-ws.tiktok.com) | ✅ 已接通 | fws_1.0.0 / pbbp2, 连接/帧编解码/typing 已实测; 消息发送复用 HTTP send_text |
| 模拟通道: BrowserClient (AdsPower + CDP) | ✅ 已跑通 | 2026-08-10 k1flkhdn 实测: 输入+发送+消息可达; 真实鼠标/键盘事件 |
| 通道一: Android WSS 协议 | ⚠️ 骨架 | 协议结构已还原, 服务端已拒绝 (HTTP 400), 不投入修复 |

## 二、已实现功能

### 协议层 (internal/protocol)
- [x] WebClient: Connect / CreateConversation / SendText (HTTP 层)
- [x] 无签名直连: 签名快照从"必需"降级为"可选" (BuildWebSendURL 空签名路径)
- [x] 业务码映射: 0成功 / 7193消息请求限制 / 7195内容审核 / 7180过快 / 7175 / 7278 / 7282 / 7283 / 7289 / 7290 / 7409
- [x] protobuf wire 编解码 (encoder/parser) + LZ4 压缩 (K4os 等价)
- [x] Web 响应解析: 204 静默成功 / 200 protobuf 业务响应 (兼容 Android/Web 信封)
- [x] BrowserClient: 导航/等待/点击/输入/结果探测 (SVG 按钮真实鼠标点击)
- [x] DOM 选择器集中管理 (selectors.go)

### API 层 (internal/tiktokapi)
- [x] CheckImPermission 强私筛选: chat_stranger_check→3条 / chat_request_start→1条 / 其他→0
- [x] CheckCookie 登录态校验 (profile UID 提取, 多布局兼容)
- [x] TLS 校验始终开启 + socks5/http 出站代理

### 模拟通道 (internal/adspower)
- [x] AdsPower Local API: 启动/获取 debug_port
- [x] CDP 客户端: 导航/截图/鼠标/键盘/选择器
- [x] 账号与 AdsPower profile 1:1 绑定

### 任务引擎 (internal/task)
- [x] 多账号并发发送 (MaxDegreeOfParallelism)
- [x] 同账号轮询 (MaxSentCount 上限)
- [x] 通道选择策略 (优先 Web HTTP, 降级模拟)
- [x] 话术模板渲染 (变量插值)
- [x] 失败阈值 / 间隔控制 / 进度回调

### 存储层 (internal/store)
- [x] SQLite: accounts / tasks / messages / screenings / chat_templates
- [x] 账号导入 (4 种 CK 格式: JSON对象/数组/cookie行/分段)
- [x] Cookie 导出 (cookiexport, AdsPower CDP)

### CLI (cmd/ttdm)
- [x] account: import / list / check
- [x] screening: 强私筛选任务
- [x] template: 话术模板管理
- [x] task: 发送任务 (含 7193/7195 业务码回显)
- [x] message: 消息记录查询
- [x] adspower: 浏览器管理
- [x] server: 内置 Web 控制台 (一键启动 start.ps1, 浏览器环境切换 ads/local, 任务创建与监控)

### 辅助工具 (cmd/)
- [x] websend: 单条消息验证 CLI (`-snap <json|->` 支持无签名直连)
- [x] cookiexport: AdsPower 浏览器 cookie 导出
- [x] mkbody: protobuf body 构造 (支持 -to 自定义接收方)
- [x] decodeframe: WSS 帧解码
- [x] wedsnap / probeak / quickcheck / browser_probe: 调试工具

## 三、核心结论 (M6 逆向实测)

1. **签名非必需**: X-Bogus/X-Gnarly/X-Dynosaur 对 message/send 零影响 (A~J 十变体逐字节对照)
2. **7193 = message_request_limit**: 对方接受请求前只能发 1 条 (对应 CheckImPermission 预筛)
3. **7195 = 内容审核**: 话术合规性规避
4. **cookie 是唯一通行证**: 有效 cookie + protobuf body 即可直连发送

## 四、验证状态

- [x] `go build ./...` 通过
- [x] `go vet ./...` 通过
- [x] `go test ./...` 全量通过
- [x] CLI 真实环境: 无签名/带签名双路径一致 (7193)
- [x] UI 模拟: 输入+按钮链路实测 (受限会话前端静默拦截, 属业务层限制)

## 五、待办 (后续迭代)

- [ ] status=0 正面成功案例验证 (需可接收消息的真实接收方)
- [ ] 通道一 Android WSS 真机验证
- [ ] 7195 话术合规词表/规避策略
- [ ] 消息请求 (message request) 自动接受/跟进流程
- [ ] AI 话术变量插值接入
