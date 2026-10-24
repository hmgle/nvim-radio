-- Diagnostics: external tools, paths, database, and catalog health.
local config = require("radio.config")
local sqlite = require("radio.store.sqlite")
local store_mod = require("radio.store")
local util = require("radio.util")

local Doctor = {}

---@param program string
---@param version_args string[]
---@return table
local function check_program(program, version_args)
  local path = vim.fn.exepath(program)
  if path == "" then
    return { ok = false, name = program, detail = "not found in PATH" }
  end
  local result = vim.system({ path, unpack(version_args) }, {}):wait(5000)
  local first = ""
  for line in util.system_output(result.stdout):gmatch("[^\n]+") do
    first = line
    break
  end
  if first == "" then
    for line in util.system_output(result.stderr):gmatch("[^\n]+") do
      first = line
      break
    end
  end
  return { ok = result.code == 0, name = program, detail = (first ~= "" and first or path) }
end

---@return table[]
function Doctor.run()
  local o = config.ensure()
  local checks = {}

  checks[#checks + 1] = check_program(o.mpv, { "--version" })
  checks[#checks + 1] = check_program(o.ffmpeg, { "-version" })
  checks[#checks + 1] = check_program(o.ffprobe, { "-version" })
  checks[#checks + 1] = {
    ok = sqlite.available(),
    name = "libsqlite3",
    detail = sqlite.available() and sqlite.version() or sqlite.load_error(),
  }

  -- Data and recording directories.
  local data_stat = vim.uv.fs_stat(o.data_dir)
  checks[#checks + 1] = {
    ok = data_stat ~= nil and data_stat.type == "directory",
    name = "data directory",
    detail = o.data_dir,
  }
  local recording_stat = vim.uv.fs_stat(o.recording_dir)
  checks[#checks + 1] = {
    ok = recording_stat ~= nil and recording_stat.type == "directory",
    name = "recording directory",
    detail = o.recording_dir,
  }
  local statfs = vim.uv.fs_statfs(o.recording_dir)
  if statfs then
    local free = statfs.bavail * statfs.frsize
    local required = o.recording_min_free_mb * 1024 * 1024
    checks[#checks + 1] = {
      ok = free >= required,
      name = "recording free space",
      detail = util.fmt_bytes(free) .. " free (reserve " .. util.fmt_bytes(required) .. ")",
    }
  end

  -- Database.
  local store = store_mod.open(o.db_path)
  if store then
    checks[#checks + 1] = {
      ok = true,
      name = "database",
      detail = o.db_path .. " (schema v" .. tostring(store_mod.SCHEMA_VERSION) .. ")",
    }
    local count = store:count()
    local last_sync = store:meta("last_sync")
    checks[#checks + 1] = {
      ok = count > 0,
      name = "catalog",
      detail = count
        .. " active stations"
        .. (last_sync and (", last sync " .. last_sync) or ", never synced"),
    }
    local unfinished = store:unfinished_recordings()
    checks[#checks + 1] = {
      ok = #unfinished == 0,
      name = "pending recordings",
      detail = #unfinished == 0 and "none" or (#unfinished .. " need recovery"),
    }
    store:close()
  else
    checks[#checks + 1] = { ok = false, name = "database", detail = "cannot open " .. o.db_path }
  end

  -- Runtime directory and socket path budget.
  checks[#checks + 1] = {
    ok = vim.uv.fs_stat(o.runtime_dir) ~= nil,
    name = "runtime directory",
    detail = o.runtime_dir,
  }

  return checks
end

---@return string[]
function Doctor.lines()
  local lines = {}
  for _, check in ipairs(Doctor.run()) do
    lines[#lines + 1] =
      string.format("%s %-24s %s", check.ok and "✓" or "✗", check.name, check.detail)
  end
  return lines
end

---@return boolean all_ok
function Doctor.healthy()
  for _, check in ipairs(Doctor.run()) do
    if not check.ok then
      return false
    end
  end
  return true
end

return Doctor
