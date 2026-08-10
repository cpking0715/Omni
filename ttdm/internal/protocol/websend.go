package protocol

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// Web 通道二发送层 (M6-3 抓包逆向成果, 2026-08; M6-4 签名必要性实测, 2026-08-09):
//
//	send_text = POST https://im-api.tiktok.com/v1/message/send
//	  ?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc
//	  [&X-Dynosaur=<签名>&msToken=<token>&X-Bogus=1&X-Gnarly=<签名>]  ← 可选
//	body = protobuf (字段树见 BuildWebSendBody), 响应: 204=服务端静默响应
//	(浏览器抓包同样会收到, 幂等/限流去重, 视为成功);
//	200=protobuf {status_code, tips} 业务响应 (如 7193 消息请求限制)。
//
// 签名参数由浏览器 webmssdk.js 2.0.0.514 生成。M6-4 三变体对照实测
// (out_pat1_conclusion.json A~J): 无签名 / 假签名(X-Bogus=1 占位) / 真签名
// (frontierSign) / 快照三件套 对同一接收方返回逐字节一致的业务码 (7193
// 消息请求限制 / 7195 内容审核), 签名对 message/send 完全非必需——URL 签名
// 参数可省略, 签名快照仅为可选兼容路径。

// WebSignParams 是 message/send URL 上的三个签名参数。
type WebSignParams struct {
	XDynosaur string `json:"x_dynosaur"`
	MSToken   string `json:"ms_token"`
	XGnarly   string `json:"x_gnarly"`
}

// WebSendMeta 是 body f15 KV 中随设备/上下文变化的字段快照
// (由浏览器页面抓取, 复用即可, 实测服务端校验宽松)。
type WebSendMeta struct {
	VerifyFP             string `json:"verify_fp"`
	WebSDKMsToken        string `json:"web_sdk_ms_token"`
	TicketGuardPublicKey string `json:"ticket_guard_public_key"`
	TicketGuardClientData string `json:"ticket_guard_client_data"`
	BrowserVersion       string `json:"browser_version"`
	UserAgent            string `json:"user_agent"`
	ScreenWidth          string `json:"screen_width"`
	ScreenHeight         string `json:"screen_height"`
	TzName               string `json:"tz_name"`
}

// WebSignSnapshot 是完整签名快照 (URL 签名 + body 元数据), JSON 可序列化,
// 由抓包工具 (debug wssnap) 或人工从浏览器捕获生成。
type WebSignSnapshot struct {
	Sign      WebSignParams `json:"sign"`
	Meta      WebSendMeta   `json:"meta"`
	CapturedAt string       `json:"captured_at"`
}

// ErrWebSignMissing 表示缺少签名快照。
// 注: M6-4 实测 (2026-08-09) 签名对 message/send 非必需, 无签名直连即可;
// 该错误仅在调用方显式要求签名路径 (SetWebSign 语义) 时保留, 发送不再依赖。
var ErrWebSignMissing = errors.New("缺少 Web 签名快照 (webmssdk 签名, 需从已登录浏览器抓取)")

// webSendEndpoint 为 message/send 的固定端点 (单测替换为 httptest server)。
var webSendEndpoint = "https://im-api.tiktok.com"

// BuildWebSendURL 拼接 message/send URL。sign 为空值时输出无签名裸 URL
// (M6-4 实测 2026-08-09: 无签名直连即可, 服务端不校验签名); 非空时输出
// 带签名参数的完整 URL。
//
// 参数顺序与浏览器发出的原始 URL 完全一致, 签名值不做 URL 转义:
// 实测 (2026-08 真实环境) 用 url.Values.Encode() 的字母序排序 + 转义
// (如 +→%2B、=→%3D) 发送时服务端签名校验失败, 静默返回 204 无 body;
// 改用原始格式后返回 200 + 业务 protobuf (如 7193 消息请求限制)。
func BuildWebSendURL(sign WebSignParams) string {
	if sign.XDynosaur == "" && sign.XGnarly == "" {
		return webSendEndpoint + "/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc"
	}
	return webSendEndpoint + "/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc" +
		"&X-Dynosaur=" + escapeWebSignValue(sign.XDynosaur) +
		"&msToken=" + escapeWebSignValue(sign.MSToken) +
		"&X-Bogus=1" +
		"&X-Gnarly=" + escapeWebSignValue(sign.XGnarly)
}

