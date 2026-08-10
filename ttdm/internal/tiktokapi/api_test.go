package tiktokapi

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAPIDomain(t *testing.T) {
	cases := map[string]string{
		"useast5":  "api16-normal-useast5.tiktokv.us",
		"useast8":  "api16-normal-useast8.tiktokv.us",
		"useast2a": "api16-normal-c-useast2a.tiktokv.com",
		"alisg":    "api16-normal-c-alisg.tiktokv.com",
		"maliva":   "api16-normal-alisg.tiktokv.com",
		"":         "api22-normal-c-alisg.tiktokv.com",
		"unknown":  "api22-normal-c-alisg.tiktokv.com",
	}
	for idc, want := range cases {
		if got := APIDomain(idc); got != want {
			t.Errorf("APIDomain(%q) = %q, want %q", idc, got, want)
		}
	}
}

func TestPermissionFromCodes(t *testing.T) {
	cases := []struct {
		codes []string
		want  int
	}{
		{[]string{"chat_stranger_check"}, PermissionThree},
		{[]string{"chat_request_start"}, PermissionOne},
		{[]string{"chat_request_start", "chat_stranger_check"}, PermissionThree},
		{[]string{"some_other_code"}, PermissionNone},
		{nil, PermissionNone},
		{[]string{""}, PermissionNone},
	}
	for _, c := range cases {
		if got := permissionFromCodes(c.codes); got != c.want {
			t.Errorf("permissionFromCodes(%v) = %d, want %d", c.codes, got, c.want)
		}
	}
}

// startNoticeServer serves a canned /tiktok/v1/im/chat/notice/ response and
// points the client at it by rewriting APIDomain via a test hook: we build
// the client with a transport that redirects the API host to the test server.
func startNoticeServer(t *testing.T, body string, status int) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/tiktok/v1/im/chat/notice/") {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		if got := r.URL.Query().Get("conversation_id"); got != "0:1:222:111" {
			t.Errorf("conversation_id = %q, want 0:1:222:111", got)
		}
		if r.Header.Get("sdk-version") != "2" {
			t.Error("missing sdk-version header")
		}
		if r.Header.Get("Cookie") != "sessionid=x" {
			t.Errorf("cookie = %q", r.Header.Get("Cookie"))
		}
		w.WriteHeader(status)
		fmt.Fprint(w, body)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// newTestClient builds a Client whose API domain resolves to the test server.
func newTestClient(t *testing.T, srv *httptest.Server) *Client {
	t.Helper()
	c, err := NewClient("sessionid=x", "", "")
	if err != nil {
		t.Fatal(err)
	}
	// intercept: wrap transport to rewrite host to the test server
	base := c.http.Transport
	c.http.Transport = rewriteTransport{base: base, target: srv.URL}
	return c
}

type rewriteTransport struct {
	base   http.RoundTripper
	target string // http://127.0.0.1:port
}

func (rt rewriteTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	u := req.URL
	u.Scheme = "http"
	parsed := strings.TrimPrefix(rt.target, "http://")
	u.Host = parsed
	transport := rt.base
	if transport == nil {
		transport = http.DefaultTransport
	}
	return transport.RoundTrip(req)
}

func TestCheckImPermission(t *testing.T) {
	cases := []struct {
		name string
		body string
		want int
	}{
		{"陌生人3条", `{"status_code":0,"data":{"notice_code":["chat_stranger_check"]}}`, 3},
		{"请求1条", `{"status_code":0,"data":{"notice_code":["chat_request_start"]}}`, 1},
		{"不可私信-空", `{"status_code":0,"data":{"notice_code":[]}}`, 0},
		{"不可私信-无字段", `{"status_code":0,"data":{}}`, 0},
		{"字符串形态notice_code", `{"status_code":0,"data":{"notice_code":"chat_stranger_check"}}`, 3},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := startNoticeServer(t, tc.body, 200)
			c := newTestClient(t, srv)
			got, err := c.CheckImPermission(context.Background(), 111, "222")
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Errorf("got %d, want %d", got, tc.want)
			}
		})
	}
}

func TestCheckImPermissionStatusError(t *testing.T) {
	srv := startNoticeServer(t, `{"status_code":200001,"status_msg":"ck expired"}`, 200)
	c := newTestClient(t, srv)
	_, err := c.CheckImPermission(context.Background(), 111, "222")
	if err == nil {
		t.Fatal("expected error for status_code != 0")
	}
	if !strings.Contains(err.Error(), "ck expired") {
		t.Errorf("error should carry status_msg, got %v", err)
	}
}

func TestCheckImPermissionHTTPError(t *testing.T) {
	srv := startNoticeServer(t, "", 500)
	c := newTestClient(t, srv)
	_, err := c.CheckImPermission(context.Background(), 111, "222")
	if err == nil {
		t.Fatal("expected error for HTTP 500")
	}
}

func TestParseProfileUID(t *testing.T) {
	// layout: __DEFAULT_SCOPE__ → webapp.user-details → userInfo.user.id
	html := `<html><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">` +
		`{"__DEFAULT_SCOPE__":{"webapp.user-details":{"userInfo":{"user":{"id":"7319826453671301423"}}}}}` +
		`</script></html>`
	if uid := parseProfileUID(html); uid != 7319826453671301423 {
		t.Errorf("parseProfileUID = %d, want 7319826453671301423", uid)
	}
	// fallback regex
	if uid := parseProfileUID(`..."Uid":68841992134,...`); uid != 68841992134 {
		t.Errorf("fallback parseProfileUID = %d", uid)
	}
	// not logged in
	if uid := parseProfileUID(`<html>login page</html>`); uid != 0 {
		t.Errorf("expected 0 for anonymous page, got %d", uid)
	}
}

func TestNewClientProxyValidation(t *testing.T) {
	if _, err := NewClient("", "", ""); err == nil {
		t.Error("expected error for empty cookie")
	}
	if _, err := NewClient("sessionid=x", "", "://bad-url"); err == nil {
		t.Error("expected error for invalid proxy URL")
	}
}
