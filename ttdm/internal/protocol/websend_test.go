package protocol

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"ttdm/internal/store"
)

// testWebClient 构造带签名快照的 WebClient (发送单测用)。
func testWebClient(t *testing.T) *WebClient {
	t.Helper()
	a := &store.Account{
		UID: 7664958044560016398,
		Cookies: []store.Cookie{
			{Name: "sessionid", Value: "sess123", Domain: ".tiktok.com"},
			{Name: "ttwid", Value: "tok-7319826453671301423-tok", Domain: ".tiktok.com"},
		},
	}
	c, err := NewWebClient(a)
	if err != nil {
		t.Fatalf("NewWebClient: %v", err)
	}
	c.SetWebSign(&WebSignSnapshot{
		Sign: WebSignParams{XDynosaur: "DYN", MSToken: "TOK", XGnarly: "GNAR"},
		Meta: WebSendMeta{VerifyFP: "verify_x", WebSDKMsToken: "wsdk"},
	})
	return c
}

func TestBuildWebSendURL(t *testing.T) {
	u := BuildWebSendURL(WebSignParams{XDynosaur: "D1", MSToken: "M1", XGnarly: "G1"})
	v, err := url.Parse(u)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if v.Path != "/v1/message/send" {
		t.Errorf("path = %q", v.Path)
	}
	q := v.Query()
	checks := map[string]string{
		"aid":              "1988",
		"version_code":     "1.0.0",
		"app_name":         "tiktok_web",
		"device_platform":  "web_pc",
		"X-Dynosaur":       "D1",
		"msToken":          "M1",
		"X-Bogus":          "1",
		"X-Gnarly":         "G1",
	}
	for k, want := range checks {
		if got := q.Get(k); got != want {
			t.Errorf("%s = %q, want %q", k, got, want)
		}
	}
}

// TestBuildWebSendURLNoSign 验证空签名输出无签名裸 URL (M6-4 实测 2026-08-09:
// 签名对 message/send 完全非必需, 无签名直连即可)。
func TestBuildWebSendURLNoSign(t *testing.T) {
	u := BuildWebSendURL(WebSignParams{})
	if strings.Contains(u, "X-Dynosaur") || strings.Contains(u, "X-Gnarly") ||
		strings.Contains(u, "X-Bogus") || strings.Contains(u, "msToken") {
		t.Errorf("空签名 URL 不应含签名参数: %s", u)
	}
	q, err := url.ParseQuery(strings.SplitN(u, "?", 2)[1])
	if err != nil {
		t.Fatalf("ParseQuery: %v", err)
	}
	for k, want := range map[string]string{
		"aid":             "1988",
		"version_code":    "1.0.0",
		"app_name":        "tiktok_web",
		"device_platform": "web_pc",
	} {
		if got := q.Get(k); got != want {
			t.Errorf("%s = %q, want %q", k, got, want)
		}
	}
}

