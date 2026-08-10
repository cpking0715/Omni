// 一次性探针: 验证 Web 通道 access_key 是静态常量还是公式推导。
// 连接 1: 捕获到的真实 access_key (08ac725d...)
// 连接 2: Android 公式 AccessKey(deviceID) (对照组)
// 每次连接后发送同步帧, 等待服务端响应。
package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"time"

	"github.com/gorilla/websocket"

	"ttdm/internal/protocol"
	"ttdm/internal/store"
)

const (
	realWebAccessKey = "08ac725d2a9a3fac7cc3a25bb7a44aec"
	webWSSHost       = "im-ws.tiktok.com"
	webSubProto      = "pbbp2"
	webChromeUA      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
)

func buildURL(deviceID, ttwid, accessKey string) string {
	v := url.Values{}
	v.Set("device_platform", "web")
	v.Set("version_code", "fws_1.0.0")
	v.Set("access_key", accessKey)
	v.Set("fpid", "9")
	v.Set("aid", "1459")
	v.Set("ttwid", ttwid)
	v.Set("xsack", "1")
	v.Set("xaack", "1")
	v.Set("xsqos", "0")
	return "wss://" + webWSSHost + "/ws/v2?" + v.Encode()
}

func tryConnect(label, wsURL string, acct *store.Account) {
	fmt.Printf("\n=== %s ===\n%s\n", label, wsURL)
	dialer := websocket.Dialer{Subprotocols: []string{webSubProto}, HandshakeTimeout: 30 * time.Second}
	header := http.Header{}
	header.Set("User-Agent", webChromeUA)
	header.Set("Origin", "https://www.tiktok.com")
	header.Set("Cookie", acct.CookieString())
	ctx, cancel := context.WithTimeout(context.Background(), 35*time.Second)
	defer cancel()

	conn, resp, err := dialer.DialContext(ctx, wsURL, header)
	if err != nil {
		if resp != nil {
			fmt.Printf("拒绝 HTTP %d: %v\n", resp.StatusCode, err)
		} else {
			fmt.Printf("连接失败: %v\n", err)
		}
		return
	}
	defer conn.Close()
	fmt.Println("已连接 ✓")

	// 发送同步帧 sn=10001
	uid := acct.UID
	body := protocol.MustBuildWebSyncFrame(10001, uid)
	if err := conn.WriteMessage(websocket.BinaryMessage, body); err != nil {
		fmt.Printf("发送同步帧失败: %v\n", err)
		return
	}
	fmt.Printf("已发送同步帧 sn=10001 (%d bytes)\n", len(body))

	// 等待服务端响应
	deadline := time.Now().Add(8 * time.Second)
	got := 0
	for time.Now().Before(deadline) {
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		_, data, err := conn.ReadMessage()
		if err != nil {
			if ne, ok := err.(netErr); ok && ne.Timeout() {
				break
			}
			fmt.Printf("读取结束: %v\n", err)
			break
		}
		f, perr := protocol.ParseWebFrame(data)
		if perr != nil {
			fmt.Printf("帧 %d: %d bytes (未解析: %v)\n", got, len(data), perr)
			continue
		}
		fmt.Printf("帧 %d: sn=%d service=%d method=%d body=%d bytes\n",
			got, f.SN, f.Service, f.Method, len(f.Body))
		got++
	}
	fmt.Printf("共收到 %d 帧\n", got)
}

type netErr interface{ Timeout() bool }

func main() {
	dbPath := flag.String("db", "bin/m6/ttdm.db", "ttdm.db 路径")
	flag.Parse()

	db, err := store.Open(*dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "打开数据库失败: %v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	acct, err := db.GetAccount(1)
	if err != nil {
		fmt.Fprintf(os.Stderr, "读取账号失败: %v\n", err)
		os.Exit(1)
	}
	ttwid := store.TTWid(acct.Cookies)
	fmt.Printf("uid=%d device_id=%s store_idc=%s cookies=%d\n", acct.UID, acct.DeviceID, acct.StoreIDC, len(acct.Cookies))
	fmt.Printf("ttwid=%s\n", ttwid)
	fmt.Printf("公式 access_key = %s\n", protocol.AccessKey(acct.DeviceID))

	tryConnect("连接1: 真实 access_key (静态假设)", buildURL(acct.DeviceID, ttwid, realWebAccessKey), acct)
	tryConnect("连接2: 公式 access_key (对照)", buildURL(acct.DeviceID, ttwid, protocol.AccessKey(acct.DeviceID)), acct)
}
