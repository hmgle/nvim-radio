-- Engine: playback and recording orchestration on top of mpv and ffmpeg.
-- State changes are emitted to subscribers (UI, statusline) and a 100 ms
-- timer drives the state machine, mirroring radio-cli's engine.
local config = require("radio.config")
local directory = require("radio.directory")
local log = require("radio.log")
local Lock = require("radio.lock")
local model = require("radio.model")
local player_mod = require("radio.player")
local recorder_mod = require("radio.recorder")
local store_mod = require("radio.store")
local util = require("radio.util")

local Engine = {}
Engine.__index = Engine

local RECONNECT_BACKOFF = { 1, 3, 7 }
local RECONNECT_WINDOW = 60
local RECONNECT_WINDOW_MAX = 6
local RANDOM_TRIES = 6
local TICK_MS = 100

local PlaybackState = {
  Idle = "idle",
  Connecting = "connecting",
  Playing = "playing",
  Paused = "paused",
  Reconnecting = "reconnecting",
  Failed = "failed",
}

local RecordingState = {
  Idle = "idle",
  Probing = "probing",
  Recording = "recording",
  Finalizing = "finalizing",
  Done = "done",
  Failed = "failed",
}

Engine.PlaybackState = PlaybackState
Engine.RecordingState = RecordingState

---@param opts table|nil {force, auto_sync}
---@return table|nil engine, string|nil err
function Engine.new(opts)
  opts = opts or {}
  local o = config.ensure()
  local session_lock
  if o.single_instance and not opts.force then
    local lock_err
    session_lock, lock_err = Lock.acquire(o.runtime_dir)
    if not session_lock then
      return nil, lock_err
    end
  end
  local store, store_err = store_mod.open(o.db_path)
  if not store then
    if session_lock then
      session_lock:release()
    end
    return nil, store_err
  end
  local resume_source = o.resume and store:meta("pref_source") or nil
  local resume_station = nil
  if o.resume == true or o.resume == "selection" then
    resume_station = store:meta("pref_last_station")
  end
  local volume = tonumber(store:meta("pref_volume"))
  if volume and volume >= 0 and volume <= 100 then
    o.volume = volume
  end
  local self
  self = setmetatable({
    store = store,
    session_lock = session_lock,
    resume_source = resume_source,
    resume_station = resume_station,
    refresh_count = 0,
    catalog_revision = 0,
    finalizers = {},
    retiring_players = {},
    directory = directory.new({
      api_url = o.api_url,
      connect_timeout_secs = o.connect_timeout_secs,
      request_timeout_secs = o.request_timeout_secs,
      stop = function()
        return self ~= nil and self.stopping or false
      end,
    }),
    status = {
      station = nil,
      title = "",
      message = "",
      playback_state = PlaybackState.Idle,
      volume = o.volume,
      muted = false,
      recording_state = RecordingState.Idle,
      recording_ms = 0,
      recording_path = "",
      source_url = "",
    },
    listeners = {},
    generation = 0,
    candidates = {},
    tried = {},
    refreshed = false,
    confirmed = false,
    session_started = false,
    source_kind = "catalog",
    local_recording_id = nil,
    reconnect_attempts = 0,
    reconnect_window = {},
    reconnect_due = nil,
    started_at = vim.uv.now(),
    random_filter = nil,
    random_tried = {},
    failure = nil,
    recorder = nil,
    syncing = false,
  }, Engine)

  local warnings = recorder_mod.recover(store, {
    ffprobe = o.ffprobe,
  })
  self.status.message = #warnings == 0 and "ready" or table.concat(warnings, "\n")

  if o.resume == true and resume_station then
    local station = self.store:station(resume_station)
    if
      station
      and #model.Station.stream_candidates(station, self.store:backups(resume_station)) > 0
    then
      vim.schedule(function()
        if self.stopping then
          return
        end
        self:play_station(station)
      end)
    end
  end

  if opts.auto_sync ~= false then
    self:_auto_sync()
  end
  return self