// TestBuildWebSendURLRawSign 验证签名值保持原始字节不转义 (真实抓包格式):
// 服务端对 URL 做字节级签名校验, url.Values.Encode() 的转义 (+→%2B 等)
// 会导致校验失败静默 204, 故 URL 必须原样携带 +/=/ 等字符。
func TestBuildWebSendURLRawSign(t *testing.T) {
	sign := WebSignParams{
		XDynosaur: "MO-m/pHk4jJ868ZraN3owQXP/WdBEP4JCRgyYt1u16W0WMUSlRPDmBZLGUjo78qnjP0tXpSyuPx4YqKq2ep59ko2uHwfKUUvu52IvskV-ia-2eS7CH1IbRSQQI8RiyMpg7PplIC8W-wC6TT7Nf1/d-MKAEas5OQDNKdWRaqXmOwjicH6q-1bhWSZgvkpLXEATpcTvJ9cHBxF5jJNcregMcF7gymOjM/oTYNWXXSVJaVDXa3pnOFWHJSvRy4vUty1iMhuDnm2Mnrmrf1u0QxT9rRf/KSKcwtwpJILEs3c/AqfLkoOu4HDjiNCy8z4OKCSkukiZJjJW0iseESk0s8dDnTT5EkVdACx63OsXWCzrAZAeegSrkjRPKC5BCVMhg2JUzRC",
		MSToken:   "CrspTWZz7D3RBFsbg4DWBDN-PvlHvI1bqTraJKJdzrFMmOdYNmHVENrYRqnRc9BUF4KBVWKqtZr4pAqMrfyPyRFmafgL6T3eg_nXFu2ZSvO5RZtgMIdnOw51JPJSe_ScY1gqPKKRj-uwNhXaAp_0ymjXUU1OXVq2Yjs-WSu-kpA=",
		XGnarly:   "Ma4SfJGs--Y/1TC6umx7dIWAl9LrxBTBBLoM5sXQv/a1XvzNHO0W11aySFxKMV6GywAgtEaYdSlV2lcxPormdZmbqgEW-yxXqMlYIAd/4fQ9hK9Q9UjkcE2Git11Dsh-NOesOjQRwF1Dm7q-ln8rjnXGWeKm3G5vqtMmT-r3S-SwL4FDzg75yQRtfDTkJbXNfJY9MXqQT0jg6W6wgIBW9KKSfBOdeX6sHQBXgJO6SbQoFIheGG5G7xoFEKj0EJ18Mkxeyf4v6EI3XS-3Lv-aMo3bI/y/X-HTCILmDRV1yCgCS8lYJYORXJ1E6NyLG/zgDL40-cMRgWOF",
	}
	u := BuildWebSendURL(sign)
	// 1. 参数顺序固定: 固定参数后紧跟 X-Dynosaur, 签名值未转义
	prefix := "/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc&X-Dynosaur="
	if !strings.HasPrefix(u, webSendEndpoint+prefix) {
		t.Fatalf("URL 开头不符: %s", u[:min(len(u), 160)])
	}
	// 2. 签名值原样出现在 URL 中 (+ / = 不转义)
	for _, want := range []string{sign.XDynosaur, sign.MSToken, sign.XGnarly} {
		if !strings.Contains(u, want) {
			t.Errorf("签名值被转义或缺失: %q", want[:min(len(want), 40)])
		}
	}
	if strings.Contains(u, "%2B") || strings.Contains(u, "%2F") || strings.Contains(u, "%3D") {
		t.Errorf("URL 含转义签名: %s", u[len(u)-120:])
	}
	// 3. msToken 以 = 结尾时解析仍取回原值 (值内含 = 合法)
	q, err := url.ParseQuery(strings.SplitN(u, "?", 2)[1])
	if err != nil {
		t.Fatalf("ParseQuery: %v", err)
	}
	if got := q.Get("msToken"); got != sign.MSToken {
		t.Errorf("msToken = %q, want %q", got, sign.MSToken)
	}
}

// decodeSendBodyCore 提取 body f8.f100 核心消息块。
func decodeSendBodyCore(t *testing.T, body []byte) []byte {
	t.Helper()
	p := &parser{data: body}
	f8, ok, err := p.findLen(8)
	if err != nil || !ok {
		t.Fatalf("body f8 missing: %v", err)
	}
	p2 := &parser{data: f8}
	core, ok, err := p2.findLen(100)
	if err != nil || !ok {
		t.Fatalf("f8.f100 missing: %v", err)
	}
	return core
}

