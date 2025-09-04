# MCP SSE 与 Inspector 连接问题分析

本文记录“Claude Code 可以通过当前 SSE MCP 连接成功，但 `npx @modelcontextprotocol/inspector` 无法连接”的完整分析、证据、复现方式与修复建议。

## TL;DR
- 现有 SSE 实现建立了 `GET /mcp` 的事件流，并允许 `POST /messages` 或 `POST /mcp` 发送 JSON-RPC，但在 SSE 连接建立后没有立刻推送初始的 `event: endpoint` 事件。
- Inspector 的 SSE 客户端依赖这条 `endpoint` 事件来获取后续 JSON-RPC 的 POST 地址（通常是 `/messages?sessionId=...`）；若收不到该事件，它就认为“无法连接”。
- 因此：Claude Code 能连（不需要 `endpoint` 事件），而 Inspector 等待该事件 → 超时或报错。

## 现状与证据

代码主要位置：
- `lua/claudecode/server/router.lua`
  - 路由规则允许：`GET /mcp`（或 `/sse`）作为 SSE、`POST /messages` 或 `POST /mcp` 作为 JSON-RPC 消息端点、`POST /register` 注册端点、以及 `OPTIONS` 预检。
- `lua/claudecode/server/sse.lua`
  - `handle_sse_connect(client, request)`：返回 `text/event-stream` 头、保存 `M.sse_session_id`、设置 `client.client_type = "sse"`，但不发送任何首包事件。
  - `send_sse_event(client, data, event_type)`：会产生标准 SSE 帧（支持 `event:` 与自增的 `id:`，`data:` 为 JSON 字符串）。
  - `handle_post_message(...)`：仅使用 `Content-Length` 判断请求体长度，并只从头部读取 `mcp-session-id`；不解析查询参数。
  - `handle_options()`：CORS 允许的头为 `Content-Type, Accept, X-Claude-Code-IDE-Authorization, Mcp-Session-Id, Last-Event-ID`。
- `lua/claudecode/server/tcp.lua`
  - 在路由判断为 `sse` 后，写回 `create_sse_response()` 返回的 200 头，并启动 30s 的 SSE 心跳（以 `:\n\n` 注释形式）。没有后续立即推送“endpoint”事件。

补充现象：
- `MCP_METHODS.md` 里有一条过时说明“当前实现仅发送 `data:` 无 `event:`/`id:`”。实际代码里 `send_sse_event` 已含 `event`（可选）与 `id`，但“缺少初始 endpoint 事件”仍成立。
- 服务器绑定 `127.0.0.1`；若上游用 `localhost` 被解析到了 `::1`（IPv6 回环），可能出现“连接不上”的表现（排查方式见下）。

## 为什么 Claude Code 能连而 Inspector 不行

- Claude Code（Neovim/VSCode 扩展一类）对 SSE 连接可能不依赖初始 `endpoint` 事件（或使用了不同的握手路径），因此当前实现依旧可用。
- Inspector 的 SSE 流程通常是：
  1) `GET /mcp` 建立 SSE；
  2) 等待服务端推送 `event: endpoint`，其 `data` 是“用于发送 JSON-RPC 的 POST URL”（常见是 `/messages?sessionId=...`）；
  3) 客户端拿到该 URL 后，发送 `initialize` 等 JSON-RPC 请求。
- 我们当前没有推送步骤 2 的事件，导致 Inspector 不知道 POST 应发到何处，于是失败。

## 可能的次要影响点

- 仅支持 `Content-Length`：如果上游使用 `Transfer-Encoding: chunked`（部分 Node/fetch/代理情形），`router.has_complete_body` 会误判，`handle_post_message` 会返回“Missing Content-Length header”等。
- CORS 头缺少 `Authorization`：若未来需要浏览器端或代理转发带鉴权头的 POST/SSE，可将其加入 `Access-Control-Allow-Headers` 以提高兼容性。
- IPv4/IPv6：Inspector 目标 URL 建议使用 `http://127.0.0.1:<PORT>/mcp` 明确走 IPv4，避免系统把 `localhost` 解析到 `::1`。
- 协议版本：`initialize` 响应里当前返回的 `protocolVersion = "2024-11-05"`（见 `server/init.lua`），新客户端可能使用更高版本；一般问题不大，但改为回显或协商也更稳健。

## 复现步骤

1) 观察 SSE 首包是否包含 `endpoint`：

```bash
PORT=<<<实际端口>>>
curl -v -N \
  -H 'Accept: text/event-stream' \
  http://127.0.0.1:$PORT/mcp
```

- 期望（Inspector 友好）：连接后立刻出现一条事件：

```
event: endpoint
id: 1
data: /messages?sessionId=<某会话ID>

```

- 实际（当前）：通常只有 200 头，随后每 30s 一次 `:` 心跳注释，没有 `endpoint` 事件。

