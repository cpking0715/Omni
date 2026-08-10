// Package adspower integrates with the AdsPower fingerprint browser:
// start browser profiles via Local API and extract data via CDP.
package adspower

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// CDPClient is a minimal Chrome DevTools Protocol client over WebSocket.
type CDPClient struct {
	conn *websocket.Conn
	mu   sync.Mutex
	next int
}

// Cookie mirrors the CDP Network.Cookie shape we need.
type Cookie struct {
	Name   string `json:"name"`
	Value  string `json:"value"`
	Domain string `json:"domain"`
	Path   string `json:"path"`
}

// ConnectCDP dials the browser-level DevTools websocket.
func ConnectCDP(ctx context.Context, wsURL string) (*CDPClient, error) {
	conn, _, err := websocket.DefaultDialer.DialContext(ctx, wsURL, nil)
	if err != nil {
		return nil, fmt.Errorf("连接 CDP: %w", err)
	}
	return &CDPClient{conn: conn, next: 1}, nil
}

func (c *CDPClient) Close() { _ = c.conn.Close() }

// Call sends a CDP command and returns the result object.
func (c *CDPClient) Call(ctx context.Context, method string, params any) (json.RawMessage, error) {
	c.mu.Lock()
	id := c.next
	c.next++
	req := map[string]any{
		"id":     id,
		"method": method,
	}
	if params != nil {
		req["params"] = params
	}
	if err := c.conn.WriteJSON(req); err != nil {
		c.mu.Unlock()
		return nil, fmt.Errorf("发送 CDP 命令 %s: %w", method, err)
	}
	c.mu.Unlock()

	deadline := time.Now().Add(30 * time.Second)
	_ = c.conn.SetReadDeadline(deadline)
	for {
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			return nil, fmt.Errorf("读取 CDP 响应 %s: %w", method, err)
		}
		var msg struct {
			ID     int             `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  *struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if err := json.Unmarshal(data, &msg); err != nil {
			continue // event frames, not responses
		}
		if msg.ID != id {
			continue
		}
		if msg.Error != nil {
			return nil, fmt.Errorf("CDP %s 错误: %s", method, msg.Error.Message)
		}
		return msg.Result, nil
	}
}

// GetAllCookies returns all browser cookies.
func (c *CDPClient) GetAllCookies(ctx context.Context) ([]Cookie, error) {
	res, err := c.Call(ctx, "Network.getAllCookies", nil)
	if err != nil {
		return nil, err
	}
	var out struct {
		Cookies []Cookie `json:"cookies"`
	}
	if err := json.Unmarshal(res, &out); err != nil {
		return nil, fmt.Errorf("解析 cookies: %w", err)
	}
	return out.Cookies, nil
}

// WaitEvent blocks until a CDP event with the given method arrives (or
// timeout). Returns the event params. Not safe for concurrent use with Call.
func (c *CDPClient) WaitEvent(method string, timeout time.Duration) (json.RawMessage, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		_ = c.conn.SetReadDeadline(deadline)
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			return nil, fmt.Errorf("等待事件 %s: %w", method, err)
		}
		var msg struct {
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if err := json.Unmarshal(data, &msg); err != nil {
			continue
		}
		if msg.Method == method {
			return msg.Params, nil
		}
	}
	return nil, fmt.Errorf("等待事件 %s 超时", method)
}

// WaitEventAny reads the next CDP event and returns (method, params).
// Response frames are skipped. Not safe for concurrent use with Call.
func (c *CDPClient) WaitEventAny(timeout time.Duration) (string, json.RawMessage, error) {
	deadline := time.Now().Add(timeout)
	_ = c.conn.SetReadDeadline(deadline)
	_, data, err := c.conn.ReadMessage()
	if err != nil {
		return "", nil, fmt.Errorf("等待事件: %w", err)
	}
	var msg struct {
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
	}
	if err := json.Unmarshal(data, &msg); err != nil {
		return "", nil, nil // response frame, skip
	}
	return msg.Method, msg.Params, nil
}

// Eval runs a JS expression in the page and returns the string value.
func (c *CDPClient) Eval(ctx context.Context, expression string) (string, error) {
	res, err := c.Call(ctx, "Runtime.evaluate", map[string]any{
		"expression":    expression,
		"returnByValue": true,
	})
	if err != nil {
		return "", err
	}
	var out struct {
		Result struct {
			Type  string `json:"type"`
			Value any    `json:"value"`
		} `json:"result"`
		ExceptionDetails *struct {
			Text      string `json:"text"`
			Exception struct {
				Description string `json:"description"`
			} `json:"exception"`
		} `json:"exceptionDetails"`
	}
	if err := json.Unmarshal(res, &out); err != nil {
		return "", fmt.Errorf("解析 evaluate: %w", err)
	}
	if out.ExceptionDetails != nil {
		if out.ExceptionDetails.Exception.Description != "" {
			return "", fmt.Errorf("JS 异常: %s", out.ExceptionDetails.Exception.Description)
		}
		return "", fmt.Errorf("JS 异常: %s", out.ExceptionDetails.Text)
	}
	switch v := out.Result.Value.(type) {
	case string:
		return v, nil
	case nil:
		return "", nil
	default:
		b, _ := json.Marshal(v)
		return string(b), nil
	}
}
