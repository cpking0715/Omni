# TikTok 模块开发设计文档

> 版本：1.0 | 日期：2026-08-05
> 来源：Juytu OmniMarket v5.8.21 反编译代码 + Go 重构（ttdm/）实测经验
> 对应 PRD：docs/tiktok/TIKTOK-PRD.md

---

## 1. 总体架构

### 1.1 技术栈（原系统）

| 层 | 技术 | 说明 |
|---|---|---|
| 壳层 | Avalonia 11.3 + WebView2 | 原生窗口 + 内嵌浏览器 |
| UI | Blazor Hybrid + MudBlazor 8 | Razor 组件渲染 |
| 业务 | Juytu.OmniMarket.TikTok | 平台模块（362 文件） |
| 自动化 | Lantern.AsService BrowserSimulator | CDP 驱动的浏览器模拟（Puppeteer 风格） |
| 存储 | EF Core 9 + SQLite (e_sqlite3) | 每平台一个 .sqlite |
| 网络 | HttpClient + ClientWebSocket + SignalR | REST + WSS + 实时 |
| 辅助 | AngleSharp/Jint/protobuf-net/LZ4/NPOI/SkiaSharp | DOM 解析/JS 引擎/序列化/Excel/图像 |

### 1.2 分层架构

```
┌────────────────────────────────────────────┐
│ UI 层: Components/* (Matrix/Im/Im3/Im4/    │
│        Touch/Screening/Data/Live/Dialogs)  │
├────────────────────────────────────────────┤
│ 动作层: Actions/* (46) ActionDispatcher    │
├────────────────────────────────────────────┤
│ 任务层: Automation.Tasks/* (29)            │
│         TikTokAutomaTask / BrowserTask     │
├────────────────────────────────────────────┤
│ 服务层: Services/* (28)                    │
│         ImProtocol/ImApi/ImProxy/Touch/    │
│         ShorterLink/ApiService             │
├────────────────────────────────────────────┤
│ 协议层: Services.Im.Internal/Contracts     │
│         ImAndroidApiClient/ImWebApiClient  │
│         AppIm*/WebIm* protobuf DTO         │
├────────────────────────────────────────────┤
│ 基础设施: TikTokDbContext (SQLite)         │
│           AutomaTaskManager (任务调度)      │
│           BrowserSimulatorPool (浏览器池)   │
└────────────────────────────────────────────┘
```

### 1.3 核心模式

1. **平台适配器模式**：`IPlatformAdapter` 抽象（Login/SendMessage/CollectUsers/Follow/Like/Publish/RefreshCookie/CheckStatus），各平台实现
2. **任务-采集-筛选-触达漏斗**：数据流单向，每阶段产出供下阶段消费
3. **账号-代理-环境 1:1:1 绑定**：每账号 = 独立虚拟设备
4. **多通道降级**：协议通道失效 → 自动切换备用通道

---

## 2. 账号管理模块设计

### 2.1 模块职责

账号全生命周期管理：导入（4 种方式）、登录（4 种方式）、注册（2 种）、状态维护、资料编辑、人机验证、2FA、验证码接收、导入导出（3 种格式）。是矩阵营销的底座。

### 2.2 账号实体与状态机

**账号类型**（TikTokAccountType）：Anonymous=-1 / Unknown=0 / Phone=1 / Email=2 / GoogleAccount=3

**核心字段**：TikTokId(uid)、DeviceId、StoreIdc、Sid、QueryParameters、XToken、UserAgent、SecurityKey(2FA)、Cookie、UseCookie(CK号标记)、EmailPassword、RecoveryEmail、Birthday、PhoneSmsUrl、PhoneCountry、IsRegistered

**状态机**（AutomaAccountStatus）：
```
NotRegistered(-1) → NotLoggedIn(0) → LoggedIn(1) → Suspended(2)
  导入CK → LoggedIn(直接)
  登录/注册成功 → LoggedIn + IsRegistered=true + UseCookie=false
  登录态检测未登录 → LoggedIn/Suspended → NotLoggedIn
  页面含 "suspended"/"停用" → 抛"账号已停用"（未显式写 Suspended）
```

**协议可用性判定**（HasFullCookieParameters）：`TikTokId>0 && DeviceId!=null && Cookie!=null && StoreIdc!=null` → 可协议私信。

**Cookie 提取规则**（SetCookies，核心）：
```
Sid      ← cookie "sessionid" 或 "sid_tt"
StoreIdc ← cookie "store-idc"
TikTokId ← cookie "multi_sids": URL解码 → 第一个 ":" 前的数字
```

### 2.3 登录态检测（IsLoggedInAsync）

1. 非首页 URL → 导航首页（60s 超时）
2. 等待二选一：`#loginContainer,#header-login-button`(未登录) / `div#header-more-menu-icon`(已登录)，60s；未登录再复检 40s
3. 收尾：关广告弹窗（`.webapp-pa-prompt_container__ga_button`）+ 接受 Cookie 横幅（shadow DOM `tiktok-_cookie-banner`）

### 2.4 登录流程（TikTokLogin）

