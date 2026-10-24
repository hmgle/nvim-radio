-- Kernel-owned session lock, shared with radio-cli. Never unlink the file:
-- contenders must always lock the same inode, including after a crash.
local ffi = require("ffi")
ffi.cdef([[int flock(int fd, int operation);]])

local Lock = {}
Lock.__index = Lock

function Lock.acquire(runtime_dir)
  local path = runtime_dir .. "/media.lock"
  local fd, err = vim.uv.fs_open(path, "a+", 384)
  if not fd then
    return nil, "session_lock: " .. tostring(err)
  end
  local ok, result = pcall(ffi.C.flock, fd, 2 + 4) -- LOCK_EX | LOCK_NB
  if not ok or result ~= 0 then
    vim.uv.fs_close(fd)
    return nil,
      ok and "media_busy: another session owns this data directory"
        or ("session_lock: " .. tostring(result))
  end
  return setmetatable({ fd = fd, path = path }, Lock)
end

function Lock:release()
  if self.fd then
    -- Explicit unlock also prevents inherited descriptors prolonging ownership.
    ffi.C.flock(self.fd, 8) -- LOCK_UN
    vim.uv.fs_close(self.fd)
    self.fd = nil
  end
end

return Lock
