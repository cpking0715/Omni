// Package task implements the DM task execution engine.
package task

import (
	"context"
	"strconv"
	"sync"
	"time"

	"ttdm/internal/protocol"
	"ttdm/internal/store"
)

// Progress carries per-message results as a task runs.
type Progress struct {
	TaskID    int64
	SenderUID int64
	Receiver  int64
	Success   bool // any card succeeded
	Error     string
	Sent      int
	Fail      int
}

// SendParams is the resolved runtime config for one task.
type SendParams struct {
	Accounts       []*store.Account
	Receivers      []int64
	Proxies        []string
	Message        string
	LinkURL        string
	LinkTitle      string
	LinkDesc       string
	LinkCover      string
	VideoURL       string
	PictureURL     string
	HomePageUID    string
	IntervalSecs   int
	MaxSentCount   int
	MaxFailCount   int
	MaxConcurrency int

	// Channel selects the IM channel: android|web|browser|auto (DESIGN 5.3).
	Channel string
	// AdsAPIKey is required for the browser/auto channels.
	AdsAPIKey string
	// ProtocolType records which protocol the messages were sent over.
	ProtocolType int
	// Renderer renders 话术 per message (nil → use Message as-is).
	Renderer *Renderer

	// ClientFactory creates the protocol client for an account.
	// Defaults to channel-based selection; overridable in tests.
	ClientFactory func(*store.Account) protocol.IImClient
}

// senderState tracks one sender's counters (mirrors ImTaskState).
type senderState struct {
	acct   *store.Account
	proxy  string
	receivers []int64
	sent   int
	fail   int
	consec int
	quit   bool
}

