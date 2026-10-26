local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  config.setup({
    data_dir = H.tmpdir("sync-faults"),
    auto_sync_days = 0,
    api_url = "https://example.test",
  })
  local engine = assert(require("radio.engine").new({ auto_sync = false }))
  local http = require("radio.http")
  local get, response = http.get, nil
  http.get = function(_, _, cb)
    response = cb
    return { cancel = function() end }
  end
  local body = vim.json.encode({
    {
      stationuuid = "11111111-2222-4333-8444-555555555555",
      name = "Sync faults",
      url = "https://example.test/live",
    },
  })
  local store, set_meta = engine.store, engine.store.set_meta
  local function block_report(self, key, value)
    if key == "last_sync_attempt" then
      error("SQLITE_FULL: diagnostic write")
    end
    return set_meta(self, key, value)
  end
  local notify = vim.notify
  vim.notify = function() end
  for _, scenario in ipairs({
    "directory_count",
    "begin_sync",
    "stage",
    "incoming_count",
    "finish_sync",
    "network",
    "json",
    "empty",
    "shrink",
    "report",
  }) do
    local original = store[scenario]
    if original then
      store[scenario] = function()
        error("SQLITE_FULL: " .. scenario)
      end
    end
    local count = store.directory_count
    if scenario == "shrink" then
      store.directory_count = function()
        return 10
      end
    end
    store.set_meta = block_report
    local callbacks, sync_err = 0, nil
    response = nil
    H.check(
      pcall(engine.sync, engine, {}, function(err)
        callbacks, sync_err = callbacks + 1, err
      end),
      scenario .. " starts without unwinding"
    )
    if response then
      local pending = response
      local err = scenario == "network" and "network unavailable" or nil
      local data = scenario == "json" and "invalid json" or (scenario == "empty" and "[]" or body)
      H.check(pcall(pending, err, data), scenario .. " response handles database errors")
      H.check(pcall(pending, err, data), scenario .. " duplicate response is harmless")
    end
    H.eq(callbacks, 1, scenario .. " completes exactly once")
    H.eq(engine.syncing, false, scenario .. " clears the syncing state")
    if scenario == "report" then
      H.eq(sync_err, nil, "diagnostic write failure does not undo published success")
    else
      H.check(sync_err ~= nil, scenario .. " returns the original sync failure")
    end
    if original then
      store[scenario] = original
    end
    if scenario == "shrink" then
      store.directory_count = count
    end
    store.set_meta = set_meta
    local retry, retry_err = 0, nil
    engine:sync({}, function(err)
      retry, retry_err = retry + 1, err
    end)
    response(nil, body)
    H.eq(retry, 1, scenario .. " can retry after storage recovers")
    H.eq(retry_err, nil, scenario .. " retry succeeds")
  end
  http.get, vim.notify = get, notify
  engine:shutdown()
end
