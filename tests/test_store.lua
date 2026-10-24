-- Store tests: schema, search, facets, favorites, custom stations,
-- recordings, and sync staging.
local H = require("tests.helpers")

return function()
  local Store = require("radio.store")
  local model = require("radio.model")

  local dir = H.tmpdir("store")
  local store = assert(Store.open(dir .. "/radio.db"))
  H.check(store.fts5 ~= nil, "fts5 capability detected")

  local function station(uuid, name, extra)
    local s = model.station({
      stationuuid = uuid,
      name = name,
      url = "https://example.com/" .. uuid,
      url_resolved = "https://resolved.example.com/" .. uuid,
      country = "France",
      countrycode = "fr",
      language = "french",
      languagecodes = "fr",
      tags = "jazz,blues",
      bitrate = 128,
      clickcount = 500,
      active = true,
    })
    for key, value in pairs(extra or {}) do
      s[key] = value
    end
    return s
  end

  local uuid_a = "11111111-1111-4111-8111-111111111111"
  local uuid_b = "22222222-2222-4222-8222-222222222222"
  local uuid_c = "33333333-3333-4333-8333-333333333333"
  store:upsert(station(uuid_a, "Jazz FM"))
  store:upsert(station(uuid_b, "刚果之声", {
    country = "刚果",
    countrycode = "cd",
    language = "chinese",
    tags = "news",
    bitrate = 64,
    clickcount = 100,
  }))
  store:upsert(station(uuid_c, "Blues Bar", {
    country = "USA",
    countrycode = "us",
    language = "english",
    tags = "blues",
    bitrate = 256,
    clickcount = 900,
  }))

  H.eq(store:count(), 3, "count after upserts")
  H.eq(store:directory_count(), 3, "directory count")

  local all, total = store:search(model.filter({}))
  H.eq(#all, 3, "search returns all stations")
  H.eq(total, 3, "search total")
  H.eq(all[1].name, "Blues Bar", "default sort is clickcount desc")

  local jazz = store:search(model.filter({ query = "jazz" }))
  H.eq(#jazz, 1, "query matches one station")
  H.eq(jazz[1].name, "Jazz FM", "query result name")

  local china = store:search(model.filter({ query = "刚果" }))
  H.eq(#china, 1, "Chinese territory query widens the match")
  H.eq(china[1].name, "刚果之声", "Chinese query result name")

  H.eq(#store:search(model.filter({ country = "fr" })), 1, "country filter")
  H.eq(#store:search(model.filter({ language = "english" })), 1, "language filter")
  H.eq(#store:search(model.filter({ tag = "blues" })), 2, "tag filter counts both")
  H.eq(#store:search(model.filter({ min_bitrate = 200 })), 1, "min bitrate filter")
  local by_bitrate = store:search(model.filter({ sort = "bitrate" }))
  H.eq(by_bitrate[1].name, "Blues Bar", "bitrate sort")
  local by_name = store:search(model.filter({ sort = "name" }))
  H.eq(by_name[1].name, "Blues Bar", "name sort is case-insensitive")
  local page = store:search(model.filter({ limit = 2, offset = 1 }))
  H.eq(#page, 2, "limit/offset paging")

  H.eq(
    store:station_position(uuid_c, model.filter({ sort = "clickcount" })),
    0,
    "position of top station"
  )
  H.eq(
    store:station_position(uuid_a, model.filter({ sort = "clickcount" })),
    1,
    "position of middle station"
  )
  H.eq(
    store:station_position(uuid_b, model.filter({ sort = "clickcount" })),
    2,
    "position of last station"
  )

  -- Favorites and history.
  H.eq(store:toggle_favorite(uuid_a), true, "favorite added")
  H.eq(store:toggle_favorite(uuid_a), false, "favorite removed")
  store:toggle_favorite(uuid_a)
  local favorites = store:search(model.filter({ favorites = true }))
  H.eq(#favorites, 1, "favorites filter")
  H.eq(favorites[1].favorite, true, "favorite flag is live")
  store:played(uuid_b)
  local history = store:search(model.filter({ history = true }))
  H.eq(#history, 1, "history filter")
  H.eq(history[1].name, "刚果之声", "history result")

  -- Facets.
  local countries = store:facets(0, "", 10)
  H.eq(#countries, 3, "country facets")
  local languages = store:facets(1, "f", 10)
  H.eq(#languages, 2, "language prefix facets")

  -- Custom stations.
  local custom = model.station({
    stationuuid = "44444444-4444-4444-8444-444444444444",
    name = "My Cast",
    url = "https://cast.example.com/live",
    active = true,
  })
  store:save_custom(custom, { "https://cast.example.com/backup" })
  H.eq(#store:search(model.filter({ custom = true })), 1, "custom station searchable")
  H.eq(#store:backups("44444444-4444-4444-8444-444444444444"), 1, "backup stored")
  local duplicate = model.station({
    stationuuid = "55555555-5555-4555-8555-555555555555",
    name = "Dup",
    url = "https://cast.example.com/live",
    active = true,
  })
  local ok = pcall(store.save_custom, store, duplicate)
  H.check(not ok, "duplicate URL rejected")
  store:upsert(station("44444444-4444-4444-8444-444444444444", "Overwritten"))
  H.eq(
    store:station("44444444-4444-4444-8444-444444444444").name,
    "My Cast",
    "upsert skips custom rows"
  )
  H.eq(store:toggle_favorite("44444444-4444-4444-8444-444444444444"), true, "favorite custom")
  H.eq(
    store:remove_custom("44444444-4444-4444-8444-444444444444"),
    true,
    "referenced removal reported"
  )
  H.eq(#store:search(model.filter({ custom = true })), 0, "tombstoned station hidden")

  -- Recordings.
  store:save_recording(model.recording({
    id = "rec1",
    stationuuid = uuid_b,
    station_name = "刚果之声",
    path = "/tmp/x.part",
    status = "recording",
    started_at = "2026-01-01T00:00:00Z",
  }))
  store:save_recording(model.recording({
    id = "rec2",
    stationuuid = uuid_b,
    station_name = "刚果之声",
    path = "/tmp/y.mp3",
    status = "complete",
    started_at = "2026-01-02T00:00:00Z",
  }))
  H.eq(store:recordings_count(), 2, "recordings counted")
  H.eq(store:recordings()[1].id, "rec2", "recordings sorted by started_at desc")
  H.eq(#store:unfinished_recordings(), 1, "unfinished recording detected")

  -- Sync staging and publication.
  store:begin_sync()
  store:stage({
    station("66666666-6666-4666-8666-666666666666", "Synced One"),
    station("77777777-7777-4777-8777-777777777777", "Synced Two", {
      countrycode = "de",
      country = "Germany",
      language = "german",
      tags = "pop",
      clickcount = 42,
    }),
  })
  H.eq(store:incoming_count(), 2, "staged rows")
  H.eq(store:finish_sync(), 2, "publish returns staged count")
  H.eq(store:count(), 2, "old catalog deactivated")
  H.check(not store:station(uuid_a).active, "previous station inactive")
  H.check(store:station("44444444-4444-4444-8444-444444444444") ~= nil, "custom survives sync")
  local facets_after = store:facets(0, "", 10)
  H.eq(#facets_after, 2, "facets rebuilt on publish")
  H.eq(store:meta("last_sync") ~= nil, true, "last_sync recorded")

  -- Shrink protection is a directory-level policy; store only reports counts.
  H.eq(store:directory_count(), 2, "directory count after sync")

  store:close()
end
