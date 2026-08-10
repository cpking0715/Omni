package protocol

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"ttdm/internal/adspower"
	"ttdm/internal/store"
)

// BrowserClient implements IImClient over a real browser driven via CDP
// (模拟通道, DESIGN 5.7). Each account maps 1:1 to an AdsPower profile,
// so the fingerprint environment stays consistent with the login session.
//
// Only text messages are supported on this channel; card messages return a
// terminate result (the engine then skips subsequent cards, mirroring the
// original simulated-channel behavior of text-only sending).
type BrowserClient struct {
	account *store.Account
	adsKey  string

	ads  *adspower.Client
	page *adspower.Page
	cdp  *adspower.CDPClient

	// timings (DESIGN 5.7.2 流程)
	navigateTimeout time.Duration
	selectorTimeout time.Duration
	inputDelay      time.Duration
}

// Compile-time check: BrowserClient implements IImClient.
var _ IImClient = (*BrowserClient)(nil)

// NewBrowserClient binds an account to its AdsPower profile browser.
// adsAPIKey is the AdsPower Local API key.
func NewBrowserClient(a *store.Account, adsAPIKey string) (*BrowserClient, error) {
	if a.AdsProfileID == "" {
		return nil, fmt.Errorf("账号未绑定 AdsPower 浏览器配置 (ads_profile_id 为空)")
	}
	if adsAPIKey == "" {
		return nil, fmt.Errorf("缺少 AdsPower 本地 API Key")
	}
	return &BrowserClient{
		account:         a,
		adsKey:          adsAPIKey,
		navigateTimeout: 30 * time.Second,
		selectorTimeout: 30 * time.Second,
		inputDelay:      80 * time.Millisecond,
	}, nil
}

// Connect starts (or attaches to) the AdsPower profile browser and opens
// the TikTok messages page. proxyURL is ignored — the browser profile
// carries its own proxy environment (账号-环境 1:1).
func (c *BrowserClient) Connect(ctx context.Context, proxyURL string) error {
	if c.page != nil {
		return nil
	}
	c.ads = adspower.NewClient(c.adsKey)
	_, debugPort, err := c.ads.StartBrowser(ctx, c.account.AdsProfileID)
	if err != nil {
		return fmt.Errorf("启动浏览器失败: %w", err)
	}
	pageWS, err := adspower.PageWSURL(ctx, debugPort)
	if err != nil {
		return fmt.Errorf("获取页面连接失败: %w", err)
	}
	cdp, err := adspower.ConnectCDP(ctx, pageWS)
	if err != nil {
		return fmt.Errorf("连接 CDP 失败: %w", err)
	}
	c.cdp = cdp
	c.page = adspower.NewPage(cdp)
	return nil
}

