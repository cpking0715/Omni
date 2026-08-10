// 精确对照: 直连/代理 × body 来源(mkbody vs SendWebText 生成) × cookie 格式
package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/gorilla/websocket"

	"ttdm/internal/protocol"
	"ttdm/internal/store"
)

const (
	apiKey = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
	userID = "k1fan6kh"
	urlF   = "d:/MyProjects/OmniMarket/ttdm/bin/m6/send_body.txt"
	bodyF  = "d:/MyProjects/OmniMarket/ttdm/bin/m6/body14.bin"
	snapF  = "d:/MyProjects/OmniMarket/ttdm/bin/m6/sign_snapshot.json"
)

func main() {
	// 1. URL
	content, _ := os.ReadFile(urlF)
	cdp := string(content)[strings.Index(string(content), "=== CDP NETWORK EVENTS ==="):]
	u := ""
	for _, line := range strings.Split(cdp, "\n") {
		if strings.Contains(line, "url=https://im-api.tiktok.com/v1/message/send?") {
			line = line[strings.Index(line, "url=")+4:]
			if i := strings.Index(line, " status="); i > 0 {
				line = line[:i]
			}
			u = strings.TrimSpace(line)
			break
		}
	}
	// 2. body 两种来源
	bodyFile, _ := os.ReadFile(bodyF)
	snap, err := protocol.LoadWebSignSnapshot(snapF)
	if err != nil {
		fmt.Println("snap:", err)
		return
	}
	bodyNew := protocol.BuildWebSendBody(7664958044560016398, 7366359960223482885, "7669334412366218765",
		"probe15 - body origin test", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", snap.Meta)
	// 3. cookies 两种格式
	cookies := fetchCookies()
	raw := make([]store.Cookie, 0, len(cookies))
	for _, c := range cookies {
		raw = append(raw, store.Cookie{Name: c["name"], Value: c["value"], Domain: c["domain"]})
	}
	cookieGo := store.CookieString(raw) // ";" 分隔, .tiktok.com 域
	cookiePS := ""
	var parts []string
	for _, c := range cookies {
		if strings.Contains(c["domain"], "tiktok.com") || strings.Contains(c["domain"], "tiktokw.us") || strings.Contains(c["domain"], "tiktokv.us") {
			parts = append(parts, c["name"]+"="+c["value"])
		}
	}
	cookiePS = strings.Join(parts, "; ")

	type trial struct {
		label   string
		body    []byte
		cookie  string
		proxy   string
	}
	trials := []trial{
		{"file-body + ps-cookie + direct", bodyFile, cookiePS, ""},
		{"new-body + ps-cookie + direct", bodyNew, cookiePS, ""},
		{"new-body + go-cookie + direct", bodyNew, cookieGo, ""},
		{"file-body + ps-cookie + proxy8686", bodyFile, cookiePS, "http://127.0.0.1:8686"},
		{"new-body + go-cookie + proxy8686", bodyNew, cookieGo, "http://127.0.0.1:8686"},
	}
	for _, t := range trials {
		tr := &http.Transport{}
		if t.proxy != "" {
			p, _ := url.Parse(t.proxy)
			tr.Proxy = http.ProxyURL(p)
		}
		client := &http.Client{Transport: tr, Timeout: 30 * time.Second}
		req, _ := http.NewRequestWithContext(context.Background(), "POST", u, bytes.NewReader(t.body))
		req.Header.Set("Content-Type", "application/x-protobuf")
		req.Header.Set("Cookie", t.cookie)
		req.Header.Set("Origin", "https://www.tiktok.com")
		req.Header.Set("Referer", "https://www.tiktok.com/messages")
		req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36")
		resp, err := client.Do(req)
		if err != nil {
			fmt.Printf("=== %s: ERROR %v ===\n", t.label, err)
			continue
		}
		rawB, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		code := "n/a"
		if len(rawB) > 0 {
			if s := extractStatus(rawB); s != "" {
				code = s
			} else {
				code = fmt.Sprintf("b64:%s", base64.StdEncoding.EncodeToString(rawB)[:60])
			}
		}
		fmt.Printf("=== %s: HTTP %d bodylen=%d code=%s proto=%s ===\n", t.label, resp.StatusCode, len(rawB), code, resp.Proto)
	}
}

// extractStatus 提取 protobuf 中 status_code (f6.f100.f6 JSON)
func extractStatus(raw []byte) string {
	s := string(raw)
	if i := strings.Index(s, `"status_code":`); i > 0 {
		rest := s[i+len(`"status_code":`):]
		if j := strings.Index(rest, `,`); j > 0 {
			return "status=" + rest[:j]
		}
	}
	// 找 "200005" 类错误码 (f4)
	for _, pat := range []string{"200001", "200005"} {
		if strings.Contains(s, pat) {
			return pat
		}
	}
	return ""
}

func fetchCookies() []map[string]string {
	var targets []struct {
		Type                string `json:"type"`
		URL                 string `json:"url"`
		WebSocketDebuggerURL string `json:"webSocketDebuggerUrl"`
	}
	r, _ := http.NewRequest("GET", fmt.Sprintf("http://127.0.0.1:50325/api/v1/browser/start?user_id=%s", userID), nil)
	r.Header.Set("Authorization", "Bearer "+apiKey)
	resp, _ := http.DefaultClient.Do(r)
	var m map[string]any
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	json.Unmarshal(b, &m)
	port := 0
	if d, ok := m["data"].(map[string]any); ok {
		switch v := d["debug_port"].(type) {
		case float64:
			port = int(v)
		case string:
			fmt.Sscanf(v, "%d", &port)
		}
	}
	_ = httpGetJSON(fmt.Sprintf("http://127.0.0.1:%d/json/list", port), &targets)
	wsURL := ""
	for _, t := range targets {
		if t.Type == "page" && strings.Contains(t.URL, "tiktok.com") {
			wsURL = t.WebSocketDebuggerURL
			break
		}
	}
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		return nil
	}
	defer conn.Close()
	conn.WriteJSON(map[string]any{"id": 1, "method": "Network.getAllCookies"})
	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	var msg struct {
		ID     int `json:"id"`
		Result struct {
			Cookies []map[string]any `json:"cookies"`
		} `json:"result"`
	}
	for {
		if err := conn.ReadJSON(&msg); err != nil {
			return nil
		}
		if msg.ID == 1 {
			break
		}
	}
	var out []map[string]string
	for _, cm := range msg.Result.Cookies {
		dom, _ := cm["domain"].(string)
		if !(strings.Contains(dom, "tiktok.com") || strings.Contains(dom, "tiktokw.us") || strings.Contains(dom, "tiktokv.us")) {
			continue
		}
		name, _ := cm["name"].(string)
		val, _ := cm["value"].(string)
		out = append(out, map[string]string{"name": name, "value": val, "domain": dom})
	}
	return out
}

func httpGetJSON(u string, out any) error {
	r, err := http.Get(u)
	if err != nil {
		return err
	}
	defer r.Body.Close()
	b, _ := io.ReadAll(r.Body)
	return json.Unmarshal(b, out)
}
