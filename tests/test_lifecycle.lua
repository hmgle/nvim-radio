local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  local Engine = require("radio.engine")
  local Recorder = require("radio.recorder")
  local Store = require("radio.store")
  local Lock = require("radio.lock")
  local model = require("radio.model")
  local dir = H.tmpdir("lifecycle")
  config.setup({ data_dir = dir, auto_sync_days = 0, recording_min_free_mb = 1 })
  local function engine()
    return assert(Engine.new({ auto_sync = false }))
  end
  local e = engine()
  local station = model.station({
    stationuuid = "abababab-abab-4bab-8bab-abababababab",
    name = "Lifecycle",
    url = "https://example.test/a",
    custom = true,
    active = true,
  })
  e.store:save_custom(station, { "https://example.test/b" })
  local original_probe, original_start = Recorder.probe, Recorder.start
  local probes, recorders = {}, {}
  Recorder.probe = function(_, _, _, cb)
    local probe = {
      cb = cb,
      cancel = function(self)
        self.cancelled = true
      end,
    }
    probes[#probes + 1] = probe
    return probe
  end
  Recorder.start = function()
    local r = {
      record = { path = "record-" .. (#recorders + 1), status = "complete", reconnects = 0 },
      poll = function()
        return false, 0
      end,
    }
    function r:finish(_, cb)
      self.cb = cb
    end
    function r:cancel()
      self.cancelled = true
      self.cb(self.record, "cancelled")
    end
    recorders[#recorders + 1] = r
    return r
  end
  local info = { streams = { { codec_name = "mp3" } } }
  e:standalone_record(station.stationuuid)
  e:standalone_record(station.stationuuid)
  H.eq(#probes, 1, "independent recording probes are exclusive")
  e:stop_recording()
  H.eq(probes[1].cancelled, true, "stop cancels independent probe")
  probes[1].cb(nil, info)
  H.eq(#recorders, 0, "cancelled probe cannot create ffmpeg")

  e:standalone_record(station.stationuuid)
  probes[2].cb("bad source")
  H.eq(#probes, 3, "independent probe tries a backup")
  e:stop_recording()
  H.eq(probes[3].cancelled, true, "stop cancels current backup probe")
  probes[3].cb(nil, info)
  H.eq(#recorders, 0, "cancelled backup cannot start recording")

  local function start()
    e:standalone_record(station.stationuuid)
    probes[#probes].cb(nil, info)
    return recorders[#recorders]
  end
  local a = start()
  e:stop_recording()
  local b = start()
  a.cb(a.record)
  H.eq(e.status.recording_state, "recording", "old finalizer cannot overwrite a new recording")
  H.eq(e.status.recording_path, b.record.path, "old finalizer cannot replace new recording path")
  e:stop_recording()
  local c = start()
  e:stop_recording()
  b.cb(b.record)
  H.check(e.finalizers[c] == true, "completing B leaves C tracked")
  H.check(e:shutdown({ timeout_ms = 50 }), "shutdown cancels outstanding finalizers")
  H.eq(c.cancelled, true, "shutdown timeout cancels the specific pending task")
  H.eq(e.store, nil, "storage closes after every finalizer settles")
  H.check(pcall(probes[#probes].cb, nil, info), "late probe after shutdown is harmless")

  -- If a killed child has not exited, ownership stays with the old engine.
  e = engine()
  local waiting = {
    finish = function(self, _, cb)
      self.cb = cb
    end,
    cancel = function(self)
      self.cancelled = true
    end,
  }
  e.recorder = waiting
  H.eq(e:shutdown({ timeout_ms = 20 }), false, "shutdown can defer closure until a child exits")
  H.eq(waiting.cancelled, true, "overdue child receives cancellation")
  H.check(e.store ~= nil, "database stays open until child exit")
  H.eq(Lock.acquire(dir .. "/run"), nil, "session lock stays owned until child exit")
  waiting.cb({ path = "pending", status = "interrupted" }, "cancelled")
  H.eq(e.store, nil, "last exit callback closes the database")
  local released = assert(Lock.acquire(dir .. "/run"))
  released:release()

  -- Cancel a real recorder's verification task, persist recovery metadata,
  -- then deliberately deliver its late result after storage has closed.
  e = engine()
  local partial = dir .. "/recordings/cancelled.mp3.part"
  vim.fn.writefile({ "partial bytes" }, partial)
  local r = setmetatable({
    ended = true,
    exit_code = 0,
    duration_ms = 1000,
    reconnects = 0,
    errors = "",
    store = e.store,
    opts = {},
    partial = partial,
    final_path = dir .. "/recordings/cancelled.mp3",
    record = model.recording({
      id = "cancelled",
      path = partial,
      final_path = dir .. "/recordings/cancelled.mp3",
      status = "recording",
      codec = "mp3",
    }),
  }, Recorder)
  e.recorder, e.recording_owner = r, r
  e:stop_recording()
  local before = #probes
  H.wait_for(1000, function()
    return #probes > before
  end, "verification task starts")
  local verification = probes[#probes]
  H.check(e:shutdown({ timeout_ms = 50 }), "cancelled verification permits safe shutdown")
  H.eq(verification.cancelled, true, "verification subprocess is cancelled")
  H.check(pcall(verification.cb, nil, info), "late verification cannot access closed storage")
  H.eq(vim.uv.fs_stat(r.final_path), nil, "cancelled verification never publishes")
  local reopened = assert(Store.open(dir .. "/radio.db"))
  local saved = reopened:recording("cancelled")
  H.eq(saved.status, "interrupted", "timeout persists interrupted state")
  H.eq(saved.recovery_pending, true, "timeout preserves recoverable metadata")
  H.eq(saved.final_path, r.final_path, "timeout preserves publication target")
  H.check(vim.uv.fs_stat(partial .. ".json") ~= nil, "timeout keeps a recovery sidecar")
  reopened:close()
  Recorder.probe, Recorder.start = original_probe, original_start
end