// CreateConversation navigates to the messages page for the target user
// and waits until the chat is loaded (DESIGN 5.7.1/5.7.2):
//
//	navigate https://www.tiktok.com/messages?lang=en&u={uid}
//	→ wait input area → wait chat-uniqueid (non-empty, not "@")
func (c *BrowserClient) CreateConversation(ctx context.Context, toUID int64) (*ConversationID, error) {
	if c.page == nil {
		return nil, fmt.Errorf("未连接")
	}
	url := BrowserMessagesURL + strconv.FormatInt(toUID, 10)
	if err := c.page.Navigate(ctx, url, c.navigateTimeout); err != nil {
		return nil, err
	}
	if _, err := c.page.WaitSelector(ctx, c.selectorTimeout, 500*time.Millisecond, SelMessageInput...); err != nil {
		return nil, fmt.Errorf("私信输入区未出现 (可能未登录或页面改版): %w", err)
	}
	// 等待会话加载: chat-uniqueid 非空且非 "@"
	deadline := time.Now().Add(c.selectorTimeout)
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		txt, err := c.page.SelectorText(ctx, SelChatUniqueID...)
		if err == nil && txt != "" && txt != "@" {
			return &ConversationID{ID: strconv.FormatInt(toUID, 10), ShortID: toUID}, nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return nil, fmt.Errorf("会话加载超时 (chat-uniqueid 未就绪)")
}

// SendText types into the Draft.js input and clicks send, then probes the
// DOM for warning/failure indicators (DESIGN 5.7.2 结果检查).
func (c *BrowserClient) SendText(ctx context.Context, cid *ConversationID, text string) (SendResult, error) {
	if c.page == nil {
		return SendResult{}, fmt.Errorf("未连接")
	}
	if err := c.page.Type(ctx, text, c.inputDelay, SelMessageInput...); err != nil {
		return SendResult{}, err
	}
	time.Sleep(300 * time.Millisecond)
	if ok, err := c.page.Click(ctx, SelSendButton...); err != nil {
		return SendResult{}, err
	} else if !ok {
		return SendResult{}, fmt.Errorf("发送按钮不存在")
	}
	// 结果探测: 1.5s 内若出现 warning/失败提示则判定失败
	time.Sleep(1500 * time.Millisecond)
	warning, _ := c.visibleWarning(ctx)
	if warning != "" {
		return mapBrowserWarning(warning), nil
	}
	return Success, nil
}

// visibleWarning returns the text of the first visible send-warning
// element, or "" when none is present.
func (c *BrowserClient) visibleWarning(ctx context.Context) (string, error) {
	selsJSON := mustJSONStrings(SelSendWarning)
	expr := `(() => {
		for (const s of ` + selsJSON + `) {
			const el = document.querySelector(s);
			if (el && el.offsetParent !== null) {
				const t = el.textContent.trim();
				if (t) return t;
			}
		}
		return '';
	})()`
	return c.page.CDP.Eval(ctx, expr)
}

// LastChatText 读取最后一条聊天记录文本 (发送后结果验证/调试用)。
func (c *BrowserClient) LastChatText(ctx context.Context) (string, error) {
	if c.page == nil {
		return "", fmt.Errorf("未连接")
	}
	return c.page.SelectorText(ctx, SelLastChatItem...)
}

// FindText 全文搜索包含目标文本的叶子节点 (页面结构变化时的兜底验证)。
func (c *BrowserClient) FindText(ctx context.Context, text string) (string, error) {
	if c.page == nil {
		return "", fmt.Errorf("未连接")
	}
	expr := `(() => {
		const target = ` + fmt.Sprintf("%q", text) + `;
		for (const el of document.querySelectorAll('*')) {
			if (el.childElementCount > 0) continue;
			const t = el.textContent.trim();
			if (t && t.includes(target)) return t;
		}
		return '';
	})()`
	return c.page.CDP.Eval(ctx, expr)
}

// mapBrowserWarning translates DOM warning text into a SendResult using
// the shared tips mapping (English UI texts, mirroring MapSendStatus).
func mapBrowserWarning(text string) SendResult {
	if strings.Contains(text, "too fast") || strings.Contains(text, "发送过快") {
		return SendResult{Terminate: true, Quit: true, Error: "消息发送过快，请休息一下再试"}
	}
	if strings.Contains(text, "3 messages") || strings.Contains(text, "最多发送3条") {
		return Success // 陌生3条上限视为成功
	}
	mapped := mapTips(text)
	if mapped == "" {
		mapped = text
	}
	return SendResult{Terminate: true, Error: mapped}
}

// 卡片消息在模拟通道不支持: terminate 让引擎跳过后续卡片。
var errBrowserCardUnsupported = SendResult{Terminate: true, Error: "模拟通道仅支持文本消息"}

// SendLink is unsupported on the simulated channel.
func (c *BrowserClient) SendLink(ctx context.Context, cid *ConversationID, linkURL, coverURL, title, desc string) (SendResult, error) {
	return errBrowserCardUnsupported, nil
}

// SendVideo is unsupported on the simulated channel.
func (c *BrowserClient) SendVideo(ctx context.Context, cid *ConversationID, videoID string) (SendResult, error) {
	return errBrowserCardUnsupported, nil
}

// SendSticker is unsupported on the simulated channel.
func (c *BrowserClient) SendSticker(ctx context.Context, cid *ConversationID, imageURL string) (SendResult, error) {
	return errBrowserCardUnsupported, nil
}

// SendHomePage is unsupported on the simulated channel.
func (c *BrowserClient) SendHomePage(ctx context.Context, cid *ConversationID, uid string) (SendResult, error) {
	return errBrowserCardUnsupported, nil
}

// Close releases the CDP connection. The AdsPower browser itself stays
// running for reuse (profile reuse keeps the environment warm).
func (c *BrowserClient) Close() error {
	if c.cdp == nil {
		return nil
	}
	c.cdp.Close()
	c.cdp = nil
	c.page = nil
	return nil
}

// mustJSONStrings renders a selector list as a JS array literal.
func mustJSONStrings(sels []string) string {
	quoted := make([]string, len(sels))
	for i, s := range sels {
		// selectors never contain quotes/backslashes in practice;
		// escape defensively anyway
		s = strings.ReplaceAll(s, `\`, `\\`)
		s = strings.ReplaceAll(s, `"`, `\"`)
		quoted[i] = `"` + s + `"`
	}
	return "[" + strings.Join(quoted, ",") + "]"
}
