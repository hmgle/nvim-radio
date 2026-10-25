-- Engine tests: playback lifecycle, recording, and recovery against the
-- local stream server.
local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  local Engine = require("radio.engine")
  local Store = require("radio.store")
  local model = require("radio.model")
  local dir = H.tmpdir("engine")
  config.setup({ data_dir = dir, recording_min_free_mb = 1, auto_sync_days = 0 })
  local mp3 = H.make_mp3(dir, 30)

  local url, stop = H.start_server({
    ["/fixture.mp3"] = function()
      local fd = assert(vim.uv.fs_open(mp3, "r", 438))
      local stat = assert(vim.uv.fs_fstat(fd))
      local data = assert(vim.uv.fs_read(fd, stat.size, 0))
      vim.uv.fs_close(fd)
      return data, 200
    end,
  })
  -- Endless stream for the manual-stop recording path: a finite file would be
  -- recorded to EOF and finalized before the stop key arrives.
  local loop_url, loop_stop = H.start_loop_server(mp3)

  local engine = assert(Engine.new({ auto_sync = false }))
  local station = model.station({
    stationuuid = "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
    name = "Engine Station",
    url = loop_url,
    url_resolved = loop_url,
    custom = true,
    active = true,
    bitrate = 128,
  })
  engine.store:save_custom(station)

  local transitions = {}
  engine:subscribe(function(status)
    transitions[#transitions + 1] = status.playback_state
  end)

  engine:play(station.stationuuid)
  H.wait_for(8000, function()
    return engine:playing()
  end, "engine reaches playing state")
  H.eq(engine.status.source_url, loop_url, "source url tracked")
  H.eq(#engine.store:search(model.filter({ history = true })), 1, "history recorded once")
  H.eq(engine.store:meta("pref_last_station"), station.stationuuid, "last station persisted")

  -- Pause, volume, mute.
  engine:pause()
  H.wait_for(2000, function()
    return engine.status.playback_state == "paused"
  end, "pause applied")
  engine:pause()
  H.wait_for(2000, function()
    return engine.status.playback_state == "playing"
  end, "resume applied")
  local volume_before = engine.status.volume
  engine:volume(-10)
  H.eq(engine.status.volume, math.max(0, volume_before - 10), "volume adjusted")
  H.eq(engine.store:meta("pref_volume"), tostring(engine.status.volume), "volume persisted")
  engine:mute()
  H.wait_for(2000, function()
    return engine.status.muted
  end, "mute applied")
  engine:mute()

  -- Record the playing station, then stop and publish.
  engine:toggle_recording()
  H.wait_for(10000, function()
    return engine.status.recording_state == "recording"
  end, "recording starts")
  H.wait_for(5000, function()
    return engine.status.recording_ms > 0
  end, "recording progress advances")
  H.wait_for(5000, function()
    return engine.status.recording_ms > 1000
  end, "recording elapsed time accumulates")
  engine:toggle_recording()
  H.wait_for(15000, function()
    return engine.status.recording_state == "done" or engine.status.recording_state == "failed"
  end, "recording finalizes")
  H.eq(engine.status.recording_state, "done", "recording completes")
  H.eq(#engine.store:recordings(), 1, "one recording stored")
  local record = engine.store:recordings()[1]
  H.eq(record.status, "complete", "recording row complete")
  H.check(vim.uv.fs_stat(record.path) ~= nil, "recording file published")
  H.eq(#engine.store:unfinished_recordings(), 0, "nothing pending")

  -- Local paths with URI-sensitive characters must reach mpv unchanged.
  local local_path = dir .. "/recordings/local # 中文 %.mp3"
  assert(vim.uv.fs_rename(record.path, local_path))
  record.path = local_path
  engine.store:save_recording(record)
  local history_size = #engine.store:search(model.filter({ history = true }))
  engine:play_recording(record.id)
  H.wait_for(8000, function()
    return engine:playing()
  end, "published recording plays locally")
  H.eq(engine.status.source_url, local_path, "local playback uses the actual path")
  H.eq(
    #engine.store:search(model.filter({ history = true })),
    history_size,
    "local play leaves history intact"
  )

  -- Playing an invalid target fails cleanly.
  engine:play("not-a-station")
  H.eq(engine.status.playback_state, "failed", "invalid target fails")

  engine:stop_playback()
  H.wait_for(2000, function()
    return engine.status.playback_state == "idle"
  end, "playback stops")
  H.check(vim.tbl_contains(transitions, "playing"), "playing transition observed")

  engine:shutdown()
  H.eq(engine.store, nil, "store closed on shutdown")

  -- Reopening recovers cleanly.
  local engine2 = assert(Engine.new({ auto_sync = false }))
  H.eq(engine2.status.message, "ready", "no recovery warnings on reopen")
  H.eq(#engine2.store:unfinished_recordings(), 0, "reopen leaves nothing pending")
  engine2:shutdown()

  -- Ephemeral URL playback, recording guard, and standalone recording.
  local engine3 = assert(Engine.new({ auto_sync = false }))
  local history_before = #engine3.store:search(model.filter({ history = true }))
  engine3:play(url .. "/fixture.mp3")
  H.wait_for(8000, function()
    return engine3:playing()
  end, "ephemeral URL plays")
  engine3:toggle_recording()
  H.wait_for(10000, function()
    return engine3.status.recording_state == "failed"
  end, "ephemeral recording refused")
  H.check(
    engine3.status.message:find("ephemeral_recording") ~= nil,
    "ephemeral recording error surfaced"
  )
  H.eq(
    #engine3.store:search(model.filter({ history = true })),
    history_before,
    "ephemeral play not in history"
  )
  engine3:stop_playback()

  engine3:standalone_record(station.stationuuid, 2, nil)
  H.wait_for(15000, function()
    return engine3.status.recording_state == "recording"
  end, "standalone recording starts without playback")
  H.wait_for(10000, function()
    return engine3.status.recording_state == "done" or engine3.status.recording_state == "failed"
  end, "standalone recording finalizes")
  H.eq(engine3.status.recording_state, "done", "standalone recording completes")

  -- Random play with a filter.
  engine3:random({ custom = true })
  H.wait_for(8000, function()
    return engine3:playing()
  end, "random plays a custom station")
  engine3:stop_playback()

  -- Shutdown must let an in-flight recording finish publishing before the
  -- database goes away.
  engine3:play(station.stationuuid)
  H.wait_for(8000, function()
    return engine3:playing()
  end, "playing before shutdown test")
  engine3:toggle_recording()
  H.wait_for(15000, function()
    return engine3.status.recording_state == "recording"
  end, "recording starts for shutdown test")
  vim.wait(2500, function()
    return false
  end)
  engine3:shutdown()
  local reopened = assert(Store.open(dir .. "/radio.db"))
  local shutdown_records = reopened:recordings()
  H.check(#shutdown_records >= 1, "recording persisted across shutdown")
  local last = shutdown_records[1]
  H.check(last.status ~= "recording", "recording finalized before shutdown returns")
  H.check(last.size_bytes > 0, "finalized recording kept its audio")
  H.eq(#reopened:unfinished_recordings(), 0, "nothing pending after shutdown")
  H.check(last.final_path ~= nil, "final_path persisted through shutdown")
  reopened:close()
end
