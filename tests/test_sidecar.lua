local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  local Recorder = require("radio.recorder")
  local model = require("radio.model")
  local dir = H.tmpdir("sidecar")
  config.setup({ data_dir = dir, recording_min_free_mb = 1, auto_sync_days = 0 })
  local store = assert(require("radio.store").open(config.options.db_path))
  local Engine = require("radio.engine")
  local uv = vim.uv
  local original =
    { open = uv.fs_open, write = uv.fs_write, close = uv.fs_close, rename = uv.fs_rename }
  local notify, notices = vim.notify, {}
  vim.notify = function(message)
    notices[#notices + 1] = message
  end
  for _, scenario in ipairs({
    "open",
    "write",
    "short_write",
    "zero_write",
    "close",
    "rename",
    "failed",
  }) do
    local path = dir .. "/" .. scenario .. ".mp3"
    local record = model.recording({
      id = scenario,
      path = path,
      final_path = path,
      status = scenario == "failed" and "failed" or "complete",
      error = scenario == "failed" and "original FFmpeg error" or nil,
    })
    vim.fn.writefile({ "audio" }, path)
    local previous = '{"previous":"valid metadata"}'
    vim.fn.writefile({ previous }, path .. ".json")
    store:save_recording(record)
    local fd, writes, close_failed = nil, 0, false
    uv.fs_open = function(file, ...)
      if file == path .. ".json.tmp" and scenario == "open" then
        return nil, "ENOSPC: no space left on device", "ENOSPC"
      end
      local handle, err, code = original.open(file, ...)
      if file == path .. ".json.tmp" then
        fd = handle
      end
      return handle, err, code
    end
    uv.fs_write = function(handle, data, offset)
      if handle == fd then
        writes = writes + 1
        if
          scenario == "write"
          or scenario == "failed"
          or (scenario == "short_write" and writes > 1)
        then
          return nil, "ENOSPC: no space left on device", "ENOSPC"
        elseif scenario == "short_write" then
          return original.write(handle, data:sub(1, 7), offset)
        elseif scenario == "zero_write" then
          return 0
        end
      end
      return original.write(handle, data, offset)
    end
    uv.fs_close = function(handle)
      if handle == fd and scenario == "close" and not close_failed then
        close_failed = true
        original.close(handle)
        return nil, "EIO: close failed", "EIO"
      end
      return original.close(handle)
    end
    uv.fs_rename = function(from, to)
      if from == path .. ".json.tmp" and scenario == "rename" then
        return nil, "EACCES: rename failed", "EACCES"
      end
      return original.rename(from, to)
    end
    local recorder = setmetatable({ store = store, record = record }, Recorder)
    H.eq(recorder:_persist_recording(), false, scenario .. " reports unsuccessful persistence")
    H.eq(
      table.concat(vim.fn.readfile(path .. ".json"), "\n"),
      previous,
      scenario .. " preserves the old JSON"
    )
    H.eq(uv.fs_stat(path .. ".json.tmp"), nil, scenario .. " removes failed temporary JSON")
    H.eq(store:recording(record.id).recovery_pending, true, scenario .. " persists a retry marker")
    local callbacks, finish_err = 0, nil
    recorder._finish_callbacks = {
      function(_, err)
        callbacks, finish_err = callbacks + 1, err
      end,
    }
    recorder:_settle(nil)
    H.eq(callbacks, 1, scenario .. " settles the completion callback")
    H.check(
      finish_err and finish_err:find("recording_sidecar", 1, true),
      scenario .. " callback reports the file error"
    )
    close_failed = false
    H.eq(#Recorder.recover(store, config.options), 1, scenario .. " failed recovery warns")
    H.eq(
      store:recording(record.id).recovery_pending,
      true,
      scenario .. " failed recovery stays retryable"
    )
    H.eq(
      table.concat(vim.fn.readfile(path .. ".json"), "\n"),
      previous,
      scenario .. " recovery preserves old JSON"
    )
    for name, fn in pairs(original) do
      uv["fs_" .. name] = fn
    end
    H.eq(
      #Recorder.recover(store, config.options),
      0,
      scenario .. " recovery succeeds after storage returns"
    )
    local recovered = store:recording(record.id)
    H.eq(recovered.recovery_pending, false, scenario .. " clears the retry marker after success")
    H.eq(recovered.status, record.status, scenario .. " preserves the audio outcome")
    H.eq(recovered.error, record.error, scenario .. " preserves the audio error")
    local sidecar = model.decode_recording(table.concat(vim.fn.readfile(path .. ".json"), "\n"))
    H.check(
      sidecar and sidecar.id == record.id and not sidecar.recovery_pending,
      scenario .. " publishes complete retry metadata"
    )
  end

  -- Positive short writes are retried until all bytes have been written.
  local writes = 0
  uv.fs_write = function(fd, data, offset)
    writes = writes + 1
    return original.write(fd, data:sub(1, 11), offset)
  end
  local record =
    model.recording({ id = "partial-success", path = dir .. "/partial.mp3", status = "complete" })
  local recorder = setmetatable({ store = store, record = record }, Recorder)
  H.eq(recorder:_persist_recording(), true, "positive short writes can complete successfully")
  uv.fs_write = original.write
  H.check(writes > 1, "short writes are completed in multiple calls")
  local loaded = model.decode_recording(table.concat(vim.fn.readfile(record.path .. ".json"), "\n"))
  H.eq(loaded.id, record.id, "short-write success produces valid full JSON")

  -- Publication can succeed on the audio file while the final sidecar fails.
  local audio = H.make_mp3(dir, 1)
  local writer = dir .. "/writer"
  vim.fn.writefile({ "#!/bin/sh", "cat " .. vim.fn.shellescape(audio) }, writer)
  uv.fs_chmod(writer, 448)
  local opts = vim.tbl_extend("force", config.options, { ffmpeg = writer })
  local function start()
    return assert(
      Recorder.start(
        opts,
        store,
        model.station({ name = "Sidecar" }),
        "https://example.test/live",
        dir .. "/recordings",
        nil,
        { streams = { { codec_name = "mp3" } } }
      )
    )
  end
  local publishing = start()
  local previous = '{"previous":"final metadata"}'
  vim.fn.writefile({ previous }, publishing.final_path .. ".json")
  uv.fs_rename = function(from, to)
    if to == publishing.final_path .. ".json" then
      return nil, "ENOSPC: sidecar disk is full", "ENOSPC"
    end
    return original.rename(from, to)
  end
  H.wait_for(2000, function()
    return publishing.ended
  end, "sidecar fixture writer exits")
  local done, publication_err = 0, nil
  publishing:finish(nil, function(_, err)
    done, publication_err = done + 1, err
  end)
  H.wait_for(4000, function()
    return done == 1
  end, "sidecar publication failure still settles")
  H.check(
    publication_err and publication_err:find("recording_sidecar", 1, true),
    "final sidecar error reaches caller"
  )
  H.eq(
    store:recording(publishing.record.id).recovery_pending,
    true,
    "published audio with failed metadata stays retryable"
  )
  H.eq(
    table.concat(vim.fn.readfile(publishing.final_path .. ".json"), "\n"),
    previous,
    "publication preserves existing final metadata"
  )
  H.check(
    uv.fs_stat(publishing.partial .. ".json") ~= nil,
    "publication failure retains the previous partial sidecar"
  )
  H.eq(
    store:recording(publishing.record.id).partial_path,
    publishing.partial,
    "publication retains the original partial path in storage"
  )
  uv.fs_rename = original.rename
  local unlink = uv.fs_unlink
  uv.fs_unlink = function(path, ...)
    if path == publishing.partial .. ".json" then
      return nil, "EACCES: partial sidecar cleanup failed", "EACCES"
    end
    return unlink(path, ...)
  end
  local cleanup_warnings = Recorder.recover(store, opts)
  H.check(
    #cleanup_warnings == 1 and cleanup_warnings[1]:find("recording_sidecar_cleanup", 1, true),
    "partial sidecar cleanup failure is reported"
  )
  H.eq(
    store:recording(publishing.record.id).recovery_pending,
    true,
    "cleanup failure keeps the recording retryable"
  )
  H.check(
    uv.fs_stat(publishing.partial .. ".json") ~= nil,
    "cleanup failure retains the old metadata for retry"
  )
  uv.fs_unlink = unlink
  H.eq(#Recorder.recover(store, opts), 0, "recovery repairs the final sidecar")
  H.eq(
    store:recording(publishing.record.id).status,
    "complete",
    "metadata recovery preserves completed audio"
  )
  H.eq(
    store:recording(publishing.record.id).recovery_pending,
    false,
    "metadata recovery clears the persisted marker"
  )
  H.eq(
    uv.fs_stat(publishing.partial .. ".json"),
    nil,
    "metadata recovery removes the superseded partial sidecar"
  )
  local removing = setmetatable({ store = store, recordings_revision = 0, listeners = {} }, Engine)
  removing:remove_recording(publishing.record.id)
  H.eq(store:recording(publishing.record.id), nil, "recovered recording index can be removed")
  H.eq(uv.fs_stat(publishing.final_path), nil, "deletion removes recovered audio")
  H.eq(
    uv.fs_stat(publishing.final_path .. ".json"),
    nil,
    "deletion removes recovered final metadata"
  )
  H.eq(
    uv.fs_stat(publishing.partial .. ".json"),
    nil,
    "recovery then deletion leaves no partial metadata behind"
  )

  -- Older complete rows have no partial_path. Recover only sidecars whose
  -- decoded identity and audio path match, preserving unrelated files.
  for _, matching in ipairs({ true, false }) do
    local path = dir .. (matching and "/legacy.mp3" or "/foreign.mp3")
    local legacy = model.recording({
      id = path,
      path = path,
      final_path = path,
      status = "complete",
      recovery_pending = true,
    })
    vim.fn.writefile({ "audio" }, path)
    local previous =
      model.recording({ id = matching and legacy.id or "someone-else", path = path .. ".part" })
    vim.fn.writefile({ model.encode_recording(previous) }, path .. ".part.json")
    store:save_recording(legacy)
    H.eq(#Recorder.recover(store, opts), 0, "legacy metadata recovery succeeds")
    H.eq(
      uv.fs_stat(path .. ".part.json") == nil,
      matching,
      "legacy cleanup checks sidecar ownership"
    )
    H.eq(
      store:recording(legacy.id).partial_path,
      matching and (path .. ".part") or nil,
      "legacy cleanup records only a verified partial path"
    )
    removing:remove_recording(legacy.id)
  end

  local tracked = model.recording({
    id = "tracked",
    path = dir .. "/tracked.mp3",
    final_path = dir .. "/tracked.mp3",
    partial_path = dir .. "/original-audio.part",
    status = "complete",
    recovery_pending = true,
  })
  vim.fn.writefile({ "audio" }, tracked.path)
  vim.fn.writefile({ "{}" }, tracked.partial_path .. ".json")
  store:save_recording(tracked)
  H.eq(#Recorder.recover(store, opts), 0, "tracked nonstandard partial path recovers")
  H.eq(uv.fs_stat(tracked.partial_path .. ".json"), nil, "cleanup uses the persisted original path")
  removing:remove_recording(tracked.id)

  uv.fs_open = function(path, ...)
    if path:match("%.json%.tmp$") then
      return nil, "ENOSPC: sidecar disk is full", "ENOSPC"
    end
    return original.open(path, ...)
  end
  local initial = start()
  H.eq(
    store:recording(initial.record.id).recovery_pending,
    true,
    "initial sidecar failure persists a retry marker"
  )
  uv.fs_open = original.open
  initial:cancel("test cleanup")
  H.wait_for(2000, function()
    return initial.ended
  end, "initial sidecar failure leaves a reapable writer")
  H.check(
    table.concat(notices, "\n"):find("recording_sidecar", 1, true),
    "sidecar failures notify the user"
  )
  vim.notify = notify
  store:close()
end
