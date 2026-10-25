-- Diagnostics: external tools, paths, database, and catalog health.
local config = require("radio.config")
local sqlite = require("radio.store.sqlite")
local store_mod = require("radio.store")
local util = require("radio.util")

local Doctor = {}

---@param program string
---@param version_args string[]
---@return table
local function check_program(program, version_args, cb)
  local path = vim.fn.exepath(program)
  if path == "" then
    local result = { ok = false, name = program, detail = "not found in PATH" }
    if cb then
      vim.schedule(function()
        cb(result)
      end)
    else
      return result
    end
    return
  end
  local function report(result)
    local output = util.system_output(result.stdout)
    if output == "" then
      output = util.system_output(result.stderr)
    end
    local first = output:match("[^\n]+") or path
    return { ok = result.code == 0, name = program, detail = first }
  end
  local args = { path, unpack(version_args) }
  if cb then
    local ok, err = pcall(
      vim.system,
      args,
      { timeout = 5000 },
      vim.schedule_wrap(function(result)
        cb(report(result))
      end)
    )
    if not ok then
      vim.schedule(function()
        cb({ ok = false, name = program, detail = tostring(err) })
      end)
    end
    return
  end
  local ok, result = pcall(function()
    return vim.system(args, {}):wait(5000)
  end)
  return report(ok and result or { code = -1, stderr = tostring(result) })
end

---@return table[]
local function collect(checks)
  local o = config.ensure()
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

---With a callback, external checks run concurrently without blocking Neovim.
function Doctor.run(cb)
  local o = config.ensure()
  local programs =
    { { o.mpv, { "--version" } }, { o.ffmpeg, { "-version" } }, { o.ffprobe, { "-version" } } }
  local checks = {}
  if not cb then
    for i, program in ipairs(programs) do
      checks[i] = check_program(program[1], program[2])
    end
    return collect(checks)
  end
  local remaining = #programs
  for i, program in ipairs(programs) do
    check_program(program[1], program[2], function(check)
      checks[i] = check
      remaining = remaining - 1
      if remaining == 0 then
        cb(collect(checks))
      end
    end)
  end
end

local function format_lines(checks)
  local lines = {}
  for _, check in ipairs(checks) do
    lines[#lines + 1] =
      string.format("%s %-24s %s", check.ok and "✓" or "✗", check.name, check.detail)
  end
  return lines
end

function Doctor.lines(cb)
  if cb then
    return Doctor.run(function(checks)
      cb(format_lines(checks))
    end)
  end
  return format_lines(Doctor.run())
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
