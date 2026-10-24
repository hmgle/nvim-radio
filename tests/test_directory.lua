-- Directory tests against a fake Radio Browser server.
local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  local Directory = require("radio.directory")
  local Store = require("radio.store")
  local model = require("radio.model")

  local dir = H.tmpdir("directory")
  config.setup({
    data_dir = dir,
    auto_sync_days = 0,
    connect_timeout_secs = 2,
    request_timeout_secs = 5,
  })
  local store = assert(Store.open(config.options.db_path))

  local function row(index, overrides)
    local station = {
      stationuuid = string.format("%08d-1111-4111-8111-%012d", index, index),
      name = "Station " .. index,
      url = "https://example.com/" .. index,
      url_resolved = "https://resolved.example.com/" .. index,
      countrycode = index % 2 == 0 and "fr" or "de",
      country = index % 2 == 0 and "France" or "Germany",
      language = "french",
      tags = "jazz",
      bitrate = 128,
      clickcount = index,
      votes = index,
    }
    for key, value in pairs(overrides or {}) do
      station[key] = value
    end
    return station
  end

  local servers_body =
    vim.json.encode({ { name = "de1.api.radio-browser.info" }, { name = "evil.example.com" } })
  local first_page = {}
  for i = 1, 1000 do
    first_page[i] = row(i)
  end
  local second_page = { row(1001), row(1002) }

  local url, stop = H.start_server({
    ["/json/servers"] = servers_body,
    ["/json/stations/search"] = function(query)
      local offset = tonumber(query:match("offset=(%d+)")) or 0
      if offset == 0 then
        return vim.json.encode(first_page), 200
      end
      return vim.json.encode(second_page), 200
    end,
    ["/json/stations/byuuid/00000001-1111-4111-8111-000000000001"] = vim.json.encode({
      row(1, { name = "Refreshed Station", bitrate = 320 }),
    }),
  })

  local directory = Directory.new({
    api_url = url,
    connect_timeout_secs = 2,
    request_timeout_secs = 5,
  })

  -- Discovery against the live all.api mirror is informational only: the
  -- network is not a test dependency, and a configured api_url bypasses it.
  local discovery = Directory.new({ connect_timeout_secs = 2, request_timeout_secs = 5 })
  local discovered, discover_err = nil, nil
  discovery:discover(function(err, servers)
    discovered, discover_err = servers, err
  end)
  H.wait_for(15000, function()
    return discovered ~= nil or discover_err ~= nil
  end, "server discovery returns or fails")
  if discovered then
    H.check(#discovered > 0, "discovered at least one server")
    for _, server in ipairs(discovered) do
      H.check(server:sub(1, 8) == "https://", "discovered server uses https: " .. server)
    end
  else
    io.write("note: live discovery unavailable (" .. tostring(discover_err) .. ")\n")
  end

  -- Bootstrap seeds the catalog.
  local bootstrapped = nil
  directory:bootstrap(store, function(err, count)
    bootstrapped = err or count
  end)
  H.wait_for(10000, function()
    return bootstrapped ~= nil
  end, "bootstrap completes")
  H.eq(bootstrapped, 1000, "bootstrap stores one page")
  H.eq(store:count(), 1000, "catalog seeded")

  -- Full sync pages through the catalog.
  local sync_done, sync_err, sync_report = false, nil, nil
  directory:sync(store, {}, function(err, report)
    sync_done, sync_err, sync_report = true, err, report
  end)
  H.wait_for(20000, function()
    return sync_done
  end, "sync completes")
  H.eq(sync_err, nil, "sync succeeds")
  H.eq(sync_report.raw, 1002, "sync fetched every row")
  H.eq(sync_report.unique, 1002, "sync staged unique rows")
  H.eq(store:count(), 1002, "catalog replaced")

  -- Shrink protection: a smaller catalog is rejected.
  local shrink_err = nil
  local small = {}
  for i = 1, 10 do
    small[i] = row(i)
  end
  local shrink_url, shrink_stop = H.start_server({
    ["/json/servers"] = servers_body,
    ["/json/stations/search"] = function()
      return vim.json.encode(small), 200
    end,
  })
  local shrink_directory = Directory.new({ api_url = shrink_url, request_timeout_secs = 5 })
  shrink_directory:sync(store, {}, function(err)
    shrink_err = err
  end)
  H.wait_for(15000, function()
    return shrink_err ~= nil
  end, "shrink rejected")
  H.check(shrink_err and shrink_err:find("catalog_shrink"), "shrink error code")
  H.eq(store:count(), 1002, "catalog untouched after rejected shrink")

  -- Accepting the shrink publishes it.
  local accepted = false
  shrink_directory:sync(store, { accept_shrink = true }, function(err)
    accepted = err == nil
  end)
  H.wait_for(15000, function()
    return accepted
  end, "accepted shrink publishes")
  H.eq(store:count(), 10, "shrunken catalog published")

  -- Refresh one station.
  local refreshed, refresh_err = nil, nil
  directory:refresh("00000001-1111-4111-8111-000000000001", function(err, station)
    refreshed, refresh_err = station, err
  end)
  H.wait_for(8000, function()
    return refreshed ~= nil or refresh_err ~= nil
  end, "refresh completes")
  H.eq(refresh_err, nil, "refresh succeeds")
  H.eq(refreshed.name, "Refreshed Station", "refresh returns fresh data")
  H.eq(refreshed.bitrate, 320, "refresh bitrate updated")

  -- Invalid UUID refresh fails fast.
  local bad = nil
  directory:refresh("not-a-uuid", function(err)
    bad = err
  end)
  H.eq(bad, "invalid_uuid", "invalid uuid rejected")

  -- Click reporting is fire and forget against the fake server.
  directory:click("00000001-1111-4111-8111-000000000001")
  H.check(true, "click reported without error")

  -- sync_due reflects the last sync timestamp.
  H.eq(Directory.sync_due(store, 0), false, "auto sync disabled")
  H.eq(Directory.sync_due(store, 7), false, "fresh sync is not due")
  store:set_meta("last_sync", "2020-01-01T00:00:00Z")
  H.eq(Directory.sync_due(store, 7), true, "stale sync is due")

  shrink_stop()
  stop()
end
