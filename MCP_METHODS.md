# MCP Methods and Endpoints

This document lists all Model Context Protocol (MCP) methods and endpoints that must be implemented for a compliant MCP server with SSE transport.

## HTTP Endpoints

### SSE Transport Endpoints

| Endpoint | Method | Description | Status |
|----------|--------|-------------|--------|
| `/mcp` or `/sse` | GET | SSE event stream connection | ✅ Implemented |
| `/mcp` or `/messages` | POST | JSON-RPC message endpoint | ✅ Implemented |
| `/register` | POST | Client registration endpoint | ✅ Implemented |
| `*` | OPTIONS | CORS preflight requests | ✅ Implemented |

**Note**: The `/mcp` endpoint supports both GET (for SSE streaming) and POST (for JSON-RPC messages) as per MCP protocol specification.

## JSON-RPC Methods

### Core Lifecycle Methods

| Method | Type | Description | Status |
|--------|------|-------------|--------|
| `initialize` | Request | Initialize connection and negotiate capabilities | ✅ Implemented |
| `notifications/initialized` | Notification | Client confirms initialization | ✅ Implemented |
| `shutdown` | Request | Graceful shutdown request | ❌ Not implemented |
| `exit` | Notification | Terminate connection | ❌ Not implemented |

### Tool Methods

| Method | Type | Description | Status |
|--------|------|-------------|--------|
| `tools/list` | Request | List available tools | ✅ Implemented |
| `tools/call` | Request | Execute a tool | ✅ Implemented |

### Resource Methods

| Method | Type | Description | Status |
|--------|------|-------------|--------|
| `resources/list` | Request | List available resources | ❌ Not implemented |
| `resources/read` | Request | Read resource content | ❌ Not implemented |
| `resources/subscribe` | Request | Subscribe to resource updates | ❌ Not implemented |
| `resources/unsubscribe` | Request | Unsubscribe from resource updates | ❌ Not implemented |

### Prompt Methods

| Method | Type | Description | Status |
|--------|------|-------------|--------|
| `prompts/list` | Request | List available prompts | ✅ Implemented (returns empty) |
| `prompts/get` | Request | Get specific prompt template | ❌ Not implemented |

### Completion Methods (Optional)

| Method | Type | Description | Status |
|--------|------|-------------|--------|
| `completions/complete` | Request | Provide completion suggestions | ❌ Not implemented |

### Logging Methods (Optional)

| Method | Type | Description | Status |
|--------|------|-------------|--------|
| `logging/setLevel` | Request | Set server log level | ❌ Not implemented |

### Sampling Methods (Optional)

| Method | Type | Description | Status |
|--------|------|-------------|--------|
| `sampling/createMessage` | Request | Create sampling message | ❌ Not implemented |

## SSE Transport Features

### Required Headers

| Header | Direction | Description | Status |
|--------|-----------|-------------|--------|
| `Content-Type: text/event-stream` | Response | SSE stream content type | ✅ Implemented |
| `Accept: text/event-stream` | Request | Client accepts SSE | ✅ Handled |
| `Last-Event-ID` | Request | Resume from event ID | ❌ Not implemented |
| `Mcp-Session-Id` | Request/Response | Session identifier | ❌ Not implemented |
| `MCP-Protocol-Version` | Request/Response | Protocol version negotiation | ❌ Not implemented |

### SSE Event Format

```
event: <event-type>
id: <event-id>
data: <json-payload>

```

Current implementation only sends `data:` field without `event:` and `id:` fields.

## Required Minimal Implementation

For a minimal compliant MCP server with SSE transport, these methods MUST be implemented:

1. **Core**: `initialize`, `notifications/initialized`
2. **Tools**: `tools/list`, `tools/call`
3. **Resources**: `resources/list` (can return empty)
4. **Prompts**: `prompts/list` (can return empty)

## Implementation Priority

Based on MCP protocol requirements, implement in this order:

1. ✅ **Completed** (Core functionality):
   - Core initialization and tools
   - `resources/list` - Returns empty list
   - `resources/read` - Returns not found error
   - `resources/subscribe` - Accepts but no-op
   - `resources/unsubscribe` - Accepts but no-op
   - `prompts/get` - Returns not found error
   - `/register` endpoint - Client registration
   - SSE event IDs and proper event format
   - `Last-Event-ID` header support
   - `Mcp-Session-Id` header support

2. 🔮 **Low Priority** (Optional features):
   - `shutdown` and `exit` methods
   - `completions/complete`
   - `logging/setLevel`
   - `sampling/createMessage`