// escapeWebSignValue 只转义 query 分隔符 (& # %), 保留 webmssdk 签名原始字符
// (+ / = 及 base64url 字母), 与浏览器 URL 字节一致。
func escapeWebSignValue(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 8)
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '%':
			b.WriteString("%25")
		case '&':
			b.WriteString("%26")
		case '#':
			b.WriteString("%23")
		default:
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

// BuildWebSendBody 构造 message/send 的 protobuf body (M6-3 抓包字段树):
//
//	f1=100 f2=10033 f3="1.7.0" f4={} f5=3 f6=3 f7="3035f17:feat/call-trace-plugin"
//	f8 { f100 {
//	    f1=conversation_id "0:1:{toUID}:{selfUID}"
//	    f2=1  f3=随机19位(消息序号/随机数)  f4=`{"aweType":0,"text":"..."}`
//	    f5 {f1:"s:mentioned_users", f2:""}
//	    f5 {f1:"s:client_message_id", f2:"{uuid}"}
//	    f6=7 f7="deprecated" f8="{uuid}"
//	} }
//	f9=device_id f11="web"
//	f15 重复 KV (设备/上下文元数据, 含 aid/verifyFp/Web-Sdk-Ms-Token/tt-ticket-guard-*)
//	f18=1
func BuildWebSendBody(selfUID, toUID int64, deviceID, text, clientMsgID string, meta WebSendMeta) []byte {
	var conv encoder
	conv.str(1, "0:1:"+strconv.FormatInt(toUID, 10)+":"+strconv.FormatInt(selfUID, 10))
	conv.varint(2, 1)
	conv.varint(3, random19Digit())
	conv.str(4, fmt.Sprintf(`{"aweType":0,"text":"%s"}`, EscapeJSONString(text)))

	var mentioned encoder
	mentioned.str(1, "s:mentioned_users")
	mentioned.str(2, "")
	conv.msg(5, mentioned.b)

	var cmid encoder
	cmid.str(1, "s:client_message_id")
	cmid.str(2, clientMsgID)
	conv.msg(5, cmid.b)

	conv.varint(6, 7)
	conv.str(7, "deprecated")
	conv.str(8, clientMsgID)

	var core encoder
	core.msg(100, conv.b)

	var f encoder
	f.varint(1, 100)
	f.varint(2, 10033)
	f.str(3, "1.7.0")
	f.msg(4, nil)
	f.varint(5, 3)
	f.varint(6, 3)
	f.str(7, "3035f17:feat/call-trace-plugin")
	f.msg(8, core.b)
	f.str(9, deviceID)
	f.str(11, "web")
	f.strMap(15, webSendKVs(deviceID, meta))
	f.varint(18, 1)
	return f.b
}