end

---Bootstrap when the catalog is empty, else refresh when due.
function Engine:_auto_sync()
  local o = config.options
  if self.store:count() == 0 then
    self.status.message = "catalog empty; bootstrapping"
    self.syncing = true
    self.directory:bootstrap(self.store, function(err, count)
      if self.stopping then
        return
      end
      self.syncing = false
      if err then
        self.status.message = "bootstrap failed: " .. err
        self:emit()
        return
      end
      self.catalog_revision = self.catalog_revision + 1
      self.status.message = "catalog ready: " .. tostring(count) .. " stations"
      self:emit()
    end)
  elseif o.auto_sync_days > 0 and directory.sync_due(self.store, o.auto_sync_days) then
    self:sync({})
  end
end

---@param fn fun(status: table)
---@return function unsubscribe
function Engine:subscribe(fn)
  local subscription = {}
  self.listeners[subscription] = fn
  return function()
    self.listeners[subscription] = nil
  end
end

---Snapshot subscribers and state at emission; unsubscribed listeners must
---not receive already-queued events, and new listeners cannot receive old ones.
function Engine:emit()
  local snapshot = vim.deepcopy(self.status)
  local subscriptions = vim.tbl_keys(self.listeners)
  vim.schedule(function()
    for _, subscription in ipairs(subscriptions) do
      local fn = self.listeners[subscription]
      if fn then
        pcall(fn, snapshot)
      end
    end
  end)
end

---@param message string
function Engine:_say(message)
  self.status.message = message
  self:emit()
end

---Ensure the tick timer runs while something is active.
function Engine:_ensure_timer()
  if self.stopping or self.timer then
    return
  end
  self.timer = vim.uv.new_timer()
  self.timer:start(0, TICK_MS, function()
    local ok, err = pcall(function()
      self:tick()
    end)
    if not ok then
      log.debug("tick error: " .. tostring(err))
    end
  end)
end

function Engine:_stop_timer()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
end

function Engine:active()
  return self.player ~= nil
    or self.starting_player ~= nil
    or self.player_starting
    or self.reconnect_due ~= nil
    or self.recorder ~= nil
    or self.recording_probe ~= nil
    or next(self.finalizers) ~= nil
    or self.syncing
end

function Engine:tick()
  if not self:active() then
    self:_stop_timer()
    return
  end
  self:_ensure_timer()
  self:_tick_reconnect()
  self:_tick_player()
  self:_tick_recording()
end

function Engine:_tick_reconnect()
  if self.reconnect_due and vim.uv.now() >= self.reconnect_due then
    self.reconnect_due = nil
    self:_start_url()
  end
end

function Engine:_tick_player()
  local player = self.player
  if not player then
    return
  end
  if
    not self.confirmed
    and vim.uv.now() - self.started_at > config.options.playback_timeout_secs * 1000
  then
    self:_stream_failed("playback timeout")
  end
end

function Engine:_tick_recording()
  if not self.recorder then
    return
  end
  local ended, elapsed = self.recorder:poll()
  local changed = math.floor(elapsed / 1000) ~= math.floor(self.status.recording_ms / 1000)
  self.status.recording_ms = elapsed
  if changed then
    self:emit()
  end
  if ended then
    self:stop_recording(nil)
  end
end

---------------------------------------------------------------------------
-- Playback
---------------------------------------------------------------------------

---@param target string UUID or http(s) URL
function Engine:play(target)
  if self.stopping or not self.store then
    return
  end
  self.random_filter = nil
  self.random_tried = {}
  if util.is_uuid(target) then
    local station = self.store:station(target)
    if not station then
      self:_fail_playback("station_not_found")
      return
    end
    self:play_station(station)
    return
  end
  local ok = util.validate_url(target)
  if not ok then
    self:_fail_playback("invalid_url")
    return
  end
  local station = model.station({
    stationuuid = util.uuid_v4(),
    name = util.truncate(util.clean_text(util.host_path(target)), 60),
    url = target,
    url_resolved = target,
    custom = true,
    active = true,
  })
  self:_play_source(station, { target }, "ephemeral")
