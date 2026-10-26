local H = require("tests.helpers")

return function()
  local model = require("radio.model")
  local store = assert(require("radio.store").open(H.tmpdir("sync-publication") .. "/radio.db"))
  local rows = {}
  for i = 1, 3 do
    rows[i] = model.station({
      stationuuid = string.format("%08d-1111-4111-8111-%012d", i, i),
      name = "Station " .. i,
      url = "https://example.test/" .. i,
      countrycode = "DE",
      tags = "music,jazz",
      active = true,
    })
  end
  store:begin_sync()
  store:stage(rows)
  store:finish_sync()
  assert(store._db:exec([[
    CREATE TEMP TABLE mutations(uuid TEXT);
    CREATE TEMP TRIGGER audit_station_update AFTER UPDATE ON stations BEGIN
      INSERT INTO mutations VALUES (new.uuid);
    END;
  ]]))
  store:begin_sync()
  store:stage(rows)
  store:finish_sync()
  H.eq(
    #store._db:execute("SELECT * FROM mutations"),
    0,
    "unchanged snapshots do not rewrite stations"
  )

  -- A vanished row is deactivated once; changed rows stay active throughout
  -- publication. Custom stations win UUID collisions with incoming rows.
  local custom = model.station({
    stationuuid = rows[3].stationuuid,
    name = "Custom station",
    url = "https://custom.test/live",
    tags = "custom",
    active = true,
    custom = true,
  })
  store:save_custom(custom)
  store:set_favorite(rows[1].stationuuid, true)
  store._db:execute("DELETE FROM mutations")
  rows[2].name = "Changed station"
  rows[2].tags = "news"
  store:begin_sync()
  store:stage({ rows[2], rows[3] })
  store:finish_sync()
  H.eq(
    #store._db:execute("SELECT * FROM mutations"),
    2,
    "publication updates only changed or vanished rows"
  )
  H.eq(store:station(rows[1].stationuuid).active, false, "vanished station becomes inactive")
  H.eq(#store:search({ favorites = true }), 1, "vanished favorites remain accessible")
  H.eq(
    store:station(rows[3].stationuuid).name,
    custom.name,
    "incoming UUID collision preserves custom station"
  )
  H.eq(store:facets(2, "news")[1].count, 1, "changed facets are counted")
  H.eq(#store:facets(2, "jazz"), 0, "vanished and overridden facets are removed")
  H.eq(store:facets(2, "custom")[1].count, 1, "custom facets survive publication")
  H.eq(#store:search({ query = "Changed station" }), 1, "FTS sees updated station text")

  local original = store.rebuild_facets
  store.rebuild_facets = function()
    error("injected publication failure")
  end
  store:begin_sync()
  store:stage({ rows[1] })
  H.check(not pcall(store.finish_sync, store), "publication failure is reported")
  store.rebuild_facets = original
  H.eq(store:station(rows[1].stationuuid).active, false, "failed publication rolls back activation")
  H.eq(
    store:station(rows[2].stationuuid).active,
    true,
    "failed publication rolls back deactivation"
  )
  H.eq(store:facets(2, "news")[1].count, 1, "failed publication retains facets")
  if store.fts5 then
    local before = store._db:execute("SELECT n FROM station_search_stats WHERE term=''")[1].n
    local execute = store._db.execute
    store._db.execute = function(self, sql, args)
      if sql:find("INSERT INTO station_search_stats", 1, true) then
        error("injected stats failure")
      end
      return execute(self, sql, args)
    end
    H.check(pcall(store.refresh_search_stats, store), "advisory stats failure stays nonfatal")
    store._db.execute = execute
    H.eq(
      store._db:execute("SELECT n FROM station_search_stats WHERE term=''")[1].n,
      before,
      "failed stats refresh preserves previous hints"
    )
  end
  store:close()
end
