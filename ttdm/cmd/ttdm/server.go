package main

import (
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"strconv"

	"ttdm/internal/store"
	"ttdm/internal/task"
)

//go:embed web
var webFS embed.FS

// ---------- Web 控制台 (ttdm server) ----------

// cmdServer 启动内置 Web 控制台: 浏览器环境切换 (指纹/本地) + 任务创建/监控。
func cmdServer(db *store.DB, args []string) {
	fs := flag.NewFlagSet("server", flag.ExitOnError)
	addr := fs.String("addr", "127.0.0.1:8787", "监听地址 (默认 127.0.0.1:8787)")
	fs.Parse(args)

	mgr := task.NewManager(db)
	if key, err := db.GetSetting(store.SettingAdsAPIKey); err == nil && key != "" {
		mgr.SetAdsAPIKey(key)
	}

	srv := &http.Server{Addr: *addr, Handler: serverRoutes(db, mgr)}
	fmt.Printf("ttdm Web 控制台: http://%s\n", *addr)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("server 退出: %v", err)
	}
}

func serverRoutes(db *store.DB, mgr *task.Manager) http.Handler {
	mux := http.NewServeMux()

	sub, _ := fs.Sub(webFS, "web")
	mux.Handle("GET /", http.FileServer(http.FS(sub)))

	mux.HandleFunc("GET /api/settings", handleSettingsGet(db))
	mux.HandleFunc("POST /api/settings", handleSettingsPost(db, mgr))
	mux.HandleFunc("GET /api/accounts", handleAccounts(db))
	mux.HandleFunc("POST /api/tasks", handleTaskCreate(db, mgr))
	mux.HandleFunc("GET /api/tasks", handleTaskList(db))
	mux.HandleFunc("GET /api/tasks/{id}", handleTaskGet(db))
	mux.HandleFunc("POST /api/tasks/{id}/stop", handleTaskStop(db, mgr))
	return mux
}

// ---------- settings ----------

// settingsView 是前端可读写的设置 (browser_mode 默认 ads = 指纹浏览器)。
type settingsView struct {
	BrowserMode string `json:"browser_mode"` // "ads" | "local"
	LocalPort   string `json:"local_port"`
	AdsAPIKey   string `json:"ads_api_key"`
}

func handleSettingsGet(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		mode, _ := db.GetSetting(store.SettingBrowserMode)
		if mode == "" {
			mode = "ads"
		}
		port, _ := db.GetSetting(store.SettingLocalPort)
		key, _ := db.GetSetting(store.SettingAdsAPIKey)
		writeJSON(w, settingsView{BrowserMode: mode, LocalPort: port, AdsAPIKey: key})
	}
}

func handleSettingsPost(db *store.DB, mgr *task.Manager) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var v settingsView
		if err := json.NewDecoder(r.Body).Decode(&v); err != nil {
			writeErr(w, http.StatusBadRequest, "请求体解析失败: "+err.Error())
			return
		}
		if v.BrowserMode != "ads" && v.BrowserMode != "local" {
			writeErr(w, http.StatusBadRequest, "browser_mode 仅支持 ads|local")
			return
		}
		if v.BrowserMode == "local" && v.LocalPort == "" {
			writeErr(w, http.StatusBadRequest, "本地浏览器模式需要 local_port")
			return
		}
		_ = db.SetSetting(store.SettingBrowserMode, v.BrowserMode)
		_ = db.SetSetting(store.SettingLocalPort, v.LocalPort)
		_ = db.SetSetting(store.SettingAdsAPIKey, v.AdsAPIKey)
		mgr.SetAdsAPIKey(v.AdsAPIKey)
		writeJSON(w, map[string]string{"ok": "saved"})
	}
}

// ---------- accounts ----------

type accountView struct {
	ID           int64  `json:"id"`
	UID          int64  `json:"uid"`
	Nickname     string `json:"nickname"`
	Username     string `json:"username"`
	AdsProfileID string `json:"ads_profile_id"`
	ProxyURL     string `json:"proxy_url,omitempty"`
}

func handleAccounts(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		accts, err := db.ListAccounts()
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		out := make([]accountView, 0, len(accts))
		for _, a := range accts {
			out = append(out, accountView{
				ID: a.ID, UID: a.UID, Nickname: a.Nickname, Username: a.Username,
				AdsProfileID: a.AdsProfileID, ProxyURL: a.ProxyURL,
			})
		}
		writeJSON(w, out)
	}
}

