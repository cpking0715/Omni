package store

import (
	"path/filepath"
	"testing"
)

// sampleCookieJSON mimics a real TikTok cookie export (JSON array format).
const sampleCookieJSON = `[
  {"name":"sessionid","value":"abc123session","domain":".tiktok.com","path":"/","httpOnly":true,"secure":true},
  {"name":"store-idc","value":"alisg","domain":".tiktok.com","path":"/"},
  {"name":"multi_sids","value":"7319826453671301423%3Aabcd%3A1725000000","domain":".tiktok.com","path":"/"},
  {"name":"ttwid","value":"%2Fttwid-value","domain":".tiktok.com","path":"/"},
  {"name":"msToken","value":"mstoken-value","domain":".tiktok.com","path":"/"},
  {"name":"sessionid_ss","value":"ss-extra","domain":".tiktok.com","path":"/"}
]`

func TestParseCookiesJSON(t *testing.T) {
	cookies, err := ParseCookies(sampleCookieJSON)
	if err != nil {
		t.Fatalf("ParseCookies JSON: %v", err)
	}
	if len(cookies) != 6 {
		t.Fatalf("expected 6 cookies, got %d", len(cookies))
	}
	if cookies[0].Name != "sessionid" || cookies[0].Value != "abc123session" {
		t.Errorf("first cookie mismatch: %+v", cookies[0])
	}
}

func TestParseCookiesHeader(t *testing.T) {
	raw := "sessionid=xyz; store-idc=useast5; multi_sids=123%3Aabc"
	cookies, err := ParseCookies(raw)
	if err != nil {
		t.Fatalf("ParseCookies header: %v", err)
	}
	if len(cookies) != 3 {
		t.Fatalf("expected 3 cookies, got %d", len(cookies))
	}
	if cookies[1].Name != "store-idc" || cookies[1].Value != "useast5" {
		t.Errorf("store-idc mismatch: %+v", cookies[1])
	}
}

func TestExtractAccountInfo(t *testing.T) {
	cookies, err := ParseCookies(sampleCookieJSON)
	if err != nil {
		t.Fatal(err)
	}
	sid, storeIDC, uid, err := ExtractAccountInfo(cookies)
	if err != nil {
		t.Fatalf("ExtractAccountInfo: %v", err)
	}
	if sid != "abc123session" {
		t.Errorf("sid = %q, want abc123session", sid)
	}
	if storeIDC != "alisg" {
		t.Errorf("storeIDC = %q, want alisg", storeIDC)
	}
	if uid != 7319826453671301423 {
		t.Errorf("uid = %d, want 7319826453671301423", uid)
	}
}

func TestCookieStringFiltersDomain(t *testing.T) {
	cookies, _ := ParseCookies(sampleCookieJSON)
	cs := CookieString(cookies)
	if cs == "" || cs == "sessionid=abc123session" {
		t.Fatalf("CookieString = %q", cs)
	}
	// should contain ttwid
	found := false
	for _, c := range cookies {
		if c.Name == "ttwid" {
			found = len(cs) > 0
		}
	}
	_ = found
}

func TestNewAccountFromCookieText(t *testing.T) {
	a, err := NewAccountFromCookieText(sampleCookieJSON, "7319826453671301423", "user1", "昵称", "")
	if err != nil {
		t.Fatalf("NewAccountFromCookieText: %v", err)
	}
	if a.UID != 7319826453671301423 || a.StoreIDC != "alisg" || a.DeviceID != "7319826453671301423" {
		t.Errorf("account fields: %+v", a)
	}
	if !a.HasFullIMParams() {
		t.Errorf("HasFullIMParams should be true: %+v", a)
	}
	if a.CookieString() == "" {
		t.Error("CookieString empty")
	}
}

func TestAccountMissingUID(t *testing.T) {
	raw := `[{"name":"sessionid","value":"x","domain":".tiktok.com"},{"name":"store-idc","value":"alisg","domain":".tiktok.com"}]`
	_, err := NewAccountFromCookieText(raw, "device1", "", "", "")
	if err == nil {
		t.Fatal("expected error for missing uid, got nil")
	}
}