// runTask executes a task synchronously, reporting progress per message.
// Returns (success, fail) counts.
func runTask(ctx context.Context, db *store.DB, t *store.Task, p SendParams, onProgress func(Progress)) (success, fail int) {
	states := assignWork(p)

	var (
		mu      sync.Mutex
		wg      sync.WaitGroup
	)
	inc := func(s, f int) {
		mu.Lock()
		success += s
		fail += f
		mu.Unlock()
	}

	// Cap parallel senders at MaxConcurrency (mirrors Parallel.ForEachAsync
	// with MaxDegreeOfParallelism = min(params, senders.Length)).
	limit := p.MaxConcurrency
	if limit <= 0 {
		limit = 1
	}
	if limit > len(states) {
		limit = len(states)
	}
	sem := make(chan struct{}, limit)
	for _, st := range states {
		if len(st.receivers) == 0 {
			continue
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(st *senderState) {
			defer wg.Done()
			defer func() { <-sem }()
			runSender(ctx, db, t, p, st, onProgress, inc)
		}(st)
	}
	wg.Wait()
	return success, fail
}

// assignWork distributes receivers round-robin across senders with a
// MaxSentCount cap, and proxies round-robin too (mirrors CreateTasks).
func assignWork(p SendParams) []*senderState {
	states := make([]*senderState, len(p.Accounts))
	for i, acct := range p.Accounts {
		st := &senderState{acct: acct}
		if len(p.Proxies) > 0 {
			st.proxy = p.Proxies[i%len(p.Proxies)]
		}
		states[i] = st
	}
	// Mirrors the original CreateTasks loop: advance round-robin each
	// iteration, only assign when the sender is below MaxSentCount, and
	// drop remaining receivers once every sender is at its cap.
	queue := append([]int64(nil), p.Receivers...)
	idx := 0
	for len(queue) > 0 {
		if len(states[idx].receivers) < p.MaxSentCount {
			states[idx].receivers = append(states[idx].receivers, queue[0])
			queue = queue[1:]
		}
		idx = (idx + 1) % len(states)
		if allAtCap(states, p.MaxSentCount) {
			break
		}
	}
	return states
}

func allAtCap(states []*senderState, max int) bool {
	for _, st := range states {
		if len(st.receivers) < max {
			return false
		}
	}
	return true
}

// runSender loops over one sender's assigned receivers
// (mirrors ImTaskState.ExecuteAsync: per-receiver connect, card sequence,
// failure threshold and interval delay).
func runSender(ctx context.Context, db *store.DB, t *store.Task, p SendParams, st *senderState, onProgress func(Progress), inc func(int, int)) {
	for i, receiver := range st.receivers {
		if ctx.Err() != nil {
			return
		}
		if st.quit {
			return
		}
		msg, connectErr, quit := sendToReceiver(ctx, st, receiver, p)
		if msg != nil {
			msg.TaskID = t.ID
			msg.SenderUID = st.acct.UID
			if _, err := db.CreateMessage(msg); err != nil {
				_ = err // persistence failure must not kill the loop
			}
			ok := anySuccess(msg)
			if ok {
				st.sent++
				st.consec = 0
			} else {
				st.fail++
				st.consec++
			}
			inc(boolToInt(ok), boolToInt(!ok))
			if onProgress != nil {
				onProgress(Progress{
					TaskID: t.ID, SenderUID: st.acct.UID, Receiver: receiver,
					Success: ok, Error: firstError(msg), Sent: st.sent, Fail: st.fail,
				})
			}
			if quit {
				st.quit = true
			}
		} else if connectErr != nil {
			st.fail++
			st.consec++
			inc(0, 1)
			if onProgress != nil {
				onProgress(Progress{
					TaskID: t.ID, SenderUID: st.acct.UID, Receiver: receiver,
					Success: false, Error: connectErr.Error(), Sent: st.sent, Fail: st.fail,
				})
			}
		}
		if st.consec >= p.MaxFailCount {
			return
		}
		if i < len(st.receivers)-1 && p.IntervalSecs > 0 {
			select {
			case <-time.After(time.Duration(p.IntervalSecs) * time.Second):
			case <-ctx.Done():
				return
			}
		}
	}
}

// sendToReceiver connects, creates a conversation and sends all configured
// cards to one receiver. Returns the message record, a fatal error and the
// quit flag (rate limit → abort the whole sender).
func sendToReceiver(ctx context.Context, st *senderState, receiver int64, p SendParams) (*store.Message, error, bool) {
	factory := p.ClientFactory
	if factory == nil {
		factory = func(a *store.Account) protocol.IImClient {
			cl, err := protocol.NewChannelClient(a, p.Channel, p.AdsAPIKey)
			if err != nil {
				return failedClient{err: err}
			}
			return cl
		}
	}
	client := factory(st.acct)
	// 连接失败重试 1 次（网络波动常见；TikTok 风控封 IP 时重试会立刻失败并计入失败数）
	if err := client.Connect(ctx, st.proxy); err != nil {
		if ctx.Err() == nil {
			select {
			case <-time.After(time.Second):
			case <-ctx.Done():
				return nil, ctx.Err(), false
			}
			if err2 := client.Connect(ctx, st.proxy); err2 != nil {
				return nil, err2, false
			}
		} else {
			return nil, err, false
		}
	}
	defer client.Close()

	cid, err := client.CreateConversation(ctx, receiver)
	if err != nil {
		return nil, err, false
	}

	protoType := p.ProtocolType
	if protoType == 0 {
		protoType = store.ProtocolAndroid
	}
	msg := store.NewMessage(0, st.acct.UID, receiver, protoType)
	terminate := false
	quit := false

	// 话术渲染: 每条消息随机选模板 + 变量插值 (PRD 4.10 新增)
	text := p.Message
	linkURL := p.LinkURL
	if p.Renderer != nil {
		if len(p.Renderer.templates) > 0 {
			text = p.Renderer.RenderText(strconv.FormatInt(receiver, 10))
		}
		if u := p.Renderer.PickLinkURL(); u != "" {
			linkURL = u
		}
	}

	if text != "" {
		terminate, quit = sendCard(client, cid, text, terminate, quit,
			func(cid *protocol.ConversationID, s string) (protocol.SendResult, error) {
				return client.SendText(ctx, cid, s)
			},
			func(r protocol.SendResult, e string) { // apply
				applyResult(&msg.TextStatus, &msg.TextError, r, e)
			})
	}
	if linkURL != "" && !terminate {
		terminate, quit = sendCard(client, cid, "", terminate, quit,
			func(*protocol.ConversationID, string) (protocol.SendResult, error) {
				return client.SendLink(ctx, cid, linkURL, p.LinkCover, p.LinkTitle, p.LinkDesc)
			},
			func(r protocol.SendResult, e string) {
				applyResult(&msg.LinkStatus, &msg.LinkError, r, e)
			})
	}
	if p.VideoURL != "" && !terminate {
		terminate, quit = sendCard(client, cid, "", terminate, quit,
			func(*protocol.ConversationID, string) (protocol.SendResult, error) {
				return client.SendVideo(ctx, cid, p.VideoURL)
			},
			func(r protocol.SendResult, e string) {
				applyResult(&msg.VideoStatus, &msg.VideoError, r, e)
			})
	}
	if p.PictureURL != "" && !terminate {
		terminate, quit = sendCard(client, cid, "", terminate, quit,
			func(*protocol.ConversationID, string) (protocol.SendResult, error) {
				return client.SendSticker(ctx, cid, p.PictureURL)
			},
			func(r protocol.SendResult, e string) {
				applyResult(&msg.ImageStatus, &msg.ImageError, r, e)
			})
	}
	if p.HomePageUID != "" && !terminate {
		_, quit = sendCard(client, cid, "", terminate, quit,
			func(*protocol.ConversationID, string) (protocol.SendResult, error) {
				return client.SendHomePage(ctx, cid, p.HomePageUID)
			},
			func(r protocol.SendResult, e string) {
				applyResult(&msg.HomepageStatus, &msg.HomepageError, r, e)
			})
	}
	return msg, nil, quit
}

// sendCard runs one send op, updating terminate/quit and applying the result.
func sendCard(client protocol.IImClient, cid *protocol.ConversationID, text string, terminate, quit bool,
	send func(*protocol.ConversationID, string) (protocol.SendResult, error),
	apply func(protocol.SendResult, string)) (bool, bool) {
	res, err := send(cid, text)
	if err != nil {
		apply(protocol.SendResult{}, err.Error())
		return true, quit
	}
	apply(res, "")
	return terminate || res.Terminate, quit || res.Quit
}

func applyResult(status **int, err **string, res protocol.SendResult, sendErr string) {
	if res.Error != "" {
		f := store.SendFailed
		*status = &f
		e := res.Error
		*err = &e
		return
	}
	if sendErr != "" {
		f := store.SendFailed
		*status = &f
		e := sendErr
		*err = &e
		return
	}
	s := store.SendSuccess
	*status = &s
}

func anySuccess(m *store.Message) bool {
	for _, s := range []*int{m.TextStatus, m.LinkStatus, m.VideoStatus, m.ImageStatus, m.HomepageStatus} {
		if s != nil && *s == store.SendSuccess {
			return true
		}
	}
	return false
}

func firstError(m *store.Message) string {
	for _, e := range []*string{m.TextError, m.LinkError, m.VideoError, m.ImageError, m.HomepageError} {
		if e != nil && *e != "" {
			return *e
		}
	}
	return ""
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// failedClient is returned by the default factory when client construction
// fails (e.g. missing ttwid / AdsPower profile): every call reports the
// construction error so the engine counts it as a normal send failure.
type failedClient struct{ err error }

func (f failedClient) Connect(context.Context, string) error { return f.err }
func (f failedClient) CreateConversation(context.Context, int64) (*protocol.ConversationID, error) {
	return nil, f.err
}
func (f failedClient) SendText(context.Context, *protocol.ConversationID, string) (protocol.SendResult, error) {
	return protocol.SendResult{}, f.err
}
func (f failedClient) SendLink(context.Context, *protocol.ConversationID, string, string, string, string) (protocol.SendResult, error) {
	return protocol.SendResult{}, f.err
}
func (f failedClient) SendVideo(context.Context, *protocol.ConversationID, string) (protocol.SendResult, error) {
	return protocol.SendResult{}, f.err
}
func (f failedClient) SendSticker(context.Context, *protocol.ConversationID, string) (protocol.SendResult, error) {
	return protocol.SendResult{}, f.err
}
func (f failedClient) SendHomePage(context.Context, *protocol.ConversationID, string) (protocol.SendResult, error) {
	return protocol.SendResult{}, f.err
}
func (f failedClient) Close() error { return nil }
