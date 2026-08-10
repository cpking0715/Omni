// wedsnap 从 M6-3 抓包产物 (send_body.txt) 提取 Web 签名快照:
//
//	go run ./cmd/wedsnap <send_body.txt> <out.json>
//
// send_body.txt 包含 "XHR https://im-api.tiktok.com/v1/message/send?..." 行
// (完整签名 URL) 与 "=== GETREQUESTPOSTDATA ===" 后的 base64 body。
package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"regexp"

	"ttdm/internal/protocol"
)

// urlRe 优先匹配 CDP NETWORK EVENTS 行 (含 webmssdk 附加的完整签名 URL),
// 回退匹配页面 hook 的 XHR 行。
var urlRe = regexp.MustCompile(`url=(https://im-api\.tiktok\.com/v1/message/send\?[^\s"']+)`)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "用法: wedsnap <send_body.txt> <out.json>")
		os.Exit(2)
	}
	content, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "读取输入失败:", err)
		os.Exit(1)
	}
	text := string(content)

	m := urlRe.FindStringSubmatch(text)
	if m == nil {
		fmt.Fprintln(os.Stderr, "未找到带签名的 message/send URL (需要 CDP NETWORK EVENTS 段)")
		os.Exit(1)
	}
	fullURL := m[1]

	marker := "=== GETREQUESTPOSTDATA ==="
	idx := indexOf(text, marker)
	if idx < 0 {
		fmt.Fprintln(os.Stderr, "未找到 GETREQUESTPOSTDATA 段")
		os.Exit(1)
	}
	b64 := trimSpace(text[idx+len(marker):])
	body, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		fmt.Fprintln(os.Stderr, "body base64 解码失败:", err)
		os.Exit(1)
	}

	snap := protocol.SnapshotFromBody(body, fullURL)
	out, err := json.MarshalIndent(snap, "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, "序列化失败:", err)
		os.Exit(1)
	}
	if err := os.WriteFile(os.Args[2], out, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "写入失败:", err)
		os.Exit(1)
	}
	fmt.Printf("快照已生成: %s (sign: %d+%d 字符, meta: verifyFp=%s)\n",
		os.Args[2], len(snap.Sign.XDynosaur), len(snap.Sign.XGnarly), short(snap.Meta.VerifyFP, 24))
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

func trimSpace(s string) string {
	start, end := 0, len(s)
	for start < end && (s[start] == ' ' || s[start] == '\n' || s[start] == '\r' || s[start] == '\t') {
		start++
	}
	for end > start && (s[end-1] == ' ' || s[end-1] == '\n' || s[end-1] == '\r' || s[end-1] == '\t') {
		end--
	}
	return s[start:end]
}

func short(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
