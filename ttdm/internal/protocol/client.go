package protocol

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pierrec/lz4/v4"
	"golang.org/x/net/proxy"

	"ttdm/internal/store"
)

// md5Hex returns the lowercase hex MD5 of s.
func md5Hex(s string) string {
	sum := md5.Sum([]byte(s))
	return hex.EncodeToString(sum[:])
}

// ConversationID identifies a created conversation.
type ConversationID struct {
	ID      string
	ShortID int64
}

// IImClient is the protocol surface used by the task engine. The Android
// implementation is AndroidClient; a Web protocol client can implement the
// same interface as a fallback.
type IImClient interface {
	Connect(ctx context.Context, proxyURL string) error
	CreateConversation(ctx context.Context, toUID int64) (*ConversationID, error)
	SendText(ctx context.Context, cid *ConversationID, text string) (SendResult, error)
	SendLink(ctx context.Context, cid *ConversationID, linkURL, coverURL, title, desc string) (SendResult, error)
	SendVideo(ctx context.Context, cid *ConversationID, videoID string) (SendResult, error)
	SendSticker(ctx context.Context, cid *ConversationID, imageURL string) (SendResult, error)
	SendHomePage(ctx context.Context, cid *ConversationID, uid string) (SendResult, error)
	Close() error
}

// Compile-time check: AndroidClient implements IImClient.
var _ IImClient = (*AndroidClient)(nil)

// WSSDomain resolves the IM WebSocket host from the account's store-idc
// (mirrors TikTokDomains.GetWssDomain).
func WSSDomain(storeIDC string) string {
	switch storeIDC {
	case "useast5", "useast8":
		return "frontier.tiktokv.us"
	case "useast2a":
		return "frontier.tiktokv.eu"
	default: // alisg, maliva, unknown
		return "frontier.tiktokv.com"
	}
}

// AccessKey computes MD5("9e1bd35ec9db7b8d846de66ed140b1ad9"+deviceId+"f8a69f1719916z").
func AccessKey(deviceID string) string {
	const fpid = "9"
	const magic = "e1bd35ec9db7b8d846de66ed140b1ad9"
	const suffix = "f8a69f1719916z"
	return md5Hex(fpid + magic + deviceID + suffix)
}

// BuildWSQuery mirrors GetDefaultQueryString of the Android client.
func BuildWSQuery(deviceID, accessKey string, accountQuery string) string {
	now := time.Now()
	ts := now.Add(-3 * time.Second).Unix()
	rticket := now.UnixMilli()
	params := map[string]string{
		"version_code":              "2023107030",
		"manifest_version_code":     "2023107030",
		"update_version_code":       "2023107030",
		"carrier_region_v2":         "310",
		"fpid":                      "9",
		"aid":                       "1233",
		"access_key":                accessKey,
		"device_id":                 deviceID,
		"platform":                  "0",
		"sdk_version":               "2",
		"transport_mode":            "0",
		"disable_fallback_websocket": "false",
		"private_protocol_enable":   "false",
		"uoo":                       "1",
		"dpi":                       "320",
		"is_pad":                    "0",
		"ab_version":                appVersion,
		"version_name":              appVersion,
		"build_number":              appVersion,
		"em":                        "netstate_change",
		"ac":                        "WIFI",
		"ac2":                       "wifi5g",
		"ne":                        "1",
		"host_abi":                  abi,
		"os":                        "android",
		"os_api":                    osAPI,
		"os_version":                osVersion,
		"monitor_service_id_list":   "%5B%5D",
		"service_id_list":           "%5B%5D",
		"is_background":             "0",
		"mcc_mnc":                   "310004",
		"_rticket":                  strconv.FormatInt(rticket, 10),
		"ts":                        strconv.FormatInt(ts, 10),
		"app_name":                  appName,
		"app_language":              "en",
		"app_type":                  "normal",
		"channel":                   "googleplay",
		"device_platform":           "android",
		"device_brand":              deviceBrand,
		"device_type":               deviceType,
		"resolution":                resolution,
		"locale":                    "en",
		"language":                  "en",
	}
	// account.QueryParameters override the defaults when present
	if accountQuery != "" {
		for _, kv := range strings.Split(accountQuery, "&") {
			if i := strings.Index(kv, "="); i > 0 {
				params[kv[:i]] = kv[i+1:]
			}
		}
	}
	parts := make([]string, 0, len(params))
	for k, v := range params {
		parts = append(parts, k+"="+v)
	}
	return strings.Join(parts, "&")
}

// AndroidClient implements the TikTok Android IM protocol over WebSocket.
type AndroidClient struct {
	account *store.Account
	conn    *websocket.Conn
	sn      int32
}

