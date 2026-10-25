-- Shared helpers: text cleaning, URL handling, formatting, table utilities.
local M = {}

---Trim leading and trailing whitespace.
---@param s string?
---@return string
function M.trim(s)
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param s string?
---@param prefix string
---@return boolean
function M.startswith(s, prefix)
  return type(s) == "string" and s:sub(1, #prefix) == prefix
end

---@param s string?
---@param suffix string
---@return boolean
function M.endswith(s, suffix)
  return type(s) == "string" and (suffix == "" or s:sub(-#suffix) == suffix)
end

---@param list any[]
---@param value any
---@return boolean
function M.contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

---@param t table
---@return integer
function M.count(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

---Recursively merge `src` into a copy of `dst`; non-table values replace.
---@param dst table
---@param src table
---@return table
function M.deep_merge(dst, src)
  local out = vim.deepcopy(dst)
  for key, value in pairs(src or {}) do
    if type(value) == "table" and type(out[key]) == "table" then
      out[key] = M.deep_merge(out[key], value)
    else
      out[key] = value
    end
  end
  return out
end

---Clamp a number into [lo, hi].
function M.clamp(value, lo, hi)
  if value < lo then
    return lo
  end
  if value > hi then
    return hi
  end
  return value
end

local CLEAN_TEXT_LIMIT = 1024

local function is_control(cp)
  return cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)
end

---Drop control characters and clamp to 1024 scalar values, mirroring
---radio-cli's clean_text. Falls back to byte iteration without the utf8 lib.
---@param s string?
---@return string
function M.clean_text(s)
  if type(s) ~= "string" or s == "" then
    return ""
  end
  local out, kept = {}, 0
  if rawget(_G, "utf8") and utf8.codes then
    for _, cp in utf8.codes(s) do
      if kept >= CLEAN_TEXT_LIMIT then
        break
      end
      if not is_control(cp) then
        out[#out + 1] = utf8.char(cp)
        kept = kept + 1
      end
    end
  else
    local i, len = 1, #s
    while i <= len and kept < CLEAN_TEXT_LIMIT do
      local byte = s:byte(i)
      local cp, width = byte, 1
      if byte >= 0xf0 then
        cp, width = byte, 4
      elseif byte >= 0xe0 then
        cp, width = byte, 3
      elseif byte >= 0xc0 then
        cp, width = byte, 2
      end
      if cp < 0x80 and not is_control(cp) then
        out[#out + 1] = s:sub(i, i)
        kept = kept + 1
      elseif cp >= 0x80 then
        out[#out + 1] = s:sub(i, i + width - 1)
        kept = kept + 1
      end
      i = i + width
    end
  end
  return table.concat(out)
end

---Lowercase a value for storage/search (ASCII fast path).
---@param s string?
---@return string
function M.lower(s)
  if type(s) ~= "string" then
    return ""
  end
  return s:lower()
end

---Normalize a comma separated list: split, trim, lowercase, drop empties.
---@param s string?
---@return string
function M.normalize_list(s)
  if type(s) ~= "string" or s == "" then
    return ""
  end
  local out = {}
  for item in s:gmatch("[^,]+") do
    local value = M.trim(item):lower()
    if value ~= "" then
      out[#out + 1] = value
    end
  end
  return table.concat(out, ",")
end

---UUID (hyphenated 8-4-4-4-12) syntax check.
---@param s string?
---@return boolean
function M.is_uuid(s)
  if type(s) ~= "string" then
    return false
  end
  return s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
    ~= nil
end

---@return string
function M.uuid_v4()
  local bytes = { assert(vim.uv.random(16)):byte(1, 16) }
  bytes[7] = bit.bor(bit.band(bytes[7], 0x0f), 0x40)
  bytes[9] = bit.bor(bit.band(bytes[9], 0x3f), 0x80)
  local out = {}
  for i, byte in ipairs(bytes) do
    out[#out + 1] = string.format("%02x", byte)
    if i == 4 or i == 6 or i == 8 or i == 10 then
      out[#out + 1] = "-"
    end
  end
  return table.concat(out)
end

---radio-cli accepts only http(s) URLs with a host.
---@param url string?
---@return boolean ok
---@return string|nil reason
function M.validate_url(url)
  if type(url) ~= "string" or url == "" then
    return false, "invalid_url"
  end
  local scheme, rest = url:match("^(%a[%w+.-]*):(.*)$")
  if not scheme or (scheme:lower() ~= "http" and scheme:lower() ~= "https") then
    return false, "invalid_url"
  end
  local host = rest:match("^//([^/?#]*)")
  if not host or host == "" then
    return false, "invalid_url"
  end
  return true
end

---Strip the fragment; returns nil when the URL is invalid.
---@param url string
---@return string|nil
function M.normalize_url(url)
  local ok = M.validate_url(url)
  if not ok then
    return nil
  end
  return (url:gsub("#.*$", ""))
end

---Host and path used to name an ephemeral station (radio-cli parity).
---@param url string
---@return string
function M.host_path(url)
  local rest = url:match("^%a[%w+.-]*://(.*)$") or url
  local host, path = rest:match("^([^/?#]*)(.*)$")
  return (host or "") .. (path or "")
end

---Escape LIKE wildcards for substring matching without wildcards.
---@param s string
---@return string
function M.escape_like(s)
  return (s:gsub("([%%%_\\])", "\\%1"))
end

---Truncate to `max_chars` UTF-8 characters, appending an ellipsis when cut.
---Byte slicing would split multibyte characters.
---@param s string|nil
---@param max_chars integer
---@return string
function M.truncate(s, max_chars)
  s = type(s) == "string" and s or ""
  if max_chars <= 0 then
    return ""
  end
  local count = 0
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
    count = count + 1
    if count > max_chars then
      return s:sub(1, i - 1) .. "…"
    end
    i = i + width
  end
  return s
end

---Format milliseconds as M:SS or H:MM:SS.
---@param ms integer
---@return string
function M.fmt_duration(ms)
  ms = math.max(0, math.floor((ms or 0) / 1000))
  local seconds = ms % 60
  local minutes = math.floor(ms / 60) % 60
  local hours = math.floor(ms / 3600)
  if hours > 0 then
    return string.format("%d:%02d:%02d", hours, minutes, seconds)
  end
  return string.format("%d:%02d", minutes, seconds)
end

---@param bytes integer
---@return string
function M.fmt_bytes(bytes)
  bytes = math.max(0, tonumber(bytes) or 0)
  local units = { "B", "KiB", "MiB", "GiB", "TiB" }
  local index = 1
  local value = bytes
  while value >= 1024 and index < #units do
    value = value / 1024
    index = index + 1
  end
  if index == 1 then
    return string.format("%d %s", value, units[index])
  end
  return string.format("%.1f %s", value, units[index])
end

---Sort a copy of `list` with `comparator` and return it.
function M.sorted(list, comparator)
  local out = vim.deepcopy(list)
  table.sort(out, comparator)
  return out
end

---Normalize vim.system output (string or chunk table) to a string.
---@param value any
---@return string
function M.system_output(value)
  if type(value) == "table" then
    return table.concat(value)
  end
  return value or ""
end

---Deduplicate a list of strings, preserving first-seen order.
---@param list string[]
---@return string[]
function M.unique(list)
  local seen, out = {}, {}
  for _, value in ipairs(list) do
    if not seen[value] then
      seen[value] = true
      out[#out + 1] = value
    end
  end
  return out
end

---Use Neovim's platform-specific opener and report launch failures.
function M.open_path(path)
  local ok, job, err = pcall(vim.ui.open, path)
  if not ok or not job then
    local message = tostring(ok and err or job)
    require("radio.log").error(message)
    return nil, message
  end
  require("radio.log").info("opening " .. path)
  return job
end

return M
