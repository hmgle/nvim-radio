-- SQLite persistence: schema, migrations, and every catalog query.
-- Mirrors radio-cli's store semantics (schema v5) so both tools can share a
-- data directory; FTS5 trigram search degrades to LIKE when unavailable.
local sqlite = require("radio.store.sqlite")
local util = require("radio.util")
local model = require("radio.model")

local Store = {}
Store.__index = Store

Store.SCHEMA_VERSION = 5

local FACET_COUNTRY, FACET_LANGUAGE, FACET_TAG = 0, 1, 2

local BASE_SCHEMA = {
  [[CREATE TABLE IF NOT EXISTS stations (
    uuid TEXT PRIMARY KEY, name TEXT NOT NULL, search TEXT NOT NULL,
    country TEXT NOT NULL, languages TEXT NOT NULL, tags TEXT NOT NULL,
    bitrate INTEGER NOT NULL, popularity INTEGER NOT NULL,
    custom INTEGER NOT NULL, active INTEGER NOT NULL, json TEXT NOT NULL)]],
  [[CREATE INDEX IF NOT EXISTS station_country ON stations(country, bitrate)]],
  [[CREATE INDEX IF NOT EXISTS station_popularity ON stations(popularity DESC)]],
  [[CREATE TABLE IF NOT EXISTS favorites (
    uuid TEXT PRIMARY KEY REFERENCES stations(uuid), created_at TEXT NOT NULL)]],
  [[CREATE TABLE IF NOT EXISTS history (
    id INTEGER PRIMARY KEY, uuid TEXT NOT NULL REFERENCES stations(uuid),
    played_at TEXT NOT NULL)]],
  [[CREATE INDEX IF NOT EXISTS history_station ON history(uuid)]],
  [[CREATE TABLE IF NOT EXISTS streams (
    uuid TEXT NOT NULL REFERENCES stations(uuid), url TEXT NOT NULL,
    PRIMARY KEY(uuid,url))]],
  [[CREATE TABLE IF NOT EXISTS recordings (
    id TEXT PRIMARY KEY, status TEXT NOT NULL, json TEXT NOT NULL)]],
  [[CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)]],
}

local V2_SCHEMA = {
  [[ALTER TABLE recordings ADD COLUMN recovery_pending INTEGER NOT NULL DEFAULT 0
    CHECK(recovery_pending IN (0,1))]],
  [[UPDATE recordings SET recovery_pending=1 WHERE status='interrupted'
    AND json_extract(json,'$.error') LIKE '恢复失败:%']],
}

local V3_SCHEMA = {
  [[ALTER TABLE stations ADD COLUMN normalized_url TEXT]],
  [[CREATE INDEX IF NOT EXISTS station_url ON stations(normalized_url) WHERE active=1]],
}

local V4_SCHEMA = {
  [[CREATE TABLE IF NOT EXISTS facets_cache (
    kind INTEGER NOT NULL,value TEXT NOT NULL,n INTEGER NOT NULL CHECK(n>=0),
    PRIMARY KEY(kind,value)) WITHOUT ROWID]],
}

local V5_INDEXES = {
  [[CREATE INDEX IF NOT EXISTS station_sort ON stations(popularity DESC,name,uuid,active,custom,bitrate)]],
  [[CREATE INDEX IF NOT EXISTS station_name ON stations(name COLLATE NOCASE,uuid,active,custom,bitrate)]],
  [[CREATE INDEX IF NOT EXISTS station_bitrate ON stations(bitrate DESC,name,uuid,active,custom)]],
  [[CREATE INDEX IF NOT EXISTS station_active ON stations(active) WHERE active=1]],
  [[CREATE INDEX IF NOT EXISTS station_directory ON stations(active) WHERE active=1 AND custom=0]],
  [[DROP INDEX IF EXISTS station_popularity]],
}

local FTS_SCHEMA = {
  [[CREATE VIRTUAL TABLE IF NOT EXISTS station_search USING fts5(search,
    content='stations',content_rowid='rowid',columnsize=0,detail=none,
    tokenize='trigram case_sensitive 1')]],
  [[CREATE VIRTUAL TABLE IF NOT EXISTS station_search_terms USING fts5vocab(station_search,'row')]],
  [[CREATE TABLE IF NOT EXISTS station_search_stats(term TEXT PRIMARY KEY,n INTEGER NOT NULL) WITHOUT ROWID]],
  [[CREATE TRIGGER IF NOT EXISTS station_search_insert AFTER INSERT ON stations BEGIN
    INSERT INTO station_search(rowid,search) VALUES (new.rowid,new.search);
  END]],
  [[CREATE TRIGGER IF NOT EXISTS station_search_delete AFTER DELETE ON stations BEGIN
    INSERT INTO station_search(station_search,rowid,search) VALUES ('delete',old.rowid,old.search);
  END]],
  [[CREATE TRIGGER IF NOT EXISTS station_search_update AFTER UPDATE OF search ON stations
    WHEN old.search IS NOT new.search BEGIN
    INSERT INTO station_search(station_search,rowid,search) VALUES ('delete',old.rowid,old.search);
    INSERT INTO station_search(rowid,search) VALUES (new.rowid,new.search);
  END]],
}

