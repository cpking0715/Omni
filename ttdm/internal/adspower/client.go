package adspower

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"
)

// Client talks to the AdsPower Local API.
type Client struct {
	baseURL string
	apiKey  string
	http    *http.Client
}

// NewClient creates an AdsPower Local API client.
func NewClient(apiKey string) *Client {
	return &Client{
		baseURL: "http://127.0.0.1:50325",
		apiKey:  apiKey,
		http:    &http.Client{Timeout: 15 * time.Second},
	}
}

// BrowserInfo describes a browser profile.
type BrowserInfo struct {
	UserID string `json:"user_id"`
	Name   string `json:"name"`
	Remark string `json:"remark"`
	OpenURLs []string `json:"open_urls"`
}

// ListBrowsers returns all browser profiles.
func (c *Client) ListBrowsers(ctx context.Context) ([]BrowserInfo, error) {
	var out struct {
		Code int `json:"code"`
		Msg  string `json:"msg"`
		Data struct {
			List []BrowserInfo `json:"list"`
		} `json:"data"`
	}
	if err := c.get(ctx, "/api/v1/user/list?page=1&page_size=100", &out); err != nil {
		return nil, err
	}
	if out.Code != 0 {
		return nil, fmt.Errorf("AdsPower 错误: %s", out.Msg)
	}
	return out.Data.List, nil
}

// StartBrowser starts (or attaches to) a browser profile and returns the
// browser-level CDP websocket URL plus the debug port (for page targets).
func (c *Client) StartBrowser(ctx context.Context, userID string) (wsURL, debugPort string, err error) {
	var out struct {
		Code int    `json:"code"`
		Msg  string `json:"msg"`
		Data struct {
			Ws struct {
				Puppeteer string `json:"puppeteer"`
				Selenium  string `json:"selenium"`
			} `json:"ws"`
			DebugPort string `json:"debug_port"`
		} `json:"data"`
	}
	if err := c.get(ctx, "/api/v1/browser/start?user_id="+url.QueryEscape(userID), &out); err != nil {
		return "", "", err
	}
	if out.Code != 0 {
		return "", "", fmt.Errorf("AdsPower 启动浏览器失败: %s", out.Msg)
	}
	if out.Data.Ws.Puppeteer == "" && out.Data.DebugPort == "" {
		return "", "", fmt.Errorf("AdsPower 未返回 CDP 地址 (ws 为空)")
	}
	return out.Data.Ws.Puppeteer, out.Data.DebugPort, nil
}

func (c *Client) get(ctx context.Context, path string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.apiKey)
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("AdsPower 请求失败: %w", err)
	}
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf("AdsPower 响应解析失败: %w", err)
	}
	return nil
}
