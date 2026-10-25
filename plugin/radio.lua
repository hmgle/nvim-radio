-- Report command failures through notifications instead of Ex tracebacks.
local function command(name, callback, opts)
  vim.api.nvim_create_user_command(name, function(info)
    local ok, err = pcall(callback, info)
    if not ok then
      require("radio.log").error(tostring(err):gsub("^.-:%d+: ", ""))
    end
  end, opts)
end

-- User commands. The plugin module loads lazily on first command use.
local completed = function(sub)
  return function(arg_lead, cmd_line)
    local args = vim.split(vim.trim(cmd_line), "%s+")
    if #args <= 2 then
      return vim
        .iter(sub)
        :filter(function(item)
          return item:find(arg_lead, 1, true) == 1
        end)
        :totable()
    end
    return {}
  end
end

command("Radio", function()
  require("radio").toggle()
end, { desc = "Toggle the nvim-radio browser" })

command("RadioPlay", function(info)
  require("radio").play(vim.trim(info.args))
end, { nargs = 1, desc = "Play a station UUID or http(s) URL" })

command("RadioStop", function()
  require("radio").stop()
end, { desc = "Stop playback" })

command("RadioPause", function()
  require("radio").pause()
end, { desc = "Pause or resume playback" })

command("RadioMute", function()
  require("radio").mute()
end, { desc = "Mute or unmute" })

command("RadioVolume", function(info)
  local arg = vim.trim(info.args)
  local delta = tonumber(arg)
  if not delta then
    if arg:sub(1, 1) == "+" or arg:sub(1, 1) == "-" then
      delta = tonumber(arg)
    end
  end
  if not delta then
    vim.notify("[radio] usage: RadioVolume <+n|-n|n>", vim.log.levels.ERROR)
    return
  end
  local radio = require("radio")
  local engine, err = radio.engine()
  if not engine then
    require("radio.log").error(err)
    return
  end
  if arg:sub(1, 1) == "+" or arg:sub(1, 1) == "-" then
    radio.volume(delta)
  else
    radio.volume(delta - engine.status.volume)
  end
end, { nargs = 1, desc = "Set or adjust volume" })

command("RadioRecord", function(info)
  local args = vim.split(vim.trim(info.args), "%s+")
  local duration, dir = nil, nil
  local index = 1
  while index <= #args do
    local arg = args[index]
    if arg == "--output-dir" then
      dir = args[index + 1]
      if not dir or dir == "" or dir:sub(1, 2) == "--" then
        error("usage: RadioRecord [duration] --output-dir <directory>", 0)
      end
      index = index + 2
    elseif arg ~= "" then
      duration = arg
      index = index + 1
    else
      index = index + 1
    end
  end
  require("radio").record(duration, dir)
end, { nargs = "*", desc = "Record the playing station (e.g. 30m --output-dir ~/music)" })

command("RadioRecordStop", function()
  require("radio").record_stop()
end, { desc = "Stop and publish the recording" })

command("RadioRandom", function(info)
  local query = vim.trim(info.args)
  require("radio").random(query ~= "" and { query = query } or nil)
end, { nargs = "*", desc = "Play a random station (optional query)" })

command("RadioSync", function()
  require("radio").sync()
end, { desc = "Sync the Radio Browser catalog" })

command("RadioStatus", function()
  require("radio").status()
end, { desc = "Show the playback/recording HUD" })

command("RadioDoctor", function()
  vim.notify("[radio] doctor\n" .. table.concat(require("radio").doctor(), "\n"))
end, { desc = "Run diagnostics" })

command("RadioDevices", function()
  local devices = require("radio").devices()
  local lines = {}
  for _, device in ipairs(devices) do
    lines[#lines + 1] = device.name .. "  " .. device.description
  end
  vim.notify("[radio] audio devices\n" .. table.concat(lines, "\n"))
end, { desc = "List mpv audio output devices" })

command("RadioFavorites", function(info)
  local args = vim.split(vim.trim(info.args), "%s+")
  local radio = require("radio")
  local action = args[1] or "list"
  if (action == "add" or action == "remove") and args[2] then
    radio.favorite_set(args[2], action == "add")
    vim.notify("[radio] " .. (action == "add" and "added " or "removed ") .. args[2])
    return
  end
  if action == "add" or action == "remove" then
    vim.notify("[radio] usage: RadioFavorites add|remove <UUID>", vim.log.levels.ERROR)
    return
  end
  local stations = radio.favorites()
  local lines = {}
  for _, station in ipairs(stations) do
    lines[#lines + 1] = station.stationuuid .. "  " .. station.name
  end
  vim.notify("[radio] favorites (" .. #stations .. ")\n" .. table.concat(lines, "\n"))
end, { nargs = "*", desc = "List favorites or add/remove one" })

command("RadioHistory", function()
  local stations = require("radio").history()
  local lines = {}
  for _, station in ipairs(stations) do
    lines[#lines + 1] = station.name
  end
  vim.notify("[radio] history (" .. #stations .. ")\n" .. table.concat(lines, "\n"))
end, { desc = "Show recent playback history" })

command("RadioRecordings", function(info)
  local args = vim.split(vim.trim(info.args), "%s+")
  local radio = require("radio")
  if args[1] == "play" and args[2] then
    radio.recording_play(args[2])
    return
  end
  if args[1] == "remove" and args[2] then
    radio.recording_remove(args[2], vim.tbl_contains(args, "--index-only"))
    vim.notify("[radio] recording removed: " .. args[2])
    return
  end
  local recordings = radio.recordings()
  local lines = {}
  for _, record in ipairs(recordings) do
    lines[#lines + 1] = string.format(
      "%s  %-11s %8s  %s",
      record.id:sub(1, 8),
      record.status,
      require("radio.util").fmt_bytes(record.size_bytes),
      record.station_name
    )
  end
  vim.notify("[radio] recordings (" .. #recordings .. ")\n" .. table.concat(lines, "\n"))
end, {
  nargs = "*",
  complete = completed({ "list", "play", "remove" }),
  desc = "List recordings or play/remove one",
})

command("RadioStationAdd", function(info)
  local args = vim.split(vim.trim(info.args), "%s+")
  if #args < 2 then
    vim.notify("[radio] usage: RadioStationAdd <name> <url>", vim.log.levels.ERROR)
    return
  end
  local name = table.concat(args, " ", 1, #args - 1)
  local station = require("radio").station_add(name, args[#args])
  vim.notify("[radio] station added: " .. station.name .. " (" .. station.stationuuid .. ")")
end, { nargs = "+", desc = "Add a custom station" })

command("RadioStationRemove", function(info)
  require("radio").station_remove(vim.trim(info.args))
end, { nargs = 1, desc = "Remove a custom station" })

command("RadioOpenRecordings", function()
  require("radio").open_recordings()
end, { desc = "Open the recordings directory" })
