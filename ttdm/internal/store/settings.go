package store

import (
	"database/sql"
	"time"
)

// Settings keys for the Web 控制台 (cmd/ttdm server).
const (
	// SettingBrowserMode 浏览器环境: "ads" (指纹浏览器, 默认) | "local" (本地浏览器)
	SettingBrowserMode = "browser_mode"
	// SettingLocalPort 本地浏览器 CDP 调试端口 (browser_mode=local 时使用)
	SettingLocalPort = "local_port"
	// SettingAdsAPIKey AdsPower 本地 API Key (browser_mode=ads 时使用)
	SettingAdsAPIKey = "ads_api_key"
)

// GetSetting returns a settings value ("" when absent).
func (db *DB) GetSetting(key string) (string, error) {
	var v string
	err := db.QueryRow(`SELECT value FROM settings WHERE key = ?`, key).Scan(&v)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return v, err
}

// SetSetting upserts a settings value.
func (db *DB) SetSetting(key, value string) error {
	_, err := db.Exec(`INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
		key, value, time.Now().UnixMilli())
	return err
}
