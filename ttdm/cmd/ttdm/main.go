// ttdm — TikTok 私信触达工具（Android WSS 协议直连）
//
// 用法:
//
//	ttdm account add --cookie <文本或@文件> --device-id <id> [--name <n>] [--proxy <url>]
//	ttdm account list
//	ttdm account delete <id>
//	ttdm task create --senders 1,2 --receivers 123456,789012 --text "hi"
//	ttdm task list
//	ttdm task show <id>
//	ttdm task stop <id>
//	ttdm message export <task-id>
package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/csv"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"ttdm/internal/adspower"
	"ttdm/internal/protocol"
	"ttdm/internal/store"
	"ttdm/internal/task"
)

var dataDir string

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}
	// global --data-dir must precede the subcommand
	args := os.Args[1:]
	if args[0] == "--data-dir" || args[0] == "-d" {
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "--data-dir requires a path")
			os.Exit(1)
		}
		dataDir = args[1]
		args = args[2:]
	} else {
		home, err := os.UserHomeDir()
		if err != nil {
			home = "."
		}
		dataDir = filepath.Join(home, "AppData", "Local", "ttdm")
	}

	db, err := store.Open(filepath.Join(dataDir, "ttdm.db"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "打开数据库失败: %v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	// 恢复上次进程中断留下的排队/运行任务
	if n, err := db.RecoverInterruptedTasks(); err == nil && n > 0 {
		fmt.Printf("已标记 %d 个中断任务为失败\n", n)
	}

	if len(args) < 1 {
		usage()
		os.Exit(1)
	}
	switch args[0] {
	case "account":
		cmdAccount(db, args[1:])
	case "screening":
		cmdScreening(db, args[1:])
	case "template":
		cmdTemplate(db, args[1:])
	case "task":
		cmdTask(db, args[1:])
	case "message":
		cmdMessage(db, args[1:])
	case "adspower":
		cmdAdsPower(db, args[1:])
	case "debug":
		cmdDebug(db, args[1:])
	case "help", "-h", "--help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "未知命令: %s\n", args[0])
		usage()
		os.Exit(1)
	}
}

// ---------- debug ----------

func cmdDebug(db *store.DB, args []string) {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "debug 子命令: connect <account-id> | browser <user-id> --key <api-key> | wscap <user-id> --key <api-key> | jsfind <user-id> --key <api-key>")
		os.Exit(1)
	}
	switch args[0] {
	case "netcap":
		// 抓 HTTP 请求（验证消息发送是否走 HTTP API）
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "用法: ttdm debug netcap <user-id> --key <api-key> [--auto]")
			os.Exit(1)
		}
		userID := args[1]
		fs := flag.NewFlagSet("debug netcap", flag.ExitOnError)
		key := fs.String("key", "", "AdsPower 本地 API Key")
		auto := fs.Bool("auto", false, "自动发送测试消息")
		fs.Parse(args[2:])
		if *key == "" {
			fmt.Fprintln(os.Stderr, "用法: ttdm debug netcap <user-id> --key <api-key> [--auto]")
			os.Exit(1)
		}
		ac := adspower.NewClient(*key)
		ctx := context.Background()
		_, debugPort, err := ac.StartBrowser(ctx, userID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "启动浏览器失败: %v\n", err)
			os.Exit(1)
		}
		pageWS, err := adspower.PageWSURL(ctx, debugPort)
		if err != nil {
			fmt.Fprintf(os.Stderr, "获取页面失败: %v\n", err)
			os.Exit(1)
		}
		cdp, err := adspower.ConnectCDP(ctx, pageWS)
		if err != nil {
			fmt.Fprintf(os.Stderr, "连接 CDP 失败: %v\n", err)
			os.Exit(1)
		}
		defer cdp.Close()
		_, _ = cdp.Call(ctx, "Page.enable", nil)
		_, _ = cdp.Call(ctx, "Network.enable", nil)
		_, _ = cdp.Call(ctx, "Page.navigate", map[string]any{"url": "https://www.tiktok.com/messages"})
		fmt.Println("已打开私信页，等待会话加载 (8s)...")
		time.Sleep(8 * time.Second)
		// 监听必须与 autoSend 并发: autoSend 内部的 CDP Call 会消耗并丢弃
		// socket 上未匹配的事件帧(含 send frame)。用第二个 CDP 会话独立
		// 监听 — CDP 事件对每个客户端广播, 两个连接互不冲突。
		cdp2, err := adspower.ConnectCDP(ctx, pageWS)
		if err != nil {
			fmt.Fprintf(os.Stderr, "连接监听 CDP 失败: %v\n", err)
			os.Exit(1)
		}
		defer cdp2.Close()
		_, _ = cdp2.Call(ctx, "Page.enable", nil)
		_, _ = cdp2.Call(ctx, "Network.enable", nil)

		// 监听 goroutine: HTTP 请求(含签名头) + 响应状态 + WS 收发帧
		listenDone := make(chan struct{})
		go func() {
			defer close(listenDone)
			seen := 0
			interestingReq := map[string]string{} // requestId -> url
			deadline := time.Now().Add(50 * time.Second)
		loop:
			for time.Now().Before(deadline) {
				method, p, err := cdp2.WaitEventAny(50 * time.Second)
				if err != nil {
					break
				}
			switch method {
			case "Network.requestWillBeSent":
				var ev struct {
					RequestID string `json:"requestId"`
					Request   struct {
						Method   string         `json:"method"`
						URL      string         `json:"url"`
						PostData string         `json:"postData"`
						Headers  map[string]any `json:"headers"`
					} `json:"request"`
				}
				if err := json.Unmarshal(p, &ev); err != nil {
					continue
				}
				if ev.Request.Method != "POST" ||
					!(strings.Contains(ev.Request.URL, "message") ||
						strings.Contains(ev.Request.URL, "im/") ||
						strings.Contains(ev.Request.URL, "im-") ||
						strings.Contains(ev.Request.URL, "conversation") ||
						strings.Contains(ev.Request.URL, "chat") ||
						strings.Contains(ev.Request.URL, "send")) {
					continue
				}
				seen++
				fmt.Printf("\n===== 请求 #%d =====\n%s %s\n", seen, ev.Request.Method, ev.Request.URL)
				for _, h := range []string{"x-bogus", "x-tt-token", "ms-token", "x-vc-b-headers", "x-secsdk-cookie", "x-ss-stub", "cookie"} {
					if v, ok := ev.Request.Headers[h]; ok {
						s := fmt.Sprint(v)
						if len(s) > 400 {
							s = s[:400] + "..."
						}
						fmt.Printf("  HDR %s: %s\n", h, s)
					}
				}
				body := ev.Request.PostData
				if len(body) > 3000 {
					body = body[:3000] + "..."
				}
				fmt.Printf("BODY: %s\n", body)
				interestingReq[ev.RequestID] = ev.Request.URL
				if seen >= 15 {
					break loop
				}
			case "Network.responseReceived":
				var ev struct {
					RequestID string `json:"requestId"`
					Response  struct {
						Status   int    `json:"status"`
						MimeType string `json:"mimeType"`
					} `json:"response"`
				}
				if err := json.Unmarshal(p, &ev); err != nil {
					continue
				}
				if url, ok := interestingReq[ev.RequestID]; ok {
					fmt.Printf("RESP %s → HTTP %d (%s)\n", url, ev.Response.Status, ev.Response.MimeType)
				}
			case "Network.webSocketFrameSent":
				var ev struct {
					Response struct {
						PayloadData string `json:"payloadData"`
						Opcode      int    `json:"opcode"`
					} `json:"response"`
				}
				_ = json.Unmarshal(p, &ev)
				if ev.Response.PayloadData != "" {
					s := ev.Response.PayloadData
					if ev.Response.Opcode == 2 { // binary 帧 payloadData 是 base64
						if raw, err := base64.StdEncoding.DecodeString(s); err == nil {
							s = string(raw)
						}
					}
					if len(s) > 800 {
						s = s[:800] + "..."
					}
					fmt.Printf("WS→ %q\n", s)
				}
			case "Network.webSocketFrameReceived":
				var ev struct {
					Response struct {
						PayloadData string `json:"payloadData"`
						Opcode      int    `json:"opcode"`
					} `json:"response"`
				}
				_ = json.Unmarshal(p, &ev)
				if ev.Response.PayloadData != "" {
					s := ev.Response.PayloadData
					if ev.Response.Opcode == 2 {
						if raw, err := base64.StdEncoding.DecodeString(s); err == nil {
							s = string(raw)
						}
					}
					if len(s) > 800 {
						s = s[:800] + "..."
					}
					fmt.Printf("WS← %q\n", s)
				}
			}
			}
			if seen == 0 {
				fmt.Println("未捕获到消息相关请求")
			}
		}()
		// autoSend 与监听并发执行
		if *auto {
			autoSend(ctx, cdp)
			fmt.Println("已触发自动发送，等待监听窗口结束 (50s)...")
		} else {
			fmt.Println(">>> 请在浏览器中打开会话并发送一条消息（50 秒窗口）...")
		}
		<-listenDone
		fmt.Println("监听结束")
	case "dom":
		// 探测私信页 DOM: dump 全部 data-e2e 属性 + 会话项/输入区结构,
		// 用于修正 selectors.go (页面改版后选择器失效)
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "用法: ttdm debug dom <user-id> --key <api-key> [--conv]")
			os.Exit(1)
		}
		userID := args[1]
		fs := flag.NewFlagSet("debug dom", flag.ExitOnError)
		key := fs.String("key", "", "AdsPower 本地 API Key")
		conv := fs.Bool("conv", false, "同时探测会话内结构")
		fs.Parse(args[2:])
		if *key == "" {
			fmt.Fprintln(os.Stderr, "用法: ttdm debug dom <user-id> --key <api-key> [--conv]")
			os.Exit(1)
		}
		ac := adspower.NewClient(*key)
		ctx := context.Background()
		_, debugPort, err := ac.StartBrowser(ctx, userID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "启动浏览器失败: %v\n", err)
			os.Exit(1)
		}
		pageWS, err := adspower.PageWSURL(ctx, debugPort)
		if err != nil {
			fmt.Fprintf(os.Stderr, "获取页面失败: %v\n", err)
			os.Exit(1)
		}
		cdp, err := adspower.ConnectCDP(ctx, pageWS)
		if err != nil {
			fmt.Fprintf(os.Stderr, "连接 CDP 失败: %v\n", err)
			os.Exit(1)
		}
		defer cdp.Close()
		_, _ = cdp.Call(ctx, "Page.navigate", map[string]any{"url": "https://www.tiktok.com/messages"})
		fmt.Println("已打开私信页，等待加载 (10s)...")
		time.Sleep(10 * time.Second)

		// 1. 全部 data-e2e 属性去重
		expr1 := `(() => { const m = new Map(); document.querySelectorAll('[data-e2e]').forEach(el => { const tag = el.tagName.toLowerCase(); const k = tag + '[data-e2e=' + JSON.stringify(el.getAttribute('data-e2e')) + ']'; m.set(k, (m.get(k)||0)+1); }); return [...m.entries()].map(([k,v])=>k+' x'+v).join('\n'); })()`
		res, err := cdp.Eval(ctx, expr1)
		if err == nil {
			fmt.Println("=== data-e2e 属性清单 ===")
			fmt.Println(res)
		}
		// 2. 会话列表项: 找 a[href*=messages] 与含用户名的可点击项
		expr2 := `(() => { const out = []; document.querySelectorAll('a[href*="/messages/"]').forEach(a => { out.push('A href=' + a.getAttribute('href') + ' | text=' + (a.textContent||'').trim().slice(0,60).replace(/\s+/g,' ')); }); if (out.length === 0) { const items = document.querySelectorAll('[role=listitem], [data-e2e]'); let n = 0; for (const el of items) { const e2e = el.getAttribute('data-e2e') || ''; if (e2e.indexOf('conversation') >= 0 || e2e.indexOf('chat') >= 0 || e2e.indexOf('message-item') >= 0) { out.push(el.tagName.toLowerCase() + ' e2e=' + e2e + ' | ' + (el.outerHTML||'').slice(0,300)); if (++n >= 5) break; } } } return out.join('\n'); })()`
		res2, err := cdp.Eval(ctx, expr2)
		if err == nil && res2 != "" {
			fmt.Println("=== 会话项结构 ===")
			fmt.Println(res2)
		}
		if *conv {
			// 3. 点击第一个会话 (新版 dm-new-conversation-item), 探测输入区/发送按钮结构
			expr3 := `(() => { const el = document.querySelector('div[data-e2e="dm-new-conversation-item"]'); if (el) { el.click(); return 'clicked ' + (el.getAttribute('data-conv-id')||''); } return 'no-conv'; })()`
			res3, _ := cdp.Eval(ctx, expr3)
			fmt.Println("点击会话:", res3)
			time.Sleep(5 * time.Second)
			expr4 := `(() => { const out = [];
  // 聊天框区域内全部按钮 + 输入元素
  const box = document.querySelector('div[data-e2e="dm-new-chatbox"]');
  if (box) {
    box.querySelectorAll('button, [role=textbox], textarea, [contenteditable], [data-e2e]').forEach(el => {
      const e2e = el.getAttribute && el.getAttribute('data-e2e');
      out.push(el.tagName.toLowerCase() + (e2e ? '[data-e2e=' + JSON.stringify(e2e) + ']' : '') + ' | cls=' + ((el.className||'').toString().slice(0,60)) + (el.outerHTML ? ' | html=' + el.outerHTML.slice(0,160) : ''));
    });
    // 聊天记录最后一条 (结果判定用)
    const msgs = box.querySelectorAll('div[data-e2e="dm-message-item"], div[data-e2e="chat-item"], [data-e2e*="message"]');
    out.push('-- message items: ' + msgs.length);
  } else { out.push('no chatbox'); }
  return out.slice(0, 50).join('\n'); })()`
			res4, err := cdp.Eval(ctx, expr4)
			if err == nil {
				fmt.Println("=== 输入区/按钮结构 ===")
				fmt.Println(res4)
			}
		}
	case "decode":
		// base64 WS 帧 → protobuf 字段树 (逆向辅助)
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "用法: ttdm debug decode <base64帧> [base64帧...]")
			os.Exit(1)
		}
		for _, b64 := range args[1:] {
			raw, err := base64.StdEncoding.DecodeString(b64)
			if err != nil {
				fmt.Fprintf(os.Stderr, "base64 解码失败: %v\n", err)
				continue
			}
			fmt.Printf("===== %d bytes =====\n%s\n", len(raw), protocol.DumpProto(raw))
		}
	case "wshook":
		// 注入 WebSocket hook，捕获 TikTok 页面自身发送的 IM 帧
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "用法: ttdm debug wshook <user-id> --key <api-key> [--auto] [--target uid]")
			os.Exit(1)
		}
		userID := args[1]
		fs := flag.NewFlagSet("debug wshook", flag.ExitOnError)
		key := fs.String("key", "", "AdsPower 本地 API Key")
		auto := fs.Bool("auto", false, "自动点击会话并发送测试消息")
		target := fs.String("target", "", "目标 uid: 自动打开与其会话并发送 1 条测试消息")
		fs.Parse(args[2:])
		if *key == "" {
			fmt.Fprintln(os.Stderr, "用法: ttdm debug wshook <user-id> --key <api-key> [--auto] [--target uid]")
			os.Exit(1)
		}
		ac := adspower.NewClient(*key)
		ctx := context.Background()
		_, debugPort, err := ac.StartBrowser(ctx, userID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "启动浏览器失败: %v\n", err)
			os.Exit(1)
		}
		pageWS, err := adspower.PageWSURL(ctx, debugPort)
		if err != nil {
			fmt.Fprintf(os.Stderr, "获取页面失败: %v\n", err)
			os.Exit(1)
		}
		cdp, err := adspower.ConnectCDP(ctx, pageWS)
		if err != nil {
			fmt.Fprintf(os.Stderr, "连接 CDP 失败: %v\n", err)
			os.Exit(1)
		}
		defer cdp.Close()

		_, _ = cdp.Call(ctx, "Page.enable", nil)

		// 注入 hook（新文档加载即生效）
		hook := `window.__wsFrames = []; window.__wsErrors = []; window.__wsConns = [];
(function(){
  const OrigWS = window.WebSocket;
  if (window.__wsHooked) return;
  window.__wsHooked = true;
  window.WebSocket = class extends OrigWS {
    constructor(url, protocols) {
      super(url, protocols);
      this.__url = String(url);
      window.__wsConns.push({t: Date.now(), url: String(url)});
      if (window.__wsConns.length > 50) window.__wsConns.shift();
    }
    send(data) {
      try {
        if (this.__url && this.__url.indexOf('im-ws') >= 0) {
          let bytes = null;
          if (data instanceof ArrayBuffer) bytes = new Uint8Array(data);
          else if (ArrayBuffer.isView(data)) bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
          else if (typeof data === 'string') bytes = new TextEncoder().encode(data);
          if (bytes) {
            let bin = '';
            for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
            window.__wsFrames.push({t: Date.now(), dir: 'send', len: bytes.length, d: btoa(bin)});
            if (window.__wsFrames.length > 300) window.__wsFrames.shift();
          }
        }
      } catch(e) { window.__wsErrors.push(String(e)); }
      return super.send(data);
    }
  };
  // hook onmessage: 捕获接收帧（响应/推送）
  const origDesc = Object.getOwnPropertyDescriptor(OrigWS.prototype, 'onmessage');
  if (origDesc && origDesc.configurable) {
    Object.defineProperty(OrigWS.prototype, 'onmessage', {
      configurable: true,
      enumerable: true,
      get() { return this.__handler; },
      set(fn) {
        this.__handler = fn;
        const ws = this;
        const wrapper = function(ev) {
          try {
            if (ws.__url && ws.__url.indexOf('im-ws') >= 0 && ev.data instanceof ArrayBuffer) {
              const bytes = new Uint8Array(ev.data);
              let bin = '';
              for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
              window.__wsFrames.push({t: Date.now(), dir: 'recv', len: bytes.length, d: btoa(bin)});
              if (window.__wsFrames.length > 300) window.__wsFrames.shift();
            }
          } catch(e) {}
          return fn.call(this, ev);
        };
        this.__wrapped = wrapper;
        super.onmessage = wrapper;
      }
    });
  }
})();`
		if _, err := cdp.Call(ctx, "Page.addScriptToEvaluateOnNewDocument", map[string]any{"source": hook}); err != nil {
			fmt.Fprintf(os.Stderr, "注入 hook 失败: %v\n", err)
			os.Exit(1)
		}

		// 刷新私信页让 hook 生效
		if _, err := cdp.Call(ctx, "Page.navigate", map[string]any{"url": "https://www.tiktok.com/messages"}); err != nil {
			fmt.Fprintf(os.Stderr, "导航失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("已注入 hook 并打开私信页。")
		if *target != "" {
			fmt.Printf(">>> 目标模式: 导航到 uid=%s 会话并自动发送测试消息...\n", *target)
			page := adspower.NewPage(cdp)
			navURL := protocol.BrowserMessagesURL + *target
			// 用 location.href 导航: 同一连接上二次 Page.navigate 可能挂起 (CDP 响应超时),
			// Eval 不阻塞响应通道, 之后轮询等待新文档的输入框出现
			if _, err := cdp.Eval(ctx, "location.href = "+strconv.Quote(navURL)); err != nil {
				fmt.Fprintf(os.Stderr, "导航到会话失败: %v\n", err)
				os.Exit(1)
			}
			sel, err := page.WaitSelector(ctx, 45*time.Second, 500*time.Millisecond, protocol.SelMessageInput...)
			if err != nil {
				fmt.Fprintf(os.Stderr, "等待输入框超时: %v (可能未登录或页面异常)\n", err)
				os.Exit(1)
			}
			fmt.Println("输入框: READY (" + sel + ")")
			if uid, _ := page.SelectorText(ctx, protocol.SelChatUniqueID...); uid != "" {
				fmt.Println("会话校验: chat-uniqueid=" + uid)
			} else {
				fmt.Println("会话校验: 未找到 chat-uniqueid, 继续尝试发送")
			}
			// 关闭遮挡弹窗 (通知/设置 dialog 会拦截输入与点击)
			dlg := `(() => {
				const d = document.querySelector('[role="dialog"]');
				if (!d) return 'no-dialog';
				const close = d.querySelector('[aria-label*="Close" i], [aria-label*="close"], [data-testid*="close" i], [data-e2e*="close" i]');
				if (close) { close.click(); return 'clicked-close'; }
				return 'dialog-open';
			})()`
			if res, err := cdp.Eval(ctx, dlg); err != nil {
				fmt.Fprintln(os.Stderr, "弹窗检测失败:", err)
			} else if res == "dialog-open" {
				// ESC 兑底
				if err := pressEscape(ctx, cdp); err == nil {
					fmt.Println("弹窗: ESC 关闭")
				}
			} else if res == "clicked-close" {
				fmt.Println("弹窗: 已点关闭")
			}
			time.Sleep(600 * time.Millisecond)
			if err := page.Type(ctx, "test", 80*time.Millisecond, protocol.SelMessageInput...); err != nil {
				fmt.Fprintf(os.Stderr, "输入失败: %v\n", err)
				os.Exit(1)
			}
			time.Sleep(300 * time.Millisecond)
			// 新版发送按钮是聊天容器内的 svg[aria-label=Send] (输入文字后出现):
			// 全局 querySelector 会点错页面其他 Send 图标, 且 SVGElement 无
			// click() 方法 — 容器内找 + 真实鼠标事件坐标点击。失败不退出,
			// 帧仍会取回 (发送帧可能已出站)。
			sent := false
			exprSend := `(() => {
				const box = document.querySelector('div[data-e2e="dm-new-chat-bottom"]') || document.querySelector('div[data-e2e="dm-new-chatbox"]');
				if (!box) return 'no-box';
				const el = box.querySelector('svg[aria-label="Send"], [aria-label="Send"], [data-e2e=message-send], [data-e2e=dm-new-send-btn]');
				if (!el) return 'no-send';
				const r = el.getBoundingClientRect();
				if (r.width <= 0 || r.height <= 0) return 'hidden';
				return Math.round(r.x + r.width/2) + '|' + Math.round(r.y + r.height/2);
			})()`
			if res, err := cdp.Eval(ctx, exprSend); err != nil {
				fmt.Fprintln(os.Stderr, "发送按钮探测失败:", err)
			} else if res == "no-box" || res == "no-send" || res == "hidden" {
				fmt.Println("发送按钮:", res, "(输入未生效或会话不可发送)")
			} else if parts := strings.SplitN(res, "|", 2); len(parts) == 2 {
				if sx, e1 := strconv.Atoi(parts[0]); e1 == nil {
					if sy, e2 := strconv.Atoi(parts[1]); e2 == nil {
						if err := mouseClick(ctx, cdp, float64(sx), float64(sy)); err != nil {
							fmt.Fprintln(os.Stderr, "发送点击失败:", err)
						} else {
							fmt.Println("已点击发送 (坐标)")
							sent = true
						}
					}
				}
			}
			if !sent {
				// Enter 兜底 (重新聚焦输入框后)
				if _, err := page.Click(ctx, protocol.SelMessageInput...); err == nil {
					time.Sleep(200 * time.Millisecond)
				}
				if err := pressEnter(ctx, cdp); err != nil {
					fmt.Fprintln(os.Stderr, "发送: Enter 键失败:", err)
				} else {
					fmt.Println("已发送 (Enter)")
				}
			}
			fmt.Println("等待帧捕获 (4s)...")
			time.Sleep(4 * time.Second)
		} else if *auto {
			fmt.Println(">>> 自动模式：点击第一个会话并发送测试消息...")
			autoSend(ctx, cdp)
			fmt.Println(">>> 自动发送完成，等待帧捕获 (3s)...")
			time.Sleep(3 * time.Second)
		} else {
			fmt.Println(">>> 请在浏览器中打开任意会话并【发送一条消息】（60 秒窗口，随时可发）...")
			time.Sleep(60 * time.Second)
		}

		expr := `JSON.stringify({hooked: !!window.__wsHooked, frames: window.__wsFrames || [], conns: window.__wsConns || [], errors: window.__wsErrors || []})`
		res, err := cdp.Eval(ctx, expr)
		if err != nil {
			fmt.Fprintf(os.Stderr, "取回帧失败: %v\n", err)
			os.Exit(1)
		}
		var out struct {
			Hooked bool `json:"hooked"`
			Frames []struct {
				T   int    `json:"t"`
				Len int    `json:"len"`
				D   string `json:"d"`
			} `json:"frames"`
			Conns []struct {
				T   int    `json:"t"`
				URL  string `json:"url"`
			} `json:"conns"`
			Errors []string `json:"errors"`
		}
		_ = json.Unmarshal([]byte(res), &out)
		fmt.Printf("hook 生效: %v | 连接数: %d | 帧数: %d\n", out.Hooked, len(out.Conns), len(out.Frames))
		for _, c := range out.Conns {
			fmt.Printf("  连接: %s\n", c.URL)
		}
		if len(out.Errors) > 0 {
			fmt.Println("hook 错误:", out.Errors)
		}
		for i, f := range out.Frames {
			fmt.Printf("\n--- 帧 #%d (len=%d) ---\n%s\n", i+1, f.Len, f.D)
			if raw, err := base64.StdEncoding.DecodeString(f.D); err == nil {
				fmt.Println("--- 字段树 ---")
				fmt.Println(protocol.DumpProto(raw))
			}
		}
		if len(out.Frames) == 0 {
			fmt.Println("未捕获到帧（浏览器可能没有发送消息，或连接未建立）")
		}
	case "jsfind":
		// 在 TikTok 页面 JS bundle 中搜索 access_key 算法相关字符串
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "用法: ttdm debug jsfind <user-id> --key <api-key>")
			os.Exit(1)
		}
		userID := args[1]
		fs := flag.NewFlagSet("debug jsfind", flag.ExitOnError)
		key := fs.String("key", "", "AdsPower 本地 API Key")
		fs.Parse(args[2:])
		if *key == "" {
			fmt.Fprintln(os.Stderr, "用法: ttdm debug jsfind <user-id> --key <api-key>")
			os.Exit(1)
		}
		ac := adspower.NewClient(*key)
		ctx := context.Background()
		_, debugPort, err := ac.StartBrowser(ctx, userID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "启动浏览器失败: %v\n", err)
			os.Exit(1)
		}
		pageWS, err := adspower.PageWSURL(ctx, debugPort)
		if err != nil {
			fmt.Fprintf(os.Stderr, "获取页面失败: %v\n", err)
			os.Exit(1)
		}
		cdp, err := adspower.ConnectCDP(ctx, pageWS)
		if err != nil {
			fmt.Fprintf(os.Stderr, "连接 CDP 失败: %v\n", err)
			os.Exit(1)
		}
		defer cdp.Close()
		_, _ = cdp.Call(ctx, "Page.navigate", map[string]any{"url": "https://www.tiktok.com/messages"})
		fmt.Println("已打开私信页，等待 IM 脚本加载 (12s)...")
		time.Sleep(12 * time.Second)
		// 诊断页面状态
		diag, _ := cdp.Eval(ctx, `JSON.stringify({href: location.href, title: document.title, ready: document.readyState, perf: performance.getEntriesByType('resource').length, scripts: document.querySelectorAll('script[src]').length})`)
		fmt.Println("页面状态:", diag)
		expr := `(async () => {
			const needles = ['e1bd35ec9db7b8d846de66ed140b1ad9', 'f8a69f1719916z', 'access_key', 'accessKey', 'im-ws', '33554513', 'fpid', 'pbbp'];
			const out = [];
			const seen = new Set();
			const urls = [];
			performance.getEntriesByType('resource').forEach(e => { if (/\.js/.test(e.name) && !seen.has(e.name)) { seen.add(e.name); urls.push(e.name); } });
			document.querySelectorAll('script[src]').forEach(s => { if (!seen.has(s.src)) { seen.add(s.src); urls.push(s.src); } });
			for (const u of urls.slice(0, 150)) {
				try {
					const r = await fetch(u);
					if (!r.ok) continue;
					const t = await r.text();
					for (const n of needles) {
						let idx = t.indexOf(n);
						let cnt = 0;
						while (idx >= 0 && cnt < 2) {
							out.push({f: u.slice(-60), n, ctx: t.slice(Math.max(0, idx-200), idx+300)});
							idx = t.indexOf(n, idx + 1); cnt++;
						}
					}
				} catch (e2) {}
			}
			return JSON.stringify({total: urls.length, hits: out});
		})()`
		res, err := cdp.Eval(ctx, expr)
		if err != nil {
			fmt.Fprintf(os.Stderr, "执行 JS 失败: %v\n", err)
			os.Exit(1)
		}
		var result struct {
			Total int `json:"total"`
			Hits  []struct {
				F   string `json:"f"`
				N   string `json:"n"`
				Ctx string `json:"ctx"`
			} `json:"hits"`
		}
		_ = json.Unmarshal([]byte(res), &result)
		fmt.Printf("扫描了 %d 个 JS 文件, 找到 %d 处命中:\n", result.Total, len(result.Hits))
		for i, h := range result.Hits {
			fmt.Printf("\n===== 命中 #%d [%s] in %s =====\n%s\n", i+1, h.N, h.F, truncateStr(h.Ctx, 600))
		}
		if len(result.Hits) == 0 {
			fmt.Println("未找到相关字符串")
		}
	case "wscap":
		// 打开 TikTok 私信页并抓取浏览器真实的 WebSocket 握手参数
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "用法: ttdm debug wscap <user-id> --key <api-key>")
			os.Exit(1)
		}
		userID := args[1]
		fs := flag.NewFlagSet("debug wscap", flag.ExitOnError)
		key := fs.String("key", "", "AdsPower 本地 API Key")
		fs.Parse(args[2:])
		if *key == "" {
			fmt.Fprintln(os.Stderr, "用法: ttdm debug wscap <user-id> --key <api-key>")
			os.Exit(1)
		}
		ac := adspower.NewClient(*key)
		ctx := context.Background()
		_, debugPort, err := ac.StartBrowser(ctx, userID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "启动浏览器失败: %v\n", err)
			os.Exit(1)
		}
		pageWS, err := adspower.PageWSURL(ctx, debugPort)
		if err != nil {
			fmt.Fprintf(os.Stderr, "获取页面失败: %v\n", err)
			os.Exit(1)
		}
		cdp, err := adspower.ConnectCDP(ctx, pageWS)
		if err != nil {
			fmt.Fprintf(os.Stderr, "连接 CDP 失败: %v\n", err)
			os.Exit(1)
		}
		defer cdp.Close()
		_, _ = cdp.Call(ctx, "Network.enable", nil)
		_, _ = cdp.Call(ctx, "Page.enable", nil)
		_, _ = cdp.Call(ctx, "Page.navigate", map[string]any{"url": "https://www.tiktok.com/messages"})
		fmt.Println("已打开 https://www.tiktok.com/messages")
		fmt.Println("等待 WebSocket 创建事件（拿真实 URL/query 参数）...")

		// 1) 抓 webSocketCreated 事件拿 URL
		params, err := cdp.WaitEvent("Network.webSocketCreated", 45*time.Second)
		if err != nil {
			fmt.Fprintf(os.Stderr, "未捕获到 WebSocket: %v\n", err)
			os.Exit(1)
		}
		var created struct {
			URL     string            `json:"url"`
			Headers map[string]string `json:"requestHeaders"`
		}
		_ = json.Unmarshal(params, &created)
		fmt.Printf("\n===== WebSocket URL =====\n%s\n", created.URL)

		// 2) 抓握手响应头（含服务端返回的子协议）
		params2, err := cdp.WaitEvent("Network.webSocketHandshakeResponseReceived", 15*time.Second)
		if err == nil {
			var resp struct {
				Response struct {
					Headers    map[string]string `json:"headers"`
					StatusCode int               `json:"status"`
				} `json:"response"`
			}
			_ = json.Unmarshal(params2, &resp)
			fmt.Printf("\n===== 握手响应 HTTP %d =====\n", resp.Response.StatusCode)
			if v, ok := resp.Response.Headers["Sec-WebSocket-Protocol"]; ok {
				fmt.Printf("Sec-WebSocket-Protocol: %s\n", v)
			}
		}

		// 3) 抓数据帧（前 12 帧，含 payload 前 200 字节 base64）
		fmt.Println("\n===== 监听数据帧 30s（请在浏览器里打开一个私信会话或发送一条消息）=====")
		seen := 0
		deadline := time.Now().Add(30 * time.Second)
		for time.Now().Before(deadline) {
			frameParams, ferr := cdp.WaitEvent("Network.webSocketFrameSent", 30*time.Second)
			if ferr != nil {
				break
			}
			var fr struct {
				Response struct {
					Opcode  int    `json:"opcode"`
					Payload string `json:"payloadData"`
				} `json:"response"`
			}
			if err := json.Unmarshal(frameParams, &fr); err != nil {
				continue
			}
			seen++
			p := fr.Response.Payload
			if len(p) > 260 {
				p = p[:260] + "..."
			}
			fmt.Printf("\n--- 发送帧 #%d (opcode=%d, %d bytes) ---\n%s\n",
				seen, fr.Response.Opcode, len(fr.Response.Payload), p)
		}
		if seen == 0 {
			fmt.Println("未捕获到发送帧")
		}
	case "browser":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "用法: ttdm debug browser <user-id> --key <api-key>")
			os.Exit(1)
		}
		userID := args[1]
		fs := flag.NewFlagSet("debug browser", flag.ExitOnError)
		key := fs.String("key", "", "AdsPower 本地 API Key")
		fs.Parse(args[2:])
		if *key == "" {
			fmt.Fprintln(os.Stderr, "用法: ttdm debug browser <user-id> --key <api-key>")
			os.Exit(1)
		}
		ac := adspower.NewClient(*key)
		ctx := context.Background()
		_, debugPort, err := ac.StartBrowser(ctx, userID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "启动浏览器失败: %v\n", err)
			os.Exit(1)
		}
		pageWS, err := adspower.PageWSURL(ctx, debugPort)
		if err != nil {
			fmt.Fprintf(os.Stderr, "获取页面失败: %v\n", err)
			os.Exit(1)
		}
		cdp, err := adspower.ConnectCDP(ctx, pageWS)
		if err != nil {
			fmt.Fprintf(os.Stderr, "连接 CDP 失败: %v\n", err)
			os.Exit(1)
		}
		defer cdp.Close()
		_, _ = cdp.Call(ctx, "Page.navigate", map[string]any{"url": "https://www.tiktok.com"})
		time.Sleep(4 * time.Second)

		cookies, _ := cdp.GetAllCookies(ctx)
		fmt.Println("=== tiktok cookies ===")
		for _, c := range cookies {
			if strings.Contains(c.Domain, "tiktok.com") {
				v := c.Value
				if len(v) > 40 {
					v = v[:40] + "..."
				}
				fmt.Printf("  %-24s %s\n", c.Name, v)
			}
		}
		fmt.Println("=== localStorage (含19位数字的key) ===")
		expr := `(() => { const out=[]; for(let i=0;i<localStorage.length;i++){ const k=localStorage.key(i); const v=localStorage.getItem(k); if(/^\d{15,20}$/.test((v||'').trim())) out.push(k+'='+v.trim()); } return out.join('\n'); })()`
		res, err := cdp.Eval(ctx, expr)
		if err == nil {
			fmt.Println(res)
		}
		fmt.Println("=== ttwid 解码 ===")
		expr2 := `(() => { const v=localStorage.getItem('ttwid') || document.cookie.match(/ttwid=([^;]+)/)?.[1] || ''; try{ return decodeURIComponent(v); }catch(e){ return v; } })()`
		res2, err := cdp.Eval(ctx, expr2)
		if err == nil && res2 != "" {
			fmt.Println(res2)
		}
	case "wsweb":
		// 新版 Web 协议握手测试 (fws_1.0.0) —— 复现浏览器真实连接参数
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "用法: ttdm debug wsweb <account-id>")
			os.Exit(1)
		}
		id, err := strconv.ParseInt(args[1], 10, 64)
		if err != nil {
			fmt.Fprintf(os.Stderr, "无效账号 id: %v\n", err)
			os.Exit(1)
		}
		a, err := db.GetAccount(id)
		if err != nil || a == nil {
			fmt.Fprintf(os.Stderr, "账号 %d 不存在\n", id)
			os.Exit(1)
		}
		wc, err := protocol.NewWebClient(a)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		proxyURL := a.ProxyURL
		if proxyURL == "" {
			proxyURL = protocol.SystemProxy()
		}
		fmt.Printf("账号: uid=%d ttwid_device_id=%s\n", a.UID, maskDeviceID(store.TTWidDeviceID(a.Cookies)))
		fmt.Printf("access_key: %s\n", protocol.AccessKey(store.TTWidDeviceID(a.Cookies)))
		ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
		defer cancel()
		if err := wc.Connect(ctx, proxyURL); err != nil {
			fmt.Printf("连接失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("WSS 连接成功 ✓ (pbbp2 握手通过, 初始化帧已发送)")
		if err := wc.SendTyping(); err != nil {
			fmt.Printf("typing 帧发送失败: %v\n", err)
		}
		// 等待一段时间观察连接是否被服务端保持
		time.Sleep(5 * time.Second)
		wc.Close()
		fmt.Println("连接保持 5s 后正常关闭 ✓")
	case "connect":
		id, err := strconv.ParseInt(args[1], 10, 64)
		if err != nil {
			fmt.Fprintf(os.Stderr, "无效账号 id: %v\n", err)
			os.Exit(1)
		}
		a, err := db.GetAccount(id)
		if err != nil || a == nil {
			fmt.Fprintf(os.Stderr, "账号 %d 不存在\n", id)
			os.Exit(1)
		}
		fmt.Printf("账号: uid=%d store_idc=%s device_id=%s cookies=%d 完整参数=%v\n",
			a.UID, a.StoreIDC, maskDeviceID(a.DeviceID), len(a.Cookies), a.HasFullIMParams())
		fmt.Printf("WSS 目标: wss://%s/ws/v2\n", protocol.WSSDomain(a.StoreIDC))
		fmt.Printf("access_key: %s\n", protocol.AccessKey(a.DeviceID))

		client := protocol.NewAndroidClient(a)
		ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
		defer cancel()
		if err := client.Connect(ctx, a.ProxyURL); err != nil {
			fmt.Printf("连接失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("WSS 连接成功 ✓ (握手通过，Cookie/access_key 有效)")
		client.Close()
	default:
		fmt.Fprintln(os.Stderr, "debug 子命令: connect <account-id> | wsweb <account-id>")
		os.Exit(1)
	}
}

func usage() {
	fmt.Print(`ttdm — TikTok 私信触达工具

用法:
  ttdm [--data-dir <路径>] <命令> [参数]

命令:
  account add    --cookie <文本|@文件> --device-id <id> [--name <n>] [--nick <n>] [--proxy <socks5://...>]
  account import --file <路径> [--device-id <id>] [--proxy <url>]   # 支持 4 种 CK 格式批量导入
  account list
  account delete <id>
  screening run    --account <id> --targets <uid,uid|@文件> [--threads 10] [--proxy <url,...>] [--label <名>]
  screening list   [--label <名>]
  screening export [--label <名>]
  template add     --text "话术" [--tag <标签>]
  template list
  template delete  <id>
  task create    --senders <id,id> --receivers <uid,uid|@文件> --text "话术"
                 [--link-url <url> --link-title <t> --link-desc <d> --link-cover <url>]
                 [--video <url>] [--image <url>] [--homepage <uid>]
                 [--interval <秒>] [--max-sent <n>] [--max-fail <n>] [--concurrency <n>]
                 [--proxy <url>...] [--wait]
  task list
  task show      <id>
  task stop      <id>
  message export <task-id>
`)
}

func openDB() (*store.DB, error) {
	return store.Open(filepath.Join(dataDir, "ttdm.db"))
}

// ---------- account ----------

func cmdAccount(db *store.DB, args []string) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "account 子命令: add | import | list | delete")
		os.Exit(1)
	}
	switch args[0] {
	case "import":
		cmdAccountImport(db, args[1:])
	case "add":
		fs := flag.NewFlagSet("account add", flag.ExitOnError)
		cookie := fs.String("cookie", "", "Cookie 文本或 @文件路径")
		deviceID := fs.String("device-id", "", "TikTok 设备 ID (必须)")
		name := fs.String("name", "", "备注名")
		nick := fs.String("nick", "", "昵称")
		proxy := fs.String("proxy", "", "代理 URL (http/https/socks5)")
		fs.Parse(args[1:])
		if *cookie == "" || *deviceID == "" {
			fmt.Fprintln(os.Stderr, "需要 --cookie 和 --device-id")
			os.Exit(1)
		}
		text := *cookie
		if strings.HasPrefix(*cookie, "@") {
			b, err := os.ReadFile(strings.TrimPrefix(*cookie, "@"))
			if err != nil {
				fmt.Fprintf(os.Stderr, "读取 Cookie 文件失败: %v\n", err)
				os.Exit(1)
			}
			text = string(b)
		}
		a, err := store.NewAccountFromCookieText(text, *deviceID, *name, *nick, *proxy)
		if err != nil {
			fmt.Fprintf(os.Stderr, "导入账号失败: %v\n", err)
			os.Exit(1)
		}
		id, err := db.CreateAccount(a)
		if err != nil {
			fmt.Fprintf(os.Stderr, "保存账号失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("账号已添加: id=%d uid=%d store_idc=%s\n", id, a.UID, a.StoreIDC)
	case "list":
		accounts, err := db.ListAccounts()
		if err != nil {
			fmt.Fprintf(os.Stderr, "查询失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("%-5s %-18s %-12s %-10s %-20s %s\n", "ID", "UID", "用户名", "状态", "StoreIDC", "IM参数")
		for _, a := range accounts {
			ok := "完整"
			if !a.HasFullIMParams() {
				ok = "缺失"
			}
			fmt.Printf("%-5d %-18d %-12s %-10d %-20s %s\n", a.ID, a.UID, a.Username, a.Status, a.StoreIDC, ok)
		}
	case "delete":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "用法: ttdm account delete <id>")
			os.Exit(1)
		}
		id, err := strconv.ParseInt(args[1], 10, 64)
		if err != nil {
			fmt.Fprintf(os.Stderr, "无效 id: %v\n", err)
			os.Exit(1)
		}
		if err := db.DeleteAccount(id); err != nil {
			fmt.Fprintf(os.Stderr, "删除失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("账号 %d 已删除\n", id)
	default:
		fmt.Fprintln(os.Stderr, "account 子命令: add | import | list | delete")
		os.Exit(1)
	}
}

// ---------- task ----------

func cmdTask(db *store.DB, args []string) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "task 子命令: create | list | show | stop")
		os.Exit(1)
	}
	switch args[0] {
	case "create":
		cmdTaskCreate(db, args[1:])
	case "list":
		tasks, err := db.ListTasks(50)
		if err != nil {
			fmt.Fprintf(os.Stderr, "查询失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("%-6s %-9s %-7s %-7s %-7s %-20s %s\n", "ID", "状态", "总数", "成功", "失败", "创建时间", "错误")
		for _, t := range tasks {
			fmt.Printf("%-6d %-9d %-7d %-7d %-7d %-20s %s\n",
				t.ID, t.Status, t.TotalCount, t.SuccessCount, t.FailCount,
				time.UnixMilli(t.CreatedAt).Format("2006-01-02 15:04:05"), t.Error)
		}
	case "show":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "用法: ttdm task show <id>")
			os.Exit(1)
		}
		id, _ := strconv.ParseInt(args[1], 10, 64)
		t, err := db.GetTask(id)
		if err != nil || t == nil {
			fmt.Fprintf(os.Stderr, "任务 %d 不存在\n", id)
			os.Exit(1)
		}
		statusNames := map[int]string{0: "排队", 1: "运行", 2: "完成", 3: "取消", 4: "失败"}
		fmt.Printf("任务 %d: 状态=%s 总数=%d 成功=%d 失败=%d\n",
			t.ID, statusNames[t.Status], t.TotalCount, t.SuccessCount, t.FailCount)
		if t.Error != "" {
			fmt.Printf("错误: %s\n", t.Error)
		}
		p, _ := store.ParseParams(t.ParamsJSON)
		fmt.Printf("发送账号: %v\n", p.Senders)
		fmt.Printf("接收目标: %d 个\n", len(p.Receivers))
		if p.Channel != "" {
			fmt.Printf("通道: %s\n", p.Channel)
		}
		if p.Message != "" {
			fmt.Printf("话术: %s\n", p.Message)
		}
		if len(p.Templates) > 0 {
			fmt.Printf("话术模板: %v\n", p.Templates)
		}
		// 发送遥测: 失败原因分布
		if t.FailCount > 0 {
			if breakdown, err := db.FailureBreakdown(t.ID); err == nil && len(breakdown) > 0 {
				fmt.Println("失败原因分布:")
				for _, f := range breakdown {
					fmt.Printf("  [%d] %s\n", f.Count, f.Reason)
				}
			}
		}
		msgs, err := db.ListMessagesByTask(t.ID)
		if err == nil {
			fmt.Printf("消息记录: %d 条\n", len(msgs))
			for _, m := range msgs {
				fmt.Printf("  [%d] 发送者=%d -> 接收者=%d 文本=%s %s\n",
					m.ID, m.SenderUID, m.ReceiverUID,
					statusOf(m.TextStatus), strPtrOr(m.TextError, ""))
			}
		}
	case "stop":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "用法: ttdm task stop <id>")
			os.Exit(1)
		}
		id, _ := strconv.ParseInt(args[1], 10, 64)
		mgr := task.NewManager(db)
		if err := mgr.Stop(id); err != nil {
			fmt.Fprintf(os.Stderr, "停止失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("任务 %d 已停止\n", id)
	default:
		fmt.Fprintln(os.Stderr, "task 子命令: create | list | show | stop")
		os.Exit(1)
	}
}

