local H = require("tests.helpers")

return function()
  local Recorder = require("radio.recorder")
  local model = require("radio.model")
  local dir = H.tmpdir("atomic-publication")
  local store = assert(require("radio.store").open(dir .. "/radio.db"))
  local uv = vim.uv
  local function recording(id)
    local partial, final = dir .. "/" .. id .. ".mp3.part", dir .. "/" .. id .. ".mp3"
    vim.fn.writefile({ "recorded audio" }, partial)
    return model.recording({
      id = id,
      path = partial,
      partial_path = partial,
      final_path = final,
      size_bytes = uv.fs_stat(partial).size,
      status = "finalizing",
    })
  end

  local link, rename, unlink = uv.fs_link, uv.fs_rename, uv.fs_unlink
  local raced = recording("raced")
  local function competing_file(from, to)
    if from == raced.path and to == raced.final_path then
      vim.fn.writefile({ "unrelated audio" }, to)
    end
  end
  -- Inject at either syscall boundary so a check-then-rename implementation
  -- would overwrite the competing file and fail these assertions.
  uv.fs_link = function(from, to)
    competing_file(from, to)
    return link(from, to)
  end
  uv.fs_rename = function(from, to)
    competing_file(from, to)
    return rename(from, to)
  end
  local ok = pcall(Recorder._complete_finalization, store, raced)
  uv.fs_link, uv.fs_rename = link, rename
  H.eq(ok, false, "destination created during publication causes a conflict")
  H.eq(
    table.concat(vim.fn.readfile(raced.final_path)),
    "unrelated audio",
    "competing audio survives"
  )
  H.eq(
    table.concat(vim.fn.readfile(raced.path)),
    "recorded audio",
    "conflict retains partial audio"
  )

  local dangling = recording("dangling")
  assert(uv.fs_symlink(dir .. "/absent", dangling.final_path))
  H.eq(
    pcall(Recorder._complete_finalization, store, dangling),
    false,
    "dangling symlink is a conflict"
  )
  H.eq(uv.fs_lstat(dangling.final_path).type, "link", "publication preserves existing symlinks")

  local unsupported = recording("unsupported")
  uv.fs_link = function()
    return nil, "ENOTSUP: links unsupported", "ENOTSUP"
  end
  ok = pcall(Recorder._complete_finalization, store, unsupported)
  uv.fs_link = link
  H.eq(ok, false, "unsupported hard links fail without destructive fallback")
  H.check(uv.fs_stat(unsupported.path) ~= nil, "unsupported links retain partial audio")
  H.eq(uv.fs_stat(unsupported.final_path), nil, "unsupported links do not publish")

  -- Simulate interruption between link and unlink. Startup must recognize
  -- its own inode and finish publication without losing either audio copy.
  local interrupted = recording("interrupted")
  local partial = interrupted.path
  store:save_recording(interrupted)
  uv.fs_unlink = function(path, ...)
    if path == partial then
      return nil, "EACCES: temporary denial", "EACCES"
    end
    return unlink(path, ...)
  end
  ok = pcall(Recorder._complete_finalization, store, interrupted)
  uv.fs_unlink = unlink
  H.eq(ok, false, "partial unlink failure is reported")
  H.eq(
    uv.fs_stat(partial).ino,
    uv.fs_stat(interrupted.final_path).ino,
    "both names preserve the same audio"
  )
  H.eq(#Recorder.recover(store, {}), 0, "recovery finishes interrupted link publication")
  H.eq(store:recording(interrupted.id).status, "complete", "recovered publication is complete")
  H.eq(uv.fs_stat(partial), nil, "recovery removes the partial name")
  H.eq(
    table.concat(vim.fn.readfile(interrupted.final_path)),
    "recorded audio",
    "recovered audio is intact"
  )
  store:close()
end
