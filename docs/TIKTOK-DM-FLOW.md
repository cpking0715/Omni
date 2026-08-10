# TikTok 私信模块业务流程 �?逆向分析文档

> 基于 `OmniMaketDev/decompiled/Juytu.OmniMarket.TikTok/`（IL 反编译，0 警告�?62 文件�?> 版本 5.8.21 | 更新�?026-08-04

---

## 1. 总体架构：五条私信通道

```
                    ┌─────────────────────────────────────────────────�?                    �?                TikTok 私信                      �?                    └───────────┬──────────────────┬──────────────────�?                                �?                 �?             ┌──────────────────┴─────�?   ┌───────┴─────────────────�?             �? 浏览器模拟通道           �?   �? 协议通道（直�?中转�?     �?             �? WebView2 自动�?       �?   └──┬──────┬──────┬───────�?             �? (TikTokImTask 之上)    �?      �?     �?     �?             └────────────────────────�?  ┌───┴┐  ┌─┴──�?┌─┴────�?                                         │通道一�? │通道二│ │通道�?�?                                         │Android�? �?Web �?│中转API�?                                         │直�?  �? │直�? �?│服务器 �?                                         └──────�? └─────�?└──┬───�?                                                              �?                                                         ┌────┴───�?                                                         �?通道�? �?                                                         �?服务器端�?                                                         �?代跑任务�?                                                         └────────�?```

| 通道 | UI 页面 | 调度任务 | 实现服务 | 技术形�?|
|---|---|---|---|---|
| 模拟通道 | Touch（触达）/ Im 内嵌 | `TikTokTouchTask` | `TikTokTouchService` + 浏览�?| WebView2 模拟点击，稳定慢�?|
| 通道一 | `Im.cs` "协议群发→通道一" | `TikTokImTask` | `TikTokImProtocolService` + `ImAndroidApiClient` | 直连 App �?WSS，aid=1233 |
| 通道�?| `Im.cs` "协议群发→通道�? | `TikTokImTask` | `TikTokImProtocolService` + `ImWebApiClient` | 直连 Web �?WSS，aid=1988 |
| 通道�?| `Im3.cs` "协议群发（通道三）" | `TikTokImApiTask` | `TikTokImApiService` | **第三方中�?HTTP API**（厂商服务器�?|
| 通道�?| `Im4.cs` "协议群发（通道4，仅供测试）" | 直接调用 | `TikTokImProxyService` | **第三方服务器端代跑任�?*（x-api-key�?|

---

## 2. 通道一/二：直连协议（TikTokImProtocolService�?
### 2.1 链路

```
TikTokImProtocolService.SendAsync(ImProtocolSendOptions)
  ├─ 校验: Senders/Receivers 非空、Parameters.Validate()
  ├─ CreateTasks(): 每个发送账�?= 1 �?ImTaskState
  �?   ├─ 接收者队列轮询分�?(Round-Robin)，每个账号上�?MaxSentCount
  �?   ├─ 代理轮询分配 (WebProxy)
  �?   └─ 试用模式: 只取 1 个发送账�?+ 3 个接收�?  ├─ Parallel.ForEachAsync(并发�?MaxDegreeOfParallelism)
  �?   └─ 每个 ImTaskState 遍历自己�?Receivers:
  �?        SendAsync(receiver):
  �?          ├─ 选客户端: UseWebProtocol ? ImWebApiClient : ImAndroidApiClient
  �?          ├─ ConnectAsync()  �?WSS 建连
  �?          ├─ CreateConversationAsync() �?创建会话 (Type 609)
  �?          ├─ SendTextAsync() / SendLinkAsync() / SendVideoAsync()
  �?          �?  / SendStickerAsync() / SendHomePageAsync()
  �?          └─ DisconnectAsync()
  └─ 结果 �?TikTokImMessageSentEvent �?MessageQueue �?异步写库
```

