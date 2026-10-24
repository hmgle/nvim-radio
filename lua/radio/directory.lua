-- Radio Browser directory: server discovery, bootstrap, full sync, refresh,
-- and click reporting. Async through the curl-based http module.
local http = require("radio.http")
local log = require("radio.log")
local model = require("radio.model")
local util = require("radio.util")

local Directory = {}
Directory.__index = Directory

local PAGE_SIZE = 1000
local MAX_OFFSET = 200000
local MAX_SERVERS = 3
local ALL_SERVERS_URL = "https://all.api.radio-browser.info/json/servers"

---@param opts table|nil {api_url, connect_timeout_secs, request_timeout_secs, stop}
---@return table
function Directory.new(opts)
  opts = opts or {}
  return setmetatable({
    api_url = opts.api_url,
    connect_timeout = opts.connect_timeout_secs or 5,
    request_timeout = opts.request_timeout_secs or 20,
    stop = opts.stop,
    servers = nil,
    discovered = false,
  }, Directory)
end

---@return boolean
function Directory:cancelled()
  return self.stop ~= nil and self.stop() == true
end

---Shuffle a copy of `list` deterministically per call site (no RNG in tests
---is not required here; the list order only affects failover preference).
---@param list string[]
---@return string[]
local function shuffle(list)
  local out = vim.deepcopy(list)
  for i = #out, 2, -1 do
    local j = math.random(i)
    out[i], out[j] = out[j], out[i]
  end
  return out
end

