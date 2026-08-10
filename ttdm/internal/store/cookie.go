package store

import (
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Cookie is a single browser cookie in the TikTok account format.
type Cookie struct {
	Name     string `json:"name"`
	Value    string `json:"value"`
	Domain   string `json:"domain"`
	Path     string `json:"path,omitempty"`
	Expires  string `json:"expires,omitempty"`
	HttpOnly bool   `json:"httpOnly,omitempty"`
	Secure   bool   `json:"secure,omitempty"`
	SameSite string `json:"sameSite,omitempty"`
}

// ParseCookies parses either a JSON array of cookies
// ([{"name":...,"value":...},...]) or a raw cookie header string
// ("name=value;name2=value2;...").
func ParseCookies(text string) ([]Cookie, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil, fmt.Errorf("empty cookie string")
	}
	if strings.HasPrefix(text, "[") {
		var cookies []Cookie
		if err := json.Unmarshal([]byte(text), &cookies); err != nil {
			return nil, fmt.Errorf("parse cookie JSON: %w", err)
		}
		return cookies, nil
	}
	// Raw header format: name=value; name=value
	var cookies []Cookie
	for _, pair := range strings.Split(text, ";") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		idx := strings.Index(pair, "=")
		if idx <= 0 {
			continue
		}
		cookies = append(cookies, Cookie{
			Name:  strings.TrimSpace(pair[:idx]),
			Value: strings.TrimSpace(pair[idx+1:]),
		})
	}
	if len(cookies) == 0 {
		return nil, fmt.Errorf("no cookies found in input")
	}
	return cookies, nil
}

// MarshalCookies serializes cookies to the JSON storage format.
func MarshalCookies(cookies []Cookie) (string, error) {
	b, err := json.Marshal(cookies)
	if err != nil {
		return "", fmt.Errorf("marshal cookies: %w", err)
	}
	return string(b), nil
}

// CookieString builds the "name=value;name=value" header string from
// TikTok-domain cookies only (mirrors TikTokAccount.GetCookieString()).
func CookieString(cookies []Cookie) string {
	parts := make([]string, 0, len(cookies))
	for _, c := range cookies {
		if c.Domain != "" && !strings.HasSuffix(c.Domain, ".tiktok.com") {
			continue
		}
		parts = append(parts, c.Name+"="+c.Value)
	}
	return strings.Join(parts, ";")
}

// ExtractAccountInfo pulls the derived fields the IM protocol needs from the
// cookie set: sid (sessionid/sid_tt), storeIdc (store-idc) and uid
// (multi_sids, URL-decoded, first ":" segment as int64).
func ExtractAccountInfo(cookies []Cookie) (sid string, storeIDC string, uid int64, err error) {
	for _, c := range cookies {
		switch c.Name {
		case "sessionid", "sid_tt":
			if sid == "" {
				sid = c.Value
			}
		case "store-idc":
			storeIDC = c.Value
		case "multi_sids":
			if uid == 0 {
				decoded, decErr := url.QueryUnescape(c.Value)
				if decErr != nil {
					decoded = c.Value
				}
				first := strings.SplitN(decoded, ":", 2)[0]
				uid, _ = strconv.ParseInt(first, 10, 64)
			}
		}
	}
	if sid == "" && storeIDC == "" && uid == 0 {
		return "", "", 0, fmt.Errorf("cookie set lacks sessionid/store-idc/multi_sids; cannot derive account info")
	}
	return sid, storeIDC, uid, nil
}

// TTWid returns the URL-decoded ttwid cookie value (prefers .tiktok.com
// domain), or "" when absent. Web 通道（通道二）连接参数需要原始 ttwid。
func TTWid(cookies []Cookie) string {
	fallback := ""
	for _, c := range cookies {
		if c.Name != "ttwid" {
			continue
		}
		if c.Domain == "" || strings.HasSuffix(c.Domain, ".tiktok.com") {
			dec, err := url.QueryUnescape(c.Value)
			if err != nil {
				dec = c.Value
			}
			if c.Domain == ".tiktok.com" {
				return dec
			}
			if fallback == "" {
				fallback = dec
			}
		}
	}
	return fallback
}

// ttwidDeviceIDNum matches a 19-digit TikTok device id embedded in ttwid.
var ttwidDeviceIDNum = regexp.MustCompile(`\d{19}`)

// TTWidDeviceID extracts the device id embedded in the ttwid cookie
// (DESIGN 5.4.1: access_key 素材 = ttwid 中的 19 位设备 ID).
// Two layouts are handled: decoded JSON with a "d" field, or a bare
// 19-digit run inside the decoded token. Returns "" when not found.
func TTWidDeviceID(cookies []Cookie) string {
	ttwid := TTWid(cookies)
	if ttwid == "" {
		return ""
	}
	var m map[string]any
	if json.Unmarshal([]byte(ttwid), &m) == nil {
		if d, ok := m["d"].(string); ok && len(d) > 8 {
			return d
		}
	}
	if id := ttwidDeviceIDNum.FindString(ttwid); id != "" {
		return id
	}
	return ""
}

// nowMillis returns the current time in unix milliseconds.
func nowMillis() int64 { return time.Now().UnixMilli() }
