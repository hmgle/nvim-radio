local H = require("tests.helpers")

return function()
  local Lock = require("radio.lock")
  local dir = H.tmpdir("kernel-lock")
  local function child(id, release)
    return vim.system({
      vim.v.progpath,
      "--headless",
      "-u",
      "NONE",
      "-l",
      H.root .. "/tests/fixtures/lock_owner.lua",
      H.root,
      dir,
      dir .. "/result-" .. id,
      release,
    })
  end
  local function result(id)
    local path = dir .. "/result-" .. id
    H.wait_for(5000, function()
      return vim.uv.fs_stat(path) ~= nil
    end, "lock contender finishes")
    return table.concat(vim.fn.readfile(path))
  end
  local release = dir .. "/release"
  local one, two = child("one", release), child("two", release)
  local a, b = result("one"), result("two")
  H.check((a == "owned") ~= (b == "owned"), "only one simultaneous process acquires the lock")
  local owner, loser = a == "owned" and one or two, a == "owned" and two or one
  H.eq(loser:wait(5000).code, 0, "blocked contender exits normally")
  owner:kill("sigkill")
  owner:wait(5000)
  local recovered = assert(Lock.acquire(dir))
  H.check(vim.uv.fs_stat(dir .. "/media.lock") ~= nil, "lock inode survives owner crash")
  H.eq(Lock.acquire(dir), nil, "same-process contenders are excluded too")
  recovered:release()
  recovered:release()
  local next_owner = assert(Lock.acquire(dir))
  H.check(true, "kernel releases ownership after crash and normal close")
  next_owner:release()

  -- libuv and external flock must agree (radio-cli uses flock on media.lock).
  if vim.fn.executable("flock") == 1 then
    local external = vim.system({ "flock", "-n", dir .. "/media.lock", "true" }):wait()
    H.eq(external.code, 0, "external flock can acquire a released session")
    local held = assert(Lock.acquire(dir))
    external = vim.system({ "flock", "-n", dir .. "/media.lock", "true" }):wait()
    H.check(external.code ~= 0, "external flock cannot enter an owned session")
    held:release()
  end
end