---@return boolean
local function fts5_supported(db)
  local ok = db:exec("CREATE VIRTUAL TABLE IF NOT EXISTS temp.fts5_probe USING fts5(x)")
  db:exec("DROP TABLE IF EXISTS temp.fts5_probe")
  return ok
end

---Count (kind, value) pairs for one station; only active rows contribute.
---@param station table
---@return table<string, boolean> keys are "kind\0value"
local function station_values(station)
  local values = {}
  if not station.active then
    return values
  end
  local country = (station.countrycode or ""):upper()
  if country ~= "" then
    values[FACET_COUNTRY .. "\0" .. country] = true
  end
  for _, list in ipairs({ station.language, station.languagecodes }) do
    for item in (list or ""):gmatch("[^,]+") do
      local value = util.trim(item):lower()
      if value ~= "" then
        values[FACET_LANGUAGE .. "\0" .. value] = true
      end
    end
  end
  for item in (station.tags or ""):gmatch("[^,]+") do
    local value = util.trim(item):lower()
    if value ~= "" then
      values[FACET_TAG .. "\0" .. value] = true
    end
  end
  return values
end

local function facet_key(kind, value)
  return kind .. "\0" .. value
end

---@param kind integer
---@param prefix string
---@param limit integer|nil
---@param offset integer|nil
---@return table[]
function Store:facets(kind, prefix, limit, offset)
  prefix = util.trim(prefix or "")
  local sql = [[SELECT value,n FROM facets_cache WHERE kind=?1
    AND substr(value,1,length(?2))=?2 ORDER BY value LIMIT ?3 OFFSET ?4]]
  local rows = self._db:execute(sql, { kind, prefix, limit or 100000, offset or 0 })
  local out = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = { value = row.value, count = row.n }
  end
  return out
end

local function apply_facet_diff(db, before, after)
  for key in pairs(before) do
    if not after[key] then
      local kind, value = key:match("^(%d+)%z(.*)$")
      db:execute(
        "UPDATE facets_cache SET n=n-1 WHERE kind=?1 AND value=?2",
        { tonumber(kind), value }
      )
      db:execute(
        "DELETE FROM facets_cache WHERE kind=?1 AND value=?2 AND n=0",
        { tonumber(kind), value }
      )
    end
  end
  for key in pairs(after) do
    if not before[key] then
      local kind, value = key:match("^(%d+)%z(.*)$")
      db:execute(
        [[INSERT INTO facets_cache(kind,value,n) VALUES (?1,?2,1)
          ON CONFLICT(kind,value) DO UPDATE SET n=n+1]],
        { tonumber(kind), value }
      )
    end
  end
end

function Store:rebuild_facets()
  local db = self._db
  local counts = {}
  local rows = db:execute("SELECT country,languages,tags FROM stations WHERE active=1")
  for _, row in ipairs(rows) do
    local values = {}
    local country = (row.country or ""):upper()
    if country ~= "" then
      values[facet_key(FACET_COUNTRY, country)] = true
    end
    for _, column in ipairs({ "languages", "tags" }) do
      local kind = column == "languages" and FACET_LANGUAGE or FACET_TAG
      for item in (row[column] or ""):gmatch("[^,]+") do
        local value = util.trim(item):lower()
        if value ~= "" then
          values[facet_key(kind, value)] = true
        end
      end
    end
    for key in pairs(values) do
      counts[key] = (counts[key] or 0) + 1
    end
  end
  db:execute("DELETE FROM facets_cache")
  for key, n in pairs(counts) do
    local kind, value = key:match("^(%d+)%z(.*)$")
    db:execute(
      "INSERT INTO facets_cache(kind,value,n) VALUES (?1,?2,?3)",
      { tonumber(kind), value, n }
    )
  end
end

---Refresh planner statistics for trigram candidates (advisory).
function Store:refresh_search_stats()
  if not self.fts5 then
    return
  end
  local ok = pcall(function()
    local rows = self._db:execute([[
      SELECT term,doc FROM station_search_terms
      UNION ALL SELECT '',count(*) FROM stations]])
    self._db:execute("DELETE FROM station_search_stats")
    for _, row in ipairs(rows) do
      self._db:execute("INSERT INTO station_search_stats VALUES (?1,?2)", { row.term, row.doc })
    end
  end)
  if not ok then
    -- fts5vocab reads can fail mid-write; stats are hints only.
  end
end

