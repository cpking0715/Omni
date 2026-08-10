// 临时验证: 修复 BuildWebSendURL 后真实发送, 预期 200+7193 业务响应 (非 204)
package main

import (
	"bytes"
	"context"
	"crypto/rand"
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
	toUID  = 7366359960223482885
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: websend_probe <text>")
		os.Exit(1)
	}
	text := os.Args[1]

	// 1. 启动浏览器拿 debug port
	start, err := httpGet(fmt.Sprintf("http://127.0.0.1:50325/api/v1/browser/start?user_id=%s", userID), apiKey)
	if err != nil {
		fmt.Fprintln(os.Stderr, "browser start:", err)
		os.Exit(1)
	}
	port := 0
	switch v := start["debug_port"].(type) {
	case float64:
		port = int(v)
	case string:
		fmt.Sscanf(v, "%d", &port)
	}

	// 2. 抓 cookies (从 /json/list 找到页面 WS, 用 CDP getAllCookies)
	cookies, err := fetchCookies(int(port))
	if err != nil {
		fmt.Fprintln(os.Stderr, "cookies:", err)
		os.Exit(1)
	}

	// 3. 构建账号 (deviceID 来自抓包 body 的 device_id KV)
	acc := &store.Account{UID: 7664958044560016398, DeviceID: "7669334412366218765"}
	for _, c := range cookies {
		acc.Cookies = append(acc.Cookies, store.Cookie{Name: c["name"], Value: c["value"], Domain: c["domain"]})
	}

	// 4. 加载签名快照
	snap, err := protocol.LoadWebSignSnapshot("d:/MyProjects/OmniMarket/ttdm/bin/m6/sign_snapshot.json")
	if err != nil {
		fmt.Fprintln(os.Stderr, "snapshot:", err)
		os.Exit(1)
	}

	// 5. 发送
	client, err := protocol.NewWebClient(acc)
	if err != nil {
		fmt.Fprintln(os.Stderr, "client:", err)
		os.Exit(1)
	}
	client.SetWebSign(snap)
	urlStr := protocol.BuildWebSendURL(snap.Sign)
	fmt.Printf("URL: %s\n", urlStr)
	fmt.Printf("URL len: %d, cookies: %d, uid: %d\n", len(urlStr), len(acc.Cookies), acc.UID)
	fmt.Printf("SystemProxy: %q\n", protocol.SystemProxy())
	// 逐字节对比 send_body.txt 中的原始 URL
	if raw, err := os.ReadFile("d:/MyProjects/OmniMarket/ttdm/bin/m6/send_body.txt"); err == nil {
		s := string(raw)
		i := strings.Index(s, "url=https://im-api.tiktok.com/v1/message/send?")
		if i > 0 {
			seg := s[i+4:]
			if j := strings.Index(seg, " status="); j > 0 {
				seg = seg[:j]
			}
			orig := strings.TrimSpace(seg)
			fmt.Printf("fileURL len: %d, equal: %v\n", len(orig), orig == urlStr)
			if orig != urlStr {
				for k := 0; k < len(orig) && k < len(urlStr); k++ {
					if orig[k] != urlStr[k] {
						fmt.Printf("first diff at %d: file=%q url=%q\n", k, orig[k-20:k+20], urlStr[k-20:k+20])
						break
					}
				}
			}
		}
	}
	fmt.Printf("CookieString len: %d\n", len(acc.CookieString()))
	// 复制 SendWebText 逻辑并打印响应头 (诊断 204 来源); mode=once 时跳过
	if len(os.Args) < 3 || os.Args[2] != "once" {
		manualSend(acc, toUID, text, snap, urlStr)
	}
	res, err := client.SendWebText(context.Background(), toUID, text, "")
	fmt.Printf("result: %+v\n", res)
	if err != nil {
		fmt.Println("error:", err)
		os.Exit(1)
	}
	if res.Error == "" {
		fmt.Println("SENT (204/ok)")
	} else {
		fmt.Println("BLOCKED:", res.Error)
	}
}

