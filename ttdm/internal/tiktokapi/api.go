// Package tiktokapi implements the TikTok HTTP API surface ttdm needs:
// IM permission check (强私筛选) and cookie validity check.
//
// Faithful to the decompiled TikTokApiService, with two deliberate fixes
// (DESIGN 4.5 / 5.11): TLS certificate verification is always enabled and
// every call supports an outbound proxy.
package tiktokapi

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"golang.org/x/net/proxy"
)

// APIDomain resolves the mobile API host from the account's store-idc
// (mirrors TikTokDomains.GetApiDomain).
func APIDomain(storeIDC string) string {
	switch storeIDC {
	case "useast5":
		return "api16-normal-useast5.tiktokv.us"
	case "useast8":
		return "api16-normal-useast8.tiktokv.us"
	case "useast2a":
		return "api16-normal-c-useast2a.tiktokv.com"
	case "alisg":
		return "api16-normal-c-alisg.tiktokv.com"
	case "maliva":
		return "api16-normal-alisg.tiktokv.com"
	default:
		return "api22-normal-c-alisg.tiktokv.com"
	}
}

// Permission result values (MaxMessageCount semantics).
const (
	PermissionNone = 0 // 不可私信
	PermissionOne  = 1 // chat_request_start: 需对方接受, 可发 1 条
	PermissionThree = 3 // chat_stranger_check: 陌生人会话, 可发 3 条
)

// Client carries the sender credentials + transport for API calls.
type Client struct {
	cookie   string
	storeIDC string
	http     *http.Client
}

// NewClient builds a Client. proxyURL may be "" (direct connection), or an
// http(s)/socks5 URL. TLS verification is never disabled.
func NewClient(cookie, storeIDC, proxyURL string) (*Client, error) {
	if strings.TrimSpace(cookie) == "" {
		return nil, fmt.Errorf("cookie 为空")
	}
	transport := &http.Transport{
		DisableCompression: false,
	}
	if proxyURL != "" {
		u, err := url.Parse(proxyURL)
		if err != nil {
			return nil, fmt.Errorf("代理 URL 无效: %w", err)
		}
		switch u.Scheme {
		case "socks5", "socks5h":
			dialer, err := socks5Dialer(u)
			if err != nil {
				return nil, err
			}
			if cd, ok := dialer.(proxy.ContextDialer); ok {
				transport.DialContext = cd.DialContext
			} else {
				transport.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
					return dialer.Dial(network, addr)
				}
			}
		default:
			transport.Proxy = http.ProxyURL(u)
		}
	}
	return &Client{
		cookie:   cookie,
		storeIDC: storeIDC,
		http: &http.Client{
			Transport: transport,
			Timeout:   30 * time.Second,
			// redirects allowed (profile check relies on them)
		},
	}, nil
}

