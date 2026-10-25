local H = require("tests.helpers")

return function()
  local Store = require("radio.store")
  local model = require("radio.model")
  local dir = H.tmpdir("store-edges")
  local path = dir .. "/radio.db"
  local store = assert(Store.open(path))
  local rows = {}
  for i = 1, 120 do
    rows[i] = model.station({
      stationuuid = string.format("%08x-5151-4515-8515-515151515151", i),
      name = "Station " .. i,
      url = "https://example.test/" .. i,
      active = true,
    })
    store:upsert(rows[i])
  end
  local seen, order = {}, {}
  for offset = 0, 110, 10 do
    local page = store:search({ sort = "random", limit = 10, offset = offset })
    for _, station in ipairs(page) do
      seen[station.stationuuid] = true
      order[#order + 1] = station.stationuuid
    end
  end
  H.eq(#order, 120, "random pages return every row")
  H.eq(vim.tbl_count(seen), 120, "random pages contain no duplicates")
  local page = store:search({ sort = "random", limit = 10, offset = 10 })
  H.eq(page[1].stationuuid, order[11], "revisiting random page preserves order")
  H.eq(
    store:station_position(order[11], { sort = "random" }),
    10,
    "random position agrees with pagination"
  )

  store:begin_sync()
  local execute, writes = store._db.execute, 0
  store._db.execute = function(self, sql, args)
    if sql:find("INSERT INTO incoming", 1, true) then
      writes = writes + 1
      if writes == 2 then
        error("injected stage failure")
      end
    end
    return execute(self, sql, args)
  end
  H.check(not pcall(store.stage, store, rows), "staging failure is reported")
  store._db.execute = execute
  H.eq(store:incoming_count(), 0, "staging failure rolls back the batch")

  -- A table belonging to another client must never be mistaken for FTS.
  store._db:exec("DROP TABLE station_search")
  store._db:exec("CREATE TABLE station_search (data TEXT)")
  store._db:exec("PRAGMA user_version=4")
  store:close()
  for round = 1, 2 do
    store = assert(Store.open(path))
    H.eq(store.fts5, false, "conflicting table disables FTS on open " .. round)
    H.eq(
      #store:search({ query = "Station 120" }),
      1,
      "fallback search works with conflicting table"
    )
    store:upsert(rows[1])
    H.eq(store._db:pragma("user_version"), "5", "optional FTS does not block core migration")
    store:close()
  end

  -- Rebuild failure must roll back optional objects and be retried next open.
  path = H.tmpdir("fts-rebuild") .. "/radio.db"
  store = assert(Store.open(path))
  store:upsert(rows[1])
  store._db:exec("DELETE FROM meta WHERE key='station_search_ready'")
  store._db:exec("INSERT INTO station_search(station_search) VALUES ('delete-all')")
  local Db = getmetatable(store._db)
  local exec = Db.exec
  store:close()
  Db.exec = function(self, sql)
    if sql:find("VALUES ('rebuild')", 1, true) then
      return nil, "injected rebuild failure"
    end
    return exec(self, sql)
  end
  store = assert(Store.open(path))
  Db.exec = exec
  H.eq(store.fts5, false, "failed rebuild disables FTS")
  H.eq(store:meta("station_search_ready"), nil, "failed rebuild cannot mark index ready")
  H.eq(#store:search({ query = "Station 1" }), 1, "failed rebuild uses substring search")
  store:close()
  store = assert(Store.open(path))
  H.eq(store.fts5, true, "next open retries rebuilding FTS")
  H.eq(#store:search({ query = "Station 1" }), 1, "rebuilt index contains existing stations")
  store:close()
end