---Resolve the server list: configured URL, else the all.api mirror list.
---@param cb fun(err: string|nil, servers: string[]|nil)
function Directory:discover(cb)
  if self.discovered and self.servers then
    cb(nil, self.servers)
    return
  end
  if self.api_url and self.api_url ~= "" then
    local base = self.api_url:gsub("/+$", "")
    self.servers = { base }
    self.discovered = true
    cb(nil, self.servers)
    return
  end
  http.get(ALL_SERVERS_URL, {
    connect_timeout = self.connect_timeout,
    timeout = self.request_timeout,
  }, function(err, body)
    if err then
      cb("directory_request: " .. err, nil)
      return
    end
    local ok, decoded = pcall(vim.json.decode, body or "[]")
    if not ok or type(decoded) ~= "table" then
      cb("directory_request: invalid servers json", nil)
      return
    end
    local servers = {}
    for _, row in ipairs(decoded) do
      local name = type(row) == "table" and row.name or nil
      if
        type(name) == "string"
        and name:sub(-#"api.radio-browser.info") == "api.radio-browser.info"
      then
        servers[#servers + 1] = "https://" .. name
      end
    end
    if #servers == 0 then
      cb("no_directory_servers", nil)
      return
    end
    self.servers = shuffle(servers)
    self.discovered = true
    cb(nil, self.servers)
  end)
end

---Map directory rows to local stations, dropping invalid identities.
---@param rows table[]
---@return table[] stations, integer raw, integer invalid
local function map_rows(rows)
  local stations, invalid = {}, 0
  for _, row in ipairs(rows) do
    if type(row) ~= "table" then
      invalid = invalid + 1
    else
      local station = model.station(row)
      station.active = true
      station.custom = false
      local ok = model.valid_identity(station)
      if ok then
        stations[#stations + 1] = station
      else
        invalid = invalid + 1
      end
    end
  end
  return stations, #rows, invalid
end

---@param station table
---@return boolean
local function is_uuid_row(station)
  return util.is_uuid(station.stationuuid)
end

---Seed the catalog with one request (first run).
---@param store table
---@param cb fun(err: string|nil, count: integer|nil)
function Directory:bootstrap(store, cb)
  self:discover(function(discover_err, servers)
    if discover_err then
      cb(discover_err, nil)
      return
    end
    local server = servers[1]
    local url = server
      .. "/json/stations/search?limit="
      .. PAGE_SIZE
      .. "&hidebroken=true&order=clickcount&reverse=true"
    http.get(
      url,
      { connect_timeout = self.connect_timeout, timeout = self.request_timeout },
      function(err, body)
        if err then
          cb("directory_request: " .. err, nil)
          return
        end
        local ok, decoded = pcall(vim.json.decode, body or "[]")
        if not ok or type(decoded) ~= "table" then
          cb("directory_request: invalid stations json", nil)
          return
        end
        local stations = map_rows(decoded)
        if self:cancelled() then
          cb("cancelled", nil)
          return
        end
        local written, write_err = pcall(store.bootstrap, store, stations)
        if not written then
          cb(tostring(write_err), nil)
          return
        end
        cb(nil, #stations)
      end
    )
  end)
end

---Full catalog refresh with paging, staging, and shrink protection.
---@param store table
---@param opts table|nil {accept_shrink, progress}
---@param cb fun(err: string|nil, report: table|nil)
function Directory:sync(store, opts, cb)
  opts = opts or {}
  local progress = opts.progress or function() end
  self:discover(function(discover_err, servers)
    if discover_err then
      cb(discover_err, nil)
      return
    end
    local previous = store:directory_count()
    local attempts = {}
    local failures = {}
    local index = 0

    -- Snapshot the attempt history so reports never contain themselves.
    local function attempt_history()
      local copy = {}
      for i, entry in ipairs(attempts) do
        copy[i] = entry
      end
      return copy
    end

    local function attempt(server)
      index = index + 1
      if index > math.min(MAX_SERVERS, #servers) then
        cb("directory_sync: " .. table.concat(failures, "; "), nil)
        return
      end
      local report = {
        server = server,
        raw = 0,
        valid = 0,
        invalid = 0,
        duplicates = 0,
        unique = 0,
        previous = previous,
        shrink_requires_acceptance = false,
        accepted = opts.accept_shrink == true,
        error = nil,
        attempts = attempt_history(),
      }
      store:begin_sync()
      local offset = 0

      local function finish_success()
        local count = store:incoming_count()
        report.unique = count
        report.duplicates = math.max(0, report.valid - count)
        local suspicious = previous > 0 and count * 4 < previous * 3
        report.shrink_requires_acceptance = suspicious
        attempts[#attempts + 1] = report
        if suspicious and not opts.accept_shrink then
          store:set_meta("last_sync_attempt", vim.json.encode(report))
          cb("catalog_shrink: " .. server .. ": " .. previous .. " → " .. count .. " (>25%)", nil)
          return
        end
        local ok, published = pcall(store.finish_sync, store)
        if not ok then
          report.error = tostring(published)
          store:set_meta("last_sync_attempt", vim.json.encode(report))
          cb(tostring(published), nil)
          return
        end
        store:set_meta("last_sync_attempt", vim.json.encode(report))
        cb(nil, report)
      end

      local function fetch_page()
        if self:cancelled() then
          report.error = "cancelled"
          attempts[#attempts + 1] = report
          store:set_meta("last_sync_attempt", vim.json.encode(report))
          cb("cancelled", nil)
          return
        end
        if offset >= MAX_OFFSET then
          report.error = "catalog_too_large"
          attempts[#attempts + 1] = report
          failures[#failures + 1] = server .. ": catalog_too_large"
          attempt(servers[index + 1] or "")
          return
        end
        local url = server
          .. "/json/stations/search?limit="
          .. PAGE_SIZE
          .. "&offset="
          .. offset
          .. "&hidebroken=true&order=name"
        http.get(url, {
          connect_timeout = self.connect_timeout,
          timeout = self.request_timeout,
        }, function(err, body)
          if err then
            report.error = err
            attempts[#attempts + 1] = report
            failures[#failures + 1] = server .. ": " .. err
            store:set_meta("last_sync_attempt", vim.json.encode(report))
            attempt(servers[index + 1] or "")
            return
          end
          local ok, decoded = pcall(vim.json.decode, body or "[]")
          if not ok or type(decoded) ~= "table" then
            report.error = "directory_request: invalid stations json"
            attempts[#attempts + 1] = report
            failures[#failures + 1] = server .. ": " .. report.error
            store:set_meta("last_sync_attempt", vim.json.encode(report))
            attempt(servers[index + 1] or "")
            return
          end
          if #decoded > PAGE_SIZE then
            report.error = "invalid_pagination"
            attempts[#attempts + 1] = report
            failures[#failures + 1] = server .. ": invalid_pagination"
            store:set_meta("last_sync_attempt", vim.json.encode(report))
            attempt(servers[index + 1] or "")
            return
          end
          local stations, raw, invalid = map_rows(decoded)
          report.raw = report.raw + raw
          report.invalid = report.invalid + invalid
          report.valid = report.valid + #stations
          local staged, stage_err = pcall(store.stage, store, stations)
          if not staged then
            report.error = tostring(stage_err)
            attempts[#attempts + 1] = report
            store:set_meta("last_sync_attempt", vim.json.encode(report))
            cb(tostring(stage_err), nil)
            return
          end
          offset = offset + #decoded
          progress(offset)
          if self:cancelled() then
            report.error = "cancelled"
            attempts[#attempts + 1] = report
            store:set_meta("last_sync_attempt", vim.json.encode(report))
            cb("cancelled", nil)
            return
          end
          if #decoded < PAGE_SIZE then
            if store:incoming_count() == 0 then
              report.error = "empty_catalog"
              attempts[#attempts + 1] = report
              failures[#failures + 1] = server .. ": empty_catalog"
              store:set_meta("last_sync_attempt", vim.json.encode(report))
              attempt(servers[index + 1] or "")
              return
            end
            finish_success()
            return
          end
          fetch_page()
        end)
      end

      fetch_page()
    end

    attempt(servers[1] or "")
  end)
end

---Fetch one station by UUID.
---@param uuid string
---@param cb fun(err: string|nil, station: table|nil)
function Directory:refresh(uuid, cb)
  if not util.is_uuid(uuid) then
    cb("invalid_uuid", nil)
    return
  end
  self:discover(function(discover_err, servers)
    if discover_err then
      cb(discover_err, nil)
      return
    end
    local url = servers[1] .. "/json/stations/byuuid/" .. uuid
    http.get(url, {
      connect_timeout = self.connect_timeout,
      timeout = math.min(self.request_timeout, 3),
    }, function(err, body)
      if err then
        cb("directory_request: " .. err, nil)
        return
      end
      local ok, decoded = pcall(vim.json.decode, body or "[]")
      if not ok or type(decoded) ~= "table" or #decoded == 0 then
        cb("station_not_found", nil)
        return
      end
      local station = model.station(decoded[1])
      station.active = true
      station.custom = false
      if not model.valid_identity(station) then
        cb("station_not_found", nil)
        return
      end
      cb(nil, station)
    end)
  end)
end

---Report a listener click (non-fatal, fire and forget).
---@param uuid string
function Directory:click(uuid)
  if not util.is_uuid(uuid) then
    return
  end
  self:discover(function(_, servers)
    if not servers or not servers[1] then
      return
    end
    http.post(
      servers[1] .. "/json/url/" .. uuid,
      { timeout = 3, connect_timeout = 3 },
      function() end
    )
  end)
end

---True when the last successful sync is older than `days`.
---@param store table
---@param days integer
---@return boolean
function Directory.sync_due(store, days)
  if not days or days <= 0 then
    return false
  end
  local last = store:meta("last_sync")
  if not last then
    return true
  end
  local year, month, day, hour, min, sec = last:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not year then
    return true
  end
  local stamp = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour) or 0,
    min = tonumber(min) or 0,
    sec = tonumber(sec) or 0,
  })
  local age_days = (os.time() - stamp) / 86400
  return age_days >= days
end

log.debug("directory module loaded")
return Directory
