local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  local Engine = require("radio.engine")
  local model = require("radio.model")
  for _, mode in ipairs({ "shared", "forced", "shared-first", "forced-first" }) do
    local dir = H.tmpdir("sessions-" .. mode)
    local writer, probe = dir .. "/writer", dir .. "/probe"
    vim.fn.writefile({ "#!/bin/sh", "exec sleep 30" }, writer)
    vim.fn.writefile({ "#!/bin/sh", [[echo '{"streams":[{"codec_name":"mp3"}]}' ]] }, probe)
    vim.uv.fs_chmod(writer, 448)
    vim.uv.fs_chmod(probe, 448)
    config.setup({
      data_dir = dir,
      auto_sync_days = 0,
      recording_min_free_mb = 1,
      single_instance = mode ~= "shared" and mode ~= "shared-first",
      ffmpeg = writer,
      ffprobe = probe,
    })
    local first = assert(Engine.new({ auto_sync = false, force = mode == "forced-first" }))
    local station = model.station({
      stationuuid = "11111111-2222-4333-8444-555555555555",
      name = "Live owner",
      url = "https://example.test/live",
      custom = true,
      active = true,
    })
    first.store:save_custom(station)
    first:standalone_record(station.stationuuid)
    H.wait_for(3000, function()
      return first.recorder ~= nil
    end, mode .. " writer starts")
    local recorder = first.recorder
    local before = first.store:recording(recorder.record.id)
    if mode == "shared-first" or mode == "forced-first" then
      config.setup({ data_dir = dir, auto_sync_days = 0 })
    end
    local second = assert(Engine.new({ auto_sync = false, force = mode == "forced" }))
    if mode == "shared-first" or mode == "forced-first" then
      H.check(second.session_lock ~= nil, mode .. " second session owns media.lock")
    end
    H.check(
      vim.deep_equal(second.store:recording(before.id), before),
      mode .. " startup leaves live recording metadata unchanged"
    )
    H.eq(recorder.ended, false, mode .. " first writer remains alive")
    local ok, err = pcall(second.remove_recording, second, before.id)
    H.check(
      not ok and tostring(err):find("recording_in_use", 1, true),
      mode .. " live recording remains protected from deletion"
    )
    H.check(
      vim.uv.fs_stat(before.path) ~= nil,
      mode .. " partial audio survives the second session"
    )
    second:shutdown()
    first:shutdown({ timeout_ms = 1000 })
    H.wait_for(2000, function()
      return first.store == nil
    end, mode .. " writer is reaped before closing storage")
    config.setup({ data_dir = dir, auto_sync_days = 0 })
    local exclusive = assert(Engine.new({ auto_sync = false }))
    H.eq(
      #exclusive.store:unfinished_recordings(),
      0,
      mode .. " later exclusive startup recovers abandoned metadata"
    )
    exclusive:shutdown()
  end

  local Recorder = require("radio.recorder")
  local recover = Recorder.recover
  Recorder.recover = function()
    error("injected recovery read failure")
  end
  local failed, err = Engine.new({ auto_sync = false })
  Recorder.recover = recover
  H.check(
    not failed and err:find("injected recovery", 1, true),
    "recovery read failure is reported"
  )
  local retry = assert(Engine.new({ auto_sync = false }))
  H.check(true, "failed recovery releases both startup leases for retry")
  retry:shutdown()
end
