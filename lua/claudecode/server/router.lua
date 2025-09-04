---@brief HTTP request router for handling WebSocket, SSE, and REST endpoints
local logger = require("claudecode.logger")

local M = {}

---Parse HTTP request line and headers
---@param request string The raw HTTP request
---@return table|nil result Parsed request info or nil on error
function M.parse_http_request(request)
  -- Extract first line
  local first_line = request:match("^([^\r\n]+)")
  if not first_line then
    return nil
  end
  
  -- Parse method, path, and version
  local method, path, version = first_line:match("^(%S+)%s+(%S+)%s+(%S+)$")
  if not method or not path or not version then
    return nil
  end
  
  -- Parse headers (already lowercased for case-insensitive access)
  local headers = {}
  for line in request:gmatch("([^\r\n]+)") do
    if line ~= first_line then
      local key, value = line:match("^([^:]+):%s*(.+)$")
      if key and value then
        headers[key:lower()] = value
      end
    end
  end
  
  return {
    method = method,
    path = path,
    version = version,
    headers = headers,
    raw = request
  }
end

---Determine request type and route
---@param request_info table Parsed request info
---@param config table Server configuration
---@return string route_type One of: "websocket", "sse", "post", "options", "unknown"
---@return string|nil path The matched path if applicable
function M.determine_route(request_info, config)
  if not request_info then
    return "unknown", nil
  end
  
  local method = request_info.method
  local path = request_info.path
  local headers = request_info.headers
  
  -- Check for WebSocket upgrade
  if headers["upgrade"] and headers["upgrade"]:lower() == "websocket" then
    logger.debug("router", "WebSocket upgrade detected")
    return "websocket", path
  end
  
  -- Check for OPTIONS preflight
  if method == "OPTIONS" then
    logger.debug("router", "OPTIONS preflight request")
    return "options", path
  end
  
  -- Get SSE configuration
  local sse_enabled = config and config.sse and config.sse.enabled
  local sse_path = config and config.sse and config.sse.path or "/mcp"
  
  if sse_enabled then
    -- Check for SSE endpoint (GET request)
    if method == "GET" and (path == sse_path or path == "/sse") then
      logger.debug("router", "SSE connection request on path:", path)
      return "sse", path
    end
    
    -- Check for POST message endpoints
    -- Both /messages and /mcp can accept POST for JSON-RPC messages
    if method == "POST" and (path == "/messages" or path == sse_path or path == "/mcp") then
      logger.debug("router", "POST message request on path:", path)
      return "post", path
    end
    
    -- Check for register endpoint (MCP protocol)
    if method == "POST" and path == "/register" then
      logger.debug("router", "POST register request")
      return "register", path
    end
  end
  
  logger.debug("router", "Unknown request type - method:", method, "path:", path)
  return "unknown", path
end

---Check if request has complete body
---@param request string The raw HTTP request
---@return boolean complete
---@return string|nil body The request body if complete
function M.has_complete_body(request)
  local headers_end = request:find("\r\n\r\n")
  if not headers_end then
    return false, nil
  end
  
  -- Check for Content-Length header
  local content_length = request:match("Content%-Length:%s*(%d+)")
  if not content_length then
    -- No body expected
    return true, ""
  end
  
  content_length = tonumber(content_length)
  local body_start = headers_end + 4
  local current_body = request:sub(body_start)
  
  if #current_body >= content_length then
    return true, current_body:sub(1, content_length)
  end
  
  return false, nil
end

---Create 404 response
---@param path string|nil The requested path for better error message
---@return string response
function M.create_404_response(path)
  local body = "Not Found"
  if path then
    body = "Not Found: " .. path .. "\nSupported SSE endpoints: GET /mcp, POST /messages"
  end
  local response_lines = {
    "HTTP/1.1 404 Not Found",
    "Content-Type: text/plain",
    "Content-Length: " .. #body,
    "Connection: close",
    "",
    body
  }
  return table.concat(response_lines, "\r\n")
end

---Create 405 Method Not Allowed response
---@return string response
function M.create_405_response()
  local body = "Method Not Allowed"
  local response_lines = {
    "HTTP/1.1 405 Method Not Allowed",
    "Content-Type: text/plain",
    "Content-Length: " .. #body,
    "Connection: close",
    "",
    body
  }
  return table.concat(response_lines, "\r\n")
end

---Create 503 Service Unavailable response (for when SSE is disabled)
---@return string response
function M.create_503_response()
  local body = "SSE service not enabled"
  local response_lines = {
    "HTTP/1.1 503 Service Unavailable",
    "Content-Type: text/plain",
    "Content-Length: " .. #body,
    "Connection: close",
    "",
    body
  }
  return table.concat(response_lines, "\r\n")
end

return M