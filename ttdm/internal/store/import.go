package store

import (
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// ImportResult is one account parsed from CK import text.
// Mirrors AutomaAccountCookie in the decompiled client (DESIGN 2.8).
type ImportResult struct {
	Username      string
	Password      string
	TwoFactorCode string
	Email         string
	EmailPassword string
	Cookies       []Cookie
	// UID overrides the uid derived from multi_sids (JSON format "uid" field).
	UID int64
	// Extension fields: device_id / uage / platFromUrl / xtoken.
	DeviceID    string
	UserAgent   string
	QueryParams string // platFromUrl raw value
	XToken      string
}

// totpSecret matches a TOTP base32 secret (16-64 chars), used to detect the
// optional 2FA segment in ---- format (RegexHelper.CheckTwoFactorCode).
var totpSecret = regexp.MustCompile(`^[A-Z2-7]{16,64}$`)

// ParseImport parses CK import text in the 4 formats of DESIGN 2.8:
//  1. full JSON: [{"uid":"...", "cookies":{"name":"value",...}}] (or single object;
//     "cookie"/"cookies"/"Cookie"/"Cookies" keys accepted, value is a name→value map
//     or a cookie array; extension keys device_id/uage/platFromUrl/xtoken supported)
//  2. cookie JSON array: [{"name":"sessionid","value":"...","domain":...},...]
//  3. cookie string lines: sessionid=...; ttwid=...; ... (optional "xxx | Cookies: ..." prefix)
//  4. ---- segments: username----password----[2FA]----[email]----[email-pwd]----<cookie string>
//
// Multiple accounts per input are supported for formats 1/3/4 (JSON array or
// one entry per line). A single line without '=' and without '----' is an error.
func ParseImport(text string) ([]*ImportResult, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil, fmt.Errorf("导入内容为空")
	}

	// JSON formats (1 & 2)
	if strings.HasPrefix(text, "[") || strings.HasPrefix(text, "{") {
		if items, err := parseImportJSON(text); err == nil {
			return items, nil
		}
		// fall through: some cookie strings legitimately start with '['? no —
		// '[' only appears in JSON arrays, so a JSON parse failure is fatal here.
		if strings.HasPrefix(text, "[") {
			// still try cookie-array-only interpretation happened inside parseImportJSON
			return nil, fmt.Errorf("JSON 解析失败")
		}
	}

	// line-based formats (3 & 4)
	var out []*ImportResult
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		item, err := parseImportLine(line)
		if err != nil {
			return nil, err
		}
		if item != nil {
			out = append(out, item)
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("未解析出任何账号")
	}
	return out, nil
}

// parseImportJSON handles format 1 (full JSON) and format 2 (cookie array).
func parseImportJSON(text string) ([]*ImportResult, error) {
	// format 1 probe: array of objects carrying a cookies/cookie map
	var probe []map[string]json.RawMessage
	if strings.HasPrefix(text, "[") {
		if err := json.Unmarshal([]byte(text), &probe); err == nil && len(probe) > 0 {
			first := probe[0]
			if _, ok := pickCookieKey(first); ok {
				return parseFullJSON(probe)
			}
		}
	}
	// format 1 single object
	if strings.HasPrefix(text, "{") {
		var obj map[string]json.RawMessage
		if err := json.Unmarshal([]byte(text), &obj); err == nil {
			if _, ok := pickCookieKey(obj); ok {
				return parseFullJSON([]map[string]json.RawMessage{obj})
			}
		}
	}
	// format 2: plain cookie array (single account)
	cookies, err := ParseCookies(text)
	if err != nil {
		return nil, err
	}
	return []*ImportResult{{Cookies: cookies}}, nil
}

// pickCookieKey finds the cookie payload key (cookies/cookie/Cookies/Cookie).
func pickCookieKey(obj map[string]json.RawMessage) (json.RawMessage, bool) {
	for _, k := range []string{"cookies", "cookie", "Cookies", "Cookie"} {
		if v, ok := obj[k]; ok {
			return v, true
		}
	}
	return nil, false
}

// parseFullJSON decodes format-1 items: {uid, cookies: map[string]string|array, extensions...}.
func parseFullJSON(items []map[string]json.RawMessage) ([]*ImportResult, error) {
	var out []*ImportResult
	for _, raw := range items {
		item := &ImportResult{}

		if uidRaw, ok := raw["uid"]; ok {
			var uidStr string
			if json.Unmarshal(uidRaw, &uidStr) == nil {
				item.UID, _ = strconv.ParseInt(uidStr, 10, 64)
			} else {
				var uidNum int64
				if json.Unmarshal(uidRaw, &uidNum) == nil {
					item.UID = uidNum
				}
			}
		}

		cookieRaw, ok := pickCookieKey(raw)
		if !ok {
			return nil, fmt.Errorf("JSON 缺少 cookies/cookie 字段")
		}
		// cookies as name→value map
		var asMap map[string]string
		if json.Unmarshal(cookieRaw, &asMap) == nil && len(asMap) > 0 {
			for name, value := range asMap {
				item.Cookies = append(item.Cookies, Cookie{
					Name:   name,
					Value:  value,
					Domain: ".tiktok.com",
				})
			}
		} else {
			// cookies as array of cookie objects
			var asArr []Cookie
			if err := json.Unmarshal(cookieRaw, &asArr); err != nil || len(asArr) == 0 {
				return nil, fmt.Errorf("cookies 字段既不是 name→value 映射也不是 cookie 数组")
			}
			item.Cookies = asArr
		}

		// extension fields (flat or nested under "extensions")
		exts := raw
		if nested, ok := raw["extensions"]; ok {
			var m map[string]json.RawMessage
			if json.Unmarshal(nested, &m) == nil {
				exts = m
			}
		}
		extStr := func(key string) string {
			if v, ok := exts[key]; ok {
				var s string
				if json.Unmarshal(v, &s) == nil {
					return strings.TrimSpace(s)
				}
			}
			return ""
		}
		item.DeviceID = extStr("device_id")
		item.UserAgent = extStr("uage")
		item.QueryParams = extStr("platFromUrl")
		item.XToken = extStr("xtoken")
		// device_id may be embedded in platFromUrl query string
		if item.DeviceID == "" && item.QueryParams != "" {
			if u, err := url.Parse(item.QueryParams); err == nil {
				if v := u.Query().Get("device_id"); v != "" {
					item.DeviceID = v
				}
			} else if qs, err := url.ParseQuery(item.QueryParams); err == nil {
				if v := qs.Get("device_id"); v != "" {
					item.DeviceID = v
				}
			}
		}
		out = append(out, item)
	}
	return out, nil
}

