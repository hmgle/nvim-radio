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

  stop()
end