### 2.2 ImAndroidApiClient（通道一�?
- 来源账号字段：`Cookie / StoreIdc / DeviceId / QueryParameters / UserAgent / Sid / TikTokId`
- 连接：`wss://{TikTokDomains.GetWssDomain(idc)}/ws/v2?...`
  - 域名映射：`useast5/useast8 �?frontier.tiktokv.us`；`useast2a �?frontier.tiktokv.eu`；`alisg/maliva/默认 �?frontier.tiktokv.com`
  - 子协�?`pbbp`；UA `okhttp/3.12.13.4-tiktok` 或账号自�?UA
  - 默认参数模拟：Samsung SM-G9900、Android 12、`app_name=musical_ly`、`aid=1233`、`ab_version=31.7.3`、`access_key` �?- 会话：Type 609 创建会话（`Ps = [uid, to]`�?- 发文本：先发 Type 411（发消息预请求，收到 411 响应�?pre-ok），�?Type 100�?  `{"isDefault":false,"text":"...","is_card":false,"sendStartTime":...,"aweType":700}`
- 发视�?图片/主页卡片/链接卡：Type 100 + **LZ4 压缩**（`K4os.Compression.LZ4`，`AppImLz4Request`�?- 消息类型：文�?JSON content)、图�?贴纸=5、视�?8、主页卡�?25、链接卡=26
- 超时 10s；`access_key = MD5("9e1bd35ec9db7b8d846de66ed140b1ad9" + deviceId + "f8a69f1719916z")` 小写

### 2.3 ImWebApiClient（通道二）

- 来源账号字段：`Cookie(ttwid/msToken 必须存在) / DeviceId / TikTokId`
- 连接：`wss://im-ws.tiktok.com/ws/v2?aid=1459&fpid=9&access_key=...&ttwid=...&Web-Sdk-Ms-Token=...`
  - 子协�?`binary/base64/pbbp`；Edge 129 UA；Origin https://www.tiktok.com
- 请求参数集合 DefaultParameters 完整模拟 Web 端（aid=1988, device_platform=web_pc, region=JP, priority_region=US, msToken 注入等）
- 会话 Type 609；发�?Type 100�?*不压�?*
- 响应匹配�?`Sn` 序号；接收超�?50s

### 2.4 错误处理（两个直连客户端共用逻辑�?
| 错误来源 | 判定 | 结果 |
|---|---|---|
| 连接异常 | SSL �?"可能是网络环境较差导�?ssl)"；WSS �?"wss" 提示 | 该接收者失�?|
| 创建会话 | status="200001" �?"CK失效" | 抛出 |
| 发送状态码 | 见下�?| `ImSendMessageResult(Terminate/Quit)` |

状态码表（`status_code`，通道一二三通用）：

| �?| 中文提示 | Terminate | Quit |
|---|---|---|---|
| 7174/7178/7192 或提示含 "3 messages"/"最多发�?�? | **视为成功**（陌生会�?3 条上限达成） | - | - |
| 7180 / "too fast" | 消息发送过�?| �?| ✓（整任务退出） |
| 7175 | 已达到聊天消息限�?| �?| |
| 7195 | 违反《社区自律公约�?| �?| |
| 7278 / "contact has been suspended" | 对方账号已停�?| �?| |
| 7282 | 只有好友才能互相发送消�?| �?| |
| 7283 / "receiver's settings"/"privacy settings" | 对方设置/隐私限制 | �?| |
| 7289 | 账号疑似被停�?| �?| |
| 7290 / "Due to multiple Community" | 对方多次违规 | �?| |
| 7409 | 现在无法与该用户聊天 | �?| |

---

## 3. 通道三：外部中转 API（TikTokImApiService�?
**重要：不直连 TikTok，全部请求转发给厂商中转服务�?*

```
POST http://137.175.124.165:7788/tiok/v2/message/cx/send
Body: {
  "accountData": <发送账�?�?     // 疑似为账号数据标识（Cookie 序列�?账号 ID�?  "userId": <接收�?uid>,
  "proxy":  "socks5://..."�?      // 缺省时使用硬编码住宅代理
  "sendType": 1|2|3|4|5,           // 1文本 2链接�?3视频 4图片 5主页�?  "message" / "cardLinkUrl"+"cardTitle"+"cardCoverUrl"+"cardDesc"
  / "videoId" / "imageUrl" / "homePageUserId"
}
响应: { code, success, data: { body6: { body100: { status, errorDesc } } } }
  status==0 �?成功；errorDesc �?status_code �?§2.4 错误码表
```

