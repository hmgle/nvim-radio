-- Notification and debug logging helpers.
local M = {}

M.levels = {
  error = vim.log.levels.ERROR,
  warn = vim.log.levels.WARN,
  info = vim.log.levels.INFO,
  debug = vim.log.levels.DEBUG,
}

local prefix = "[radio] "

---@param msg string
---@param level integer|nil
local function notify(msg, level)
  if vim.in_fast_event() then
    vim.schedule(function()
      vim.notify(prefix .. msg, level or vim.log.levels.INFO)
    end)
  else
    vim.notify(prefix .. msg, level or vim.log.levels.INFO)
  end
end

---@param msg string
function M.error(msg)
  notify(msg, vim.log.levels.ERROR)
end

---@param msg string
function M.warn(msg)
  notify(msg, vim.log.levels.WARN)
end

---@param msg string
function M.info(msg)
  notify(msg, vim.log.levels.INFO)
end

---@param msg string
function M.debug(msg)
  local config = require("radio.config")
  if not config.options.debug then
    return
  end
  notify(msg, vim.log.levels.DEBUG)
end

---Wrap a message with an error prefix.
---@param msg string
function M.errorf(msg)
  M.error(msg)
end

return M
