package main

import (
	"context"
	"encoding/csv"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"ttdm/internal/store"
	"ttdm/internal/tiktokapi"
)

// ---------- account import ----------

// cmdAccountImport bulk-imports accounts from a file in any of the 4 CK
// formats (DESIGN 2.8): full JSON / cookie JSON array / cookie string lines
// / ---- segments. One bad entry never aborts the whole batch.
func cmdAccountImport(db *store.DB, args []string) {
	fs := flag.NewFlagSet("account import", flag.ExitOnError)
	file := fs.String("file", "", "导入文件路径 (文本或 JSON)")
	deviceID := fs.String("device-id", "", "统一设备 ID (JSON 扩展字段/ttwid 优先)")
	proxy := fs.String("proxy", "", "统一代理 URL")
	adsProfile := fs.String("ads-profile", "", "浏览器环境: AdsPower 配置 ID 或 local:<端口> 本地直连 (模拟通道需要; 仅单账号导入时生效)")
	fs.Parse(args)
	if *file == "" {
		fmt.Fprintln(os.Stderr, "需要 --file")
		os.Exit(1)
	}
	raw, err := os.ReadFile(*file)
	if err != nil {
		fmt.Fprintf(os.Stderr, "读取文件失败: %v\n", err)
		os.Exit(1)
	}
	items, err := store.ParseImport(string(raw))
	if err != nil {
		fmt.Fprintf(os.Stderr, "解析失败: %v\n", err)
		os.Exit(1)
	}
	ok, fail := 0, 0
	if *adsProfile != "" && len(items) > 1 {
		fmt.Fprintln(os.Stderr, "警告: --ads-profile 仅对单账号导入生效, 已忽略")
	}
	for i, item := range items {
		a, err := item.ToAccount(*deviceID, *proxy)
		if err != nil {
			fail++
			fmt.Fprintf(os.Stderr, "[%d] 跳过: %v\n", i+1, err)
			continue
		}
		if *adsProfile != "" && len(items) == 1 {
			a.AdsProfileID = *adsProfile
		}
		id, err := db.CreateAccount(a)
		if err != nil {
			fail++
			fmt.Fprintf(os.Stderr, "[%d] uid=%d 保存失败 (可能重复): %v\n", i+1, a.UID, err)
			continue
		}
		ok++
		fmt.Printf("[%d] 已导入: id=%d uid=%d device_id=%s store_idc=%s\n",
			i+1, id, a.UID, maskDeviceID(a.DeviceID), a.StoreIDC)
	}
	fmt.Printf("导入完成: 成功 %d, 失败 %d\n", ok, fail)
}

// ---------- screening ----------

func cmdScreening(db *store.DB, args []string) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "screening 子命令: run | list | export")
		os.Exit(1)
	}
	switch args[0] {
	case "run":
		cmdScreeningRun(db, args[1:])
	case "list":
		fs := flag.NewFlagSet("screening list", flag.ExitOnError)
		label := fs.String("label", "", "按标签过滤")
		fs.Parse(args[1:])
		rows, err := db.ListScreenings(*label)
		if err != nil {
			fmt.Fprintf(os.Stderr, "查询失败: %v\n", err)
			os.Exit(1)
		}
		chatable, total, _ := db.CountScreenings(*label)
		fmt.Printf("%-20s %-18s %-18s %-6s %s\n", "标签", "发送者UID", "目标UID", "可发", "错误")
		for _, s := range rows {
			fmt.Printf("%-20s %-18d %-18s %-6d %s\n",
				s.Label, s.SenderUID, s.TargetUID, s.MaxMessageCount, s.Error)
		}
		fmt.Printf("\n共 %d 条, 其中可私信 %d 条\n", total, chatable)
	case "export":
		fs := flag.NewFlagSet("screening export", flag.ExitOnError)
		label := fs.String("label", "", "按标签过滤")
		chatableOnly := fs.Bool("chatable", false, "仅导出可私信目标")
		fs.Parse(args[1:])
		out := csv.NewWriter(os.Stdout)
		defer out.Flush()
		out.Write([]string{"label", "sender_uid", "target_uid", "max_message_count", "error", "updated_at"})
		if *chatableOnly {
			uids, err := db.ChatableTargetUIDs(*label)
			if err != nil {
				fmt.Fprintf(os.Stderr, "查询失败: %v\n", err)
				os.Exit(1)
			}
			for _, uid := range uids {
				out.Write([]string{*label, "", uid, "", "", ""})
			}
			return
		}
		rows, err := db.ListScreenings(*label)
		if err != nil {
			fmt.Fprintf(os.Stderr, "查询失败: %v\n", err)
			os.Exit(1)
		}
		for _, s := range rows {
			out.Write([]string{
				s.Label,
				strconv.FormatInt(s.SenderUID, 10),
				s.TargetUID,
				strconv.Itoa(s.MaxMessageCount),
				s.Error,
				time.UnixMilli(s.UpdatedAt).Format("2006-01-02 15:04:05"),
			})
		}
	default:
		fmt.Fprintln(os.Stderr, "screening 子命令: run | list | export")
		os.Exit(1)
	}
}

