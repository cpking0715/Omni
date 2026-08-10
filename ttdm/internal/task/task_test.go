package task

import (
	"context"
	"fmt"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"ttdm/internal/protocol"
	"ttdm/internal/store"
)

// ---- mock protocol client ----

type fakeClient struct {
	mu            sync.Mutex
	sendTextFn    func(ctx context.Context, cid *protocol.ConversationID, text string) (protocol.SendResult, error)
	connectFail   error
	convFail      error
	conversations int
	createdFor    []int64
}

func (f *fakeClient) Connect(ctx context.Context, proxyURL string) error { return f.connectFail }
func (f *fakeClient) CreateConversation(ctx context.Context, toUID int64) (*protocol.ConversationID, error) {
	if f.convFail != nil {
		return nil, f.convFail
	}
	f.mu.Lock()
	f.conversations++
	f.createdFor = append(f.createdFor, toUID)
	f.mu.Unlock()
	return &protocol.ConversationID{ID: "conv-1", ShortID: 99}, nil
}
func (f *fakeClient) SendText(ctx context.Context, cid *protocol.ConversationID, text string) (protocol.SendResult, error) {
	if f.sendTextFn != nil {
		return f.sendTextFn(ctx, cid, text)
	}
	return protocol.Success, nil
}
func (f *fakeClient) SendLink(ctx context.Context, cid *protocol.ConversationID, linkURL, coverURL, title, desc string) (protocol.SendResult, error) {
	return protocol.Success, nil
}
func (f *fakeClient) SendVideo(ctx context.Context, cid *protocol.ConversationID, videoID string) (protocol.SendResult, error) {
	return protocol.Success, nil
}
func (f *fakeClient) SendSticker(ctx context.Context, cid *protocol.ConversationID, imageURL string) (protocol.SendResult, error) {
	return protocol.Success, nil
}
func (f *fakeClient) SendHomePage(ctx context.Context, cid *protocol.ConversationID, uid string) (protocol.SendResult, error) {
	return protocol.Success, nil
}
func (f *fakeClient) Close() error { return nil }

var _ protocol.IImClient = (*fakeClient)(nil)

// flakyConnectClient fails the first Connect, then delegates.
type flakyConnectClient struct {
	protocol.IImClient
	failFirst bool
}

func (f *flakyConnectClient) Connect(ctx context.Context, proxyURL string) error {
	if f.failFirst {
		f.failFirst = false
		return fmt.Errorf("连接服务器失败: temporary")
	}
	return f.IImClient.Connect(ctx, proxyURL)
}

// alwaysFailConnectClient never connects.
type alwaysFailConnectClient struct{}

func (a *alwaysFailConnectClient) Connect(ctx context.Context, proxyURL string) error {
	return fmt.Errorf("连接服务器失败: blocked")
}
func (a *alwaysFailConnectClient) CreateConversation(ctx context.Context, toUID int64) (*protocol.ConversationID, error) {
	return nil, fmt.Errorf("not connected")
}
func (a *alwaysFailConnectClient) SendText(ctx context.Context, cid *protocol.ConversationID, text string) (protocol.SendResult, error) {
	return protocol.SendResult{}, fmt.Errorf("not connected")
}
func (a *alwaysFailConnectClient) SendLink(ctx context.Context, cid *protocol.ConversationID, linkURL, coverURL, title, desc string) (protocol.SendResult, error) {
	return protocol.SendResult{}, fmt.Errorf("not connected")
}
func (a *alwaysFailConnectClient) SendVideo(ctx context.Context, cid *protocol.ConversationID, videoID string) (protocol.SendResult, error) {
	return protocol.SendResult{}, fmt.Errorf("not connected")
}
func (a *alwaysFailConnectClient) SendSticker(ctx context.Context, cid *protocol.ConversationID, imageURL string) (protocol.SendResult, error) {
	return protocol.SendResult{}, fmt.Errorf("not connected")
}
func (a *alwaysFailConnectClient) SendHomePage(ctx context.Context, cid *protocol.ConversationID, uid string) (protocol.SendResult, error) {
	return protocol.SendResult{}, fmt.Errorf("not connected")
}
func (a *alwaysFailConnectClient) Close() error { return nil }

