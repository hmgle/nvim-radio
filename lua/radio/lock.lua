-- Kernel-owned session lock, shared with radio-cli. Never unlink the file:
-- contenders must always lock the same inode, including after a crash.
local ffi = require("ffi")
ffi.cdef([[int flock(int fd, int operation);]])

local Lock = {}
Lock.__index = Lock

local function acquire(path, operation)
  local fd, err = vim.uv.fs_open(path, "a+", 384)
  if not fd then
    return nil, "session_lock: " .. tostring(err)
  end
  local ok, result = pcall(ffi.C.flock, fd, operation + 4) -- LOCK_NB
  if not ok or result ~= 0 then
    vim.uv.fs_close(fd)
    return nil,
      ok and "media_busy: another session owns this data directory"
        or ("session_lock: " .. tostring(result))
  end
  return setmetatable({ fd = fd, path = path }, Lock)
end

function Lock.acquire(runtime_dir)
  return acquire(runtime_dir .. "/media.lock", 2) -- LOCK_EX
end

---Every session participates, including sessions bypassing media.lock.
---An exclusive recovery lease is downgraded after startup; shared leases
---remain held until all owned writers and finalizers have exited.
function Lock.recovery(runtime_dir, exclusive)
  local path = runtime_dir .. "/recovery.lock"
  if exclusive then
    local lock = acquire(path, 2)
    if lock then
      return lock, true
    end
  end
  local lock, err = acquire(path, 1) -- LOCK_SH
  return lock, false, err
end

function Lock:share()
  assert(ffi.C.flock(self.fd, 1 + 4) == 0, "session_lock: cannot share recovery lease")
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
