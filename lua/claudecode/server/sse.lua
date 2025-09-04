---@brief SSE (Server-Sent Events) MCP server implementation
local logger = require("claudecode.logger")
local utils = require("claudecode.server.utils")

local M = {}

-- SSE client state
M.sse_client = nil
M.sse_session_id = nil
M.event_id_counter = 0  -- Counter for SSE event IDs

---Create SSE response headers
---@return string response HTTP response with SSE headers
function M.create_sse_response()
  local response_lines = {
    "HTTP/1.1 200 OK",
    "Content-Type: text/event-stream",
    "Cache-Control: no-cache",
    "Connection: keep-alive",
    "Access-Control-Allow-Origin: *",
    "Access-Control-Allow-Methods: GET, POST, OPTIONS",
    "Access-Control-Allow-Headers: Content-Type, Accept, X-Claude-Code-IDE-Authorization, Mcp-Session-Id, Last-Event-ID",
  }
  
  -- Add session ID header if we have one
  if M.sse_session_id then
    table.insert(response_lines, "Mcp-Session-Id: " .. M.sse_session_id)
  end
  
  table.insert(response_lines, "")
  table.insert(response_lines, "")
  
  return table.concat(response_lines, "\r\n")
end

---Send an SSE event to the client
---@param client table The client object
---@param data table The data to send (will be JSON encoded)
---@param event_type string|nil Optional event type (default: nil)
---@return boolean success
function M.send_sse_event(client, data, event_type)
  if not client or not client.tcp_handle then
    return false
  end

  -- Increment event ID counter
  M.event_id_counter = M.event_id_counter + 1
  
  local json_data = vim.json.encode(data)
  
  -- Build SSE event with proper format
  local event_parts = {}
  
  -- Add event type if specified
  if event_type then
    table.insert(event_parts, "event: " .. event_type)
  end
  
  -- Add event ID for resumption support
  table.insert(event_parts, "id: " .. tostring(M.event_id_counter))
  
  -- Add data
  table.insert(event_parts, "data: " .. json_data)
  
  -- SSE events are separated by double newline
  local event = table.concat(event_parts, "\n") .. "\n\n"
  
  client.tcp_handle:write(event, function(err)
    if err then
      logger.error("sse", "Failed to send SSE event:", err)
    end
  end)
  
  return true
end

