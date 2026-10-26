-- A separate Neovim process contends for the same kernel lock as its parent.
vim.opt.runtimepath:prepend(arg[1])
local Lock = require("radio.lock")
local lock, err
if arg[5] == "shared-recovery" then
  lock, _, err = Lock.recovery(arg[2], false)
else
  lock, err = Lock.acquire(arg[2])
end
local fd = assert(vim.uv.fs_open(arg[3], "w", 384))
vim.uv.fs_write(fd, lock and "owned" or tostring(err))
vim.uv.fs_close(fd)
if lock then
  vim.wait(10000, function()
    return vim.uv.fs_stat(arg[4]) ~= nil
  end, 10)
  lock:release()
end
vim.cmd("qa!")