func TestBuildWebSendBodyStructure(t *testing.T) {
	const (
		selfUID  = 7664958044560016398
		toUID    = 7366359960223482885
		deviceID = "7319826453671301423"
	)
	body := BuildWebSendBody(selfUID, toUID, deviceID, "hello 世界", "uuid-1", WebSendMeta{VerifyFP: "vf"})

	// 顶层字段
	p := &parser{data: body}
	if v, _, _ := p.findVarint(1); v != 100 {
		t.Errorf("f1 = %d, want 100", v)
	}
	if v, _, _ := p.findVarint(2); v != 10033 {
		t.Errorf("f2 = %d, want 10033", v)
	}
	if s, _, _ := p.findStr(3); s != "1.7.0" {
		t.Errorf("f3 = %q", s)
	}
	if s, _, _ := p.findStr(9); s != deviceID {
		t.Errorf("f9 = %q", s)
	}
	if s, _, _ := p.findStr(11); s != "web" {
		t.Errorf("f11 = %q", s)
	}
	if v, _, _ := p.findVarint(18); v != 1 {
		t.Errorf("f18 = %d", v)
	}

	// f8.f100 核心
	core := decodeSendBodyCore(t, body)
	cp := &parser{data: core}
	if cid, _, _ := cp.findStr(1); cid != "0:1:7366359960223482885:7664958044560016398" {
		t.Errorf("conv id = %q", cid)
	}
	if v, _, _ := cp.findVarint(2); v != 1 {
		t.Errorf("core f2 = %d", v)
	}
	if v, ok, _ := cp.findVarint(3); !ok || v < 1000000000000000000 {
		t.Errorf("core f3 random id = %d (ok=%v)", v, ok)
	}
	content, _, _ := cp.findStr(4)
	if !strings.Contains(content, `"aweType":0`) || !strings.Contains(content, `"text":"hello 世界"`) {
		t.Errorf("core f4 = %q", content)
	}
	// f8 与 f5 扩展: client_message_id (先查 f8, 再遍历 f5)
	if s, _, _ := cp.findStr(8); s != "uuid-1" {
		t.Errorf("core f8 = %q", s)
	}
	cp = &parser{data: core}
	foundCMID := false
	for !cp.eof() {
		field, wt, err := cp.next()
		if err != nil {
			break
		}
		if field == 5 && wt == wtLen {
			inner, err := cp.lengthBytes()
			if err != nil {
				break
			}
			ep := &parser{data: inner}
			k, _, _ := ep.findStr(1)
			v, _, _ := ep.findStr(2)
			if k == "s:client_message_id" && v == "uuid-1" {
				foundCMID = true
			}
		} else {
			_ = cp.skip(wt)
		}
	}
	if !foundCMID {
		t.Error("core lacks s:client_message_id entry")
	}

	// f15 KV
	kv := ExtractKV(body)
	for _, k := range []string{"aid", "app_name", "device_platform", "device_id", "verifyFp", "Web-Sdk-Ms-Token", "tt-ticket-guard-version"} {
		if _, ok := kv[k]; !ok {
			t.Errorf("KV 缺少 %s", k)
		}
	}
	if kv["aid"] != "1988" || kv["device_id"] != deviceID {
		t.Errorf("KV aid/device_id = %q/%q", kv["aid"], kv["device_id"])
	}
}

func TestWebToUID(t *testing.T) {
	if uid, err := webToUID("0:1:7366359960223482885:7664958044560016398"); err != nil || uid != 7366359960223482885 {
		t.Errorf("uid = %d, err = %v", uid, err)
	}
	for _, bad := range []string{"", "1:2:3", "0:1:x:4", "0:2:3:4"} {
		if _, err := webToUID(bad); err == nil {
			t.Errorf("expected error for %q", bad)
		}
	}
}

func TestCreateConversationWeb(t *testing.T) {
	c := testWebClient(t)
	cid, err := c.CreateConversation(t.Context(), 7366359960223482885)
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	if cid.ID != "0:1:7366359960223482885:7664958044560016398" {
		t.Errorf("conv id = %q", cid.ID)
	}
}

// fakeSendServer 返回一个断言请求的 fake server。
// requireSign 为 true 时断言签名参数存在 (带签名路径), false 时断言不存在 (无签名直连)。
func fakeSendServer(t *testing.T, status int, respBody []byte) *httptest.Server {
	return fakeSendServerSign(t, status, respBody, true)
}