// ---------- tasks ----------

type createTaskReq struct {
	Senders      []int64 `json:"senders"`
	Receivers    []int64 `json:"receivers"`
	Text         string  `json:"text"`
	Channel      string  `json:"channel"` // web|browser|auto|android
	IntervalSecs int     `json:"interval_secs"`
	JitterSecs   int     `json:"jitter_secs"`
	DailyMax     int     `json:"daily_max"`
	MaxSent      int     `json:"max_sent"`
	MaxFail      int     `json:"max_fail"`
	Concurrency  int     `json:"concurrency"`
}

func handleTaskCreate(db *store.DB, mgr *task.Manager) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req createTaskReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, "请求体解析失败: "+err.Error())
			return
		}
		switch req.Channel {
		case "", "web", "browser", "auto", "android":
		default:
			writeErr(w, http.StatusBadRequest, "channel 仅支持 web|browser|auto|android")
			return
		}
		p := store.DefaultParams()
		p.Senders = req.Senders
		p.Receivers = req.Receivers
		p.Message = req.Text
		p.Channel = req.Channel
		if req.IntervalSecs > 0 {
			p.IntervalSecs = req.IntervalSecs
		}
		if req.JitterSecs >= 0 {
			p.IntervalJitterSecs = req.JitterSecs
		}
		p.MaxDailyCount = req.DailyMax
		if req.MaxSent > 0 {
			p.MaxSentCount = req.MaxSent
		}
		if req.MaxFail > 0 {
			p.MaxFailCount = req.MaxFail
		}
		if req.Concurrency > 0 {
			p.MaxConcurrency = req.Concurrency
		}

		// 浏览器环境切换: local 模式下 browser/auto 任务运行时改用本地浏览器
		if mode, _ := db.GetSetting(store.SettingBrowserMode); mode == "local" &&
			(req.Channel == "browser" || req.Channel == "auto" || req.Channel == "") {
			if port, _ := db.GetSetting(store.SettingLocalPort); port != "" {
				p.AdsProfileOverride = "local:" + port
			}
		}

		t, err := mgr.Submit(p)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, taskViewFrom(t, p))
	}
}

var taskStatusNames = map[int]string{0: "排队", 1: "运行", 2: "完成", 3: "取消", 4: "失败"}

type taskView struct {
	ID           int64  `json:"id"`
	Status       int    `json:"status"`
	StatusText   string `json:"status_text"`
	TotalCount   int    `json:"total_count"`
	SuccessCount int    `json:"success_count"`
	FailCount    int    `json:"fail_count"`
	Error        string `json:"error"`
	Channel      string `json:"channel"`
	CreatedAt    int64  `json:"created_at"`
	FinishedAt   *int64 `json:"finished_at,omitempty"`
}

func taskViewFrom(t *store.Task, p store.Params) taskView {
	v := taskView{
		ID: t.ID, Status: t.Status, StatusText: taskStatusNames[t.Status],
		TotalCount: t.TotalCount, SuccessCount: t.SuccessCount, FailCount: t.FailCount,
		Error: t.Error, CreatedAt: t.CreatedAt, FinishedAt: t.FinishedAt,
	}
	if p.Channel != "" {
		v.Channel = p.Channel
	}
	return v
}

func handleTaskList(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		tasks, err := db.ListTasks(limit)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		out := make([]taskView, 0, len(tasks))
		for _, t := range tasks {
			p, err := store.ParseParams(t.ParamsJSON)
			if err != nil {
				continue
			}
			out = append(out, taskViewFrom(t, p))
		}
		writeJSON(w, out)
	}
}

func handleTaskGet(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "无效任务 id")
			return
		}
		t, err := db.GetTask(id)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		if t == nil {
			writeErr(w, http.StatusNotFound, "任务不存在")
			return
		}
		p, _ := store.ParseParams(t.ParamsJSON)
		writeJSON(w, taskViewFrom(t, p))
	}
}

func handleTaskStop(db *store.DB, mgr *task.Manager) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "无效任务 id")
			return
		}
		if err := mgr.Stop(id); err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, map[string]string{"ok": "stopped"})
	}
}

// ---------- helpers ----------

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}
