local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  local Player = require("radio.player")
  local dir = H.tmpdir("probes")
  config.setup({ data_dir = dir, auto_sync_days = 0 })
  local sleeper = dir .. "/slow-mpv"
  vim.fn.writefile({ "#!/bin/sh", "exec sleep 30" }, sleeper)
  vim.uv.fs_chmod(sleeper, 448)
  local started = vim.uv.hrtime()
  local probe_error
  local task = Player.start(
    { mpv = sleeper, normalize_loudness = true, runtime_dir = config.options.runtime_dir },
    function() end,
    function(err)
      probe_error = err
    end
  )
  H.check(
    (vim.uv.hrtime() - started) / 1e6 < 500,
    "uncached normalization probe returns immediately"
  )
  local closed = false
  task:close(function()
    closed = true
  end)
  H.wait_for(3000, function()
    return closed
  end, "normalization cancellation reaps the probe")
  H.eq(probe_error, "cancelled", "cancelled normalization cannot launch playback")
  H.eq(task.player, nil, "cancelled normalization creates no player")

  -- Fake mpv: the capability probe runs {mpv, "--no-config", "--af=help"}, so
  -- $2 is the probe marker and every other invocation execs the real binary.
  -- Keep the argument order in sync with Player.start.
  local fallback = dir .. "/timeout-mpv"
  vim.fn.writefile({
    "#!/bin/sh",
    'if [ "$2" = "--af=help" ]; then',
    "  exec sleep 30",
    "fi",
    "exec " .. vim.fn.shellescape(vim.fn.exepath("mpv")) .. ' "$@"',
  }, fallback)
  vim.uv.fs_chmod(fallback, 448)
  local fallback_error, fallback_started
  local timeout_task = Player.start({
    mpv = fallback,
    normalize_loudness = true,
    runtime_dir = config.options.runtime_dir,
    audio_device = "null",
    url = H.make_mp3(dir, 2),
  }, function() end, function(err)
    if not fallback_started then
      fallback_error = err
      fallback_started = true
    end
  end)
  -- The probe itself burns the hard 3 s timeout, so the budget must also cover
  -- spawning and connecting the fallback player.
  H.wait_for(8000, function()
    return fallback_started and timeout_task.player ~= nil
  end, "normalization timeout falls back to playback")
  local fallback_reaped = false
  timeout_task:close(function()
    fallback_reaped = true
  end)
  H.wait_for(3000, function()
    return fallback_reaped
  end, "fallback player is closed after the test")
  H.eq(fallback_error, nil, "normalization timeout is not a hard failure")

  local missing
  local missing_task = Player.start(
    { mpv = dir .. "/missing", normalize_loudness = true, runtime_dir = config.options.runtime_dir },
    function() end,
    function(err)
      missing = err
    end
  )
  H.wait_for(1000, function()
    return missing ~= nil
  end, "missing normalization binary reports asynchronously")
  H.check(
    missing:find("missing_dependency", 1, true),
    "missing normalization binary retains dependency error"
  )
  missing_task:close()
  local ok, devices, device_err = pcall(Player.audio_devices, dir .. "/missing")
  H.check(
    ok and #devices == 0 and device_err,
    "missing device binary returns an error without throwing"
  )
  local devices_done = false
  Player.audio_devices("mpv", function(list, err)
    H.check(not err and #list > 0, "asynchronous device listing uses real mpv")
    devices_done = true
  end)
  H.wait_for(3000, function()
    return devices_done
  end, "asynchronous device listing completes")

  -- Ownership transfers from the capability probe to the connecting player.
  local wrapper = dir .. "/wrapped-mpv"
  vim.fn.writefile({
    "#!/bin/sh",
    'if [ "$2" = "--af=help" ]; then',
    "  echo ' dynaudnorm'",
    "  exit 0",
    "fi",
    "exec " .. vim.fn.shellescape(vim.fn.exepath("mpv")) .. ' "$@"',
  }, wrapper)
  vim.uv.fs_chmod(wrapper, 448)
  local connecting = Player.start({
    mpv = wrapper,
    normalize_loudness = true,
    runtime_dir = config.options.runtime_dir,
    audio_device = "null",
    url = H.make_mp3(dir, 2),
  }, function() end, function() end)
  H.wait_for(3000, function()
    return connecting.player ~= nil
  end, "probe starts a connecting player")
  local reaped = false
  connecting:close(function()
    reaped = true
  end)
  H.wait_for(3000, function()
    return reaped
  end, "closing probe task also reaps its player")

  local diagnostic = dir .. "/slow-version"
  vim.fn.writefile({ "#!/bin/sh", "exec sleep 0.2" }, diagnostic)
  vim.uv.fs_chmod(diagnostic, 448)
  config.setup({
    data_dir = dir,
    auto_sync_days = 0,
    mpv = diagnostic,
    ffmpeg = diagnostic,
    ffprobe = diagnostic,
  })
  local diagnostic_done = false
  started = vim.uv.hrtime()
  require("radio.doctor").run(function(checks)
    H.check(#checks >= 9, "asynchronous diagnostics includes path and database checks")
    diagnostic_done = true
  end)
  H.check((vim.uv.hrtime() - started) / 1e6 < 300, "diagnostics does not wait for subprocesses")
  H.eq(diagnostic_done, false, "diagnostic callback runs after subprocess completion")
  H.wait_for(3000, function()
    return diagnostic_done
  end, "asynchronous diagnostics completes")
  config.setup({ data_dir = dir, auto_sync_days = 0 })
end
