package task

import (
	"context"
	"fmt"
	"sync"
	"time"

	"ttdm/internal/store"
)

// Manager schedules DM tasks: FIFO queue, per-account mutual exclusion
// (one task per sender UID at a time) and a global concurrency cap.
type Manager struct {
	db *store.DB

	mu         sync.Mutex
	maxTasks   int
	running    map[int64]context.CancelFunc
	busyUIDs   map[int64]int
	queue      []*store.Task
	onProgress func(Progress)
	adsAPIKey  string
}

// NewManager creates a manager with the default global concurrency (4).
func NewManager(db *store.DB) *Manager {
	return &Manager{
		db:       db,
		maxTasks: 4,
		running:  make(map[int64]context.CancelFunc),
		busyUIDs: make(map[int64]int),
	}
}

// SetOnProgress registers a callback invoked for each message result.
func (m *Manager) SetOnProgress(fn func(Progress)) { m.onProgress = fn }

// SetAdsAPIKey provides the AdsPower Local API key needed by the
// browser/auto channels.
func (m *Manager) SetAdsAPIKey(key string) { m.adsAPIKey = key }

// SetMaxTasks sets the global concurrent-task limit.
func (m *Manager) SetMaxTasks(n int) {
	if n <= 0 {
		n = 1
	}
	m.mu.Lock()
	m.maxTasks = n
	m.mu.Unlock()
}

// Submit validates and enqueues a task, starting it if possible.
func (m *Manager) Submit(p store.Params) (*store.Task, error) {
	if len(p.Senders) == 0 {
		return nil, fmt.Errorf("至少选择一个发送账号")
	}
	if len(p.Receivers) == 0 {
		return nil, fmt.Errorf("至少一个接收目标")
	}
	if p.Message == "" && p.LinkURL == "" && p.VideoURL == "" && p.PictureURL == "" && p.HomePageUID == "" &&
		len(p.Templates) == 0 && len(p.LinkURLs) == 0 {
		return nil, fmt.Errorf("未配置任何发送内容 (文本/话术/链接/视频/图片/主页卡)")
	}
	if p.IntervalSecs <= 0 {
		p.IntervalSecs = 3
	}
	if p.MaxSentCount <= 0 {
		p.MaxSentCount = 30
	}
	if p.MaxFailCount <= 0 {
		p.MaxFailCount = 5
	}
	if p.MaxConcurrency <= 0 {
		p.MaxConcurrency = 4
	}

	t, err := m.db.CreateTask(p)
	if err != nil {
		return nil, err
	}
	m.mu.Lock()
	m.queue = append(m.queue, t)
	m.mu.Unlock()
	m.dispatch()
	return t, nil
}

// Stop cancels a running task or marks a queued task canceled.
func (m *Manager) Stop(taskID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if cancel, ok := m.running[taskID]; ok {
		cancel()
		return nil
	}
	for i, t := range m.queue {
		if t.ID == taskID {
			m.queue = append(m.queue[:i], m.queue[i+1:]...)
			return m.db.SetTaskStatus(taskID, store.TaskCanceled, 0, 0, "用户取消", true)
		}
	}
	t, err := m.db.GetTask(taskID)
	if err != nil {
		return err
	}
	if t == nil {
		return fmt.Errorf("任务 %d 不存在", taskID)
	}
	if t.Status == store.TaskQueued || t.Status == store.TaskRunning {
		if cancel, ok := m.running[taskID]; ok {
			cancel()
		}
	}
	return nil
}

// dispatch starts as many queued tasks as the constraints allow.
func (m *Manager) dispatch() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for {
		started := false
		for i, t := range m.queue {
			p, err := store.ParseParams(t.ParamsJSON)
			if err != nil {
				continue
			}
			if m.conflictsLocked(p) {
				continue
			}
			m.queue = append(m.queue[:i], m.queue[i+1:]...)
			m.startLocked(t, p)
			started = true
			break
		}
		if !started {
			return
		}
	}
}

// conflictsLocked reports whether the task's sender accounts are busy or the
// global cap is reached.
func (m *Manager) conflictsLocked(p store.Params) bool {
	if len(m.running) >= m.maxTasks {
		return true
	}
	for _, uid := range p.Senders {
		if m.busyUIDs[uid] > 0 {
			return true
		}
	}
	return false
}

// startLocked launches a task goroutine. Caller holds m.mu.
func (m *Manager) startLocked(t *store.Task, p store.Params) {
	ctx, cancel := context.WithCancel(context.Background())
	m.running[t.ID] = cancel
	for _, uid := range p.Senders {
		m.busyUIDs[uid]++
	}
	go m.execute(ctx, t, p)
}

