package protocol

import (
	"testing"

	"ttdm/internal/store"
)

func TestMapBrowserWarning(t *testing.T) {
	cases := []struct {
		text      string
		wantQuit  bool
		wantOK    bool // expect Success
		wantSub   string
	}{
		{"You're sending messages too fast", true, false, "发送过快"},
		{"消息发送过快", true, false, "发送过快"},
		{"You can only send 3 messages", false, true, ""},
		{"最多发送3条", false, true, ""},
		{"Due to the receiver's settings, you can't send messages", false, false, "对方的设置"},
	}
	for _, c := range cases {
		r := mapBrowserWarning(c.text)
		if c.wantOK {
			if r.Error != "" || r.Terminate {
				t.Errorf("%q: expected success, got %+v", c.text, r)
			}
			continue
		}
		if r.Quit != c.wantQuit {
			t.Errorf("%q: quit = %v, want %v", c.text, r.Quit, c.wantQuit)
		}
		if c.wantSub != "" && !contains(r.Error, c.wantSub) {
			t.Errorf("%q: error = %q, want substring %q", c.text, r.Error, c.wantSub)
		}
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || indexOfSub(s, sub))
}

func indexOfSub(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

func TestMustJSONStrings(t *testing.T) {
	got := mustJSONStrings([]string{`div[data-e2e="x"]`, `[data-e2e=y]`})
	want := `["div[data-e2e=\"x\"]","[data-e2e=y]"]`
	if got != want {
		t.Errorf("got %s, want %s", got, want)
	}
}

func TestNewBrowserClientValidation(t *testing.T) {
	// no ads profile → error
	a := &store.Account{UID: 1}
	if _, err := NewBrowserClient(a, "secret"); err == nil {
		t.Error("expected error for missing ads profile")
	}
	// profile without api key → error
	a2 := &store.Account{UID: 1, AdsProfileID: "k1fan6kh"}
	if _, err := NewBrowserClient(a2, ""); err == nil {
		t.Error("expected error for missing API key even with profile")
	}
	// both present → ok
	if _, err := NewBrowserClient(a2, "secret"); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	// local:<port> direct mode → ok without api key
	a3 := &store.Account{UID: 1, AdsProfileID: LocalBrowserPrefix + "9222"}
	if _, err := NewBrowserClient(a3, ""); err != nil {
		t.Errorf("unexpected error for local direct mode: %v", err)
	}
	// local: without port → error
	a4 := &store.Account{UID: 1, AdsProfileID: LocalBrowserPrefix}
	if _, err := NewBrowserClient(a4, ""); err == nil {
		t.Error("expected error for empty local port")
	}
}

func TestLocalDebugPort(t *testing.T) {
	if port, ok := localDebugPort("local:9222"); !ok || port != "9222" {
		t.Errorf("local:9222 → got %q,%v", port, ok)
	}
	if _, ok := localDebugPort("k1flkhdn"); ok {
		t.Error("ads profile id must not be treated as local")
	}
	if _, ok := localDebugPort("local:"); ok {
		t.Error("empty port must not be accepted")
	}
}
