local H = require("tests.helpers")

return function()
  local http = require("radio.http")
  local util = require("radio.util")
  local payload = string.rep("short reads ", 10000)
  local url, stop = H.start_server({ ["/body"] = payload })
  local read = vim.uv.fs_read
  vim.uv.fs_read = function(fd, size, offset)
    return read(fd, math.min(size, 97), offset)
  end
  local done, response = false, nil
  http.get(url .. "/body", {}, function(err, body)
    H.eq(err, nil, "HTTP succeeds with short filesystem reads")
    response, done = body, true
  end)
  H.wait_for(5000, function()
    return done
  end, "short-read HTTP request completes")
  vim.uv.fs_read = read
  H.eq(response, payload, "HTTP response is read through EOF")
  stop()

  local system = vim.system
  local outfile
  vim.system = function(args)
    for i, arg in ipairs(args) do
      if arg == "-o" then
        outfile = args[i + 1]
      end
    end
    H.eq(bit.band(vim.uv.fs_stat(outfile).mode, 511), 384, "HTTP response file is private")
    vim.fn.writefile({ "sync response" }, outfile)
    return {
      wait = function()
        return { code = 0, stdout = "200" }
      end,
    }
  end
  local body, err = http.get_sync("http://example.test", {})
  vim.system = system
  H.eq(body, "sync response\n", "blocking HTTP reads before cleanup")
  H.eq(err, nil, "blocking HTTP succeeds")
  H.eq(vim.uv.fs_stat(outfile), nil, "response file removed after reading")

  local dir = H.tmpdir("http-collision")
  local victim = dir .. "/victim"
  vim.fn.writefile({ "keep" }, victim)
  local uuid = util.uuid_v4
  local name = "collision-" .. vim.uv.os_getpid()
  local collision = vim.uv.os_tmpdir() .. "/nvim-radio-http-" .. name
  vim.uv.fs_unlink(collision)
  assert(vim.uv.fs_symlink(victim, collision))
  util.uuid_v4 = function()
    return name
  end
  local error_done = false
  http.get("http://example.test", {}, function(request_err)
    H.check(
      request_err and request_err:find("cannot create response file", 1, true),
      "exclusive create rejects symlink collision"
    )
    error_done = true
  end)
  util.uuid_v4 = uuid
  H.wait_for(1000, function()
    return error_done
  end, "temp allocation error uses callback")
  H.eq(vim.fn.readfile(victim)[1], "keep", "symlink target is never overwritten")
  vim.uv.fs_unlink(collision)
end