---@param path string
---@return table|nil store, string|nil err
function Store.open(path)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local db, err = sqlite.open(path)
  if not db then
    return nil, err
  end
  db:exec("PRAGMA foreign_keys=ON")
  db:exec("PRAGMA journal_mode=WAL")
  db:exec("PRAGMA synchronous=NORMAL")
  db:exec("PRAGMA cache_size=-4096")
  local bytes = { assert(vim.uv.random(3)):byte(1, 3) }
  local seed = 1 + bytes[1] + bytes[2] * 256 + bytes[3] * 65536
  local self = setmetatable({ _db = db, path = path, random_seed = seed }, Store)
  local ok, migrate_err = pcall(self.migrate, self)
  if not ok then
    db:close()
    return nil, tostring(migrate_err)
  end
  return self
end

---Create or upgrade the schema up to SCHEMA_VERSION.
function Store:migrate()
  local db = self._db
  local version = tonumber(db:pragma("user_version")) or 0
  if version > Store.SCHEMA_VERSION then
    error("database_too_new: schema " .. version .. " > " .. Store.SCHEMA_VERSION, 0)
  end
  if version == 0 then
    for _, sql in ipairs(BASE_SCHEMA) do
      local ok, exec_err = db:exec(sql)
      if not ok then
        error("schema: " .. tostring(exec_err), 0)
      end
    end
  end
  if version < 2 then
    for _, sql in ipairs(V2_SCHEMA) do
      local ok = db:exec(sql)
      if not ok and not sql:find("recovery_pending") then
        error("migration 1->2: " .. tostring(sql), 0)
      end
    end
    db:exec("PRAGMA user_version=2")
  end
  if version < 3 then
    local has_column = #db:execute("PRAGMA table_info(stations)") > 0
    local found = false
    for _, column in ipairs(db:execute("PRAGMA table_info(stations)")) do
      if column.name == "normalized_url" then
        found = true
      end
    end
    if not found and has_column then
      -- One transaction: a failed backfill must not leave a half-upgraded DB.
      db:transaction(function()
        for _, sql in ipairs(V3_SCHEMA) do
          local ok, exec_err = db:exec(sql)
          if not ok then
            error("migration 2->3: " .. tostring(exec_err), 0)
          end
        end
        for _, row in ipairs(db:execute("SELECT uuid,json FROM stations")) do
          local station = model.decode(row.json)
          local normalized = station and util.normalize_url(station:primary_url()) or nil
          db:execute(
            "UPDATE stations SET normalized_url=?2 WHERE uuid=?1",
            { row.uuid, normalized }
          )
        end
      end)
    end
    db:exec("PRAGMA user_version=3")
  end
  if version < 4 then
    for _, sql in ipairs(V4_SCHEMA) do
      local ok, exec_err = db:exec(sql)
      if not ok then
        error("migration 3->4: " .. tostring(exec_err), 0)
      end
    end
    self:rebuild_facets()
    db:exec("PRAGMA user_version=4")
  end
  if version < 5 then
    for _, sql in ipairs(V5_INDEXES) do
      local ok = db:exec(sql)
      if not ok and not sql:find("DROP INDEX") then
        error("migration 4->5: " .. tostring(sql), 0)
      end
    end
    db:exec("ANALYZE")
    db:exec("PRAGMA user_version=5")
  end
  self:_prepare_search_index()
  return true
end

---FTS is optional and must be ready independently of the schema version.
function Store:_prepare_search_index()
  local db = self._db
  self.fts5 = false
  local object = db:execute("SELECT sql FROM sqlite_master WHERE name='station_search'")[1]
  local compatible = not object
    or (
      object.sql
      and object.sql:lower():find("create virtual table", 1, true)
      and object.sql:lower():find("using%s+fts5%s*%(")
      and object.sql:lower():find("trigram", 1, true)
    )
  if compatible and fts5_supported(db) then
    local ok, index_err = pcall(function()
      db:transaction(function()
        for _, sql in ipairs(FTS_SCHEMA) do
          local created, err = db:exec(sql)
          if not created then
            error(err, 0)
          end
        end
        if not object or self:meta("station_search_ready") ~= "1" then
          local rebuilt, err =
            db:exec("INSERT INTO station_search(station_search) VALUES ('rebuild')")
          if not rebuilt then
            error(err, 0)
          end
        end
        -- Verify MATCH is usable, including when opening an existing v5 DB.
        db:execute("SELECT rowid FROM station_search WHERE station_search MATCH 'rad' LIMIT 1")
        self:set_meta("station_search_ready", "1")
      end)
    end)
    self.fts5 = ok
    if not ok then
      require("radio.log").debug("FTS unavailable: " .. tostring(index_err))
    end
  end
  if not self.fts5 then
    -- Legacy failed migrations may have installed triggers for a conflicting
    -- ordinary table. Disable those writers before using substring search.
    for _, name in ipairs({
      "station_search_insert",
      "station_search_delete",
      "station_search_update",
    }) do
      db:exec("DROP TRIGGER IF EXISTS " .. name)
    end
    db:execute("DELETE FROM meta WHERE key='station_search_ready'")
  end
