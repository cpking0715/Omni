// M6-6 辅助: 从 AdsPower 浏览器导出账号导入 JSON (格式1: full JSON)。
// 输出: {"uid":"...","device_id":"...","cookies":[{name,value,domain},...]}
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

const (
	apiKey = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
	userID = "k1fan6kh"
	uid    = "7664958044560016398"
	devID  = "7669334412366218765"
)

func main() {
	out := os.Args[1]
	// 1. 启动浏览器
	req, _ := http.NewRequest("GET", fmt.Sprintf("http://127.0.0.1:50325/api/v1/browser/start?user_id=%s", userID), nil)
	req.Header.Set("Authorization", "Bearer "+apiKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Fprintln(os.Stderr, "browser start:", err)
		os.Exit(1)
	}
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
	if port == 0 {
		fmt.Fprintln(os.Stderr, "no debug port")
		os.Exit(1)
	}
	// 2. 找 tiktok 页面
	var targets []struct {
		Type                 string `json:"type"`
		URL                  string `json:"url"`
		WebSocketDebuggerURL string `json:"webSocketDebuggerUrl"`
	}
	r2, _ := http.Get(fmt.Sprintf("http://127.0.0.1:%d/json/list", port))
	rb, _ := io.ReadAll(r2.Body)
	r2.Body.Close()
	json.Unmarshal(rb, &targets)
	wsURL := ""
	for _, t := range targets {
		if t.Type == "page" && strings.Contains(t.URL, "tiktok.com") {
			wsURL = t.WebSocketDebuggerURL
			break
		}
	}
	if wsURL == "" {
		fmt.Fprintln(os.Stderr, "no tiktok page")
		os.Exit(1)
	}
	// 3. getAllCookies
	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		fmt.Fprintln(os.Stderr, "cdp dial:", err)
		os.Exit(1)
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
			fmt.Fprintln(os.Stderr, "cdp read:", err)
			os.Exit(1)
		}
		if msg.ID == 1 {
			break
		}
	}
	var cookies []map[string]string
	for _, cm := range msg.Result.Cookies {
		dom, _ := cm["domain"].(string)
		if !(strings.Contains(dom, "tiktok.com") || strings.Contains(dom, "tiktokw.us") || strings.Contains(dom, "tiktokv.us")) {
			continue
		}
		name, _ := cm["name"].(string)
		val, _ := cm["value"].(string)
		cookies = append(cookies, map[string]string{"name": name, "value": val, "domain": dom})
	}
	doc := map[string]any{
		"uid":       uid,
		"device_id": devID,
		"cookies":   cookies,
	}
	raw, _ := json.MarshalIndent([]any{doc}, "", "  ")
	if err := os.WriteFile(out, raw, 0644); err != nil {
		fmt.Fprintln(os.Stderr, "write:", err)
		os.Exit(1)
	}
	fmt.Printf("exported %d cookies -> %s\n", len(cookies), out)
}
