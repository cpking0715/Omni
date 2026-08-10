package protocol

import (
	"net/url"
	"testing"

	"ttdm/internal/store"
)

func TestBuildWebQuery(t *testing.T) {
	devID := "7319826453671301423"
	q := BuildWebQuery(devID, `{"d":"`+devID+`"}`)
	v, err := url.ParseQuery(q)
	if err != nil {
		t.Fatalf("ParseQuery: %v", err)
	}
	checks := map[string]string{
		"device_platform": "web",
		"version_code":    "fws_1.0.0",
		"fpid":            "9",
		"aid":             "1459",
		"xsack":           "1",
		"xaack":           "1",
		"xsqos":           "0",
		"access_key":      AccessKey(devID),
		"ttwid":           `{"d":"` + devID + `"}`,
	}
	for k, want := range checks {
		if got := v.Get(k); got != want {
			t.Errorf("%s = %q, want %q", k, got, want)
		}
	}
}

func TestNewWebClientValidation(t *testing.T) {
	// no ttwid → error
	a := &store.Account{UID: 1, Cookies: []store.Cookie{{Name: "sessionid", Value: "x", Domain: ".tiktok.com"}}}
	if _, err := NewWebClient(a); err == nil {
		t.Error("expected error for missing ttwid")
	}
	// ttwid without 19-digit device id → error
	a2 := &store.Account{UID: 1, Cookies: []store.Cookie{{Name: "ttwid", Value: "short-token", Domain: ".tiktok.com"}}}
	if _, err := NewWebClient(a2); err == nil {
		t.Error("expected error for ttwid lacking device id")
	}
	// valid ttwid → client with sn starting at webFirstSN-1
	a3 := &store.Account{UID: 1, Cookies: []store.Cookie{
		{Name: "ttwid", Value: "tok-7319826453671301423-tok", Domain: ".tiktok.com"}}}
	c, err := NewWebClient(a3)
	if err != nil {
		t.Fatalf("NewWebClient: %v", err)
	}
	if c.deviceID != "7319826453671301423" {
		t.Errorf("deviceID = %q", c.deviceID)
	}
	if got := c.nextSN(); got != webFirstSN {
		t.Errorf("first sn = %d, want %d", got, webFirstSN)
	}
}

func TestWebFrameRoundTrip(t *testing.T) {
	frame := buildWebFrame(webFirstSN, 7300000000000000001, []string{"0:1:123:456"})
	f, err := parseWebFrame(frame)
	if err != nil {
		t.Fatalf("parseWebFrame: %v", err)
	}
	if f.SN != webFirstSN {
		t.Errorf("sn = %d", f.SN)
	}
	if f.Timestamp <= 0 {
		t.Errorf("timestamp = %d", f.Timestamp)
	}
	if f.Service != webService || f.Method != webMethod {
		t.Errorf("service/method = %d/%d", f.Service, f.Method)
	}
	// body: f1 device block carries uid strings
	bp := &parser{data: f.Body}
	device, ok, err := bp.findLen(1)
	if err != nil || !ok {
		t.Fatal("body lacks device block")
	}
	dp := &parser{data: device}
	if v, _, _ := dp.findVarint(1); v != 2 {
		t.Errorf("device f1 = %d", v)
	}
	uidStr, ok, _ := dp.findStr(2)
	if !ok || uidStr != "7300000000000000001" {
		t.Errorf("device f2 = %q", uidStr)
	}
	// body: f2 message block carries the conversation id
	blk, ok, err := bp.findLen(2)
	if err != nil || !ok {
		t.Fatal("body lacks message block")
	}
	mp := &parser{data: blk}
	if cid, ok, _ := mp.findStr(4); !ok || cid != "0:1:123:456" {
		t.Errorf("conv id = %q", cid)
	}
}

func TestParseWebFrameRejectsGarbage(t *testing.T) {
	if _, err := parseWebFrame(nil); err == nil {
		t.Error("expected error for empty frame")
	}
}