end

function Store:close()
  if self._db then
    self._db:close()
    self._db = nil
  end
end

---------------------------------------------------------------------------
-- Station writes
---------------------------------------------------------------------------

---Validate and persist one station row.
---@param station table
---@param custom boolean replace even when the row is custom
---@param maintain_facets boolean
function Store:_write_station(station, custom, maintain_facets)
  local ok, reason = model.valid_identity(station)
  if not ok then
    error(reason, 2)
  end
  station = model.station(station)
  local db = self._db
  local before = {}
  if maintain_facets then
    local rows = db:execute(
      "SELECT country,languages,tags,active FROM stations WHERE uuid=?1",
      { station.stationuuid }
    )
    if rows[1] and rows[1].active == 1 then
      before = station_values({
        countrycode = rows[1].country,
        language = rows[1].languages,
        languagecodes = "",
        tags = rows[1].tags,
        active = true,
      })
    end
  end
  local languages = ","
    .. util.normalize_list(station.language .. "," .. station.languagecodes)
    .. ","
  local tags = "," .. util.normalize_list(station.tags) .. ","
  local country = (station.countrycode or ""):upper()
  local popularity = math.floor(station.clickcount)
  local json = model.encode(station)
  local normalized = util.normalize_url(model.Station.primary_url(station))
  db:execute(
    [[INSERT INTO stations (uuid,name,search,country,languages,tags,bitrate,popularity,custom,active,json,normalized_url)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)
      ON CONFLICT(uuid) DO UPDATE SET name=excluded.name,search=excluded.search,
        country=excluded.country,languages=excluded.languages,tags=excluded.tags,
        bitrate=excluded.bitrate,popularity=excluded.popularity,custom=excluded.custom,
        active=excluded.active,json=excluded.json,normalized_url=excluded.normalized_url
      WHERE stations.custom=0 OR ?13]],
    {
      station.stationuuid,
      station.name,
      station:search_text(),
      country,
      languages,
      tags,
      math.floor(station.bitrate),
      popularity,
      station.custom and 1 or 0,
      station.active and 1 or 0,
      json,
      normalized,
      custom and 1 or 0,
    }
  )
  if maintain_facets then
    apply_facet_diff(db, before, station_values(station))
  end
end

---Catalog upsert: never overwrites an existing custom station.
---@param station table
function Store:upsert(station)
  self._db:transaction(function()
    self:_write_station(station, false, true)
  end)
end

---@param uuid string
---@return table|nil
function Store:station(uuid)
  local rows = self._db:execute(
    [[
    SELECT s.json,s.active,EXISTS(SELECT 1 FROM favorites f WHERE f.uuid=s.uuid) AS favorite
    FROM stations s WHERE s.uuid=?1]],
    { uuid }
  )
  if not rows[1] then
    return nil
  end
  local station = model.decode(rows[1].json)
  if not station then
    return nil
  end
  station.active = rows[1].active == 1
  station.favorite = rows[1].favorite == 1
  return station
end

---@param uuid string
---@return string[]
function Store:backups(uuid)
  local rows = self._db:execute("SELECT url FROM streams WHERE uuid=?1 ORDER BY rowid", { uuid })
  local out = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = row.url
  end
  return out
end

---@param uuid string
---@param url string
function Store:add_backup(uuid, url)
  local ok = util.validate_url(url)
  if not ok then
    error("invalid_url", 2)
  end
  self._db:execute("INSERT OR IGNORE INTO streams(uuid,url) VALUES (?1,?2)", { uuid, url })
end

---@param uuid string
---@param add string[]
---@param remove string[]
---@return string[]
function Store:update_backups(uuid, add, remove)
  if not self:station(uuid) then
    error("station_not_found", 2)
  end
  self._db:transaction(function()
    for _, url in ipairs(remove or {}) do
      self._db:execute("DELETE FROM streams WHERE uuid=?1 AND url=?2", { uuid, url })
    end
    for _, url in ipairs(add or {}) do
      self:add_backup(uuid, url)
    end
  end)
  return self:backups(uuid)
end

---------------------------------------------------------------------------
-- Search
---------------------------------------------------------------------------