end

---@param station table
function Engine:play_station(station)
  if self.stopping or not self.store then
    return
  end
  local backups = self.store:backups(station.stationuuid)
  local candidates = model.Station.stream_candidates(station, backups)
  self:_play_source(station, candidates, "catalog")
end

---@param id string recording id
function Engine:play_recording(id)
  if self.stopping or not self.store then
    return
  end
  local record = self.store:recording(id)
  if not record then
    self:_fail_playback("recording_not_found")
    return
  end
  if record.status == "recording" or record.status == "finalizing" or record.recovery_pending then
    self:_fail_playback("recording_in_use")
    return
  end
  local path = vim.uv.fs_realpath(record.path)
  if not path then
    self:_fail_playback("recording file missing")
    return
  end
  local station = model.station({
    stationuuid = record.stationuuid,
    name = "♪ " .. (record.station_name or ""),
    custom = true,
  })
  self.random_filter = nil
  self:_play_source(station, { vim.uri_from_fspath(path) }, "local")
  self.local_recording_id = id
end

---@param station table
---@param candidates string[]
---@param kind string
---@param keep_recovery boolean|nil preserve the refresh budget and tried URLs
function Engine:_play_source(station, candidates, kind, keep_recovery)
  self.generation = self.generation + 1
  self:_stop_recording(nil)
  self:_retire_player()
  self.candidates = vim.deepcopy(candidates)
  if not keep_recovery then
    -- A new play request gets a fresh refresh budget; a directory refresh
    -- continues the same request, so its budget and tried URLs survive.
    self.tried = {}
    self.refreshed = false
    self.refresh_count = 0
  end
  self.confirmed = false
  self.session_started = false
  self.source_kind = kind
  self.local_recording_id = nil
  self.reconnect_attempts = 0
  self.reconnect_window = {}
  self.reconnect_due = nil
  self.failure = nil
  self.status.title = ""
  self.status.muted = false
  self.status.playback_state = PlaybackState.Idle
  self.status.station = station
  self:_start_candidate()
end

