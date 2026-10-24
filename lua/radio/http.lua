-- HTTP via curl, driven by vim.system so nothing blocks the editor.
local M = {}

local util = require("radio.util")
local version = require("radio.version").version

M.USER_AGENT = "nvim-radio/" .. version
M.MAX_RESPONSE_BYTES = 16 * 1024 * 1024

local temp_counter = 0

---Temp file name without the Vimscript API (fast-event safe).
---@return string
local function tempname()
  temp_counter = temp_counter + 1
  return vim.uv.os_tmpdir()
    .. "/nvim-radio-http-"
    .. tostring(vim.uv.os_getpid())
    .. "-"
    .. temp_counter
    .. "-"
    .. string.format("%06d", math.random(1, 999999))
end

---Read a whole file through libuv (safe in fast-event contexts).
---@param path string
---@return string|nil
local function read_file(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  local data = stat and stat.size > 0 and vim.uv.fs_read(fd, stat.size, 0) or ""
  vim.uv.fs_close(fd)
  return data
end

---@param args string[]
---@param on_done fun(code: integer, http_code: integer, err: string|nil)
local function run_curl(args, on_done)
  vim.system(args, {}, function(result)
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
  local outfile = tempname()
  run_curl(
    curl_args(method, url, vim.tbl_extend("force", opts or {}, { outfile = outfile })),
    function(code, http_code, curl_err)
      local function finish(err, body, status)
        vim.uv.fs_unlink(outfile, function() end)
        cb(err, body, status)
      end
      if code == 63 then
        finish("directory_response_too_large", nil, nil)
        return
      end
      if code ~= 0 then
        finish("directory_request: " .. (curl_err or ("curl exit " .. code)), nil, nil)
        return
      end
      local status = http_code
      if status < 200 or status >= 300 then
        finish("directory_request: HTTP " .. status, nil, status)
        return
      end
      local data = read_file(outfile)
      if not data then
        finish("directory_request: cannot read response", nil, status)
        return
      end
      finish(nil, data, status)
    end
  )
end

---@param url string
---@param opts table|nil
---@param cb fun(err: string|nil, body: string|nil, status: integer|nil)
function M.get(url, opts, cb)
  M.request("GET", url, opts, cb)
end

---@param url string
---@param opts table|nil
---@param cb fun(err: string|nil, body: string|nil, status: integer|nil)
function M.post(url, opts, cb)
  M.request("POST", url, opts, cb)
end

---Blocking GET, for tests and short diagnostics.
---@param url string
---@param opts table|nil
---@return string|nil body, string|nil err
function M.get_sync(url, opts)
  local outfile = tempname()
  local args = curl_args("GET", url, vim.tbl_extend("force", opts or {}, { outfile = outfile }))
  local result = vim.system(args, {}):wait()
  vim.uv.fs_unlink(outfile, function() end)
  local code = result.code or 0
  if code ~= 0 then
    return nil,
      (
        util.system_output(result.stderr) ~= "" and util.system_output(result.stderr)
        or ("curl exit " .. code)
      )
  end
  local body = read_file(outfile)
  if not body then
    return nil, "cannot read response"
  end
  return body, nil
end

return M