---Split a string into UTF-8 characters (byte slicing would corrupt CJK).
---@param s string
---@return string[]
local function utf8_chars(s)
  local out = {}
  local i, len = 1, #s
  while i <= len do
    local b = s:byte(i)
    local width = 1
    if b >= 0xf0 then
      width = 4
    elseif b >= 0xe0 then
      width = 3
    elseif b >= 0xc0 then
      width = 2
    end
    out[#out + 1] = s:sub(i, i + width - 1)
    i = i + width
  end
  return out
end

---Pick the lowest-frequency trigram as an FTS candidate, mirroring
---radio-cli's trigram_candidate. Returns nil when the hint is not useful.
---@param term string
---@return string|nil
function Store:_trigram_candidate(term)
  if not self.fts5 or term:find("\0", 1, true) then
    return nil
  end
  local chars = utf8_chars(term)
  if #chars < 3 then
    return nil
  end
  local total_row = self._db:execute("SELECT n FROM station_search_stats WHERE term=''")[1]
  local total = total_row and total_row.n or 0
  local stride = math.max(math.floor((#chars - 2) / 16), 1)
  local best_term, best_n = chars[1] .. chars[2] .. chars[3], nil
  local seen = 0
  local i = 1
  while i <= #chars - 2 and seen < 16 do
    local candidate = chars[i] .. chars[i + 1] .. chars[i + 2]
    seen = seen + 1
    local row =
      self._db:execute("SELECT n FROM station_search_stats WHERE term=?1", { candidate })[1]
    if row and (best_n == nil or row.n < best_n) then
      best_term, best_n = candidate, row.n
    end
    i = i + stride
  end
  if total > 0 and (best_n == nil or best_n > total / 4) then
    return nil
  end
  return '"' .. best_term:gsub('"', '""') .. '"'
end

---Build WHERE clauses and the FROM source for a filter.
---@param filter table
---@return string where, table args, string source
function Store:_conditions(filter)
  local args = {}
  local clauses = {}
  local territories = require("radio.territories")
  local source = "stations s"
  if filter.history then
    clauses[#clauses + 1] = "EXISTS(SELECT 1 FROM history h WHERE h.uuid=s.uuid)"
  else
    clauses[#clauses + 1] =
      "(s.active=1 OR s.custom=1 OR EXISTS(SELECT 1 FROM favorites f WHERE f.uuid=s.uuid))"
  end
  if filter.favorites then
    clauses[#clauses + 1] = "EXISTS(SELECT 1 FROM favorites f WHERE f.uuid=s.uuid)"
  end
  if filter.custom then
    clauses[#clauses + 1] = "s.custom=1"
  end
  if filter.country and filter.country ~= "" then
    clauses[#clauses + 1] = "s.country=?"
    args[#args + 1] = filter.country:upper()
  end
  if filter.language and filter.language ~= "" then
    clauses[#clauses + 1] = "instr(s.languages,?)>0"
    args[#args + 1] = "," .. util.trim(filter.language):lower() .. ","
  end
  if filter.tag and filter.tag ~= "" then
    clauses[#clauses + 1] = "instr(s.tags,?)>0"
    args[#args + 1] = "," .. util.trim(filter.tag):lower() .. ","
  end
  if filter.query ~= "" then
    local codes = territories.matching_codes(filter.query)
    local normalized = filter.query:lower()
    if filter.country == nil and (filter.language ~= nil or filter.tag ~= nil) then
      source = "stations s NOT INDEXED"
    end
    local candidate = self:_trigram_candidate(normalized)
    if candidate then
      args[#args + 1] = candidate
      local candidate_sql = "SELECT rowid FROM station_search WHERE station_search MATCH ?"
      if #codes > 0 then
        for _, code in ipairs(codes) do
          args[#args + 1] = code
        end
        candidate_sql = candidate_sql
          .. " UNION SELECT rowid FROM stations WHERE country IN ("
          .. string.rep("?,", #codes):sub(1, -2)
          .. ")"
        clauses[#clauses + 1] = "s.rowid IN (" .. candidate_sql .. ")"
      else
        source = "station_search CROSS JOIN stations s ON s.rowid=station_search.rowid"
        clauses[#clauses + 1] = "station_search MATCH ?"
      end
    end
    args[#args + 1] = normalized
    if #codes > 0 then
      for _, code in ipairs(codes) do
        args[#args + 1] = code
      end
      clauses[#clauses + 1] = "(instr(s.search,?)>0 OR s.country IN ("
        .. string.rep("?,", #codes):sub(1, -2)
        .. "))"
    else
      clauses[#clauses + 1] = "instr(s.search,?)>0"
    end
  end
  clauses[#clauses + 1] = "s.bitrate>=?"
  args[#args + 1] = filter.min_bitrate
  return table.concat(clauses, " AND "), args, source
end

---@param filter table
---@return string
function Store:_search_order(filter)
  if filter.history then
    return "(SELECT max(id) FROM history WHERE uuid=s.uuid) DESC"
  end
  if filter.sort == "name" then
    return "s.name COLLATE NOCASE,s.uuid"
  end
  if filter.sort == "bitrate" then
    return "s.bitrate DESC,s.name,s.uuid"
  end
  if filter.sort == "votes" then
    return "json_extract(s.json,'$.votes') DESC,s.name,s.uuid"
  end
  if filter.sort == "random" then
    return "((((s.rowid * " .. self.random_seed .. ") % 2147483647) * 48271) % 2147483647),s.uuid"
  end
  return "s.popularity DESC,s.name,s.uuid"
end

---@param filter table
---@return table[] stations, integer total
function Store:search(filter)
  filter = model.filter(filter)
  local where, args, source = self:_conditions(filter)
  local order = self:_search_order(filter)
  local page_order = " ORDER BY " .. order
  local bind = vim.deepcopy(args)
  bind[#bind + 1] = filter.limit
  bind[#bind + 1] = filter.offset
  local rows = self._db:execute([[
    WITH page AS MATERIALIZED (
      SELECT s.rowid AS id FROM ]] .. source .. [[
      WHERE ]] .. where .. [[ ORDER BY ]] .. order .. [[ LIMIT ? OFFSET ?)
    SELECT s.json,s.active,EXISTS(SELECT 1 FROM favorites f WHERE f.uuid=s.uuid) AS favorite
    FROM page JOIN stations s ON s.rowid=page.id]] .. page_order, bind)
  local stations = {}
  for _, row in ipairs(rows) do
    local station = model.decode(row.json)
    if station then
      station.active = row.active == 1
      station.favorite = row.favorite == 1
      stations[#stations + 1] = station
    end
  end
  return stations, self:search_count(filter)
end

---@param filter table
---@return integer
function Store:search_count(filter)
  filter = model.filter(filter)
  local where, args, source = self:_conditions(filter)
  local row =
    self._db:execute("SELECT count(*) AS n FROM " .. source .. " WHERE " .. where, args)[1]
  return row and row.n or 0
end

---@param filter table
---@param exclude string[]
---@return table|nil
function Store:random(filter, exclude)
  filter = model.filter(filter)
  local where, args, source = self:_conditions(filter)
  local sql = "SELECT s.uuid FROM " .. source .. " WHERE " .. where
  if exclude and #exclude > 0 then
    sql = sql .. " AND s.uuid NOT IN (" .. string.rep("?,", #exclude):sub(1, -2) .. ")"
    for _, uuid in ipairs(exclude) do
      args[#args + 1] = uuid
    end
  end
  sql = sql .. " ORDER BY random() LIMIT 1"
  local row = self._db:execute(sql, args)[1]
  if not row then
    return nil
  end
  return self:station(row.uuid)
end

---Zero-based position of a station inside the current filtered order.
---@param uuid string
---@param filter table
---@return integer|nil
function Store:station_position(uuid, filter)
  filter = model.filter(filter)
  local where, args, source = self:_conditions(filter)
  local order = self:_search_order(filter)
  local bind = vim.deepcopy(args)
  bind[#bind + 1] = uuid
  local row = self._db:execute([[
    WITH ranked AS (
      SELECT s.uuid,row_number() OVER (ORDER BY ]] .. order .. [[ )-1 AS position
      FROM ]] .. source .. [[ WHERE ]] .. where .. [[)
    SELECT position FROM ranked WHERE uuid=?]], bind)[1]
  if not row then
    return nil
  end
  return row.position
end

---------------------------------------------------------------------------
-- Favorites, history
---------------------------------------------------------------------------

---@param uuid string
---@return boolean added
function Store:toggle_favorite(uuid)
  local added = false
  self._db:transaction(function()
    local rows = self._db:execute("SELECT 1 FROM stations WHERE uuid=?1", { uuid })
    if not rows[1] then
      error("station_not_found", 2)
    end
    self._db:execute("DELETE FROM favorites WHERE uuid=?1", { uuid })
    if self._db:changes() == 0 then
      self._db:execute(
        "INSERT INTO favorites(uuid,created_at) VALUES (?1,?2)",
        { uuid, os.date("!%Y-%m-%dT%H:%M:%SZ") }
      )
      added = true
    end
  end)
  return added
end

---Add or remove a favorite explicitly (radio-cli's favorite(uuid, add)).
---@param uuid string
---@param want boolean
---@return boolean changed
function Store:set_favorite(uuid, want)
  local rows = self._db:execute("SELECT 1 FROM stations WHERE uuid=?1", { uuid })
  if not rows[1] then
    error("station_not_found", 2)
  end
  local existed = self._db:execute("SELECT 1 FROM favorites WHERE uuid=?1", { uuid })[1] ~= nil
  if want and not existed then
    self._db:execute(
      "INSERT INTO favorites(uuid,created_at) VALUES (?1,?2)",
      { uuid, os.date("!%Y-%m-%dT%H:%M:%SZ") }
    )
    return true
  end
  if not want and existed then
    self._db:execute("DELETE FROM favorites WHERE uuid=?1", { uuid })
    return true
  end
  return false
end

---Record a successful play; history keeps the newest 1000 rows.
---@param uuid string
function Store:played(uuid)
  self._db:execute(
    "INSERT INTO history(uuid,played_at) VALUES (?1,?2)",
    { uuid, os.date("!%Y-%m-%dT%H:%M:%SZ") }
  )
  local last = self._db:last_insert_rowid()
  self._db:execute("DELETE FROM history WHERE id <= ?1", { math.max(0, last - 1000) })
end

---------------------------------------------------------------------------
-- Custom stations
---------------------------------------------------------------------------

---Persist a custom station; replaces backup URLs when `backups` is given.
---@param station table
---@param backups string[]|nil
---@return table station
function Store:save_custom(station, backups)
  station = model.station(station)
  station.custom = true
  local key = util.normalize_url(model.Station.primary_url(station))
  if not key then
    error("invalid_url", 2)
  end
  self._db:transaction(function()
    local rows = self._db:execute(
      [[SELECT uuid FROM stations WHERE active=1 AND normalized_url=?1
        AND uuid<>?2 LIMIT 1]],
      { key, station.stationuuid }
    )
    if rows[1] then
      error("duplicate_station:" .. rows[1].uuid, 2)
    end
    self:_write_station(station, true, true)
    if backups then
      self._db:execute("DELETE FROM streams WHERE uuid=?1", { station.stationuuid })
      for _, url in ipairs(backups) do
        self:add_backup(station.stationuuid, url)
      end
    end
  end)
  return self:station(station.stationuuid) or station
end

---@param uuid string
---@param keep_references boolean
---@return boolean referenced
function Store:remove_custom(uuid, keep_references)
  local referenced = false
  self._db:transaction(function()
    local rows = self._db:execute("SELECT json FROM stations WHERE uuid=?1 AND custom=1", { uuid })
    if not rows[1] then
      error("not_custom", 2)
    end
    local station = model.decode(rows[1].json)
    local refs = self._db:execute(
      [[
      SELECT EXISTS(SELECT 1 FROM favorites WHERE uuid=?1)
        OR EXISTS(SELECT 1 FROM history WHERE uuid=?1)
        OR EXISTS(SELECT 1 FROM recordings WHERE json_extract(json,'$.stationuuid')=?1)
        AS referenced]],
      { uuid }
    )[1]
    referenced = refs and refs.referenced == 1
    self._db:execute("DELETE FROM streams WHERE uuid=?1", { uuid })
    if referenced or keep_references then
      station.custom = false
      station.active = false
      station.url = ""
      station.url_resolved = ""
      self:_write_station(station, true, true)
    else
      local before = station_values(station)
      self._db:execute("DELETE FROM stations WHERE uuid=?1", { uuid })
      apply_facet_diff(self._db, before, {})
    end
  end)
  return referenced
end

---------------------------------------------------------------------------
-- Recordings
---------------------------------------------------------------------------

---@param record table
function Store:save_recording(record)
  record = model.recording(record)
  self._db:execute(
    [[INSERT INTO recordings (id,status,json,recovery_pending) VALUES (?1,?2,?3,?4)
      ON CONFLICT(id) DO UPDATE SET status=excluded.status,json=excluded.json,
        recovery_pending=excluded.recovery_pending]],
    {
      record.id,
      record.status,
      model.encode_recording(record),
      record.recovery_pending and 1 or 0,
    }
  )
end

---@param id string
---@return table|nil
function Store:recording(id)
  local rows = self._db:execute("SELECT json,recovery_pending FROM recordings WHERE id=?1", { id })
  if not rows[1] then
    return nil
  end
  local record = model.decode_recording(rows[1].json)
  if not record then
    return nil
  end
  record.recovery_pending = rows[1].recovery_pending == 1
  return record
end

---@param limit integer|nil
---@param offset integer|nil
---@return table[]
function Store:recordings_page(limit, offset)
  limit = math.floor(math.min(1000, math.max(1, tonumber(limit) or 100)))
  offset = math.floor(math.max(0, tonumber(offset) or 0))
  local rows = self._db:execute(
    [[SELECT json,recovery_pending FROM recordings
      ORDER BY json_extract(json,'$.started_at') DESC,id DESC LIMIT ?1 OFFSET ?2]],
    { limit, offset }
  )
  local out = {}
  for _, row in ipairs(rows) do
    local record = model.decode_recording(row.json)
    if record then
      record.recovery_pending = row.recovery_pending == 1
      out[#out + 1] = record
    end
  end
  return out
end

---@return table[]
function Store:recordings()
  return self:recordings_page(100, 0)
end

---@return integer
function Store:recordings_count()
  local row = self._db:execute("SELECT count(*) AS n FROM recordings")[1]
  return row and row.n or 0
end

---@param id string
function Store:remove_recording_index(id)
  self._db:execute("DELETE FROM recordings WHERE id=?1", { id })
end

---@return table[]
function Store:unfinished_recordings()
  local rows = self._db:execute([[
    SELECT json,recovery_pending FROM recordings
    WHERE status IN ('recording','finalizing') OR recovery_pending=1]])
  local out = {}
  for _, row in ipairs(rows) do
    local record = model.decode_recording(row.json)
    if record then
      record.recovery_pending = row.recovery_pending == 1
      out[#out + 1] = record
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Meta and counts
---------------------------------------------------------------------------

---@param key string
---@return string|nil
function Store:meta(key)
  local row = self._db:execute("SELECT value FROM meta WHERE key=?1", { key })[1]
  return row and row.value or nil
end

---@param key string
---@param value string
function Store:set_meta(key, value)
  self._db:execute(
    [[INSERT INTO meta(key,value) VALUES (?1,?2)
      ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE meta.value IS NOT excluded.value]],
    { key, tostring(value) }
  )
end

---@return integer active stations
function Store:count()
  local row = self._db:execute("SELECT count(*) AS n FROM stations WHERE active=1")[1]
  return row and row.n or 0
end

---@return integer active non-custom stations
function Store:directory_count()
  local row = self._db:execute("SELECT count(*) AS n FROM stations WHERE custom=0 AND active=1")[1]
  return row and row.n or 0
end

---@return integer
function Store:incoming_count()
  local row = self._db:execute("SELECT count(*) AS n FROM temp.incoming")[1]
  return row and row.n or 0
end

---------------------------------------------------------------------------
-- Catalog sync
---------------------------------------------------------------------------

function Store:begin_sync()
  self._db:exec("DROP TABLE IF EXISTS temp.incoming")
  self._db:exec([[CREATE TEMP TABLE incoming AS SELECT uuid,name,search,country,
    languages,tags,bitrate,popularity,custom,active,json,normalized_url FROM stations WHERE 0]])
  self._db:exec("CREATE UNIQUE INDEX temp.incoming_uuid ON incoming(uuid)")
end

---@param rows table[] stations from the directory
function Store:stage(rows)
  self._db:transaction(function()
    for _, station in ipairs(rows) do
      station = model.station(station)
      station.active = true
      station.custom = false
      self._db:execute(
        [[INSERT INTO incoming (uuid,name,search,country,languages,tags,bitrate,popularity,custom,active,json,normalized_url)
        VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)
        ON CONFLICT(uuid) DO UPDATE SET name=excluded.name,search=excluded.search,
          country=excluded.country,languages=excluded.languages,tags=excluded.tags,
          bitrate=excluded.bitrate,popularity=excluded.popularity,custom=0,active=1,
          json=excluded.json,normalized_url=excluded.normalized_url]],
        {
          station.stationuuid,
          station.name,
          station:search_text(),
          (station.countrycode or ""):upper(),
          "," .. util.normalize_list(station.language .. "," .. station.languagecodes) .. ",",
          "," .. util.normalize_list(station.tags) .. ",",
          math.floor(station.bitrate),
          math.floor(station.clickcount),
          0,
          1,
          model.encode(station),
          util.normalize_url(model.Station.primary_url(station)),
        }
      )
    end
  end)
end

---Publish the staged snapshot; returns the number of staged unique rows.
---@return integer
function Store:finish_sync()
  local count = self:incoming_count()
  if count == 0 then
    error("empty_catalog", 2)
  end
  self._db:transaction(function()
    self._db:execute("UPDATE stations SET active=0 WHERE custom=0")
    self._db:execute([[
      INSERT INTO stations (uuid,name,search,country,languages,tags,bitrate,popularity,custom,active,json,normalized_url)
      SELECT uuid,name,search,country,languages,tags,bitrate,popularity,custom,active,json,normalized_url
      FROM incoming WHERE true
      ON CONFLICT(uuid) DO UPDATE SET name=excluded.name,search=excluded.search,
        country=excluded.country,languages=excluded.languages,tags=excluded.tags,
        bitrate=excluded.bitrate,popularity=excluded.popularity,active=1,json=excluded.json,
        normalized_url=excluded.normalized_url
      WHERE stations.custom=0]])
    self:set_meta("last_sync", os.date("!%Y-%m-%dT%H:%M:%SZ"))
    self:rebuild_facets()
  end)
  self:refresh_search_stats()
  self._db:exec("PRAGMA optimize")
  return count
end

---Seed the catalog without staging (first run).
---@param rows table[]
---@param should_cancel function|nil
---@return integer
function Store:bootstrap(rows, should_cancel)
  if #rows == 0 then
    error("empty_catalog", 2)
  end
  local written = 0
  self._db:transaction(function()
    for _, station in ipairs(rows) do
      if should_cancel and should_cancel() then
        error("cancelled", 2)
      end
      self:_write_station(station, false, false)
      written = written + 1
    end
    self:rebuild_facets()
  end)
  self:refresh_search_stats()
  return written
end

return Store
