// websend 用 Web 通道二 HTTP 层真实发送一条文本消息 (M6-4 验证):
//
//	go run ./cmd/websend [-snap <sign_snapshot.json>] -to <uid> -account <account.json> -text <text>
//	或:  websend <sign_snapshot.json|-> <account.json> <to_uid> <text>
//
// account.json: { "uid": 7664958044560016398, "device_id": "...",
// "cookies": [{"name":"sessionid","value":"...","domain":".tiktok.com"}, ...] }
// 响应 204 = 成功; 200+protobuf = 业务错误 (7193 等)。
// M6-4 实测 (2026-08-09): 签名对 message/send 完全非必需, 快照传 "-" 走无签名直连。
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"ttdm/internal/protocol"
	"ttdm/internal/store"
)

type accountFile struct {
	UID      jsonUID       `json:"uid"`
	DeviceID string        `json:"device_id"`
	Cookies  []store.Cookie `json:"cookies"`
}

// jsonUID 兼容 uid 字段的字符串/数字两种形态 (cookiexport 输出字符串)。
type jsonUID int64

func (u *jsonUID) UnmarshalJSON(b []byte) error {
	s := strings.Trim(string(b), "\"")
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return err
	}
	*u = jsonUID(n)
	return nil
}

func main() {
	if len(os.Args) == 5 {
		runLegacy(os.Args[1], os.Args[2], os.Args[3], os.Args[4])
		return
	}
	fs := flag.NewFlagSet("websend", flag.ExitOnError)
	snapPath := fs.String("snap", "-", "签名快照 JSON 路径, '-'=无签名直连")
	acctPath := fs.String("account", "", "账号 JSON 路径")
	toUID := fs.Int64("to", 0, "接收方 UID")
	text := fs.String("text", "", "消息文本")
	fs.Parse(os.Args[1:])
	if *acctPath == "" || *toUID == 0 || *text == "" {
		fmt.Fprintln(os.Stderr, "用法: websend -snap <json|-> -account <json> -to <uid> -text <text>")
		os.Exit(2)
	}
	run(*snapPath, *acctPath, *toUID, *text)
}

// runLegacy 兼容旧调用: websend <snap|-> <account.json> <to_uid> <text>
func runLegacy(snapPath, acctPath, toUIDStr, text string) {
	toUID, err := strconv.ParseInt(toUIDStr, 10, 64)
	if err != nil {
		fmt.Fprintln(os.Stderr, "解析 to_uid 失败:", err)
		os.Exit(2)
	}
	run(snapPath, acctPath, toUID, text)
}

func run(snapPath, acctPath string, toUID int64, text string) {
	acct := loadAccount(acctPath)
	client, err := protocol.NewWebClient(acct)
	if err != nil {
		fmt.Fprintln(os.Stderr, "NewWebClient:", err)
		os.Exit(1)
	}
	if snapPath != "" && snapPath != "-" {
		snap, err := protocol.LoadWebSignSnapshot(snapPath)
		if err != nil {
			fmt.Fprintln(os.Stderr, "加载签名快照失败:", err)
			os.Exit(1)
		}
		client.SetWebSign(snap)
	} else {
		fmt.Println("无签名直连 (M6-4: 签名非必需)")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()

	cid, err := client.CreateConversation(ctx, toUID)
	if err != nil {
		fmt.Fprintln(os.Stderr, "CreateConversation:", err)
		os.Exit(1)
	}
	fmt.Printf("会话: %s\n", cid.ID)

	start := time.Now()
	res, err := client.SendText(ctx, cid, text)
	if err != nil {
		fmt.Fprintln(os.Stderr, "SendText:", err)
		os.Exit(1)
	}
	fmt.Printf("耗时 %s 结果: Terminate=%v Quit=%v Error=%q\n",
		time.Since(start).Round(time.Millisecond), res.Terminate, res.Quit, res.Error)
	if res.Terminate || res.Quit {
		os.Exit(3) // 业务拒绝
	}
}

func loadAccount(path string) *store.Account {
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "读取账号失败:", err)
		os.Exit(1)
	}
	// 兼容两种格式: full JSON 对象 / 账号对象数组 [{"cookies":...}] (cookiexport 输出)
	if strings.HasPrefix(strings.TrimSpace(string(raw)), "[") {
		var arr []accountFile
		if err := json.Unmarshal(raw, &arr); err != nil {
			fmt.Fprintln(os.Stderr, "解析账号数组失败:", err)
			os.Exit(1)
		}
		if len(arr) == 0 {
			fmt.Fprintln(os.Stderr, "账号数组为空")
			os.Exit(1)
		}
		af := arr[0]
		if af.UID == 0 || len(af.Cookies) == 0 {
			fmt.Fprintln(os.Stderr, "账号缺少 uid/cookies")
			os.Exit(1)
		}
		if af.DeviceID == "" {
			af.DeviceID = store.TTWidDeviceID(af.Cookies)
		}
		return &store.Account{UID: int64(af.UID), DeviceID: af.DeviceID, Cookies: af.Cookies}
	}
	var af accountFile
	if err := json.Unmarshal(raw, &af); err != nil {
		fmt.Fprintln(os.Stderr, "解析账号失败:", err)
		os.Exit(1)
	}
	if af.UID == 0 || len(af.Cookies) == 0 {
		fmt.Fprintln(os.Stderr, "账号缺少 uid/cookies")
		os.Exit(1)
	}
	if af.DeviceID == "" {
		af.DeviceID = store.TTWidDeviceID(af.Cookies)
	}
	return &store.Account{UID: int64(af.UID), DeviceID: af.DeviceID, Cookies: af.Cookies}
}