// webSendKVs 组装 f15 的设备/上下文 KV (抓包模板, 易变值由 meta 覆盖)。
func webSendKVs(deviceID string, meta WebSendMeta) map[string]string {
	ua := meta.UserAgent
	if ua == "" {
		ua = webChromeUA
	}
	sw := meta.ScreenWidth
	if sw == "" {
		sw = "1707"
	}
	sh := meta.ScreenHeight
	if sh == "" {
		sh = "1067"
	}
	ver := meta.BrowserVersion
	if ver == "" {
		ver = "5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
	}
	tz := meta.TzName
	if tz == "" {
		tz = "America/Los_Angeles"
	}
	return map[string]string{
		"aid":                          "1988",
		"app_name":                     "tiktok_web",
		"channel":                      "web",
		"device_platform":              "web_pc",
		"device_id":                    deviceID,
		"region":                       "US",
		"priority_region":              "US",
		"os":                           "windows",
		"referer":                      "https://www.tiktok.com/messages",
		"root_referer":                 "https://www.tiktok.com/messages",
		"cookie_enabled":               "true",
		"screen_width":                 sw,
		"screen_height":                sh,
		"browser_language":             "en-US",
		"browser_platform":             "Win32",
		"browser_name":                 "Mozilla",
		"browser_version":              ver,
		"browser_online":               "true",
		"verifyFp":                     meta.VerifyFP,
		"app_language":                 "en",
		"webcast_language":             "en",
		"tz_name":                      tz,
		"is_page_visible":              "true",
		"focus_state":                  "true",
		"is_fullscreen":                "false",
		"history_len":                  "14",
		"user_is_login":                "true",
		"data_collection_enabled":      "true",
		"from_appID":                   "1988",
		"locale":                       "en",
		"user_agent":                   ua,
		"Web-Sdk-Ms-Token":             meta.WebSDKMsToken,
		"tt-ticket-guard-public-key":   meta.TicketGuardPublicKey,
		"tt-ticket-guard-client-data":  meta.TicketGuardClientData,
		"tt-ticket-guard-version":      "2",
		"tt-ticket-guard-iteration-version": "0",
		"tt-ticket-guard-web-version":  "1",
	}
}

// random19Digit 生成 19 位随机正整数 (消息序号字段 f8.f100.f3, 实测服务端不校验具体值)。
func random19Digit() uint64 {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return uint64(time.Now().UnixNano()) // crypto/rand 失败时退化为时间戳
	}
	v := binary.BigEndian.Uint64(b[:])
	return 1_000_000_000_000_000_000 + v%9_000_000_000_000_000_000
}

