-- Public API. Everything is lazy: nothing starts until first use.
local M = {}

M.version = require("radio.version").version

---@param opts table|nil see lua/radio/config.lua for defaults
function M.setup(opts)
  require("radio.config").setup(opts)
  M._apply_keys()
  return M
end

---Global keymaps are opt-in; see the `keys` option.
function M._apply_keys()
  local keys = require("radio.config").options.keys or {}
  local actions = {
    toggle = function()
      M.toggle()
    end,
    pause = function()
      M.pause()
    end,
    mute = function()
      M.mute()
    end,
    volume_up = function()
      M.volume(5)
    end,
    volume_down = function()
      M.volume(-5)
    end,
    record = function()
      local engine = M.engine()
      engine:toggle_recording()
    end,
    status = function()
      M.status()
    end,
    random = function()
      M.random()
    end,
    stop = function()
      M.stop()
    end,
  }
  for name, lhs in pairs(keys) do
    if lhs and actions[name] then
      vim.keymap.set("n", lhs, actions[name], { desc = "nvim-radio: " .. name })
    end
  end
end

---@param opts table|nil
---@return table|nil engine, string|nil err
function M.engine(opts)
  return require("radio.ui").engine(opts)
end

---Open or close the station browser.
function M.toggle()
  require("radio.ui").toggle()
end

---@param target string station UUID or http(s) URL
function M.play(target)
  local engine = assert(M.engine())
  engine:play(target)
end

function M.stop()
  local engine = M.engine()
  if engine then
    engine:stop_playback()
  end
end

function M.pause()
  local engine = assert(M.engine())
  engine:pause()
end

function M.mute()
  local engine = assert(M.engine())
  engine:mute()
end

---@param delta integer
function M.volume(delta)
  local engine = assert(M.engine())
  engine:volume(delta)
end

---@param duration string|nil e.g. "30m"
---@param dir string|nil
function M.record(duration, dir)
  local engine = assert(M.engine())
  local seconds
  if duration and duration ~= "" then
    seconds = assert(require("radio.model").parse_duration(duration))
  end
  engine:record_current(seconds, dir)
end

function M.record_stop()
  local engine = assert(M.engine())
  engine:stop_recording(nil)
end

---@param filter table|nil
function M.random(filter)
  local engine = assert(M.engine())
  engine:random(filter)
end

---@param opts table|nil {accept_shrink}
---@param cb function|nil
function M.sync(opts, cb)
  local engine = assert(M.engine())
  engine:sync(opts, cb)
end

function M.status()
  require("radio.ui").hud()
end

---@return string
function M.statusline()
  return require("radio.ui").statusline()
end

---@param filter table|nil
---@return table[] stations, integer total
function M.stations(filter)
  local engine = assert(M.engine())
  return engine.store:search(require("radio.model").filter(filter))
end

---@param uuid string
---@return boolean added
function M.favorite_toggle(uuid)
  local engine = assert(M.engine())
  return engine.store:toggle_favorite(uuid)
end

---@param filter table|nil
---@return table[] stations
function M.favorites(filter)
  local model = require("radio.model")
  return M.stations(model.filter(vim.tbl_extend("force", filter or {}, { favorites = true })))
end

---@return table[] stations
function M.history()
  local model = require("radio.model")
  return M.stations(model.filter({ history = true }))
end

---@return table[] recordings
function M.recordings()
  local engine = assert(M.engine())
  return engine.store:recordings()
end

---@param name string
---@param url string
---@param backups string[]|nil
---@return table station
function M.station_add(name, url, backups)
  local engine = assert(M.engine())
  local model = require("radio.model")
  local util = require("radio.util")
  local station = model.station({
    stationuuid = util.uuid_v4(),
    name = util.trim(name),
    url = url,
    url_resolved = url,
    custom = true,
    active = true,
    lastcheckok = 1,
  })
  return engine.store:save_custom(station, backups)
end

---@param uuid string
---@param opts table|nil {keep_references}
---@return boolean referenced
function M.station_remove(uuid, opts)
  local engine = assert(M.engine())
  return engine.store:remove_custom(uuid, opts and opts.keep_references or false)
end

---@param id string
function M.recording_play(id)
  local engine = assert(M.engine())
  engine:play_recording(id)
end

---@param id string
---@param index_only boolean|nil
function M.recording_remove(id, index_only)
  local engine = assert(M.engine())
  local record = engine.store:recording(id)
  if not record then
    error("recording_not_found", 2)
  end
  if record.status == "recording" or record.status == "finalizing" or record.recovery_pending then
    error("recording_in_use", 2)
  end
  if not index_only then
    vim.uv.fs_unlink(record.path)
    vim.uv.fs_unlink(record.path .. ".json")
  end
  engine.store:remove_recording_index(id)
end

function M.open_recordings()
  local dir = require("radio.config").ensure().recording_dir
  vim.system({ "xdg-open", dir }, {}, function() end)
  vim.notify("[radio] opening " .. dir)
end

---@return table[] devices
function M.devices()
  local o = require("radio.config").ensure()
  return require("radio.player").audio_devices(o.mpv)
end

---@return string[] lines
function M.doctor()
  return require("radio.doctor").lines()
end

---@param uuid string
---@return table|nil station
function M.info(uuid)
  local engine = assert(M.engine())
  return engine.store:station(uuid)
end

return M
