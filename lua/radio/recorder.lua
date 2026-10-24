-- FFmpeg recording: stream copy into a .part file, progress tracking,
-- graceful stop, verification, publication, and crash recovery.
local http = require("radio.http")
local log = require("radio.log")
local model = require("radio.model")
local util = require("radio.util")

local Recorder = {}
Recorder.__index = Recorder

local ERROR_TAIL_BYTES = 8192

---Keep alphanumerics plus '-' and '_' (Unicode letters, e.g. CJK, survive
---as multibyte sequences), bounded by character and byte budgets.
---@param text string
---@return string
local function filename_component(text, max_chars, max_bytes)
  local out = {}
  local bytes, chars = 0, 0
  local i, len = 1, #(text or "")
  while i <= len do
    local b = text:byte(i)
    local width, keep = 1, false
    if b < 0x80 then
      keep = text:sub(i, i):match("[%w%-_]") ~= nil
    else
      width = (b >= 0xf0) and 4 or (b >= 0xe0) and 3 or 2
      keep = true
    end
    if keep and chars < max_chars then
      local piece = text:sub(i, i + width - 1)
      if bytes + #piece > max_bytes then
        break
      end
      out[#out + 1] = piece
      bytes = bytes + #piece
      chars = chars + 1
    end
    i = i + width
  end
  return table.concat(out)
end

---@param text string
---@param max_bytes integer
---@return string
local function track_component(text, max_bytes)
  local words = {}
  for word in text:gmatch("%S+") do
    local cleaned = filename_component(word, 40, max_bytes)
    if cleaned ~= "" then
      words[#words + 1] = cleaned
    end
  end
  return filename_component(table.concat(words, "_"), 40, max_bytes)
end

---@param line string
---@return boolean
local function is_progress_line(line)
  return line:match("^[a-z_]+=") ~= nil
end

---@param text string
---@param line string
local function append_error_tail(text, line)
  local cleaned = line:gsub("[%c]", function(c)
    return (c == "\n" or c == "\t") and c or ""
  end)
  text = text .. cleaned
  if #text > ERROR_TAIL_BYTES then
    local start = #text - ERROR_TAIL_BYTES + 1
    text = text:sub(start)
  end
  return text
end

---Run ffprobe against a URL or file.
---@param opts table {ffprobe, probe_timeout_secs}
---@param input string
---@param timeout number|nil
---@param cb fun(err: string|nil, info: table|nil)
---@return table|nil handle vim.system handle (killable)
function Recorder.probe(opts, input, timeout, cb)
  local args = {
    opts.ffprobe or "ffprobe",
    "-v",
    "error",
    "-rw_timeout",
    "5000000",
    "-analyzeduration",
    "1000000",
    "-probesize",
    "262144",
    "-user_agent",
    http.USER_AGENT,
    "-select_streams",
    "a:0",
    "-show_entries",
    "stream=codec_name,bit_rate:format=duration,bit_rate",
    "-of",
    "json",
    "-i",
    input,
  }
  return vim.system(args, {}, function(result)
    if result.code ~= 0 then
      local err = result.stderr and table.concat(result.stderr)
        or ("ffprobe exit " .. tostring(result.code))
      cb("process_failed: " .. util.trim(err), nil)
      return
    end
    local ok, decoded = pcall(vim.json.decode, util.system_output(result.stdout))
    if not ok or type(decoded) ~= "table" then
      cb("process_failed: invalid ffprobe json", nil)
      return
    end
    cb(nil, decoded)
  end)
end

---Blocking probe for recovery paths.
---@param opts table
---@param input string
---@param timeout number
---@return table|nil info, string|nil err
function Recorder.probe_sync(opts, input, timeout)
  local args = {
    opts.ffprobe or "ffprobe",
    "-v",
    "error",
    "-rw_timeout",
    "5000000",
    "-analyzeduration",
    "1000000",
    "-probesize",
    "262144",
    "-user_agent",
    http.USER_AGENT,
    "-select_streams",
    "a:0",
    "-show_entries",
    "stream=codec_name,bit_rate:format=duration,bit_rate",
    "-of",
    "json",
    "-i",
    input,
  }
  local result = vim.system(args, {}):wait(timeout * 1000)
  if result.code ~= 0 then
    return nil, "process_failed: exit " .. tostring(result.code)
  end
  local ok, decoded = pcall(vim.json.decode, util.system_output(result.stdout))
  if not ok then
    return nil, "process_failed: invalid ffprobe json"
  end
  return decoded
end

---Positive integer field from probe info (string or number).
---@param value any
---@return integer|nil
local function positive(value)
  if type(value) == "string" then
    value = tonumber(value)
  end
  if type(value) == "number" and value > 0 then
    return math.floor(value)
  end
  return nil
end

---Required free bytes: reserve plus a finite estimate when both the bitrate
---and duration are known.
---@param reserve_mb integer
---@param station table
---@param info table
---@param duration integer|nil seconds
---@return integer required, boolean estimated
function Recorder.required_space(reserve_mb, station, info, duration)
  local bitrate = positive(info.streams and info.streams[1] and info.streams[1].bit_rate)
    or positive(info.format and info.format.bit_rate)
  if not bitrate and station and station.bitrate and station.bitrate > 0 then
    bitrate = station.bitrate * 1000
  end
  local reserve = reserve_mb * 1024 * 1024
  if duration and bitrate then
    return reserve + math.floor(bitrate * duration / 8), true
  end
  return reserve, false
end

---Create a directory tree without touching the Vimscript API (safe in fast
---event contexts such as vim.system callbacks).
---@param path string
---@return boolean ok
local function mkdir_p(path)
  local stat = vim.uv.fs_stat(path)
  if stat then
    return stat.type == "directory"
  end
  local parent = vim.fs.dirname(path)
  if parent ~= path then
    mkdir_p(parent)
  end
  if vim.uv.fs_mkdir(path, 493) ~= nil then
    return true
  end
  stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

---@param dir string
---@return integer|nil available, string|nil err
local function available_space(dir)
  local ancestor = dir
  while ancestor and ancestor ~= "" do
    local stat = vim.uv.fs_stat(ancestor)
    if stat then
      local statfs = vim.uv.fs_statfs(ancestor)
      if statfs then
        return statfs.bavail * statfs.frsize
      end
      return nil, "final_path_missing"
    end
    ancestor = vim.fs.dirname(ancestor)
  end
  return nil, "final_path_missing"
end

---Publish a partial file without overwriting an existing destination.
---@param partial string
---@param final_path string
---@return boolean ok, string|nil err
local function publish(partial, final_path)
  if vim.uv.fs_stat(final_path) then
    local source = vim.uv.fs_lstat(partial)
    local target = vim.uv.fs_lstat(final_path)
    if not source or not target or source.dev ~= target.dev or source.ino ~= target.ino then
      return false, "recording_publish"
    end
    local ok = vim.uv.fs_unlink(partial)
    return ok ~= nil, ok ~= nil and nil or "recording_publish"
  end
  local ok, err = vim.uv.fs_rename(partial, final_path)
  if not ok then
    return false, "recording_publish: " .. tostring(err)
  end
  return true
end

---@param record table
local function write_sidecar(record)
  local path = record.path .. ".json"
  local temp = path .. ".tmp"
  local fd = vim.uv.fs_open(temp, "w", 420)
  if not fd then
    return
  end
  vim.uv.fs_write(fd, vim.json.encode(record))
  vim.uv.fs_close(fd)
  vim.uv.fs_rename(temp, path)
end

---Start recording `url` into `dir`.
---@param opts table {ffmpeg, ffprobe, probe_timeout_secs, playback_timeout_secs, recording_min_free_mb}
---@param store table
---@param station table
---@param url string
---@param dir string
---@param duration integer|nil seconds
---@param info table ffprobe result
---@param track string|nil
---@return table|nil recorder, string|nil err
function Recorder.start(opts, store, station, url, dir, duration, info, track)
  local ok_url = util.validate_url(url)
  if not ok_url then
    return nil, "invalid_url"
  end
  local codec = info.streams and info.streams[1] and info.streams[1].codec_name
  if not codec then
    return nil, "no_audio"
  end
  local extension, muxer = model.format_for_codec(codec)
  if not extension then
    return nil, "unsupported_codec: " .. codec
  end
  dir = vim.fs.normalize(dir)
  if dir:sub(1, 1) ~= "/" then
    dir = (vim.uv.cwd() or ".") .. "/" .. dir
  end
  local required, space_estimated =
    Recorder.required_space(opts.recording_min_free_mb or 16, station, info, duration)
  local available, space_err = available_space(dir)
  if space_err then
    return nil, space_err
  end
  if available < required then
    return nil,
      "insufficient_space: available " .. tostring(available) .. " required " .. tostring(required)
  end
  mkdir_p(dir)

  local name = filename_component(station.name or "", 60, 180)
  local track_name = track_component(track or "", math.max(0, 200 - #name))
  local label = track_name == "" and name or (name .. "-" .. track_name)
  local id = util.uuid_v4()
  local base = os.date("%Y%m%d-%H%M%S") .. "-" .. label .. "-" .. id:sub(1, 8)
  local final_path = dir .. "/" .. base .. "." .. extension
  local partial = dir .. "/" .. base .. "." .. extension .. ".part"
  local fd = vim.uv.fs_open(partial, "wx", 420)
  if not fd then
    return nil, "recording_publish: cannot create " .. partial
  end

  local args = {
    opts.ffmpeg or "ffmpeg",
    "-hide_banner",
    "-loglevel",
    "warning",
    "-nostats",
    "-rw_timeout",
    "12000000",
    "-reconnect",
    "1",
    "-reconnect_streamed",
    "1",
    "-reconnect_delay_max",
    "2",
    "-analyzeduration",
    "1000000",
    "-probesize",
    "262144",
    "-user_agent",
    http.USER_AGENT,
    "-i",
    url,
    "-map",
    "0:a:0",
    "-c:a",
    "copy",
  }
  if duration then
    args[#args + 1] = "-t"
    args[#args + 1] = tostring(duration)
  end
  args[#args + 1] = "-progress"
  args[#args + 1] = "pipe:2"
  args[#args + 1] = "-f"
  args[#args + 1] = muxer
  args[#args + 1] = "pipe:1"

  local self = setmetatable({
    opts = opts,
    store = store,
    partial = partial,
    final_path = final_path,
    duration = duration,
    space_estimated = space_estimated,
    errors = "",
    reconnects = 0,
    duration_ms = 0,
    ended = false,
    stop_requested = false,
    timed_out = false,
    finished = false,
    record = model.recording({
      id = id,
      stationuuid = station.stationuuid or "",
      station_name = station.name or "",
      track = (track and track ~= "") and track or nil,
      source_url_resolved = url,
      started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      codec = codec,
      container = muxer,
      path = partial,
      final_path = final_path,
      status = "recording",
    }),
  }, Recorder)

  local stderr_pipe = vim.uv.new_pipe()
  local handle, spawn_err = vim.uv.spawn(args[1], {
    args = vim.list_slice(args, 2),
    stdio = { nil, fd, stderr_pipe },
  }, function(code, signal)
    self:_on_exit(code, signal)
  end)
  vim.uv.fs_close(fd)
  if not handle then
    vim.uv.fs_unlink(partial)
    return nil,
      "missing_dependency: ffmpeg" .. (spawn_err and (" (" .. tostring(spawn_err) .. ")") or "")
  end
  self.handle = handle
  self._stderr_pipe = stderr_pipe
  stderr_pipe:read_start(function(err, chunk)
    if err or not chunk then
      return
    end
    self:_consume_stderr(chunk)
  end)

  store:save_recording(self.record)
  write_sidecar(self.record)
  if duration then
    self.deadline = vim.uv.now() + (duration + (opts.playback_timeout_secs or 12)) * 1000
  end
  return self
end

function Recorder:_consume_stderr(chunk)
  self._stderr_buffer = (self._stderr_buffer or "") .. chunk
  while true do
    local line_end = self._stderr_buffer:find("\n", 1, true)
    if not line_end then
      break
    end
    local line = util.trim(self._stderr_buffer:sub(1, line_end - 1))
    self._stderr_buffer = self._stderr_buffer:sub(line_end + 1)
    if line ~= "" then
      self:_handle_stderr_line(line)
    end
  end
end

---@param line string
function Recorder:_handle_stderr_line(line)
  local value = line:match("^out_time_us=(%d+)$")
  if value then
    self.duration_ms = math.max(self.duration_ms, math.floor(value / 1000))
    return
  end
  if is_progress_line(line) then
    return
  end
  if line:find("Will reconnect at", 1, true) or line:find("Failed to open segment", 1, true) then
    self.reconnects = self.reconnects + 1
  end
  self.errors = append_error_tail(self.errors, line)
end

function Recorder:_on_exit(code, signal)
  self.ended = true
  self.exit_code = code
  self.exit_signal = signal
end

---@return boolean ended
---@return integer elapsed_ms
function Recorder:poll()
  if not self.ended and self.deadline and vim.uv.now() >= self.deadline then
    self.timed_out = true
    return true, self.duration_ms
  end
  return self.ended, self.duration_ms
end

---@return integer
function Recorder:elapsed_ms()
  return self.duration_ms
end

---Stop ffmpeg gracefully (SIGINT), verify, and publish.
---@param reason string|nil
---@param cb fun(record: table, err: string|nil)
function Recorder:finish(reason, cb)
  if self.finished then
    cb(self.record, nil)
    return
  end
  self.finished = true
  local function stop_child(done)
    if self.handle and not self.handle:is_closing() then
      self.stop_requested = true
      pcall(vim.uv.process_kill, self.handle, "sigint")
    end
    local timer = vim.uv.new_timer()
    local waited = 0
    timer:start(50, 100, function()
      waited = waited + 50
      if self.ended or waited >= 3000 then
        timer:stop()
        timer:close()
        if not self.ended and self.handle and not self.handle:is_closing() then
          pcall(vim.uv.process_kill, self.handle, "sigkill")
        end
        done()
      end
    end)
  end

  local function finalize()
    local stat = vim.uv.fs_stat(self.partial)
    self.record.size_bytes = stat and stat.size or 0
    self.record.stopped_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    self.record.reconnects = self.reconnects

    local verification = Recorder.probe_sync(self.opts, self.partial, 2)
    if verification then
      local duration_text = verification.format and verification.format.duration
      local seconds = tonumber(duration_text)
      if seconds and seconds >= 0 then
        self.record.media_duration_ms = math.floor(seconds * 1000)
      end
    end
    local target = self.duration and (self.duration * 1000) or nil
    local measured = self.record.media_duration_ms or self.duration_ms
    local premature = self.ended
      and not self.stop_requested
      and target ~= nil
      and measured + 100 < target
    if self.timed_out then
      reason = reason or "录音未在时限内完成"
    elseif premature then
      reason = reason or "直播源提前结束"
    end
    local graceful = self.exit_code == 0 or self.stop_requested
    if graceful and not reason and self.record.size_bytes > 0 then
      self.record.status = "complete"
    elseif reason then
      self.record.status = "interrupted"
    else
      self.record.status = "failed"
    end
    if self.record.status == "complete" then
      local probed = verification
        and verification.streams
        and verification.streams[1]
        and verification.streams[1].codec_name
      if probed ~= self.record.codec then
        self.record.status = "failed"
        self.record.error = "录音文件未通过音频轨道验证；保留临时文件"
      end
    end
    if not self.record.media_duration_ms and self.duration_ms > 0 then
      self.record.media_duration_ms = self.duration_ms
    end

    if self.record.status == "complete" then
      self.record.status = "finalizing"
      self.store:save_recording(self.record)
      write_sidecar(self.record)
      local published, publish_err = publish(self.partial, self.final_path)
      if not published then
        self.record.recovery_pending = true
        self.record.error = "录音 "
          .. self.record.id
          .. " ("
          .. self.record.path
          .. ") 收尾待重试: "
          .. tostring(publish_err)
        self.store:save_recording(self.record)
        write_sidecar(self.record)
        cb(self.record, tostring(publish_err))
        return
      end
      local final_stat = vim.uv.fs_stat(self.final_path)
      local size = final_stat and final_stat.size or 0
      if size ~= self.record.size_bytes or size == 0 then
        self.record.status = "failed"
        self.record.error = "recording_size_mismatch"
        self.record.recovery_pending = true
        self.store:save_recording(self.record)
        write_sidecar(self.record)
        cb(self.record, "recording_size_mismatch")
        return
      end
      self.record.path = self.final_path
      self.record.status = "complete"
      self.record.error = nil
      self.record.recovery_pending = false
      self.store:save_recording(self.record)
      write_sidecar(self.record)
      vim.uv.fs_unlink(self.partial .. ".json")
      cb(self.record, nil)
      return
    end

    self.record.error = self.record.error
      or reason
      or (self.errors ~= "" and self.errors or ("FFmpeg exit " .. tostring(self.exit_code)))
    if self.errors ~= "" and not self.record.error:find(self.errors, 1, true) then
      self.record.error = self.record.error .. "\n" .. util.trim(self.errors)
    end
    self.store:save_recording(self.record)
    write_sidecar(self.record)
    cb(self.record, nil)
  end

  -- Finalization runs blocking probes, so it must leave the fast-event
  -- context that libuv timers and stream callbacks provide.
  local function after_stop()
    vim.schedule(function()
      finalize()
    end)
  end

  if self.ended then
    after_stop()
  else
    stop_child(after_stop)
  end
end

---Abort without publishing; keeps the partial file for recovery.
---@param reason string|nil
function Recorder:cancel(reason)
  if self.finished then
    return
  end
  self.finished = true
  self.record.status = "interrupted"
  self.record.error = reason or "cancelled"
  self.record.stopped_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local stat = vim.uv.fs_stat(self.partial)
  self.record.size_bytes = stat and stat.size or 0
  if self.handle and not self.handle:is_closing() then
    pcall(vim.uv.process_kill, self.handle, "sigkill")
  end
  self.store:save_recording(self.record)
  write_sidecar(self.record)
end

---Recover interrupted recordings from a previous session.
---@param store table
---@param opts table
---@return string[] warnings
function Recorder.recover(store, opts)
  local warnings = {}
  for _, record in ipairs(store:unfinished_recordings()) do
    local ok, err = pcall(function()
      if record.status == "finalizing" then
        Recorder:_complete_finalization(store, record)
        return
      end
      if record.status == "recording" then
        record.status = "interrupted"
        record.stopped_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        record.error = "上一个会话未正常结束；保留临时文件供恢复"
        local stat = vim.uv.fs_stat(record.path)
        record.size_bytes = stat and stat.size or 0
        record.recovery_pending = true
        store:save_recording(record)
      end
      local retry = record.recovery_pending
      if retry then
        record.error = vim.uv.fs_stat(record.path)
            and "上一个会话未正常结束；临时文件保留，元数据已恢复"
          or "上一个会话未正常结束；音频文件缺失，元数据已恢复"
      end
      record.recovery_pending = false
      write_sidecar(record)
      if retry then
        store:save_recording(record)
      end
    end)
    if not ok then
      local message = "恢复失败: 录音 "
        .. record.id
        .. " ("
        .. record.path
        .. ")："
        .. tostring(err)
      record.error = message
      record.recovery_pending = true
      local saved, save_err = pcall(store.save_recording, store, record)
      if not saved then
        warnings[#warnings + 1] = message .. "；数据库: " .. tostring(save_err)
      else
        warnings[#warnings + 1] = message
      end
    end
  end
  return warnings
end

---@param store table
---@param record table
function Recorder._complete_finalization(store, record)
  local partial = record.path
  local final_path = record.final_path
  if not final_path then
    error("final_path_missing")
  end
  if vim.uv.fs_stat(partial) then
    local published, publish_err = publish(partial, final_path)
    if not published then
      error("recording_publish: " .. tostring(publish_err))
    end
  end
  local stat = vim.uv.fs_stat(final_path)
  local size = stat and stat.size or 0
  if size ~= record.size_bytes or size == 0 then
    error("recording_size_mismatch")
  end
  record.path = final_path
  record.status = "complete"
  record.error = nil
  record.recovery_pending = false
  write_sidecar(record)
  store:save_recording(record)
  vim.uv.fs_unlink(partial .. ".json")
end

log.debug("recorder module loaded")
return Recorder
