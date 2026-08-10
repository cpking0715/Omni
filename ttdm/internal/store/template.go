package store

// ChatTemplate is one 话术 entry (mirrors ChatTemplate { Id, Tag, Text }).
type ChatTemplate struct {
	ID        int64
	Tag       string
	Text      string
	CreatedAt int64
	UpdatedAt int64
}

// CreateTemplate inserts a new 话术 and returns its id.
func (db *DB) CreateTemplate(tag, text string) (int64, error) {
	now := nowMillis()
	res, err := db.Exec(`INSERT INTO chat_templates (tag, text, created_at, updated_at)
		VALUES (?, ?, ?, ?)`, tag, text, now, now)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// ListTemplates returns all 话术 ordered by id.
func (db *DB) ListTemplates() ([]*ChatTemplate, error) {
	rows, err := db.Query(`SELECT id, tag, text, created_at, updated_at FROM chat_templates ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*ChatTemplate
	for rows.Next() {
		var t ChatTemplate
		if err := rows.Scan(&t.ID, &t.Tag, &t.Text, &t.CreatedAt, &t.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, &t)
	}
	return out, rows.Err()
}

// GetTemplates returns the 话术 with the given ids (missing ids skipped).
func (db *DB) GetTemplates(ids []int64) ([]*ChatTemplate, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	var out []*ChatTemplate
	for _, id := range ids {
		var t ChatTemplate
		err := db.QueryRow(`SELECT id, tag, text, created_at, updated_at FROM chat_templates WHERE id = ?`, id).
			Scan(&t.ID, &t.Tag, &t.Text, &t.CreatedAt, &t.UpdatedAt)
		if err != nil {
			continue
		}
		out = append(out, &t)
	}
	return out, nil
}

// DeleteTemplate removes a 话术 by id.
func (db *DB) DeleteTemplate(id int64) error {
	_, err := db.Exec(`DELETE FROM chat_templates WHERE id = ?`, id)
	return err
}
