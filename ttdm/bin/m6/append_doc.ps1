$f = "d:\MyProjects\OmniMarket\docs\TIKTOK-DM-FLOW.md"
$enc = [System.Text.Encoding]::GetEncoding(936)
$content = [System.IO.File]::ReadAllText($f, $enc)
$appendix = @'

---

# 附录 A: 通道二 Web 发送逆向补充（ttdm M6, 2026-08 实测）

> 来源: ttdm 项目 M6-3/4 真实抓包 + 重放实验（ttdm/bin/m6/, CDP 抓包 send_body.txt / sign_snapshot.json / decodeframe 解码）

## A.1 发送端点与参数

send_text = POST `https://im-api.tiktok.com/v1/message/send`

固定参数顺序（与浏览器 URL 逐字节一致, 签名值不做 URL 转义）:

```
aid=1988 & version_code=1.0.0 & app_name=tiktok_web & device_platform=web_pc
& X-Dynosaur=<签名> & msToken=<token> & X-Bogus=1 & X-Gnarly=<签名>
```

- 签名值含未转义 `+/=`; 用 url.Values.Encode()（字母序排序+转义）会签名校验失败 → 静默 204
- 签名由浏览器 webmssdk.js 2.0.0.514 生成, 快照复用有效（重放返回 200+7193 业务响应而非签名拒绝）

## A.2 body protobuf 字段树

| 字段 | 值 |
|---|---|
| f1 | 100 |
| f2 | 10033 |
| f3 | "1.7.0" |
| f8.f100 | conv_id "0:1:{toUID}:{selfUID}", f2=1, f3=19位随机数, f4=`{"aweType":0,"text":"..."}`, f5 KV(s:mentioned_users / s:client_message_id), f8=clientMsgID |
| f9 | device_id |
| f11 | "web" |
| f15 | 28 项设备/上下文 KV（aid/verifyFp/Web-Sdk-Ms-Token/tt-ticket-guard-* 等, 快照复用即可） |
| f18 | 1 |

## A.3 响应语义（2026-08 实测）

- **204**: 服务端静默响应。浏览器本机发送同样出现（抓包 id=102 收到 204）, 幂等/限流去重, 视为接受
- **200**: protobuf 业务响应信封 f3=0 / f4="OK" / f6{f100{f6=JSON}}:
  - status_code=0 → 成功, 服务端生成消息 ID
  - status_code=7193 → scene="message_request_limit": 对方未接受消息请求, 仅能发送有限条数
- 网关错误: 200001（缺签名/裸 POST）/ 200005（缺 cookies）, 55B protobuf f1=100/f3=200001/f4="200001"

## A.4 工程落点

- `ttdm/internal/protocol/websend.go`: BuildWebSendURL（原始格式不转义）/ BuildWebSendBody / SendWebText / parseWebSendResponse（Web 信封 f6.f100.f6 JSON）
- 浏览器本机抓包路径: 页面 hook XHR + CDP Network events（ttdm/bin/m6/send_body.txt）
'@
[System.IO.File]::WriteAllText($f, $content + $appendix, $enc)
Write-Host "appended, new size: $((Get-Item $f).Length)"
