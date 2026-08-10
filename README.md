# Omni

TikTok 私信触达工具（`ttdm`）及其协议逆向文档仓库。

`ttdm` 是基于 [docs/TIKTOK-DM-FLOW.md](docs/TIKTOK-DM-FLOW.md) 协议梳理与 [docs/tiktok/TIKTOK-DESIGN.md](docs/tiktok/TIKTOK-DESIGN.md) 重构方案实现的纯本地 CLI 工具：强私筛选 → 话术库随机话术 → 多通道私信发送 → 结果导出，无第三方中转依赖。

## 仓库结构

```
├── docs/                 # 协议逆向、PRD、设计文档
│   ├── TIKTOK-DM-FLOW.md     # DM 协议链路梳理
│   └── tiktok/
│       ├── TIKTOK-PRD.md     # 产品需求文档
│       └── TIKTOK-DESIGN.md  # 重构设计方案
└── ttdm/                 # Go 实现（CLI）
    ├── cmd/ttdm              # CLI 入口 (account/screening/template/task/message/adspower)
    ├── internal/
    │   ├── store/            # SQLite 数据层
    │   ├── tiktokapi/        # TikTok Web HTTP API（强私筛选 / Cookie 校验）
    │   ├── protocol/         # 通道实现: AndroidClient / WebClient / BrowserClient / AutoClient
    │   ├── adspower/         # AdsPower Local API + CDP 操作原语
    │   └── task/             # 任务引擎（并发 / 互斥 / 通道选择 / 话术渲染）
    ├── README.md             # ttdm 完整使用文档
    └── FEATURES.md           # 已实现功能清单与逆向结论
```

## 快速开始

```bash
cd ttdm
go build -o ttdm.exe ./cmd/ttdm
go test ./...
```

完整用法（账号导入、强私筛选、话术库、任务创建、AdsPower 绑定）见 [ttdm/README.md](ttdm/README.md)。

## 通道状态一览

| 通道 | 状态 |
|---|---|
| 通道二 Web HTTP 发送（im-api message/send） | ✅ 可用，无签名直连（M6 已打通） |
| 通道二 Web WSS（im-ws.tiktok.com） | 🔶 连接已打通，发送走 HTTP |
| 模拟通道（AdsPower 浏览器 + CDP） | ✅ 可用（当前主力） |
| 通道一 Android WSS 协议 | ⚠️ 骨架保留，服务端已拒绝 |
| 通道三/四（厂商中转） | ❌ 已弃用 |

## 技术栈

- Go 1.26，单文件二进制，无运行时依赖
- gorilla/websocket、手写 protobuf wire 编解码、pierrec/lz4
- modernc.org/sqlite（纯 Go，无 CGO）、golang.org/x/net/proxy（socks5/http 代理）
- AdsPower Local API + CDP 模拟浏览器通道