- **硬编码默认代�?*（未配置代理时使用，住宅代理池）�?  `90156752-zone-custom-region-gb-sessid-%s-sessTime-10:EcgAtaqE@f.proxys5.net:6200`
  （socks5 变体在另一处硬编码 `socks5://90156752-zone-custom-region-GB-...`�?- 通道三的发送顺序：视频 �?图片 �?主页�?�?链接�?�?文本（与通道一二相反）
- 依赖 `state.IsTrial`：试�?1 账号 + 3 接收�?- 历史遗留：异常信息中�?strip `39.108.58.156:7788`（旧中转地址�?
---

## 4. 通道四：服务器端代跑任务（TikTokImProxyService�?
```
客户�?                             厂商服务�?(137.175.124.165:48088)
  �? x-api-key: <用户ApiKey>
  ├─ POST /admin-api/tiktok/message/api/create
  �?   { proxy, uidList(按行分隔), sendTxt/sendCard/sendImg/sendVideo/sendHp } �?taskId
  ├─ POST .../start?id={taskId}      启动
  ├─ POST .../interrupt?id={taskId}  停止
  └─ GET  .../page?pageNo=1&pageSize=10  查询汇�?�?轮询刷新成功/失败�?```

- **发送在服务器端执行**，客户端只提交任�?+ 轮询状态；发送账号信息只体现�?proxy 上（即：服务器用你的代理+APIKey 所属账号体系发送）
- 任务实体 `TikTokImProxyTask`（含 ApiKey、TaskId、Total/Success/Failure、IsCompleted），接收者明�?`TikTokImProxyTaskReceiver`
- 本地无发送线程，UI（Im4）只做创�?刷新/停止/删除

---

## 5. 浏览器模拟通道（触达）

- `TikTokTouchService.CreateTask()` �?`TikTokTouchTask`（每账号一个浏览器实例�?- 触达动作组合�?*关注 + 首页点赞 + 收藏 + 转贴 + 评论 + 私信**，可自由勾�?- 私信文本支持多话术随机（`Messages`）、追加当前时间、追加随机表情、@博主/@指定用户
- 浏览器池 "tiktok" 30 实例，InPrivate、隐�?WebRTC、禁用语言/时区跟随 IP

---

## 6. 强私筛选（可私信判定）

```
TikTokScreeningUserChatTask ("筛选强�?)
  ├─ �?ChatScreenings 表读取待筛列表（可按 Status 重筛已完�?失败�?  ├─ 校验采集 Cookie（CheckCookieAsync�?  ├─ �?N 组并行（MaxDegreeOfParallelism�?  └─ 每目标调�?
     TikTokApiService.CheckImPermissionAsync(fromUid, toUid, cookie, idc)

GET https://{apiDomain}/tiktok/v1/im/chat/notice/
    ?to_user_id={toUid}&conversation_id=0%3A1%3A{toUid}%3A{fromUid}
    &source_type=dm_chat&aid=1233&app_name=musical_ly&version_code=250203
    （Cookie + sdk-version:2，SSL 证书校验关闭，失败重�?2 次）

判定:
  notice_code �?"chat_stranger_check" �?可发 3 条（MaxMessageCount=3�?  notice_code �?"chat_request_start" �?可发 1 条（=1�?  其他/null                     �?不可私信�?0�?```

- 结果写入 `TikTokChatScreeningItem`（IsChatabled / MaxMessageCount / Status�?- 筛选后可直接作为私信任务目标列表（"筛选结�?�?触达"漏斗�?
---