// SendWebText 发送一条文本消息 (HTTP 协议层, 不依赖 WS 连接)。
// 返回 nil = 204 成功; 业务错误返回 *WebSendError (含 status_code)。
// M6-4 (2026-08-09) 实测: 签名对 message/send 非必需, 无签名直连即可;
// 注入签名快照时 (SetWebSign) 仍按原路径附带签名参数 (可选兼容)。
func (c *WebClient) SendWebText(ctx context.Context, toUID int64, text string, proxyURL string) (SendResult, error) {
	if c.account.UID == 0 {
		return SendResult{}, fmt.Errorf("账号 UID 为空, 无法构造会话 ID")
	}
	clientMsgID := newUUID()
	body := BuildWebSendBody(c.account.UID, toUID, c.deviceID, text, clientMsgID, c.signMeta())

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, BuildWebSendURL(c.signParams()), bytes.NewReader(body))
	if err != nil {
		return SendResult{}, fmt.Errorf("构造发送请求失败: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-protobuf")
	req.Header.Set("Origin", webOrigin)
	req.Header.Set("Referer", webOrigin+"/messages")
	req.Header.Set("User-Agent", webChromeUA)
	if c.account.CookieString() != "" {
		req.Header.Set("Cookie", c.account.CookieString())
	}

	client := c.httpClient(proxyURL)
	resp, err := client.Do(req)
	if err != nil {
		return SendResult{}, fmt.Errorf("发送请求失败: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	switch resp.StatusCode {
	case http.StatusNoContent: // 204 = 服务端静默响应 (浏览器抓包同样出现, 幂等/限流去重), 视为接受
		return Success, nil
	case http.StatusOK: // 200 = protobuf 业务响应
		return parseWebSendResponse(raw), nil
	default:
		return SendResult{Terminate: true}, &WebSendError{
			Status: resp.StatusCode,
			Msg:    fmt.Sprintf("HTTP %d", resp.StatusCode),
		}
	}
}

// WebSendError 是 HTTP 层错误 (非业务 protobuf 响应)。
type WebSendError struct {
	Status int
	Msg    string
}

func (e *WebSendError) Error() string { return e.Msg }

// parseWebSendResponse 解析 200 + protobuf 业务响应。
//
//	实测 Web 响应信封 (2026-08 真实环境):
//	  f3 = raw_check_code (0=OK)
//	  f4 = "OK"
//	  f6 { f100 { f6 = `{"status_code":7193,"scene":"message_request_limit",...}` } }
//	历史 Android 信封 f2 { f1=status_code f2=status_msg } 仍兼容。
func parseWebSendResponse(raw []byte) SendResult {
	p := &parser{data: raw}
	for !p.eof() {
		field, wt, err := p.next()
		if err != nil {
			break
		}
		if wt != wtLen {
			_ = p.skip(wt)
			continue
		}
		inner, err := p.lengthBytes()
		if err != nil {
			break
		}
		switch field {
		case 2: // Android 信封: {f1=status_code, f2=status_msg}
			return parseWebSendStatus(inner)
		case 6: // Web 信封: 递归找 f100.f6 JSON
			if r := parseWebEnvelope(inner); r != nil {
				return *r
			}
		}
	}
	// 无 status 字段: 视为成功 (与 204 等价)
	return Success
}

// parseWebEnvelope 递归查找 { f100 { f6 = JSON } } 结构。
func parseWebEnvelope(raw []byte) *SendResult {
	pp := &parser{data: raw}
	for !pp.eof() {
		field, wt, err := pp.next()
		if err != nil {
			break
		}
		if wt != wtLen {
			_ = pp.skip(wt)
			continue
		}
		s, err := pp.str()
		if err != nil {
			break
		}
		if field == 6 { // 内层 JSON: {"status_code":N,...}
			if code, ok := statusCodeFromJSON(s); ok {
				r := MapSendStatus(code, s)
				return &r
			}
		}
		if field == 100 {
			if r := parseWebEnvelope([]byte(s)); r != nil {
				return r
			}
		}
	}
	return nil
}

// statusCodeFromJSON 从 JSON 中提取 status_code 数值字段。
func statusCodeFromJSON(s string) (int, bool) {
	var m map[string]any
	if err := json.Unmarshal([]byte(s), &m); err != nil {
		return 0, false
	}
	v, ok := m["status_code"]
	if !ok {
		return 0, false
	}
	switch n := v.(type) {
	case float64:
		return int(n), true
	case string:
		if code, err := strconv.Atoi(n); err == nil {
			return code, true
		}
	}
	return 0, false
}

// parseWebSendStatus 解析 { f1=status_code varint, f2=status_msg JSON }。
func parseWebSendStatus(inner []byte) SendResult {
	code := 0
	tips := ""
	pp := &parser{data: inner}
	for !pp.eof() {
		field, wt, err := pp.next()
		if err != nil {
			break
		}
		switch {
		case field == 1 && wt == wtVarint:
			if v, err := pp.varint(); err == nil {
				code = int(v)
			}
		case field == 2 && wt == wtLen:
			if s, err := pp.str(); err == nil {
				tips = extractTips(s)
			}
		default:
			_ = pp.skip(wt)
		}
	}
	if code == 0 {
		return Success
	}
	return MapSendStatus(code, tips)
}

// extractTips 从 status_msg JSON 中提取 tips 文本 (兼容嵌套结构)。
func extractTips(s string) string {
	var m map[string]any
	if err := json.Unmarshal([]byte(s), &m); err != nil {
		return s
	}
	if msgContent, ok := m["msg_content"].(map[string]any); ok {
		if t, ok := msgContent["tips"].(string); ok {
			return t
		}
	}
	if t, ok := m["tips"].(string); ok {
		return t
	}
	return s
}

// httpClient 构造带代理的 HTTP 客户端 (与 WS dialer 共用代理解析)。
func (c *WebClient) httpClient(proxyURL string) *http.Client {
	if proxyURL == "" {
		proxyURL = SystemProxy()
	}
	tr := &http.Transport{}
	if proxyURL != "" {
		if u, err := url.Parse(proxyURL); err == nil {
			tr.Proxy = http.ProxyURL(u)
		}
	}
	return &http.Client{Transport: tr, Timeout: 30 * time.Second}
}

// SetWebSign 注入签名快照 (可选兼容路径; M6-4 实测发送不依赖签名)。
func (c *WebClient) SetWebSign(s *WebSignSnapshot) {
	c.sign = s
}

// signParams 返回 URL 签名参数 (未注入快照时为空, 走无签名直连)。
func (c *WebClient) signParams() WebSignParams {
	if c.sign == nil {
		return WebSignParams{}
	}
	return c.sign.Sign
}

// signMeta 返回 body 元数据快照 (未注入时为零值, 使用默认设备上下文)。
func (c *WebClient) signMeta() WebSendMeta {
	if c.sign == nil {
		return WebSendMeta{}
	}
	return c.sign.Meta
}

// WebSign 返回当前签名快照 (nil 表示未注入)。
func (c *WebClient) WebSign() *WebSignSnapshot { return c.sign }

// ParseWebSendResponseBody 解析原始响应字节 (导出, 供帧级单测)。
func ParseWebSendResponseBody(raw []byte) SendResult { return parseWebSendResponse(raw) }

// ExtractKV 从 protobuf body 提取 f15 KV (导出, 供抓包工具生成快照)。
func ExtractKV(body []byte) map[string]string {
	out := map[string]string{}
	p := &parser{data: body}
	for !p.eof() {
		field, wt, err := p.next()
		if err != nil {
			break
		}
		if field == 15 && wt == wtLen {
			inner, err := p.lengthBytes()
			if err != nil {
				break
			}
			pp := &parser{data: inner}
			k, v := "", ""
			for !pp.eof() {
				f2, wt2, err := pp.next()
				if err != nil {
					break
				}
				if wt2 != wtLen {
					_ = pp.skip(wt2)
					continue
				}
				s, err := pp.str()
				if err != nil {
					break
				}
				if f2 == 1 {
					k = s
				} else if f2 == 2 {
					v = s
				}
			}
			if k != "" {
				out[k] = v
			}
		} else {
			_ = p.skip(wt)
		}
	}
	return out
}

// kvToSnapshot 从 KV 提取 WebSendMeta (供抓包工具)。
func kvToSnapshot(kv map[string]string) WebSendMeta {
	return WebSendMeta{
		VerifyFP:              kv["verifyFp"],
		WebSDKMsToken:         kv["Web-Sdk-Ms-Token"],
		TicketGuardPublicKey:  kv["tt-ticket-guard-public-key"],
		TicketGuardClientData: kv["tt-ticket-guard-client-data"],
		BrowserVersion:        kv["browser_version"],
		UserAgent:             kv["user_agent"],
		ScreenWidth:           kv["screen_width"],
		ScreenHeight:          kv["screen_height"],
		TzName:                kv["tz_name"],
	}
}

// SnapshotFromBody 从捕获的 body + URL 构造签名快照 (抓包工具入口)。
func SnapshotFromBody(body []byte, fullURL string) *WebSignSnapshot {
	kv := ExtractKV(body)
	meta := kvToSnapshot(kv)
	sign := WebSignParams{}
	if u, err := url.Parse(fullURL); err == nil {
		q := u.Query()
		sign.XDynosaur = q.Get("X-Dynosaur")
		sign.MSToken = q.Get("msToken")
		sign.XGnarly = q.Get("X-Gnarly")
	}
	return &WebSignSnapshot{
		Sign:       sign,
		Meta:       meta,
		CapturedAt: time.Now().Format(time.RFC3339),
	}
}

// LoadWebSignSnapshot 从 JSON 文件加载签名快照。
func LoadWebSignSnapshot(path string) (*WebSignSnapshot, error) {
	raw, err := readFile(path)
	if err != nil {
		return nil, err
	}
	var s WebSignSnapshot
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, fmt.Errorf("解析签名快照失败: %w", err)
	}
	if s.Sign.XDynosaur == "" || s.Sign.XGnarly == "" {
		return nil, fmt.Errorf("签名快照缺少 X-Dynosaur/X-Gnarly")
	}
	return &s, nil
}

// LoadWebSignSnapshot 的底层文件读取 (拆出便于测试替换)。
var readFile = os.ReadFile
