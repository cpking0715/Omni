package protocol

import (
	"strconv"
	"strings"
)

// SendResult is the outcome of one send attempt.
// Terminate: stop sending further cards to this receiver.
// Quit: abort the whole sender loop (rate limit etc.).
type SendResult struct {
	Terminate bool
	Quit      bool
	Error     string
}

// Success is a send that completed without error.
var Success = SendResult{}

// status codes treated as success — the "stranger 3-message limit" reached.
var successLimitCodes = map[int]bool{7174: true, 7178: true, 7192: true}

// errorCodeText maps TikTok IM status codes to the client's Chinese messages.
var errorCodeText = map[int]struct {
	msg  string
	quit bool
}{
	7180: {"消息发送过快，请休息一下再试", true},
	7175: {"已达到聊天消息限制。您将无法向该用户发送消息", false},
	7193: {"对方尚未接受你的消息请求，仅能发送有限条数", false},
	7195: {"此消息违反了《社区自律公约》。为保护社区安全，将对特定内容和行为有所限制", false},
	7278: {"由于对方的帐户已被停用，无法发送消息", false},
	7282: {"只有好友才能互相发送消息", false},
	7283: {"由于对方的设置，无法发送消息", false},
	7289: {"由于多次违反社区准则，您被暂时禁止发送和接收消息", false},
	7290: {"由于对方多次违反社区准则，无法发送或接收消息", false},
	7409: {"您现在无法与该用户聊天", false},
}

// MapSendStatus translates a TikTok status_code + tips into a SendResult,
// mirroring ReceiveMessageAckAsync of the original client.
func MapSendStatus(statusCode int, tips string) SendResult {
	if successLimitCodes[statusCode] {
		return Success
	}
	if tips != "" && (strings.Contains(tips, "3 messages") || strings.Contains(tips, "最多发送3条")) {
		return Success
	}
	if e, ok := errorCodeText[statusCode]; ok {
		return SendResult{Terminate: true, Quit: e.quit, Error: e.msg + " [" + itoa(statusCode) + "]"}
	}
	if tips != "" {
		msg := mapTips(tips)
		if msg == "" {
			msg = tips
		}
		return SendResult{Terminate: true, Error: msg + " [" + itoa(statusCode) + "]"}
	}
	return SendResult{Terminate: true, Error: "发送失败 [" + itoa(statusCode) + "]"}
}

// mapTips handles English text hints that carry the same meaning as codes.
func mapTips(tips string) string {
	switch {
	case strings.Contains(tips, "receiver’s settings") || strings.Contains(tips, "receiver's settings"):
		return "由于对方的设置，无法发送消息"
	case strings.Contains(tips, "privacy settings"):
		return "由于对方的隐私设置，无法发送消息"
	case strings.Contains(tips, "contact has been suspended"):
		return "由于对方的帐户已被停用，无法发送消息"
	case strings.Contains(tips, "violation of our Community"):
		return "此消息违反了《社区自律公约》。为保护社区安全，将对特定内容和行为有所限制"
	case strings.Contains(tips, "Due to multiple Community"):
		return "由于多次违反《社区自律公约》，你暂时无法发送消息"
	case strings.Contains(tips, "too fast"):
		return "消息发送过快，请休息一下再试"
	}
	return ""
}

func itoa(v int) string { return strconv.Itoa(v) }
