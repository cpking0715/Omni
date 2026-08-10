package protocol

import (
	"context"
	"errors"
	"testing"

	"ttdm/internal/store"
)

// fakeChannel is a scriptable IImClient for channel-strategy tests.
type fakeChannel struct {
	connectErr  error
	createErr   error
	sendErr     error
	sendRes     SendResult
	connects    int
	creates     int
	sends       int
	connected   bool
}

func (f *fakeChannel) Connect(ctx context.Context, proxy string) error {
	f.connects++
	if f.connectErr != nil {
		return f.connectErr
	}
	f.connected = true
	return nil
}

func (f *fakeChannel) CreateConversation(ctx context.Context, toUID int64) (*ConversationID, error) {
	f.creates++
	if f.createErr != nil {
		return nil, f.createErr
	}
	return &ConversationID{ID: "fake", ShortID: toUID}, nil
}

func (f *fakeChannel) SendText(ctx context.Context, cid *ConversationID, text string) (SendResult, error) {
	f.sends++
	return f.sendRes, f.sendErr
}

func (f *fakeChannel) SendLink(ctx context.Context, cid *ConversationID, a, b, c, d string) (SendResult, error) {
	return f.sendRes, f.sendErr
}

func (f *fakeChannel) SendVideo(ctx context.Context, cid *ConversationID, id string) (SendResult, error) {
	return f.sendRes, f.sendErr
}

func (f *fakeChannel) SendSticker(ctx context.Context, cid *ConversationID, u string) (SendResult, error) {
	return f.sendRes, f.sendErr
}

func (f *fakeChannel) SendHomePage(ctx context.Context, cid *ConversationID, uid string) (SendResult, error) {
	return f.sendRes, f.sendErr
}

func (f *fakeChannel) Close() error { return nil }

// newTestAuto builds an AutoClient with injected fakes (no real network).
func newTestAuto(primary, fallback *fakeChannel) *AutoClient {
	return &AutoClient{primary: primary, fallback: fallback}
}

func TestAutoStaysOnWebWhenHealthy(t *testing.T) {
	web := &fakeChannel{}
	browser := &fakeChannel{}
	c := newTestAuto(web, browser)
	ctx := context.Background()

	if err := c.Connect(ctx, ""); err != nil {
		t.Fatal(err)
	}
	if c.ConnectedVia() != "web" {
		t.Errorf("connectedVia = %q", c.ConnectedVia())
	}
	if _, err := c.CreateConversation(ctx, 1); err != nil {
		t.Fatal(err)
	}
	if _, err := c.SendText(ctx, &ConversationID{}, "hi"); err != nil {
		t.Fatal(err)
	}
	if browser.connects+browser.creates+browser.sends != 0 {
		t.Error("browser fallback must not be touched while web works")
	}
}

func TestAutoDowngradesOnNotImplemented(t *testing.T) {
	web := &fakeChannel{createErr: ErrWebSendNotImplemented, sendErr: ErrWebSendNotImplemented}
	browser := &fakeChannel{}
	c := newTestAuto(web, browser)
	ctx := context.Background()

	if err := c.Connect(ctx, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := c.CreateConversation(ctx, 1); err != nil {
		t.Fatalf("expected fallback to handle create: %v", err)
	}
	if _, err := c.SendText(ctx, &ConversationID{}, "hi"); err != nil {
		t.Fatalf("expected fallback to handle send: %v", err)
	}
	if c.ConnectedVia() != "browser" {
		t.Errorf("connectedVia = %q, want browser", c.ConnectedVia())
	}
	if browser.creates != 1 || browser.sends != 1 {
		t.Errorf("browser create/send = %d/%d", browser.creates, browser.sends)
	}
}

func TestAutoDowngradesOnConnectFailure(t *testing.T) {
	web := &fakeChannel{connectErr: errors.New("http 403")}
	browser := &fakeChannel{}
	c := newTestAuto(web, browser)
	ctx := context.Background()

	if err := c.Connect(ctx, ""); err != nil {
		t.Fatal(err)
	}
	if c.ConnectedVia() != "browser" {
		t.Errorf("connectedVia = %q, want browser", c.ConnectedVia())
	}
	if browser.connects != 1 {
		t.Errorf("browser connects = %d", browser.connects)
	}
}

func TestAutoPropagatesWebErrors(t *testing.T) {
	wantErr := errors.New("rate limited")
	web := &fakeChannel{sendErr: wantErr}
	browser := &fakeChannel{}
	c := newTestAuto(web, browser)
	ctx := context.Background()
	if err := c.Connect(ctx, ""); err != nil {
		t.Fatal(err)
	}
	_, err := c.SendText(ctx, &ConversationID{}, "hi")
	if !errors.Is(err, wantErr) {
		t.Errorf("err = %v, want %v", err, wantErr)
	}
	if browser.sends != 0 {
		t.Error("non-downgrade errors must not switch channels")
	}
}

func TestNewChannelClientUnknownChannel(t *testing.T) {
	a := &store.Account{UID: 1}
	if _, err := NewChannelClient(a, "satellite", ""); err == nil {
		t.Error("expected error for unknown channel")
	}
	// android channel always constructible
	if _, err := NewChannelClient(a, ChannelAndroid, ""); err != nil {
		t.Errorf("android channel: %v", err)
	}
}