func socks5Dialer(u *url.URL) (proxy.Dialer, error) {
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

// chatNoticeResponse mirrors TikTokChatNoticeResponse. notice_code may be a
// string or a string array in different server versions, so it is decoded
// permissively.
type chatNoticeResponse struct {
	StatusCode int    `json:"status_code"`
	StatusMsg  string `json:"status_msg"`
	Data       struct {
		NoticeCode json.RawMessage `json:"notice_code"`
	} `json:"data"`
}

// noticeCodes decodes notice_code into a flat list of codes.
func (r *chatNoticeResponse) noticeCodes() []string {
	raw := r.Data.NoticeCode
	if len(raw) == 0 {
		return nil
	}
	var single string
	if json.Unmarshal(raw, &single) == nil {
		if single == "" {
			return nil
		}
		return []string{single}
	}
	var multi []string
	if json.Unmarshal(raw, &multi) == nil {
		return multi
	}
	return nil
}

// CheckImPermission decides how many messages the sender may DM the target
// (强私筛选, DESIGN 5.11):
//
//	notice_code contains chat_stranger_check → 3
//	notice_code contains chat_request_start  → 1
//	otherwise                                → 0
func (c *Client) CheckImPermission(ctx context.Context, fromUID int64, toUID string) (int, error) {
	conv := url.QueryEscape(fmt.Sprintf("0:1:%s:%d", toUID, fromUID))
	apiURL := fmt.Sprintf(
		"https://%s/tiktok/v1/im/chat/notice/?to_user_id=%s&conversation_id=%s&source_type=dm_chat&aid=1233&app_name=musical_ly&version_code=250203",
		APIDomain(c.storeIDC), url.QueryEscape(toUID), conv)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, apiURL, nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("sdk-version", "2")
	req.Header.Set("Cookie", c.cookie)

	resp, err := c.http.Do(req)
	if err != nil {
		return 0, fmt.Errorf("采集强私失败: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return 0, fmt.Errorf("采集强私失败: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("采集强私失败: HTTP %d", resp.StatusCode)
	}
	var parsed chatNoticeResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		return 0, fmt.Errorf("采集强私失败: 响应解析失败 %w", err)
	}
	if parsed.StatusCode != 0 {
		return 0, fmt.Errorf("采集强私失败 %s", parsed.StatusMsg)
	}
	return permissionFromCodes(parsed.noticeCodes()), nil
}

// permissionFromCodes maps notice codes to the max message count.
// Extracted for unit testing.
func permissionFromCodes(codes []string) int {
	for _, code := range codes {
		if strings.Contains(code, "chat_stranger_check") {
			return PermissionThree
		}
	}
	for _, code := range codes {
		if strings.Contains(code, "chat_request_start") {
			return PermissionOne
		}
	}
	return PermissionNone
}

// profileUIDRe is the fallback extractor for the login uid on /profile HTML.
var profileUIDRe = regexp.MustCompile(`"Uid"\s*:\s*(\d+)`)

// CheckCookie verifies the sender cookie is still logged in by loading
// https://www.tiktok.com/profile with the mobile UA and extracting the uid
// (mirrors TikTokApiService.CheckCookieAsync). Returns uid>0 when valid.
func (c *Client) CheckCookie(ctx context.Context) (bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://www.tiktok.com/profile", nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("User-Agent", "com.zhiliaoapp.musically/2022502030 (Linux; U; Android 12; en; SM-G9900; Build/V417IR;tt-ok/3.12.13.1)")
	req.Header.Set("Cookie", c.cookie)

	resp, err := c.http.Do(req)
	if err != nil {
		return false, fmt.Errorf("Cookie 校验失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false, fmt.Errorf("Cookie 校验失败: HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return false, err
	}
	return parseProfileUID(string(body)) > 0, nil
}

// parseProfileUID extracts the logged-in uid from profile page HTML.
// Primary path: __UNIVERSAL_DATA_FOR_REHYDRATION__ JSON
// (Scope.AppContext.User.Uid or webapp.user-details userInfo.user.id);
// fallback: raw regex.
func parseProfileUID(html string) int64 {
	const marker = `id="__UNIVERSAL_DATA_FOR_REHYDRATION__"`
	if idx := strings.Index(html, marker); idx >= 0 {
		start := strings.Index(html[idx:], ">")
		end := strings.Index(html[idx:], "</script>")
		if start >= 0 && end > start {
			blob := html[idx+start+1 : idx+end]
			var root map[string]json.RawMessage
			if json.Unmarshal([]byte(blob), &root) == nil {
				if uid := walkUID(root); uid > 0 {
					return uid
				}
			}
		}
	}
	if m := profileUIDRe.FindStringSubmatch(html); m != nil {
		var uid int64
		fmt.Sscanf(m[1], "%d", &uid)
		return uid
	}
	return 0
}

// walkUID navigates known JSON layouts for the uid.
func walkUID(root map[string]json.RawMessage) int64 {
	var asMap func(raw json.RawMessage) map[string]json.RawMessage
	asMap = func(raw json.RawMessage) map[string]json.RawMessage {
		m := map[string]json.RawMessage{}
		_ = json.Unmarshal(raw, &m)
		return m
	}
	// layout 1: __DEFAULT_SCOPE__ → webapp.user-details → userInfo.user.id
	if scope, ok := root["__DEFAULT_SCOPE__"]; ok {
		details := asMap(scope)["webapp.user-details"]
		if details != nil {
			userInfo := asMap(details)["userInfo"]
			if userInfo != nil {
				user := asMap(userInfo)["user"]
				if user != nil {
					var idStr string
					if json.Unmarshal(asMap(user)["id"], &idStr) == nil {
						var uid int64
						fmt.Sscanf(idStr, "%d", &uid)
						if uid > 0 {
							return uid
						}
					}
				}
			}
		}
		// layout 2: AppContext.User.Uid
		for _, key := range []string{"webapp.user-detail", "webapp.user"} {
			detail := asMap(scope)[key]
			if detail == nil {
				continue
			}
			appCtx := asMap(detail)["appContext"]
			if appCtx == nil {
				appCtx = asMap(detail)["AppContext"]
			}
			if appCtx != nil {
				user := asMap(appCtx)["user"]
				if user == nil {
					user = asMap(appCtx)["User"]
				}
				if user != nil {
					userM := asMap(user)
					var uid int64
					for _, k := range []string{"uid", "Uid"} {
						if json.Unmarshal(userM[k], &uid) == nil && uid > 0 {
							return uid
						}
					}
				}
			}
			// layout 3 (2026-08 实测): userInfo.user.id
			userInfo := asMap(detail)["userInfo"]
			if userInfo != nil {
				user := asMap(userInfo)["user"]
				if user != nil {
					var idStr string
					if json.Unmarshal(asMap(user)["id"], &idStr) == nil {
						var uid int64
						fmt.Sscanf(idStr, "%d", &uid)
						if uid > 0 {
							return uid
						}
					}
				}
			}
		}
	}
	return 0
}
