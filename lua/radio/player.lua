-- mpv playback over its JSON IPC socket, driven by libuv.
local http = require("radio.http")
local log = require("radio.log")
local util = require("radio.util")

local Player = {}
Player.__index = Player

local SOCKET_PATH_LIMIT = 100
local normalization_cache = {}

local function normalization_supported(result)
  if result.code ~= 0 then
    return false
  end
  for line in util.system_output(result.stdout):gmatch("[^\n]+") do
    if line:match("^%s*dynaudnorm") then
      return true
    end
  end
  return false
end

local function normalization_probe_error(result)
  if result.code == 124 then
    return "normalization_probe_timeout"
  end
  if normalization_supported(result) then
    return nil
  end
  return "normalization_unavailable"
end

---@return string
local function random_suffix(n)
  local bytes = assert(vim.uv.random(math.ceil(n / 2)))
  return (bytes:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end)):sub(1, n)
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
local function start_player(opts, on_event, cb)
  local socket, socket_err = socket_path(opts.runtime_dir)
  if not socket then
    cb(socket_err, nil)
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
    _start_callback = cb,
    _close_callbacks = {},
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
    self.connecting_pipe = pipe
    pipe:connect(socket, function(connect_err)
      if self.connecting_pipe == pipe then
        self.connecting_pipe = nil
      end
      if self.closing then
        if not pipe:is_closing() then
          pipe:close()
        end
        return
      end
      if connect_err then
        if not pipe:is_closing() then
          pipe:close()
        end
        if vim.uv.now() >= deadline or self.closing or self.exited then
          self:_fail_start("player_startup")
          return
        end
        local timer = vim.uv.new_timer()
        self.connect_timer = timer
        timer:start(20, 0, function()
          timer:stop()
          timer:close()
          if self.connect_timer == timer then
            self.connect_timer = nil
          end
          if self.closing then
            return
          end
          try_connect()
        end)
        return
      end
      self.pipe = pipe
      self:_on_connect()
      self:_complete_start(nil)
    end)
  end
  try_connect()
  return self
end

