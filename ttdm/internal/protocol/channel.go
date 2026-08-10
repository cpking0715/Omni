package protocol

import (
	"context"
	"errors"
	"fmt"

	"ttdm/internal/store"
)

// Channel names accepted by task parameters (--channel).
const (
	ChannelAndroid = "android" // 通道一 (HTTP 400, 仅骨架参考)
	ChannelWeb     = "web"     // 通道二
	ChannelBrowser = "browser" // 模拟通道
	ChannelAuto    = "auto"    // Web 优先, 失败降级模拟通道
)

// NewChannelClient builds the IImClient for one account according to the
// channel strategy (DESIGN 5.3 通道状态表):
//
//	android → AndroidClient (骨架, HTTP 400)
//	web     → WebClient (ttwid required)
//	browser → BrowserClient (AdsPower profile + API key required)
//	auto    → AutoClient: Web first, downgrade to browser on connect
//	          failure or ErrWebSendNotImplemented
func NewChannelClient(a *store.Account, channel, adsAPIKey string) (IImClient, error) {
	switch channel {
	case ChannelAndroid:
		return NewAndroidClient(a), nil
	case ChannelWeb:
		return NewWebClient(a)
	case ChannelBrowser:
		return NewBrowserClient(a, adsAPIKey)
	case ChannelAuto, "":
		web, webErr := NewWebClient(a)
		if webErr != nil {
			// no ttwid → go straight to the browser channel
			bc, err := NewBrowserClient(a, adsAPIKey)
			if err != nil {
				return nil, fmt.Errorf("auto 通道初始化失败: web: %v; browser: %v", webErr, err)
			}
			return bc, nil
		}
		return &AutoClient{account: a, adsKey: adsAPIKey, primary: web}, nil
	default:
		return nil, fmt.Errorf("未知通道: %s (可选: android|web|browser|auto)", channel)
	}
}

// AutoClient implements the auto channel strategy: use the Web channel
// while it works, transparently downgrading to the simulated browser
// channel when the Web channel fails to connect or its send payloads are
// not reverse-engineered yet (DESIGN 5.3 决策门).
type AutoClient struct {
	account *store.Account
	adsKey  string

	primary      IImClient // web
	fallback     IImClient // browser, created lazily
	useFallback  bool
	connectedVia string
}

// Compile-time check: AutoClient implements IImClient.
var _ IImClient = (*AutoClient)(nil)

// ConnectedVia reports which channel the last successful Connect used
// ("web" / "browser"), for telemetry.
func (c *AutoClient) ConnectedVia() string { return c.connectedVia }

// Connect tries the Web channel first; on failure downgrades to browser.
func (c *AutoClient) Connect(ctx context.Context, proxyURL string) error {
	if !c.useFallback {
		if err := c.primary.Connect(ctx, proxyURL); err == nil {
			c.connectedVia = "web"
			return nil
		}
		c.useFallback = true // web unusable for this session
	}
	fb, err := c.browserFallback()
	if err != nil {
		return err
	}
	if err := fb.Connect(ctx, proxyURL); err != nil {
		return err
	}
	c.connectedVia = "browser"
	return nil
}

func (c *AutoClient) browserFallback() (IImClient, error) {
	if c.fallback != nil {
		return c.fallback, nil
	}
	bc, err := NewBrowserClient(c.account, c.adsKey)
	if err != nil {
		return nil, fmt.Errorf("Web 通道不可用且模拟通道初始化失败: %w", err)
	}
	c.fallback = bc
	return bc, nil
}

// active returns the client currently responsible for sending, switching
// to the fallback when the primary reports ErrWebSendNotImplemented.
func (c *AutoClient) active(ctx context.Context, proxyURL string) (IImClient, error) {
	if c.useFallback {
		return c.browserFallback()
	}
	return c.primary, nil
}

// downgrade switches to the browser channel after a web-side
// ErrWebSendNotImplemented, connecting it on demand.
func (c *AutoClient) downgrade(ctx context.Context, proxyURL string) (IImClient, error) {
	c.useFallback = true
	fb, err := c.browserFallback()
	if err != nil {
		return nil, err
	}
	if err := fb.Connect(ctx, proxyURL); err != nil {
		return nil, err
	}
	c.connectedVia = "browser"
	return fb, nil
}

// isNotImplemented reports whether the error marks the Web send payloads
// as still being reverse-engineered.
func isNotImplemented(err error) bool {
	return errors.Is(err, ErrWebSendNotImplemented)
}

// CreateConversation forwards to the active channel, downgrading on
// ErrWebSendNotImplemented.
func (c *AutoClient) CreateConversation(ctx context.Context, toUID int64) (*ConversationID, error) {
	cl, err := c.active(ctx, "")
	if err != nil {
		return nil, err
	}
	cid, err := cl.CreateConversation(ctx, toUID)
	if isNotImplemented(err) {
		if cl, err = c.downgrade(ctx, ""); err != nil {
			return nil, err
		}
		return cl.CreateConversation(ctx, toUID)
	}
	return cid, err
}

func (c *AutoClient) send(ctx context.Context, cid *ConversationID,
	call func(IImClient) (SendResult, error)) (SendResult, error) {
	cl, err := c.active(ctx, "")
	if err != nil {
		return SendResult{}, err
	}
	res, err := call(cl)
	if isNotImplemented(err) {
		if cl, err = c.downgrade(ctx, ""); err != nil {
			return SendResult{}, err
		}
		return call(cl)
	}
	return res, err
}

// SendText forwards to the active channel.
func (c *AutoClient) SendText(ctx context.Context, cid *ConversationID, text string) (SendResult, error) {
	return c.send(ctx, cid, func(cl IImClient) (SendResult, error) {
		return cl.SendText(ctx, cid, text)
	})
}

// SendLink forwards to the active channel.
func (c *AutoClient) SendLink(ctx context.Context, cid *ConversationID, linkURL, coverURL, title, desc string) (SendResult, error) {
	return c.send(ctx, cid, func(cl IImClient) (SendResult, error) {
		return cl.SendLink(ctx, cid, linkURL, coverURL, title, desc)
	})
}

// SendVideo forwards to the active channel.
func (c *AutoClient) SendVideo(ctx context.Context, cid *ConversationID, videoID string) (SendResult, error) {
	return c.send(ctx, cid, func(cl IImClient) (SendResult, error) {
		return cl.SendVideo(ctx, cid, videoID)
	})
}

// SendSticker forwards to the active channel.
func (c *AutoClient) SendSticker(ctx context.Context, cid *ConversationID, imageURL string) (SendResult, error) {
	return c.send(ctx, cid, func(cl IImClient) (SendResult, error) {
		return cl.SendSticker(ctx, cid, imageURL)
	})
}

// SendHomePage forwards to the active channel.
func (c *AutoClient) SendHomePage(ctx context.Context, cid *ConversationID, uid string) (SendResult, error) {
	return c.send(ctx, cid, func(cl IImClient) (SendResult, error) {
		return cl.SendHomePage(ctx, cid, uid)
	})
}

// Close releases whichever channels were opened.
func (c *AutoClient) Close() error {
	var firstErr error
	if c.primary != nil {
		if err := c.primary.Close(); err != nil {
			firstErr = err
		}
	}
	if c.fallback != nil {
		if err := c.fallback.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}
