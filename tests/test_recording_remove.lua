local H = require("tests.helpers")

return function()
  local radio = require("radio")
  local model = require("radio.model")
  local dir = H.tmpdir("recording-remove")
  radio.setup({ data_dir = dir, auto_sync_days = 0 })
  local engine = assert(radio.engine({ auto_sync = false }))
  local path = dir .. "/audio.mp3"
  local record = model.recording({ id = "delete-me", path = path, status = "complete" })
  local function reset()
    engine.store:save_recording(record)
    vim.fn.writefile({ "audio" }, path)
    vim.fn.writefile({ "{}" }, path .. ".json")
  end
  local unlink, notify = vim.uv.fs_unlink, vim.notify
  local denied, attempts, messages = path, {}, {}
  vim.uv.fs_unlink = function(file)
    attempts[#attempts + 1] = file
    if file == denied then
      return nil, "EACCES: permission denied", "EACCES"
    end
    return unlink(file)
  end
  vim.notify = function(message, level)
    messages[#messages + 1] = { message, level }
  end
  reset()
  local ok, err = pcall(radio.recording_remove, record.id)
  H.check(
    not ok and tostring(err):find("EACCES", 1, true),
    "public deletion reports file permissions error"
  )
  H.check(engine.store:recording(record.id) ~= nil, "failed file deletion preserves index")
  H.check(vim.uv.fs_stat(path) ~= nil, "failed file deletion keeps audio")
  H.eq(#attempts, 1, "audio failure leaves sidecar untouched")

  -- Browser deletion uses the same operation and reports errors locally.
  local browser = require("radio.ui.browser").new(engine)
  browser.source = "recordings"
  browser:open()
  local select = vim.ui.select
  vim.ui.select = function(items, _, cb)
    cb(items[1], 1)
  end
  H.check(pcall(browser.delete_recording, browser), "browser deletion handles permissions error")
  H.check(engine.store:recording(record.id) ~= nil, "browser error preserves index")
  H.check(
    messages[#messages] and messages[#messages][2] == vim.log.levels.ERROR,
    "browser reports failure instead of success"
  )

  denied = path .. ".json"
  local sidecar_ok, sidecar_err = pcall(radio.recording_remove, record.id)
  H.check(
    not sidecar_ok and tostring(sidecar_err):find("EACCES", 1, true),
    "sidecar deletion errors are reported"
  )
  H.check(engine.store:recording(record.id) ~= nil, "sidecar failure preserves index for retry")
  denied = nil
  H.check(pcall(radio.recording_remove, record.id), "retry tolerates missing audio")
  H.eq(engine.store:recording(record.id), nil, "successful retry removes index")
  H.eq(vim.uv.fs_stat(path .. ".json"), nil, "successful retry removes sidecar")
  engine.store:save_recording(record)
  H.check(pcall(radio.recording_remove, record.id), "missing audio and sidecar are tolerated")

  reset()
  denied, attempts = path, {}
  H.check(pcall(radio.recording_remove, record.id, true), "index-only removal succeeds")
  H.eq(#attempts, 0, "index-only removal never unlinks files")
  H.check(vim.uv.fs_stat(path) ~= nil, "index-only removal keeps audio")
  for _, state in ipairs({ "recording", "finalizing", "pending" }) do
    record.status = state == "pending" and "interrupted" or state
    record.recovery_pending = state == "pending"
    engine.store:save_recording(record)
    local active_ok, active_err = pcall(radio.recording_remove, record.id, true)
    H.check(
      not active_ok and tostring(active_err):find("recording_in_use", 1, true),
      "deletion rejects " .. state
    )
  end
  vim.ui.select = select
  vim.uv.fs_unlink = unlink
  vim.notify = notify
  browser:close()
  engine:shutdown()
end