func cmdTaskCreate(db *store.DB, args []string) {
	fs := flag.NewFlagSet("task create", flag.ExitOnError)
	senders := fs.String("senders", "", "发送账号 id，逗号分隔")
	receivers := fs.String("receivers", "", "接收者 uid，逗号分隔或 @文件")
	text := fs.String("text", "", "话术文本")
	linkURL := fs.String("link-url", "", "链接卡 URL")
	linkTitle := fs.String("link-title", "", "链接卡标题")
	linkDesc := fs.String("link-desc", "", "链接卡描述")
	linkCover := fs.String("link-cover", "", "链接卡封面")
	video := fs.String("video", "", "视频卡 URL")
	image := fs.String("image", "", "图片 URL")
	homepage := fs.String("homepage", "", "主页卡 UID")
	interval := fs.Int("interval", 3, "发送间隔(秒)")
	maxSent := fs.Int("max-sent", 30, "每账号最大发送数")
	maxFail := fs.Int("max-fail", 5, "连续失败退出阈值")
	concurrency := fs.Int("concurrency", 4, "并行发送账号数")
	proxies := fs.String("proxy", "", "代理 URL 列表，逗号分隔")
	templates := fs.String("templates", "", "话术库 ID 列表，逗号分隔 (随机选一条)")
	randomEmoji := fs.Bool("random-emoji", false, "话术追加 3 个随机表情")
	dateTime := fs.Bool("datetime", false, "话术追加当前时间")
	linkPool := fs.String("links", "", "链接多 URL 随机池，逗号分隔")
	channel := fs.String("channel", "auto", "通道: web|browser|auto|android")
	adsKey := fs.String("ads-key", "", "AdsPower 本地 API Key (browser/auto 通道需要)")
	async := fs.Bool("async", false, "异步提交（进程退出后任务停止）")
	fs.Parse(args)

	if *senders == "" || *receivers == "" {
		fmt.Fprintln(os.Stderr, "需要 --senders 和 --receivers")
		os.Exit(1)
	}
	var senderIDs []int64
	for _, s := range strings.Split(*senders, ",") {
		id, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
		if err != nil {
			fmt.Fprintf(os.Stderr, "无效发送账号 id: %s\n", s)
			os.Exit(1)
		}
		senderIDs = append(senderIDs, id)
	}
	recvText := *receivers
	if strings.HasPrefix(*receivers, "@") {
		b, err := os.ReadFile(strings.TrimPrefix(*receivers, "@"))
		if err != nil {
			fmt.Fprintf(os.Stderr, "读取接收者文件失败: %v\n", err)
			os.Exit(1)
		}
		recvText = string(b)
	}
	var receiverUIDs []int64
	sc := bufio.NewScanner(strings.NewReader(recvText))
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		for _, part := range strings.Split(line, ",") {
			uid, err := strconv.ParseInt(strings.TrimSpace(part), 10, 64)
			if err != nil {
				fmt.Fprintf(os.Stderr, "无效接收者 uid: %s\n", part)
				os.Exit(1)
			}
			receiverUIDs = append(receiverUIDs, uid)
		}
	}
	if len(receiverUIDs) == 0 {
		fmt.Fprintln(os.Stderr, "接收者列表为空")
		os.Exit(1)
	}

	p := store.DefaultParams()
	p.Senders = senderIDs
	p.Receivers = receiverUIDs
	p.Message = *text
	p.LinkURL, p.LinkTitle, p.LinkDesc, p.LinkCoverURL = *linkURL, *linkTitle, *linkDesc, *linkCover
	p.VideoURL, p.PictureURL, p.HomePageUID = *video, *image, *homepage
	p.IntervalSecs, p.MaxSentCount, p.MaxFailCount, p.MaxConcurrency = *interval, *maxSent, *maxFail, *concurrency
	if *proxies != "" {
		for _, pr := range strings.Split(*proxies, ",") {
			if pr = strings.TrimSpace(pr); pr != "" {
				p.Proxies = append(p.Proxies, pr)
			}
		}
	}
	if *templates != "" {
		for _, s := range strings.Split(*templates, ",") {
			id, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
			if err != nil {
				fmt.Fprintf(os.Stderr, "无效话术 id: %s\n", s)
				os.Exit(1)
			}
			p.Templates = append(p.Templates, id)
		}
	}
	if *linkPool != "" {
		for _, s := range strings.Split(*linkPool, ",") {
			if s = strings.TrimSpace(s); s != "" {
				p.LinkURLs = append(p.LinkURLs, s)
			}
		}
	}
	p.RandomEmoji = *randomEmoji
	p.CurrentDateTime = *dateTime
	p.Channel = *channel

	mgr := task.NewManager(db)
	mgr.SetAdsAPIKey(*adsKey)
	if !*async {
		mgr.SetOnProgress(func(pr task.Progress) {
			fmt.Printf("\r进度: 已发 %d 成功 / %d 失败 (最新: %s)   ",
				pr.Sent, pr.Fail, statusText(pr.Success, pr.Error))
		})
	}
	t, err := mgr.Submit(p)
	if err != nil {
		fmt.Fprintf(os.Stderr, "创建任务失败: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("任务已创建: id=%d 发送账号=%d 接收目标=%d\n", t.ID, len(p.Senders), len(p.Receivers))
	if *async {
		fmt.Println("警告: 异步模式下进程退出后任务将停止")
		return
	}
	// 默认前台执行：等待任务完成（goroutine 随进程存活）
	for {
		time.Sleep(500 * time.Millisecond)
		cur, err := db.GetTask(t.ID)
		if err != nil || cur == nil {
			continue
		}
		if cur.Status >= store.TaskCompleted {
			statusNames := map[int]string{0: "排队", 1: "运行", 2: "完成", 3: "取消", 4: "失败"}
			fmt.Printf("\n任务结束: %s 成功=%d 失败=%d\n", statusNames[cur.Status], cur.SuccessCount, cur.FailCount)
			if cur.Error != "" {
				fmt.Printf("错误: %s\n", cur.Error)
			}
			os.Exit(0)
		}
	}
}

// ---------- adspower ----------

func cmdAdsPower(db *store.DB, args []string) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "adspower 子命令: sync | list")
		os.Exit(1)
	}
	switch args[0] {
	case "list":
		fs := flag.NewFlagSet("adspower list", flag.ExitOnError)
		key := fs.String("key", "", "AdsPower 本地 API Key")
		fs.Parse(args[1:])
		if *key == "" {
			fmt.Fprintln(os.Stderr, "需要 --key")
			os.Exit(1)
		}
		ac := adspower.NewClient(*key)
		browsers, err := ac.ListBrowsers(context.Background())
		if err != nil {
			fmt.Fprintf(os.Stderr, "获取浏览器列表失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("%-12s %-20s %s\n", "user_id", "name", "remark")
		for _, b := range browsers {
			fmt.Printf("%-12s %-20s %s\n", b.UserID, b.Name, b.Remark)
		}
	case "sync":
		fs := flag.NewFlagSet("adspower sync", flag.ExitOnError)
		key := fs.String("key", "", "AdsPower 本地 API Key")
		userID := fs.String("user-id", "", "浏览器配置 ID (如 k1fan6kh)")
		name := fs.String("name", "", "账号备注名")
		proxy := fs.String("proxy", "", "账号代理 URL (与浏览器环境代理一致)")
		fs.Parse(args[1:])
		if *key == "" || *userID == "" {
			fmt.Fprintln(os.Stderr, "需要 --key 和 --user-id")
			os.Exit(1)
		}
		ac := adspower.NewClient(*key)
		ctx := context.Background()

		_, debugPort, err := ac.StartBrowser(ctx, *userID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "启动浏览器失败: %v\n", err)
			os.Exit(1)
		}
		// 浏览器级 ws 无法直接 evaluate，从 debug port 的 /json/list 拿页面 ws
		pageWS, err := adspower.PageWSURL(ctx, debugPort)
		if err != nil {
			fmt.Fprintf(os.Stderr, "获取页面连接失败: %v\n", err)
			os.Exit(1)
		}
		cdp, err := adspower.ConnectCDP(ctx, pageWS)
		if err != nil {
			fmt.Fprintf(os.Stderr, "连接 CDP 失败: %v\n", err)
			os.Exit(1)
		}
		defer cdp.Close()

		// 确保在 TikTok 页面上下文（若浏览器停在空白页，导航过去）
		_, _ = cdp.Call(ctx, "Page.navigate", map[string]any{"url": "https://www.tiktok.com"})
		time.Sleep(3 * time.Second)

		data, err := adspower.ExtractTikTok(ctx, cdp)
		if err != nil {
			fmt.Fprintf(os.Stderr, "提取失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("提取到 TikTok 账号: uid=%d store_idc=%s device_id=%s cookies=%d\n",
			data.UID, data.StoreIDC, maskDeviceID(data.DeviceID), len(data.Cookies))
		if data.DeviceID == "" {
			names := make([]string, 0, len(data.Cookies))
			for _, c := range data.Cookies {
				names = append(names, c.Name)
			}
			fmt.Fprintf(os.Stderr, "警告: 未提取到 device_id。当前 cookies: %s\n", strings.Join(names, ", "))
			os.Exit(1)
		}
		if data.UID <= 0 {
			fmt.Fprintln(os.Stderr, "警告: 未提取到 uid (缺少 multi_sids cookie)")
			os.Exit(1)
		}
		cookieJSON, _ := store.MarshalCookies(data.Cookies)
		a, err := store.NewAccountFromCookieText(cookieJSON, data.DeviceID, *name, "", *proxy)
		if err != nil {
			fmt.Fprintf(os.Stderr, "构建账号失败: %v\n", err)
			os.Exit(1)
		}
		a.AdsProfileID = *userID
		id, err := db.CreateAccount(a)
		if err != nil {
			fmt.Fprintf(os.Stderr, "保存账号失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("账号已导入: id=%d (AdsPower: %s)\n", id, *userID)
	default:
		fmt.Fprintln(os.Stderr, "adspower 子命令: sync | list")
		os.Exit(1)
	}
}

// autoSend 全自动操作 TikTok 私信页：点击会话 → 输入文字 → 发送。
// 选择器集中管理于 protocol/selectors.go (DESIGN 13.7)。
func autoSend(ctx context.Context, cdp *adspower.CDPClient) {
	page := adspower.NewPage(cdp)
	// 0. 等待会话列表出现 (新版 dm-new-conversation-item, 2026-08 实测)
	var convID string
	for i := 0; i < 10; i++ {
		if _, err := page.WaitSelector(ctx, time.Second, 200*time.Millisecond, protocol.SelConversationItem...); err == nil {
			if v, err2 := cdp.Eval(ctx, `(document.querySelector('div[data-e2e="dm-new-conversation-item"]')?.getAttribute('data-conv-id'))||''`); err2 == nil {
				convID = v
			}
			break
		}
		fmt.Println("会话列表: WAIT")
		time.Sleep(2 * time.Second)
	}
	if convID != "" {
		fmt.Println("会话列表: READY conv-id=" + convID)
	} else {
		fmt.Println("会话列表: 未找到会话项")
	}
	// 1. 点击第一个会话 (新版是 div, 直接 click)
	if ok, err := page.Click(ctx, protocol.SelConversationItem...); err != nil || !ok {
		fmt.Println("会话点击: 未找到会话项", err)
	} else {
		fmt.Println("会话点击: 已点击")
	}

	// 2. 等待会话打开（chat-uniqueid 非空且非 @）+ 输入框出现
	time.Sleep(3 * time.Second)
	for i := 0; i < 10; i++ {
		uidTxt, _ := page.SelectorText(ctx, protocol.SelChatUniqueID...)
		inputSel, err := page.WaitSelector(ctx, time.Second, 200*time.Millisecond, protocol.SelMessageInput...)
		if uidTxt != "" && uidTxt != "@" && err == nil && inputSel != "" {
			fmt.Println("会话状态: READY:to=" + uidTxt)
			break
		}
		fmt.Println("会话状态: WAIT:" + uidTxt)
		time.Sleep(2 * time.Second)
	}

	// 3+4. 聚焦输入框 + CDP 真实键盘输入
	if err := page.Type(ctx, "hi", 100*time.Millisecond, protocol.SelMessageInput...); err != nil {
		fmt.Println("输入失败:", err)
	}
	time.Sleep(500 * time.Millisecond)

	// 输入后探测动态按钮 (新版发送按钮输入文字后才出现)
	exprBtns := `(() => { const out = []; const box = document.querySelector('div[data-e2e="dm-new-chat-bottom"]') || document.querySelector('div[data-e2e="dm-new-chatbox"]'); if (box) { box.querySelectorAll('button, [role=button]').forEach(b => { out.push(b.tagName.toLowerCase() + ' | aria=' + (b.getAttribute && b.getAttribute('aria-label')||'') + ' | cls=' + ((b.className||'').toString().slice(0,50))); }); } return out.join('\n'); })()`
	if res, err := cdp.Eval(ctx, exprBtns); err == nil && res != "" {
		fmt.Println("输入后按钮:", res)
	}

	// 5. 点击发送按钮。2026-08 实测: 新版发送按钮是
	//    svg[aria-label="Send"] (输入文字后出现, 非 button)。
	//    优先 svg 真实坐标点击 (CDP 鼠标事件 — React 组件有时忽略
	//    合成 click()), 再轮询通用选择器, 最后 Enter (重新聚焦后)。
	sent := false
	for i := 0; i < 5 && !sent; i++ {
		// 探测: 发送按钮坐标 + 命中元素 + 输入框内容 + 当前焦点。
		// 发送按钮必须在聊天输入区容器内找 — 全局 querySelector 会匹配到
		// 页面其他位置的 aria-label=Send 元素 (2026-08 实测点错过)。
		// 点击统一走 mouseClick (真实鼠标事件, SVGElement 无 click 方法)。
		expr := `(() => {
			const box = document.querySelector('div[data-e2e="dm-new-chat-bottom"]') || document.querySelector('div[data-e2e="dm-new-chatbox"]');
			if (!box) return 'no-box';
			const svg = box.querySelector('svg[aria-label="Send"], [aria-label="Send"]');
			if (!svg) return 'no-svg';
			const r = svg.getBoundingClientRect();
			if (r.width <= 0 || r.height <= 0) return 'hidden';
			const cx = Math.round(r.x + r.width/2), cy = Math.round(r.y + r.height/2);
			const hit = document.elementFromPoint(cx, cy);
			const hitDesc = hit ? hit.tagName + '.' + ((hit.className||'').toString().slice(0,30)) + ' aria=' + (hit.getAttribute && hit.getAttribute('aria-label') || '') : 'null';
			const input = box.querySelector('[contenteditable]');
			const inputTxt = input ? input.textContent.trim().slice(0, 30) : '?';
			const act = document.activeElement;
			const actDesc = act ? act.tagName + (act.getAttribute && act.getAttribute('data-e2e') || '') : 'null';
			// emoji 按钮坐标 — 用于 sanity check (真实点击应打开 emoji 面板)
			const emo = box.querySelector('[aria-label="Click to add emojis"]');
			const er = emo ? emo.getBoundingClientRect() : null;
			const eco = er && er.width > 0 ? Math.round(er.x + er.width/2) + '|' + Math.round(er.y + er.height/2) : 'none';
			return cx + '|' + cy + '|hit=' + hitDesc + '|input="' + inputTxt + '"|active=' + actDesc + '|emo=' + eco;
		})()`
		res, err := cdp.Eval(ctx, expr)
		if err != nil {
			fmt.Println("svg 探测错误:", err)
			continue
		}
		fmt.Println("svg 探测:", res)
		if res == "no-box" || res == "no-svg" || res == "hidden" {
			time.Sleep(600 * time.Millisecond)
			continue
		}
		parts := strings.SplitN(res, "|", 3)
		if len(parts) < 2 {
			continue
		}
		x, err1 := strconv.Atoi(parts[0])
		y, err2 := strconv.Atoi(parts[1])
		if err1 != nil || err2 != nil {
			continue
		}
		// 先点击 emoji 按钮做 sanity check — 真实鼠标点击应打开 emoji 面板
		// (否则 CDP Input 事件被忽略, 点击 send 也必然无效)
		emo := ""
		for _, part := range strings.Split(res, "|") {
			if strings.HasPrefix(part, "emo=") {
				emo = strings.TrimPrefix(part, "emo=")
			}
		}
		if emo != "" && emo != "none" {
			ep := strings.SplitN(emo, "|", 2)
			if len(ep) == 2 {
				if ex, e1 := strconv.Atoi(ep[0]); e1 == nil {
					if ey, e2 := strconv.Atoi(ep[1]); e2 == nil {
						if err := mouseClick(ctx, cdp, float64(ex), float64(ey)); err != nil {
							fmt.Println("emoji 点击失败:", err)
						} else {
							time.Sleep(600 * time.Millisecond)
							panel, _ := cdp.Eval(ctx, `(() => { const box = document.querySelector('div[data-e2e="dm-new-chat-bottom"]'); const btn = box ? box.querySelector('[aria-label="Click to add emojis"]') : null; return btn ? 'emoji-btn-still-' + btn.getAttribute('aria-label') : 'emoji-btn-gone'; })()`)
							fmt.Println("sanity:", panel)
							// 无论面板是否打开, 再次点击关闭, 恢复原状
							_ = mouseClick(ctx, cdp, float64(ex), float64(ey))
							time.Sleep(300 * time.Millisecond)
						}
					}
				}
			}
		}
		// 坐标点击 send (真实鼠标事件, 与用户操作一致)
		if err := mouseClick(ctx, cdp, float64(x), float64(y)); err != nil {
			fmt.Println("svg 坐标点击失败:", err)
		}
		time.Sleep(800 * time.Millisecond)
		// 检查输入框是否已清空 (清空 = 发送成功)
		empty, _ := cdp.Eval(ctx, `(() => { const box = document.querySelector('div[data-e2e="dm-new-chat-bottom"]'); const input = box ? box.querySelector('[contenteditable]') : null; return input ? (input.textContent.trim() === '' ? 'cleared' : 'still:' + input.textContent.trim().slice(0,20)) : 'no-input'; })()`)
		fmt.Println("发送状态:", empty)
		if strings.HasPrefix(empty, "cleared") {
			sent = true
			break
		}
	}
	if !sent {
		// Enter 前重新聚焦输入框 (中间多次 Eval/点击, 输入框可能失焦)
		if _, err := page.Click(ctx, protocol.SelMessageInput...); err == nil {
			time.Sleep(200 * time.Millisecond)
		}
		if err := pressEnter(ctx, cdp); err != nil {
			fmt.Println("发送: Enter 键失败:", err)
		} else {
			fmt.Println("发送: SENT (Enter)")
		}
	}
	time.Sleep(2 * time.Second)

	// 验证: 扫描聊天区消息项 (排除输入区容器本身 — chat-bottom/chatbox
	// 的文本是输入框内容不是消息)
	exprVerify := `(() => { const out = []; let last = 'none'; document.querySelectorAll('div[data-e2e="dm-new-chat-item"]').forEach(el => { const t = (el.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 70); if (t) last = t; if (out.length < 8) out.push(t); }); const input = document.querySelector('[data-e2e="message-input-area"]'); const inputTxt = input ? input.textContent.trim().slice(0, 40) : '?'; return 'items=' + out.length + ' last=' + last + ' input="' + inputTxt + '" || ' + out.join(' | ').slice(0, 400); })()`
	if res, err := cdp.Eval(ctx, exprVerify); err == nil {
		fmt.Println("发送验证:", res)
	}
	// 截图保存现场 (验证 UI 真实状态: 发送按钮/失败提示/输入框)
	if err := page.Screenshot(ctx, filepath.Join(os.TempDir(), "ttdm_autosend.png")); err == nil {
		fmt.Println("截图: " + filepath.Join(os.TempDir(), "ttdm_autosend.png"))
	}
}

// mouseClick 用 CDP 真实鼠标事件在页面坐标 (x,y) 处点击。
// React 组件有时忽略合成 click(), 真实输入事件必然触发 onClick/onPointerUp。
func mouseClick(ctx context.Context, cdp *adspower.CDPClient, x, y float64) error {
	events := []struct {
		name string
		par  map[string]any
	}{
		{"mouseMoved", map[string]any{"type": "mouseMoved", "x": x, "y": y, "button": "none"}},
		{"mousePressed", map[string]any{"type": "mousePressed", "x": x, "y": y, "button": "left", "buttons": 1, "clickCount": 1}},
		{"mouseReleased", map[string]any{"type": "mouseReleased", "x": x, "y": y, "button": "left", "buttons": 0, "clickCount": 1}},
	}
	for _, e := range events {
		if _, err := cdp.Call(ctx, "Input.dispatchMouseEvent", e.par); err != nil {
			return fmt.Errorf("%s: %w", e.name, err)
		}
		time.Sleep(60 * time.Millisecond)
	}
	return nil
}

// pressEnter dispatches a real Enter keyDown/keyUp via CDP (新版 DM 无
// 静态发送按钮, Enter 发送是页面默认行为)。keyDown 需带 text 字段,
// 否则 Chromium 不生成完整按键 (之前 Enter 无效的原因之一)。
func pressEnter(ctx context.Context, cdp *adspower.CDPClient) error {
	keys := []map[string]any{
		{"type": "keyDown", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "nativeVirtualKeyCode": 13, "text": "\r"},
		{"type": "keyUp", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "nativeVirtualKeyCode": 13},
	}
	for _, k := range keys {
		if _, err := cdp.Call(ctx, "Input.dispatchKeyEvent", k); err != nil {
			return fmt.Errorf("key event: %w", err)
		}
	}
	return nil
}

// pressEscape sends an Escape key press (closes overlay dialogs).
func pressEscape(ctx context.Context, cdp *adspower.CDPClient) error {
	keys := []map[string]any{
		{"type": "keyDown", "key": "Escape", "code": "Escape", "windowsVirtualKeyCode": 27, "nativeVirtualKeyCode": 27},
		{"type": "keyUp", "key": "Escape", "code": "Escape", "windowsVirtualKeyCode": 27, "nativeVirtualKeyCode": 27},
	}
	for _, k := range keys {
		if _, err := cdp.Call(ctx, "Input.dispatchKeyEvent", k); err != nil {
			return fmt.Errorf("key event: %w", err)
		}
	}
	return nil
}

func maskDeviceID(id string) string {
	if len(id) <= 8 {
		return "***"
	}
	return id[:4] + "..." + id[len(id)-4:]
}

func truncateStr(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

// ---------- message ----------

func cmdMessage(db *store.DB, args []string) {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "用法: ttdm message export <task-id>")
		os.Exit(1)
	}
	id, err := strconv.ParseInt(args[1], 10, 64)
	if err != nil {
		fmt.Fprintf(os.Stderr, "无效 id: %v\n", err)
		os.Exit(1)
	}
	msgs, err := db.ListMessagesByTask(id)
	if err != nil {
		fmt.Fprintf(os.Stderr, "查询失败: %v\n", err)
		os.Exit(1)
	}
	out := csv.NewWriter(os.Stdout)
	defer out.Flush()
	out.Write([]string{"id", "task_id", "sender_uid", "receiver_uid", "text_status", "text_error",
		"link_status", "video_status", "image_status", "homepage_status", "sent_at"})
	for _, m := range msgs {
		out.Write([]string{
			strconv.FormatInt(m.ID, 10),
			strconv.FormatInt(m.TaskID, 10),
			strconv.FormatInt(m.SenderUID, 10),
			strconv.FormatInt(m.ReceiverUID, 10),
			strconv.FormatInt(int64(intOr(m.TextStatus, -1)), 10),
			strPtrOr(m.TextError, ""),
			strconv.FormatInt(int64(intOr(m.LinkStatus, -1)), 10),
			strconv.FormatInt(int64(intOr(m.VideoStatus, -1)), 10),
			strconv.FormatInt(int64(intOr(m.ImageStatus, -1)), 10),
			strconv.FormatInt(int64(intOr(m.HomepageStatus, -1)), 10),
			strconv.FormatInt(m.SentAt, 10),
		})
	}
}

// ---------- helpers ----------

func statusOf(s *int) string {
	if s == nil {
		return "未请求"
	}
	if *s == store.SendSuccess {
		return "成功"
	}
	return "失败"
}

func statusText(success bool, errMsg string) string {
	if success {
		return "成功"
	}
	if errMsg == "" {
		return "失败"
	}
	return "失败:" + errMsg
}

func intOr(p *int, def int) int {
	if p == nil {
		return def
	}
	return *p
}

func strPtrOr(p *string, def string) string {
	if p == nil {
		return def
	}
	return *p
}
