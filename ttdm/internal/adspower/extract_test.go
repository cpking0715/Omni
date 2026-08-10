package adspower

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

// fakeCDP simulates CDP responses for ExtractTikTok.
type fakeCDP struct {
	cookies []Cookie
	storage map[string]string
}

func (f *fakeCDP) GetAllCookies(ctx context.Context) ([]Cookie, error) { return f.cookies, nil }
func (f *fakeCDP) Eval(ctx context.Context, expr string) (string, error) {
	// expression like: localStorage.getItem('KEY')
	start := strings.Index(expr, "'")
	end := strings.LastIndex(expr, "'")
	if start < 0 || end <= start {
		return "null", nil
	}
	key := expr[start+1 : end]
	if v, ok := f.storage[key]; ok {
		b, _ := json.Marshal(v)
		return string(b), nil
	}
	return "null", nil
}

func sampleCookies() []Cookie {
	return []Cookie{
		{Name: "sessionid", Value: "abc123", Domain: ".tiktok.com"},
		{Name: "store-idc", Value: "alisg", Domain: ".tiktok.com"},
		{Name: "multi_sids", Value: "7319826453671301423%3Axyz%3A1725000000", Domain: ".tiktok.com"},
		{Name: "ttwid", Value: "ttwid-v", Domain: ".tiktok.com"},
		{Name: "other-site", Value: "noise", Domain: ".example.com"},
	}
}

func TestExtractTikTok(t *testing.T) {
	cdp := &fakeCDP{
		cookies: sampleCookies(),
		storage: map[string]string{"tiktok_device_id": "7319826453671301423"},
	}
	data, err := ExtractTikTok(context.Background(), cdp)
	if err != nil {
		t.Fatalf("ExtractTikTok: %v", err)
	}
	if data.UID != 7319826453671301423 {
		t.Errorf("uid = %d", data.UID)
	}
	if data.StoreIDC != "alisg" {
		t.Errorf("storeIDC = %q", data.StoreIDC)
	}
	if data.DeviceID != "7319826453671301423" {
		t.Errorf("deviceID = %q", data.DeviceID)
	}
	// non-tiktok cookies filtered out
	for _, c := range data.Cookies {
		if c.Domain == ".example.com" {
			t.Error("non-tiktok cookie leaked through")
		}
	}
	if len(data.Cookies) != 4 {
		t.Errorf("tiktok cookies = %d, want 4", len(data.Cookies))
	}
}

func TestExtractTikTokNoTikTokCookies(t *testing.T) {
	cdp := &fakeCDP{cookies: []Cookie{{Name: "x", Value: "y", Domain: ".example.com"}}}
	_, err := ExtractTikTok(context.Background(), cdp)
	if err == nil {
		t.Fatal("expected error for missing tiktok cookies")
	}
}

func TestExtractTikTokDeviceIDFallback(t *testing.T) {
	// no localStorage device id → fall back to cdid2 cookie
	cdp := &fakeCDP{
		cookies: append(sampleCookies(), Cookie{Name: "cdid2", Value: "fallback-device", Domain: ".tiktok.com"}),
		storage: map[string]string{},
	}
	data, err := ExtractTikTok(context.Background(), cdp)
	if err != nil {
		t.Fatal(err)
	}
	if data.DeviceID != "fallback-device" {
		t.Errorf("deviceID fallback = %q", data.DeviceID)
	}
}
