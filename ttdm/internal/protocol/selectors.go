package protocol

// DOM 选择器集中管理 (DESIGN 13.7)。模拟通道用到的全部选择器收敛在此,
// 页面改版只需改这一处。选择器取自反编译代码
// TikTokBrowserSimulateService.ImSendMessageAsync,2026-08 实测有效。

// 私信页面 URL 模板 (DESIGN 5.7.1 导航):
// https://www.tiktok.com/messages?lang=en&u={uid}
const BrowserMessagesURL = "https://www.tiktok.com/messages?lang=en&u="

// SelMessageInput 输入区 (Draft.js 编辑器)。
var SelMessageInput = []string{
	"div[data-e2e=message-input-area] div.DraftEditor-root",
}

// SelChatUniqueID 会话标志: 非空且非 "@" 表示会话已加载。
var SelChatUniqueID = []string{
	"p[data-e2e='chat-uniqueid']",
}

// SelSendButton 发送按钮 (新旧两版 + 2026-08 新版候选)。
// 2026-08 实测: 新版发送按钮是 svg[aria-label="Send"] (非 button,
// 输入文字后出现)。autoSend 有 svg 点击 + Enter 兜底。
var SelSendButton = []string{
	"svg[aria-label=Send]",
	"[aria-label=Send]",
	"[data-e2e=message-send]",
	"[data-e2e=dm-new-send-btn]",
	"[data-e2e=dm-send-btn]",
	"[data-e2e=dm-message-send-btn]",
	"div[data-e2e=dm-new-chat-bottom] button[type=button]",
}

// SelLastChatItem 结果检查: 最后一条聊天记录。
var SelLastChatItem = []string{
	"#main-content-messages div[data-e2e=chat-item]:last-of-type",
}

// SelSendWarning 发送结果探测: 警告/通知/失败提示。
var SelSendWarning = []string{
	"div[data-e2e=dm-warning]",
	"div[data-e2e=dm-message-notification]",
	"div[class*=DivSendFailTip]",
}

// SelConversationItem 会话列表项 (debug/兜底用)。
// 2026-08 实测: 新版页面使用 dm-new-conversation-item, 且元素
// data-conv-id 属性直接携带完整 conversation_id (0:1:{对方}:{自己})。
var SelConversationItem = []string{
	`div[data-e2e="dm-new-conversation-item"]`,
	`[data-e2e="conversation-item"]`,
	`[data-e2e="im-conversation-item"]`,
	`[data-e2e="chat-item"]`,
	`div[class*="DivConversationItem"]`,
	`a[href*="/messages/"]`,
}

// SelConversationList 会话列表容器 (会话项存在性判断)。
var SelConversationList = []string{
	`div[data-e2e="dm-new-conversation-list"]`,
}
