package task

import (
	"math/rand"
	"strings"
	"testing"
	"time"

	"ttdm/internal/store"
)

func fixedRenderer(text string, opts ...bool) *Renderer {
	randomEmoji, currentDateTime := false, false
	if len(opts) > 0 {
		randomEmoji = opts[0]
	}
	if len(opts) > 1 {
		currentDateTime = opts[1]
	}
	r := NewRenderer([]*store.ChatTemplate{{ID: 1, Text: text}},
		[]string{"https://a.example", "https://b.example"}, randomEmoji, currentDateTime)
	r.rnd = rand.New(rand.NewSource(42))
	r.now = func() time.Time { return time.Date(2026, 8, 15, 9, 30, 0, 0, time.UTC) }
	return r
}

func TestNewRendererEmpty(t *testing.T) {
	if NewRenderer(nil, nil, false, false) != nil {
		t.Error("expected nil renderer for empty templates")
	}
}

func TestRenderTextVariables(t *testing.T) {
	r := fixedRenderer("hi {用户名}, visit {链接} on {日期} {时间}")
	got := r.RenderText("730123")
	if !strings.Contains(got, "hi 730123,") {
		t.Errorf("{用户名} not interpolated: %q", got)
	}
	if !strings.Contains(got, "https://a.example") && !strings.Contains(got, "https://b.example") {
		t.Errorf("{链接} not interpolated from pool: %q", got)
	}
	if !strings.Contains(got, "2026-08-15") || !strings.Contains(got, "09:30") {
		t.Errorf("date/time not interpolated: %q", got)
	}
}

func TestRenderTextEmojiAndTime(t *testing.T) {
	base := "hello"
	r := fixedRenderer(base, true, true)
	got := r.RenderText("1")
	if !strings.HasPrefix(got, base) {
		t.Errorf("prefix lost: %q", got)
	}
	// 3 emoji appended + " 2026-08-15 09:30" suffix
	if !strings.HasSuffix(got, " 2026-08-15 09:30") {
		t.Errorf("datetime suffix missing: %q", got)
	}
	body := strings.TrimSuffix(strings.TrimPrefix(got, base), " 2026-08-15 09:30")
	if len([]rune(body)) != 3 {
		t.Errorf("expected 3 emoji runes, got %q (%d runes)", body, len([]rune(body)))
	}
}

func TestRenderTextNormalizesNewlines(t *testing.T) {
	r := fixedRenderer("line1\r\nline2\rline3")
	got := r.RenderText("1")
	if strings.ContainsAny(got, "\r") {
		t.Errorf("CR not folded: %q", got)
	}
	if got != "line1\nline2\nline3" {
		t.Errorf("unexpected text: %q", got)
	}
}

func TestPickLinkURL(t *testing.T) {
	r := fixedRenderer("x")
	for i := 0; i < 20; i++ {
		u := r.PickLinkURL()
		if u != "https://a.example" && u != "https://b.example" {
			t.Fatalf("unexpected url %q", u)
		}
	}
	empty := NewRenderer([]*store.ChatTemplate{{ID: 1, Text: "x"}}, nil, false, false)
	if empty.PickLinkURL() != "" {
		t.Error("expected empty url for empty pool")
	}
}

func TestRenderRandomSelection(t *testing.T) {
	r := NewRenderer([]*store.ChatTemplate{
		{ID: 1, Text: "AAA"}, {ID: 2, Text: "BBB"},
	}, nil, false, false)
	r.rnd = rand.New(rand.NewSource(1))
	seen := map[string]bool{}
	for i := 0; i < 50; i++ {
		seen[r.RenderText("x")] = true
	}
	if !seen["AAA"] || !seen["BBB"] {
		t.Errorf("random selection should hit both templates, got %v", seen)
	}
}
