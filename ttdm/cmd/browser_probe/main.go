// M6-5 验证: browser 通道真实端到端 (AdsPower profile → CDP → DOM 操作 → 发送)。
// 目标 = 测试账号自身会话, 发送/接收即为探测验证。
package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"ttdm/internal/protocol"
	"ttdm/internal/store"
)

const (
	apiKey     = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
	adsProfile = "k1fan6kh"
	toUID      = 7366359960223482885
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: browser_probe <text>")
		os.Exit(1)
	}
	text := os.Args[1]
	acc := &store.Account{UID: 7664958044560016398, AdsProfileID: adsProfile}

	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()

	t0 := time.Now()
	bc, err := protocol.NewBrowserClient(acc, apiKey)
	if err != nil {
		fmt.Fprintln(os.Stderr, "new client:", err)
		os.Exit(1)
	}
	if err := bc.Connect(ctx, ""); err != nil {
		fmt.Fprintln(os.Stderr, "connect:", err)
		os.Exit(1)
	}
	fmt.Printf("connected: %s\n", time.Since(t0).Round(time.Millisecond))

	cid, err := bc.CreateConversation(ctx, toUID)
	if err != nil {
		fmt.Fprintln(os.Stderr, "conversation:", err)
		os.Exit(1)
	}
	fmt.Printf("conversation ready: %s (%s)\n", cid.ID, time.Since(t0).Round(time.Millisecond))

	res, err := bc.SendText(ctx, cid, text)
	if err != nil {
		fmt.Fprintln(os.Stderr, "send:", err)
		os.Exit(1)
	}
	fmt.Printf("result: %+v\n", res)
	if res.Error == "" {
		fmt.Println("SENT (browser channel)")
	} else {
		fmt.Println("BLOCKED:", res.Error)
	}
	verifySent(bc, ctx, text)
}

// verifySent 从 DOM 读回聊天记录, 确认消息进入聊天流。
// 优先用 SelLastChatItem, 失败则回退到全文搜索叶子节点文本。
func verifySent(bc *protocol.BrowserClient, ctx context.Context, text string) {
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		txt, err := bc.LastChatText(ctx)
		if err == nil && txt != "" {
			fmt.Printf("LAST CHAT ITEM: %q\n", txt)
			if strings.Contains(txt, text) {
				fmt.Println("VERIFIED: message visible in chat DOM")
				return
			}
		}
		// 全文搜索叶子节点 (适配页面结构变化)
		if found, err := bc.FindText(ctx, text); err == nil && found != "" {
			fmt.Printf("DOM TEXT FOUND: %q\n", found)
			fmt.Println("VERIFIED: message visible in chat DOM")
			return
		}
		time.Sleep(1 * time.Second)
	}
	fmt.Println("WARN: sent text not found in chat DOM")
}
