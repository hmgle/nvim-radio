-- HTTP via curl, driven by vim.system so nothing blocks the editor.
local M = {}

local util = require("radio.util")
local version = require("radio.version").version

M.USER_AGENT = "nvim-radio/" .. version
M.MAX_RESPONSE_BYTES = 16 * 1024 * 1024

---Reserve an unpredictable, private file before handing its path to curl.
local function tempname()
  local path = vim.uv.os_tmpdir() .. "/nvim-radio-http-" .. util.uuid_v4()
  local fd, err = vim.uv.fs_open(path, "wx", 384)
  if not fd then
    return nil, tostring(err)
  end
  vim.uv.fs_close(fd)
  return path
end

---Read through EOF, including filesystems that return short reads.
local function read_file(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local chunks, offset = {}, 0
  while true do
    local chunk = vim.uv.fs_read(fd, 65536, offset)
    if not chunk then
      vim.uv.fs_close(fd)
      return nil
    end
    if #chunk == 0 then
      break
    end
    chunks[#chunks + 1] = chunk
    offset = offset + #chunk
  end
  vim.uv.fs_close(fd)
  return table.concat(chunks)
end

---@param args string[]
---@param on_done fun(code: integer, http_code: integer, err: string|nil)
local function run_curl(args, on_done)
  return vim.system(args, {}, function(result)
    local code = result.code or 0
    local http_code = tonumber(util.system_output(result.stdout)) or 0
    local errtext = util.system_output(result.stderr)
    on_done(code, http_code, errtext ~= "" and errtext or nil)
  end)
end

---Build curl arguments for a request; the body lands in a temp file so
---stdout stays reserved for the status code.
---@param method string
---@param url string
---@param opts table|nil {timeout, connect_timeout, body, headers, outfile}
---@return string[]
local function curl_args(method, url, opts)
  opts = opts or {}
  local args = {
    "curl",
    "-sS",
    "--compressed",
    "-A",
    M.USER_AGENT,
    "--connect-timeout",
    tostring(math.floor(opts.connect_timeout or 5)),
    "--max-time",
    tostring(math.floor(opts.timeout or 20)),
    "--max-filesize",
    tostring(opts.max_bytes or M.MAX_RESPONSE_BYTES),
    "-X",
    method,
    "-w",
    "%{http_code}",
    "-o",
    opts.outfile,
  }
  for _, header in ipairs(opts.headers or {}) do
    args[#args + 1] = "-H"
    args[#args + 1] = header
  end
  if opts.body then
    args[#args + 1] = "--data-binary"
    args[#args + 1] = opts.body
  end
  args[#args + 1] = url
  return args
end

---@param method string
---@param url string
---@param opts table|nil
---@param cb fun(err: string|nil, body: string|nil, status: integer|nil)
function M.request(method, url, opts, cb)
  local outfile, temp_err = tempname()
  local request = {}
  local function finish(err, body, status)
    request.done = true
    if outfile then
      vim.uv.fs_unlink(outfile, function() end)
    end
    if not request.cancelled then
      cb(err, body, status)
    end
  end
  if not outfile then
    function request:cancel()
      self.cancelled = true
    end
    vim.schedule(function()
      finish("directory_request: cannot create response file: " .. temp_err)
    end)
    return request
  end
  local ok, handle = pcall(
    run_curl,
    curl_args(method, url, vim.tbl_extend("force", opts or {}, { outfile = outfile })),
    function(code, http_code, curl_err)
      if code == 63 then
        finish("directory_response_too_large", nil, nil)
        return
      end
      if code ~= 0 then
        finish("directory_request: " .. (curl_err or ("curl exit " .. code)), nil, nil)
        return
      end
      if http_code < 200 or http_code >= 300 then
        finish("directory_request: HTTP " .. http_code, nil, http_code)
        return
      end
      local data = read_file(outfile)
      if not data then
        finish("directory_request: cannot read response", nil, http_code)
        return
      end
      finish(nil, data, http_code)
    end
  )
  if ok then
    request.handle = handle
  else
    vim.schedule(function()
      finish("directory_request: " .. tostring(handle))
    end)
  end
  function request:cancel()
    if self.done or self.cancelled then
      return
    end
    self.cancelled = true
    if self.handle then
      pcall(self.handle.kill, self.handle, "sigkill")
    end
    vim.uv.fs_unlink(outfile, function() end)
  end
  return request
end

---@param url string
---@param opts table|nil
---@param cb fun(err: string|nil, body: string|nil, status: integer|nil)
function M.get(url, opts, cb)
  return M.request("GET", url, opts, cb)
end

---@param url string
---@param opts table|nil
---@param cb fun(err: string|nil, body: string|nil, status: integer|nil)
function M.post(url, opts, cb)
  return M.request("POST", url, opts, cb)
end

---Blocking GET, for tests and short diagnostics.
---@param url string
---@param opts table|nil
---@return string|nil body, string|nil err
function M.get_sync(url, opts)
  local outfile, temp_err = tempname()
  if not outfile then
    return nil, temp_err
  end
  local args = curl_args("GET", url, vim.tbl_extend("force", opts or {}, { outfile = outfile }))
  local ok, result = pcall(function()
    return vim.system(args, {}):wait()
  end)
  local body = ok and result.code == 0 and read_file(outfile) or nil
  vim.uv.fs_unlink(outfile)
  if not ok then
    return nil, tostring(result)
  end
  if result.code ~= 0 then
    return nil,
      util.system_output(result.stderr) ~= "" and util.system_output(result.stderr)
        or ("curl exit " .. tostring(result.code))
  end
  if not body then
    return nil, "cannot read response"
  end
  return body, nil
end

return M
