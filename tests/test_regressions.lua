-- Regression tests for the review findings: field loss, migration, locks,
-- session isolation, refresh bounds, shutdown finalization, and recovery.
local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  local model = require("radio.model")
  local sqlite = require("radio.store.sqlite")
  local Store = require("radio.store")
  local Recorder = require("radio.recorder")
  local Engine = require("radio.engine")

  ------------------------------------------------------------------
  -- Recording fields survive the model and the database.
  ------------------------------------------------------------------
  local dir = H.tmpdir("regress-model")
  config.setup({ data_dir = dir, recording_min_free_mb = 1, auto_sync_days = 0 })
  local store = assert(Store.open(config.options.db_path))
  local full = model.recording({
    id = "reg-1",
    stationuuid = "14141414-1414-4414-8414-141414141414",
    station_name = "字段 Station",
    track = " Artist - 歌曲 ",
    source_url_resolved = "https://example.com/live",
    started_at = "2026-02-01T10:00:00Z",
    stopped_at = "2026-02-01T10:05:00Z",
    media_duration_ms = 300000,
    codec = "mp3",
    container = "mp3",
    path = dir .. "/recordings/reg-1.mp3.part",
    final_path = dir .. "/recordings/reg-1.mp3",
    size_bytes = 4242,
    status = "complete",
    error = "some error",
    reconnects = 3,
    recovery_pending = false,
  })
  store:save_recording(full)
  local loaded = store:recording("reg-1")
  H.eq(loaded.track, " Artist - 歌曲 ", "track persisted")
  H.eq(loaded.final_path, dir .. "/recordings/reg-1.mp3", "final_path persisted")
  H.eq(loaded.stopped_at, "2026-02-01T10:05:00Z", "stopped_at persisted")
  H.eq(loaded.media_duration_ms, 300000, "media_duration_ms persisted")
  H.eq(loaded.error, "some error", "error persisted")
  H.eq(loaded.reconnects, 3, "reconnects persisted")
  store:close()

  ------------------------------------------------------------------
  -- A v2 database with stations upgrades to v5.
  ------------------------------------------------------------------
  local old_dir = H.tmpdir("regress-migrate")
  local db = assert(sqlite.open(old_dir .. "/radio.db"))
  assert(
    db:exec(
      [[
    CREATE TABLE stations (uuid TEXT PRIMARY KEY, name TEXT NOT NULL, search TEXT NOT NULL,
      country TEXT NOT NULL, languages TEXT NOT NULL, tags TEXT NOT NULL, bitrate INTEGER NOT NULL,
      popularity INTEGER NOT NULL, custom INTEGER NOT NULL, active INTEGER NOT NULL, json TEXT NOT NULL)]]
    )
  )
  assert(
    db:exec(
      "CREATE TABLE favorites (uuid TEXT PRIMARY KEY REFERENCES stations(uuid), created_at TEXT NOT NULL)"
    )
  )
  assert(
    db:exec(
      "CREATE TABLE history (id INTEGER PRIMARY KEY, uuid TEXT NOT NULL REFERENCES stations(uuid), played_at TEXT NOT NULL)"
    )
  )
  assert(
    db:exec(
      "CREATE TABLE streams (uuid TEXT NOT NULL REFERENCES stations(uuid), url TEXT NOT NULL, PRIMARY KEY(uuid,url))"
    )
  )
  assert(
    db:exec(
      "CREATE TABLE recordings (id TEXT PRIMARY KEY, status TEXT NOT NULL, json TEXT NOT NULL)"
    )
  )
  assert(db:exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"))
  db:execute(
    "INSERT INTO stations (uuid,name,search,country,languages,tags,bitrate,popularity,custom,active,json) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
    {
      "15151515-1515-4515-8515-151515151515",
      "Legacy",
      "legacy",
      "FR",
      ",french,",
      ",jazz,",
      128,
      5,
      0,
      1,
      vim.json.encode({
        stationuuid = "15151515-1515-4515-8515-151515151515",
        name = "Legacy",
        url = "https://example.com/legacy",
        url_resolved = "https://resolved.example.com/legacy",
        countrycode = "fr",
        language = "french",
        tags = "jazz",
        bitrate = 128,
        clickcount = 5,
        active = true,
      }),
    }
  )
  db:execute("PRAGMA user_version=2")
  db:close()
  local migrated = assert(Store.open(old_dir .. "/radio.db"))
  H.eq(migrated._db:pragma("user_version"), "5", "v2 database upgraded")
  local rows = migrated._db:execute("SELECT normalized_url FROM stations")
  H.eq(
    rows[1] and rows[1].normalized_url,
    "https://resolved.example.com/legacy",
    "normalized_url backfilled"
  )
  H.eq(#migrated:facets(0, "", 10), 1, "facets rebuilt during migration")
  migrated:close()

  ------------------------------------------------------------------
  -- Session lock: live owner blocks, force overrides, stale is taken over.
  ------------------------------------------------------------------
  local lock_dir = H.tmpdir("regress-lock")
  config.setup({ data_dir = lock_dir, auto_sync_days = 0 })
  vim.fn.mkdir(lock_dir .. "/run", "p")
  local owner = assert(require("radio.lock").acquire(lock_dir .. "/run"))
  local blocked, block_err = Engine.new({ auto_sync = false })
  H.check(blocked == nil and block_err:find("media_busy"), "live owner blocks startup")
  local forced = assert(Engine.new({ auto_sync = false, force = true }))
  forced:shutdown()
  H.eq(require("radio.lock").acquire(lock_dir .. "/run"), nil, "bypass does not release owner")
  owner:release()
  local taken = assert(Engine.new({ auto_sync = false }))
  H.eq(taken.status.message, "ready", "released lock taken over")
  taken:shutdown()

  -- single_instance = false leaves no lock behind.
  local free_dir = H.tmpdir("regress-lock-off")
  config.setup({ data_dir = free_dir, auto_sync_days = 0, single_instance = false })
  local free = assert(Engine.new({ auto_sync = false }))
  H.eq(vim.uv.fs_stat(free_dir .. "/run/nvim-radio.pid"), nil, "no lock when single_instance=false")
  free:shutdown()

  ------------------------------------------------------------------
  -- A stale player callback cannot resurrect playback after a stop.
  ------------------------------------------------------------------
  local gen_dir = H.tmpdir("regress-generation")
  config.setup({ data_dir = gen_dir, auto_sync_days = 0 })
  local player_mod = require("radio.player")
  local captured_event
  local original_start = player_mod.start
  player_mod.start = function(_, on_event, on_started)
    captured_event = on_event
    vim.schedule(function()
      on_started(nil, {
        close = function() end,
        command = function() end,
        toggle_pause = function() end,
      })
    end)
    return { close = function() end }
  end
  local engine = assert(Engine.new({ auto_sync = false }))
  local uuid = "16161616-1616-4616-8616-161616161616"
  engine.store:save_custom(model.station({
    stationuuid = uuid,
    name = "Stale",
    url = "http://127.0.0.1:1/live.mp3",
    custom = true,
    active = true,
  }))
  engine:play(uuid)
  H.wait_for(3000, function()
    return captured_event ~= nil
  end, "player start callback captured")
  engine:stop_playback()
  captured_event({ type = "playing" })
  captured_event({ type = "title", title = "ghost" })
  H.eq(engine.status.playback_state, "idle", "stale playing event ignored after stop")
  H.eq(engine.status.title, "", "stale title ignored after stop")
  player_mod.start = original_start

  ------------------------------------------------------------------
  -- A station whose refresh keeps returning the same dead URL refreshes once.
  ------------------------------------------------------------------
  local refreshes = 0
  local dead = model.station({
    stationuuid = "17171717-1717-4717-8717-171717171717",
    name = "Dead",
    url = "http://127.0.0.1:1/live.mp3",
    url_resolved = "http://127.0.0.1:1/live.mp3",
    active = true,
    bitrate = 128,
  })
  engine.store:upsert(dead)
  engine.directory.refresh = function(_, _uuid, cb)
    refreshes = refreshes + 1
    cb(nil, dead)
  end
  engine:play(dead.stationuuid)
  H.wait_for(20000, function()
    return engine.status.playback_state == "failed"
  end, "dead station fails")
  vim.wait(500, function()
    return false
  end)
  H.check(refreshes <= 1, "refresh bounded to one per play request (got " .. refreshes .. ")")
  engine:shutdown()

  ------------------------------------------------------------------
  -- Recovery publishes a finalizing recording instead of failing.
  ------------------------------------------------------------------
  local rec_dir = H.tmpdir("regress-recover")
  config.setup({ data_dir = rec_dir, recording_min_free_mb = 1, auto_sync_days = 0 })
  local rec_store = assert(Store.open(config.options.db_path))
  local partial = rec_dir .. "/recordings/pending.mp3.part"
  local final_path = rec_dir .. "/recordings/pending.mp3"
  vim.fn.mkdir(rec_dir .. "/recordings", "p")
  local fd = assert(vim.uv.fs_open(partial, "w", 420))
  vim.uv.fs_write(fd, string.rep("x", 2048))
  vim.uv.fs_close(fd)
  rec_store:save_recording(model.recording({
    id = "finalizing-1",
    stationuuid = "18181818-1818-4818-8818-181818181818",
    station_name = "Finalizing",
    path = partial,
    final_path = final_path,
    status = "finalizing",
    started_at = "2026-03-01T00:00:00Z",
    size_bytes = 2048,
  }))
  local warnings = Recorder.recover(rec_store, { ffprobe = "ffprobe" })
  H.eq(#warnings, 0, "finalizing recovery reports no warnings")
  local recovered = rec_store:recording("finalizing-1")
  H.eq(recovered.status, "complete", "finalizing recording published")
  H.eq(recovered.path, final_path, "path updated to the published file")
  H.eq(recovered.recovery_pending, false, "recovery flag cleared")
  H.check(vim.uv.fs_stat(final_path) ~= nil, "published file exists")
  H.eq(vim.uv.fs_stat(partial), nil, "partial removed after publication")
  H.eq(#rec_store:unfinished_recordings(), 0, "nothing pending after recovery")
  rec_store:close()
end
