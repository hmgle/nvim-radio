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

---Run a subprocess with a hard timeout; the timer kills it on expiry.
---@param args string[]
---@param timeout number seconds
---@param cb fun(result: table, timed_out: boolean)
---@return table|nil handle killable vim.system handle
local function run_with_timeout(args, timeout, cb)
  local task = {}
  local timer
  local function stop_timer()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  function task:cancel()
    if self.done then
      return
    end
    self.done = true
    stop_timer()
    if self.handle then
      pcall(self.handle.kill, self.handle, "sigkill")
    end
  end
  local ok, handle = pcall(vim.system, args, {}, function(result)
    if task.done then
      return
    end
    task.done = true
    stop_timer()
    cb(result, false)
  end)
  if not ok then
    vim.schedule(function()
      if not task.done then
        task.done = true
        cb({ code = -1, stderr = tostring(handle) }, false)
      end
    end)
    return task
  end
  task.handle = handle
  timer = vim.uv.new_timer()
  timer:start(math.max(1, math.floor((timeout or 5) * 1000)), 0, function()
    if task.done then
      stop_timer()
      return
    end
    task:cancel()
    cb({ code = -1, stdout = "", stderr = "timeout" }, true)
  end)
  return task
end

---Run ffprobe against a URL or file.
---@param opts table {ffprobe, probe_timeout_secs}
---@param input string
---@param timeout number|nil
---@param cb fun(err: string|nil, info: table|nil)
---@return table task cancellable probe
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
  return run_with_timeout(args, timeout or 5, function(result, timed_out)
    if timed_out then
      cb("process_failed: ffprobe timeout", nil)
      return
    end
    if result.code ~= 0 then
      local err = util.trim(util.system_output(result.stderr))
      if err == "" then
        err = "ffprobe exit " .. tostring(result.code)
      end
      cb("process_failed: " .. err, nil)
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
        return statfs.bavail * (statfs.frsize or statfs.bsize)
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
  if partial == final_path then
    return true
  end
  -- Creating a hard link is atomic and fails if the destination exists.
  -- Both names are in the recording directory, on the same filesystem.
  -- Never fall back to rename: it can overwrite a concurrently created file.
  local linked, link_err, code = vim.uv.fs_link(partial, final_path)
  if not linked then
    if code ~= "EEXIST" then
      return false, "recording_publish: " .. tostring(link_err)
    end
    -- A previous publication may have linked successfully and stopped before
    -- unlinking the partial. Only the same regular inode permits that retry.
    local source = vim.uv.fs_lstat(partial)
    local target = vim.uv.fs_lstat(final_path)
    if
      not source
      or not target
      or source.type ~= "file"
      or target.type ~= "file"
      or source.dev ~= target.dev
      or source.ino ~= target.ino
    then
      return false, "recording_publish"
    end
  end
  local ok, err = vim.uv.fs_unlink(partial)
  if not ok then
    return false, "recording_publish: " .. tostring(err)
  end
  return true
end

---@param record table
---@return boolean saved, string|nil err
local function write_sidecar(record)
  local path = record.path .. ".json"
  local temp = path .. ".tmp"
  local encoded = model.encode_recording(record)
  local fd, open_err = vim.uv.fs_open(temp, "w", 420)
  local function failed(operation, err)
    if fd then
      vim.uv.fs_close(fd)
    end
    vim.uv.fs_unlink(temp)
    return false, "recording_sidecar: " .. path .. ": " .. operation .. ": " .. tostring(err)
  end
  if not fd then
    return failed("open", open_err)
  end
  local offset = 0
  while offset < #encoded do
    local written, write_err = vim.uv.fs_write(fd, encoded:sub(offset + 1), offset)
    if not written or written == 0 then
      return failed("write", write_err or "zero-byte write")
    end
    offset = offset + written
  end
  local closed, close_err = vim.uv.fs_close(fd)
  if not closed then
    return failed("close", close_err)
  end
  fd = nil
  local renamed, rename_err = vim.uv.fs_rename(temp, path)
  if not renamed then
    return failed("rename", rename_err)
  end
  return true
end

---Find the original partial path in older completed rows only when its
---sidecar proves that it belongs to this recording.
local function restore_partial_path(record)
  if record.partial_path or record.status ~= "complete" or record.path ~= record.final_path then
    return
  end
  local partial = record.path .. ".part"
  local fd = vim.uv.fs_open(partial .. ".json", "r", 0)
  if not fd then
    return
  end
  local stat = vim.uv.fs_fstat(fd)
  local json = stat and stat.size <= 1024 * 1024 and vim.uv.fs_read(fd, stat.size, 0) or nil
  vim.uv.fs_close(fd)
  local previous = json and model.decode_recording(json)
  if previous and previous.id == record.id and previous.path == partial then
    record.partial_path = partial
  end
end

---Keep either persistence failure retryable, even on separate filesystems.
---@return boolean saved, string|nil err
local function persist_recording(store, record)
  restore_partial_path(record)
  local errors = {}
  local sidecar, sidecar_err = write_sidecar(record)
  if not sidecar then
    record.recovery_pending = true
    errors[#errors + 1] = sidecar_err
  end
  -- Save the final state only after the sidecar outcome is known, so a
  -- failed sidecar never briefly becomes a completed, non-retryable row.
  local saved, save_err = pcall(store.save_recording, store, record)
  if not saved then
    record.recovery_pending = true
    errors[#errors + 1] = "recording_store: " .. tostring(save_err)
    if sidecar then
      local marked, mark_err = write_sidecar(record)
      if not marked then
        errors[#errors + 1] = mark_err
      end
    end
  end
  if
    #errors == 0
    and record.status == "complete"
    and record.partial_path
    and record.partial_path ~= record.path
  then
    local path = record.partial_path .. ".json"
    local removed, err, code = vim.uv.fs_unlink(path)
    if not removed and code ~= "ENOENT" then
      record.recovery_pending = true
      errors[#errors + 1] = "recording_sidecar_cleanup: " .. path .. ": " .. tostring(err)
      local marked, mark_err = write_sidecar(record)
      if not marked then
        errors[#errors + 1] = mark_err
      end
      local indexed, index_err = pcall(store.save_recording, store, record)
      if not indexed then
        errors[#errors + 1] = "recording_store: " .. tostring(index_err)
      end
    end
  end
  return #errors == 0, #errors > 0 and table.concat(errors, "\n") or nil
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
      partial_path = partial,
      final_path = final_path,
      status = "recording",
    }),
  }, Recorder)

  -- Persist ownership before launching a writer. A database failure must
  -- leave neither a child process nor an unindexed partial file behind.
  local saved, save_err = pcall(store.save_recording, store, self.record)
  if not saved then
    vim.uv.fs_close(fd)
    vim.uv.fs_unlink(partial)
    return nil, "recording_store: " .. tostring(save_err)
  end

  local stderr_pipe = vim.uv.new_pipe()
  local handle, spawn_err = vim.uv.spawn(args[1], {
    args = vim.list_slice(args, 2),
    stdio = { nil, fd, stderr_pipe },
  }, function(code, signal)
    self:_on_exit(code, signal)
  end)
  vim.uv.fs_close(fd)
  if not handle then
    stderr_pipe:close()
    pcall(store.remove_recording_index, store, self.record.id)
    vim.uv.fs_unlink(partial)
    return nil,
      "missing_dependency: ffmpeg" .. (spawn_err and (" (" .. tostring(spawn_err) .. ")") or "")
  end
  self.handle = handle
  self._stderr_pipe = stderr_pipe
  stderr_pipe:read_start(function(err, chunk)
    if err or not chunk then
      self:_close_stderr()
      return
    end
    self:_consume_stderr(chunk)
  end)

  self:_persist_recording()
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

function Recorder:_close_stderr()
  if self._stderr_pipe and not self._stderr_pipe:is_closing() then
    self._stderr_pipe:read_stop()
    self._stderr_pipe:close()
  end
end

---Persistence must never prevent process cleanup or completion callbacks.
---@return boolean saved
function Recorder:_persist_recording()
  local ok, err = persist_recording(self.store, self.record)
  self._persistence_error = err
  if not ok then
    log.error(
      "recording " .. self.record.id .. " (" .. self.record.path .. "): " .. self._persistence_error
    )
  end
  return ok
end

function Recorder:_settle(err)
  if self._settled then
    return
  end
  self._settled = true
  if self._persistence_error then
    err = err and (err .. "\n" .. self._persistence_error) or self._persistence_error
  end
  self._finish_error = err
  self:_close_stderr()
  local callbacks = self._finish_callbacks or {}
  self._finish_callbacks = {}
  for _, cb in ipairs(callbacks) do
    cb(self.record, err)
  end
end

function Recorder:_on_exit(code, signal)
  self.ended = true
  self.exit_code = code
  self.exit_signal = signal
  if self.handle and not self.handle:is_closing() then
    self.handle:close()
  end
  if self._cancelled then
    self:_settle(self.record.error)
  end
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
  if self._settled then
    cb(self.record, self._finish_error)
    return
  end
  self._finish_callbacks = self._finish_callbacks or {}
  self._finish_callbacks[#self._finish_callbacks + 1] = cb
  if self.finished then
    return
  end
  self.finished = true
  local function stop_child(done)
    if self.handle and not self.handle:is_closing() then
      self.stop_requested = true
      pcall(vim.uv.process_kill, self.handle, "sigint")
    end
    local deadline = vim.uv.now() + 3000
    local timer = vim.uv.new_timer()
    self._stop_timer = timer
    timer:start(0, 25, function()
      if self.ended then
        timer:stop()
        timer:close()
        self._stop_timer = nil
        done()
      elseif vim.uv.now() >= deadline then
        -- Wait for the exit callback before inspecting a file still owned by
        -- ffmpeg. Engine shutdown can cancel this task at its outer deadline.
        if self.handle and not self.handle:is_closing() then
          pcall(vim.uv.process_kill, self.handle, "sigkill")
        end
      end
    end)
  end

  -- Step 1: collect file facts, then verify asynchronously so the editor is
  -- never blocked by ffprobe.
  local finalize
  local function collect()
    if self._cancelled then
      return
    end
    local stat = vim.uv.fs_stat(self.partial)
    self.record.size_bytes = stat and stat.size or 0
    self.record.stopped_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    self.record.reconnects = self.reconnects
    self._verification = Recorder.probe(self.opts, self.partial, 2, function(_, verification)
      self._verification = nil
      finalize(verification)
    end)
  end

  -- Step 2: decide the outcome from the probe result and publish.
  finalize = function(verification)
    if self._cancelled then
      return
    end
    if self.duration_ms > 0 then
      self.record.media_duration_ms = self.duration_ms
    elseif verification then
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
      reason = reason or "recording deadline exceeded"
    elseif premature then
      reason = reason or "stream ended before requested duration"
    end
    local signal = self.exit_signal or 0
    local graceful = signal == 0
        and (self.exit_code == 0 or (self.stop_requested and self.exit_code == 255))
      or (self.stop_requested and signal == 2)
    if signal ~= 0 and not graceful then
      reason = reason or ("FFmpeg terminated by signal " .. signal)
    end
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
        self.record.error = "recording audio verification failed; partial file retained"
      end
    end
    if not self.record.media_duration_ms and self.duration_ms > 0 then
      self.record.media_duration_ms = self.duration_ms
    end

    if self.record.status == "complete" then
      self.record.status = "finalizing"
      if not self:_persist_recording() then
        self:_settle(nil)
        return
      end
      local published, publish_err = publish(self.partial, self.final_path)
      if not published then
        self.record.recovery_pending = true
        self.record.error = "recording "
          .. self.record.id
          .. " ("
          .. self.record.path
          .. ") finalization pending: "
          .. tostring(publish_err)
        self:_persist_recording()
        self:_settle(tostring(publish_err))
        return
      end
      local final_stat = vim.uv.fs_stat(self.final_path)
      local size = final_stat and final_stat.size or 0
      if size ~= self.record.size_bytes or size == 0 then
        self.record.status = "failed"
        self.record.error = "recording_size_mismatch"
        self.record.recovery_pending = true
        self:_persist_recording()
        self:_settle("recording_size_mismatch")
        return
      end
      self.record.path = self.final_path
      self.record.status = "complete"
      self.record.error = nil
      self.record.recovery_pending = false
      self:_persist_recording()
      self:_settle(nil)
      return
    end

    self.record.error = self.record.error
      or reason
      or (
        self.errors ~= "" and self.errors
        or (
          self.record.size_bytes == 0 and "empty_recording"
          or ("FFmpeg exit " .. tostring(self.exit_code))
        )
      )
    if self.errors ~= "" and not self.record.error:find(self.errors, 1, true) then
      self.record.error = self.record.error .. "\n" .. util.trim(self.errors)
    end
    self:_persist_recording()
    self:_settle(nil)
  end

  -- Finalization leaves the fast-event context that libuv timers and stream
  -- callbacks provide; the verification probe itself is asynchronous.
  local function after_stop()
    vim.schedule(function()
      collect()
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
  if self._settled or self._cancelled then
    return
  end
  self._cancelled = true
  self.finished = true
  if self._stop_timer and not self._stop_timer:is_closing() then
    self._stop_timer:stop()
    self._stop_timer:close()
    self._stop_timer = nil
  end
  if self._verification then
    self._verification:cancel()
    self._verification = nil
  end
  self.record.status = "interrupted"
  self.record.error = reason or "cancelled"
  self.record.recovery_pending = true
  self.record.stopped_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local stat = vim.uv.fs_stat(self.partial)
  self.record.size_bytes = stat and stat.size or 0
  if not self.ended and self.handle and not self.handle:is_closing() then
    pcall(vim.uv.process_kill, self.handle, "sigkill")
  end
  self:_persist_recording()
  if self.ended or not self.handle then
    self:_settle(self.record.error)
  end
end

---Recover interrupted recordings from a previous session.
---@param store table
---@param opts table
---@return string[] warnings
function Recorder.recover(store, opts)
  local warnings = {}
  for _, record in ipairs(store:unfinished_recordings()) do
    local persistence_failed = false
    local function persisted(saved, err)
      if not saved then
        persistence_failed = true
        error(err, 0)
      end
    end
    local ok, err = pcall(function()
      if record.status == "finalizing" then
        persisted(Recorder._complete_finalization(store, record))
        return
      end
      if record.status == "recording" then
        record.status = "interrupted"
        record.stopped_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        record.error = "previous session ended unexpectedly; partial file retained for recovery"
        local stat = vim.uv.fs_stat(record.path)
        record.size_bytes = stat and stat.size or 0
        record.recovery_pending = true
      end
      local retry = record.recovery_pending
      if retry and record.status == "interrupted" then
        record.error = vim.uv.fs_stat(record.path)
            and "previous session ended unexpectedly; partial file retained, metadata recovered"
          or "previous session ended unexpectedly; audio file missing, metadata recovered"
      end
      record.recovery_pending = false
      persisted(persist_recording(store, record))
    end)
    if not ok then
      if not vim.uv.fs_stat(record.path) and record.final_path then
        local final_stat = vim.uv.fs_stat(record.final_path)
        if final_stat and final_stat.size == record.size_bytes and final_stat.size > 0 then
          record.path = record.final_path
        end
      end
      local message = "recovery failed: recording "
        .. record.id
        .. " ("
        .. record.path
        .. "): "
        .. tostring(err)
      -- Publication failures retain the audio, but must not keep a dead
      -- session permanently active or prevent the user from removing it.
      if persistence_failed then
        record.recovery_pending = true
      else
        record.error = message
        record.status = "failed"
        record.recovery_pending = false
      end
      local saved, save_err = pcall(store.save_recording, store, record)
      if not saved then
        warnings[#warnings + 1] = message .. "; database: " .. tostring(save_err)
      else
        warnings[#warnings + 1] = message
      end
    end
  end
  return warnings
end

---@param store table
---@param record table
---@return boolean saved, string|nil err
function Recorder._complete_finalization(store, record)
  local partial = record.path
  local final_path = record.final_path
  if not final_path then
    error("final_path_missing")
  end
  if partial ~= final_path then
    record.partial_path = record.partial_path or partial
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
  local saved, err = persist_recording(store, record)
  if not saved then
    return false, err
  end
  return true
end

log.debug("recorder module loaded")
return Recorder
