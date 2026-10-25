local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  local Engine = require("radio.engine")
  local model = require("radio.model")
  local player = require("radio.player")
  local dir = H.tmpdir("playback-edges")
  config.setup({ data_dir = dir, auto_sync_days = 0 })
  local engine = assert(Engine.new({ auto_sync = false }))
  local original = player.start
  local starts, event, fast = 0, nil, false
  player.start = function(_, on_event, cb)
    starts = starts + 1
    fast = vim.in_fast_event()
    event = on_event
    cb(nil, {
      close = function(_, done)
        done()
      end,
    })
  end
  local station = model.station({
    stationuuid = "42424242-4242-4242-8242-424242424242",
    name = "Previous",
    url = "https://example.test/live",
    custom = true,
    active = true,
  })
  engine.store:save_custom(station, { "https://example.test/backup" })
  engine:play(station.stationuuid)
  event({ type = "paused", paused = true })
  event({ type = "playing" })
  H.eq(engine.status.playback_state, "paused", "pause while connecting survives confirmation")
  event({ type = "paused", paused = false })
  H.eq(engine.status.playback_state, "playing", "unpause synchronizes state")

  engine.reconnect_due = vim.uv.now()
  H.wait_for(2000, function()
    return starts == 2
  end, "timer starts reconnect")
  H.eq(fast, false, "reconnect starts outside fast events")
  engine:stop_playback()

  engine.store:save_recording(
    model.recording({ id = "missing-file", path = dir .. "/missing.mp3", status = "complete" })
  )
  for _, target in ipairs({
    "invalid",
    "99999999-9999-4999-8999-999999999999",
    "missing-record",
    "missing-file",
  }) do
    engine:play(station.stationuuid)
    event({ type = "playing" })
    local stale = event
    local before = starts
    if target:find("missing", 1, true) then
      engine:play_recording(target)
    else
      engine:play(target)
    end
    H.eq(starts, before, "invalid target never starts old backup: " .. target)
    H.eq(engine.status.playback_state, "failed", "invalid target reports failure: " .. target)
    H.eq(#engine.candidates, 0, "invalid target discards old candidates")
    stale({ type = "playing" })
    H.eq(engine.status.playback_state, "failed", "old confirmation cannot revive rejected request")
  end
  local ok, result, err = pcall(engine.random, engine, { query = "no such station" })
  H.check(
    ok and result == nil and err == "no_matching_station",
    "empty random returns a useful error"
  )
  H.eq(engine.random_filter, nil, "empty random clears retry mode")

  engine:shutdown()
  player.start = original
end
