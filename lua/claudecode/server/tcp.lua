---@brief TCP server implementation using vim.loop
local client_manager = require("claudecode.server.client")
local utils = require("claudecode.server.utils")
local router = require("claudecode.server.router")
local sse = require("claudecode.server.sse")
local handshake = require("claudecode.server.handshake")
local logger = require("claudecode.logger")

local M = {}

---@class TCPServer
---@field server table The vim.loop TCP server handle
---@field port number The port the server is listening on
---@field auth_token string|nil The authentication token for validating connections
---@field clients table<string, WebSocketClient> Table of connected clients
---@field on_message function Callback for WebSocket messages
---@field on_connect function Callback for new connections
---@field on_disconnect function Callback for client disconnections
---@field on_error fun(err_msg: string) Callback for errors

---Find an available port by attempting to bind
---@param min_port number Minimum port to try
---@param max_port number Maximum port to try
---@return number|nil port Available port number, or nil if none found
function M.find_available_port(min_port, max_port)
  if min_port > max_port then
    return nil -- Or handle error appropriately
  end

  local ports = {}
  for i = min_port, max_port do
    table.insert(ports, i)
  end

  -- Shuffle the ports
  utils.shuffle_array(ports)

  -- Try to bind to a port from the shuffled list
  for _, port in ipairs(ports) do
    local test_server = vim.loop.new_tcp()
    if test_server then
      local success = test_server:bind("127.0.0.1", port)
      test_server:close()

      if success then
        return port
      end
    end
    -- Continue to next port if test_server creation failed or bind failed
  end

  return nil
end

---Create and start a TCP server
---@param config ClaudeCodeConfig Server configuration
---@param callbacks table Callback functions
---@param auth_token string|nil Authentication token for validating connections
---@return TCPServer|nil server The server object, or nil on error
---@return string|nil error Error message if failed
function M.create_server(config, callbacks, auth_token)
  local port = M.find_available_port(config.port_range.min, config.port_range.max)
  if not port then
    return nil, "No available ports in range " .. config.port_range.min .. "-" .. config.port_range.max
  end

  local tcp_server = vim.loop.new_tcp()
  if not tcp_server then
    return nil, "Failed to create TCP server"
  end

  -- Create server object
  local server = {
    server = tcp_server,
    port = port,
    auth_token = auth_token,
    clients = {},
    config = config,  -- Store config for SSE routing
    on_message = callbacks.on_message or function() end,
    on_connect = callbacks.on_connect or function() end,
    on_disconnect = callbacks.on_disconnect or function() end,
    on_error = callbacks.on_error or function() end,
    server_instance = callbacks.server_instance, -- Reference to main server for SSE handlers
  }

  local bind_success, bind_err = tcp_server:bind("127.0.0.1", port)
  if not bind_success then
    tcp_server:close()
    return nil, "Failed to bind to port " .. port .. ": " .. (bind_err or "unknown error")
  end

  -- Start listening
  local listen_success, listen_err = tcp_server:listen(128, function(err)
    if err then
      callbacks.on_error("Listen error: " .. err)
      return
    end

    M._handle_new_connection(server)
  end)

  if not listen_success then
    tcp_server:close()
    return nil, "Failed to listen on port " .. port .. ": " .. (listen_err or "unknown error")
  end

  return server, nil
end