**邮箱/用户名+密码**：
1. 打开 `/login/phone-or-email/email` → 输用户名（300ms 间隔模拟真人）→ 随机 500-2000ms → 输密码 → 提交
2. 提交后轮询判定：验证码页(code-input) / 人机验证(#captcha_container) / 错误可重试
3. **120 次 × 500ms 循环监听 URL**：离开 login/signup=成功；`2sv/email` → 自动切 `2sv/totp`；TOTP → Handle2FA；captcha → 处理
4. 超时 → "登录超时"

**手机验证码**：选国家（`#loginContainer div[aria-controls=phone-country-code-selector-wrapper]` → `#US-1`）→ 输手机号 → 短信平台收码 → 输入提交

**Google 登录**：完整 Google 状态机（14 种 URL 模式）：账号列表选择 / 密码 / TOTP / 备用邮箱确认(kpe) / 手机验证(iap→抛错) / 停用页 / 人机验证 / 同意页；TikTok 侧补生日（随机）→ next-button → 完成

### 2.5 注册流程（TikTokSignUp）

**邮箱注册**：PrepareSignup（处理政策确认弹窗 `#signup-policy-all`+next-button）→ 随机生日（年 18-50/月/日）→ 输邮箱+勾选同意+输密码 → 邮箱收码 → 提交 → 三选一判定：注册失败页(instagram-img)/取用户名页(new-username)/captcha → 跳过用户名 → 完成

**手机注册**：类似，国家选择 → 手机号 → 短信收码 → 设密码页 → 用户名=`U+手机号` → 完成

**失败提示**："注册失败, 可能是因为注册次数过多或您的注册邮箱存在问题"

### 2.6 人机验证（Recaptcha，4 类）

| 类型 | 识别方式 | 执行 |
|---|---|---|
| 滑块 Slide | 云端 `RecognizeSlideAsync(img)` → 偏移像素 | SimulateDrag 拖拽把手 `.secsdk-captcha-drag-icon` |
| 双旋转 DoubleRotate | 内外图 → `RecognizeDoubleRotateAsync` → 角度 | 像素位移 `271*(offset/180)` 拖拽 |
| 选图 SameSharp | `RecognizeSameSharpAsync` → 点坐标数组 | 逐点点击(500-2000ms 间隔) + 确认 |
| 音频 Audio | 下载 → MD5 查缓存 → `RecognizeSpeechAsync` → 语音字母替换规则(why→y/you→u/be→b/oh→o) | 输入 + 确认；成功记录缓存 |

最多 3 次重试，失败抛"人机验证失败"。全部识别走云端服务（`CloudService`）。

### 2.7 2FA 与验证码接收

**TikTok 2FA**：`Fa2SecurityKeyHelper`：本地 TOTP（标准 30s）→ 失败 HTTP `https://2fa.cc/tool/code/{key}` 兜底。自动从 `/2sv/email` 切到 `/2sv/totp`。

**短信平台**（SmsCodeReceiver）：
- sms8: `api.sms8.net/api/record/?token=` → `{code:1, data:{code}}`
- sms999: `999sms.vip/sms-record/?token=` → `{code:200, data:"含6位数字"}`（新平台：logincode.add4533.com / jiema.didiapi.uk）
- 3s 轮询 × 12 次

**邮箱验证码**：IMAP 拉取（IEmailVCodeReceiver 接口，发码时刻-10s 起）

### 2.8 导入导出

**CK 导入 4 种格式**：
1. 完整 JSON（`{"uid":..., "cookie":[...]}`）
2. Cookie JSON 数组
3. Cookie 字符串（`sessionid=...;...`）
4. `----` 分隔段：`用户名----密码----[2FA]----[邮箱]----[邮箱密码]----[Cookie串]`

扩展字段：`device_id`→DeviceId、`uage`→UserAgent、`platFromUrl`→QueryParameters、`xtoken`→XToken。

**"固定使用此Cookie"（UseSessionCookie）**：导入后 Expires=null + UseCookie=true（永不刷新，协议号专用）。

**导出 3 种**：
| 类型 | 格式 | 说明 |
|---|---|---|
| 明文账号 | `----` 分隔（按类型含 2FA/邮箱/短信 URL） | 按登录状态过滤 |
| Cookie 加密串 | JSON → Brotli → **AES-ECB**/PKCS7 → Base64 | 硬编码 Key(32B) |
| 环境 .jyttk | zip(LocalStorage/IndexedDB/Cookies/指纹) + **AES-CBC** 加密 | 硬编码 Key+IV |

### 2.9 刷新账号信息（RefreshProfileAsync）

1. 导航个人主页（点 `a[data-e2e=nav-profile]`）→ 等 `@用户名` URL
2. 解析 `__UNIVERSAL_DATA_FOR_REHYDRATION__` JSON（`UserPageModel.Scope.UserDetail.UserInfo`，兜底 `AppContext.User`）
3. 提取：昵称/头像/签名/粉丝/关注/视频数/地区/语言 + **DeviceId = AppContext.Wid**
4. Cookie 刷新（可选）：访问 `/messages` 触发跨域同步 → WebView2 拉取全部 `.tiktok.com` cookies
5. 头像下载本地缓存（2 次重试）
6. **CK 号警示**：刷新会把移动端 Cookie 换成浏览器平台 Cookie，影响协议私信 → UI 明确提示

### 2.10 资料批量设置

- 昵称随机后缀：`NickName + 随机(小写字母+数字)`
- 编辑流程：`edit-profile-entrance` → `edit-profile-header` → 仅值变化才改 → 保存（`edit-profile-save` 等脱离，120s）→ 用户名变更需确认弹窗（`set-username-popup-confirm`）
- 头像：注入文件 → 裁剪弹窗确认（5 分钟超时）→ 保存 → 5s → 刷新

### 2.11 并发与启动

- 并行度：私信任务=1、Google 采集=1、匿名采集=4、浏览器任务=Settings.MaxDegreeOfParallelism（默认 4，可持久化配置）
- 启动：加载账号 → 批量建浏览器环境（每账号独立 UserDataFolder + 指纹）→ 未注册空状态批量置 NotRegistered

### 2.12 优化建议（重构评估）

| # | 问题 | 建议 |
|---|---|---|
| 1 | 环境加密密钥硬编码（AES-ECB Key 明文） | 用户级密钥 + 迁移方案 |
| 2 | 人机验证依赖云端服务（CloudService） | 本地化/开源识别方案，或人工兜底队列 |
| 3 | 120×500ms 登录轮询 | 事件驱动（CDP 监听）+ 超时可配 |
| 4 | 注册区域限制（"当前IP区域不支持邮箱注册"） | 区域/代理联动提示 |
| 5 | 密码明文存储（SQLite） | 系统级 DPAPI 加密 |
| 6 | Cookie 刷新破坏协议号 | CK 号刷新前强制二次确认（已有警示，可加保护锁） |

---

## 3. 数据采集模块设计

### 3.1 模块职责

从 TikTok 批量采集用户/视频/评论/关系/标签数据，作为筛选与触达的数据源。核心架构决策：**浏览器上下文内请求（window.fetch）+ 可选签名（XBogus/XGnarly）** 两种路径。

### 3.2 采集架构

```
UI DataGrid → Collect 对话框 → TaskManager.Execute(TikTokCollect*Task)
  ├─ Task1 系: TikTokAutomaCollectTask（无登录，租用匿名浏览器池）
  ├─ Task2 系: TikTokAutomaBrowserTask（需登录，运行在账号浏览器内）
  └─ Google 采集: 独立 Google 搜索任务（max 1 并发）
  └─ TikTokApiService（每用户名一个实例, IDisposable）
       ├─ HttpClient 路径: 桌面/移动 UA + XBogus/XGnarly 签名
       └─ BrowserSimulator 路径: 页面内 window.fetch（无签名, 浏览器环境反爬）
  → SaveAndPushDataAsync → EF BulkInsert → tiktok.sqlite + UI 实时推送
```

**浏览器池**："tiktok" 池 30 实例（InPrivate、隐藏 WebRTC、1280x800），匿名采集用。

**并发**：Task1 系硬编码 4 并发；Task2 系 MaxDegreeOfParallelism（默认 4）；Google 采集 1 并发。

### 3.3 采集任务清单与机制

| 任务 | 端点 | 签名 | 传输 | 说明 |
|---|---|---|---|---|
| 采集视频 (TikTokCollectPostTask) | `/api/post/item_list/` count=35 | 无（浏览器） | 页面 fetch | 按用户名采集全部帖子；游标分页；CreateTime 降序 |
| 采集评论 (Task1/2) | `/api/comment/list/` count=20 | 无 | 页面 fetch | 按视频 URL 采集；aweme_id + cursor 分页 |
| 采集用户评论 (Task1/2) | 同上 | 无 | 页面 fetch | 用户 → 帖子（天数过滤）→ 评论 |
| 采集粉丝/关注 (Task2) | `/api/user/list/` scene=67/21 | 无 | 页面 fetch | 需登录账号；minCursor/maxCursor 分页 |
| 采集博主 (TikTokCollectUserSearchTask) | `/api/search/user/full/` | XBogus | 浏览器 Fetch | 关键词搜索；cursor+search_id 分页 |
| 采集标签 (TikTokCollectTagPostTask) | `/api/challenge/detail/` + `/api/challenge/item_list/` | XBogus | HttpClient | 两步：标签→challengeID→帖子 |
| 全网用户 (TikTokSearchGoogleTask) | Google SERP 抓取 | - | 浏览器 | `{关键词} {地区} site:tiktok.com`；风控弹窗人工验证 |

### 3.4 签名机制

- **XBogus**：内嵌 JS（`Juytu.OmniMarket.TikTok.Services.XBogus.js`，51KB），Jint 引擎执行 `sign(url, userAgent)` —— 完整还原 TikTok 网页端签名
- **XGnarly**：纯 C# 实现字节码风格签名 —— MD5(query/body/UA) + 时间戳异或混淆 + 自定义 base64 字母表 `"u09tbS3UvgDEe6r-ZVMXzLpsAohTn7mdINQlW412GqBjfYiyk8JORCF5/xKHwacP="`
- 浏览器路径不需要签名（真实页面上下文本身就是反爬证明）

### 3.5 默认查询参数（CreateDefaultParameter）

`aid=1988, app_name=tiktok_web, os=windows, device_id=随机19位(7331578718382456832~7331860193359167487), device_platform=web_pc, screen 1440x900, region=US, WebIdLastTime=随机(1s~30天前), browser_language=en-US`

**设计要点**：device_id 随机生成 + WebIdLastTime 随机回退 —— 模拟真实新访客。

### 3.6 数据模型（7 张采集表）

| 表 | 实体 | 关键字段 |
|---|---|---|
| UserRelationship | TikTokDataUserRelationship | Type(Follower=1/Following=2/Friend=3), 用户全量画像(粉丝/关注/视频/点赞/签名/私密/商家/认证), BioLink |
| UserComments | TikTokDataUserComment | 评论者画像 + 评论内容/点赞/回复数 |
| PostComments | TikTokDataPostComment | 同上 + 作者信息 |
| UserSearchs | TikTokDataUserSearchItem | Keyword, 用户画像 |
| UserPosts | TikTokDataPost | 帖子全量(播放/点赞/评论/分享/封面/时长/比例) |
| SearchTags | TikTokDataSearchTagItem | Tag + 作者画像 + 帖子统计 |
| SearchGoogeItems | TikTokDataSearchGoogleItem | Keyword, Region, UserName, Title, Summary, Link |

**导出**：每个 DataGrid 的"导出"按钮 → NPOI Excel（列由 [Display] 特性驱动，[ExcelIgnore] 跳过）。

### 3.7 关键设计决策与已知问题

1. **浏览器路径为主**：无签名依赖 + 反爬由真实浏览器承担 → 稳定性高但慢（每次租窗口）
2. **每用户名新建 TikTokApiService**：处理完一个用户即 Dispose（关浏览器窗）→ 不跨用户复用（性能可优化点）
3. **评论采集的 cookie 参数是死代码**：EnumerateCommentsAsync 接收 cookie 但状态机从不使用（浏览器 jar 生效）→ 纯 HttpClient 重构时需接上
4. 任务错误吞掉（catch 空）继续 —— 容错但难诊断（建议重构加错误统计）
5. 采集并发 4 硬编码 —— 平台风控平衡，可配置化
6. 试用限制：100 行/任务、导出禁用

### 3.8 优化建议（重构评估）

| # | 问题 | 建议 |
|---|---|---|
| 1 | 浏览器窗口每用户名重建 | 池化复用 + 连接复用 |
| 2 | 无签名 HttpClient 路径闲置 | 优先走 HttpClient + XBogus（快） |
| 3 | 错误静默 | 错误统计/重试策略 |
| 4 | device_id 随机生成 | 每个浏览器环境固定 device_id（一致性） |
| 5 | 4 并发硬编码 | 配置化 + 风控自适应降速 |

---

## 4. 用户筛选模块设计

### 4.1 模块职责

对采集/手动添加的用户列表做多维画像增强（地区/性别年龄/可私信/活跃度），产出可直接用于触达的目标列表。UI 上即"AI 数据深挖"页（`/tiktok/screening`，三个 Tab：用户筛选 / 强私筛选 / 筛选数据库）。

### 4.2 用户资料筛选（TikTokScreeningUserProfileTask）

**数据源**：`UserScreenings` 表（手动粘贴用户名 / 采集任务产出）。

**配置**（ScreeningUserConfirmDialog）：线程数 1-10、筛选间隔秒、代理多选（建议数量=线程数）、重筛已完成/已失败、筛选国家区域、筛选头像（性别年龄）、筛选活跃时间、可私信（需选账号）。

**每个用户的处理流水线**（子任务并行 Task.WhenAll）：
```
1. 主页解析: GET /@{username} (移动UA) → __UNIVERSAL_DATA_FOR_REHYDRATION__ JSON
   → TikTokUserInfo (uid/secUid/头像/昵称/签名/地区/语言/粉丝/关注/视频/点赞/私密/卖家/认证/BioLink)
2. [区域] Region 为空 → SignalR CloudService.GetTikTokUserRegion(uid) 云端补全
3. [头像] AvatarUrl 有效 → 下载头像 → POST 人脸识别服务(175.178.52.225:8001/api/v3/recognize/face)
   → Gender/Age (Multiple=多人脸标记)
4. [可私信] CheckImPermissionAsync → MaxMessageCount (0/1/3)
5. [活跃] 浏览器模拟采集帖子 → 最新帖子时间 → LastActivity
6. 结果 → 状态 Completed/Faulted + Error
```

**并发模型**：RandomGroup 轮询分发给 N 组（1-10），每组独立 TikTokApiService（浏览器池）+ 独立 HttpClient（**直接 WebProxy，不走 Xray**，轮询分配）；组内可配间隔。

**云端推送**：UserId + Region 存在时 → SignalR `PushData("tk-ui", {id,un,rg,lg,ca})`（供云端/其他端消费）。

### 4.3 强私筛选（TikTokScreeningUserChatTask）

独立任务：对 `ChatScreenings` 表逐条调 `CheckImPermissionAsync`：
```
GET https://{apiDomain}/tiktok/v1/im/chat/notice/?to_user_id={to}&conversation_id=0%3A1%3A{to}%3A{from}&source_type=dm_chat&aid=1233&app_name=musical_ly&version_code=250203
notice_code: chat_stranger_check→3条 / chat_request_start→1条 / 其他→0条
```
- 线程 1-100，**无代理支持**（原实现缺陷），组内无间隔
- Cookie 有效性先验（CheckCookieAsync：GET /profile + 解析 Uid）

### 4.4 数据模型

- `TikTokUserScreeningItem`：Key(用户名) + UserId/昵称/头像/签名/BioLink/地区/语言/可私信/最大条数/最近活跃(秒)/性别/年龄/点赞/视频/好友/关注/粉丝/Digg/私密/卖家/认证 + Status(待筛/完成/失败) + Error
- `TikTokChatScreeningItem`：Key(uid) + IsChatabled + MaxMessageCount
- 归档：`TikTokUserArchiveItem`（Id=UserId 字符串，无 UserId 列）

### 4.5 设计要点与缺陷

1. 时间戳不一致：WhenCreated/WhenUpdated 用毫秒，LastActivity 用秒（导出/筛选需区分）
2. 强私筛选无代理（并发 100 时单 IP 风险高）→ 重构必加
3. 筛选用直接 WebProxy 而非 Xray（HTTP 客户端场景绕过 Xray 设计）
4. 试用限制：3 条 + 禁导出
5. 人脸识别/区域查询依赖云端（SignalR + 175.178.52.225）→ 重构需自建或本地化

---

## 5. 私信触达模块设计 ★（最详细）

### 5.1 模块职责

私信触达模块负责 TikTok 私信的**全部发送能力**：目标管理、话术渲染、多通道发送、结果记录、导出。是产品的核心变现功能。

### 5.2 架构

```
                    ┌──────────────────────────┐
                    │  私信触达模块 (Im*)       │
                    │                          │
  ┌───────────┐    │  ┌────────────────────┐  │    ┌──────────────┐
  │ 目标来源    │───▶│  │ 任务调度           │  │───▶│ 通道一 Android│
  │ 采集结果    │    │  │ (AutomaTaskManager)│  │    │ 通道二 Web    │
  │ 筛选结果    │    │  └────────────────────┘  │    │ 通道三 中转API │
  │ 手动导入    │    │   │  │   │   │          │    │ 通道四 代跑任务│
  └───────────┘    │   ▼  ▼   ▼   ▼          │    │ 模拟通道 浏览器 │
                   │  ImTask ImApiTask       │    └──────┬─────────┘
                   │  TouchTask ImProxyTask  │           │
                   │                          │    ┌──────▼─────────┐
                   │  ┌────────────────────┐  │    │ TikTokImMessage │
                   │  │ 话术渲染/卡片构建   │  │───▶│ 结果记录        │
                   │  └────────────────────┘  │    │ (SQLite)       │
                   └──────────────────────────┘    └────────────────┘
```

### 5.3 通道对比与选型

| 通道 | 连接方式 | 速度 | 依赖 | 封号风险 | 2026 实测状态 | 重构建议 |
|---|---|---|---|---|---|---|
| 一 Android | WSS frontier.tiktokv.* | 快 | 无 | 高 | ❌ 400（协议升级） | 放弃/需重逆向 |
| 二 Web | WSS im-ws.tiktok.com | 快 | 无 | 高 | ✅ 握手通，发送逆向中 | **主力** |
| 三 中转 API | HTTP 厂商服务器 | 快 | 厂商 | 中 | 未测（厂商依赖） | 弃 |
| 四 代跑任务 | HTTP 厂商服务器 | 快 | 厂商+key | 中 | 未测 | 弃 |
| 模拟 | WebView2 浏览器 | 慢 2-5条/分 | 无 | 低 | 流程验证通过 | **兜底** |

**设计结论**：通道二（Web 直连）为主力（自持能力 + 速度），模拟通道兜底（低风险），通道一/三/四放弃。

> 重构定位澄清（2026-08 评审）：ttdm（Go 重构版）当前已完整实现的恰是**通道一**（AndroidClient，含 protobuf/LZ4/错误码/任务引擎），但因 HTTP 400 不可用，其定位是**协议骨架与字段参考**（`IImClient` 接口、帧编解码、任务引擎均复用）；通道二（WebClient）与模拟通道（BrowserClient）将实现同一 `IImClient` 接口。

### 5.4 通道二协议设计（Web WSS，fws_1.0.0）

#### 5.4.1 连接（已实测打通）

```
wss://im-ws.tiktok.com/ws/v2?device_platform=web&version_code=fws_1.0.0
  &access_key=<MD5("9"+"e1bd35ec9db7b8d846de66ed140b1ad9"+ttwid设备ID+"f8a69f1719916z")>
  &fpid=9&aid=1459&ttwid=<URL解码后的ttwid原始值>&xsack=1&xaack=1&xsqos=0
```

- 子协议：`pbbp2`（2026 实测；旧版 pbbp 已淘汰）
- 请求头：UA（Chrome 149 系）、Origin: https://www.tiktok.com、Cookie（全部 tiktok.com cookies）
- **关键**：access_key 的 device_id 素材 = **ttwid 中的设备 ID**（19 位数字，非 uid！）
- 备选连接（fpid=32 变体）：`fpid=32&service=33554513&method=2&aid=1988&device_id={uid}`，access_key 算法不同（待逆）

#### 5.4.2 消息信封（已解析）

```
帧 = protobuf:
  f1: sn (varint，起始 10001，递增)
  f2: timestamp ms (varint)
  f3: service = 33554513
  f4: method = 2
  f7: "2" (string)
  f8: body (length-delimited)
    f1: 设备块 { f1: 2, f2: "{uid}", f3: "{uid}", f4: ts }
    f2: 消息块列表（len16 块 { f1: 4, f2: 0, f3: 1/0, f4: 会话ID }）
```

#### 5.4.3 消息流（发送结构逆向中）

- 初始化帧（页面打开自动发）：sn 递增的心跳/同步帧
- 输入状态帧：`ws.send("hi")`（文本帧，2 字节 = 输入内容，typing 通知）
- **发送消息**：疑似走 HTTP API（`Network.requestWillBeSent` 待抓）或特定 method 的 protobuf 帧（待逆）

#### 5.4.4 待完成事项

- [ ] 抓取发送消息的真实请求（HTTP 或 WS 帧）
- [ ] 逆向创建会话/发送消息的完整字段结构
- [ ] 实现 WebImClient（Go）：连接/会话/发送/错误映射
- [ ] 真实发送验证

### 5.5 通道一协议设计（Android WSS，已实现待修）

#### 5.5.1 连接

```
wss://{frontier.tiktokv.us|eu|com}/ws/v2?{40项设备参数}&access_key=<MD5("9"+magic+deviceId+suffix)>
```
- 子协议：pbbp（旧）
- 参数模拟：Samsung SM-G9900 / Android 12 / musical_ly 31.7.3 / aid=1233 / okhttp UA

#### 5.5.2 消息流

```
文本: 609创建会话 → 411预发 → 200ms → 100发送(text JSON) → ack
其他: 609 → 100发送(LZ4压缩信封) → ack
```

- Type 609 body: { f1: 1, f2: [fromUid, toUid] }
- Type 411 body: { f1: convId, f2: 1, f3: shortId, f4: 3 }
- Type 100 body: { f1: convId, f2: 1, f3: shortId, f4: contentJSON, f6: msgType, f8: msgId }
- LZ4 信封: AppImLz4Request { f1: sn, f6: "__lz4", f8: 压缩后的消息protobuf }
- 文本 JSON: `{"isDefault":false,"text":"...","is_card":false,"sendStartTime":ms,"aweType":700}`

#### 5.5.3 失效原因与修复路径

- 2026 实测 HTTP 400：子协议升级（pbbp→pbbp2）+ 版本参数过时（31.7.3）+ access_key 变体
- 修复需要：真实 Android App 流量参照（抓包）—— 成本高，建议放弃

### 5.6 通道三/四设计（厂商中转，弃用但记录契约）

**通道三**：
```
POST http://137.175.124.165:7788/tiok/v2/message/cx/send
{ accountData, userId, proxy, sendType: 1|2|3|4|5, message/卡片参数 }
响应: { code, success, data: { body6: { body100: { status, errorDesc } } } }
```

**通道四**：
```
POST http://137.175.124.165:48088/admin-api/tiktok/message/api/{create|start|interrupt|page}
x-api-key 认证；create 提交 uid列表+话术+代理 → taskId
```

### 5.7 模拟通道设计（浏览器自动化）

#### 5.7.1 触达任务（TikTokTouchTask）

```
对每个目标用户:
  1. 导航 https://www.tiktok.com/@{username}
  2. 等待用户主页（title 或 error container）
  3. 定位第一条帖子 → 点击进入详情
  4. 按配置执行: 关注/点赞/收藏/转贴/评论
  5. 返回主页 → (如未在帖子中关注) 关注
  6. 点击私信按钮 button[data-e2e=message-button]
  7. 输入话术(随机) → 发送
  8. 记录 AutomaImMessage 结果
  9. 随机间隔后下一个
```

#### 5.7.2 私信发送（ImSendMessageAsync）

DOM 选择器（2026 年 8 月实测有效）：
```
输入区:  div[data-e2e=message-input-area] div.DraftEditor-root
会话标志: p[data-e2e='chat-uniqueid']  (非空且非 @)
发送按钮: [data-e2e=message-send], [data-e2e=dm-new-send-btn]
结果检查: #main-content-messages div[data-e2e=chat-item]:last-of-type
         div[data-e2e=dm-warning] / div[data-e2e=dm-message-notification]
         div[class*=DivSendFailTip]
```

**流程**：等待输入区 → 等待会话加载（chat-uniqueid）→ 聚焦输入 → 输入文本（模拟键盘）→ 300ms → 点击发送 → 检查发送结果（warning/notification）。

### 5.8 话术渲染设计

```
TikTokImMessageCard.GetMessage():
  1. 从 Templates(HashSet<int>) 随机选一个话术 ID → AppState.ChatTemplates 查文本
  2. 转义: 先将 CRLF/LF 统一折叠为 LF，再把换行与双引号转义为 JSON 字面量（供消息 body 使用）
  3. [RandomEmoji] 追加 3 个随机表情（40 符号常量池，随机偏移取）
  4. [CurrentDateTime] 追加 " yyyy-MM-dd HH:mm"
  注: 原版无 {变量} 插值，占位符替换需重构新增（见 10.2 澄清）
```

**链接卡多 URL 随机**：`RandomLinkUrl()` 从 LinkUrls 池随机选，防平台识别重复链接。

### 5.9 任务执行引擎设计（协议通道）

```
SendAsync(options):
  1. 校验: senders/receivers 非空、至少一种内容、参数 Validate()
  2. CreateTasks(): 每发送账号 = 1 任务状态
     - 接收者轮询分配 (Round-Robin)，每账号上限 MaxSentCount
     - 代理轮询分配
     - 试用模式: 1 账号 + 3 接收者
  3. Parallel.ForEachAsync(并发度 = min(MaxConcurrency, 账号数))
  4. 每账号循环接收者:
     - 连接 → 创建会话 → 发卡片(文本/链接/视频/图/主页) → 断开
     - 卡片间 terminate 短路 (前卡失败跳过后续)
     - 7180 → quit 整个账号; 连续失败 >= MaxFailCount → 退出
     - 间隔 IntervalSeconds
  5. 结果 → MessageQueue 异步写库
```

### 5.10 错误码设计（统一映射）

| status_code | 中文提示 | Terminate | Quit |
|---|---|---|---|
| 7174/7178/7192 | (陌生3条上限=成功) | - | - |
| 7180 | 消息发送过快 | ✓ | ✓ |
| 7175 | 已达到聊天消息限制 | ✓ | |
| 7195 | 违反《社区自律公约》 | ✓ | |
| 7278 | 对方帐户已停用 | ✓ | |
| 7282 | 只有好友才能互相发送消息 | ✓ | |
| 7283 | 对方设置限制 | ✓ | |
| 7289 | 发送方被暂时禁止 | ✓ | |
| 7290 | 对方多次违规 | ✓ | |
| 7409 | 无法与该用户聊天 | ✓ | |
| 200001 | CK 失效 | 抛出 | |

### 5.11 强私筛选设计

```
CheckImPermissionAsync(fromUid, toUid, cookie, idc):
  GET https://{apiDomain}/tiktok/v1/im/chat/notice/
     ?to_user_id={toUid}&conversation_id=0%3A1%3A{toUid}%3A{fromUid}
     &source_type=dm_chat&aid=1233&app_name=musical_ly&version_code=250203
  Headers: Cookie + sdk-version: 2
  判定:
    notice_code 含 "chat_stranger_check" → 3 条
    notice_code 含 "chat_request_start" → 1 条
    其他 → 0 条 (不可私信)
```

- 多线程（最高 100）+ 失败重筛
- ⚠️ 实现中关闭了 SSL 证书校验（DangerousAcceptAnyServerCertificateValidator）→ 重构须修复

### 5.12 数据模型

```
ImMessages (通道一/二结果):
  TaskId, SenderId, ReceiverId, ProtocolType(1/2),
  MessageStatus/LinkCardStatus/VideoCardStatus/PictureCardStatus/HomePageStatus (bool?),
  各 Error, Quit, WhenSent

ImApiMessages (通道三结果): 同结构, SenderId 为 string

ImProxyTasks (通道四): ApiKey, TaskId, Total, Success, Failure, IsCompleted

ImSenderRecord (每发送账号统计, PK=Uid): Sent, Failed, Total, Quit
ImReceiverRecord (每接收者状态, PK=Uid): 各卡片 Odle/WaitForSend/Success/Failed

AutomaImMessage (模拟通道): AccountId, To, ToId, IsSuccess,
  Follow/PostLike/PostFavorite/PostRepost/PostComment/ImText, Error
```

### 5.13 优化建议（重构评估）

| # | 问题 | 建议 |
|---|---|---|
| 1 | 通道一被协议升级淘汰 | 集中资源做通道二 |
| 2 | 通道三/四依赖厂商 | 弃用；自建中转则按契约实现 |
| 3 | 每接收者重连（慢） | 连接复用（会话级连接池），控制并发防风控 |
| 4 | 单例互斥（一次一任务） | 任务实例化，多任务并发（账号互斥保留） |
| 5 | 错误处理散落字符串 | 统一错误码枚举 + 统计 |
| 6 | 强私筛选关证书校验 | 证书固定/代理复用 |
| 7 | 模拟通道 DOM 脆弱 | 选择器集中管理 + 自动降级到协议通道 |
| 8 | 无发送成功率观测 | 遥测表（发送/失败原因分布） |
| 9 | 试用假发送 | 独立标记，不混入真实数据 |

---

## 6. 养号模块设计

### 6.1 模块职责

通过模拟真实用户行为（浏览/互动/互聊）提升账号活跃度与权重，降低新号封号风险。纯行为模拟，**不产生业务数据落库**（养号过程无 DB 写入，仅登录态更新）。

### 6.2 关键词/浏览养号（TikTokWatchTask）

**触发**：矩阵批量选择账号 → TrainDialog 配置 → StartWatchCommand → 每账号一个 TikTokWatchTask。

**参数**（WatchOptions）：

| 参数 | 默认 | 说明 |
|---|---|---|
| MaxDuration | 60s | 单视频观看时长上限 |
| Times | 30 | 浏览视频数（≤0 = 无限） |
| Like/Follow/Digg/Collect/Comment/ViewCommentsProbability | 0 | 各互动概率 0-1 |
| Search | null | 非空则从搜索词进入（非 ForYou） |
| Comments | null | 评论话术池（随机选） |

**执行流程**：
```
1. 确保登录（不导航首页）
2. 入口: Search模式 → /search?q={词} → 点击搜索结果第一条
         ForYou模式 → 首页/ForYou → 定位可见第一条视频 → 打开评论面板(检测3种布局)
3. 关闭 Cookie 横幅 (shadow-DOM 点击)
4. 循环 Times 次:
   - 并发等待"下一个视频"按钮 + 随机时长(5s~MaxDuration)
   - 概率执行: 点赞/收藏/关注/评论(话术池随机)/评论点赞/滚动评论(取消时终止)
   - 每次互动前 100-1500ms 人性化停顿
   - 点击下一个 (dialog 或 feed 布局)
5. 关闭浏览抽屉
```

**关键选择器**：
- 搜索输入: `input[data-e2e=search-user-input], input[type=search]`
- 下一个视频: `button:has(path[d^='m24 27']), button[data-e2e=arrow-right]`
- 评论面板 3 种布局检测: Browse(dialog) / Floating / Sidebar
- 关闭: `button[data-e2e=browse-close]`

**设计要点**：
- 随机性无处不在（时长/概率/停顿）→ 反风控核心
- 并发观看 + 滚动评论用 LinkedCancellationTokenSource 协同
- 评论面板布局检测（GetCommentViewModeAsync）适配 TikTok 多版本 UI

### 6.3 智能养号/互聊（AutomaBrowserChatTrainTask）

**原理**：两个自有账号互相聊天（算术题问答脚本），模拟真人对话，提高账号活跃度。

**配置**（AutomaTrainParameters）：PairCount=1、每会话消息数 MinChat=1~MaxChat=5、回复间隔 1-60s、MaxFaulted、语音/图片概率 25%、并发 ≥2。

**配对算法**（ChatConversationPairer）：
1. 洗牌 → 按"已发起会话数升序、已回复会话数降序"排序
2. 第一个作发起者，找**从未配对过**的回复者（历史去重）
3. 无新配对则随机
4. 产出 ChatConversation(Initiator, Responder, IsNewConversation)

**消息生成**（ChatMessageGenerator）：N 轮 Q+A（算术题 `{a} + {b} = ?`），25% 概率带图片、语音开启时 25% 概率带语音；每条带 DelaySeconds。

**执行**：
- 每会话两个浏览器**并发启动**（Task.WhenAll），故障方 SetFaulted 移除
- 逐条交替发送：发送者 = 消息.From；首条后每条先等 DelaySeconds 再**复检登录**（登出 → "账号疑似被停用"终止）
- 失败计数：被动方 errors_passive，达 MaxFaulted 终止
- 数据落库：AutomaChatConversation（Initiator/Responder/WhenCreated）+ 账号会话计数（InitiatedConversationsCount/RespondedConversationsCount）

**⚠️ 注意**：TikTok 模块**没有** TrainTask 子类（反编译快照里只有 Telegram/WhatsApp 实现了 ChatAsync）—— 原版 TikTok 互聊可能未启用或已移除。

### 6.4 矩阵私信（TikTokChatTask，浏览器模拟）

按 uid 逐个发送：导航 `https://www.tiktok.com/messages?lang=en&u={userId}` → 等待输入区 → 校验 `chat-uniqueid` 非 "@"（用户不存在判断）→ 话术+随机表情+当前时间 → 输入 → 发送 → DOM 探测结果。

---

## 7. 视频发布模块设计

### 7.1 模块职责

批量账号发布视频（内容矩阵），支持文件交叉分配、话题标签、橱窗商品链接。

### 7.2 参数与分配策略

**文件校验**（PublishDialog）：.mp4/.webm、≤10GB、≤10分钟、720x1280+。

**分配模式**（StartPublishCommand）：
- 交叉分配（Cross=true）：`files.RandomGroup(账号数)` 平均分给各账号
- 非交叉：每个账号发布全部文件

### 7.3 执行流程（TikTokPublish）

```
每个文件:
1. 确保登录
2. 导航 https://www.tiktok.com/tiktokstudio/upload?from=webapp&tab=video
3. input[type=file] 注入文件 → 等待上传完成
   (轮询 div.info-progress-num 文本; 完成标志: 主按钮 aria-disabled=false)
4. 关闭 2 个弹窗浮层 (__floater__open 按钮 + common-modal-close)
5. 填写标题: 点击 caption-editor → 逐字符输入(500ms间隔, 先清空)
6. 话题标签: 逐个输入 → 点击联想项 div.hashtag-suggestion-item (最多3次尝试)
7. 橱窗商品(可选): 点击 anchor_container → 确认弹窗 → 商品表格中按 ID 勾选 → 确认 (10次重试)
8. 点击发布按钮 (TUXButton--primary, 两套布局分支) → 等待按钮消失
```

**设计要点**：
- 上传进度轮询 + 截图留证
- 双布局发布按钮适配（TUX 与 Button__root 新旧两套类名）
- 商品选择器按 ProductId 精确匹配表格行

---

## 8. 直播间监听模块设计

### 8.1 模块职责

实时监听直播间消息（进房/评论/点赞/礼物/关注/分享/表情），获取直播观众数据用于截流/私信。**纯协议实现**（无浏览器依赖）。

### 8.2 连接流程（TikTokLiveClient，3 阶段）

```
阶段1 解析房间: 
  GET https://www.tiktok.com/@{username} (移动UA) → 解析 __UNIVERSAL_DATA_FOR_REHYDRATION__ JSON → UserInfo.RoomId
  无 RoomId → GET /@{username}/live → 正则提取 room_id

阶段2 获取 WSS 连接数据:
  GET https://tiktok.eulerstream.com/webcast/fetch?client=ttlive-net&uuc=1&room_id={id}
  响应: protobuf WebcastConnectionData { Cursor(2), InternalExt(5), RouteParamsMap(7), WssUrl(10) }
  头: x-set-tt-cookie → 存入 Cookie
  429 → 读 RateLimit-Reset 头 → 提示"访问过于频繁，请在 mm:ss 后尝试"
  重试 3 次 × 500ms

阶段3 建立 WebSocket:
  wss://{WssUrl 或默认 webcast16-ws-useast5.us.tiktok.com}/webcast/im/ws_proxy/ws_reuse_supplement/
  query: aid=1988 + 浏览器参数 + room_id + cursor + internal_ext + RouteParamsMap
  headers: Cookie + UA(Edge/Chrome 134) + Origin
  3 次尝试
```

### 8.3 心跳与接收

- **PingLoop**：每 3s 发送二进制心跳 `[0x3A, 0x02, 0x68, 0x62]`
- **ReceiveLoop**：接收 → 解析 `WebcastPushFrame`（protobuf: SeqId/LogId/Service/Method/PayloadEncoding/PayloadType/Payload）→ 解包 `WebcastResponse`（MessagesList/NeedsAck）→ **NeedsAck 时回 ack**（`WebcastAck { Id=SeqId, Type="ack" }`）→ 逐条 `WebcastMessage`（Method/Payload）分发

### 8.4 事件映射

| Method | 事件类型 | 关键字段 |
|---|---|---|
| WebcastMemberMessage | Join（进房） | User, MemberCount, EnterType |
| WebcastSocialMessage | Follow(动作1)/Share(动作3) | Sender, Action |
| WebcastChatMessage | Chat（评论） | User, Content |
| WebcastLikeMessage | Like | Count, Total, User |
| WebcastGiftMessage | Gift | GiftId, ComboCount, User, ToUser |
| WebcastRoomUserSeqMessage | 房间人数更新 | Total, TotalUser |
| WebcastControlMessage | Stream_Ended → LiveEnded | Action |
| WebcastEmoteChatMessage | Emote | User, EmoteList |

用户结构 WebcastUser 完整字段（Id/NickName/AvatarThumb/Follow_Info{粉丝数}/DisplayId/SecUid 等 60+ 字段）。

### 8.5 断线重连

- 意外异常 → 关闭 socket → **递归重连**（重新走 3 阶段）
- 重连失败 → Faulted（"直播间意外离线，并尝试重连失败"）
- 取消 → Disconnected（单次触发，Lock + _stopped 保护）
- 试用模式：100 条消息后自动停止

### 8.6 数据模型

- `TikTokLiveMessage`：TaskId, RoomId, RoomUserName, SenderId/UserName/NickName, SenderFollowerCount/FollowingCount, MessageType(Join/Chat/Emote/Like/Follow/Share/Gift), Message, WhenSent, SenderAvatar
- `TikTokLiveRoomInfo`（PK=UserName）：RoomId, UserId, TotalUserCount, CurrentUserCount, LastUpdated 等
- 写库：单消费者 MessageQueue 串行化 + EFCore.BulkExtensions（首次 Upsert，之后 Update）

### 8.7 设计要点与风险

- 唯一外部依赖：`tiktok.eulerstream.com` fetch 端点（第三方，需监控可用性）
- protobuf 解析容错（ProtoException 吞掉继续）
- 直播用户数据可直接进入私信目标（截流闭环）
- 状态机：Connecting → Connected → LiveEnded/Disconnected/Faulted

---

## 9. AI 集成模块设计

### 9.1 架构：客户端不直连 DeepSeek

**关键发现**：客户端**从不直接调 api.deepseek.com** —— 所有 LLM 流量走 SignalR Hub（`{ConnectServer}/connect`，默认 `http://134.175.62.12:8002/api/v3`），API Key 与调用都在**厂商服务端**（未反编译）。

```
客户端 → SignalR WebSocket → 厂商服务器 → DeepSeek API
  ChatStreaming(messages, reasoning)     → 流式 AIChatCompletionUpdate {c:内容, r:推理, u:用量}
  TranslateStreaming(text, target)       → 翻译
  CreationStreaming(text, maxWords)      → 文案创作
```

**协议 DTO**（短键名压缩）：`AIChatMessage {r:角色, t:文本}`、`AIChatCompletionUpdate {c, r, u}`、`AIChatTokenUsage {i:输入, o:输出}`。

### 9.2 对话状态管理（AIState / ChatCompletionService）

- 会话历史 `Messages: ChangeTrackingList<AIChatMessagePair>`（Request/Response/Reasoning/Usage/Type/Status）
- **上下文预算**：`ToChatMessages()` 从最新往回，累计 usage ≥ 16384 token 截断（AITokenLimit）
- 单飞并发：同时只允许一个请求（"请等待上一次请求完成"）
- 三种模式：Chat（普通对话）/ Translate（翻译，19 种语言）/ Creation（文案，50-1000 字预设）
- DeepSeek-R1 深度思考开关（ReasoningEnabled）
- 推理内容 ReasoningContent 单独展示 + token 用量统计

### 9.3 人脸识别（头像 → 性别/年龄）

```
POST {FaceRecognionServer}/recognize/face    默认 http://175.178.52.225:8001/api/v3/
  Body: { Image: base64 }  (头像先下载→base64，2次重试)
  响应: { Gender: Unknown/Male/Female/Neuter, Age, Multiple: 多人脸 }
```
- 专用 HttpClient：证书校验恒真 + 可选代理 + Bearer Token
- 集成点：筛选任务（ScreeningAvatar 选项），失败静默不影响整条记录

### 9.4 重构评估

1. **AI 能力完全依赖厂商服务器**（SignalR + Key 都在服务端）→ 重构必须改为直连 DeepSeek API（客户端配置 Key）
2. 人脸识别服务（175.178.52.225）同理 —— 自建或换开源方案（如 insightface）
3. 16284 token 预算、单飞并发等设计可直接沿用
4. 短键 JSON 协议（c/r/u）可复用（省流量）

---

## 10. 话术管理模块设计

### 10.1 实体与服务

- `ChatTemplate { Id, Tag(标签), Text(话术文本) }` —— 全局跨平台（JuytuCommonDbContext.ChatTemplates）
- `AutomaChatTempleteService`：启动加载 → AppState.ChatTemplates；CRUD 双写（DB + 内存态）
- UI：AutomaChatTemplateSelect（多选/单选话术）+ AutomaChatTemplatePanel（CRUD 面板）

### 10.2 渲染规则（TikTokImMessageCard.GetMessage）

```
1. 从 Templates(HashSet<int>) 随机选一个话术 ID → AppState.ChatTemplates 查文本
2. 转义: 先将 \r\n 与 \n 统一折叠为 \n，再把换行与双引号转义为 JSON 字面量（供消息 body 使用）
3. [RandomEmoji] 追加 3 个随机表情（40 符号常量池，随机偏移取）
4. [CurrentDateTime] 追加 " yyyy-MM-dd HH:mm"
5. 转义 JSON 特殊字符 (\" \n)
```

**⚠️ 重要澄清**：反编译的 TikTok 话术**没有 {变量} 插值**（无 {用户名}/{链接} 占位符替换）—— PRD 层如有此需求需重构新增。链接卡的多 URL 随机（RandomLinkUrl）是防重复链接的机制，与话术变量无关。

### 10.3 使用链路

- 协议通道：`Parameters.Message.Templates`（HashSet<int>）→ 发送时 GetMessage 渲染（校验：选了话术但 Templates 空 → "消息内容不能为空"）
- 模拟通道（触达）：UI 预渲染 `ChatMessages: List<string>` → 发送时随机取一条
- 平台通用：话术库跨平台共享，各平台卡片类各自渲染

---

## 11. 数据管理模块设计

### 11.1 导出（SourceGeneration.ExcelUtilities，NPOI）

- `ExcelUtility.Save(stream, rows, ExcelSaveOptions)` → .xlsx（XSSFWorkbook）/ .xls（HSSFWorkbook）
- **列定义由特性驱动**：`[Display(Name=列名)]` 表头、`[Display(Order)]` 排序、`[ExcelIgnore]` 跳过、`[DataType(DateTime)]` 日期格式
- 大表分片（perSheetRowCount 多 sheet）
- 文件名模式：`{数据名} {yyyy-MM-dd HH-mm-ss}.xlsx`
- 导出前应用当前表格筛选/分页（state.Apply(query)）

### 11.2 归档

- 筛选结果 → `ToArchiveData()` → `ExecuteBulkUpsertAsync`（按 Id upsert）→ 删除原筛选行
- 归档库独立 Tab（筛选数据库），可删除/导出

### 11.3 任务记录（AutomaTaskInfo）

- OnStartedAsync 建记录（Name/AccountId/Status/WhenStarted）→ OnStoppedAsync 回填（Error/DataCount/WhenStopped）
- AccountId 映射列名 "MachineKey"（历史遗留）

### 11.4 设计要点

- 试用限制：采集 100 行/任务、筛选 3 条、禁导出
- 时间戳单位不一致（ms vs s）需统一
- 删除：按任务删除 / 全部删除（ExecuteDeleteAsync 批量）

---

## 12. 系统基础设施设计

### 12.1 任务引擎（AutomaTaskManager）

```
Execute(task) → CanExecute? 直接运行 : 入队
CanExecute: 同 ConcurrentKey 冲突? 类型并发已达上限?
状态机: Created → WaittingToRun → Running → RanToCompletion/Canceled/Faulted
OnTaskStateChanged: 终态 → 解锁 → GetNext() 取队首可执行任务 → 链式执行
Stop: 队列移除 + 运行中取消
```

- 每类型并发上限（SetMaxParallelism<TTask>）
- ConcurrentKey：浏览器任务 = [Browser.Id]（同账号互斥）
- ExecuteCoreAsync：新建 DI Scope → SetParameters → InternalExecute

### 12.2 代理管理（AutomaProxyService + Xray）

```
代理记录 → XrayProxyServer 本地入站代理 (GetInboundProxy)
浏览器 → 拨号本地入站 http://{Listen}:{Port} → Xray 转发真实代理
```

- 协议归一：https→http、socks→socks5
- 增删改：别名唯一校验、变更重启、批量添加
- 交叉分配：账号-代理交叉绑定
- **注意**：HTTP API 场景（筛选）不走 Xray，直接 WebProxy（两套路径）

### 12.3 浏览器环境

- 每账号独立 UserDataFolder（含 fingerprint.json、LocalStorage、IndexedDB、Cookies）
- 环境导出 .jyttk：zip + AES-CBC 加密（硬编码 Key/IV）
- 随机头像库（云端下载，8000+）

### 12.4 云端通信（Juytu.Cloud.Client）

- SignalR Hub `/connect`：ChatStreaming/Translate/Creation/GetTikTokUserRegion/PushData/Report/GetAppContext/Recharge/SetPassword
- HTTP REST：登录认证（api/v3/auth/*）+ 业务 API
- 登录态：JWT Bearer Token 自动续期
- **风险**：账号体系/订阅/人脸/AI 全部依赖厂商云端 → 重构需自建服务端或去云端化

### 12.5 基础设施级优化建议

| # | 问题 | 建议 |
|---|---|---|
| 1 | 全部依赖厂商云端（认证/AI/人脸/区域/订阅） | 去云端化：本地认证 + 直连 DeepSeek + 自建人脸 |
| 2 | 任务引擎单例 + 全局互斥 | 任务实例化，多任务并发 |
| 3 | 代理双路径（Xray/直接）不一致 | 统一代理抽象 |
| 4 | 环境加密硬编码密钥 | 用户级密钥管理 |
| 5 | 浏览器池 30 实例硬编码 | 资源感知动态池 |
| 6 | 试用限制散落各处 | 统一 License/FeatureGate 层 |