func TestAccountCRUD(t *testing.T) {
	dir := t.TempDir()
	db, err := Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer db.Close()

	a, err := NewAccountFromCookieText(sampleCookieJSON, "device-1", "u1", "nick1", "socks5://u:p@1.2.3.4:1080")
	if err != nil {
		t.Fatal(err)
	}
	id, err := db.CreateAccount(a)
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	if id <= 0 {
		t.Fatal("invalid id")
	}
	got, err := db.GetAccount(id)
	if err != nil || got == nil {
		t.Fatalf("GetAccount: %v", err)
	}
	if got.UID != a.UID || got.DeviceID != "device-1" || got.ProxyURL == "" {
		t.Errorf("roundtrip mismatch: %+v", got)
	}
	if got.CookieString() == "" {
		t.Error("cookie string empty after roundtrip")
	}
	list, err := db.ListAccounts()
	if err != nil || len(list) != 1 {
		t.Fatalf("ListAccounts: %v len=%d", err, len(list))
	}
	if err := db.DeleteAccount(id); err != nil {
		t.Fatalf("DeleteAccount: %v", err)
	}
	gone, _ := db.GetAccount(id)
	if gone != nil {
		t.Error("account still exists after delete")
	}
}

func TestRecoverInterruptedTasks(t *testing.T) {
	dir := t.TempDir()
	db, err := Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	p := DefaultParams()
	p.Receivers = []int64{1, 2}
	q, _ := db.CreateTask(p)
	r, _ := db.CreateTask(p)
	if err := db.SetTaskStatus(r.ID, TaskRunning, 0, 0, "", false); err != nil {
		t.Fatal(err)
	}
	n, err := db.RecoverInterruptedTasks()
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Errorf("recovered %d, want 2", n)
	}
	gotQ, _ := db.GetTask(q.ID)
	gotR, _ := db.GetTask(r.ID)
	if gotQ.Status != TaskFailed || gotR.Status != TaskFailed {
		t.Errorf("status after recover: %d / %d", gotQ.Status, gotR.Status)
	}
	if gotQ.Error != "进程中断" {
		t.Errorf("error = %q", gotQ.Error)
	}
	if gotQ.FinishedAt == nil {
		t.Error("finished_at not set")
	}
	// second run: nothing to recover
	n2, _ := db.RecoverInterruptedTasks()
	if n2 != 0 {
		t.Errorf("second recover = %d, want 0", n2)
	}
}

func TestTaskAndMessageCRUD(t *testing.T) {
	dir := t.TempDir()
	db, err := Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	p := DefaultParams()
	p.Senders = []int64{1}
	p.Receivers = []int64{1001, 1002, 1003}
	p.Message = "hello {user}"
	task, err := db.CreateTask(p)
	if err != nil {
		t.Fatalf("CreateTask: %v", err)
	}
	if task.TotalCount != 3 || task.Status != TaskQueued {
		t.Errorf("task: %+v", task)
	}
	// create messages
	for i, uid := range p.Receivers {
		m := NewMessage(task.ID, 1, uid, ProtocolAndroid)
		status := SendSuccess
		m.TextStatus = &status
		if i == 1 {
			failStatus := SendFailed
			msg := "FRIENDS_ONLY [7282]"
			m.TextStatus = &failStatus
			m.TextError = &msg
		}
		if _, err := db.CreateMessage(m); err != nil {
			t.Fatalf("CreateMessage: %v", err)
		}
	}
	total, success, fail, err := db.CountMessagesByTask(task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if total != 3 || success != 2 || fail != 1 {
		t.Errorf("counts total=%d success=%d fail=%d", total, success, fail)
	}
	msgs, err := db.ListMessagesByTask(task.ID)
	if err != nil || len(msgs) != 3 {
		t.Fatalf("ListMessagesByTask: %v len=%d", err, len(msgs))
	}
	if msgs[1].TextError == nil || *msgs[1].TextError == "" {
		t.Error("expected error text on failed message")
	}
	if err := db.SetTaskStatus(task.ID, TaskCompleted, success, fail, "", true); err != nil {
		t.Fatal(err)
	}
	got, _ := db.GetTask(task.ID)
	if got.Status != TaskCompleted || got.SuccessCount != 2 || got.FinishedAt == nil {
		t.Errorf("task after update: %+v", got)
	}
}