// NewAndroidClient creates a client bound to an account.
func NewAndroidClient(a *store.Account) *AndroidClient {
	return &AndroidClient{account: a, sn: 773841}
}

// Connect opens the WebSocket. proxyURL may be nil for direct connection;
// http(s) proxies are supported via the dialer.
func (c *AndroidClient) Connect(ctx context.Context, proxyURL string) error {
	if !c.account.HasFullIMParams() {
		return fmt.Errorf("账号缺少参数 (uid/device_id/store_idc/cookie)，请尝试刷新账号信息")
	}
	wsURL := "wss://" + WSSDomain(c.account.StoreIDC) + "/ws/v2?" +
		BuildWSQuery(c.account.DeviceID, AccessKey(c.account.DeviceID), "")

	dialer := websocket.Dialer{
		Subprotocols:     []string{"pbbp"},
		HandshakeTimeout: 30 * time.Second,
	}
	if proxyURL == "" {
		// match the OS proxy (Clash etc.) so egress is consistent with the
		// browser environment the account was logged in from
		proxyURL = SystemProxy()
	}
	if proxyURL != "" {
		u, err := url.Parse(proxyURL)
		if err != nil {
			return fmt.Errorf("解析代理失败: %w", err)
		}
		if u.Scheme == "socks5" || u.Scheme == "socks5h" {
			p, err := SOCKS5Dialer(u)
			if err != nil {
				return fmt.Errorf("配置 SOCKS5 代理失败: %w", err)
			}
			if cd, ok := p.(proxy.ContextDialer); ok {
				dialer.NetDialContext = cd.DialContext
			} else {
				dialer.NetDial = p.Dial
			}
		} else {
			dialer.Proxy = http.ProxyURL(u)
		}
	}

	header := http.Header{}
	header.Set("User-Agent", uaOrDefault(c.account.UserAgent))
	header.Set("Accept-Encoding", "gzip")
	header.Set("Host", WSSDomain(c.account.StoreIDC))
	header.Set("Cookie", c.account.CookieString())

	conn, resp, err := dialer.DialContext(ctx, wsURL, header)
	if err != nil {
		if resp != nil {
			reason := "未知"
			if ct := resp.Header.Get("Content-Type"); ct != "" {
				reason = ct
			}
			return fmt.Errorf("连接被拒绝 HTTP %d (%s): %w", resp.StatusCode, reason, err)
		}
		return fmt.Errorf("连接服务器失败: %w", err)
	}
	c.conn = conn
	return nil
}

func uaOrDefault(ua string) string {
	if ua == "" {
		return "okhttp/3.12.13.4-tiktok"
	}
	return ua
}

// SOCKS5Dialer builds a dialer for socks5://[user:pass@]host:port URLs.
func SOCKS5Dialer(u *url.URL) (proxy.Dialer, error) {
	host := u.Host
	if !strings.Contains(host, ":") {
		host += ":1080"
	}
	var auth *proxy.Auth
	if u.User != nil {
		pass, _ := u.User.Password()
		auth = &proxy.Auth{User: u.User.Username(), Password: pass}
	}
	return proxy.SOCKS5("tcp", host, auth, proxy.Direct)
}

// Close disconnects the socket.
func (c *AndroidClient) Close() error {
	if c.conn == nil {
		return nil
	}
	_ = c.conn.WriteControl(websocket.CloseMessage,
		websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""),
		time.Now().Add(2*time.Second))
	err := c.conn.Close()
	c.conn = nil
	return err
}

// CreateConversation sends Type 609 and returns the conversation id.
func (c *AndroidClient) CreateConversation(ctx context.Context, toUID int64) (*ConversationID, error) {
	sn := c.nextSn()
	body := buildCreateConversationBody(c.account.UID, toUID)
	req := buildAppImRequest(sn, cmdCreateConversation, c.account.DeviceID, body)
	if err := c.sendBinary(req); err != nil {
		return nil, err
	}
	resp, err := c.receiveAck(ctx, sn, 10*time.Second)
	if err != nil {
		return nil, err
	}
	if resp.status != "OK" && resp.status != "" {
		if resp.status == "200001" {
			return nil, fmt.Errorf("创建会话失败, 可能是CK失效导致")
		}
		return nil, fmt.Errorf("创建会话失败 %s", resp.status)
	}
	if resp.result == nil {
		return nil, fmt.Errorf("创建会话失败")
	}
	// parse AppImResponseCreateConversationBody {1: ConversationId}
	p := &parser{data: resp.result}
	inner, ok, err := p.findLen(1)
	if err != nil || !ok {
		return nil, fmt.Errorf("创建会话失败: 响应缺少会话ID")
	}
	cp := &parser{data: inner}
	id, _, _ := cp.findStr(1)
	shortRaw, ok2, err := cp.findVarint(2)
	if err != nil || !ok2 {
		return nil, fmt.Errorf("创建会话失败: 响应缺少短ID")
	}
	cid := &ConversationID{ID: id, ShortID: int64(shortRaw)}
	if cid.ID == "" || cid.ShortID == 0 {
		return nil, fmt.Errorf("创建会话失败: 会话ID无效")
	}
	return cid, nil
}