function Engine:_start_candidate()
  self.reconnect_due = nil
  self.reconnect_attempts = 0
  local url = table.remove(self.candidates, 1)
  if not url then
    self:_fail_playback("no_stream")
    return
  end
  self.url = url
  self.tried[#self.tried + 1] = url
  self.status.source_url = url
  self:_start_url()
end

function Engine:_start_url()
  if self.stopping or not self.store then
    return
  end
  local o = config.options
  self:_ensure_timer()
  self.started_at = vim.uv.now()
  self.confirmed = false
  self.status.playback_state = self.reconnect_attempts > 0 and PlaybackState.Reconnecting
    or PlaybackState.Connecting
  self:_say("connecting: " .. (self.status.station and self.status.station.name or ""))
  self.player_starting = true
  -- Callbacks that outlive their session generation are discarded: stopping or
  -- switching stations must never let a stale player resurrect playback.
  local generation = self.generation
  local starting
  local completed = false
  starting = player_mod.start({
    mpv = o.mpv,
    volume = self.status.volume,
    playback_timeout_secs = o.playback_timeout_secs,
    normalize_loudness = o.normalize_loudness,
    audio_device = o.audio_device,
    runtime_dir = o.runtime_dir,
    url = self.url,
  }, function(event)
    if generation ~= self.generation then
      return
    end
    self:_on_player_event(event)
  end, function(err, player)
    completed = true
    if generation ~= self.generation then
      -- Superseded while connecting: drop the process immediately.
      if player then
        player:close()
      end
      return
    end
    self.player_starting = false
    self.starting_player = nil
    if err then
      self:_player_failed(err)
      return
    end
    self.player = player
  end)
  if not completed and generation == self.generation then
    self.starting_player = starting
  end
end

---@param event table
function Engine:_on_player_event(event)
  if not self.store then
    -- Shut down: late mpv events have nowhere to go.
    return
  end
  local kind = event.type
  if kind == "playing" then
    self.reconnect_attempts = 0
    self.reconnect_due = nil
    self.status.playback_state = PlaybackState.Playing
    self:_say("playing: " .. (self.status.station and self.status.station.name or ""))
    if not self.confirmed then
      self.confirmed = true
      self:_on_confirmed()
    end
  elseif kind == "title" then
    if self.status.title ~= event.title then
      self.status.title = event.title
      self:emit()
    end
  elseif kind == "paused" then
    if self.confirmed then
      self.status.playback_state = event.paused and PlaybackState.Paused or PlaybackState.Playing
      self:emit()
    end
  elseif kind == "muted" then
    self.status.muted = event.muted
    self:emit()
  elseif kind == "volume" then
    if event.volume ~= self.status.volume then
      self.status.volume = event.volume
      self.store:set_meta("pref_volume", tostring(event.volume))
      self:emit()
    end
  elseif kind == "end" then
    self:_on_end(event.reason)
  elseif kind == "failed" then
    self:_player_failed(event.code .. (event.device and (": " .. event.device) or ""))
  elseif kind == "exited" or kind == "closed" then
    if self.player and not self.closing_player then
      self:_stream_failed("player " .. kind)
    end
  end
end

---First successful playback of a station: history, resume, click report.
function Engine:_on_confirmed()
  if not self.store then
    return
  end
  local station = self.status.station
  if not station or self.session_started or self.source_kind == "local" then
    return
  end
  if self.source_kind ~= "ephemeral" then
    self.store:played(station.stationuuid)
    self.store:set_meta("pref_last_station", station.stationuuid)
  end
  self.session_started = true
  if not station.custom then
    self.directory:click(station.stationuuid)
  end
end

---@param reason string
function Engine:_on_end(reason)
  if reason == "redirect" then
    return
  end
  if self.source_kind == "local" and reason == "eof" then
    self:stop_playback()
    self:_say("local playback finished")
    return
  end
  if reason == "stop" or reason == "quit" then
    self:stop_playback()
    self:_say("playback stopped")
    return
  end
  if reason == "eof" or reason == "error" then
    self:_stream_failed("stream ended: " .. reason)
  else
    self:_fail_playback("stream ended: " .. reason)
  end
end

---Retry with backoff inside the outage budget, else give up on this stream.
---@param reason string
function Engine:_stream_failed(reason)
  local now = vim.uv.now()
  while self.reconnect_window[1] and now - self.reconnect_window[1] >= RECONNECT_WINDOW * 1000 do
    table.remove(self.reconnect_window, 1)
  end
  if
    self.session_started
    and self.reconnect_attempts < #RECONNECT_BACKOFF
    and #self.reconnect_window < RECONNECT_WINDOW_MAX
    and self.player
  then
    self.reconnect_window[#self.reconnect_window + 1] = now
    local delay = RECONNECT_BACKOFF[self.reconnect_attempts + 1]
    self.reconnect_attempts = self.reconnect_attempts + 1
    self:_retire_player()
    self.status.playback_state = PlaybackState.Reconnecting
    self.reconnect_due = vim.uv.now() + delay * 1000
    self:_say(
      string.format(
        "reconnecting %d/%d in %ds (%s)",
        self.reconnect_attempts,
        #RECONNECT_BACKOFF,
        delay,
        reason
      )
    )
    self:_ensure_timer()
    return
  end
  self:_fail_playback(reason)
end

---Try the next candidate, refresh from the directory, then give up.
---@param reason string
function Engine:_fail_playback(reason)
  self:_retire_player()
  self:_stop_recording(reason)
  self.status.muted = false
  self.status.playback_state = PlaybackState.Idle
  local station = self.status.station
  if #self.candidates > 0 then
    self:_start_candidate()
    return
  end
  if
    not self.refreshed
    and self.refresh_count < 1
    and station
    and not station.custom
    and self.source_kind == "catalog"
  then
    self.refreshed = true
    self.refresh_count = self.refresh_count + 1
    self:_say("refreshing station from directory")
    local uuid = station.stationuuid
    local generation = self.generation
    self.directory:refresh(uuid, function(err, updated)
      if self.stopping or generation ~= self.generation or not self.store then
        return
      end
      if not err and updated then
        self.store:upsert(updated)
        self:_play_source(
          updated,
          model.Station.stream_candidates(updated, self.store:backups(uuid)),
          "catalog",
          true
        )
      else
        self:_exhausted(reason)
      end
    end)
    return
  end
  self:_exhausted(reason)
end

---Local failures (bad device, missing mpv) skip every fallback.
---@param reason string
function Engine:_player_failed(reason)
  self.failure = reason
  self.candidates = {}
  self.random_filter = nil
  self:_retire_player()
  self:_stop_recording(reason)
  self:_exhausted(reason)
end

---@param reason string
function Engine:_exhausted(reason)
  if self.random_filter and #self.random_tried < RANDOM_TRIES then
    local ok = pcall(function()
      self:_pick_random()
    end)
    if ok then
      return
    end
  end
  self.reconnect_due = nil
  self.reconnect_attempts = 0
  self.reconnect_window = {}
  self.status.muted = false
  self.status.playback_state = PlaybackState.Failed
  self:_say("playback failed: " .. reason)
end

---@param filter table|nil
function Engine:random(filter)
  if self.stopping or not self.store then
    return
  end
  self.random_tried = self.status.station and { self.status.station.stationuuid } or {}
  self.random_filter = model.filter(filter)
  self:_pick_random()
end

function Engine:_pick_random()
  local filter = self.random_filter
  if not filter then
    error("random_disabled")
  end
  local station = self.store:random(filter, self.random_tried)
  if not station then
    error("no_matching_station")
  end
  self.random_tried[#self.random_tried + 1] = station.stationuuid
  self:play_station(station)
end

---@param delta integer
function Engine:volume(delta)
  if not self.store then
    return
  end
  local value = math.floor(util.clamp(self.status.volume + delta, 0, 100))
  if self.player then
    self.player:volume(value - self.status.volume)
  end
  self.status.volume = value
  config.options.volume = value
  self.store:set_meta("pref_volume", tostring(value))
  self:emit()
end

function Engine:pause()
  if not self.player then
    self:_say("not_playing")
    return
  end
  self.player:toggle_pause()
end

function Engine:mute()
  if not self.player then
    self:_say("not_playing")
    return
  end
  self.player:toggle_mute()
end

function Engine:stop_playback()
  local closing = self.player or self.starting_player
  self.closing_player = true
  self:_retire_player()
  self.closing_player = nil
  -- Cancel any pending reconnect so a stop during the backoff is final.
  self.reconnect_due = nil
  self.reconnect_attempts = 0
  self.reconnect_window = {}
  self.status.muted = false
  self.status.playback_state = PlaybackState.Idle
  self.status.title = ""
  if closing then
    self:_say("playback stopped")
  end
  self:emit()
end

function Engine:_retire_player()
  local player, starting = self.player, self.starting_player
  self.player, self.starting_player = nil, nil
  self.player_starting = false
  self.confirmed = false
  self.generation = self.generation + 1
  for _, child in pairs({ player, starting }) do
    if not self.retiring_players[child] then
      self.retiring_players[child] = true
      child:close(function()
        self.retiring_players[child] = nil
        self:_complete_shutdown()
      end)
    end
  end
end

function Engine:playing()
  return self.status.playback_state == PlaybackState.Playing
    or self.status.playback_state == PlaybackState.Paused
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------

function Engine:toggle_recording()
  if not self.store then
    return
  end
  if self.recorder or self.recording_probe then
    self:stop_recording(nil)
    return
  end
  self:record_current(nil, nil)
end

---@param duration integer|nil seconds
---@param dir string|nil
function Engine:record_current(duration, dir)
  if self.stopping or not self.store then
    return
  end
  if self.source_kind == "local" or self.source_kind == "ephemeral" then
    self:_fail_recording(self.source_kind == "local" and "local_recording" or "ephemeral_recording")
    return
  end
  if not self:playing() then
    self:_fail_recording("wait_for_playback")
    return
  end
  local station = self.status.station
  if not station then
    self:_fail_recording("not_playing")
    return
  end
  self:_record_source(station, { self.url }, duration, dir)
end

-- A task owns every probe attempt and its eventual recorder. Cancellation
-- invalidates the task before killing ffprobe, including between backups.
function Engine:_record_source(station, candidates, duration, dir)
  if self.recorder or self.recording_probe then
    self:_fail_recording("recording_busy")
    return
  end
  local o = config.options
  local task = { station = station, track = self.status.title, generation = self.generation }
  self.recording_probe = task
  self.recording_owner = task
  self.status.recording_state = RecordingState.Probing
  self.status.recording_ms = 0
  self.status.recording_path = ""
  self:_say("probing stream for recording")
  self:_ensure_timer()
  local function current()
    return not self.stopping
      and self.store ~= nil
      and self.recording_probe == task
      and self.generation == task.generation
  end
  local function attempt(last_err)
    if not current() then
      return
    end
    local url = table.remove(candidates, 1)
    if not url then
      self.recording_probe = nil
      self:_fail_recording(last_err or "no_stream")
      return
    end
    local completed = false
    local handle = recorder_mod.probe(
      { ffprobe = o.ffprobe },
      url,
      o.probe_timeout_secs,
      function(err, info)
        completed = true
        task.handle = nil
        if not current() then
          if self.recording_probe == task then
            self.recording_probe = nil
            self.status.recording_state = RecordingState.Idle
            self:emit()
          end
          return
        end
        if err then
          attempt("probe failed: " .. err)
          return
        end
        local recorder, start_err = recorder_mod.start({
          ffmpeg = o.ffmpeg,
          ffprobe = o.ffprobe,
          playback_timeout_secs = o.playback_timeout_secs,
          recording_min_free_mb = o.recording_min_free_mb,
        }, self.store, station, url, dir or o.recording_dir, duration, info, task.track)
        if not recorder then
          attempt(start_err)
          return
        end
        self.recording_probe = nil
        self.recorder = recorder
        self.recording_owner = recorder
        self.status.recording_state = RecordingState.Recording
        self.status.recording_path = recorder.record.path
        self:_say(
          recorder.space_estimated and "recording" or "recording (space estimate unavailable)"
        )
        self:_ensure_timer()
      end
    )
    if not completed then
      task.handle = handle
    end
  end
  attempt()
end

---@param uuid string
---@param duration integer|nil
---@param dir string|nil
function Engine:standalone_record(uuid, duration, dir)
  if self.stopping or not self.store then
    return
  end
  local station = self.store:station(uuid)
  if not station then
    self:_fail_recording("station_not_found")
    return
  end
  self:_record_source(
    station,
    model.Station.stream_candidates(station, self.store:backups(uuid)),
    duration,
    dir
  )
end

---@param reason string|nil
function Engine:stop_recording(reason)
  self:_stop_recording(reason)
end

---@param reason string|nil
function Engine:_stop_recording(reason)
  local probe = self.recording_probe
  self.recording_probe = nil
  if probe then
    if probe.handle then
      pcall(function()
        probe.handle:cancel()
      end)
    end
    self.status.recording_state = RecordingState.Idle
    self.status.recording_ms = 0
    self:_say("recording probe cancelled")
  end
  local recorder = self.recorder
  self.recorder = nil
  if not recorder then
    return
  end
  self.status.recording_state = RecordingState.Finalizing
  self.finalizers[recorder] = true
  self:_say("finalizing recording")
  recorder:finish(reason, function(record, err)
    self.finalizers[recorder] = nil
    self:_complete_shutdown()
    if self.stopping or self.recording_owner ~= recorder then
      return
    end
    self.status.recording_ms = 0
    self.status.recording_path = record.path
    if err or record.status ~= "complete" then
      self.status.recording_state = RecordingState.Failed
      self:_say("recording " .. record.status .. ": " .. tostring(record.error or err))
    else
      self.status.recording_state = RecordingState.Done
      local message = "recording complete: " .. record.path
      if record.reconnects > 0 then
        message = message .. " (reconnects: " .. record.reconnects .. ")"
      end
      self:_say(message)
    end
    self:emit()
  end)
end

---@param reason string
function Engine:_fail_recording(reason)
  if not (self.recorder or self.recording_probe) then
    self.status.recording_state = RecordingState.Failed
  end
  self:_say("recording failed: " .. reason)
end

function Engine:recording()
  return self.status.recording_state == RecordingState.Probing
    or self.status.recording_state == RecordingState.Recording
end

---------------------------------------------------------------------------
-- Catalog sync and lifecycle
---------------------------------------------------------------------------

---@param opts table|nil {accept_shrink}
---@param cb function|nil
function Engine:sync(opts, cb)
  if self.stopping then
    if cb then
      cb("cancelled")
    end
    return
  end
  if self.syncing then
    if cb then
      cb("sync already running")
    end
    return
  end
  self.syncing = true
  self:_ensure_timer()
  self:_say("syncing catalog")
  self.directory:sync(self.store, {
    accept_shrink = opts and opts.accept_shrink,
    progress = function(offset)
      self:_say("syncing catalog: " .. offset .. " stations")
    end,
  }, function(err, report)
    if self.stopping then
      return
    end
    self.syncing = false
    if err then
      self:_say("sync failed: " .. err)
    else
      self.catalog_revision = self.catalog_revision + 1
      self:_say("catalog synced: " .. tostring(report and report.unique or 0) .. " stations")
    end
    if cb then
      cb(err, report)
    end
  end)
end

-- Closing storage is the last lifecycle action. If a killed child has not
-- been reaped at the deadline, retain the store and lock until its callback.
function Engine:_shutdown_pending()
  return next(self.finalizers) ~= nil or next(self.retiring_players) ~= nil
end

function Engine:_complete_shutdown()
  if not self.stopping or self._shutdown_waiting or self:_shutdown_pending() then
    return false
  end
  self:_stop_timer()
  if self.store then
    self.store:close()
    self.store = nil
  end
  if self.session_lock then
    self.session_lock:release()
    self.session_lock = nil
  end
  return true
end

---@param opts table|nil {timeout_ms} total grace and forced-reap budget
---@return boolean closed false only while killed children are still exiting
function Engine:shutdown(opts)
  if not self.store then
    return true
  end
  self._shutdown_waiting = true
  self.stopping = true
  self.directory:close()
  self.syncing = false
  self:_stop_timer()
  self:_stop_recording("shutdown")
  self:stop_playback()
  local budget = math.max(0, opts and opts.timeout_ms or 6000)
  local deadline = vim.uv.now() + budget
  local graceful_deadline = deadline - math.min(500, budget)
  vim.wait(math.max(0, graceful_deadline - vim.uv.now()), function()
    return not self:_shutdown_pending()
  end, 10)
  if next(self.finalizers) then
    local pending = vim.tbl_keys(self.finalizers)
    for _, recorder in ipairs(pending) do
      recorder:cancel("shutdown timeout")
    end
  end
  vim.wait(math.max(0, deadline - vim.uv.now()), function()
    return not self:_shutdown_pending()
  end, 10)
  self._shutdown_waiting = false
  return self:_complete_shutdown()
end

return Engine
