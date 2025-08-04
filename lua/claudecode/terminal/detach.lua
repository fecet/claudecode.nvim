--- Detach terminal provider for Claude Code Neovim integration.
-- This provider simulates terminal operations without actually creating terminals.
-- Used when the plugin is running in detached mode.
-- @module claudecode.terminal.detach

local M = {}

local logger = require("claudecode.logger")

-- State tracking for the detach provider
local current_process = nil -- SystemObj returned by vim.system
local current_pid = nil     -- Process ID for tracking
local autocmd_id = nil      -- Autocmd ID for cleanup on exit

--- Setup autocmd for process cleanup on Neovim exit
local function setup_exit_cleanup()
  if autocmd_id then
    return -- Already set up
  end

  autocmd_id = vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("ClaudeCodeDetachCleanup", { clear = true }),
    callback = function()
      if current_process and current_pid then
        logger.debug("terminal", "Detach provider: cleaning up process on Neovim exit (PID: " .. current_pid .. ")")
        current_process:kill(15) -- Send SIGTERM for graceful shutdown
        current_process = nil
        current_pid = nil
      end
    end,
    desc = "Clean up detach provider processes when exiting Neovim",
  })

  logger.debug("terminal", "Detach provider: exit cleanup autocmd registered")
end

--- Remove the exit cleanup autocmd
local function remove_exit_cleanup()
  if autocmd_id then
    vim.api.nvim_del_autocmd(autocmd_id)
    autocmd_id = nil
    logger.debug("terminal", "Detach provider: exit cleanup autocmd removed")
  end
end

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

--- Close/terminate the running process
function M.close()
  if current_process and current_pid then
    logger.debug("terminal", "Detach provider: terminating process (PID: " .. current_pid .. ")")
    current_process:kill(15) -- Send SIGTERM first for graceful shutdown
    current_process = nil
    current_pid = nil

    -- Remove exit cleanup since we manually closed the process
    remove_exit_cleanup()
  else
    logger.debug("terminal", "Detach provider: close() - no active process to terminate")
  end
end

--- Execute command using vim native methods instead of creating terminal
--- @param cmd_string string The command string to execute
--- @param env_table table Environment variables (applied to command execution)
--- @param effective_config table Configuration options (supports auto_close)
function M.simple_toggle(cmd_string, env_table, effective_config)
  -- If there's already a running process, kill it first (toggle behavior)
  if current_process and current_pid then
    logger.debug("terminal", "Detach provider: stopping existing process (PID: " .. current_pid .. ")")
    current_process:kill(9) -- Force kill the process
    current_process = nil
    current_pid = nil

    -- Remove exit cleanup since we manually stopped the process
    remove_exit_cleanup()
    return
  end

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
  -- Build the full command array
  local full_cmd = { cmd }
  for _, arg in ipairs(args) do
    table.insert(full_cmd, arg)
  end

  current_process = vim.system(full_cmd, {
    env = env,
    text = true,
  }, function(result)
    -- Handle the result in a scheduled callback to ensure thread safety
    vim.schedule(function()
      -- Clear process tracking when command completes
      current_process = nil
      current_pid = nil

      -- Remove exit cleanup since process is done
      remove_exit_cleanup()

      if result.code == 0 then
        logger.debug("terminal", "Detach provider: command executed successfully")
        if result.stdout and result.stdout ~= "" then
          logger.debug("terminal", "Command output: " .. result.stdout)
        end

        -- Handle auto_close behavior - close/cleanup if enabled
        if effective_config and effective_config.auto_close then
          logger.debug("terminal", "Detach provider: auto_close enabled, command completed successfully")
          -- In detach mode, there's no terminal window to close, but we can refresh file status
          -- This ensures any file changes made by the command are reflected in Neovim
          vim.cmd.checktime()
        end
      else
        logger.warn("terminal", "Detach provider: command failed with exit code " .. result.code)
        if result.stderr and result.stderr ~= "" then
          logger.warn("terminal", "Command error output: " .. result.stderr)
        end
        -- Notify user of command failure
        vim.notify("Command failed: " .. cmd_string, vim.log.levels.WARN)

        -- Handle auto_close behavior for failed commands
        if effective_config and effective_config.auto_close then
          logger.error("terminal", "Detach provider: command exited with code " .. result.code .. ". Check for any errors.")
          -- Even for failed commands, refresh file status in case partial changes were made
          vim.cmd.checktime()
        end
      end
    end)
  end)

  -- Store the process ID for tracking
  if current_process and current_process.pid then
    current_pid = current_process.pid
    logger.debug("terminal", "Detach provider: started process with PID: " .. current_pid)

    -- Set up exit cleanup when we start a process
    setup_exit_cleanup()
  else
    -- If we couldn't get the PID, clean up and log error
    logger.warn("terminal", "Detach provider: failed to get process ID from vim.system")
    current_process = nil
    current_pid = nil
  end
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

--- Get active process ID (returns PID if process is running, nil otherwise)
--- @return number|nil Process ID if a process is running, nil otherwise
function M.get_active_bufnr()
  if current_pid then
    logger.debug("terminal", "Detach provider: get_active_bufnr() - returning PID: " .. current_pid)
    return current_pid
  else
    logger.debug("terminal", "Detach provider: get_active_bufnr() - no active process")
    return nil
  end
end

--- Get process information for testing
--- @return table|nil Process information if running, nil otherwise
function M._get_terminal_for_test()
  if current_process and current_pid then
    return {
      pid = current_pid,
      process = current_process,
      buf = nil,    -- No buffer in detach mode
      win = nil,    -- No window in detach mode
    }
  end
  return nil
end

return M
