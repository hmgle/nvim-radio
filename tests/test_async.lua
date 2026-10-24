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
  -- Exercise actual curl cancellation as well as simulated late responses.
  local slow, stop = H.start_blackhole()
  local callbacks = 0
  local request = http.get(slow, { timeout = 5 }, function()
    callbacks = callbacks + 1
  end)
  request:cancel()
  request:cancel()
  local killed = request.handle:wait(2000)
  H.check(killed.code ~= 0 or killed.signal ~= 0, "cancel kills the real curl process")
  H.eq(callbacks, 0, "cancel suppresses real HTTP completion")
  stop()
  local original_system = vim.system
  vim.system = function()
    error("missing curl")
  end
  local missing
  local failed = http.get("http://example.test", {}, function(err)
    missing = err
  end)
  vim.system = original_system
  H.wait_for(1000, function()
    return missing ~= nil
  end, "curl spawn failure completes asynchronously")
  H.check(missing:find("missing curl", 1, true) ~= nil, "curl spawn failure preserves its reason")
  H.check(pcall(failed.cancel, failed), "completed HTTP task can be cancelled harmlessly")
end
