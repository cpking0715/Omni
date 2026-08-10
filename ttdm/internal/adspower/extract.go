package adspower

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	"ttdm/internal/store"
)

// numericID matches a TikTok numeric device id (19 digits).
var numericID = regexp.MustCompile(`\d{19}`)

// TikTokData is the extracted account material needed by ttdm.
type TikTokData struct {
	Cookies  []store.Cookie
	DeviceID string
	UID      int64
	StoreIDC string
	Sid      string
}

// CDP is the minimal DevTools surface ExtractTikTok needs; CDPClient
// implements it, tests use fakes.
type CDP interface {
	GetAllCookies(ctx context.Context) ([]Cookie, error)
	Eval(ctx context.Context, expression string) (string, error)
}

var _ CDP = (*CDPClient)(nil)

// PageWSURL resolves the first page target's websocket from the debug port.
func PageWSURL(ctx context.Context, debugPort string) (string, error) {
	url := fmt.Sprintf("http://127.0.0.1:%s/json/list", debugPort)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("获取页面列表: %w", err)
	}
	defer resp.Body.Close()
	var targets []struct {
		Type    string `json:"type"`
		URL     string `json:"url"`
		WSURL   string `json:"webSocketDebuggerUrl"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&targets); err != nil {
		return "", fmt.Errorf("解析页面列表: %w", err)
	}
	// prefer a tiktok page; fall back to any page target
	for _, t := range targets {
		if t.Type == "page" && strings.Contains(t.URL, "tiktok.com") && t.WSURL != "" {
			return t.WSURL, nil
		}
	}
	for _, t := range targets {
		if t.Type == "page" && t.WSURL != "" {
			return t.WSURL, nil
		}
	}
	return "", fmt.Errorf("没有可用页面 target (浏览器可能未打开任何页面)")
}

// ExtractTikTok pulls cookies and device id from a running browser profile.
func ExtractTikTok(ctx context.Context, cdp CDP) (*TikTokData, error) {
	cookies, err := cdp.GetAllCookies(ctx)
	if err != nil {
		return nil, fmt.Errorf("获取 cookies: %w", err)
	}

	var ttk []store.Cookie
	for _, c := range cookies {
		if strings.Contains(c.Domain, "tiktok.com") {
			ttk = append(ttk, store.Cookie{
				Name:   c.Name,
				Value:  c.Value,
				Domain: c.Domain,
				Path:   c.Path,
			})
		}
	}
	if len(ttk) == 0 {
		return nil, fmt.Errorf("浏览器中没有 tiktok.com 的 cookie，请确认已登录 TikTok")
	}

	// device id lives in localStorage on the TikTok site
	deviceID := ""
	for _, key := range []string{"tiktok_device_id", "device_id"} {
		v, err := cdp.Eval(ctx, "localStorage.getItem('"+key+"')")
		if err == nil && v != "" && v != "null" && v != "undefined" {
			deviceID = strings.Trim(v, `"`)
			if deviceID != "" {
				break
			}
		}
	}
	// fallback 1: scan every localStorage value for a 19-digit numeric id
	if deviceID == "" {
		expr := `(() => { const out=[]; for(let i=0;i<localStorage.length;i++){ const k=localStorage.key(i); const v=localStorage.getItem(k); if(v && /^\d{19}$/.test(v.trim())) out.push(k+':'+v.trim()); } return out.join('|'); })()`
		if v, err := cdp.Eval(ctx, expr); err == nil && v != "" {
			// v 形如 "shopNotificationWID:7669334412366218765|ttwid:7669334412366218765"
			// 只取第一个 19 位纯数字
			if m := numericID.FindString(v); m != "" {
				deviceID = m
			}
		}
	}
	// fallback 2: some profiles keep device_id in a cookie
	if deviceID == "" {
		for _, c := range ttk {
			if c.Name == "cdid2" || c.Name == "tt_webid" || c.Name == "s_v_web_id" {
				deviceID = c.Value
				break
			}
		}
	}
	// fallback 3: ttwid embeds the device id in its decoded JSON ("d" field)
	if deviceID == "" {
		for _, c := range ttk {
			if c.Name == "ttwid" {
				dec, err := url.QueryUnescape(c.Value)
				if err != nil {
					dec = c.Value
				}
				var m map[string]any
				if json.Unmarshal([]byte(dec), &m) == nil {
					if d, ok := m["d"].(string); ok && len(d) > 8 {
						deviceID = d
					}
				}
				break
			}
		}
	}

	_, storeIDC, uid, err := store.ExtractAccountInfo(ttk)
	if err != nil {
		return nil, fmt.Errorf("从 cookie 提取账号信息失败: %w", err)
	}
	sid := ""
	if s, _, _, e := store.ExtractAccountInfo(ttk); e == nil {
		sid = s
	}

	return &TikTokData{
		Cookies:  ttk,
		DeviceID: deviceID,
		UID:      uid,
		StoreIDC: storeIDC,
		Sid:      sid,
	}, nil
}