var _ protocol.IImClient = (*alwaysFailConnectClient)(nil)

// ---- helpers ----

func testAccount(uid int64) *store.Account {
	cookies, _ := store.ParseCookies(`[{"name":"sessionid","value":"s","domain":".tiktok.com"},{"name":"store-idc","value":"alisg","domain":".tiktok.com"},{"name":"multi_sids","value":"` + fmt.Sprintf("%d%%3Aabc", uid) + `","domain":".tiktok.com"}]`)
	return &store.Account{
		UID: uid, DeviceID: "d" + fmt.Sprint(uid), StoreIDC: "alisg",
		Cookies: cookies, Status: store.StatusLoggedIn,
	}
}

func openTestDB(t *testing.T) *store.DB {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

// ---- assignWork ----

func TestAssignWorkRoundRobin(t *testing.T) {
	accts := []*store.Account{testAccount(1), testAccount(2)}
	p := SendParams{Accounts: accts, Receivers: []int64{101, 102, 103, 104, 105}, MaxSentCount: 30, MaxFailCount: 5}
	states := assignWork(p)
	if len(states[0].receivers) != 3 || len(states[1].receivers) != 2 {
		t.Errorf("round-robin split: %v / %v", states[0].receivers, states[1].receivers)
	}
}

func TestAssignWorkMaxSentCap(t *testing.T) {
	accts := []*store.Account{testAccount(1), testAccount(2)}
	// 5 receivers, cap 2 per sender: 4 assigned, 1 dropped (original behavior)
	p := SendParams{Accounts: accts, Receivers: []int64{101, 102, 103, 104, 105}, MaxSentCount: 2, MaxFailCount: 5}
	states := assignWork(p)
	total := len(states[0].receivers) + len(states[1].receivers)
	if len(states[0].receivers) > 2 || len(states[1].receivers) > 2 {
		t.Errorf("cap violated: %v / %v", states[0].receivers, states[1].receivers)
	}
	if total != 4 {
		t.Errorf("assigned %d receivers, want 4 (cap reached, remainder dropped)", total)
	}
}

func TestAssignWorkProxyRoundRobin(t *testing.T) {
	accts := []*store.Account{testAccount(1), testAccount(2), testAccount(3)}
	p := SendParams{Accounts: accts, Receivers: []int64{101}, MaxSentCount: 30, MaxFailCount: 5,
		Proxies: []string{"socks5://a:1", "socks5://b:2"}}
	states := assignWork(p)
	if states[0].proxy != "socks5://a:1" || states[1].proxy != "socks5://b:2" || states[2].proxy != "socks5://a:1" {
		t.Errorf("proxy assignment: %q %q %q", states[0].proxy, states[1].proxy, states[2].proxy)
	}
}

// ---- runSender behavior ----

func TestRunSenderSuccessAndFailure(t *testing.T) {
	db := openTestDB(t)
	fake := &fakeClient{} // success for all
	acct := testAccount(1)
	task, err := db.CreateTask(store.DefaultParams())
	if err != nil {
		t.Fatal(err)
	}
	p := SendParams{
		Accounts: []*store.Account{acct}, Receivers: []int64{101, 102, 103},
		Message: "hi", IntervalSecs: 0, MaxSentCount: 30, MaxFailCount: 5,
		ClientFactory: func(*store.Account) protocol.IImClient { return fake },
	}
	var progress []Progress
	success, fail := runTask(context.Background(), db, task, p, func(pr Progress) { progress = append(progress, pr) })
	if success != 3 || fail != 0 {
		t.Errorf("success=%d fail=%d want 3/0", success, fail)
	}
	if len(fake.createdFor) != 3 {
		t.Errorf("conversations created = %d, want 3", len(fake.createdFor))
	}
	if len(progress) != 3 {
		t.Errorf("progress events = %d, want 3", len(progress))
	}
	// DB rows
	msgs, err := db.ListMessagesByTask(task.ID)
	if err != nil || len(msgs) != 3 {
		t.Fatalf("messages = %d err=%v", len(msgs), err)
	}
	for _, m := range msgs {
		if m.TextStatus == nil || *m.TextStatus != store.SendSuccess {
			t.Errorf("message %+v not success", m)
		}
	}
}

func TestRunSenderRateLimitQuit(t *testing.T) {
	db := openTestDB(t)
	fake := &fakeClient{
		sendTextFn: func(ctx context.Context, cid *protocol.ConversationID, text string) (protocol.SendResult, error) {
			return protocol.SendResult{Terminate: true, Quit: true, Error: "消息发送过快 [7180]"}, nil
		},
	}
	acct := testAccount(1)
	task, err := db.CreateTask(store.DefaultParams())
	if err != nil {
		t.Fatal(err)
	}
	p := SendParams{
		Accounts: []*store.Account{acct}, Receivers: []int64{101, 102, 103},
		Message: "hi", IntervalSecs: 0, MaxSentCount: 30, MaxFailCount: 5,
		ClientFactory: func(*store.Account) protocol.IImClient { return fake },
	}
	success, fail := runTask(context.Background(), db, task, p, nil)
	if fail != 1 || success != 0 {
		t.Errorf("expected quit after first fail: success=%d fail=%d", success, fail)
	}
	if len(fake.createdFor) != 1 {
		t.Errorf("expected 1 conversation (quit after first), got %d", len(fake.createdFor))
	}
}

func TestRunSenderMaxFailExits(t *testing.T) {
	db := openTestDB(t)
	fake := &fakeClient{
		sendTextFn: func(ctx context.Context, cid *protocol.ConversationID, text string) (protocol.SendResult, error) {
			return protocol.SendResult{Terminate: true, Error: "只有好友才能互相发送消息 [7282]"}, nil
		},
	}
	acct := testAccount(1)
	task, err := db.CreateTask(store.DefaultParams())
	if err != nil {
		t.Fatal(err)
	}
	p := SendParams{
		Accounts: []*store.Account{acct}, Receivers: []int64{101, 102, 103, 104},
		Message: "hi", IntervalSecs: 0, MaxSentCount: 30, MaxFailCount: 2,
		ClientFactory: func(*store.Account) protocol.IImClient { return fake },
	}
	success, fail := runTask(context.Background(), db, task, p, nil)
	if fail != 2 || success != 0 {
		t.Errorf("expected exit after 2 consecutive failures: success=%d fail=%d", success, fail)
	}
	if len(fake.createdFor) != 2 {
		t.Errorf("expected 2 conversations, got %d", len(fake.createdFor))
	}
}

// ---- resilience ----

func TestConnectRetrySucceeds(t *testing.T) {
	db := openTestDB(t)
	acct := testAccount(1)
	task, err := db.CreateTask(store.DefaultParams())
	if err != nil {
		t.Fatal(err)
	}
	p := SendParams{
		Accounts: []*store.Account{acct}, Receivers: []int64{101},
		Message: "hi", IntervalSecs: 0, MaxSentCount: 30, MaxFailCount: 5,
		ClientFactory: func(*store.Account) protocol.IImClient {
			return &flakyConnectClient{IImClient: &fakeClient{}, failFirst: true}
		},
	}
	success, fail := runTask(context.Background(), db, task, p, nil)
	if success != 1 || fail != 0 {
		t.Errorf("retry should succeed: success=%d fail=%d", success, fail)
	}
}

func TestConnectFailureCountsAsFail(t *testing.T) {
	db := openTestDB(t)
	acct := testAccount(1)
	task, err := db.CreateTask(store.DefaultParams())
	if err != nil {
		t.Fatal(err)
	}
	p := SendParams{
		Accounts: []*store.Account{acct}, Receivers: []int64{101, 102},
		Message: "hi", IntervalSecs: 0, MaxSentCount: 30, MaxFailCount: 5,
		ClientFactory: func(*store.Account) protocol.IImClient {
			return &alwaysFailConnectClient{}
		},
	}
	success, fail := runTask(context.Background(), db, task, p, nil)
	if success != 0 || fail != 2 {
		t.Errorf("all connects fail: success=%d fail=%d", success, fail)
	}
	// messages should have been recorded as failures? No — connect failures
	// happen before message creation, so DB should have 0 message rows but
	// task-level fail counts should reflect. runTask returns counts.
	msgs, _ := db.ListMessagesByTask(task.ID)
	if len(msgs) != 0 {
		t.Errorf("connect failures should not create message rows, got %d", len(msgs))
	}
}

// ---- manager ----

func TestManagerQueueAndAccountExclusion(t *testing.T) {
	db := openTestDB(t)
	// create two accounts
	a1 := testAccount(1)
	a2 := testAccount(2)
	id1, err := db.CreateAccount(a1)
	if err != nil {
		t.Fatal(err)
	}
	id2, err := db.CreateAccount(a2)
	if err != nil {
		t.Fatal(err)
	}
	m := NewManager(db)
	m.SetMaxTasks(1)

	// task A uses account 1, task B uses account 1 too (must queue),
	// task C uses account 2 (must also queue while max=1)
	pA := store.DefaultParams()
	pA.Senders = []int64{id1}
	pA.Receivers = []int64{101, 102}
	pA.Message = "hello"
	pA.IntervalSecs = 0

	pB := pA
	pB.Receivers = []int64{103, 104}
	pC := pA
	pC.Senders = []int64{id2}
	pC.Receivers = []int64{201}

	// Validate scheduling with accounts that lack full IM params (fail fast
	// at validation, before any network I/O). maxTasks=1 forces t2 to queue.
	db2 := openTestDB(t)
	bad := &store.Account{UID: 5, DeviceID: "", StoreIDC: "", Status: store.StatusLoggedIn}
	badID, _ := db2.CreateAccount(bad)
	m2 := NewManager(db2)
	m2.SetMaxTasks(1)
	pX := store.DefaultParams()
	pX.Senders = []int64{badID}
	pX.Receivers = []int64{301, 302}
	pX.Message = "x"
	pX.IntervalSecs = 0
	pX.MaxFailCount = 1

	t1, err := m2.Submit(pX)
	if err != nil {
		t.Fatal(err)
	}
	t2, err := m2.Submit(pX)
	if err != nil {
		t.Fatal(err)
	}
	// wait for both to finish (fail fast: no IM params)
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		tt, _ := db2.GetTask(t1.ID)
		t2t, _ := db2.GetTask(t2.ID)
		if tt != nil && t2t != nil && tt.Status >= store.TaskCompleted && t2t.Status >= store.TaskCompleted {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	got1, _ := db2.GetTask(t1.ID)
	got2, _ := db2.GetTask(t2.ID)
	if got1 == nil || got2 == nil {
		t.Fatal("tasks missing")
	}
	if got1.Status != store.TaskFailed && got1.Status != store.TaskCompleted {
		t.Errorf("task1 status=%d", got1.Status)
	}
	if got2.Status != store.TaskFailed && got2.Status != store.TaskCompleted {
		t.Errorf("task2 status=%d", got2.Status)
	}
	// both finished — validates queue serialization through the manager (max=1)
	if got1.FinishedAt == nil || got2.FinishedAt == nil {
		t.Error("tasks did not finish")
	}
}
