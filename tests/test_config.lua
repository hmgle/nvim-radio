local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  config.setup({ data_dir = H.tmpdir("config"), auto_sync_days = 0 })
  local valid = config.options
  config.setup({
    data_dir = valid.data_dir,
    auto_sync_days = 0,
    keys = { toggle = false },
  })
  valid = vim.deepcopy(config.options)
  H.eq(config.options.keys.toggle, false, "false disables an inherited global key")
  local cases = {
    { { keys = { toggle = 5 } }, "keys.toggle" },
    { { keys = 5 }, "keys" },
    { { audio_device = 5 }, "audio_device" },
    { { api_url = 42 }, "api_url" },
    { { api_url = "bad-url" }, "api_url" },
    { { data_dir = 5 }, "data_dir" },
    { { recording_dir = 5 }, "recording_dir" },
    { { ui = { width = "abc" } }, "ui.width" },
    { { ui = { height = 0 } }, "ui.height" },
    { { ui = { border = "invalid" } }, "ui.border" },
    { { ui = false }, "ui" },
    { { normalize_loudness = 1 }, "normalize_loudness" },
    { { volume = 0 / 0 }, "volume" },
    { { auto_sync_days = math.huge }, "auto_sync_days" },
    { 5, "options" },
  }
  for _, case in ipairs(cases) do
    local ok, err = pcall(config.setup, case[1])
    H.check(
      not ok and err:find("invalid settings:", 1, true) and err:find(case[2], 1, true),
      "invalid option is rejected at setup: " .. case[2]
    )
    H.check(vim.deep_equal(config.options, valid), "invalid setup preserves previous configuration")
  end
end
