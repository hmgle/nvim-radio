local H = require("tests.helpers")

return function()
  local Store = require("radio.store")
  local model = require("radio.model")
  local util = require("radio.util")
  local path = H.tmpdir("unicode-search") .. "/radio.db"
  local store = assert(Store.open(path))
  local supports_fts = store.fts5
  local target = model.station({
    stationuuid = "11111111-2222-4333-8444-555555555555",
    name = "ÉCOLE Über Радио",
    url = "https://example.test/live",
    language = "FRANÇAIS",
    tags = "ÉLECTRO,НОВОСТИ",
    active = true,
  })
  store:upsert(target)
  H.eq(
    util.lower(target.name),
    "école über радио",
    "Unicode lowercase covers Latin accents and Cyrillic"
  )
  -- Populate enough unrelated rows to make the FTS planner choose a candidate.
  for i = 1, 12 do
    store:upsert(model.station({
      stationuuid = string.format("%08d-1111-4111-8111-%012d", i, i),
      name = "Other station " .. i,
      url = "https://example.test/" .. i,
      active = true,
    }))
  end
  store:refresh_search_stats()
  local function search_cases(label)
    for _, query in ipairs({ "ÉCOLE", "école", "Über", "über", "Радио", "радио" }) do
      local rows, count = store:search({ query = query })
      H.eq(count, 1, label .. " finds " .. query)
      H.eq(
        rows[1] and rows[1].stationuuid,
        target.stationuuid,
        label .. " returns the expected station"
      )
    end
    H.eq(#store:search({ language = "français" }), 1, label .. " normalizes language filters")
    H.eq(#store:search({ tag = "électro" }), 1, label .. " normalizes tag filters")
    H.eq(
      #store:search({ tag = "НОВОСТИ" }),
      1,
      label .. " normalizes uppercase Cyrillic filters"
    )
    H.eq(
      store:facets(2, "é")[1] and store:facets(2, "é")[1].value,
      "électro",
      label .. " normalizes facets"
    )
  end
  if store.fts5 then
    H.check(
      store:_trigram_candidate("école") ~= nil,
      "Unicode query exercises FTS candidate search"
    )
  end
  search_cases("indexed")
  store.fts5 = false
  search_cases("substring")
  store.fts5 = supports_fts

  -- Simulate the derived columns written by older releases.
  store._db:execute("UPDATE stations SET search=?1,languages=?2,tags=?3 WHERE uuid=?4", {
    "École Über Радио",
    ",franÇais,",
    ",Électro,НОВОСТИ,",
    target.stationuuid,
  })
  store._db:execute("DELETE FROM meta WHERE key='search_text_normalization'")
  store:rebuild_facets()
  store:close()

  -- Failed conversion must roll back both derived data and its version marker.
  local probe = assert(require("radio.store.sqlite").open(path))
  local Db = getmetatable(probe)
  local db_execute = Db.execute
  probe:close()
  Db.execute = function(self, sql, args)
    if sql:find("UPDATE stations SET search", 1, true) then
      error("injected Unicode migration failure")
    end
    return db_execute(self, sql, args)
  end
  local failed, migration_err = Store.open(path)
  Db.execute = db_execute
  H.check(
    not failed and tostring(migration_err):find("injected Unicode", 1, true),
    "failed Unicode migration reports the storage error"
  )
  probe = assert(require("radio.store.sqlite").open(path))
  H.eq(
    #probe:execute("SELECT value FROM meta WHERE key='search_text_normalization'"),
    0,
    "failed migration leaves its marker unset"
  )
  H.eq(
    probe:execute("SELECT search FROM stations WHERE uuid=?1", { target.stationuuid })[1].search,
    "École Über Радио",
    "failed migration retains previous search text"
  )
  probe:close()
  store = assert(Store.open(path))
  search_cases("migrated")
  H.eq(store._db:pragma("user_version"), "5", "Unicode migration preserves the shared schema")
  H.eq(
    store:station(target.stationuuid).name,
    target.name,
    "Unicode migration preserves display text"
  )
  local mutations = 0
  local execute = store._db.execute
  store._db.execute = function(self, sql, args)
    if sql:find("UPDATE stations", 1, true) then
      mutations = mutations + 1
    end
    return execute(self, sql, args)
  end
  store:migrate()
  H.eq(mutations, 0, "Unicode migration is not repeated after success")
  store._db.execute = execute

  local async_done = false
  local timer = vim.uv.new_timer()
  timer:start(0, 0, function()
    timer:close()
    local ok, err = pcall(function()
      store:begin_sync()
      store:stage({ target })
      store:finish_sync()
      H.eq(#store:search({ query = "école" }), 1, "Unicode normalization works in libuv callbacks")
    end)
    H.check(ok, "asynchronous normalization does not throw: " .. tostring(err))
    async_done = true
  end)
  H.wait_for(2000, function()
    return async_done
  end, "Unicode sync callback completes")
  store:close()
end
