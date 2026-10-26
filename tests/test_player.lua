-- Player tests against real mpv playing a local HTTP stream.
local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  local player_mod = require("radio.player")

  -- uv.walk can crash Neovim 0.10 on editor-owned handles. Track only the
  -- process handles created by this test, including vim.system children.
  local spawn, processes = vim.uv.spawn, {}
  vim.uv.spawn = function(...)
    local handle, pid = spawn(...)
    if handle then
      processes[#processes + 1] = handle
    end
    return handle, pid
  end

  local dir = H.tmpdir("player")
  config.setup({ data_dir = dir, auto_sync_days = 0 })
  local mp3 = H.make_mp3(dir, 4)

  local url, stop = H.start_server({
    ["/fixture.mp3"] = function()
      local fd = assert(vim.uv.fs_open(mp3, "r", 438))
      local stat = assert(vim.uv.fs_fstat(fd))
      local data = assert(vim.uv.fs_read(fd, stat.size, 0))
      vim.uv.fs_close(fd)
      return data, 200
    end,
  })

  local events = {}
  local started = false
  local start_error = nil
  local player = player_mod.start({
    mpv = config.options.mpv,
    volume = 42,
    playback_timeout_secs = 12,
    runtime_dir = config.options.runtime_dir,
    url = url .. "/fixture.mp3",
  }, function(event)
    events[#events + 1] = event
  end, function(err, handle)
    start_error = err
    started = err == nil
    player = handle
  end)

  H.eq(start_error, nil, "mpv starts")
  H.check(
    player.socket:match("/mpv%-" .. string.rep("%x", 12) .. "%.sock$") ~= nil,
    "socket suffix has a fixed length"
  )
  H.wait_for(8000, function()
    for _, event in ipairs(events) do
      if event.type == "playing" then
        return true
      end
    end
    return false
  end, "mpv reports playback-restart")

  local saw_volume = false
  for _, event in ipairs(events) do
    if event.type == "volume" and event.volume == 42 then
      saw_volume = true
    end
  end
  H.check(saw_volume, "initial volume observed")

  player:toggle_pause()
  H.wait_for(2000, function()
    for _, event in ipairs(events) do
      if event.type == "paused" and event.paused then
        return true
      end
    end
    return false
  end, "pause event")

  player:toggle_pause()
  player:volume(8)
  H.wait_for(2000, function()
    for _, event in ipairs(events) do
      if event.type == "volume" and event.volume == 50 then
        return true
      end
    end
    return false
  end, "volume change event")

  player:toggle_mute()
  H.wait_for(2000, function()
    for _, event in ipairs(events) do
      if event.type == "muted" and event.muted then
        return true
      end
    end
    return false
  end, "mute event")

  local closed = false
  player:close(function()
    closed = true
  end)
  H.wait_for(3000, function()
    return closed
  end, "player closes")
  H.wait_for(2000, function()
    return vim.uv.fs_stat(player.socket) == nil
  end, "socket removed")
  H.eq(player.handle:is_closing(), true, "mpv process handle closes after exit")
  local function process_count()
    local count = 0
    for _, handle in ipairs(processes) do
      if not handle:is_closing() then
        count = count + 1
      end
    end
    return count
  end
  local baseline = process_count()
  for _ = 1, 3 do
    local ready, done = false, false
    local p = assert(
      player_mod.start(
        { mpv = "mpv", runtime_dir = config.options.runtime_dir, url = url .. "/fixture.mp3" },
        function() end,
        function(err)
          ready = err == nil
        end
      )
    )
    H.wait_for(5000, function()
      return ready
    end, "repeated player connects")
    p:close(function()
      done = true
    end)
    H.wait_for(3000, function()
      return done
    end, "repeated player is reaped")
  end
  H.eq(process_count(), baseline, "repeated playback does not leak process handles")
  local cancel_callbacks = 0
  local connecting = assert(
    player_mod.start(
      { mpv = "mpv", runtime_dir = config.options.runtime_dir, url = url .. "/fixture.mp3" },
      function() end,
      function(err)
        cancel_callbacks = cancel_callbacks + 1
        H.eq(err, "cancelled", "startup cancellation completes with an error")
      end
    )
  )
  local closes = 0
  connecting:close(function()
    closes = closes + 1
  end)
  connecting:close(function()
    closes = closes + 1
  end)
  H.wait_for(3000, function()
    return closes == 2
  end, "all close waiters run after exit")
  H.eq(cancel_callbacks, 1, "startup callback completes exactly once")
  H.eq(process_count(), baseline, "cancelled startup releases its process handle")
  -- Caller PRNG seeds must not make persistent recording IDs repeat across
  -- sessions, or make socket suffixes unexpectedly exceed path limits.
  local util = require("radio.util")
  math.randomseed(1234)
  local id_a = util.uuid_v4()
  math.randomseed(1234)
  local id_b = util.uuid_v4()
  H.check(util.is_uuid(id_a) and util.is_uuid(id_b), "OS-random IDs retain UUID syntax")
  H.check(id_a ~= id_b, "re-seeding Lua cannot repeat persistent IDs")
  -- Missing binary surfaces a dependency error.
  local missing_error = "unset"
  player_mod.start({
    mpv = "/nonexistent/mpv",
    runtime_dir = config.options.runtime_dir,
    url = url .. "/fixture.mp3",
  }, function() end, function(err)
    missing_error = err
  end)
  H.wait_for(5000, function()
    return missing_error ~= "unset"
  end, "missing mpv fails to start")
  H.check(missing_error and missing_error:find("missing_dependency"), "missing mpv error code")

  -- Device listing and normalization probe use the real binary.
  local devices = player_mod.audio_devices(config.options.mpv)
  H.check(#devices > 0, "mpv audio devices listed")
  H.check(
    type(player_mod.supports_normalization(config.options.mpv)) == "boolean",
    "normalization probe"
  )

  stop()
  vim.uv.spawn = spawn
end
