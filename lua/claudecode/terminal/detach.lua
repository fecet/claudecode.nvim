--- Detach terminal provider for Claude Code Neovim integration.
-- This provider simulates terminal operations without actually creating terminals.
-- Used when the plugin is running in detached mode.
-- @module claudecode.terminal.detach

local M = {}

local logger = require("claudecode.logger")

--- Check if the detach provider is available
--- @return boolean available Always returns true since this is a no-op provider
function M.is_available()
  return true
end

--- Setup the detach provider
--- @param config table Configuration options (ignored in detach mode)
function M.setup(config)
  logger.debug("terminal", "Detach provider setup - terminal operations will be simulated")
end

--- Simulate opening a terminal
--- @param cmd_string string The command string (ignored)
--- @param env_table table Environment variables (ignored)
--- @param effective_config table Configuration options (ignored)
--- @param focus boolean|nil Whether to focus terminal (ignored)
function M.open(cmd_string, env_table, effective_config, focus)
  logger.debug("terminal", "Detach provider: simulating terminal open() - no terminal created")
end

--- Simulate closing a terminal
function M.close()
  logger.debug("terminal", "Detach provider: simulating terminal close() - no action taken")
end

--- Execute command using vim native methods instead of creating terminal
--- @param cmd_string string The command string to execute
--- @param env_table table Environment variables (applied to command execution)
--- @param effective_config table Configuration options (ignored in detach mode)
function M.simple_toggle(cmd_string, env_table, effective_config)
  logger.debug("terminal", "Detach provider: executing command using vim.system: " .. cmd_string)

  -- Parse command string into command and arguments
  local cmd_parts = vim.split(cmd_string, " ", { plain = true, trimempty = true })
  local cmd = cmd_parts[1]
  local args = {}
  for i = 2, #cmd_parts do
    table.insert(args, cmd_parts[i])
  end

  -- Prepare environment variables for vim.system
  local env = {}
  if env_table and next(env_table) then
    for key, value in pairs(env_table) do
      env[key] = tostring(value)
    end
  end

  -- Execute the command using vim.system
  -- This runs the command asynchronously without creating a terminal
  vim.system({ cmd, unpack(args) }, {
    env = env,
    text = true,
  }, function(result)
    -- Handle the result in a scheduled callback to ensure thread safety
    vim.schedule(function()
      if result.code == 0 then
        logger.debug("terminal", "Detach provider: command executed successfully")
        if result.stdout and result.stdout ~= "" then
          logger.debug("terminal", "Command output: " .. result.stdout)
        end
      else
        logger.warn("terminal", "Detach provider: command failed with exit code " .. result.code)
        if result.stderr and result.stderr ~= "" then
          logger.warn("terminal", "Command error output: " .. result.stderr)
        end
        -- Notify user of command failure
        vim.notify("Command failed: " .. cmd_string, vim.log.levels.WARN)
      end
    end)
  end)
end

--- Execute command using vim native methods (focus toggle behavior same as simple toggle in detach mode)
--- @param cmd_string string The command string to execute
--- @param env_table table Environment variables (applied to command execution)
--- @param effective_config table Configuration options (ignored in detach mode)
function M.focus_toggle(cmd_string, env_table, effective_config)
  -- In detach mode, focus_toggle behaves the same as simple_toggle since there's no terminal to focus
  M.simple_toggle(cmd_string, env_table, effective_config)
end

--- Execute command using vim native methods (legacy function - calls simple_toggle)
--- @param cmd_string string The command string to execute
--- @param env_table table Environment variables (applied to command execution)
--- @param effective_config table Configuration options (ignored in detach mode)
function M.toggle(cmd_string, env_table, effective_config)
  M.simple_toggle(cmd_string, env_table, effective_config)
end

--- Get active terminal buffer number (always returns nil in detach mode)
--- @return nil Always returns nil since no terminal exists
function M.get_active_bufnr()
  logger.debug("terminal", "Detach provider: get_active_bufnr() - returning nil (no terminal)")
  return nil
end

--- Get terminal instance for testing (always returns nil in detach mode)
--- @return nil Always returns nil since no terminal exists
function M._get_terminal_for_test()
  return nil
end

return M
