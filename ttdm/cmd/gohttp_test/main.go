// 对照实验: Go http.Client HTTP/1.1 vs HTTP/2 → 判断 204 是否由 HTTP/2 引起
package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"crypto/tls"

	"github.com/gorilla/websocket"
)

const (
	apiKey = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
	userID = "k1fan6kh"
	urlF   = "d:/MyProjects/OmniMarket/ttdm/bin/m6/send_body.txt"
	bodyF  = "d:/MyProjects/OmniMarket/ttdm/bin/m6/body14.bin"
)

func main() {
	// 1. 原始 URL
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
	fmt.Println("URL len:", len(u))

	// 2. body
	body, _ := os.ReadFile(bodyF)
	fmt.Println("body len:", len(body))

	// 3. cookies
	cookies := fetchCookies()
	cookieStr := strings.Join(cookies, "; ")
	fmt.Println("cookie count:", len(cookies))

	// 4. 发送: h2 on vs off × gzip on vs off
	for _, disableH2 := range []bool{true, false} {
		for _, noGzip := range []bool{true, false} {
			tr := &http.Transport{}
			if disableH2 {
				tr.ForceAttemptHTTP2 = false
				tr.TLSNextProto = map[string]func(string, *tls.Conn) http.RoundTripper{} // 空 map 禁用 h2
			}
			if noGzip {
				tr.DisableCompression = true // 不发送 Accept-Encoding: gzip
			}
			client := &http.Client{Transport: tr, Timeout: 30 * time.Second}
			req, _ := http.NewRequestWithContext(context.Background(), "POST", u, bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/x-protobuf")
			req.Header.Set("Cookie", cookieStr)
			req.Header.Set("Origin", "https://www.tiktok.com")
			req.Header.Set("Referer", "https://www.tiktok.com/messages")
			req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36")
			resp, err := client.Do(req)
			label := fmt.Sprintf("h2=%v gzip=%v", !disableH2, !noGzip)
			if err != nil {
				fmt.Printf("=== %s: ERROR %v ===\n", label, err)
				continue
			}
			raw, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			fmt.Printf("=== %s: HTTP %d, body len %d, proto %s ===\n", label, resp.StatusCode, len(raw), resp.Proto)
			if len(raw) > 0 {
				fmt.Printf("  body b64: %s\n", base64.StdEncoding.EncodeToString(raw))
			}
		}
	}
}

func fetchCookies() []string {
	var targets []struct {
		Type                string `json:"type"`
		URL                 string `json:"url"`
		WebSocketDebuggerURL string `json:"webSocketDebuggerUrl"`
	}
	r, _ := http.NewRequest("GET", fmt.Sprintf("http://127.0.0.1:50325/api/v1/browser/start?user_id=%s", userID), nil)
	r.Header.Set("Authorization", "Bearer "+apiKey)
	resp, _ := http.DefaultClient.Do(r)
	// start 返回 debug_port, 再查 /json/list
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
	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		return nil
	}
	defer c.Close()
	c.WriteJSON(map[string]any{"id": 1, "method": "Network.getAllCookies"})
	c.SetReadDeadline(time.Now().Add(10 * time.Second))
	var msg struct {
		ID     int `json:"id"`
		Result struct {
			Cookies []map[string]any `json:"cookies"`
		} `json:"result"`
	}
	for {
		if err := c.ReadJSON(&msg); err != nil {
			return nil
		}
		if msg.ID == 1 {
			break
		}
	}
	var out []string
	for _, cm := range msg.Result.Cookies {
		dom, _ := cm["domain"].(string)
		if !(strings.Contains(dom, "tiktok.com") || strings.Contains(dom, "tiktokw.us") || strings.Contains(dom, "tiktokv.us")) {
			continue
		}
		name, _ := cm["name"].(string)
		val, _ := cm["value"].(string)
		out = append(out, name+"="+val)
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