2) 验证 POST 消息端点可用：

```bash
PORT=<<<实际端口>>>
curl -v -X POST \
  -H 'Content-Type: application/json' \
  http://127.0.0.1:$PORT/messages \
  --data '{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"inspector","version":"dev"}}}'
```

- 若返回 JSON 则端点逻辑可用；若报缺少 `Content-Length`，说明 hit 到 chunked 限制（`curl` 默认不会发 chunked，但经代理/脚本可能会）。

3) Inspector 明确以 SSE 连接（便于观察其行为）：

```bash
npx @modelcontextprotocol/inspector \
  --server http://127.0.0.1:$PORT/mcp \
  --transport sse \
  --verbose
```

- 如果日志显示在“等待 SSE endpoint”阶段卡住/超时，则与上述根因一致。

## 修复方案（推荐实现顺序）

1) 在 SSE 连接建立后立即推送 `endpoint` 事件（核心修复）

- 在 `tcp.lua` 中完成 `sse.handle_sse_connect` 写回 200 头并设为 `connected` 后，立即发送：

  - `event: endpoint`
  - `data: /messages?sessionId=<M.sse_session_id>`

- 当前的 `send_sse_event` 会将 `data` JSON 编码。`endpoint` 事件的 `data` 应该是“纯文本路径字符串”，为避免多层引号，建议在 `sse.lua` 增加一个“不做 JSON 包装的原始事件发送函数”。例如：

```lua
-- sse.lua（新增）
function M.send_sse_raw_event(client, raw_data, event_type)
  if not client or not client.tcp_handle then return false end
  M.event_id_counter = M.event_id_counter + 1
  local parts = {}
  if event_type then table.insert(parts, "event: " .. event_type) end
  table.insert(parts, "id: " .. tostring(M.event_id_counter))
  for line in tostring(raw_data):gmatch("[^\n]+") do
    table.insert(parts, "data: " .. line)
  end
  local event = table.concat(parts, "\n") .. "\n\n"
  client.tcp_handle:write(event)
  return true
end
```

- 在 `tcp.lua` 里，`client.state = "connected"` 且 `server.on_connect(client)` 之后调用：

```lua
local sse_path = server.config.sse and server.config.sse.path or "/mcp"
local endpoint = "/messages?sessionId=" .. (require("claudecode.server.sse").sse_session_id or "")
require("claudecode.server.sse").send_sse_raw_event(client, endpoint, "endpoint")
```

2) 兼容从查询参数读取 `sessionId`

- 在 `sse.lua:handle_post_message` 里，如果没有 `mcp-session-id` 头，则解析请求行路径上的 `?sessionId=...` 并赋值到 `M.sse_session_id`。这可与 Inspector 的常见习惯保持一致。

3)（可选）接受 `Transfer-Encoding: chunked`

- 扩展 `router.has_complete_body` 与 `handle_post_message`：当检测到 `Transfer-Encoding: chunked` 时，解析 chunk 流，直到 `0\r\n\r\n` 结束，再解 JSON。

4)（可选）CORS 允许 `Authorization`

- 在 `create_sse_response`、`create_json_response` 与 `handle_options` 的 `Access-Control-Allow-Headers` 中加入 `Authorization`，增强代理/浏览器端连通性。

5)（可选）协议版本与日志

- `initialize` 响应里的 `protocolVersion` 可回显客户端请求或升级到兼容的较新版本；同时在 Inspector 连接路径增加 debug 日志（记录是否已发送 `endpoint` 事件、其 `data` 内容等）。

## 验证清单

- 连接后即刻能在 `curl -N` 的输出中看到 `event: endpoint` 与正确的 `data:` 路径。
- Inspector 指向 `--server http://127.0.0.1:<PORT>/mcp --transport sse` 能正常显示 `initialize`/工具列表。
- `POST /messages` 同时支持：
  - `Mcp-Session-Id` 头；
  - `?sessionId=` 查询参数（两者任一存在即可）。
- 代理环境或 Node 客户端下（可能 chunked）仍能返回 JSON；
- IPv4/IPv6：使用 `127.0.0.1` 或确保 `localhost` 解析一致；
- CORS：必要时能带上 `Authorization` 头访问。

## 附：代码参考点

- 路由与端点：`lua/claudecode/server/router.lua`
- SSE 实现：`lua/claudecode/server/sse.lua`
- TCP 接入与心跳：`lua/claudecode/server/tcp.lua`
- 认证/锁文件：`lua/claudecode/lockfile.lua`，`lua/claudecode/init.lua`
- MCP 方法注册：`lua/claudecode/server/init.lua`

---

若需要，我可以直接提交上述最小修复（发送 `endpoint` 事件 + 解析 `sessionId` 查询参数），并附上一个 `scripts/sse_endpoint_probe.sh` 的小脚本用于自动验证首包事件。