// SendText sends a text message: Type 411 pre-send → 200ms → Type 100.
func (c *AndroidClient) SendText(ctx context.Context, cid *ConversationID, text string) (SendResult, error) {
	// Phase 1: pre-send 411
	sn411 := c.nextSn()
	req411 := buildAppImRequest(sn411, cmdPreSend, c.account.DeviceID, buildPreSendBody(cid))
	if err := c.sendBinary(req411); err != nil {
		return SendResult{}, err
	}
	if _, err := c.receiveAck(ctx, sn411, 10*time.Second); err != nil {
		return SendResult{}, err
	}
	select {
	case <-time.After(200 * time.Millisecond):
	case <-ctx.Done():
		return SendResult{}, ctx.Err()
	}
	// Phase 2: send 100
	sn := c.nextSn()
	content := fmt.Sprintf(`{"isDefault":false,"text":"%s","is_card":false,"sendStartTime":%d,"aweType":700}`,
		EscapeJSONString(text), time.Now().UnixMilli())
	req := buildAppImRequest(sn, cmdSendMessage, c.account.DeviceID,
		buildSendBody(cid, MsgText, content, nil))
	if err := c.sendBinary(req); err != nil {
		return SendResult{}, err
	}
	resp, err := c.receiveAck(ctx, sn, 10*time.Second)
	if err != nil {
		return SendResult{}, err
	}
	return parseSendAck(resp)
}

// SendVideo sends a video card (Type 100, LZ4-compressed body).
func (c *AndroidClient) SendVideo(ctx context.Context, cid *ConversationID, videoID string) (SendResult, error) {
	content, _ := json.Marshal(map[string]any{
		"itemId": videoID,
		"aweType": 0,
		"is_card": false,
	})
	return c.sendLz4(ctx, cid, MsgVideo, string(content), nil)
}

// SendSticker sends an image/sticker card (Type 100, LZ4).
func (c *AndroidClient) SendSticker(ctx context.Context, cid *ConversationID, imageURL string) (SendResult, error) {
	content := fmt.Sprintf(`{"height":1920,"width":1080,"url":{"uri":"","url_list":["%s"]},"prev_conv_id":"%s","root_conv_id":"%s","prev_id":%d,"root_id":%d}`,
		EscapeJSONString(imageURL), cid.ID, cid.ID, cid.ShortID, cid.ShortID)
	return c.sendLz4(ctx, cid, MsgSticker, content, nil)
}

// SendHomePage sends a profile card (Type 100, LZ4, with ext params).
func (c *AndroidClient) SendHomePage(ctx context.Context, cid *ConversationID, uid string) (SendResult, error) {
	content := fmt.Sprintf(`{"uid":"%s","push_detail":"you"}`, EscapeJSONString(uid))
	return c.sendLz4(ctx, cid, MsgHomePage, content, linkExtParams())
}

// SendLink sends a link card (Type 100, LZ4, with ext params).
func (c *AndroidClient) SendLink(ctx context.Context, cid *ConversationID, linkURL, coverURL, title, desc string) (SendResult, error) {
	content := fmt.Sprintf(`{"link_url":"%s","cover_url":"%s","title":"%s","desc":"%s","prev_conv_id":"%s","root_conv_id":"%s","prev_id":%d,"root_id":%d,"sendStartTime":%d,"root_relation_tag":"2","is_card":false,"aweType":0,"push_detail":""}`,
		EscapeJSONString(linkURL), EscapeJSONString(coverURL), EscapeJSONString(title),
		EscapeJSONString(desc), cid.ID, cid.ID, cid.ShortID, cid.ShortID, time.Now().UnixMilli())
	return c.sendLz4(ctx, cid, MsgLink, content, linkExtParams())
}

