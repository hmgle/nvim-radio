local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  local Recorder = require("radio.recorder")
  local model = require("radio.model")
  local dir = H.tmpdir("recorder-faults")
  config.setup({ data_dir = dir, recording_min_free_mb = 1, auto_sync_days = 0 })
  local store = assert(require("radio.store").open(config.options.db_path))
  local audio = H.make_mp3(dir, 1)
  local writer = dir .. "/writer"
  vim.fn.writefile({ "#!/bin/sh", "cat " .. vim.fn.shellescape(audio) }, writer)
  vim.uv.fs_chmod(writer, 448)
  local opts = vim.tbl_extend("force", config.options, { ffmpeg = writer })
  local function start()
    return assert(
      Recorder.start(
        opts,
        store,
        model.station({ name = "Persistence failures" }),
        "https://example.test/live",
        dir .. "/recordings",
        nil,
        { streams = { { codec_name = "mp3" } } }
      )
    )
  end
  local notify, notices = vim.notify, {}
  vim.notify = function(message)
    notices[#notices + 1] = message
  end
  local save = store.save_recording
  local function fail_save()
    error("SQLITE_FULL: database or disk is full")
  end

  -- Cancellation must still kill and reap a live child if SQLite fails.
  vim.fn.writefile({ "#!/bin/sh", "trap '' INT", "exec sleep 30" }, writer)
  local cancelled = start()
  store.save_recording = fail_save
  H.check(pcall(cancelled.cancel, cancelled, "shutdown timeout"), "cancel survives SQLite failure")
  cancelled:cancel("again")
  local callbacks, cancel_err = 0, nil
  cancelled:finish(nil, function(_, err)
    callbacks, cancel_err = callbacks + 1, err
  end)
  local reaped = H.wait_for(3000, function()
    return cancelled.ended and callbacks == 1
  end, "failed cancellation persistence still reaps and settles")
  store.save_recording = save
  if not reaped then
    pcall(vim.uv.process_kill, cancelled.handle, "sigkill")
    vim.wait(1000, function()
      return cancelled.ended
    end)
  end
  H.check(
    cancel_err and cancel_err:find("SQLITE_FULL", 1, true),
    "callback reports persistence failure"
  )
  H.eq(cancelled.handle:is_closing(), true, "cancel closes the process handle")
  H.eq(cancelled._stderr_pipe:is_closing(), true, "cancel closes the stderr pipe")
  H.check(vim.uv.fs_stat(cancelled.partial) ~= nil, "cancel retains partial audio")
  H.check(vim.uv.fs_stat(cancelled.partial .. ".json") ~= nil, "cancel retains recovery sidecar")

  -- Fail each publication write separately, plus the terminal failure write.
  for _, scenario in ipairs({ "finalizing", "complete", "failed" }) do
    vim.fn.writefile(
      { "#!/bin/sh", scenario == "failed" and "exit 1" or ("cat " .. vim.fn.shellescape(audio)) },
      writer
    )
    local recorder = start()
    H.wait_for(3000, function()
      return recorder.ended
    end, scenario .. " writer exits")
    store.save_recording = function(self, record)
      if record.status == scenario then
        fail_save()
      end
      return save(self, record)
    end
    local done, finish_err = 0, nil
    recorder:finish(nil, function(_, err)
      done, finish_err = done + 1, err
    end)
    recorder:finish(nil, function()
      done = done + 1
    end)
    H.wait_for(4000, function()
      return done == 2
    end, scenario .. " write failure settles every waiter")
    store.save_recording = save
    H.check(
      finish_err and finish_err:find("SQLITE_FULL", 1, true),
      scenario .. " write failure reaches callback"
    )
    H.eq(recorder._stderr_pipe:is_closing(), true, scenario .. " closes stderr")
    H.eq(recorder.record.recovery_pending, true, scenario .. " keeps recovery metadata")
    H.check(
      vim.uv.fs_stat(recorder.record.path .. ".json") ~= nil,
      scenario .. " writes sidecar despite database failure"
    )
    if scenario == "finalizing" then
      H.check(
        vim.uv.fs_stat(recorder.partial) ~= nil,
        "failed publication intent retains the partial"
      )
      H.eq(
        vim.uv.fs_stat(recorder.final_path),
        nil,
        "failed publication intent does not rename audio"
      )
    elseif scenario == "complete" then
      H.check(
        vim.uv.fs_stat(recorder.final_path) ~= nil,
        "failed final write retains published audio"
      )
      H.eq(#Recorder.recover(store, opts), 0, "publication can be recovered after SQLite recovers")
      H.eq(
        store:recording(recorder.record.id).status,
        "complete",
        "recovery finishes the pending index"
      )
    end
  end
  H.check(
    table.concat(notices, "\n"):find("SQLITE_FULL", 1, true),
    "persistence failure is reported separately"
  )
  vim.notify = notify
  store:close()
end