// execute runs the task to completion and releases its slot.
func (m *Manager) execute(ctx context.Context, t *store.Task, p store.Params) {
	now := time.Now().UnixMilli()
	t.StartedAt = &now
	_ = m.db.SetTaskStatus(t.ID, store.TaskRunning, 0, 0, "", false)

	var accts []*store.Account
	loadErr := error(nil)
	for _, id := range p.Senders {
		a, err := m.db.GetAccount(id)
		if err != nil {
			loadErr = err
			break
		}
		if a == nil {
			loadErr = fmt.Errorf("账号 %d 不存在", id)
			break
		}
		if err := validateAccountForChannel(a, p.Channel); err != nil {
			loadErr = err
			break
		}
		accts = append(accts, a)
	}
	if loadErr != nil {
		finishTime := time.Now().UnixMilli()
		t.FinishedAt = &finishTime
		_ = m.db.SetTaskStatus(t.ID, store.TaskFailed, 0, 0, loadErr.Error(), true)
		m.release(t, p)
		return
	}

	sp := SendParams{
		Accounts:     accts,
		Receivers:    p.Receivers,
		Proxies:      p.Proxies,
		Message:      p.Message,
		LinkURL:      p.LinkURL,
		LinkTitle:    p.LinkTitle,
		LinkDesc:     p.LinkDesc,
		LinkCover:    p.LinkCoverURL,
		VideoURL:     p.VideoURL,
		PictureURL:   p.PictureURL,
		HomePageUID:  p.HomePageUID,
		IntervalSecs: p.IntervalSecs,
		MaxSentCount: p.MaxSentCount,
		MaxFailCount: p.MaxFailCount,
		MaxConcurrency: p.MaxConcurrency,
		Channel:      p.Channel,
		AdsAPIKey:    m.adsAPIKey,
		ProtocolType: protocolTypeForChannel(p.Channel),
	}

	// 话术渲染器 (PRD 4.10 新增特性)
	if len(p.Templates) > 0 {
		tpls, err := m.db.GetTemplates(p.Templates)
		if err != nil {
			loadErr = err
		} else if len(tpls) == 0 {
			loadErr = fmt.Errorf("话术 ID %v 均不存在", p.Templates)
		} else {
			sp.Renderer = NewRenderer(tpls, p.LinkURLs, p.RandomEmoji, p.CurrentDateTime)
		}
		if loadErr != nil {
			finishTime := time.Now().UnixMilli()
			t.FinishedAt = &finishTime
			_ = m.db.SetTaskStatus(t.ID, store.TaskFailed, 0, 0, loadErr.Error(), true)
			m.release(t, p)
			return
		}
	}
	if sp.Message == "" && sp.Renderer == nil && sp.LinkURL == "" && len(p.LinkURLs) == 0 &&
		sp.VideoURL == "" && sp.PictureURL == "" && sp.HomePageUID == "" {
		finishTime := time.Now().UnixMilli()
		t.FinishedAt = &finishTime
		_ = m.db.SetTaskStatus(t.ID, store.TaskFailed, 0, 0, "消息内容不能为空 (未选话术且无其他卡片)", true)
		m.release(t, p)
		return
	}

	success, fail := runTask(ctx, m.db, t, sp, m.onProgress)

	status := store.TaskCompleted
	errMsg := ""
	if ctx.Err() != nil {
		status = store.TaskCanceled
		errMsg = "用户取消"
	} else if success == 0 && fail > 0 {
		status = store.TaskFailed
		errMsg = "全部发送失败"
	}
	finishTime := time.Now().UnixMilli()
	t.FinishedAt = &finishTime
	_ = m.db.SetTaskStatus(t.ID, status, success, fail, errMsg, true)
	m.release(t, p)
}

// release frees the task's slots and dispatches the next queued task.
func (m *Manager) release(t *store.Task, p store.Params) {
	m.mu.Lock()
	delete(m.running, t.ID)
	for _, uid := range p.Senders {
		m.busyUIDs[uid]--
		if m.busyUIDs[uid] <= 0 {
			delete(m.busyUIDs, uid)
		}
	}
	m.mu.Unlock()
	m.dispatch()
}

// validateAccountForChannel checks the account carries everything the
// chosen channel needs.
func validateAccountForChannel(a *store.Account, channel string) error {
	switch channel {
	case "browser":
		if a.AdsProfileID == "" {
			return fmt.Errorf("账号 %d (%d) 未绑定 AdsPower 浏览器配置, 无法走模拟通道", a.ID, a.UID)
		}
	case "web":
		if a.UID <= 0 || len(a.Cookies) == 0 {
			return fmt.Errorf("账号 %d (%d) 缺少 uid/cookie, 无法走 Web 通道", a.ID, a.UID)
		}
	default: // android / auto / ""
		if !a.HasFullIMParams() && channel != "auto" {
			return fmt.Errorf("账号 %d (%d) 缺少 IM 参数 (uid/device_id/store_idc/cookie)", a.ID, a.UID)
		}
		if channel == "auto" && a.UID <= 0 {
			return fmt.Errorf("账号 %d 缺少 uid", a.ID)
		}
	}
	return nil
}

// protocolTypeForChannel maps the channel name to the stored protocol type.
func protocolTypeForChannel(channel string) int {
	switch channel {
	case "web":
		return store.ProtocolWeb
	case "browser":
		return store.ProtocolBrowser
	default: // android / auto (auto 的意图是 web, 降级时在消息层仍记 web)
		if channel == "auto" {
			return store.ProtocolWeb
		}
		return store.ProtocolAndroid
	}
}
