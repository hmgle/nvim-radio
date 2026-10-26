-- Manual benchmark: nvim --headless -u NONE -l tests/benchmark_sync.lua
-- Publish 50,000 synthetic stations, then repeat with no changes and with
-- 1% changed popularity values. Timings are milliseconds, not test limits.
package.path = vim.fn.getcwd()
  .. "/lua/?.lua;"
  .. vim.fn.getcwd()
  .. "/lua/?/init.lua;"
  .. package.path
local Store = require("radio.store")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local store = assert(Store.open(dir .. "/radio.db"))
local timings = {}
for _, name in ipairs({ "rebuild_facets", "refresh_search_stats" }) do
  local original = store[name]
  store[name] = function(self, ...)
    local start = vim.uv.hrtime()
    local result = original(self, ...)
    timings[name] = (vim.uv.hrtime() - start) / 1e6
    return result
  end
end
for _, phase in ipairs({ "initial", "unchanged", "changed" }) do
  store:begin_sync()
  for batch = 0, 49 do
    local rows = {}
    for j = 1, 1000 do
      local i = batch * 1000 + j
      rows[j] = {
        stationuuid = string.format("%08x-1111-4111-8111-%012x", i, i),
        name = string.format("Station %05d", i),
        url = "https://example.test/" .. i,
        countrycode = i % 2 == 0 and "DE" or "FR",
        language = "english,german",
        tags = "music,jazz,tag" .. (i % 100),
        clickcount = phase == "changed" and i % 100 == 0 and (i + 1) or i,
        active = true,
      }
    end
    store:stage(rows)
  end
  local start = vim.uv.hrtime()
  store:finish_sync()
  timings.finish_sync = (vim.uv.hrtime() - start) / 1e6
  io.write(phase .. " " .. vim.json.encode(timings) .. "\n")
end
store:close()
vim.fn.delete(dir, "rf")
vim.cmd("qa!")
