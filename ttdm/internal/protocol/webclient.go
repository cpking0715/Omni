package protocol

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"golang.org/x/net/proxy"

	"ttdm/internal/store"
)

// WebClient implements IImClient over the TikTok Web IM protocol
// (通道二, fws_1.0.0, DESIGN 5.4). Connection + envelope + send layer
// (M6-3 抓包逆向, HTTP message/send) are implemented; the signature
// snapshot (webmssdk) is optional — M6-4 (2026-08-09) 实测签名对
// message/send 非必需, 未注入快照时走无签名直连。
type WebClient struct {
	account *store.Account

	// derived connection material (DESIGN 5.4.1)
	ttwid    string // URL-decoded ttwid cookie value
	deviceID string // 19-digit device id embedded in ttwid

	conn *websocket.Conn
	sn   int32

	// webmssdk 签名快照 (可选兼容路径, 由 SetWebSign 注入; 无则无签名直连)
	sign *WebSignSnapshot

	// pending ack waiters keyed by frame sn (read-pump dispatch)
	mu      sync.Mutex
	waiters map[int32]chan []byte

	readErr error
	closed  bool
}

// ErrWebSendNotImplemented signals that a Web send variant (link/video/
// sticker/homepage) has no reverse-engineered payload yet.
var ErrWebSendNotImplemented = errors.New("该消息类型在通道二尚未逆向 (仅文本可用)")

// Compile-time check: WebClient implements IImClient.
var _ IImClient = (*WebClient)(nil)

// Web 通道常量 (DESIGN 5.4.2 消息信封).
const (
	webService   = 33554513 // 帧 f3
	webMethod    = 2        // 帧 f4
	webFirstSN   = 10001    // sn 起始值
	webWSSHost   = "im-ws.tiktok.com"
	webSubProto  = "pbbp2"
	webOrigin    = "https://www.tiktok.com"
	webChromeUA  = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
)

// NewWebClient creates a Web-channel client bound to an account.
// The account must carry a ttwid cookie; the device id comes from
// Account.DeviceID when set (ttwid 新格式不内嵌设备 ID, M6-3 实测),
// otherwise it is parsed from the ttwid value (DESIGN 5.4.1).
func NewWebClient(a *store.Account) (*WebClient, error) {
	ttwid := store.TTWid(a.Cookies)
	if ttwid == "" {
		return nil, fmt.Errorf("账号缺少 ttwid cookie, 无法连接通道二")
	}
	devID := a.DeviceID
	if devID == "" {
		devID = store.TTWidDeviceID(a.Cookies)
	}
	if devID == "" {
		return nil, fmt.Errorf("缺少设备 ID: 账号 DeviceID 为空且 ttwid 中未找到 19 位设备 ID")
	}
	return &WebClient{
		account:  a,
		ttwid:    ttwid,
		deviceID: devID,
		sn:       webFirstSN - 1,
		waiters:  make(map[int32]chan []byte),
	}, nil
}

// BuildWebQuery builds the fws_1.0.0 connection query string (DESIGN 5.4.1).
// access_key = MD5("9" + magic + ttwidDeviceID + suffix).
func BuildWebQuery(ttwidDeviceID, ttwid string) string {
	v := url.Values{}
	v.Set("device_platform", "web")
	v.Set("version_code", "fws_1.0.0")
	v.Set("access_key", AccessKey(ttwidDeviceID))
	v.Set("fpid", "9")
	v.Set("aid", "1459")
	v.Set("ttwid", ttwid)
	v.Set("xsack", "1")
	v.Set("xaack", "1")
	v.Set("xsqos", "0")
	return v.Encode()
}

