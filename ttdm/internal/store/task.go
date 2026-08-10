package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

// Task status values.
const (
	TaskQueued    = 0
	TaskRunning   = 1
	TaskCompleted = 2
	TaskCanceled  = 3
	TaskFailed    = 4
)

// Task is a DM sending job.
type Task struct {
	ID           int64
	Status       int
	TotalCount   int
	SuccessCount int
	FailCount    int
	ParamsJSON   string
	Error        string
	StartedAt    *int64
	FinishedAt   *int64
	CreatedAt    int64
}

// Params is the JSON-serializable task configuration snapshot.
// Mirrors ImProtocolSendParameters from the original client.
type Params struct {
	Senders            []int64  `json:"senders"`   // account ids
	Receivers          []int64  `json:"receivers"` // TikTok uids
	Message            string   `json:"message,omitempty"`
	LinkURL            string   `json:"link_url,omitempty"`
	LinkTitle          string   `json:"link_title,omitempty"`
	LinkDesc           string   `json:"link_desc,omitempty"`
	LinkCoverURL       string   `json:"link_cover_url,omitempty"`
	VideoURL           string   `json:"video_url,omitempty"`
	PictureURL         string   `json:"picture_url,omitempty"`
	HomePageUID        string   `json:"home_page_uid,omitempty"`
	IntervalSecs       int      `json:"interval_secs"`                  // delay between sends
	IntervalJitterSecs int      `json:"interval_jitter_secs,omitempty"` // 间隔随机抖动上限(秒)
	MaxSentCount       int      `json:"max_sent_count"`                 // per-sender receiver cap
	MaxFailCount       int      `json:"max_fail_count"`                 // consecutive failures before abort
	MaxDailyCount      int      `json:"max_daily_count,omitempty"`      // 单账号每日发送上限 (0=不限)
	MaxConcurrency     int      `json:"max_concurrency"`                // parallel senders
	UseWebProtocol     bool     `json:"use_web_protocol"`               // channel 2 vs channel 1 (legacy)
	Proxies            []string `json:"proxies,omitempty"`

	// 重构新增 (PRD 4.10 澄清): 话术模板与渲染选项
	Templates       []int64  `json:"templates,omitempty"`        // 话术库 ID 列表, 随机选
	RandomEmoji     bool     `json:"random_emoji,omitempty"`     // 追加 3 个随机表情
	CurrentDateTime bool     `json:"current_datetime,omitempty"` // 追加当前时间
	LinkURLs        []string `json:"link_urls,omitempty"`        // 链接多 URL 随机池

	// 通道选择: "" | "android" | "web" | "browser" | "auto"
	// auto = 优先 Web 通道, 失败/未逆向完成时降级模拟通道 (DESIGN 5.3)
	Channel string `json:"channel,omitempty"`
}

// DefaultParams returns parameters with the original client's defaults.
func DefaultParams() Params {
	return Params{
		IntervalSecs:       30, // 风控下限 (原客户端 3s 过快, 2026-08 实测 7180 限频)
		IntervalJitterSecs: 10,
		MaxSentCount:       30,
		MaxFailCount:       5,
		MaxConcurrency:     4,
	}
}

func (p *Params) JSON() string {
	b, _ := json.Marshal(p)
	return string(b)
}

// ParseParams decodes stored params JSON.
func ParseParams(jsonStr string) (Params, error) {
	var p Params
	if err := json.Unmarshal([]byte(jsonStr), &p); err != nil {
		return p, fmt.Errorf("parse params: %w", err)
	}
	return p, nil
}

// CreateTask inserts a queued task.
func (db *DB) CreateTask(p Params) (*Task, error) {
	now := time.Now().UnixMilli()
	t := &Task{
		Status:     TaskQueued,
		TotalCount: len(p.Receivers),
		ParamsJSON: p.JSON(),
		CreatedAt:  now,
	}
	res, err := db.Exec(`INSERT INTO tasks (status, total_count, success_count, fail_count, params_json, error, created_at)
		VALUES (?, ?, 0, 0, ?, NULL, ?)`,
		t.Status, t.TotalCount, t.ParamsJSON, t.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("insert task: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	t.ID = id
	return t, nil
}

func scanTask(row interface{ Scan(...any) error }) (*Task, error) {
	var t Task
	var errMsg sql.NullString
	var startedAt, finishedAt sql.NullInt64
	if err := row.Scan(&t.ID, &t.Status, &t.TotalCount, &t.SuccessCount, &t.FailCount,
		&t.ParamsJSON, &errMsg, &startedAt, &finishedAt, &t.CreatedAt); err != nil {
		return nil, err
	}
	t.Error = errMsg.String
	if startedAt.Valid {
		v := startedAt.Int64
		t.StartedAt = &v
	}
	if finishedAt.Valid {
		v := finishedAt.Int64
		t.FinishedAt = &v
	}
	return &t, nil
}

const taskCols = `id, status, total_count, success_count, fail_count, params_json, error, started_at, finished_at, created_at`

// GetTask fetches a task by id.
func (db *DB) GetTask(id int64) (*Task, error) {
	row := db.QueryRow(`SELECT `+taskCols+` FROM tasks WHERE id = ?`, id)
	t, err := scanTask(row)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return t, err
}

// ListTasks returns tasks ordered newest-first.
func (db *DB) ListTasks(limit int) ([]*Task, error) {
	if limit <= 0 {
		limit = 50
	}
	rows, err := db.Query(`SELECT `+taskCols+` FROM tasks ORDER BY id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Task
	for rows.Next() {
		t, err := scanTask(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// SetTaskStatus updates status and counters.
func (db *DB) SetTaskStatus(id int64, status, success, fail int, errMsg string, finished bool) error {
	var finishedAt any
	if finished {
		finishedAt = time.Now().UnixMilli()
	}
	_, err := db.Exec(`UPDATE tasks SET status=?, success_count=?, fail_count=?, error=?, finished_at=COALESCE(?, finished_at) WHERE id=?`,
		status, success, fail, errMsg, finishedAt, id)
	return err
}

// RecoverInterruptedTasks marks queued/running tasks as failed — used at
// startup to clean up after a crash (the process owns task execution).
func (db *DB) RecoverInterruptedTasks() (int, error) {
	res, err := db.Exec(`UPDATE tasks SET status=?, error=?, finished_at=? WHERE status IN (?, ?)`,
		TaskFailed, "进程中断", time.Now().UnixMilli(), TaskQueued, TaskRunning)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}
