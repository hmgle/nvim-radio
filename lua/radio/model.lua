-- Data model: stations, filters, recordings (radio-cli parity).
local util = require("radio.util")

local M = {}

M.SORT = { "clickcount", "name", "bitrate", "votes", "random" }

local STATION_DEFAULTS = {
  stationuuid = "",
  name = "",
  url = "",
  url_resolved = "",
  homepage = "",
  favicon = "",
  country = "",
  countrycode = "",
  state = "",
  language = "",
  languagecodes = "",
  tags = "",
  codec = "",
  bitrate = 0,
  hls = 0,
  lastcheckok = 0,
  votes = 0,
  clickcount = 0,
  custom = false,
  active = false,
  favorite = false,
}

---@param station table|nil
---@return table
function M.station(station)
  local out = vim.deepcopy(STATION_DEFAULTS)
  for key, value in pairs(station or {}) do
    if out[key] ~= nil then
      out[key] = value
    end
  end
  out.bitrate = tonumber(out.bitrate) or 0
  out.votes = tonumber(out.votes) or 0
  out.clickcount = tonumber(out.clickcount) or 0
  out.custom = out.custom and true or false
  out.active = out.active and true or false
  out.favorite = out.favorite and true or false
  return setmetatable(out, { __index = M.Station })
end

---@param json string
---@return table|nil
function M.decode(json)
  if type(json) ~= "string" or json == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, json)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return M.station(decoded)
end

---@param station table
---@return string
function M.encode(station)
  return vim.json.encode(station)
end

local Station = {}

---url_resolved wins over url when present.
---@return string
function Station.primary_url(self)
  if self.url_resolved and self.url_resolved ~= "" then
    return self.url_resolved
  end
  return self.url or ""
end

---Primary URL, the raw URL, then backups: deduplicated and validated.
---@param backups string[]|nil
---@return string[]
function Station.stream_candidates(self, backups)
  local out = {}
  local seen = {}
  local urls = { self:primary_url(), self.url }
  for _, url in ipairs(backups or {}) do
    urls[#urls + 1] = url
  end
  for _, url in ipairs(urls) do
    if type(url) == "string" and url ~= "" and not seen[url] then
      local ok = util.validate_url(url)
      if ok then
        seen[url] = true
        out[#out + 1] = url
      end
    end
  end
  return out
end

---Lowercase haystack used by the substring search predicate.
---@return string
function Station.search_text(self)
  return table
    .concat({
      self.name or "",
      self.country or "",
      self.countrycode or "",
      self.state or "",
      self.language or "",
      self.languagecodes or "",
      self.tags or "",
    }, " ")
    :lower()
end

M.Station = Station

---@param station table
---@return boolean, string|nil
function M.valid_identity(station)
  if not station.stationuuid or station.stationuuid == "" then
    return false, "invalid_station"
  end
  if not util.is_uuid(station.stationuuid) then
    return false, "invalid_uuid"
  end
  if util.trim(util.clean_text(station.name)) == "" then
    return false, "invalid_station"
  end
  return true
end

local FILTER_DEFAULTS = {
  sort = "clickcount",
  query = "",
  country = nil,
  language = nil,
  tag = nil,
  min_bitrate = 0,
  favorites = false,
  history = false,
  custom = false,
  limit = 100,
  recordings = false,
  offset = 0,
}

---@param filter table|nil
---@return table
function M.filter(filter)
  local out = vim.deepcopy(FILTER_DEFAULTS)
  for key, value in pairs(filter or {}) do
    out[key] = value
  end
  if not vim.tbl_contains(M.SORT, out.sort) then
    out.sort = "clickcount"
  end
  out.limit = math.floor(math.min(1000, math.max(1, tonumber(out.limit) or 100)))
  out.offset = math.floor(math.max(0, tonumber(out.offset) or 0))
  out.min_bitrate = math.floor(math.max(0, tonumber(out.min_bitrate) or 0))
  out.query = util.trim(out.query or "")
  return out
end

local RECORDING_DEFAULTS = {
  id = "",
  stationuuid = "",
  station_name = "",
  track = nil,
  source_url_resolved = "",
  started_at = "",
  stopped_at = nil,
  media_duration_ms = nil,
  codec = "",
  container = "",
  path = "",
  final_path = nil,
  size_bytes = 0,
  status = "",
  error = nil,
  reconnects = 0,
  recovery_pending = false,
}

---@param record table|nil
---@return table
function M.recording(record)
  local out = vim.deepcopy(RECORDING_DEFAULTS)
  for key, value in pairs(record or {}) do
    if out[key] ~= nil then
      out[key] = value
    end
  end
  out.size_bytes = tonumber(out.size_bytes) or 0
  out.reconnects = tonumber(out.reconnects) or 0
  out.recovery_pending = out.recovery_pending and true or false
  return out
end

---@param json string
---@return table|nil
function M.decode_recording(json)
  if type(json) ~= "string" or json == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, json)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return M.recording(decoded)
end

---@param record table
---@return string
function M.encode_recording(record)
  return vim.json.encode(record)
end

---@param codec string
---@return string|nil extension, string|nil muxer
function M.format_for_codec(codec)
  if codec == "mp3" then
    return "mp3", "mp3"
  end
  if codec == "aac" then
    return "aac", "adts"
  end
  if codec == "vorbis" then
    return "ogg", "ogg"
  end
  if codec == "opus" then
    return "opus", "opus"
  end
  return nil, nil
end

---Parse "30", "45s", "10m", "2h" into seconds.
---@param value string
---@return integer|nil seconds, string|nil err
function M.parse_duration(value)
  value = util.trim(value or "")
  local digits, unit = value:match("^(%d+)(%a*)$")
  if not digits then
    return nil, "invalid_duration"
  end
  local factor
  if unit == "" or unit == "s" then
    factor = 1
  elseif unit == "m" then
    factor = 60
  elseif unit == "h" then
    factor = 3600
  else
    return nil, "duration_unit"
  end
  local secs = tonumber(digits) * factor
  if secs <= 0 or secs > 365 * 24 * 3600 then
    return nil, "duration_range"
  end
  return secs
end

return M
