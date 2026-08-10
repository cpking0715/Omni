package store

import (
	"strings"
	"testing"
)

// format 1: full JSON with cookies map + extensions
func TestParseImportFullJSON(t *testing.T) {
	text := `[
		{"uid":"7111111111111111111","cookies":{"sessionid":"sid-a","store-idc":"alisg","multi_sids":"7111111111111111111%3Aabc"},"uage":"CustomUA/1.0","platFromUrl":"https://www.tiktok.com?device_id=7319826453671301423"},
		{"uid":7222222222222222222,"cookie":{"sessionid":"sid-b","multi_sids":"7222222222222222222:def"}}
	]`
	items, err := ParseImport(text)
	if err != nil {
		t.Fatalf("ParseImport: %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("got %d items, want 2", len(items))
	}
	a := items[0]
	if a.UID != 7111111111111111111 {
		t.Errorf("uid = %d", a.UID)
	}
	if a.UserAgent != "CustomUA/1.0" {
		t.Errorf("uage = %q", a.UserAgent)
	}
	if a.DeviceID != "7319826453671301423" {
		t.Errorf("device_id from platFromUrl = %q", a.DeviceID)
	}
	if len(a.Cookies) != 3 {
		t.Errorf("cookies = %d, want 3", len(a.Cookies))
	}
	// numeric uid form
	if items[1].UID != 7222222222222222222 {
		t.Errorf("numeric uid = %d", items[1].UID)
	}
}

// format 2: cookie JSON array (single account)
func TestParseImportCookieArray(t *testing.T) {
	text := `[{"name":"sessionid","value":"sid-x","domain":".tiktok.com"},{"name":"multi_sids","value":"7300000000000000001%3Azz","domain":".tiktok.com"}]`
	items, err := ParseImport(text)
	if err != nil {
		t.Fatalf("ParseImport: %v", err)
	}
	if len(items) != 1 || len(items[0].Cookies) != 2 {
		t.Fatalf("unexpected items: %+v", items)
	}
	a, err := items[0].ToAccount("7319826453671301423", "")
	if err != nil {
		t.Fatalf("ToAccount: %v", err)
	}
	if a.UID != 7300000000000000001 {
		t.Errorf("uid = %d", a.UID)
	}
}

// format 3: cookie string lines
func TestParseImportCookieString(t *testing.T) {
	text := "sessionid=sid-1; multi_sids=7300000000000000002%3Aaa; store-idc=useast5\n" +
		"abc | Cookies: sessionid=sid-2; multi_sids=7300000000000000003%3Abb"
	items, err := ParseImport(text)
	if err != nil {
		t.Fatalf("ParseImport: %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("got %d items, want 2", len(items))
	}
	a1, err := items[0].ToAccount("7319826453671301423", "")
	if err != nil {
		t.Fatal(err)
	}
	if a1.StoreIDC != "useast5" {
		t.Errorf("store_idc = %q", a1.StoreIDC)
	}
	if items[1].Cookies[0].Name != "sessionid" {
		t.Errorf("Cookies: prefix not stripped: %+v", items[1].Cookies)
	}
}

// format 4: ---- segments username----password----[2FA]----[email]----[email-pwd]----cookie
func TestParseImportSegments(t *testing.T) {
	cookie := "sessionid=sid-s; multi_sids=7300000000000000004%3Acc"
	cases := []struct {
		line          string
		wantUser      string
		wantPass      string
		want2FA       string
		wantEmail     string
		wantEmailPass string
	}{
		{
			line:     "user1----pass1----" + cookie,
			wantUser: "user1", wantPass: "pass1",
		},
		{
			line:     "user2----pass2----ABCDEFGHIJKLMNOP----" + cookie,
			wantUser: "user2", wantPass: "pass2", want2FA: "ABCDEFGHIJKLMNOP",
		},
		{
			line:     "user3----pass3----e@x.com----emailpass----" + cookie,
			wantUser: "user3", wantPass: "pass3", wantEmail: "e@x.com", wantEmailPass: "emailpass",
		},
		{
			line:     "user4----pass4----ABCDEFGHIJKLMNOP----e@x.com----emailpass----" + cookie,
			wantUser: "user4", wantPass: "pass4", want2FA: "ABCDEFGHIJKLMNOP", wantEmail: "e@x.com", wantEmailPass: "emailpass",
		},
	}
	for _, tc := range cases {
		items, err := ParseImport(tc.line)
		if err != nil {
			t.Fatalf("%q: %v", tc.line, err)
		}
		if len(items) != 1 {
			t.Fatalf("%q: got %d items", tc.line, len(items))
		}
		got := items[0]
		if got.Username != tc.wantUser || got.Password != tc.wantPass ||
			got.TwoFactorCode != tc.want2FA || got.Email != tc.wantEmail ||
			got.EmailPassword != tc.wantEmailPass {
			t.Errorf("%q: got user=%q pass=%q 2fa=%q email=%q emailpass=%q",
				tc.line, got.Username, got.Password, got.TwoFactorCode, got.Email, got.EmailPassword)
		}
		if len(got.Cookies) == 0 {
			t.Errorf("%q: no cookies parsed", tc.line)
		}
	}
}

func TestParseImportErrors(t *testing.T) {
	if _, err := ParseImport(""); err == nil {
		t.Error("expected error for empty input")
	}
	if _, err := ParseImport("[{invalid json"); err == nil {
		t.Error("expected error for broken JSON array")
	}
}

func TestTTWidDeviceID(t *testing.T) {
	// JSON layout with "d" field (URL-encoded cookie value)
	jsonTTWid := "%7B%22d%22%3A%227319826453671301423%22%7D" // {"d":"7319826453671301423"}
	cookies := []Cookie{{Name: "ttwid", Value: jsonTTWid, Domain: ".tiktok.com"}}
	if id := TTWidDeviceID(cookies); id != "7319826453671301423" {
		t.Errorf("TTWidDeviceID(json) = %q", id)
	}
	// bare 19-digit run inside a token
	cookies2 := []Cookie{{Name: "ttwid", Value: "prefix-7319826453671301423-suffix", Domain: ".tiktok.com"}}
	if id := TTWidDeviceID(cookies2); id != "7319826453671301423" {
		t.Errorf("TTWidDeviceID(bare) = %q", id)
	}
	// missing ttwid
	if id := TTWidDeviceID(nil); id != "" {
		t.Errorf("TTWidDeviceID(nil) = %q", id)
	}
}

func TestToAccountDeviceIDFallback(t *testing.T) {
	// device id derived from ttwid when neither flag nor extension supplies one
	cookies := []Cookie{
		{Name: "sessionid", Value: "sid", Domain: ".tiktok.com"},
		{Name: "multi_sids", Value: "7300000000000000005%3Add", Domain: ".tiktok.com"},
		{Name: "ttwid", Value: "tok-7319826453671301999-tok", Domain: ".tiktok.com"},
	}
	r := &ImportResult{Cookies: cookies}
	a, err := r.ToAccount("", "")
	if err != nil {
		t.Fatalf("ToAccount: %v", err)
	}
	if a.DeviceID != "7319826453671301999" {
		t.Errorf("device id = %q, want ttwid-derived", a.DeviceID)
	}
	// no ttwid + no device id → error mentioning device_id
	r2 := &ImportResult{Cookies: cookies[:2]}
	if _, err := r2.ToAccount("", ""); err == nil || !strings.Contains(err.Error(), "device_id") {
		t.Errorf("expected device_id error, got %v", err)
	}
}