// cmdScreeningRun executes the 强私筛选: for each target uid call
// /tiktok/v1/im/chat/notice/ with the sender account cookie and record
// the max message count (0/1/3). Threads configurable (default 10),
// proxies round-robin, TLS verification enforced (DESIGN 4.5/5.11 fixes).
func cmdScreeningRun(db *store.DB, args []string) {
	fs := flag.NewFlagSet("screening run", flag.ExitOnError)
	accountID := fs.Int64("account", 0, "发送账号 id (提供 cookie/uid/store-idc)")
	targets := fs.String("targets", "", "目标 uid 列表, 逗号分隔或 @文件")
	threads := fs.Int("threads", 10, "并发线程数 (1-100)")
	proxies := fs.String("proxy", "", "代理 URL, 逗号分隔多个则轮询")
	label := fs.String("label", "", "结果标签 (供后续导出/建任务)")
	skipCookieCheck := fs.Bool("skip-cookie-check", false, "跳过 Cookie 有效性先验")
	fs.Parse(args)

	if *accountID == 0 || *targets == "" {
		fmt.Fprintln(os.Stderr, "需要 --account 和 --targets")
		os.Exit(1)
	}
	acct, err := db.GetAccount(*accountID)
	if err != nil || acct == nil {
		fmt.Fprintf(os.Stderr, "账号 %d 不存在\n", *accountID)
		os.Exit(1)
	}
	if acct.UID <= 0 {
		fmt.Fprintln(os.Stderr, "账号缺少 uid, 无法筛选")
		os.Exit(1)
	}
	if *threads < 1 {
		*threads = 1
	}
	if *threads > 100 {
		*threads = 100
	}

	// parse targets (comma separated or @file, one uid per line)
	targetText := *targets
	if strings.HasPrefix(*targets, "@") {
		b, err := os.ReadFile(strings.TrimPrefix(*targets, "@"))
		if err != nil {
			fmt.Fprintf(os.Stderr, "读取目标文件失败: %v\n", err)
			os.Exit(1)
		}
		targetText = string(b)
	}
	seen := map[string]bool{}
	var uids []string
	for _, part := range strings.FieldsFunc(targetText, func(r rune) bool {
		return r == ',' || r == '\n' || r == '\r' || r == ' ' || r == '\t'
	}) {
		uid := strings.TrimSpace(part)
		if uid == "" || seen[uid] {
			continue
		}
		seen[uid] = true
		uids = append(uids, uid)
	}
	if len(uids) == 0 {
		fmt.Fprintln(os.Stderr, "目标列表为空")
		os.Exit(1)
	}

	var proxyList []string
	for _, p := range strings.Split(*proxies, ",") {
		if p = strings.TrimSpace(p); p != "" {
			proxyList = append(proxyList, p)
		}
	}
	// account-level proxy as fallback when no --proxy given
	if len(proxyList) == 0 && acct.ProxyURL != "" {
		proxyList = append(proxyList, acct.ProxyURL)
	}

	// one client per worker thread (each with its round-robin proxy)
	clients := make([]*tiktokapi.Client, *threads)
	for i := range clients {
		proxyURL := ""
		if len(proxyList) > 0 {
			proxyURL = proxyList[i%len(proxyList)]
		}
		c, err := tiktokapi.NewClient(acct.CookieString(), acct.StoreIDC, proxyURL)
		if err != nil {
			fmt.Fprintf(os.Stderr, "初始化筛选客户端失败: %v\n", err)
			os.Exit(1)
		}
		clients[i] = c
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// cookie validity pre-check (CheckCookieAsync equivalent)
	if !*skipCookieCheck {
		fmt.Print("校验账号 Cookie 有效性...")
		valid, err := clients[0].CheckCookie(ctx)
		if err != nil {
			fmt.Printf("失败: %v (可用 --skip-cookie-check 跳过)\n", err)
			os.Exit(1)
		}
		if !valid {
			fmt.Println("Cookie 可能失效")
			os.Exit(1)
		}
		fmt.Println("有效 ✓")
	}

	fmt.Printf("开始强私筛选: 目标 %d 个, 线程 %d, 代理 %d 个\n", len(uids), *threads, len(proxyList))

	var done, okCount, denyCount, errCount atomic.Int64
	jobs := make(chan struct{ idx int; uid string }, len(uids))
	for i, uid := range uids {
		jobs <- struct{ idx int; uid string }{i, uid}
	}
	close(jobs)

	start := time.Now()
	var wg sync.WaitGroup
	for w := 0; w < *threads; w++ {
		wg.Add(1)
		go func(client *tiktokapi.Client) {
			defer wg.Done()
			for job := range jobs {
				row := &store.Screening{
					Label:     *label,
					SenderUID: acct.UID,
					TargetUID: job.uid,
				}
				count, err := client.CheckImPermission(ctx, acct.UID, job.uid)
				if err != nil {
					row.MaxMessageCount = store.ScreeningPending
					row.Error = err.Error()
					errCount.Add(1)
				} else {
					row.MaxMessageCount = count
					if count > 0 {
						okCount.Add(1)
					} else {
						denyCount.Add(1)
					}
				}
				if err := db.UpsertScreening(row); err != nil {
					fmt.Fprintf(os.Stderr, "写入筛选结果失败: %v\n", err)
				}
				n := done.Add(1)
				if n%20 == 0 || int(n) == len(uids) {
					fmt.Printf("\r进度 %d/%d | 可私信 %d | 不可 %d | 错误 %d",
						n, len(uids), okCount.Load(), denyCount.Load(), errCount.Load())
				}
			}
		}(clients[w])
	}
	wg.Wait()
	fmt.Printf("\n筛选完成: 可私信 %d, 不可私信 %d, 错误 %d (耗时 %s)\n",
		okCount.Load(), denyCount.Load(), errCount.Load(), time.Since(start).Round(time.Second))
	if *label != "" {
		fmt.Printf("结果已存标签 %q, 可用 ttdm screening export --label %s --chatable 导出可私信目标\n", *label, *label)
	}
}

// ---------- template ----------

func cmdTemplate(db *store.DB, args []string) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "template 子命令: add | list | delete")
		os.Exit(1)
	}
	switch args[0] {
	case "add":
		fs := flag.NewFlagSet("template add", flag.ExitOnError)
		text := fs.String("text", "", "话术文本 (支持 {用户名} {链接} 变量)")
		tag := fs.String("tag", "", "标签")
		file := fs.String("file", "", "从文件批量导入 (每行一条)")
		fs.Parse(args[1:])
		var texts []string
		if *file != "" {
			b, err := os.ReadFile(*file)
			if err != nil {
				fmt.Fprintf(os.Stderr, "读取文件失败: %v\n", err)
				os.Exit(1)
			}
			for _, line := range strings.Split(string(b), "\n") {
				if line = strings.TrimSpace(line); line != "" {
					texts = append(texts, line)
				}
			}
		} else if *text != "" {
			texts = []string{*text}
		} else {
			fmt.Fprintln(os.Stderr, "需要 --text 或 --file")
			os.Exit(1)
		}
		for _, t := range texts {
			id, err := db.CreateTemplate(*tag, t)
			if err != nil {
				fmt.Fprintf(os.Stderr, "保存话术失败: %v\n", err)
				os.Exit(1)
			}
			fmt.Printf("话术已添加: id=%d %s\n", id, truncateStr(t, 60))
		}
	case "list":
		items, err := db.ListTemplates()
		if err != nil {
			fmt.Fprintf(os.Stderr, "查询失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("%-5s %-12s %s\n", "ID", "标签", "话术")
		for _, t := range items {
			fmt.Printf("%-5d %-12s %s\n", t.ID, t.Tag, truncateStr(t.Text, 80))
		}
	case "delete":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "用法: ttdm template delete <id>")
			os.Exit(1)
		}
		id, err := strconv.ParseInt(args[1], 10, 64)
		if err != nil {
			fmt.Fprintf(os.Stderr, "无效 id: %v\n", err)
			os.Exit(1)
		}
		if err := db.DeleteTemplate(id); err != nil {
			fmt.Fprintf(os.Stderr, "删除失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("话术 %d 已删除\n", id)
	default:
		fmt.Fprintln(os.Stderr, "template 子命令: add | list | delete")
		os.Exit(1)
	}
}
