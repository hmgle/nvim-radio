-- Recorder tests: probe, record, publish, sidecar, and crash recovery.
local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  local Recorder = require("radio.recorder")
  local Store = require("radio.store")
  local model = require("radio.model")

  local dir = H.tmpdir("recorder")
  config.setup({ data_dir = dir, recording_min_free_mb = 1, auto_sync_days = 0 })
  local store = assert(Store.open(config.options.db_path))
  local mp3 = H.make_mp3(dir, 30)
  local recordings = dir .. "/recordings"

  local url, stop = H.start_server({
    ["/fixture.mp3"] = function()
      local fd = assert(vim.uv.fs_open(mp3, "r", 438))
      local stat = assert(vim.uv.fs_fstat(fd))
      local data = assert(vim.uv.fs_read(fd, stat.size, 0))
      vim.uv.fs_close(fd)
      return data, 200
    end,
  })

  local opts = {
    ffmpeg = "ffmpeg",
    ffprobe = "ffprobe",
    probe_timeout_secs = 5,
    playback_timeout_secs = 12,
    recording_min_free_mb = 1,
  }

  -- Probe.
  local probed = false
  local codec = nil
  Recorder.probe(opts, url .. "/fixture.mp3", 5, function(err, info)
    probed = err == nil
    codec = info and info.streams and info.streams[1] and info.streams[1].codec_name
  end)
  H.wait_for(10000, function()
    return probed
  end, "ffprobe succeeds")
  H.eq(codec, "mp3", "probed codec is mp3")

  -- A failing ffprobe must report through the callback, not crash it.
  local probe_failed = false
  Recorder.probe(opts, "http://127.0.0.1:1/missing.mp3", 2, function(err, info)
    probe_failed = err ~= nil and info == nil
  end)
  H.wait_for(15000, function()
    return probe_failed
  end, "failing ffprobe reports an error")

  -- A stalled ffprobe is killed by its timeout instead of hanging.
  local stalled_url, stalled_stop = H.start_blackhole()
  local timed_out = false
  Recorder.probe(opts, stalled_url, 1, function(err)
    timed_out = err ~= nil and err:find("timeout") ~= nil
  end)
  H.wait_for(10000, function()
    return timed_out
  end, "ffprobe timeout enforced")
  stalled_stop()

  -- Codec mapping.
  local ext, muxer = model.format_for_codec("mp3")
  H.eq(ext, "mp3", "mp3 extension")
  H.eq(muxer, "mp3", "mp3 muxer")
  H.eq(select(1, model.format_for_codec("aac")), "aac", "aac extension")
  H.eq(select(2, model.format_for_codec("aac")), "adts", "aac muxer")
  H.eq(select(1, model.format_for_codec("opus")), "opus", "opus extension")
  H.eq(model.format_for_codec("flac"), nil, "unsupported codec rejected")

  -- Duration parsing.
  H.eq(model.parse_duration("30"), 30, "bare seconds")
  H.eq(model.parse_duration("45s"), 45, "seconds unit")
  H.eq(model.parse_duration("10m"), 600, "minutes unit")
  H.eq(model.parse_duration("2h"), 7200, "hours unit")
  H.eq(model.parse_duration("0"), nil, "zero duration rejected")
  H.eq(model.parse_duration("5x"), nil, "bad unit rejected")

  -- Record for two seconds with a duration budget.
  local station = model.station({
    stationuuid = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    name = "录音 台/Name",
    bitrate = 128,
    active = true,
  })
  local recorder = assert(
    Recorder.start(
      opts,
      store,
      station,
      url .. "/fixture.mp3",
      recordings,
      2,
      { streams = { { codec_name = "mp3", bit_rate = "128000" } } },
      "Artist - Title"
    )
  )
  H.eq(recorder.record.status, "recording", "record starts in recording state")
  H.check(recorder.record.path:find("%.part$") ~= nil, "partial file suffix")
  H.check(vim.uv.fs_stat(recorder.record.path) ~= nil, "partial file exists")
  H.eq(store:recording(recorder.record.id).status, "recording", "record persisted")

  H.wait_for(5000, function()
    return recorder:poll()
  end, "duration budget stops ffmpeg")

  local finished = false
  local final_record = nil
  recorder:finish(nil, function(record)
    final_record = record
    finished = true
  end)
  H.wait_for(15000, function()
    return finished
  end, "finalization completes")

  H.eq(final_record.status, "complete", "recording completes")
  H.check(final_record.size_bytes > 1000, "published size is non-trivial")
  H.eq(final_record.path:find("%.part$"), nil, "published path has no .part")
  H.check(vim.uv.fs_stat(final_record.path) ~= nil, "published file exists")
  H.check(vim.uv.fs_stat(final_record.path .. ".json") ~= nil, "sidecar exists")
  H.eq(final_record.codec, "mp3", "codec recorded")
  H.check(
    final_record.media_duration_ms and final_record.media_duration_ms > 1000,
    "duration probed"
  )
  local stored = store:recording(final_record.id)
  H.eq(stored.status, "complete", "database updated to complete")
  H.eq(#store:unfinished_recordings(), 0, "no unfinished recordings")

  H.eq(recorder.handle:is_closing(), true, "ffmpeg process handle released")
  H.eq(recorder._stderr_pipe:is_closing(), true, "ffmpeg stderr pipe released")

  -- SIGINT can be ignored. Enforce a real three-second deadline, then reap
  -- the child before validating or publishing its output.
  local stubborn = dir .. "/stubborn-ffmpeg"
  local ready = dir .. "/stubborn-ready"
  vim.fn.writefile({
    "#!/bin/sh",
    "trap '' INT",
    "cat " .. vim.fn.shellescape(mp3),
    "touch " .. vim.fn.shellescape(ready),
    "exec sleep 30",
  }, stubborn)
  vim.uv.fs_chmod(stubborn, 448)
  local hard = assert(
    Recorder.start(
      vim.tbl_extend("force", opts, { ffmpeg = stubborn }),
      store,
      station,
      url .. "/fixture.mp3",
      recordings,
      nil,
      { streams = { { codec_name = "mp3" } } }
    )
  )
  H.wait_for(2000, function()
    return vim.uv.fs_stat(ready) ~= nil
  end, "stubborn child is ready")
  local began, done = vim.uv.hrtime(), false
  hard:finish(nil, function()
    done = true
  end)
  H.wait_for(5000, function()
    return done
  end, "stubborn child killed and finalized")
  local elapsed = (vim.uv.hrtime() - began) / 1e6
  H.check(elapsed >= 2800 and elapsed < 4500, "SIGKILL deadline is three seconds, not six")
  H.eq(hard.exit_signal, 9, "stubborn ffmpeg was killed")
  H.check(hard.record.status ~= "complete", "forced stop never publishes a truncated recording")
  H.check(hard.record.error:find("signal 9", 1, true) ~= nil, "signal failure is visible")
  H.check(vim.uv.fs_stat(hard.partial) ~= nil, "killed recording retains partial audio")
  H.eq(vim.uv.fs_stat(hard.final_path), nil, "killed recording is not published")
  H.eq(hard.handle:is_closing(), true, "killed ffmpeg process handle released")
  H.eq(hard._stderr_pipe:is_closing(), true, "killed ffmpeg stderr pipe released")

  -- An external SIGKILL is also a failure when libuv reports exit code zero.
  local killed = assert(
    Recorder.start(
      opts,
      store,
      station,
      url .. "/fixture.mp3",
      recordings,
      nil,
      { streams = { { codec_name = "mp3" } } }
    )
  )
  assert(vim.uv.process_kill(killed.handle, "sigkill"))
  H.wait_for(3000, function()
    return killed.ended
  end, "externally killed child reaped")
  H.eq(killed.exit_code, 0, "libuv reports zero code for signal termination")
  local killed_done = false
  killed:finish(nil, function()
    killed_done = true
  end)
  H.wait_for(5000, function()
    return killed_done
  end, "externally killed recording settles")
  H.check(killed.record.status ~= "complete", "external SIGKILL is not success")

  -- A failed database write must reap the spawned process and remove its part.
  local save = store.save_recording
  store.save_recording = function()
    error("disk full")
  end
  local failed, save_err = Recorder.start(
    opts,
    store,
    station,
    url .. "/fixture.mp3",
    recordings,
    nil,
    { streams = { { codec_name = "mp3" } } }
  )
  store.save_recording = save
  H.check(failed == nil and save_err:find("disk full", 1, true), "start reports database failure")
  H.wait_for(3000, function()
    local count = 0
    for name in vim.fs.dir(recordings) do
      if name:match("%.part$") then
        count = count + 1
      end
    end
    return count == 2 -- Both deliberately killed recordings retain their parts.
  end, "failed start removes its orphan partial after child exit")

  -- Crash recovery: a stale recording row is finalized as interrupted.
  store:save_recording(model.recording({
    id = "stale-rec",
    stationuuid = station.stationuuid,
    station_name = station.name,
    path = recordings .. "/stale.mp3.part",
    status = "recording",
    started_at = "2026-01-01T00:00:00Z",
    size_bytes = 10,
  }))
  local warnings = Recorder.recover(store, opts)
  H.eq(#warnings, 0, "recovery without warnings")
  local recovered = store:recording("stale-rec")
  H.eq(recovered.status, "interrupted", "stale recording marked interrupted")
  H.eq(recovered.recovery_pending, false, "recovery flag cleared")
  H.eq(#store:unfinished_recordings(), 0, "nothing pending after recovery")

  -- Publication never overwrites an existing file.
  local conflict = recordings .. "/conflict.mp3"
  local conflict_fd = vim.uv.fs_open(conflict, "w", 420)
  vim.uv.fs_close(conflict_fd)
  local ok = pcall(function()
    Recorder._complete_finalization(
      store,
      model.recording({
        id = "conflict-rec",
        path = conflict,
        final_path = conflict,
        status = "finalizing",
        size_bytes = 1,
      })
    )
  end)
  H.check(not ok, "publishing onto an existing file fails")

  local same = recordings .. "/already-published.mp3"
  vim.fn.writefile({ "audio" }, same)
  local same_size = vim.uv.fs_stat(same).size
  Recorder._complete_finalization(
    store,
    model.recording({
      id = "same-path",
      path = same,
      final_path = same,
      status = "finalizing",
      size_bytes = same_size,
    })
  )
  H.eq(vim.uv.fs_stat(same).size, same_size, "same-path publication keeps the audio")
  H.check(vim.uv.fs_stat(same .. ".json") ~= nil, "same-path publication keeps its sidecar")

  store:save_recording(
    model.recording({
      id = "unrecoverable",
      path = recordings .. "/gone.part",
      final_path = recordings .. "/gone.mp3",
      status = "finalizing",
      size_bytes = 100,
    })
  )
  H.eq(#Recorder.recover(store, opts), 1, "failed finalization warns once")
  H.eq(store:recording("unrecoverable").status, "failed", "failed recovery reaches terminal status")
  H.eq(#store:unfinished_recordings(), 0, "failed recovery no longer blocks deletion")
  H.eq(#Recorder.recover(store, opts), 0, "next startup does not repeat permanent failure")
  store:close()
  stop()
end
