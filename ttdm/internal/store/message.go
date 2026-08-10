package store

import (
	"database/sql"
	"fmt"
	"time"
)

// Protocol types (mirror TikTokImProtocolType).
const (
	ProtocolAndroid = 1
	ProtocolWeb     = 2
	ProtocolBrowser = 3 // 模拟通道 (CDP 页面操作)
)

// Send statuses stored as *int: nil = not requested, 0 = failed, 1 = success.
const (
	SendFailed  = 0
	SendSuccess = 1
)

// Message is one send attempt to one receiver from one sender.
type Message struct {
	ID             int64
	TaskID         int64
	SenderUID      int64
	ReceiverUID    int64
	ProtocolType   int
	TextStatus     *int
	TextError      *string
	LinkStatus     *int
	LinkError      *string
	VideoStatus    *int
	VideoError     *string
	ImageStatus    *int
	ImageError     *string
	HomepageStatus *int
	HomepageError  *string
	SentAt         int64
	CreatedAt      int64
}

// NewMessage builds a Message with sent timestamps set.
func NewMessage(taskID, senderUID, receiverUID int64, protocolType int) *Message {
	now := time.Now().UnixMilli()
	return &Message{
		TaskID:       taskID,
		SenderUID:    senderUID,
		ReceiverUID:  receiverUID,
		ProtocolType: protocolType,
		SentAt:       now,
		CreatedAt:    now,
	}
}

// CreateMessage inserts one message record.
func (db *DB) CreateMessage(m *Message) (int64, error) {
	res, err := db.Exec(`INSERT INTO messages
		(task_id, sender_uid, receiver_uid, protocol_type,
		 text_status, text_error, link_status, link_error,
		 video_status, video_error, image_status, image_error,
		 homepage_status, homepage_error, sent_at, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		m.TaskID, m.SenderUID, m.ReceiverUID, m.ProtocolType,
		m.TextStatus, m.TextError, m.LinkStatus, m.LinkError,
		m.VideoStatus, m.VideoError, m.ImageStatus, m.ImageError,
		m.HomepageStatus, m.HomepageError, m.SentAt, m.CreatedAt)
	if err != nil {
		return 0, fmt.Errorf("insert message: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}
	m.ID = id
	return id, nil
}

func scanMessage(row interface{ Scan(...any) error }) (*Message, error) {
	var m Message
	var textErr, linkErr, videoErr, imgErr, hpErr sql.NullString
	if err := row.Scan(&m.ID, &m.TaskID, &m.SenderUID, &m.ReceiverUID, &m.ProtocolType,
		&m.TextStatus, &textErr, &m.LinkStatus, &linkErr,
		&m.VideoStatus, &videoErr, &m.ImageStatus, &imgErr,
		&m.HomepageStatus, &hpErr, &m.SentAt, &m.CreatedAt); err != nil {
		return nil, err
	}
	strPtr := func(s sql.NullString) *string {
		if s.Valid {
			v := s.String
			return &v
		}
		return nil
	}
	m.TextError, m.LinkError, m.VideoError, m.ImageError, m.HomepageError =
		strPtr(textErr), strPtr(linkErr), strPtr(videoErr), strPtr(imgErr), strPtr(hpErr)
	return &m, nil
}

const messageCols = `id, task_id, sender_uid, receiver_uid, protocol_type,
	text_status, text_error, link_status, link_error,
	video_status, video_error, image_status, image_error,
	homepage_status, homepage_error, sent_at, created_at`

// CountSentToday returns how many messages a sender has sent since local
// midnight (风控: 每日发送上限判定)。
func (db *DB) CountSentToday(senderUID int64) (int, error) {
	start := time.Now()
	midnight := time.Date(start.Year(), start.Month(), start.Day(), 0, 0, 0, 0, start.Location())
	var n int
	err := db.QueryRow(`SELECT COUNT(*) FROM messages
		WHERE sender_uid = ? AND sent_at >= ?`,
		senderUID, midnight.UnixMilli()).Scan(&n)
	return n, err
}

// ListMessagesByTask returns all messages of a task.
func (db *DB) ListMessagesByTask(taskID int64) ([]*Message, error) {
	rows, err := db.Query(`SELECT `+messageCols+` FROM messages WHERE task_id = ? ORDER BY id`, taskID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Message
	for rows.Next() {
		m, err := scanMessage(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// CountMessagesByTask returns (total, success, fail) for a task, where
// success = any card status == 1, fail = any card status == 0.
func (db *DB) CountMessagesByTask(taskID int64) (total, success, fail int, err error) {
	msgs, err := db.ListMessagesByTask(taskID)
	if err != nil {
		return 0, 0, 0, err
	}
	for _, m := range msgs {
		total++
		ok := false
		for _, s := range []*int{m.TextStatus, m.LinkStatus, m.VideoStatus, m.ImageStatus, m.HomepageStatus} {
			if s != nil && *s == SendSuccess {
				ok = true
				break
			}
		}
		if ok {
			success++
		} else {
			fail++
		}
	}
	return total, success, fail, nil
}

// FailureCount is one entry of the per-task failure-reason distribution
// (发送遥测: 失败原因分布).
type FailureCount struct {
	Reason string
	Count  int
}

// FailureBreakdown aggregates the first error of every failed message in
// a task, most frequent first.
func (db *DB) FailureBreakdown(taskID int64) ([]FailureCount, error) {
	msgs, err := db.ListMessagesByTask(taskID)
	if err != nil {
		return nil, err
	}
	counts := map[string]int{}
	for _, m := range msgs {
		ok := false
		for _, s := range []*int{m.TextStatus, m.LinkStatus, m.VideoStatus, m.ImageStatus, m.HomepageStatus} {
			if s != nil && *s == SendSuccess {
				ok = true
				break
			}
		}
		if ok {
			continue
		}
		reason := ""
		for _, e := range []*string{m.TextError, m.LinkError, m.VideoError, m.ImageError, m.HomepageError} {
			if e != nil && *e != "" {
				reason = *e
				break
			}
		}
		if reason == "" {
			reason = "未知错误"
		}
		counts[reason]++
	}
	out := make([]FailureCount, 0, len(counts))
	for r, c := range counts {
		out = append(out, FailureCount{Reason: r, Count: c})
	}
	// sort by count desc (stable insertion, no sort import needed)
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].Count > out[j-1].Count; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out, nil
}
