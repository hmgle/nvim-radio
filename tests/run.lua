-- Test entry point: nvim --headless -l tests/run.lua
-- Requires mpv, ffmpeg, ffprobe, and libsqlite3 on the host.
package.path = table.concat({
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/?.lua",
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/../lua/?.lua",
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/../lua/?/init.lua",
  package.path,
}, ";")

local H = require("tests.helpers")
H.setup_runtime()

local suites = {
  "test_lock",
  "test_store",
  "test_player",
  "test_recorder",
  "test_directory",
  "test_async",
  "test_engine",
  "test_ui",
  "test_regressions",
  "test_commands",
}

local only = vim.env.NVIM_RADIO_TESTS
if only and only ~= "" then
  suites = vim.split(only, ",")
end

for _, name in ipairs(suites) do
  io.write("== " .. name .. " ==\n")
  local ok, err = pcall(require("tests." .. name))
  if not ok then
    H.failed = H.failed + 1
    H.failures[#H.failures + 1] = name .. " crashed: " .. tostring(err)
    io.write("CRASH: " .. tostring(err) .. "\n")
  end
end

local ok = H.report()
vim.cmd((ok and "qa!" or "cq 1") .. "")
