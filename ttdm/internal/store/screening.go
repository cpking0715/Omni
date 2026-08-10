package store

// Screening result values for MaxMessageCount.
const (
	ScreeningPending = -1 // 未检测
	ScreeningDenied  = 0  // 不可私信
)

// Screening is one 强私筛选 result row.
type Screening struct {
	ID              int64
	Label           string
	SenderUID       int64
	TargetUID       string
	MaxMessageCount int // -1 pending / 0 denied / 1 / 3
	Error           string
	CreatedAt       int64
	UpdatedAt       int64
}

// UpsertScreening inserts or updates a screening row keyed by
// (label, sender_uid, target_uid).
func (db *DB) UpsertScreening(s *Screening) error {
	now := nowMillis()
	_, err := db.Exec(`INSERT INTO screenings
		(label, sender_uid, target_uid, max_message_count, error, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(label, sender_uid, target_uid) DO UPDATE SET
			max_message_count = excluded.max_message_count,
			error = excluded.error,
			updated_at = excluded.updated_at`,
		s.Label, s.SenderUID, s.TargetUID, s.MaxMessageCount, s.Error, now, now)
	return err
}

// ListScreenings returns rows for a label (all labels when empty),
// most recently updated first.
func (db *DB) ListScreenings(label string) ([]*Screening, error) {
	r, err := db.Query(`SELECT id, label, sender_uid, target_uid, max_message_count, error, created_at, updated_at
		FROM screenings WHERE ? = '' OR label = ? ORDER BY updated_at DESC`, label, label)
	if err != nil {
		return nil, err
	}
	defer r.Close()
	var out []*Screening
	for r.Next() {
		var s Screening
		if err := r.Scan(&s.ID, &s.Label, &s.SenderUID, &s.TargetUID,
			&s.MaxMessageCount, &s.Error, &s.CreatedAt, &s.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, &s)
	}
	return out, r.Err()
}

// CountScreeningsByCount returns the number of chatable targets (count>0)
// and total rows for a label (all labels when empty).
func (db *DB) CountScreenings(label string) (chatable, total int, err error) {
	row := db.QueryRow(`SELECT
		COALESCE(SUM(CASE WHEN max_message_count > 0 THEN 1 ELSE 0 END), 0),
		COUNT(*)
		FROM screenings WHERE ? = '' OR label = ?`, label, label)
	err = row.Scan(&chatable, &total)
	return chatable, total, err
}

// ChatableTargetUIDs returns target uids with MaxMessageCount>0 for a label,
// ready to feed a DM task as receivers.
func (db *DB) ChatableTargetUIDs(label string) ([]string, error) {
	r, err := db.Query(`SELECT target_uid FROM screenings
		WHERE max_message_count > 0 AND (? = '' OR label = ?)
		ORDER BY updated_at DESC`, label, label)
	if err != nil {
		return nil, err
	}
	defer r.Close()
	var out []string
	for r.Next() {
		var uid string
		if err := r.Scan(&uid); err != nil {
			return nil, err
		}
		out = append(out, uid)
	}
	return out, r.Err()
}
