// 诊断 CheckCookie: 打印 Go http 请求的状态码与 profile 页 uid 解析结果。
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
)

func main() {
	raw, _ := os.ReadFile("d:/MyProjects/OmniMarket/ttdm/bin/m6/m6_account.json")
	var docs []struct {
		Cookies []struct {
			Name  string `json:"name"`
			Value string `json:"value"`
			Domain string `json:"domain"`
		} `json:"cookies"`
	}
	json.Unmarshal(raw, &docs)
	var parts []string
	for _, c := range docs[0].Cookies {
		parts = append(parts, c.Name+"="+c.Value)
	}
	cs := strings.Join(parts, "; ")
	ua := "com.zhiliaoapp.musically/2022502030 (Linux; U; Android 12; en; SM-G9900; Build/V417IR;tt-ok/3.12.13.1)"
	req, _ := http.NewRequestWithContext(context.Background(), "GET", "https://www.tiktok.com/profile", nil)
	req.Header.Set("User-Agent", ua)
	req.Header.Set("Cookie", cs)
	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Println("err:", err)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	fmt.Printf("status=%d bodylen=%d proto=%s\n", resp.StatusCode, len(body), resp.Proto)
	marker := `id="__UNIVERSAL_DATA_FOR_REHYDRATION__"`
	if i := strings.Index(string(body), marker); i > 0 {
		fmt.Println("marker found at", i)
		s := strings.Index(string(body)[i:], ">")
		e := strings.Index(string(body)[i:], "</script>")
		if s >= 0 && e > s {
			blob := string(body)[i+s+1 : i+e]
			fmt.Printf("blob len=%d uid markers: %d\n", len(blob), strings.Count(blob, `"uid"`))
			var root map[string]json.RawMessage
			if err := json.Unmarshal([]byte(blob), &root); err == nil {
				for k := range root {
					fmt.Printf("top key: %q (len=%d)\n", k, len(root[k]))
				}
				// 找 uid 所在路径
				if sc, ok := root["__DEFAULT_SCOPE__"]; ok {
					var scm map[string]json.RawMessage
					json.Unmarshal(sc, &scm)
					for k := range scm {
						fmt.Printf("  scope key: %q (len=%d)\n", k, len(scm[k]))
					}
					if det, ok := scm["webapp.user-detail"]; ok {
						var detm map[string]json.RawMessage
						json.Unmarshal(det, &detm)
						for k := range detm {
							fmt.Printf("    user-detail key: %q (len=%d)\n", k, len(detm[k]))
						}
						if ui, ok := detm["userInfo"]; ok {
							var uim map[string]json.RawMessage
							json.Unmarshal(ui, &uim)
							for k := range uim {
								fmt.Printf("      userInfo key: %q (len=%d)\n", k, len(uim[k]))
							}
							if usr, ok := uim["user"]; ok {
								var usm map[string]json.RawMessage
								json.Unmarshal(usr, &usm)
								for k := range usm {
									if len(usm[k]) < 60 {
										fmt.Printf("        user.%s = %s\n", k, usm[k])
									}
								}
							}
						}
					}
				}
			}
		}
	} else {
		fmt.Println("marker NOT found")
	}
	// 显示页面中的 uid 候选
	low := string(body)
	for _, pat := range []string{`"uid":"`, `"uid":`, `user_id":"`, `"uniqueId"`} {
		if i := strings.Index(low, pat); i > 0 {
			fmt.Printf("pat %s at %d: %q\n", pat, i, low[i-30:i+60])
		}
	}
}