---Handle a new client connection with routing
---@param server TCPServer The server object
function M._handle_new_connection(server)
  local client_tcp = vim.loop.new_tcp()
  if not client_tcp then
    server.on_error("Failed to create client TCP handle")
    return
  end

  local accept_success, accept_err = server.server:accept(client_tcp)
  if not accept_success then
    server.on_error("Failed to accept connection: " .. (accept_err or "unknown error"))
    client_tcp:close()
    return
  end

  -- Create client wrapper
  local client = client_manager.create_client(client_tcp)
  server.clients[client.id] = client
  
  -- Flag to track if we've determined the connection type
  client.route_determined = false
  
  -- Set up data handler with routing logic
  client_tcp:read_start(function(err, data)
    if err then
      server.on_error("Client read error: " .. err)
      M._remove_client(server, client)
      return
    end

    if not data then
      -- EOF - client disconnected
      M._remove_client(server, client)
      if client.client_type == "sse" then
        sse.cleanup_client(client.id)
      end
      return
    end
    
    -- Buffer incoming data
    client.buffer = (client.buffer or "") .. data
    
    -- If route not determined yet, try to parse HTTP request
    if not client.route_determined then
      -- Check if we have complete headers
      local headers_complete, request, remaining = handshake.extract_http_request(client.buffer)
      
      if headers_complete and request then
        -- Parse and route the request
        local request_info = router.parse_http_request(request)
        local route_type, path = router.determine_route(request_info, server.config)
        
        logger.debug("tcp", "Route determined for client " .. client.id .. ": " .. route_type)
        client.route_determined = true
        
        if route_type == "websocket" then
          -- Handle as WebSocket - use existing flow
          client.client_type = "websocket"
          -- Store callback for WebSocket handshake success
          client.on_ws_connected = function()
            server.on_connect(client)
          end
          client_manager.process_data(client, "", function(cl, message)
            server.on_message(cl, message)
          end, function(cl, code, reason)
            server.on_disconnect(cl, code, reason)
            M._remove_client(server, cl)
          end, function(cl, error_msg)
            server.on_error("Client " .. cl.id .. " error: " .. error_msg)
            M._remove_client(server, cl)
          end, server.auth_token)
          
        elseif route_type == "sse" then
          -- Handle SSE connection
          client.client_type = "sse"
          local success, response = sse.handle_sse_connect(client, request)
          client_tcp:write(response, function(write_err)
            if write_err then
              logger.error("tcp", "Failed to send SSE response:", write_err)
              M._remove_client(server, client)
            else
              -- SSE connection established
              client.state = "connected"
              client.buffer = remaining
              server.on_connect(client)
              
              -- Start SSE heartbeat timer for this client
              M._start_sse_heartbeat(server, client)
            end
          end)
          
        elseif route_type == "post" then
          -- Handle POST request for messages
          client.client_type = "http_post"
          
          -- Check if we have complete body
          local body_complete, body = router.has_complete_body(client.buffer)
          if body_complete then
            local response = sse.handle_post_message(client.buffer, server.server_instance)
            client_tcp:write(response, function(write_err)
              if write_err then
                logger.error("tcp", "Failed to send POST response:", write_err)
              end
              -- Close connection after response
              M._remove_client(server, client)
            end)
          end
          
        elseif route_type == "register" then
          -- Handle POST request for /register
          client.client_type = "http_register"
          
          -- Check if we have complete body
          local body_complete, body = router.has_complete_body(client.buffer)
          if body_complete then
            local response = sse.handle_register(client.buffer, server.server_instance)
            client_tcp:write(response, function(write_err)
              if write_err then
                logger.error("tcp", "Failed to send register response:", write_err)
              end
              -- Close connection after response
              M._remove_client(server, client)
            end)
          end
          
        elseif route_type == "options" then
          -- Handle OPTIONS preflight
          client.client_type = "http_options"
          local response = sse.handle_options()
          client_tcp:write(response, function(write_err)
            if write_err then
              logger.error("tcp", "Failed to send OPTIONS response:", write_err)
            end
            -- Close connection after response
            M._remove_client(server, client)
          end)
          
        else
          -- Unknown route - send 404 with path info
          client.client_type = "http_unknown"
          local response = router.create_404_response(path)
          client_tcp:write(response, function(write_err)
            if write_err then
              logger.error("tcp", "Failed to send 404 response:", write_err)
            end
            -- Close connection after response
            M._remove_client(server, client)
          end)
        end
      end
      
    else
      -- Route already determined, handle based on client type
      if client.client_type == "websocket" then
        -- Continue processing WebSocket data
        client_manager.process_data(client, "", function(cl, message)
          server.on_message(cl, message)
        end, function(cl, code, reason)
          server.on_disconnect(cl, code, reason)
          M._remove_client(server, cl)
        end, function(cl, error_msg)
          server.on_error("Client " .. cl.id .. " error: " .. error_msg)
          M._remove_client(server, cl)
        end, server.auth_token)
        
      elseif client.client_type == "http_post" then
        -- Continue buffering POST body if needed
        local body_complete = router.has_complete_body(client.buffer)
        if body_complete then
          local response = sse.handle_post_message(client.buffer, server.server_instance)
          client_tcp:write(response, function(write_err)
            if write_err then
              logger.error("tcp", "Failed to send POST response:", write_err)
            end
            -- Close connection after response
            M._remove_client(server, client)
          end)
        end
      elseif client.client_type == "http_register" then
        -- Continue buffering register body if needed
        local body_complete = router.has_complete_body(client.buffer)
        if body_complete then
          local response = sse.handle_register(client.buffer, server.server_instance)
          client_tcp:write(response, function(write_err)
            if write_err then
              logger.error("tcp", "Failed to send register response:", write_err)
            end
            -- Close connection after response
            M._remove_client(server, client)
          end)
        end
      end
      -- SSE connections stay open, no additional processing needed
    end
  end)
end

