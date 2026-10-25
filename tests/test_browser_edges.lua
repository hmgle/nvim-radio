local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  local model = require("radio.model")
  config.setup({ data_dir = H.tmpdir("browser-edges"), auto_sync_days = 0 })
  local engine = assert(require("radio.engine").new({ auto_sync = false }))
  local first
  for i = 1, 30 do
    local station = model.station({
      stationuuid = string.format("%08x-4242-4242-8242-424242424242", i),
      name = string.format("Station %02d", i),
      url = "https://example.test/" .. i,
      active = true,
      tags = "classic rock",
    })
    engine.store:upsert(station)
    first = first or station
  end
  local browser = require("radio.ui.browser").new(engine)
  browser.filter.limit = 10
  browser:open()
  local cols, lines = vim.o.columns, vim.o.lines
  for _, size in ipairs({ { 80, 24 }, { 40, 16 }, { 140, 40 }, { 12, 8 } }) do
    vim.o.columns, vim.o.lines = size[1], size[2]
    vim.api.nvim_exec_autocmds("VimResized", {})
    for _, win in ipairs({ browser.win, browser.preview_win }) do
      local c = vim.api.nvim_win_get_config(win)
      H.check(c.col + c.width + 2 <= size[1], "pane fits terminal width " .. size[1])
      H.check(c.row + c.height + 2 <= size[2], "pane fits terminal height " .. size[2])
    end
    if browser.preview_win then
      local main = vim.api.nvim_win_get_config(browser.win)
      local detail = vim.api.nvim_win_get_config(browser.preview_win)
      H.check(
        detail.col >= main.col + main.width + 2 or detail.row >= main.row + main.height + 2,
        "details do not obscure the station list"
      )
      H.check(detail.zindex > main.zindex, "details have a visible stacking order")
    end
  end
  vim.o.columns, vim.o.lines = cols, lines
  vim.api.nvim_exec_autocmds("VimResized", {})
  browser:move_to(6)
  local selected = browser:current_item().station.stationuuid
  browser:toggle_favorite()
  H.eq(browser:current_item().station.stationuuid, selected, "favorite refresh preserves selection")
  H.eq(vim.api.nvim_win_get_cursor(browser.win)[1], 6, "refresh preserves cursor row")
  local select = vim.ui.select
  local applied
  vim.ui.select = function(options, _, cb)
    cb(options[2], 2)
  end
  browser:_facet_filter(2, function(value)
    applied = value
  end)
  vim.ui.select = select
  H.eq(applied, "classic rock", "facet selection retains spaces")
  engine.store:set_favorite(selected, false)
  browser:page(2)
  H.eq(browser.filter.offset, 20, "last page selected before sync")
  engine.store:begin_sync()
  engine.store:stage({ first })
  engine.store:finish_sync()
  browser:refresh()
  H.eq(browser.filter.offset, 0, "sync shrink clamps page offset")
  H.eq(#browser.items, 1, "sync shrink displays remaining station")
  local status = require("radio.ui.status")
  local _, old = status.hud(engine)
  local _, current = status.hud(engine)
  H.eq(vim.api.nvim_win_is_valid(old), false, "opening HUD replaces old window")
  vim.api.nvim_win_close(current, true)
  H.eq(status.win, nil, "manual HUD close clears singleton")
  browser:close()
  engine:shutdown()
end
