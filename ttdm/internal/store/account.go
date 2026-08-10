package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

// Account status values (mirror AutomaAccountStatus).
const (
	StatusNotLoggedIn = 0
	StatusLoggedIn    = 1
	StatusSuspended   = 2
)

// Account is a TikTok account with everything the IM protocol needs.
type Account struct {
	ID        int64
	Platform  string
	Username  string
	Nickname  string
	UID       int64  // TikTokId — required for IM
	DeviceID  string // required for IM
	StoreIDC  string // alisg / useast5 / ... — required for Android protocol
	Sid       string // sessionid value
	Cookies   []Cookie
	ProxyURL  string
	UserAgent string // optional; default okhttp UA is used when empty
	// AdsProfileID links the account to an AdsPower browser profile
	// (账号-环境 1:1); required by the simulated channel (BrowserClient).
	AdsProfileID string
	Status    int
	CreatedAt int64
	UpdatedAt int64
}

// HasFullIMParams reports whether the account has everything the Android
// WSS protocol requires: uid > 0, deviceId, cookie string and store-idc.
func (a *Account) HasFullIMParams() bool {
	return a.UID > 0 && a.DeviceID != "" && len(a.Cookies) > 0 && a.StoreIDC != ""
}

// CookieString returns the header-style cookie string.
func (a *Account) CookieString() string { return CookieString(a.Cookies) }

// NewAccountFromCookieText builds an Account from a raw cookie input
// (JSON array or header string) plus an explicit device ID.
// Optional trailing args: userAgent (last one wins).
func NewAccountFromCookieText(cookieText, deviceID, username, nickname, proxyURL string, opts ...string) (*Account, error) {
	cookies, err := ParseCookies(cookieText)
	if err != nil {
		return nil, err
	}
	_, storeIDC, uid, err := ExtractAccountInfo(cookies)
	if err != nil {
		return nil, err
	}
	if uid <= 0 {
		return nil, fmt.Errorf("cannot derive uid (need multi_sids cookie or uid in JSON)")
	}
	if deviceID == "" {
		return nil, fmt.Errorf("deviceId is required for the IM protocol")
	}
	now := time.Now().UnixMilli()
	a := &Account{
		Platform:  "tiktok",
		Username:  username,
		Nickname:  nickname,
		UID:       uid,
		DeviceID:  deviceID,
		StoreIDC:  storeIDC,
		Cookies:   cookies,
		ProxyURL:  proxyURL,
		Status:    StatusLoggedIn,
		CreatedAt: now,
		UpdatedAt: now,
	}
	if len(opts) > 0 {
		a.UserAgent = opts[len(opts)-1]
	}
	return a, nil
}

// CreateAccount inserts an account; uid is unique.
func (db *DB) CreateAccount(a *Account) (int64, error) {
	cookieJSON, err := MarshalCookies(a.Cookies)
	if err != nil {
		return 0, err
	}
	res, err := db.Exec(`INSERT INTO accounts
		(platform, username, nickname, uid, device_id, store_idc, cookie_json, proxy_url, ads_profile_id, status, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		a.Platform, a.Username, a.Nickname, a.UID, a.DeviceID, a.StoreIDC,
		cookieJSON, a.ProxyURL, a.AdsProfileID, a.Status, a.CreatedAt, a.UpdatedAt)
	if err != nil {
		return 0, fmt.Errorf("insert account: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}
	a.ID = id
	return id, nil
}

func scanAccount(row interface{ Scan(...any) error }) (*Account, error) {
	var a Account
	var cookieJSON string
	var username, nickname sql.NullString
	var proxyURL sql.NullString
	var storeIDC sql.NullString
	var adsProfileID sql.NullString
	if err := row.Scan(&a.ID, &a.Platform, &username, &nickname, &a.UID, &a.DeviceID,
		&storeIDC, &cookieJSON, &proxyURL, &adsProfileID, &a.Status, &a.CreatedAt, &a.UpdatedAt); err != nil {
		return nil, err
	}
	a.Username = username.String
	a.Nickname = nickname.String
	a.StoreIDC = storeIDC.String
	a.ProxyURL = proxyURL.String
	a.AdsProfileID = adsProfileID.String
	var cookies []Cookie
	if err := json.Unmarshal([]byte(cookieJSON), &cookies); err != nil {
		return nil, fmt.Errorf("unmarshal stored cookies: %w", err)
	}
	a.Cookies = cookies
	if s, _, _, err := ExtractAccountInfo(cookies); err == nil {
		a.Sid = s
	}
	return &a, nil
}

const accountCols = `id, platform, username, nickname, uid, device_id, store_idc, cookie_json, proxy_url, ads_profile_id, status, created_at, updated_at`

// GetAccount fetches an account by id.
func (db *DB) GetAccount(id int64) (*Account, error) {
	row := db.QueryRow(`SELECT `+accountCols+` FROM accounts WHERE id = ?`, id)
	a, err := scanAccount(row)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return a, err
}

// ListAccounts returns all accounts.
func (db *DB) ListAccounts() ([]*Account, error) {
	rows, err := db.Query(`SELECT ` + accountCols + ` FROM accounts ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Account
	for rows.Next() {
		a, err := scanAccount(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// UpdateAccount persists non-cookie fields.
func (db *DB) UpdateAccount(a *Account) error {
	a.UpdatedAt = time.Now().UnixMilli()
	_, err := db.Exec(`UPDATE accounts SET username=?, nickname=?, proxy_url=?, status=?, store_idc=?, ads_profile_id=?, updated_at=? WHERE id=?`,
		a.Username, a.Nickname, a.ProxyURL, a.Status, a.StoreIDC, a.AdsProfileID, a.UpdatedAt, a.ID)
	return err
}

// DeleteAccount removes an account by id.
func (db *DB) DeleteAccount(id int64) error {
	_, err := db.Exec(`DELETE FROM accounts WHERE id = ?`, id)
	return err
}
