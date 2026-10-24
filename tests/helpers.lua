-- Test helpers: isolated data dirs, an in-process HTTP server for streams,
-- and a fake Radio Browser directory.
local M = {}

local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

M.root = ROOT

M.passed = 0
M.failed = 0
M.failures = {}

function M.setup_runtime()
  vim.opt.runtimepath:prepend(ROOT)
end

---@param name string
---@return string dir
function M.tmpdir(name)
  local dir = "/tmp/nvim-radio-test/" .. name
  vim.fn.delete(dir, "rf")
  vim.fn.mkdir(dir, "p")
  return dir
end

function M.check(ok, message)
  if ok then
    M.passed = M.passed + 1
  else
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = message
    io.write("FAIL: " .. message .. "\n")
  end
end

function M.eq(actual, expected, message)
  M.check(
    actual == expected,
    string.format("%s (expected %s, got %s)", message, vim.inspect(expected), vim.inspect(actual))
  )
end

---Serve `routes` (path -> body string or function(query) -> body, status).
---@param routes table
---@return string url, function stop
function M.start_server(routes)
  local server = assert(vim.uv.new_tcp())
  server:bind("127.0.0.1", 0)
  server:listen(128, function(err)
    if err then
      return
    end
    local client = vim.uv.new_tcp()
    server:accept(client)
    client:read_start(function(read_err, chunk)
      if read_err or not chunk then
        if not client:is_closing() then
          client:close()
        end
        return
      end
      local request = chunk
      if type(request) == "table" then
        request = table.concat(request)
      end
      local path, query = request:match("^GET (%S+) HTTP")
      if not path then
        path = "/"
      end
      path = path:gsub("%?.*$", "")
      query = request:match("^GET %S+%?(%S*) HTTP") or ""
      local body, status = "not found", 404
      local route = routes[path]
      if type(route) == "function" then
        body, status = route(query)
      elseif type(route) == "string" then
        body, status = route, 200
      end
      client:write(
        "HTTP/1.1 "
          .. tostring(status)
          .. " OK\r\nContent-Type: application/json\r\nContent-Length: "
          .. #body
          .. "\r\nConnection: close\r\n\r\n"
          .. body
      )
      if not client:is_closing() then
        client:close(function()
          if not client:is_closing() then
            client:close()
          end
        end)
      end
    end)
  end)
  local port = server:getsockname().port
  return "http://127.0.0.1:" .. port, function()
    server:close()
  end
end

---Serve an MP3 in an endless loop so consumers never see EOF; used to test
---manual stop paths.
---@param path string
---@return string url, function stop
function M.start_loop_server(path)
  local fd = assert(vim.uv.fs_open(path, "r", 438))
  local stat = assert(vim.uv.fs_fstat(fd))
  local data = assert(vim.uv.fs_read(fd, stat.size, 0))
  vim.uv.fs_close(fd)

  local server = assert(vim.uv.new_tcp())
  server:bind("127.0.0.1", 0)
  server:listen(4, function()
    local client = vim.uv.new_tcp()
    server:accept(client)
    local timer
    local served = false
    client:read_start(function(err, chunk)
      if err or not chunk then
        if timer and not timer:is_closing() then
          timer:stop()
          timer:close()
        end
        if not client:is_closing() then
          client:close()
        end
        return
      end
      -- Answer the request once, then stream the payload forever.
      if not served then
        served = true
        client:write("HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nConnection: close\r\n\r\n")
        timer = vim.uv.new_timer()
        timer:start(0, 250, function()
          if client:is_closing() then
            timer:stop()
            timer:close()
            return
          end
          client:write(data)
        end)
      end
    end)
  end)
  local port = server:getsockname().port
  return "http://127.0.0.1:" .. port .. "/fixture.mp3", function()
    server:close()
  end
end

---Create a short MP3 fixture with FFmpeg.
---@param dir string
---@param seconds integer
---@return string path
function M.make_mp3(dir, seconds)
  local path = dir .. "/fixture.mp3"
  local result = vim
    .system({
      "ffmpeg",
      "-y",
      "-loglevel",
      "error",
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=" .. seconds,
      "-c:a",
      "libmp3lame",
      "-b:a",
      "128k",
      path,
    }, {})
    :wait()
  assert(result.code == 0, "ffmpeg fixture failed")
  return path
end

---Wait for a condition, failing the test when the deadline passes.
---@param timeout integer ms
---@param condition fun(): boolean
---@param message string
---@return boolean ok
function M.wait_for(timeout, condition, message)
  local ok = vim.wait(timeout, condition, 20)
  M.check(ok, message)
  return ok
end

function M.report()
  io.write(string.format("\n%d passed, %d failed\n", M.passed, M.failed))
  if M.failed > 0 then
    for _, failure in ipairs(M.failures) do
      io.write("  - " .. failure .. "\n")
    end
  end
  return M.failed == 0
end

return M