// fakeSendServerSign 同 fakeSendServer, 可指定是否要求签名参数。
func fakeSendServerSign(t *testing.T, status int, respBody []byte, requireSign bool) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("method = %s", r.Method)
		}
		if !strings.Contains(r.URL.Path, "/v1/message/send") {
			t.Errorf("path = %s", r.URL.Path)
		}
		q := r.URL.Query()
		if requireSign {
			if q.Get("X-Dynosaur") != "DYN" || q.Get("X-Gnarly") != "GNAR" || q.Get("X-Bogus") != "1" {
				t.Errorf("签名参数缺失: %v", q)
			}
		} else if q.Get("X-Dynosaur") != "" || q.Get("X-Gnarly") != "" || q.Get("X-Bogus") != "" {
			t.Errorf("无签名直连不应携带签名参数: %v", q)
		}
		if ct := r.Header.Get("Content-Type"); ct != "application/x-protobuf" {
			t.Errorf("Content-Type = %q", ct)
		}
		if ck := r.Header.Get("Cookie"); !strings.Contains(ck, "sessionid=sess123") {
			t.Errorf("Cookie = %q", ck)
		}
		body, err := io.ReadAll(r.Body)
		if err != nil || len(body) == 0 {
			t.Fatalf("empty request body: %v", err)
		}
		core := decodeSendBodyCore(t, body)
		cp := &parser{data: core}
		if content, _, _ := cp.findStr(4); !strings.Contains(content, "probe") {
			t.Errorf("body 文本 = %q", content)
		}
		if status != 0 {
			w.WriteHeader(status)
		}
		if respBody != nil {
			_, _ = w.Write(respBody)
		}
	}))
}

func TestSendWebTextSuccess204(t *testing.T) {
	c := testWebClient(t)
	srv := fakeSendServer(t, http.StatusNoContent, nil)
	defer srv.Close()
	webSendEndpoint = srv.URL
	defer func() { webSendEndpoint = "https://im-api.tiktok.com" }()

	cid := &ConversationID{ID: "0:1:7366359960223482885:7664958044560016398"}
	res, err := c.SendText(t.Context(), cid, "probe test")
	if err != nil {
		t.Fatalf("SendText: %v", err)
	}
	if res.Terminate || res.Quit || res.Error != "" {
		t.Errorf("unexpected result: %+v", res)
	}
}

// TestSendWebTextNoSign 验证无签名直连 (M6-4 实测签名非必需):
// 未注入签名快照也能发送, 不再返回 ErrWebSignMissing。
func TestSendWebTextNoSign(t *testing.T) {
	a := &store.Account{
		UID: 7664958044560016398,
		Cookies: []store.Cookie{
			{Name: "sessionid", Value: "sess123", Domain: ".tiktok.com"},
			{Name: "ttwid", Value: "tok-7319826453671301423-tok", Domain: ".tiktok.com"},
		},
	}
	c, err := NewWebClient(a)
	if err != nil {
		t.Fatalf("NewWebClient: %v", err)
	}
	if c.sign != nil {
		t.Fatal("新客户端不应有签名快照")
	}
	srv := fakeSendServerSign(t, http.StatusNoContent, nil, false)
	defer srv.Close()
	webSendEndpoint = srv.URL
	defer func() { webSendEndpoint = "https://im-api.tiktok.com" }()

	cid := &ConversationID{ID: "0:1:7366359960223482885:7664958044560016398"}
	res, err := c.SendText(t.Context(), cid, "nosign probe")
	if err != nil {
		t.Fatalf("SendText 无签名直连失败: %v", err)
	}
	if res.Terminate || res.Quit || res.Error != "" {
		t.Errorf("unexpected result: %+v", res)
	}
}