## 7. 数据模型（EF Core�?
| 实体 | �?| 关键字段 |
|---|---|---|
| `TikTokImMessage` | ImMessages | TaskId, SenderId, ReceiverId, ProtocolType(1=Android,2=Web), MessageStatus/LinkCardStatus/VideoCardStatus/PictureCardStatus/HomePageStatus (bool?), �?Error, Quit, WhenSent |
| `TikTokImApiMessage` | ImApiMessages | 同上（通道三） |
| `TikTokImProxyTask` | ImProxyTasks | ApiKey, TaskId, Total, Success, Failure, IsCompleted |
| `TikTokChatScreeningItem` | ChatScreenings | Key(目标uid), MaxMessageCount, IsChatabled, Status |
| `TikTokAccount` | �?| TikTokId, DeviceId, StoreIdc, XToken, UserAgent, Sid, QueryParameters, CookieData |

写库策略：`MessageQueue<T>` 异步队列落库（不阻塞发送线程），异常静默吞掉�?
---

## 8. 关键发现与风险点（迭代必读）

1. **通道�?�?短链完全依赖厂商中转服务�?*�?   - `137.175.124.165:7788`（发消息）、`39.108.58.156:7788`（短�?旧发消息）、`137.175.124.165:48088`（代跑任务）
   - 服务器下�?限流 �?通道三、四、短链全部失效�?*自建替代中转是首要降风险�?*
2. **硬编码住宅代理凭�?*（`proxys5.net` 账号密码内嵌在通道三代码中）—�?属于厂商资产，若脱离厂商需替换为自己的代理�?3. **SSL 证书校验关闭**（强私筛�?HTTP 客户�?`DangerousAcceptAnyServerCertificateValidator`）—�?MITM 风险，迭代时应替换为证书固定
4. **试用模式 `FakeSendAsync`**：试用账号走随机假成�?失败，不真实发�?5. **状态码 7174/7178/7192 视为成功**：这�?陌生 3 条上�?的达成判定，是产品特性不�?bug
6. **任务隔离薄弱**：`TikTokImProtocolService`/`TikTokImApiService` 是单例且 `IsRunning` 互斥——同一时间只能跑一个任务（UI �?当前正在运行"）；多任务并发需重构为实例化任务对象
7. 发送速度控制：`IntervalSeconds`（任务级�? `MaxSentCount`（每账号上限�? `MaxFialedCount`（失败退出）+ 7180 触发整任�?Quit

---

## 9. 迭代建议（按优先级）

| # | 方向 | 理由 |
|---|---|---|
| 1 | 通道三自建中转（或迁移到直连通道一/二） | 消除单点依赖 + 硬编码凭�?|
| 2 | 私信服务去单例化，支持多任务并发 | 当前 IsRunning 互斥限制产能 |
| 3 | 错误处理统一枚举化（现为散落字符串） | 便于统计各失败原因分�?|
| 4 | 强私筛选补证书固定 + 代理复用 | 安全 + 减少 IP 风控 |
| 5 | 补模拟通道与协议通道的自动降级（失败自动切换�?| 通道失效时兜�?|
| 6 | 发送成功率/错误分布的可观测性（遥测表） | 为迭代决策提供数�?|

---

## 10. 代码索引（对应反编译源文件）