// parseImportLine handles one line of formats 3/4.
func parseImportLine(line string) (*ImportResult, error) {
	// ---- segments format
	if strings.Contains(line, "----") {
		segments := splitSegments(line)
		if len(segments) == 0 {
			return nil, nil
		}
		return parseSegments(segments)
	}
	// "xxx | Cookies: name=value;..." prefix (ParseLine fallback)
	if parts := strings.SplitN(line, "|", 2); len(parts) == 2 {
		tail := strings.TrimSpace(parts[1])
		if strings.HasPrefix(strings.ToLower(tail), "cookies:") {
			line = strings.TrimSpace(tail[len("Cookies:"):])
		}
	}
	cookies, err := ParseCookies(line)
	if err != nil {
		return nil, fmt.Errorf("解析 Cookie 行失败: %w", err)
	}
	return &ImportResult{Cookies: cookies}, nil
}

// splitSegments splits on ---- and trims, dropping empties
// (StringSplitOptions.RemoveEmptyEntries|TrimEntries).
func splitSegments(line string) []string {
	parts := strings.Split(line, "----")
	var out []string
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// parseSegments maps segments to username/password/[2FA]/[email]/[email-pwd]/cookie
// — the last segment is always treated as the cookie text when it parses as cookies
// (mirrors ParseSegments in AccountImportCookieDialog).
func parseSegments(segments []string) (*ImportResult, error) {
	item := &ImportResult{}
	var cookies []Cookie
	lastIsCookie := false
	if c, err := ParseCookies(segments[len(segments)-1]); err == nil && len(c) > 0 {
		cookies = c
		lastIsCookie = true
	}
	if len(segments) == 1 && lastIsCookie {
		item.Cookies = cookies
		return item, nil
	}
	i := 0
	next := func() (string, bool) {
		// stop before consuming the trailing cookie segment
		if i >= len(segments) || (i == len(segments)-1 && lastIsCookie) {
			return "", false
		}
		s := segments[i]
		i++
		return s, true
	}
	if s, ok := next(); ok {
		item.Username = s
	}
	if s, ok := next(); ok {
		item.Password = s
	}
	if s, ok := next(); ok {
		if totpSecret.MatchString(s) {
			item.TwoFactorCode = s
		} else {
			// not a 2FA secret: treat as email (shift back)
			item.Email = s
		}
	}
	if item.Email == "" {
		if s, ok := next(); ok {
			item.Email = s
		}
	}
	if s, ok := next(); ok {
		item.EmailPassword = s
	}
	if lastIsCookie {
		item.Cookies = cookies
	}
	if len(item.Cookies) == 0 {
		return nil, fmt.Errorf("分段格式缺少有效 Cookie 段")
	}
	return item, nil
}

// ToAccount converts a parse result into a storable Account.
// deviceID may come from the import text (JSON extensions); when empty the
// caller must supply one (or derive from ttwid via TTWidDeviceID).
func (r *ImportResult) ToAccount(deviceID, proxyURL string) (*Account, error) {
	if len(r.Cookies) == 0 {
		return nil, fmt.Errorf("Cookie 为空")
	}
	_, storeIDC, uid, err := ExtractAccountInfo(r.Cookies)
	if err != nil {
		return nil, err
	}
	if r.UID > 0 {
		uid = r.UID
	}
	if uid <= 0 {
		return nil, fmt.Errorf("无法推导 uid (需要 multi_sids cookie 或 JSON uid 字段)")
	}
	if deviceID == "" {
		deviceID = r.DeviceID
	}
	if deviceID == "" {
		deviceID = TTWidDeviceID(r.Cookies)
	}
	if deviceID == "" {
		return nil, fmt.Errorf("缺少 device_id (请提供 --device-id，或确保 cookie 含 ttwid)")
	}
	now := nowMillis()
	return &Account{
		Platform:  "tiktok",
		Username:  r.Username,
		UID:       uid,
		DeviceID:  deviceID,
		StoreIDC:  storeIDC,
		Cookies:   r.Cookies,
		ProxyURL:  proxyURL,
		UserAgent: r.UserAgent,
		Status:    StatusLoggedIn,
		CreatedAt: now,
		UpdatedAt: now,
	}, nil
}
