package task

import (
	"math/rand"
	"strings"
	"time"

	"ttdm/internal/store"
)

// emojiPool is the 40-symbol constant pool from the original client
// (RandomEmoji 追加 3 个随机表情, DESIGN 5.8/10.2).
var emojiPool = []string{
	"😀", "😁", "😂", "🤣", "😃", "😄", "😅", "😆", "😉", "😊",
	"😋", "😎", "😍", "😘", "🥰", "😗", "😙", "😚", "🙂", "🤗",
	"🤩", "🤔", "🤨", "😐", "😑", "😶", "🙄", "😏", "😣", "😥",
	"😮", "🤐", "😯", "😪", "😫", "🥱", "😴", "😌", "😛", "😜",
}

// Renderer renders 话术 for each send (DESIGN 5.8/10.2 + PRD 4.10 新增
// 变量插值). One Renderer per task; RenderText is safe for concurrent use.
type Renderer struct {
	templates       []*store.ChatTemplate
	linkPool        []string
	randomEmoji     bool
	currentDateTime bool
	rnd             *rand.Rand
	now             func() time.Time // injectable for tests
}

// NewRenderer builds a renderer from the selected 话术 and options.
// Returns nil when templates is empty (caller falls back to plain text).
func NewRenderer(templates []*store.ChatTemplate, linkURLs []string, randomEmoji, currentDateTime bool) *Renderer {
	if len(templates) == 0 {
		return nil
	}
	return &Renderer{
		templates:       templates,
		linkPool:        linkURLs,
		randomEmoji:     randomEmoji,
		currentDateTime: currentDateTime,
		rnd:             rand.New(rand.NewSource(time.Now().UnixNano())),
		now:             time.Now,
	}
}

// RenderText picks a random template and interpolates variables:
//
//	{用户名} → receiver uid  {链接} → random pool URL
//	{日期} → 2006-01-02  {时间} → 15:04  {时间全} → 2006-01-02 15:04
//
// then optionally appends 3 random emoji and the current time.
// receiver is the target uid as a string.
func (r *Renderer) RenderText(receiver string) string {
	t := r.templates[r.rnd.Intn(len(r.templates))]
	text := normalizeNewlines(t.Text)

	vars := map[string]string{
		"{用户名}": receiver,
		"{链接}":   r.PickLinkURL(),
		"{日期}":   r.now().Format("2006-01-02"),
		"{时间}":   r.now().Format("15:04"),
		"{时间全}":  r.now().Format("2006-01-02 15:04"),
	}
	for k, v := range vars {
		text = strings.ReplaceAll(text, k, v)
	}

	if r.randomEmoji {
		for i := 0; i < 3; i++ {
			text += emojiPool[r.rnd.Intn(len(emojiPool))]
		}
	}
	if r.currentDateTime {
		text += " " + r.now().Format("2006-01-02 15:04")
	}
	return text
}

// PickLinkURL returns a random URL from the pool (RandomLinkUrl,
// 防平台识别重复链接), or "" when the pool is empty.
func (r *Renderer) PickLinkURL() string {
	if len(r.linkPool) == 0 {
		return ""
	}
	return r.linkPool[r.rnd.Intn(len(r.linkPool))]
}

// normalizeNewlines folds CRLF/CR to LF (DESIGN 10.2 渲染规则 step 2).
func normalizeNewlines(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	return strings.ReplaceAll(s, "\r", "\n")
}
