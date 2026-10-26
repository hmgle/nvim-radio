-- Statusline component and status HUD.
local config = require("radio.config")
local util = require("radio.util")

local Status = {}

local ICONS = {
  idle = "○",
  connecting = "◌",
  playing = "♪",
  paused = "‖",
  reconnecting = "↻",
  failed = "✗",
  recording = "●",
}

---Compact statusline string.
---@param engine table|nil
---@return string
function Status.statusline(engine)
  if not engine then
    return ""
  end
  local status = engine.status
  local parts = {}
  local state = status.playback_state
  if status.recording_state == "recording" or status.recording_state == "probing" then
    parts[#parts + 1] = ICONS.recording .. util.fmt_duration(status.recording_ms)
  end
  if state == "idle" and #parts == 0 then
    return "radio ○"
  end
  local name = status.station and status.station.name or "?"
  local title = status.title ~= "" and (" - " .. status.title) or ""
  parts[#parts + 1] = (ICONS[state] or "○") .. " " .. name .. title
  parts[#parts + 1] = status.volume .. "%" .. (status.muted and " 🔇" or "")
  return util.display_line("radio " .. table.concat(parts, "  "))
end

---Open a floating HUD with the full playback/recording status.
---@param engine table
function Status.hud(engine)
  if not engine then
    return
  end
  if Status.win and vim.api.nvim_win_is_valid(Status.win) then
    vim.api.nvim_win_close(Status.win, true)
  end
  local status = engine.status
  local lines = util.display_lines({
    "station:  " .. (status.station and status.station.name or "-"),
    "title:    " .. (status.title ~= "" and status.title or "-"),
    "state:    " .. status.playback_state,
    "volume:   " .. status.volume .. (status.muted and " (muted)" or ""),
    "recording: "
      .. status.recording_state
      .. (status.recording_ms > 0 and (" " .. util.fmt_duration(status.recording_ms)) or ""),
    "path:     " .. (status.recording_path ~= "" and status.recording_path or "-"),
    "source:   " .. (status.source_url ~= "" and status.source_url or "-"),
    "",
    "message:  " .. status.message,
  })
  local width = math.max(1, math.min(vim.o.columns - 2, 72, math.floor(vim.o.columns * 0.5)))
  local height = math.max(1, math.min(#lines, vim.o.lines - 3))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(1, math.floor((vim.o.columns - width) / 2) - 1),
    width = width,
    height = height,
    style = "minimal",
    border = config.options.ui.border,
    title = " nvim-radio status ",
    title_pos = "center",
    zindex = 50,
  })
  Status.win = win
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if Status.win == win then
        Status.win = nil
      end
    end,
  })
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })
  return buf, win
end

return Status
