--- Detach terminal provider for Claude Code Neovim integration.
-- This provider simulates terminal operations without actually creating terminals.
-- Used when the plugin is running in detached mode.
-- @module claudecode.terminal.detach

local M = {}

local logger = require("claudecode.logger")

-- State tracking for the detach provider
local current_process = nil -- SystemObj returned by vim.system

-- Setup autocmd for process cleanup on Neovim exit (only once)
local function setup_exit_cleanup()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("ClaudeCodeDetachCleanup", { clear = true }),
    callback = function()
      if current_process then
        logger.debug("terminal", "Detach provider: cleaning up process on Neovim exit (PID: " .. current_process.pid .. ")")
        current_process:kill(15) -- Send SIGTERM for graceful shutdown
      end
    end,
    desc = "Clean up detach provider processes when exiting Neovim",
  })
  logger.debug("terminal", "Detach provider: exit cleanup autocmd registered")
end

--- Check if the detach provider is available
--- @return boolean available Always returns true since this is a no-op provider
function M.is_available()
  return true
end

--- Setup the detach provider
--- @param config table Configuration options (ignored in detach mode)
function M.setup(config)
  setup_exit_cleanup() -- Setup cleanup once during initialization
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

--- Close/terminate the running process
function M.close()
  if current_process then
    logger.debug("terminal", "Detach provider: terminating process (PID: " .. current_process.pid .. ")")
    current_process:kill(15) -- Send SIGTERM for graceful shutdown
    current_process = nil
  else
    logger.debug("terminal", "Detach provider: close() - no active process to terminate")
  end
end

--- Execute command using vim native methods instead of creating terminal
--- @param cmd_string string The command string to execute
--- @param env_table table Environment variables (applied to command execution)
--- @param effective_config table Configuration options (supports auto_close)
function M.toggle(cmd_string, env_table, effective_config)
  -- If there's already a running process, kill it first (toggle behavior)
  if current_process then
    logger.debug("terminal", "Detach provider: stopping existing process (PID: " .. current_process.pid .. ")")
    current_process:kill(9) -- Force kill the process
    current_process = nil
    return
  end

  logger.debug("terminal", "Detach provider: executing command using vim.system: " .. cmd_string)

  -- Parse command string into command and arguments
  local cmd_parts = vim.split(cmd_string, " ", { plain = true, trimempty = true })

  -- Prepare environment variables for vim.system
  local env = {}
  if env_table and next(env_table) then
    for key, value in pairs(env_table) do
      env[key] = tostring(value)
    end
  end

  -- Execute the command using vim.system
  current_process = vim.system(cmd_parts, {
    env = env,
    text = true,
  }, function(result)
    -- Handle the result in a scheduled callback to ensure thread safety
    vim.schedule(function()
      -- Clear process tracking when command completes
      current_process = nil

      if result.code == 0 then
        logger.debug("terminal", "Detach provider: command executed successfully")
        if result.stdout and result.stdout ~= "" then
          logger.debug("terminal", "Command output: " .. result.stdout)
        end

        -- Handle auto_close behavior - refresh file status if enabled
        if effective_config and effective_config.auto_close then
          logger.debug("terminal", "Detach provider: auto_close enabled, command completed successfully")
          vim.cmd.checktime() -- Refresh file status to reflect any changes
        end
      else
        logger.warn("terminal", "Detach provider: command failed with exit code " .. result.code)
        if result.stderr and result.stderr ~= "" then
          logger.warn("terminal", "Command error output: " .. result.stderr)
        end
        vim.notify("Command failed: " .. cmd_string, vim.log.levels.WARN)

        -- Even for failed commands, refresh file status in case partial changes were made
        if effective_config and effective_config.auto_close then
          vim.cmd.checktime()
        end
      end
    end)
  end)

  -- Log process start
  if current_process and current_process.pid then
    logger.debug("terminal", "Detach provider: started process with PID: " .. current_process.pid)
  else
    logger.warn("terminal", "Detach provider: failed to get process ID from vim.system")
    current_process = nil
  end
end

-- Alias functions for compatibility (all behave the same in detach mode)
M.simple_toggle = M.toggle
M.focus_toggle = M.toggle

--- Get active process ID (returns PID if process is running, nil otherwise)
--- @return number|nil Process ID if a process is running, nil otherwise
function M.get_active_bufnr()
  if current_process then
    logger.debug("terminal", "Detach provider: get_active_bufnr() - returning PID: " .. current_process.pid)
    return current_process.pid
  else
    logger.debug("terminal", "Detach provider: get_active_bufnr() - no active process")
    return nil
  end
end

--- Get process information for testing
--- @return table|nil Process information if running, nil otherwise
function M._get_terminal_for_test()
  if current_process then
    return {
      pid = current_process.pid,
      process = current_process,
      buf = nil,    -- No buffer in detach mode
      win = nil,    -- No window in detach mode
    }
  end
  return nil
end

return M
