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
  vim.cmd([[RadioRecord 30 --output-dir /tmp/My\ Music]])
  H.eq(captured.duration, 30, "escaped directory keeps its duration")
  H.eq(captured.dir, "/tmp/My Music", "Ex-escaped spaces remain in the directory")
  vim.cmd([[RadioRecord --output-dir /tmp/My\ Music 45s]])
  H.eq(captured.duration, 45, "duration after an escaped directory is parsed")
  H.eq(captured.dir, "/tmp/My Music", "escaped directory before duration stays intact")
  vim.cmd([[RadioRecord --output-dir /tmp/radio\\files]])
  H.eq(captured.dir, [[/tmp/radio\files]], "Ex-escaped backslashes remain in the directory")
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

  local notify = vim.notify
  local notifications = {}
  vim.notify = function(message, level)
    notifications[#notifications + 1] = { message, level }
  end
  for _, command in ipairs({
    "RadioRecord abc",
    "RadioRecord --output-dir",
    "RadioRecord 30 45",
    "RadioRecord --output-dir /tmp/music 30 45",
    "RadioRecord --output-dir /tmp/music --output-dir /tmp/other",
    "RadioRecord --unknown-option",
    "RadioRecordings remove nope",
    "RadioFavorites add not-a-uuid",
    "RadioStationAdd Foo notaurl",
  }) do
    notifications = {}
    H.check(pcall(vim.cmd, command), "invalid command reports without traceback: " .. command)
    H.eq(#notifications, 1, "invalid command emits one error")
    H.eq(
      notifications[1] and notifications[1][2],
      vim.log.levels.ERROR,
      "invalid command notifies at error level"
    )
  end
  local original_engine = radio.engine
  radio.engine = function()
    return nil, "media_busy: test owner"
  end
  for _, command in ipairs({
    "RadioVolume 70",
    "RadioVolume +5",
    "RadioPause",
    "RadioRecord",
    "RadioRandom",
  }) do
    notifications = {}
    H.check(pcall(vim.cmd, command), "busy command reports without traceback: " .. command)
    H.check(
      #notifications == 1 and notifications[1][1]:find("media_busy", 1, true),
      "busy reason reaches user"
    )
  end
  radio.engine = original_engine
  local open = vim.ui.open
  vim.ui.open = function()
    error("opener missing")
  end
  H.check(pcall(radio.open_recordings), "platform opener launch failure is reported")
  vim.ui.open = open
  vim.notify = notify

  engine:shutdown()
end
