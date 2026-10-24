local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  local Engine = require("radio.engine")
  local model = require("radio.model")
  local http = require("radio.http")
  local Player = require("radio.player")
  config.setup({ data_dir = H.tmpdir("async"), auto_sync_days = 0, api_url = "http://example.test" })
  local e = assert(Engine.new({ auto_sync = false }))
  local original_get, original_start = http.get, Player.start
  local starts = 0
  Player.start = function()
    starts = starts + 1
    return {
      close = function(_, cb)
        if cb then
          cb()
        end
      end,
    }
  end
  local station = model.station({
    stationuuid = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    name = "A",
    url = "http://example.test/a",
    active = true,
  })
  e.store:upsert(station)
  local refresh
  e.directory.refresh = function(_, _, cb)
    refresh = cb
  end
  e:play_station(station)
  e:_fail_playback("dead")
  e:stop_playback()
  refresh(nil, station)
  H.eq(starts, 1, "directory response cannot restart stopped playback")
  e:play_station(station)
  e:_fail_playback("dead")
  e:play("http://example.test/b")
  refresh("network error", nil)
  H.eq(e.status.playback_state, "connecting", "old refresh errors cannot fail new playback")
  refresh(nil, station)
  H.eq(e.status.source_url, "http://example.test/b", "old refresh cannot replace new station")

  local response, cancelled
  http.get = function(_, _, cb)
    response = cb
    return {
      cancel = function()
        cancelled = true
      end,
    }
  end
  e:sync()
  e:shutdown()
  H.eq(cancelled, true, "shutdown cancels the running curl request")
  H.check(pcall(response, nil, "[]", 200), "late sync response cannot touch a closed store")
  H.check(pcall(response, "network error"), "late sync failure cannot touch a closed store")
  H.check(pcall(refresh, nil, station), "late station refresh is harmless after shutdown")

  -- Closing during discovery must not reach directory_count or begin_sync.
  local Directory = require("radio.directory")
  local d = Directory.new()
  local called = false
  d:sync({}, {}, function()
    called = true
  end)
  d:close()
  H.check(
    pcall(response, nil, '[{"name":"de1.api.radio-browser.info"}]'),
    "late discovery is harmless"
  )
  H.eq(called, false, "cancelled discovery suppresses sync continuation")
  http.get, Player.start = original_get, original_start
end