// 200 + protobuf 业务错误 (7193 消息请求限制, M6-3 真实捕获形态)。
func TestSendWebTextBusinessError(t *testing.T) {
	c := testWebClient(t)
	var status encoder
	status.varint(1, 7193)
	status.str(2, `{"msg_content":{"tips":"You can only send up to 1 message before this user accepts your message request."}}`)
	var outer encoder
	outer.varint(1, 8)
	outer.msg(2, status.b)

	srv := fakeSendServer(t, http.StatusOK, outer.b)
	defer srv.Close()
	webSendEndpoint = srv.URL
	defer func() { webSendEndpoint = "https://im-api.tiktok.com" }()

	cid := &ConversationID{ID: "0:1:7366359960223482885:7664958044560016398"}
	res, err := c.SendText(t.Context(), cid, "probe")
	if err != nil {
		t.Fatalf("SendText: %v", err)
	}
	if !res.Terminate {
		t.Error("expected Terminate for 7193")
	}
	if !strings.Contains(res.Error, "7193") {
		t.Errorf("Error = %q, want 7193", res.Error)
	}
}

// 200 + status_code=0 → 成功。
func TestSendWebTextStatusZero(t *testing.T) {
	c := testWebClient(t)
	var status encoder
	status.varint(1, 0)
	status.str(2, `{}`)
	var outer encoder
	outer.msg(2, status.b)

	srv := fakeSendServer(t, http.StatusOK, outer.b)
	defer srv.Close()
	webSendEndpoint = srv.URL
	defer func() { webSendEndpoint = "https://im-api.tiktok.com" }()

	cid := &ConversationID{ID: "0:1:7366359960223482885:7664958044560016398"}
	res, err := c.SendText(t.Context(), cid, "probe")
	if err != nil {
		t.Fatalf("SendText: %v", err)
	}
	if res.Terminate || res.Error != "" {
		t.Errorf("unexpected result: %+v", res)
	}
}

// 真实 Web 响应信封 f3=0/f4="OK"/f6{f100{f6=JSON status_code}} (2026-08 实测形态)
// → 正确识别 7193 业务错误 (旧解析器只认 f2 Android 信封, 会误判为 Success)。
func TestSendWebTextWebEnvelope(t *testing.T) {
	c := testWebClient(t)
	var jsonMsg encoder
	jsonMsg.str(6, `{"status_code":7193,"scene":"message_request_limit","msg_id":7671948781584434701}`)
	var core encoder
	core.msg(100, jsonMsg.b)
	var outer encoder
	outer.varint(3, 0)
	outer.str(4, "OK")
	outer.msg(6, core.b)

	srv := fakeSendServer(t, http.StatusOK, outer.b)
	defer srv.Close()
	webSendEndpoint = srv.URL
	defer func() { webSendEndpoint = "https://im-api.tiktok.com" }()

	cid := &ConversationID{ID: "0:1:7366359960223482885:7664958044560016398"}
	res, err := c.SendText(t.Context(), cid, "probe")
	if err != nil {
		t.Fatalf("SendText: %v", err)
	}
	if !res.Terminate {
		t.Error("expected Terminate for 7193")
	}
	if !strings.Contains(res.Error, "7193") {
		t.Errorf("Error = %q, want 7193", res.Error)
	}
}

func TestSnapshotFromBodyRoundTrip(t *testing.T) {
	const (
		selfUID  = 7664958044560016398
		toUID    = 7366359960223482885
		deviceID = "7319826453671301423"
	)
	body := BuildWebSendBody(selfUID, toUID, deviceID, "t", "u", WebSendMeta{
		VerifyFP: "verify_fp_x", WebSDKMsToken: "wsdk_x",
		TicketGuardClientData: "tgc_x",
	})
	fullURL := "https://im-api.tiktok.com/v1/message/send?aid=1988&X-Dynosaur=DYN&msToken=TOK&X-Bogus=1&X-Gnarly=GNAR"
	snap := SnapshotFromBody(body, fullURL)
	if snap.Sign.XDynosaur != "DYN" || snap.Sign.XGnarly != "GNAR" || snap.Sign.MSToken != "TOK" {
		t.Errorf("sign = %+v", snap.Sign)
	}
	if snap.Meta.VerifyFP != "verify_fp_x" || snap.Meta.WebSDKMsToken != "wsdk_x" ||
		snap.Meta.TicketGuardClientData != "tgc_x" || snap.Meta.TzName == "" {
		t.Errorf("meta = %+v", snap.Meta)
	}
}
