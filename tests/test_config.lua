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

  local radio = require("radio")
  local function setup(keys)
    radio.setup({ data_dir = valid.data_dir, auto_sync_days = 0, keys = keys })
  end
  local function mapping(lhs)
    for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
      if map.lhs == lhs then
        return map
      end
    end
  end
  setup({ toggle = "<F9>" })
  H.check(mapping("<F9>") ~= nil, "setup installs an opted-in keymap")
  setup({ toggle = false })
  H.eq(mapping("<F9>"), nil, "repeated setup disables an old keymap")
  setup({ toggle = "<F9>" })
  setup({ toggle = "<F10>" })
  H.eq(mapping("<F9>"), nil, "changing keys removes the previous mapping")
  H.check(mapping("<F10>") ~= nil, "changing keys installs the new mapping")
  setup({})
  H.eq(mapping("<F10>"), nil, "omitting keys clears previous plugin mappings")

  setup({ toggle = "<F9>" })
  local replacement = function() end
  vim.keymap.set("n", "<F9>", replacement, { desc = "nvim-radio: toggle" })
  setup({ toggle = false })
  H.eq(mapping("<F9>").callback, replacement, "cleanup preserves mappings replaced by the user")
  vim.keymap.del("n", "<F9>")

  setup({ toggle = "<F9>" })
  vim.keymap.set("n", "<F9>", replacement, { buffer = 0 })
  setup({ toggle = false })
  H.eq(mapping("<F9>"), nil, "buffer-local shadowing does not prevent global cleanup")
  H.eq(
    vim.fn.maparg("<F9>", "n", false, true).callback,
    replacement,
    "buffer-local user map survives"
  )
  vim.keymap.del("n", "<F9>", { buffer = 0 })

  local leader = vim.g.mapleader
  vim.g.mapleader = ","
  setup({ toggle = "<leader>radio" })
  vim.g.mapleader = ";"
  setup({ toggle = false })
  H.eq(mapping(",radio"), nil, "cleanup handles a changed leader key")
  vim.g.mapleader = leader
end