// manualSend 复制 SendWebText 的请求构造, 保存响应体供 decodeframe 分析。
func manualSend(acc *store.Account, toUID int64, text string, snap *protocol.WebSignSnapshot, urlStr string) {
	body := protocol.BuildWebSendBody(acc.UID, toUID, "7669334412366218765", text, uuid(), snap.Meta)
	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, urlStr, bytes.NewReader(body))
	if err != nil {
		fmt.Println("req err:", err)
		os.Exit(1)
	}
	req.Header.Set("Content-Type", "application/x-protobuf")
	req.Header.Set("Origin", "https://www.tiktok.com")
	req.Header.Set("Referer", "https://www.tiktok.com/messages")
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36")
	if cs := acc.CookieString(); cs != "" {
		req.Header.Set("Cookie", cs)
	}
	// 与 SendWebText 相同的 transport: SystemProxy
	proxyURL := protocol.SystemProxy()
	tr := &http.Transport{}
	if proxyURL != "" {
		if pu, err := url.Parse(proxyURL); err == nil {
			tr.Proxy = http.ProxyURL(pu)
		}
	}
	client2 := &http.Client{Transport: tr, Timeout: 30 * time.Second}
	resp, err := client2.Do(req)
	if err != nil {
		fmt.Println("send err:", err)
		os.Exit(1)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	fmt.Printf("=== manual send: HTTP %d, bodylen=%d, proto=%s ===\n", resp.StatusCode, len(raw), resp.Proto)
	for k, vv := range resp.Header {
		fmt.Printf("  HDR %s: %v\n", k, vv)
	}
	os.WriteFile("d:/MyProjects/OmniMarket/ttdm/bin/m6/probe_manual_body.bin", raw, 0644)
}

func httpGet(url, key string) (map[string]any, error) {
	req, _ := http.NewRequest("GET", url, nil)
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, err
	}
	if d, ok := m["data"].(map[string]any); ok {
		return d, nil
	}
	return m, nil
}

func fetchCookies(port int) ([]map[string]string, error) {
	// 1. 从 /json/list 找 TikTok 页面 WS
	var targets []struct {
		Type                string `json:"type"`
		URL                 string `json:"url"`
		WebSocketDebuggerURL string `json:"webSocketDebuggerUrl"`
	}
	resp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/json/list", port))
	if err != nil {
		return nil, err
	}
	raw, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err := json.Unmarshal(raw, &targets); err != nil {
		return nil, err
	}
	wsURL := ""
	for _, t := range targets {
		if t.Type == "page" && contains(t.URL, "tiktok.com") {
			wsURL = t.WebSocketDebuggerURL
			break
		}
	}
	if wsURL == "" {
		return nil, fmt.Errorf("no tiktok page target")
	}
	// 2. WS getAllCookies
	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	if err := c.WriteJSON(map[string]any{"id": 1, "method": "Network.getAllCookies"}); err != nil {
		return nil, err
	}
	c.SetReadDeadline(time.Now().Add(10 * time.Second))
	var msg struct {
		ID     int `json:"id"`
		Result struct {
			Cookies []map[string]any `json:"cookies"`
		} `json:"result"`
	}
	for {
		if err := c.ReadJSON(&msg); err != nil {
			return nil, err
		}
		if msg.ID == 1 {
			break
		}
	}
	var out []map[string]string
	for _, cm := range msg.Result.Cookies {
		dom, _ := cm["domain"].(string)
		if !(contains(dom, "tiktok.com") || contains(dom, "tiktokw.us") || contains(dom, "tiktokv.us")) {
			continue
		}
		name, _ := cm["name"].(string)
		val, _ := cm["value"].(string)
		out = append(out, map[string]string{"name": name, "value": val, "domain": dom})
	}
	return out, nil
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

func uuid() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
