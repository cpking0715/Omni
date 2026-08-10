// 临时验证: 输出 BuildWebSendBody 的 base64 (供 PowerShell 用原始 URL 重放)
package main

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"

	"ttdm/internal/protocol"
)

func uuid() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func main() {
	text := "probe11 - raw url test"
	emptyMeta := false
	toUID := int64(7366359960223482885)
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-empty":
			emptyMeta = true
		case "-to":
			if i+1 < len(args) {
				fmt.Sscanf(args[i+1], "%d", &toUID)
				i++
			}
		case "-text":
			if i+1 < len(args) {
				text = args[i+1]
				i++
			}
		default:
			text = args[i]
		}
	}
	var meta protocol.WebSendMeta
	if !emptyMeta {
		snap, err := protocol.LoadWebSignSnapshot("d:/MyProjects/OmniMarket/ttdm/bin/m6/sign_snapshot.json")
		if err != nil {
			fmt.Fprintln(os.Stderr, "load snapshot:", err)
			os.Exit(1)
		}
		meta = snap.Meta
	}
	body := protocol.BuildWebSendBody(7664958044560016398, toUID, "7669334412366218765", text, uuid(), meta)
	fmt.Print(base64.StdEncoding.EncodeToString(body))
}