// Connect dials the Web IM WebSocket and starts the read pump.
func (c *WebClient) Connect(ctx context.Context, proxyURL string) error {
	if c.conn != nil {
		return nil
	}
	wsURL := "wss://" + webWSSHost + "/ws/v2?" + BuildWebQuery(c.deviceID, c.ttwid)

	dialer := websocket.Dialer{
		Subprotocols:     []string{webSubProto},
		HandshakeTimeout: 30 * time.Second,
	}
	if proxyURL == "" {
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
	header.Set("User-Agent", webChromeUA)
	header.Set("Origin", webOrigin)
	header.Set("Cookie", c.account.CookieString())

	conn, resp, err := dialer.DialContext(ctx, wsURL, header)
	if err != nil {
		if resp != nil {
			return fmt.Errorf("连接被拒绝 HTTP %d: %w", resp.StatusCode, err)
		}
		return fmt.Errorf("连接服务器失败: %w", err)
	}
	c.conn = conn
	go c.readPump()

	// 页面打开后浏览器会自动发出 sn 递增的初始化/同步帧 (DESIGN 5.4.3);
	// 发送一帧空消息块列表的同步帧,保持会话活跃并探测服务端响应。
	if err := c.sendSyncFrame(); err != nil {
		_ = c.Close()
		return fmt.Errorf("发送初始化帧失败: %w", err)
	}
	return nil
}

// readPump dispatches incoming frames to sn-keyed waiters.
func (c *WebClient) readPump() {
	for {
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			c.mu.Lock()
			c.readErr = err
			for sn, ch := range c.waiters {
				close(ch)
				delete(c.waiters, sn)
			}
			c.mu.Unlock()
			return
		}
		f, perr := parseWebFrame(data)
		if perr != nil {
			continue // 心跳/未知帧
		}
		c.mu.Lock()
		if ch, ok := c.waiters[f.SN]; ok {
			ch <- f.Body
			delete(c.waiters, f.SN)
		}
		c.mu.Unlock()
	}
}

func (c *WebClient) nextSN() int32 {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sn++
	return c.sn
}

// WebFrame is a parsed 通道二 envelope (DESIGN 5.4.2).
type WebFrame struct {
	SN        int32
	Timestamp int64
	Service   int64
	Method    int64
	Body      []byte
}

// buildWebFrame encodes the envelope:
//
//	f1: sn  f2: ts_ms  f3: service=33554513  f4: method=2  f7: "2"
//	f8: body { f1: 设备块 { f1:2, f2:"{uid}", f3:"{uid}", f4:ts },
//	           f2: 消息块列表 { f1:4, f2:0, f3:1/0, f4:会话ID } }
func buildWebFrame(sn int32, uid int64, convIDs []string) []byte {
	now := time.Now().UnixMilli()

	var device encoder
	device.int32(1, 2)
	device.str(2, strconv.FormatInt(uid, 10))
	device.str(3, strconv.FormatInt(uid, 10))
	device.varint(4, uint64(now))

	var body encoder
	body.msg(1, device.b)
	for _, cid := range convIDs {
		var blk encoder
		blk.int32(1, 4)
		blk.int32(2, 0)
		blk.int32(3, 1)
		blk.str(4, cid)
		body.msg(2, blk.b)
	}

	var f encoder
	f.varint(1, uint64(sn))
	f.varint(2, uint64(now))
	f.varint(3, webService)
	f.varint(4, webMethod)
	f.str(7, "2")
	f.msg(8, body.b)
	return f.b
}

// parseWebFrame decodes the envelope fields of an incoming frame.
func parseWebFrame(data []byte) (*WebFrame, error) {
	p := &parser{data: data}
	f := &WebFrame{}
	for !p.eof() {
		field, wt, err := p.next()
		if err != nil {
			return nil, err
		}
		switch field {
		case 1:
			if wt != wtVarint {
				return nil, fmt.Errorf("sn wire type %d", wt)
			}
			v, err := p.varint()
			if err != nil {
				return nil, err
			}
			f.SN = int32(v)
		case 2:
			if wt != wtVarint {
				return nil, fmt.Errorf("ts wire type %d", wt)
			}
			v, err := p.varint()
			if err != nil {
				return nil, err
			}
			f.Timestamp = int64(v)
		case 3:
			v, err := p.varint()
			if err != nil {
				return nil, err
			}
			f.Service = int64(v)
		case 4:
			v, err := p.varint()
			if err != nil {
				return nil, err
			}
			f.Method = int64(v)
		case 8:
			b, err := p.lengthBytes()
			if err != nil {
				return nil, err
			}
			f.Body = b
		default:
			if err := p.skip(wt); err != nil {
				return nil, err
			}
		}
	}
	if f.SN == 0 && f.Body == nil {
		return nil, fmt.Errorf("frame lacks sn and body")
	}
	return f, nil
}

// sendSyncFrame sends the auto init/sync frame (no message blocks).
func (c *WebClient) sendSyncFrame() error {
	if c.conn == nil {
		return fmt.Errorf("未连接")
	}
	sn := c.nextSN()
	return c.conn.WriteMessage(websocket.BinaryMessage,
		buildWebFrame(sn, c.account.UID, nil))
}

