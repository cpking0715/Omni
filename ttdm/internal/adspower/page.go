package adspower

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// Page wraps a CDPClient with high-level page automation primitives
// (navigate / wait / click / type / screenshot) used by the simulated
// DM channel (模拟通道).
type Page struct {
	CDP *CDPClient
}

// NewPage wraps an existing CDP connection.
func NewPage(cdp *CDPClient) *Page { return &Page{CDP: cdp} }

// Navigate opens the URL and waits until DOM ready (document.readyState
// interactive/complete), polling every 300ms up to timeout.
func (p *Page) Navigate(ctx context.Context, url string, timeout time.Duration) error {
	if _, err := p.CDP.Call(ctx, "Page.navigate", map[string]any{"url": url}); err != nil {
		return fmt.Errorf("导航 %s: %w", url, err)
	}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		state, err := p.CDP.Eval(ctx, "document.readyState")
		if err == nil && (state == "interactive" || state == "complete") {
			return nil
		}
		time.Sleep(300 * time.Millisecond)
	}
	return fmt.Errorf("等待页面加载超时: %s", url)
}

// WaitSelector polls until any of the CSS selectors matches a visible
// element. Returns the matched selector or an error on timeout.
func (p *Page) WaitSelector(ctx context.Context, timeout, interval time.Duration, selectors ...string) (string, error) {
	if len(selectors) == 0 {
		return "", fmt.Errorf("no selectors")
	}
	expr := `(() => {
		const sels = SELECTORS_JSON;
		for (const s of sels) {
			const el = document.querySelector(s);
			if (el && (el.offsetParent !== null || el.getClientRects().length > 0)) return s;
		}
		return '';
	})()`
	selsJSON, _ := json.Marshal(selectors)
	expr = replaceOnce(expr, "SELECTORS_JSON", string(selsJSON))
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		res, err := p.CDP.Eval(ctx, expr)
		if err == nil && res != "" {
			return res, nil
		}
		time.Sleep(interval)
	}
	return "", fmt.Errorf("等待选择器超时: %v", selectors)
}

// SelectorText returns the trimmed text content of the first element
// matching any selector, or "" when absent.
func (p *Page) SelectorText(ctx context.Context, selectors ...string) (string, error) {
	selsJSON, _ := json.Marshal(selectors)
	expr := `(() => {
		for (const s of SELECTORS_JSON) {
			const el = document.querySelector(s);
			if (el) return el.textContent.trim();
		}
		return '';
	})()`
	return p.CDP.Eval(ctx, replaceOnce(expr, "SELECTORS_JSON", string(selsJSON)))
}

// Click clicks the first visible element matching any selector via a real
// mouse event at its center (CDP Input.dispatchMouseEvent). Real mouse
// events are required: the send button is an SVG element (SVGElement has
// no click() method) and React sometimes ignores synthetic el.click().
// Returns true when an element was clicked.
func (p *Page) Click(ctx context.Context, selectors ...string) (bool, error) {
	selsJSON, _ := json.Marshal(selectors)
	expr := `(() => {
		for (const s of SELECTORS_JSON) {
			const el = document.querySelector(s);
			if (!el) continue;
			const r = el.getBoundingClientRect();
			if (r.width > 0 && r.height > 0) {
				return Math.round(r.x + r.width/2) + '|' + Math.round(r.y + r.height/2);
			}
		}
		return '';
	})()`
	res, err := p.CDP.Eval(ctx, replaceOnce(expr, "SELECTORS_JSON", string(selsJSON)))
	if err != nil || res == "" {
		return false, err
	}
	parts := strings.SplitN(res, "|", 2)
	if len(parts) != 2 {
		return false, fmt.Errorf("解析点击坐标失败: %s", res)
	}
	x, err1 := strconv.Atoi(parts[0])
	y, err2 := strconv.Atoi(parts[1])
	if err1 != nil || err2 != nil {
		return false, fmt.Errorf("解析点击坐标失败: %s", res)
	}
	return true, p.MouseClick(ctx, float64(x), float64(y))
}

// MouseClick dispatches real mouse events (move/press/release) at page
// coordinates. React components sometimes ignore synthetic click() events;
// real input events always trigger onClick/onPointerUp handlers.
func (p *Page) MouseClick(ctx context.Context, x, y float64) error {
	for _, e := range []struct {
		name string
		par  map[string]any
	}{
		{"mouseMoved", map[string]any{"type": "mouseMoved", "x": x, "y": y, "button": "none"}},
		{"mousePressed", map[string]any{"type": "mousePressed", "x": x, "y": y, "button": "left", "buttons": 1, "clickCount": 1}},
		{"mouseReleased", map[string]any{"type": "mouseReleased", "x": x, "y": y, "button": "left", "buttons": 0, "clickCount": 1}},
	} {
		if _, err := p.CDP.Call(ctx, "Input.dispatchMouseEvent", e.par); err != nil {
			return fmt.Errorf("%s: %w", e.name, err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	return nil
}

// Type focuses the input element matched by the selectors and types text
// via CDP Input.insertText (real keyboard events, required by Draft.js
// editors). An inputDelay inserts a pause between insertText chunks.
func (p *Page) Type(ctx context.Context, text string, inputDelay time.Duration, selectors ...string) error {
	if ok, err := p.Click(ctx, selectors...); err != nil {
		return err
	} else if !ok {
		return fmt.Errorf("输入框不存在: %v", selectors)
	}
	time.Sleep(300 * time.Millisecond)
	// 强制聚焦 contenteditable (坐标点击可能命中包装层而非编辑区,
	// Draft.js 需要真实焦点才会接收 insertText)
	focusExpr := `(() => {
		const ed = document.querySelector('[contenteditable="true"]');
		if (ed && document.activeElement !== ed) ed.focus();
		return !!ed;
	})()`
	if _, err := p.CDP.Eval(ctx, focusExpr); err != nil {
		return fmt.Errorf("聚焦编辑器失败: %w", err)
	}
	time.Sleep(150 * time.Millisecond)
	// insert in chunks so Draft.js re-renders between keystrokes
	const chunk = 16
	for i := 0; i < len(text); i += chunk {
		end := i + chunk
		if end > len(text) {
			end = len(text)
		}
		if _, err := p.CDP.Call(ctx, "Input.insertText",
			map[string]any{"text": text[i:end]}); err != nil {
			return fmt.Errorf("输入文本失败: %w", err)
		}
		if inputDelay > 0 {
			time.Sleep(inputDelay)
		}
	}
	return nil
}

// Screenshot captures the page as PNG and writes it to path.
func (p *Page) Screenshot(ctx context.Context, path string) error {
	res, err := p.CDP.Call(ctx, "Page.captureScreenshot", map[string]any{"format": "png"})
	if err != nil {
		return err
	}
	var out struct {
		Data string `json:"data"`
	}
	if err := json.Unmarshal(res, &out); err != nil {
		return fmt.Errorf("解析截图: %w", err)
	}
	raw, err := base64.StdEncoding.DecodeString(out.Data)
	if err != nil {
		return fmt.Errorf("解码截图: %w", err)
	}
	return os.WriteFile(path, raw, 0o644)
}

// replaceOnce substitutes the first occurrence of old with new.
func replaceOnce(s, old, new string) string {
	i := indexOf(s, old)
	if i < 0 {
		return s
	}
	return s[:i] + new + s[i+len(old):]
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
