// Package store implements the SQLite persistence layer.
package store

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

// DB wraps *sql.DB with the schema applied.
type DB struct {
	*sql.DB
}

// Open opens (or creates) the SQLite database at path and applies the schema.
func Open(path string) (*DB, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	db.SetMaxOpenConns(1) // modernc sqlite driver is not safe for concurrent writes

	pragmas := []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA busy_timeout=10000",
		"PRAGMA foreign_keys=ON",
	}
	for _, p := range pragmas {
		if _, err := db.Exec(p); err != nil {
			db.Close()
			return nil, fmt.Errorf("apply %s: %w", p, err)
		}
	}
	if err := applySchema(db); err != nil {
		db.Close()
		return nil, err
	}
	return &DB{DB: db}, nil
}

func applySchema(db *sql.DB) error {
	schema := `
CREATE TABLE IF NOT EXISTS accounts (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    platform   TEXT    NOT NULL DEFAULT 'tiktok',
    username   TEXT,
    nickname   TEXT,
    uid        INTEGER NOT NULL UNIQUE,
    device_id  TEXT    NOT NULL,
    store_idc  TEXT,
    cookie_json TEXT   NOT NULL,
    proxy_url  TEXT,
    ads_profile_id TEXT NOT NULL DEFAULT '',
    status     INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS tasks (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    status        INTEGER NOT NULL DEFAULT 0,
    total_count   INTEGER NOT NULL DEFAULT 0,
    success_count INTEGER NOT NULL DEFAULT 0,
    fail_count    INTEGER NOT NULL DEFAULT 0,
    params_json   TEXT    NOT NULL DEFAULT '{}',
    error         TEXT,
    started_at    INTEGER,
    finished_at   INTEGER,
    created_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id         INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    sender_uid      INTEGER NOT NULL,
    receiver_uid    INTEGER NOT NULL,
    protocol_type   INTEGER NOT NULL DEFAULT 1,
    text_status     INTEGER,
    text_error      TEXT,
    link_status     INTEGER,
    link_error      TEXT,
    video_status    INTEGER,
    video_error     TEXT,
    image_status    INTEGER,
    image_error     TEXT,
    homepage_status INTEGER,
    homepage_error  TEXT,
    sent_at         INTEGER NOT NULL,
    created_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_messages_task ON messages(task_id);

CREATE TABLE IF NOT EXISTS screenings (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    label             TEXT    NOT NULL DEFAULT '',
    sender_uid        INTEGER NOT NULL,
    target_uid        TEXT    NOT NULL,
    max_message_count INTEGER NOT NULL DEFAULT -1,
    error             TEXT    NOT NULL DEFAULT '',
    created_at        INTEGER NOT NULL,
    updated_at        INTEGER NOT NULL,
    UNIQUE(label, sender_uid, target_uid)
);
CREATE INDEX IF NOT EXISTS idx_screenings_label ON screenings(label);

CREATE TABLE IF NOT EXISTS chat_templates (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    tag        TEXT NOT NULL DEFAULT '',
    text       TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS settings (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL DEFAULT '',
    updated_at INTEGER NOT NULL
);
`
	if _, err := db.Exec(schema); err != nil {
		return fmt.Errorf("apply schema: %w", err)
	}
	// migration for pre-existing databases created before ads_profile_id
	// existed (duplicate-column errors are ignored).
	_, _ = db.Exec(`ALTER TABLE accounts ADD COLUMN ads_profile_id TEXT NOT NULL DEFAULT ''`)
	return nil
}
