-- Command tests: argument parsing and favorite semantics.
local H = require("tests.helpers")

return function()
  local root = H.root
  -- plugin/radio.lua registers the commands at startup; nvim -l skips plugins.
  dofile(root .. "/plugin/radio.lua")
  local config = require("radio.config")
  local model = require("radio.model")
  config.setup({ data_dir = H.tmpdir("commands"), auto_sync_days = 0 })
  local radio = require("radio")
  local engine = assert(radio.engine({ auto_sync = false }))

  local commands = vim.api.nvim_get_commands({})
  for _, name in ipairs({
    "Radio",
    "RadioPlay",
    "RadioRecord",
    "RadioFavorites",
    "RadioSync",
    "RadioStatus",
  }) do
    H.check(commands[name] ~= nil, name .. " registered")
  end

  ------------------------------------------------------------------
  -- RadioRecord: --output-dir's value must not become the duration.
  ------------------------------------------------------------------
  local captured = {}
  local original = engine.record_current
  engine.record_current = function(_, duration, dir)
    captured = { duration = duration, dir = dir }
  end
  vim.cmd("RadioRecord 30m --output-dir /tmp/music")
  H.eq(captured.duration, 1800, "duration parsed before the flag")
  H.eq(captured.dir, "/tmp/music", "output dir parsed")
  vim.cmd("RadioRecord --output-dir /tmp/music 45s")
  H.eq(captured.duration, 45, "duration parsed after the flag")
  H.eq(captured.dir, "/tmp/music", "output dir parsed (flags first)")
  vim.cmd("RadioRecord")
  H.eq(captured.duration, nil, "no duration without arguments")
  H.eq(captured.dir, nil, "no output dir without arguments")
  engine.record_current = original

  ------------------------------------------------------------------
  -- RadioFavorites: add and remove are explicit, not toggles.
  ------------------------------------------------------------------
  local function favorite_count()
    return #engine.store:search(model.filter({ favorites = true }))
  end
  local uuid = "19191919-1919-4919-8919-191919191919"
  engine.store:save_custom(model.station({
    stationuuid = uuid,
    name = "Fav",
    url = "https://example.com/fav",
    custom = true,
    active = true,
  }))
  vim.cmd("RadioFavorites add " .. uuid)
  H.eq(favorite_count(), 1, "favorite added")
  vim.cmd("RadioFavorites add " .. uuid)
  H.eq(favorite_count(), 1, "repeated add is idempotent")
  vim.cmd("RadioFavorites remove " .. uuid)
  H.eq(favorite_count(), 0, "favorite removed")
  local other = "20202020-2020-4020-8020-202020202020"
  engine.store:save_custom(model.station({
    stationuuid = other,
    name = "Other",
    url = "https://example.com/other",
    custom = true,
    active = true,
  }))
  vim.cmd("RadioFavorites remove " .. other)
  H.eq(favorite_count(), 0, "removing an unfavorited station does not add it")

  ------------------------------------------------------------------
  -- RadioVolume accepts absolute and relative values.
  ------------------------------------------------------------------
  engine.status.volume = 50
  vim.cmd("RadioVolume +5")
  H.eq(engine.status.volume, 55, "relative volume increase")
  vim.cmd("RadioVolume 70")
  H.eq(engine.status.volume, 70, "absolute volume")

  engine:shutdown()
end
