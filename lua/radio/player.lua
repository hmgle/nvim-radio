-- mpv playback over its JSON IPC socket, driven by libuv.
local http = require("radio.http")
local log = require("radio.log")
local util = require("radio.util")

local Player = {}
Player.__index = Player

local SOCKET_PATH_LIMIT = 100

---@return string
local function random_suffix(n)
  local chars = "0123456789abcdef"
  local out = {}
  for i = 1, n do
    out[i] = chars:sub(math.random(1, #chars), math.random(1, #chars))
  end
  return table.concat(out)
end

---mpv command line, mirroring radio-cli's playback_command.
---@param opts table
---@param socket string
---@return string[]
local function playback_args(opts, socket)
  local args = {
    "--no-config",
    "--load-scripts=no",
    "--no-video",
    "--no-audio-display",
    "--terminal=no",
    "--input-default-bindings=no",
    "--idle=yes",
    "--keep-open=no",
    "--cache=yes",
    "--cache-secs=3",
    "--demuxer-max-bytes=2097152",
    "--demuxer-max-back-bytes=524288",
    "--demuxer-donate-buffer=no",
    "--audio-buffer=0.2",
    "--user-agent=" .. http.USER_AGENT,
    "--volume=" .. tostring(opts.volume or 80),
    "--network-timeout=" .. tostring(opts.playback_timeout_secs or 12),
    "--input-ipc-server=" .. socket,
  }
  if opts.normalize_loudness then
    args[#args + 1] = "--af=dynaudnorm=f=150:g=5"
  end
  if opts.audio_device and opts.audio_device:gsub("%s", "") ~= "" then
    args[#args + 1] = "--audio-device=" .. opts.audio_device
  end
  return args
end

---@param runtime_dir string
---@return string|nil socket, string|nil err
local function socket_path(runtime_dir)
  local id = random_suffix(12)
  local primary = runtime_dir .. "/mpv-" .. id .. ".sock"
  if #primary <= SOCKET_PATH_LIMIT then
    return primary
  end
  local fallback = vim.uv.os_tmpdir() .. "/mpv-" .. random_suffix(32) .. ".sock"
  if #fallback <= SOCKET_PATH_LIMIT then
    return fallback
  end
  return nil, "runtime_path_too_long"
end

---Clean an ICY/metadata title: strip control characters and trim.
---@param title string|nil
---@return string
local function metadata_title(title)
  if type(title) ~= "string" then
    return ""
  end
  return util.trim(util.clean_text(title))
end

---Spawn mpv, connect the IPC socket, and start loading `url`.
---@param opts table {mpv, volume, playback_timeout_secs, normalize_loudness, audio_device, runtime_dir, url, is_local}
---@param on_event fun(event: table)
---@param cb fun(err: string|nil, player: table|nil)
---@return table|nil player
function Player.start(opts, on_event, cb)
  local socket, socket_err = socket_path(opts.runtime_dir)
  if not socket then
    cb(socket_err, nil)
    return nil
  end
  if opts.normalize_loudness and not Player.supports_normalization(opts.mpv) then
    cb("normalization_unavailable", nil)
    return nil
  end
  local args = playback_args(opts, socket)
  local self = setmetatable({
    socket = socket,
    on_event = on_event,
    buffer = "",
    audio_device = opts.audio_device,
    closing = false,
    _url = opts.url,
  }, Player)

  local handle, pid = vim.uv.spawn(opts.mpv, {
    args = args,
    stdio = { nil, nil, nil },
  }, function(code, signal)
    self:_on_exit(code, signal)
  end)
  if not handle then
    cb("missing_dependency: mpv", nil)
    return nil
  end
  self.handle = handle
  self.pid = pid

  local deadline = vim.uv.now() + 3000
  local function try_connect()
    local pipe = vim.uv.new_pipe()
    pipe:connect(socket, function(connect_err)
      if connect_err then
        if vim.uv.now() >= deadline or self.closing or self.exited then
          pipe:close()
          self:_fail_start("player_startup")
          cb("player_startup", nil)
          return
        end
        local timer = vim.uv.new_timer()
        timer:start(20, 0, function()
          timer:stop()
          timer:close()
          try_connect()
        end)
        return
      end
      self.pipe = pipe
      self:_on_connect()
      cb(nil, self)
    end)
  end
  try_connect()
  return self
end

function Player:_fail_start(reason)
  self:_kill()
  vim.uv.fs_unlink(self.socket, function() end)
  self.startup_error = reason
end

function Player:_on_exit(code, signal)
  if self.closing then
    return
  end
  self.exited = true
  if self.on_event then
    self.on_event({ type = "exited", code = code, signal = signal })
  end
end

function Player:_on_connect()
  local pipe = self.pipe
  pipe:read_start(function(err, chunk)
    if err then
      self:_on_read_error(err)
      return
    end
    if chunk then
      self.buffer = self.buffer .. chunk
      self:_drain()
    else
      self:_on_read_error("eof")
    end
  end)
  for _, property in ipairs({ "metadata", "pause", "volume", "mute" }) do
    self:command({ "observe_property", self:_next_id(), property })
  end
  self:command({ "loadfile", self._url or "", "replace" })
end

function Player:_next_id()
  self._id = (self._id or 0) + 1
  return self._id
end

function Player:_on_read_error(err)
  if self.closing then
    return
  end
  if self.on_event then
    self.on_event({ type = "closed", error = tostring(err) })
  end
end

---Split the read buffer into JSON lines and dispatch events.
function Player:_drain()
  while true do
    local line_end = self.buffer:find("\n", 1, true)
    if not line_end then
      break
    end
    local line = self.buffer:sub(1, line_end - 1)
    self.buffer = self.buffer:sub(line_end + 1)
    if line ~= "" then
      local ok, value = pcall(vim.json.decode, line)
      if ok and type(value) == "table" then
        self:_handle_message(value)
      end
    end
  end
  if #self.buffer > 1024 * 1024 then
    self.buffer = ""
    if self.on_event then
      self.on_event({ type = "closed", error = "player_message_too_large" })
    end
  end
end

---@param value table
function Player:_handle_message(value)
  local event = value.event
  if event == "playback-restart" then
    self.on_event({ type = "playing" })
  elseif event == "end-file" then
    local file_error = value.file_error
    if
      type(file_error) == "string"
      and file_error:find("audio output", 1, true)
      and self.audio_device
      and self.audio_device:gsub("%s", "") ~= ""
    then
      self.on_event({ type = "failed", code = "audio_device_failed", device = self.audio_device })
      return
    end
    self.on_event({ type = "end", reason = value.reason or "unknown" })
  elseif event == "property-change" then
    local name = value.name
    if name == "metadata" then
      local data = value.data
      local title = type(data) == "table" and (data["icy-title"] or data.title) or nil
      self.on_event({ type = "title", title = metadata_title(title) })
    elseif name == "pause" then
      self.on_event({ type = "paused", paused = value.data == true })
    elseif name == "mute" then
      self.on_event({ type = "muted", muted = value.data == true })
    elseif name == "volume" then
      local volume = tonumber(value.data) or 80
      self.on_event({ type = "volume", volume = math.floor(util.clamp(volume, 0, 100) + 0.5) })
    end
  end
end

---Send one IPC command.
---@param command table
function Player:command(command)
  if not self.pipe or self.closing then
    return
  end
  local ok, encoded = pcall(vim.json.encode, { command = command })
  if not ok then
    return
  end
  self.pipe:write(encoded .. "\n")
end

function Player:toggle_pause()
  self:command({ "cycle", "pause" })
end

function Player:toggle_mute()
  self:command({ "cycle", "mute" })
end

---@param delta integer
function Player:volume(delta)
  self:command({ "add", "volume", delta })
end

---@param url string
function Player:load(url)
  self._url = url
  self:command({ "loadfile", url, "replace" })
end

function Player:_kill()
  if self.handle and not self.handle:is_closing() then
    pcall(vim.uv.process_kill, self.handle, "sigkill")
  end
end

---Ask mpv to quit, escalate to SIGKILL, and remove the socket.
---@param cb function|nil
function Player:close(cb)
  if self.closing then
    if cb then
      cb()
    end
    return
  end
  self.closing = true
  local finished = false
  local function finish()
    if finished then
      return
    end
    finished = true
    if self.pipe and not self.pipe:is_closing() then
      self.pipe:close()
    end
    vim.uv.fs_unlink(self.socket, function() end)
    if cb then
      cb()
    end
  end
  if self.pipe and not self.pipe:is_closing() then
    self:command({ "quit" })
  end
  local timer = vim.uv.new_timer()
  timer:start(800, 0, function()
    timer:stop()
    timer:close()
    self:_kill()
    finish()
  end)
  vim.uv.new_timer():start(900, 0, function()
    finish()
  end)
end

---List mpv audio output devices.
---@param mpv string
---@return table[] devices, string|nil err
function Player.audio_devices(mpv)
  local result = vim.system({ mpv, "--no-config", "--audio-device=help" }, {}):wait()
  if result.code ~= 0 then
    return {}, "audio_devices_unavailable"
  end
  local output = util.system_output(result.stdout)
  local devices = {}
  for line in output:gmatch("[^\n]+") do
    local name, description = line:match("^%s*'([^']*)' %((.*)%)%s*$")
    if name and name ~= "" then
      devices[#devices + 1] = { name = name, description = description or "" }
    end
  end
  if #devices == 0 then
    return {}, "audio_devices_unavailable"
  end
  return devices
end

local normalization_cache = {}

---Probe whether this mpv build provides dynaudnorm.
---@param mpv string
---@return boolean
function Player.supports_normalization(mpv)
  if normalization_cache[mpv] ~= nil then
    return normalization_cache[mpv]
  end
  local supported = false
  local result = vim.system({ mpv, "--no-config", "--af=help" }, {}):wait()
  if result.code == 0 then
    for line in util.system_output(result.stdout):gmatch("[^\n]+") do
      if line:match("^%s*dynaudnorm") then
        supported = true
        break
      end
    end
  end
  normalization_cache[mpv] = supported
  return supported
end

log.debug("player module loaded")
return Player