---Remove a client from the server
---@param server TCPServer The server object
---@param client WebSocketClient The client to remove
function M._remove_client(server, client)
  if server.clients[client.id] then
    server.clients[client.id] = nil
    
    -- Clean up SSE client and heartbeat timer if needed
    if client.client_type == "sse" then
      sse.cleanup_client(client.id)
      if client.heartbeat_timer then
        client.heartbeat_timer:stop()
        client.heartbeat_timer:close()
        client.heartbeat_timer = nil
      end
    end

    if not client.tcp_handle:is_closing() then
      client.tcp_handle:close()
    end
  end
end

---Send a message to a specific client
---@param server TCPServer The server object
---@param client_id string The client ID
---@param message string The message to send
---@param callback function|nil Optional callback
function M.send_to_client(server, client_id, message, callback)
  local client = server.clients[client_id]
  if not client then
    if callback then
      callback("Client not found: " .. client_id)
    end
    return
  end

  client_manager.send_message(client, message, callback)
end

---Broadcast a message to all connected clients
---@param server TCPServer The server object
---@param message string The message to broadcast
function M.broadcast(server, message)
  for _, client in pairs(server.clients) do
    client_manager.send_message(client, message)
  end
end

---Get the number of connected clients
---@param server TCPServer The server object
---@return number count Number of connected clients
function M.get_client_count(server)
  local count = 0
  for _ in pairs(server.clients) do
    count = count + 1
  end
  return count
end

---Get information about all clients
---@param server TCPServer The server object
---@return table clients Array of client information
function M.get_clients_info(server)
  local clients = {}
  for _, client in pairs(server.clients) do
    table.insert(clients, client_manager.get_client_info(client))
  end
  return clients
end

---Close a specific client connection
---@param server TCPServer The server object
---@param client_id string The client ID
---@param code number|nil Close code
---@param reason string|nil Close reason
function M.close_client(server, client_id, code, reason)
  local client = server.clients[client_id]
  if client then
    client_manager.close_client(client, code, reason)
  end
end

---Stop the TCP server
---@param server TCPServer The server object
function M.stop_server(server)
  -- Close all clients
  for _, client in pairs(server.clients) do
    client_manager.close_client(client, 1001, "Server shutting down")
  end

  -- Clear clients
  server.clients = {}

  -- Close server
  if server.server and not server.server:is_closing() then
    server.server:close()
  end
end

---Start a periodic ping task to keep connections alive
---@param server TCPServer The server object
---@param interval number Ping interval in milliseconds (default: 30000)
---@return table? timer The timer handle, or nil if creation failed
function M.start_ping_timer(server, interval)
  interval = interval or 30000 -- 30 seconds

  local timer = vim.loop.new_timer()
  if not timer then
    server.on_error("Failed to create ping timer")
    return nil
  end

  timer:start(interval, interval, function()
    for _, client in pairs(server.clients) do
      if client.state == "connected" and client.client_type == "websocket" then
        -- Check if client is alive (only for WebSocket clients)
        if client_manager.is_client_alive(client, interval * 2) then
          client_manager.send_ping(client, "ping")
        else
          -- Client appears dead, close it
          server.on_error("Client " .. client.id .. " appears dead, closing")
          client_manager.close_client(client, 1006, "Connection timeout")
          M._remove_client(server, client)
        end
      end
    end
  end)

  return timer
end

---Start SSE heartbeat for a specific client
---@param server TCPServer The server object
---@param client table The SSE client
function M._start_sse_heartbeat(server, client)
  -- Create a timer specific to this SSE client
  local heartbeat_timer = vim.loop.new_timer()
  if not heartbeat_timer then
    return
  end
  
  -- Store timer reference on client
  client.heartbeat_timer = heartbeat_timer
  
  -- Send heartbeat comment every 30 seconds
  heartbeat_timer:start(30000, 30000, function()
    if client.state == "connected" and client.client_type == "sse" then
      -- Send SSE comment as heartbeat
      local heartbeat = ":\n\n"  -- SSE comment line
      client.tcp_handle:write(heartbeat, function(err)
        if err then
          logger.debug("tcp", "SSE heartbeat failed for client:", client.id, err)
          -- Stop timer and remove client on error
          if client.heartbeat_timer then
            client.heartbeat_timer:stop()
            client.heartbeat_timer:close()
            client.heartbeat_timer = nil
          end
          M._remove_client(server, client)
        end
      end)
    else
      -- Client disconnected, stop timer
      if client.heartbeat_timer then
        client.heartbeat_timer:stop()
        client.heartbeat_timer:close()
        client.heartbeat_timer = nil
      end
    end
  end)
end

return M