// MustBuildWebSyncFrame builds a sync frame with no message blocks
// (exported for the reverse-engineering probe and frame-level tests).
func MustBuildWebSyncFrame(sn int32, uid int64) []byte {
	return buildWebFrame(sn, uid, nil)
}

// ParseWebFrame decodes an incoming envelope (exported for probes/tests).
func ParseWebFrame(data []byte) (*WebFrame, error) {
	return parseWebFrame(data)
}

// SendTyping sends the typing notification: a literal text frame "hi"
// (DESIGN 5.4.3 输入状态帧).
func (c *WebClient) SendTyping() error {
	if c.conn == nil {
		return fmt.Errorf("未连接")
	}
	return c.conn.WriteMessage(websocket.TextMessage, []byte("hi"))
}

// awaitFrame waits for a frame with the given sn (used once send payloads
// are reverse-engineered).
func (c *WebClient) awaitFrame(ctx context.Context, sn int32, timeout time.Duration) ([]byte, error) {
	ch := make(chan []byte, 1)
	c.mu.Lock()
	if c.readErr != nil {
		err := c.readErr
		c.mu.Unlock()
		return nil, fmt.Errorf("读取通道已断开: %w", err)
	}
	c.waiters[sn] = ch
	c.mu.Unlock()
	select {
	case body, ok := <-ch:
		if !ok {
			return nil, fmt.Errorf("连接断开")
		}
		return body, nil
	case <-time.After(timeout):
		c.mu.Lock()
		delete(c.waiters, sn)
		c.mu.Unlock()
		return nil, fmt.Errorf("响应超时")
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.waiters, sn)
		c.mu.Unlock()
		return nil, ctx.Err()
	}
}

// Close shuts down the socket and stops dispatching.
func (c *WebClient) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	c.mu.Unlock()
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

// ---- IImClient send surface ----

// CreateConversation builds the Web conversation id (M6-3 抓包):
// 会话格式 "0:1:{toUID}:{selfUID}", 无需额外 API —— 首次 send 即建会话。
func (c *WebClient) CreateConversation(ctx context.Context, toUID int64) (*ConversationID, error) {
	if c.account.UID == 0 {
		return nil, fmt.Errorf("账号 UID 为空, 无法构造会话 ID")
	}
	return &ConversationID{
		ID: "0:1:" + strconv.FormatInt(toUID, 10) + ":" + strconv.FormatInt(c.account.UID, 10),
	}, nil
}

// SendText sends a text message over the Web HTTP send layer
// (POST im-api.tiktok.com/v1/message/send, M6-3 抓包逆向).
func (c *WebClient) SendText(ctx context.Context, cid *ConversationID, text string) (SendResult, error) {
	if cid == nil || !strings.HasPrefix(cid.ID, "0:1:") {
		return SendResult{}, fmt.Errorf("无效会话 ID: %+v", cid)
	}
	toUID, err := webToUID(cid.ID)
	if err != nil {
		return SendResult{}, err
	}
	return c.SendWebText(ctx, toUID, text, "")
}

// webToUID 从 "0:1:{toUID}:{selfUID}" 提取对方 uid。
func webToUID(cid string) (int64, error) {
	parts := strings.Split(cid, ":")
	if len(parts) != 4 || parts[0] != "0" || parts[1] != "1" {
		return 0, fmt.Errorf("非法会话 ID 格式: %q", cid)
	}
	uid, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("解析会话目标 uid 失败: %w", err)
	}
	return uid, nil
}

// SendLink is not implemented yet (aweType 结构待逆向).
func (c *WebClient) SendLink(ctx context.Context, cid *ConversationID, linkURL, coverURL, title, desc string) (SendResult, error) {
	return SendResult{}, ErrWebSendNotImplemented
}

// SendVideo is not implemented yet (aweType 结构待逆向).
func (c *WebClient) SendVideo(ctx context.Context, cid *ConversationID, videoID string) (SendResult, error) {
	return SendResult{}, ErrWebSendNotImplemented
}

// SendSticker is not implemented yet (aweType 结构待逆向).
func (c *WebClient) SendSticker(ctx context.Context, cid *ConversationID, imageURL string) (SendResult, error) {
	return SendResult{}, ErrWebSendNotImplemented
}

// SendHomePage is not implemented yet (aweType 结构待逆向).
func (c *WebClient) SendHomePage(ctx context.Context, cid *ConversationID, uid string) (SendResult, error) {
	return SendResult{}, ErrWebSendNotImplemented
}