---Own the optional capability probe until it exits, including cancellation.
function Player.start(opts, on_event, cb)
  if not opts.normalize_loudness or normalization_cache[opts.mpv] == true then
    return start_player(opts, on_event, cb)
  end
  if normalization_cache[opts.mpv] == false then
    cb("normalization_unavailable", nil)
    return nil
  end
  local task = { callbacks = {} }
  local function closed()
    if task.closed then
      return
    end
    task.closed = true
    for _, done in ipairs(task.callbacks) do
      done()
    end
    task.callbacks = {}
  end
  function task:close(done)
    if done then
      if self.closed then
        done()
      else
        self.callbacks[#self.callbacks + 1] = done
      end
    end
    if self.closing then
      return
    end
    self.closing = true
    if self.player then
      self.player:close(closed)
    elseif self.probe and not self.probe_done then
      pcall(self.probe.kill, self.probe, 9)
    elseif self.probe_done then
      closed()
    end
  end
  local function result_ready(result)
    task.probe_done = true
    if task.closing then
      cb("cancelled", nil)
      closed()
      return
    end
    local probe_error = normalization_probe_error(result)
    if probe_error == "normalization_probe_timeout" then
      log.warn("loudness normalization disabled: capability probe timed out")
      local fallback_opts = vim.tbl_deep_extend("force", opts, { normalize_loudness = false })
      task.player = start_player(fallback_opts, on_event, cb)
      return
    end
    normalization_cache[opts.mpv] = probe_error == nil
    if probe_error then
      cb(probe_error, nil)
      return
    end
    task.player = start_player(opts, on_event, cb)
  end
  local ok, probe = pcall(
    vim.system,
    { opts.mpv, "--no-config", "--af=help" },
    { timeout = 3000 },
    vim.schedule_wrap(result_ready)
  )
  if ok then
    task.probe = probe
  else
    vim.schedule(function()
      task.probe_done = true
      cb(task.closing and "cancelled" or "missing_dependency: mpv", nil)
      if task.closing then
        closed()
      end
    end)
  end
  return task
end

function Player:_complete_start(err)
  local cb = self._start_callback
  self._start_callback = nil
  if cb then
    self._started = err == nil
    cb(err, err == nil and self or nil)
  end
end

function Player:_fail_start(reason)
  self.startup_error = reason
  self:_complete_start(reason)
  self:close()
end

function Player:_on_exit(code, signal)
  self.exited = true
  if self.handle and not self.handle:is_closing() then
    self.handle:close()
  end
  if self.closing then
    self:_finish_close()
  elseif not self._started then
    self:_fail_start("player_startup")
  elseif self.on_event then
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
  if not self.pipe or self.pipe_closed then
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
  if not self.exited and self.handle and not self.handle:is_closing() then
    pcall(vim.uv.process_kill, self.handle, "sigkill")
  end
end

---Ask mpv to quit, escalate to SIGKILL, and remove the socket.
---@param cb function|nil
local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

function Player:_finish_close()
  if self._closed then
    return
  end
  self._closed = true
  close_timer(self.close_timer)
  close_timer(self.connect_timer)
  self.close_timer, self.connect_timer = nil, nil
  for _, pipe in pairs({ self.pipe, self.connecting_pipe }) do
    if not pipe:is_closing() then
      pipe:read_stop()
      pipe:close()
    end
  end
  self.connecting_pipe = nil
  self.pipe_closed = true
  vim.uv.fs_unlink(self.socket, function() end)
  local callbacks = self._close_callbacks
  self._close_callbacks = {}
  for _, cb in ipairs(callbacks) do
    cb()
  end
end

function Player:close(cb)
  if self._closed then
    if cb then
      cb()
    end
    return
  end
  if cb then
    self._close_callbacks[#self._close_callbacks + 1] = cb
  end
  if self.closing then
    return
  end
  self.closing = true
  close_timer(self.connect_timer)
  self.connect_timer = nil
  self:_complete_start("cancelled")
  if self.exited then
    self:_finish_close()
    return
  end
  if self.pipe and not self.pipe:is_closing() then
    self.pipe:read_stop()
    self:command({ "quit" })
    self.close_timer = vim.uv.new_timer()
    self.close_timer:start(800, 0, function()
      close_timer(self.close_timer)
      self.close_timer = nil
      self:_kill()
    end)
  else
    self:_kill()
  end
end

---List mpv audio output devices.
---@param mpv string
---@return table[] devices, string|nil err
function Player.audio_devices(mpv, cb)
  local function parse(result)
    local devices = {}
    if result.code == 0 then
      for line in util.system_output(result.stdout):gmatch("[^\n]+") do
        local name, description = line:match("^%s*'([^']*)' %((.*)%)%s*$")
        if name and name ~= "" then
          devices[#devices + 1] = { name = name, description = description or "" }
        end
      end
    end
    return devices, #devices == 0 and "audio_devices_unavailable" or nil
  end
  local args = { mpv, "--no-config", "--audio-device=help" }
  if cb then
    local ok, handle = pcall(
      vim.system,
      args,
      { timeout = 3000 },
      vim.schedule_wrap(function(result)
        cb(parse(result))
      end)
    )
    if not ok then
      vim.schedule(function()
        cb({}, "missing_dependency: mpv")
      end)
    end
    return ok and handle or nil
  end
  local ok, result = pcall(function()
    return vim.system(args, {}):wait(3000)
  end)
  if not ok then
    return {}, "missing_dependency: mpv"
  end
  return parse(result)
end

---Synchronous capability query for explicit API callers; playback probes asynchronously.
function Player.supports_normalization(mpv)
  if normalization_cache[mpv] ~= nil then
    return normalization_cache[mpv]
  end
  local ok, result = pcall(function()
    return vim.system({ mpv, "--no-config", "--af=help" }, {}):wait(3000)
  end)
  local supported = ok and normalization_supported(result) or false
  normalization_cache[mpv] = supported
  return supported
end

log.debug("player module loaded")
return Player