| 组件 | 路径（OmniMaketDev/decompiled/Juytu.OmniMarket.TikTok/ 下） |
|---|---|
| 通道一/二编�?| `Juytu.OmniMarket.TikTok.Services/TikTokImProtocolService.cs` |
| Android 客户�?| `Juytu.OmniMarket.TikTok.Services.Internal/ImAndroidApiClient.cs` |
| Web 客户�?| `Juytu.OmniMarket.TikTok.Services.Im.Internal/ImWebApiClient.cs`、`IImApiClient.cs` |
| access_key/序列�?| `Juytu.OmniMarket.TikTok.Services.Im.Internal/ImUtils.cs` |
| 通道�?| `Juytu.OmniMarket.TikTok.Services/TikTokImApiService.cs` |
| 通道�?| `Juytu.OmniMarket.TikTok.Services/TikTokImProxyService.cs` + `TikTokImProxyApiClient.cs` |
| 短链 | `Juytu.OmniMarket.TikTok.Services/TikTokShorterLinkGenerator.cs` |
| 强私筛�?| `Juytu.OmniMarket.TikTok.Automation.Tasks/TikTokScreeningUserChatTask.cs` + `TikTokApiService.cs`(CheckImPermissionAsync, L4712) |
| 触达 | `Juytu.OmniMarket.TikTok.Services/TikTokTouchService.cs` + `Automation.Tasks/TikTokTouchTask.cs` |
| 签名算法 | `Juytu.OmniMarket.TikTok.Services.Internal/XBogus.cs`、`XGnarly.cs`（内�?xbogus.js�?|
| 协议 DTO | `Juytu.OmniMarket.TikTok.Services.Im.Contracts/`（AppIm*/WebIm* 33 文件�?|
| 域名�?| `Juytu.OmniMarket.TikTok.Services/TikTokDomains.cs` |
| UI | `Juytu.OmniMarket.TikTok.Components/Im.cs`(通道一�?、`Im3.cs`、`Im4.cs`、`Touch.cs` |

---

# ��¼ A: ͨ���� Web �������򲹳䣨ttdm M6, 2026-08 ʵ�⣩

> ��Դ: ttdm ��Ŀ M6-3/4 ��ʵץ�� + �ط�ʵ�飨ttdm/bin/m6/, CDP ץ�� send_body.txt / sign_snapshot.json / decodeframe ���룩

## A.1 ���Ͷ˵������

send_text = POST `https://im-api.tiktok.com/v1/message/send`

�̶�����˳��������� URL ���ֽ�һ��, ǩ��ֵ���� URL ת�壩:

```
aid=1988 & version_code=1.0.0 & app_name=tiktok_web & device_platform=web_pc
& X-Dynosaur=<ǩ��> & msToken=<token> & X-Bogus=1 & X-Gnarly=<ǩ��>
```

- ǩ��ֵ��δת�� `+/=`; �� url.Values.Encode()����ĸ������+ת�壩��ǩ��У��ʧ�� �� ��Ĭ 204
- ǩ��������� webmssdk.js 2.0.0.514 ����, ���ո�����Ч���طŷ��� 200+7193 ҵ����Ӧ����ǩ���ܾ���

## A.2 body protobuf �ֶ���

| �ֶ� | ֵ |
|---|---|
| f1 | 100 |
| f2 | 10033 |
| f3 | "1.7.0" |
| f8.f100 | conv_id "0:1:{toUID}:{selfUID}", f2=1, f3=19λ�����, f4=`{"aweType":0,"text":"..."}`, f5 KV(s:mentioned_users / s:client_message_id), f8=clientMsgID |
| f9 | device_id |
| f11 | "web" |
| f15 | 28 ���豸/������ KV��aid/verifyFp/Web-Sdk-Ms-Token/tt-ticket-guard-* ��, ���ո��ü��ɣ� |
| f18 | 1 |

## A.3 ��Ӧ���壨2026-08 ʵ�⣩

- **204**: ����˾�Ĭ��Ӧ���������������ͬ�����֣�ץ�� id=102 �յ� 204��, �ݵ�/����ȥ��, ��Ϊ����
- **200**: protobuf ҵ����Ӧ�ŷ� f3=0 / f4="OK" / f6{f100{f6=JSON}}:
  - status_code=0 �� �ɹ�, �����������Ϣ ID
  - status_code=7193 �� scene="message_request_limit": �Է�δ������Ϣ����, ���ܷ�����������
- ���ش���: 200001��ȱǩ��/�� POST��/ 200005��ȱ cookies��, 55B protobuf f1=100/f3=200001/f4="200001"

## A.4 �������

- `ttdm/internal/protocol/websend.go`: BuildWebSendURL��ԭʼ��ʽ��ת�壩/ BuildWebSendBody / SendWebText / parseWebSendResponse��Web �ŷ� f6.f100.f6 JSON��
- ���������ץ��·��: ҳ�� hook XHR + CDP Network events��ttdm/bin/m6/send_body.txt��