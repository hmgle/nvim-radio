local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  local Engine = require("radio.engine")
  local Store = require("radio.store")
  local model = require("radio.model")
  local Player = require("radio.player")
  local dir = H.tmpdir("resume-requests")
  config.setup({ data_dir = dir, auto_sync_days = 0, resume = true })
  local store = assert(Store.open(config.options.db_path))
  local previous, explicit =
    "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
  for id, name in pairs({ [previous] = "Previous", [explicit] = "Explicit" }) do
    store:save_custom(model.station({
      stationuuid = id,
      name = name,
      url = "https://example.test/" .. name,
      active = true,
    }))
  end
  store:set_meta("pref_last_station", previous)
  local path = dir .. "/recording.mp3"
  vim.fn.writefile({ "audio" }, path)
  store:save_recording(model.recording({ id = "local", path = path, status = "complete" }))
  store:close()

  local original, starts = Player.start, {}
  Player.start = function(opts, _, cb)
    starts[#starts + 1] = opts.url
    local player = {
      close = function(_, done)
        if done then
          done()
        end
      end,
    }
    cb(nil, player)
    return player
  end
  local cases = {
    { "automatic", function() end, "https://example.test/Previous", 1 },
    {
      "station",
      function(e)
        e:play(explicit)
      end,
      "https://example.test/Explicit",
      1,
    },
    {
      "URL",
      function(e)
        e:play("https://example.test/direct")
      end,
      "https://example.test/direct",
      1,
    },
    {
      "recording",
      function(e)
        e:play_recording("local")
      end,
      path,
      1,
    },
    {
      "random",
      function(e)
        e:random({ query = "Explicit" })
      end,
      "https://example.test/Explicit",
      1,
    },
    {
      "stop",
      function(e)
        e:stop_playback()
      end,
      nil,
      0,
    },
    {
      "invalid target",
      function(e)
        e:play("invalid")
      end,
      nil,
      0,
    },
    {
      "shutdown",
      function(e)
        e:shutdown()
      end,
      nil,
      0,
    },
  }
  for _, case in ipairs(cases) do
    starts = {}
    local engine = assert(Engine.new({ auto_sync = false }))
    case[2](engine)
    -- A FIFO sentinel proves the pending resume callback has had its turn.
    local drained = false
    vim.schedule(function()
      drained = true
    end)
    H.wait_for(1000, function()
      return drained
    end, case[1] .. " drains scheduled resume")
    H.eq(#starts, case[4], case[1] .. " starts only the requested playback")
    H.eq(starts[#starts], case[3], case[1] .. " retains the intended source")
    engine:shutdown()
  end
  Player.start = original
end
