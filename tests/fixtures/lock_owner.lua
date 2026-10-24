-- A separate Neovim process contends for the same kernel lock as its parent.
vim.opt.runtimepath:prepend(arg[1])
local lock, err = require("radio.lock").acquire(arg[2])
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
