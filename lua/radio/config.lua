-- Configuration: defaults, validation, and path resolution.
local M = {}

M.defaults = {
  -- External programs.
  mpv = "mpv",
  ffmpeg = "ffmpeg",
  ffprobe = "ffprobe",
  -- Playback.
  volume = 80,
  normalize_loudness = false,
  audio_device = nil,
  playback_timeout_secs = 12,
  resume = false, -- false | true | "selection"
  -- Catalog / network.
  api_url = nil,
  connect_timeout_secs = 5,
  request_timeout_secs = 20,
  auto_sync_days = 7, -- 0 disables background sync
  -- Recording.
  recording_dir = nil, -- default: <data_dir>/recordings
  probe_timeout_secs = 5,
  recording_min_free_mb = 16,
  -- Interface.
  debug = false,
  single_instance = true,
  data_dir = nil, -- default: $XDG_DATA_HOME/nvim-radio
  keys = {
    toggle = nil,
    pause = nil,
    mute = nil,
    volume_up = nil,
    volume_down = nil,
    record = nil,
    status = nil,
    random = nil,
    stop = nil,
  },
  ui = {
    width = 0.8,
    height = 0.8,
    border = "rounded",
    title = " nvim-radio ",
    preview = true,
  },
}

M.options = vim.deepcopy(M.defaults)

local function home()
  return vim.uv.os_homedir() or "~"
end

---Resolve the data directory, honoring $NVIM_RADIO_DATA_DIR (tests) then XDG.
---@return string
function M.resolve_data_dir()
  local env = vim.env
  local override = env.NVIM_RADIO_DATA_DIR
  if override and override ~= "" then
    return vim.fs.normalize(override)
  end
  local base = env.XDG_DATA_HOME
  if not base or base == "" then
    base = home() .. "/.local/share"
  end
  return vim.fs.normalize(base .. "/nvim-radio")
end

---Merge user options into defaults, validate, and create directories.
---@param opts table|nil
function M.setup(opts)
  if opts ~= nil and type(opts) ~= "table" then
    error("nvim-radio: invalid settings: options (table)", 0)
  end
  local o = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  local invalid = {}
  local function check(cond, key)
    if not cond then
      invalid[#invalid + 1] = key
    end
  end
  check(type(o.volume) == "number" and o.volume >= 0 and o.volume <= 100, "volume (0-100)")
  check(type(o.mpv) == "string" and o.mpv ~= "", "mpv")
  check(type(o.ffmpeg) == "string" and o.ffmpeg ~= "", "ffmpeg")
  check(type(o.ffprobe) == "string" and o.ffprobe ~= "", "ffprobe")
  check(
    type(o.connect_timeout_secs) == "number"
      and o.connect_timeout_secs >= 1
      and o.connect_timeout_secs <= 300,
    "connect_timeout_secs (1-300)"
  )
  check(
    type(o.request_timeout_secs) == "number"
      and o.request_timeout_secs >= 1
      and o.request_timeout_secs <= 300,
    "request_timeout_secs (1-300)"
  )
  check(
    type(o.playback_timeout_secs) == "number"
      and o.playback_timeout_secs >= 1
      and o.playback_timeout_secs <= 300,
    "playback_timeout_secs (1-300)"
  )
  check(
    type(o.probe_timeout_secs) == "number"
      and o.probe_timeout_secs >= 1
      and o.probe_timeout_secs <= 300,
    "probe_timeout_secs (1-300)"
  )
  check(
    type(o.recording_min_free_mb) == "number" and o.recording_min_free_mb >= 1,
    "recording_min_free_mb (>=1)"
  )
  check(
    o.resume == false or o.resume == true or o.resume == "selection",
    'resume (false | true | "selection")'
  )
  check(
    o.audio_device == nil or (type(o.audio_device) == "string" and not o.audio_device:find("[%c]")),
    "audio_device (no control characters)"
  )
  check(type(o.auto_sync_days) == "number" and o.auto_sync_days >= 0, "auto_sync_days (>=0)")
  for _, key in ipairs({ "api_url", "data_dir", "recording_dir" }) do
    check(
      o[key] == nil or (type(o[key]) == "string" and o[key] ~= "" and not o[key]:find("[%c]")),
      key
    )
  end
  if type(o.api_url) == "string" then
    check(require("radio.util").validate_url(o.api_url), "api_url (http(s) URL)")
  end
  for _, key in ipairs({ "normalize_loudness", "debug", "single_instance" }) do
    check(type(o[key]) == "boolean", key .. " (boolean)")
  end
  check(type(o.keys) == "table", "keys (table)")
  if type(o.keys) == "table" then
    for key, lhs in pairs(o.keys) do
      check(type(lhs) == "string" and lhs ~= "", "keys." .. key .. " (nonempty string)")
    end
  end
  check(type(o.ui) == "table", "ui (table)")
  if type(o.ui) == "table" then
    for _, key in ipairs({ "width", "height" }) do
      check(
        type(o.ui[key]) == "number" and o.ui[key] > 0 and o.ui[key] <= 1,
        "ui." .. key .. " (0-1)"
      )
    end
    check(type(o.ui.preview) == "boolean", "ui.preview (boolean)")
    check(type(o.ui.title) == "string", "ui.title (string)")
    local border = o.ui.border
    local valid_border = type(border) == "string"
      and vim.tbl_contains({ "none", "single", "double", "rounded", "solid", "shadow" }, border)
    if type(border) == "table" then
      valid_border = vim.tbl_contains({ 0, 1, 2, 4, 8 }, #border)
      for _, entry in ipairs(border) do
        valid_border = valid_border
          and (type(entry) == "string" or (type(entry) == "table" and type(entry[1]) == "string"))
      end
    end
    check(valid_border, "ui.border")
  end
  -- Reject NaN and infinities before downstream arithmetic or subprocess flags.
  for key, value in pairs(o) do
    if type(value) == "number" then
      check(
        value == value and value ~= math.huge and value ~= -math.huge,
        key .. " (finite number)"
      )
    end
  end
  if #invalid > 0 then
    error("nvim-radio: invalid settings: " .. table.concat(invalid, ", "), 0)
  end

  o.data_dir = o.data_dir and vim.fs.normalize(o.data_dir) or M.resolve_data_dir()
  o.runtime_dir = o.data_dir .. "/run"
  o.db_path = o.data_dir .. "/radio.db"
  o.recording_dir = o.recording_dir and vim.fs.normalize(o.recording_dir)
    or (o.data_dir .. "/recordings")
  M.options = o
  M.prepare()
  return M.options
end

---Create the data, runtime, and recording directories.
function M.prepare()
  local o = M.options
  for _, dir in ipairs({ o.data_dir, o.runtime_dir, o.recording_dir }) do
    local ok, err = pcall(vim.fn.mkdir, dir, "p", 448)
    if not ok then
      error("nvim-radio: cannot create " .. dir .. ": " .. tostring(err), 0)
    end
  end
end

---Apply defaults when the user never called setup().
---@return table
function M.ensure()
  if not M.options.data_dir then
    M.setup(nil)
  end
  return M.options
end

return M
