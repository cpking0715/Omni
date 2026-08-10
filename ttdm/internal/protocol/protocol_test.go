package protocol

import (
	"strings"
	"testing"

	"github.com/pierrec/lz4/v4"
)

func TestAccessKey(t *testing.T) {
	// md5("9e1bd35ec9db7b8d846de66ed140b1ad9" + "7319826453671301423" + "f8a69f1719916z")
	got := AccessKey("7319826453671301423")
	if len(got) != 32 {
		t.Fatalf("access_key length %d, want 32", len(got))
	}
	// recompute with stdlib to verify determinism
	want := md5Hex("9e1bd35ec9db7b8d846de66ed140b1ad9" + "7319826453671301423" + "f8a69f1719916z")
	if got != want {
		t.Errorf("access_key mismatch: %s != %s", got, want)
	}
}

func TestMapSendStatus(t *testing.T) {
	cases := []struct {
		code int
		tips string
		want bool // success?
		quit bool
	}{
		// Fidelity note: the original client treats a JsonBody with
		// status_code=0 and no tips as failure (" [0]"); real success
		// responses carry no JsonBody (→ Success) or a limit code
		// 7174/7178/7192 (stranger 3-message cap reached = still sent).
		{0, "", false, false},
		{7174, "", true, false},
		{7178, "3 messages limit", true, false},
		{7192, "", true, false},
		{7180, "", false, true},
		{7175, "", false, false},
		{7282, "", false, false},
		{9999, "", false, false},
	}
	for _, c := range cases {
		got := MapSendStatus(c.code, c.tips)
		if (got.Error == "") != c.want {
			t.Errorf("code=%d tips=%q: success=%v want %v (err=%q)", c.code, c.tips, got.Error == "", c.want, got.Error)
		}
		if got.Quit != c.quit {
			t.Errorf("code=%d: quit=%v want %v", c.code, got.Quit, c.quit)
		}
	}
}

func TestMapSendStatusTips(t *testing.T) {
	got := MapSendStatus(0, "This message is blocked by receiver's settings")
	if got.Error == "" {
		t.Error("expected error mapping for receiver settings tips")
	}
	if !strings.Contains(got.Error, "对方的设置") {
		t.Errorf("unexpected mapping: %q", got.Error)
	}
}

func TestEscapeJSONString(t *testing.T) {
	got := EscapeJSONString(`he said "hi"
next line`)
	want := `he said \"hi\"\nnext line`
	if got != want {
		t.Errorf("EscapeJSONString = %q, want %q", got, want)
	}
}

func TestBuildWSQuery(t *testing.T) {
	q := BuildWSQuery("device123", "abcd", "")
	for _, must := range []string{"aid=1233", "access_key=abcd", "device_id=device123", "app_name=musical_ly", "version_name=31.7.3"} {
		if !strings.Contains(q, must) {
			t.Errorf("query missing %q: %s", must, q)
		}
	}
}

func TestWireEncodeDecode(t *testing.T) {
	// encode a Type 609 request and verify the message sn/status roundtrip
	sn := int32(773842)
	req := buildAppImRequest(sn, cmdCreateConversation, "device-1", buildCreateConversationBody(100, 200))
	if len(req) == 0 {
		t.Fatal("empty request")
	}
	// find field 8 (AppImRequestMessage)
	p := &parser{data: req}
	inner, ok, err := p.findLen(8)
	if err != nil || !ok {
		t.Fatalf("find message field: %v ok=%v", err, ok)
	}
	mp := &parser{data: inner}
	cmd, ok, err := mp.findVarint(1)
	if err != nil || !ok {
		t.Fatalf("find cmd: %v", err)
	}
	if cmd != cmdCreateConversation {
		t.Errorf("cmd = %d, want %d", cmd, cmdCreateConversation)
	}
	gotSn, ok, _ := mp.findVarint(2)
	if !ok || int32(gotSn) != sn {
		t.Errorf("sn = %d, want %d", gotSn, sn)
	}
}

func TestParseAppImResponse(t *testing.T) {
	// build a response frame: {8: {2: sn, 4: "OK", 6: {6: "{...}"}}}
	var result encoder
	result.str(6, `{"status_code":7282,"status_msg":{"msg_content":{"tips":"Only friends"}}}`)
	var msg encoder
	msg.int32(2, 773843)
	msg.str(4, "OK")
	msg.bytes(6, result.b)
	var resp encoder
	resp.msg(8, msg.b)

	a, err := parseAppImResponse(resp.b)
	if err != nil {
		t.Fatalf("parseAppImResponse: %v", err)
	}
	if a.sn != 773843 || a.status != "OK" {
		t.Errorf("ack = %+v", a)
	}
	res, err := parseSendAck(a)
	if err != nil {
		t.Fatal(err)
	}
	if res.Error == "" || !strings.Contains(res.Error, "只有好友") {
		t.Errorf("send ack = %+v", res)
	}
}

func TestLZ4RoundTrip(t *testing.T) {
	raw := []byte("hello tiktok im protocol payload payload payload")
	compressed := make([]byte, lz4.CompressBlockBound(len(raw)))
	n, err := lz4.CompressBlock(raw, compressed, nil)
	if err != nil || n <= 0 {
		t.Fatalf("compress: %v n=%d", err, n)
	}
	compressed = compressed[:n]
	out := make([]byte, len(raw))
	got, err := lz4.UncompressBlock(compressed, out)
	if err != nil || got != len(raw) {
		t.Fatalf("uncompress: %v got=%d", err, got)
	}
	if string(out) != string(raw) {
		t.Errorf("roundtrip mismatch")
	}
}

func TestWSSDomain(t *testing.T) {
	cases := map[string]string{
		"alisg":    "frontier.tiktokv.com",
		"maliva":   "frontier.tiktokv.com",
		"useast5":  "frontier.tiktokv.us",
		"useast8":  "frontier.tiktokv.us",
		"useast2a": "frontier.tiktokv.eu",
		"unknown":  "frontier.tiktokv.com",
	}
	for idc, want := range cases {
		if got := WSSDomain(idc); got != want {
			t.Errorf("WSSDomain(%q) = %q, want %q", idc, got, want)
		}
	}
}