---Handle SSE connection request
---@param client table The client object
---@param request string The HTTP request
---@return boolean success
---@return string response The HTTP response
function M.handle_sse_connect(client, request)
  logger.debug("sse", "SSE connection request from client:", client.id)
  
  -- Extract headers for session management
  local last_event_id = nil
  local mcp_session_id = nil
  
  for line in request:gmatch("([^\r\n]+)") do
    local key, value = line:match("^([^:]+):%s*(.+)$")
    if key then
      local lower_key = key:lower()
      if lower_key == "last-event-id" then
        last_event_id = value:match("^%s*(.-)%s*$")
      elseif lower_key == "mcp-session-id" then
        mcp_session_id = value:match("^%s*(.-)%s*$")
      end
    end
  end
  
  -- Replace any existing SSE client (MCP doesn't support multiple clients)
  if M.sse_client and M.sse_client.id ~= client.id then
    logger.debug("sse", "Replacing existing SSE client:", M.sse_client.id)
    -- Close the old client will be handled by TCP server
  end
  
  -- Use provided session ID or generate new one
  if mcp_session_id then
    M.sse_session_id = mcp_session_id
    logger.debug("sse", "Using client-provided session ID:", mcp_session_id)
  else
    M.sse_session_id = utils.generate_uuid()
    logger.debug("sse", "Generated new session ID:", M.sse_session_id)
  end
  
  -- Handle event ID resumption
  if last_event_id then
    local last_id = tonumber(last_event_id)
    if last_id and last_id > 0 then
      M.event_id_counter = last_id
      logger.debug("sse", "Resuming from event ID:", last_id)
    end
  end
  
  M.sse_client = client
  client.client_type = "sse"
  client.session_id = M.sse_session_id
  
  logger.info("sse", "SSE client connected with session:", M.sse_session_id)
  
  local response = M.create_sse_response()
  return true, response
end

---Handle POST request for MCP messages
---@param request string The HTTP request with headers and body
---@param server table The server instance for accessing tools
---@return string response The HTTP response with JSON result
function M.handle_post_message(request, server)
  -- Parse headers (case-insensitive)
  local content_length
  local mcp_session_id = nil
  
  for line in request:gmatch("([^\r\n]+)") do
    local key, value = line:match("^([^:]+):%s*(.+)$")
    if key then
      local lower_key = key:lower()
      if lower_key == "content-length" then
        content_length = value:match("^%s*(%d+)")
      elseif lower_key == "mcp-session-id" then
        mcp_session_id = value:match("^%s*(.-)%s*$")
      end
    end
  end
  
  -- Store session ID if provided
  if mcp_session_id then
    M.sse_session_id = mcp_session_id
  end
  
  if not content_length then
    return M.create_json_response(400, {
      jsonrpc = "2.0",
      error = {
        code = -32700,
        message = "Parse error",
        data = "Missing Content-Length header"
      }
    })
  end
  
  -- Extract request body
  local body_start = request:find("\r\n\r\n")
  if not body_start then
    return M.create_json_response(400, {
      jsonrpc = "2.0",
      error = {
        code = -32700,
        message = "Parse error",
        data = "Malformed HTTP request"
      }
    })
  end
  
  local body = request:sub(body_start + 4)
  
  -- Parse JSON body
  local success, parsed = pcall(vim.json.decode, body)
  if not success then
    return M.create_json_response(200, {
      jsonrpc = "2.0",
      error = {
        code = -32700,
        message = "Parse error",
        data = "Invalid JSON"
      }
    })
  end
  
  -- Validate JSON-RPC request
  if type(parsed) ~= "table" or parsed.jsonrpc ~= "2.0" then
    return M.create_json_response(200, {
      jsonrpc = "2.0",
      id = parsed.id,
      error = {
        code = -32600,
        message = "Invalid Request",
        data = "Not a valid JSON-RPC 2.0 request"
      }
    })
  end
  
  -- Handle the request using server's handlers
  local method = parsed.method
  local params = parsed.params or {}
  local id = parsed.id
  
  logger.debug("sse", "Processing POST request - method:", method, "id:", id)
  
  -- Get handler from server
  local handler = server and server.state and server.state.handlers and server.state.handlers[method]
  if not handler then
    return M.create_json_response(200, {
      jsonrpc = "2.0",
      id = id,
      error = {
        code = -32601,
        message = "Method not found",
        data = "Unknown method: " .. tostring(method)
      }
    })
  end
  
  -- Execute handler
  local ok, result, error_data = pcall(handler, M.sse_client, params)
  
  local response_data
  if ok then
    -- Check if this is a deferred response (blocking tool)
    if result and result._deferred then
      -- SSE doesn't support deferred responses yet
      response_data = {
        jsonrpc = "2.0",
        id = id,
        error = {
          code = -32000,
          message = "Blocking tools not supported over SSE",
          data = "This tool requires blocking operation which is not yet supported over SSE transport"
        }
      }
    elseif error_data then
      response_data = {
        jsonrpc = "2.0",
        id = id,
        error = error_data
      }
    else
      response_data = {
        jsonrpc = "2.0",
        id = id,
        result = result
      }
    end
  else
    response_data = {
      jsonrpc = "2.0",
      id = id,
      error = {
        code = -32603,
        message = "Internal error",
        data = tostring(result)
      }
    }
  end
  
  return M.create_json_response(200, response_data)
end

---Create JSON HTTP response
---@param status_code number HTTP status code
---@param data table Data to JSON encode
---@return string response Complete HTTP response
function M.create_json_response(status_code, data)
  local json_body = vim.json.encode(data)
  local status_text = status_code == 200 and "OK" or "Bad Request"
  
  local response_lines = {
    "HTTP/1.1 " .. status_code .. " " .. status_text,
    "Content-Type: application/json",
    "Content-Length: " .. #json_body,
    "Access-Control-Allow-Origin: *",
    "Access-Control-Allow-Methods: GET, POST, OPTIONS",
    "Access-Control-Allow-Headers: Content-Type, Accept, X-Claude-Code-IDE-Authorization, Mcp-Session-Id, Last-Event-ID",
  }
  
  -- Add session ID header if we have one
  if M.sse_session_id then
    table.insert(response_lines, "Mcp-Session-Id: " .. M.sse_session_id)
  end
  
  table.insert(response_lines, "")
  table.insert(response_lines, json_body)
  
  return table.concat(response_lines, "\r\n")
end

---Handle OPTIONS preflight request
---@return string response The HTTP response
function M.handle_options()
  local response_lines = {
    "HTTP/1.1 200 OK",
    "Access-Control-Allow-Origin: *",
    "Access-Control-Allow-Methods: GET, POST, OPTIONS",
    "Access-Control-Allow-Headers: Content-Type, Accept, X-Claude-Code-IDE-Authorization, Mcp-Session-Id, Last-Event-ID",
    "Access-Control-Max-Age: 86400",
    "Content-Length: 0",
    "",
    ""
  }
  return table.concat(response_lines, "\r\n")
end

---Send notification to SSE client
---@param method string The notification method
---@param params table The notification parameters
---@return boolean success
function M.send_notification(method, params)
  if not M.sse_client then
    return false
  end
  
  local notification = {
    jsonrpc = "2.0",
    method = method,
    params = params or vim.empty_dict()
  }
  
  -- Send as a notification event type
  return M.send_sse_event(M.sse_client, notification, "notification")
end

---Handle register endpoint for MCP protocol
---@param request string The HTTP request with headers and body
---@param server table The server instance
---@return string response The HTTP response
function M.handle_register(request, server)
  logger.debug("sse", "Handling /register request")
  
  -- Parse Content-Length header
  local content_length
  for line in request:gmatch("([^\r\n]+)") do
    local key, value = line:match("^([^:]+):%s*(.+)$")
    if key and key:lower() == "content-length" then
      content_length = value:match("^%s*(%d+)")
      break
    end
  end
  
  if not content_length then
    return M.create_json_response(400, {
      jsonrpc = "2.0",
      error = {
        code = -32700,
        message = "Parse error",
        data = "Missing Content-Length header"
      }
    })
  end
  
  -- Extract request body
  local body_start = request:find("\r\n\r\n")
  if not body_start then
    return M.create_json_response(400, {
      jsonrpc = "2.0",
      error = {
        code = -32700,
        message = "Parse error",
        data = "Malformed HTTP request"
      }
    })
  end
  
  local body = request:sub(body_start + 4)
  
  -- Parse JSON body
  local success, parsed = pcall(vim.json.decode, body)
  if not success then
    return M.create_json_response(200, {
      jsonrpc = "2.0",
      error = {
        code = -32700,
        message = "Parse error",
        data = "Invalid JSON"
      }
    })
  end
  
  -- For now, just acknowledge the registration
  -- In a full implementation, this would store client capabilities
  logger.debug("sse", "Client registration data:", vim.inspect(parsed))
  
  -- Return success response
  return M.create_json_response(200, {
    jsonrpc = "2.0",
    id = parsed.id,
    result = {
      sessionId = M.sse_session_id or utils.generate_uuid(),
      capabilities = server and server.state and server.state.capabilities or {}
    }
  })
end

---Clean up SSE client
---@param client_id string The client ID to clean up
function M.cleanup_client(client_id)
  if M.sse_client and M.sse_client.id == client_id then
    logger.debug("sse", "Cleaning up SSE client:", client_id)
    M.sse_client = nil
    M.sse_session_id = nil
  end
end

return M