// sendLz4 sends a non-text card: protobuf body → LZ4 → AppImLz4Request envelope.
func (c *AndroidClient) sendLz4(ctx context.Context, cid *ConversationID, msgType int, contentJSON string, ext map[string]string) (SendResult, error) {
	sn := c.nextSn()
	// inner message (AppImRequestMessage) with Type 100 body
	var msg encoder
	msg.int32(1, cmdSendMessage)
	msg.int32(2, sn)
	msg.str(3, "local")
	msg.int32(5, 1)
	msg.str(7, "0")
	msg.bytes(8, buildSendBody(cid, msgType, contentJSON, ext))
	msg.str(9, c.account.DeviceID)
	msg.str(10, "googleplay")
	msg.str(11, "android")
	msg.str(12, deviceType)
	msg.str(13, osVersion)
	msg.str(14, "2023107030")
	msg.strMap(15, map[string]string{"aid": "1233", "user-agent": ua, "locale": "en"})

	raw := msg.b
	compressed := make([]byte, lz4.CompressBlockBound(len(raw)))
	n, err := lz4.CompressBlock(raw, compressed, nil)
	if err != nil || n <= 0 {
		return SendResult{}, fmt.Errorf("LZ4 压缩失败: %w", err)
	}
	compressed = compressed[:n]

	req := buildLz4Request(sn, cmdSendMessage, compressed)
	if err := c.sendBinary(req); err != nil {
		return SendResult{}, err
	}
	resp, err := c.receiveAck(ctx, sn, 10*time.Second)
	if err != nil {
		return SendResult{}, err
	}
	return parseSendAck(resp)
}

func (c *AndroidClient) nextSn() int32 {
	c.sn++
	return c.sn
}

func (c *AndroidClient) sendBinary(data []byte) error {
	if c.conn == nil {
		return fmt.Errorf("未连接")
	}
	return c.conn.WriteMessage(websocket.BinaryMessage, data)
}

// ack is a parsed AppImResponseMessage.
type ack struct {
	sn     int32
	status string
	result []byte
}

// receiveAck reads frames until the response for the given sn arrives,
// then parses status/result. timeouts mirror the original client.
func (c *AndroidClient) receiveAck(ctx context.Context, wantSN int32, timeout time.Duration) (*ack, error) {
	if c.conn == nil {
		return nil, fmt.Errorf("未连接")
	}
	deadline := time.Now().Add(timeout)
	c.conn.SetReadDeadline(deadline)
	defer c.conn.SetReadDeadline(time.Time{})
	for {
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				return nil, fmt.Errorf("响应超时")
			}
			return nil, fmt.Errorf("读取响应失败: %w", err)
		}
		a, err := parseAppImResponse(data)
		if err != nil {
			continue // ignore unparseable frames
		}
		if a.sn != wantSN {
			continue // stale frame
		}
		return a, nil
	}
}

// parseAppImResponse extracts {sn, status, result-bytes} from a raw frame.
func parseAppImResponse(data []byte) (*ack, error) {
	p := &parser{data: data}
	inner, ok, err := p.findLen(8) // AppImResponse.Message
	if err != nil || !ok {
		return nil, fmt.Errorf("no message field")
	}
	mp := &parser{data: inner}
	rawSn, ok, err := mp.findVarint(2)
	if err != nil || !ok {
		return nil, fmt.Errorf("no sn field")
	}
	status, _, _ := mp.findStr(4)
	result, _, _ := mp.findLen(6)
	return &ack{sn: int32(rawSn), status: status, result: result}, nil
}

// parseSendAck interprets a Type 100 ack: 411 acks count as success,
// otherwise the JSON content status_code is mapped.
func parseSendAck(a *ack) (SendResult, error) {
	if a.status != "OK" && a.status != "" {
		if a.status == "200001" {
			return SendResult{}, fmt.Errorf("发送失败(200001), 可能是CK失效导致")
		}
		return SendResult{Terminate: false, Error: a.status}, nil
	}
	if a.result == nil {
		return Success, nil
	}
	// AppImResponseSendMessageBody {6: JsonBody string}
	p := &parser{data: a.result}
	jsonBody, ok, err := p.findStr(6)
	if err != nil {
		return SendResult{}, err
	}
	if !ok {
		return Success, nil
	}
	var content struct {
		StatusCode int `json:"status_code"`
		StatusMsg  *struct {
			MsgContent *struct {
				Tips string `json:"tips"`
			} `json:"msg_content"`
		} `json:"status_msg"`
	}
	if err := json.Unmarshal([]byte(jsonBody), &content); err != nil {
		return Success, nil
	}
	tips := ""
	if content.StatusMsg != nil && content.StatusMsg.MsgContent != nil {
		tips = content.StatusMsg.MsgContent.Tips
	}
	return MapSendStatus(content.StatusCode, tips), nil
}
