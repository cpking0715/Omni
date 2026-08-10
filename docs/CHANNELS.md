# 通道清单与前端接入规范

> 更新时间: 2026-08-10 · 实测环境: AdsPower `k1flkhdn` (tiktok-2) · uid=7664958044560016398
> 实测详情见 [ttdm/FEATURES.md](../ttdm/FEATURES.md) 〇节；CLI 用法见 [ttdm/README.md](../ttdm/README.md)。

## 一、可用通道清单（下拉框数据源）

前端「发送设置」通道下拉框可直接消费以下 JSON（value 与 CLI `--channel` 取值一致）：

```json
[
  { "value": "web",    "label": "Web HTTP 协议（逆向直连）", "status": "available",     "enabled": true,
    "support": ["text"], "note": "无签名直连（M6-4/k1flkhdn 实测），最快通道" },
  { "value": "browser","label": "浏览器模拟（AdsPower + CDP）", "status": "available",  "enabled": true,
    "support": ["text"], "note": "当前主力通道，真实浏览器环境，频率最安全" },
  { "value": "auto",   "label": "自动（Web 优先，失败降级浏览器）", "status": "available", "enabled": true,
    "support": ["text"], "note": "推荐默认选项" },
  { "value": "wss",    "label": "Web WSS（im-ws 长连接）", "status": "partial",        "enabled": false,
    "support": ["text"], "note": "连接/握手已打通，发送复用 HTTP send_text；暂不单独开放" },
  { "value": "android","label": "Android WSS 协议", "status": "unavailable",          "enabled": false,
    "support": ["text"], "note": "服务端 HTTP 400 拒绝，仅保留协议骨架" }
]
```

### 状态枚举

| 状态 | 含义 | 前端呈现 |
|---|---|---|
| `available` | ✅ 实测可用 | 可选 |
| `partial` | ⚠️ 部分可用（连接通、发送未独立） | 置灰 + 原因提示 |
| `unavailable` | ❌ 不可用 | 置灰 + 原因提示 |

## 二、各通道配置项（发送设置表单）

| 通道 | 必填配置 | 说明 |
|---|---|---|
| `web` | 账号 cookie（含 ttwid/sessionid） | 签名快照可选（`sign_snapshot.json`）；代理可选 |
| `browser` | AdsPower API Key + 浏览器配置 ID（账号绑定 `ads_profile_id`） | 账号-浏览器环境 1:1；代理由浏览器环境自带 |
| `auto` | 账号 cookie + AdsPower API Key | Web 失败自动降级 browser |
| `wss` | 账号 cookie（ttwid 提取 access_key） | 仅连接层开放，发送仍走 HTTP |
| `android` | — | 不开放 |

### 前端表单 Schema（建议）

```json
{
  "channel": { "type": "select", "source": "见上方下拉框数据源", "default": "auto" },
  "ads_api_key": { "type": "password", "requiredWhen": ["browser", "auto"], "hint": "AdsPower 本地 API Key" },
  "ads_profile_id": { "type": "text", "requiredWhen": ["browser", "auto"], "hint": "AdsPower 浏览器配置 ID，如 k1flkhdn（注意与 k1fan6kh 区分）" },
  "interval_secs": { "type": "number", "min": 30, "default": 30, "hint": "发送间隔下限，风控要求 ≥30s" },
  "jitter_secs": { "type": "number", "min": 0, "max": 60, "default": 10, "hint": "间隔随机抖动上限，实际等待 = interval + [0,jitter]" },
  "daily_max": { "type": "number", "min": 0, "default": 0, "hint": "单账号每日发送上限，0=不限制；建议 ≤50" },
  "max_fail": { "type": "number", "min": 1, "default": 5, "hint": "连续失败退避退出阈值（已有 1 次连接重试）" },
  "proxy": { "type": "text", "optional": true, "hint": "http/https/socks5，逗号分隔轮询" }
}
```

## 三、CLI 对应关系

```bash
# web 通道（无签名直连）
ttdm task create --senders 2 --receivers @targets.txt --text "hi" --channel web \
  --interval 30 --jitter 10 --daily-max 50 --max-fail 5

# browser 通道
ttdm task create --senders 2 --receivers @targets.txt --text "hi" --channel browser \
  --ads-key <AdsPower API Key> --interval 30 --jitter 10 --daily-max 50

# auto 通道（推荐默认）
ttdm task create --senders 2 --receivers @targets.txt --text "hi" --channel auto \
  --ads-key <AdsPower API Key> --interval 30 --jitter 10 --daily-max 50
```

## 四、风控参数（2026-08-10 实测落地）

| 参数 | 默认 | 说明 |
|---|---|---|
| `--interval` | 30s（原 3s） | 单账号发送间隔下限，实测 30s 未触发限频 |
| `--jitter` | 10s | 随机抖动，避免固定节奏被风控识别 |
| `--daily-max` | 0（不限） | 按本地自然日统计（`messages.sent_at`），超出即停止该账号 |
| `--max-fail` | 5 | 连续失败退出；连接失败自动重试 1 次（1s 后） |

> 业务码：`7180` 过快→整账号退出；`7193` 消息请求限制→终止该目标；`7195` 内容审核；`200001` cookie 失效。
