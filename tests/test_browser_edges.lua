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

  local tags = {}
  for i = 1, 205 do
    tags[i] = string.format("tag%03d", i)
  end
  local many = model.station({
    stationuuid = "11111111-2222-4333-8444-555555555555",
    name = "Many tags",
    tags = table.concat(tags, ","),
    active = true,
  })
  engine.store:upsert(many)
  local round = 0
  vim.ui.select = function(options, _, cb)
    round = round + 1
    local target = round == 1 and "Next page" or "tag205  (1)"
    local index = vim.fn.index(options, target) + 1
    H.check(index > 0, "facet page offers " .. target)
    if index > 0 then
      cb(options[index], index)
    end
  end
  browser:_facet_filter(2, function(value)
    applied = value
  end)
  H.eq(applied, "tag205", "facets beyond the first 200 can be selected")
  local input = vim.ui.input
  vim.ui.input = function(_, cb)
    cb("TAG205")
  end
  round = 0
  vim.ui.select = function(options, _, cb)
    round = round + 1
    local target = round == 1 and "Search values..." or "tag205  (1)"
    local index = vim.fn.index(options, target) + 1
    H.check(index > 0, "facet search offers " .. target)
    if index > 0 then
      cb(options[index], index)
    end
  end
  browser:_facet_filter(2, function(value)
    applied = value
  end)
  H.eq(applied, "tag205", "facet search normalizes the value prefix")
  vim.ui.input, vim.ui.select = input, select
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

  -- Text can contain newlines both in directory data and recorder errors.
  browser.items = {
    {
      kind = "station",
      station = model.station({
        name = "First line\nSecond line",
        country = "Somewhere\r\nElsewhere",
        tags = "one\ntwo",
        codec = "mp3\ncodec",
      }),
    },
  }
  browser.filter.query = "query\ncontinuation"
  H.check(pcall(browser.render, browser), "multiline station and query render")
  local rendered = vim.api.nvim_buf_get_lines(browser.buf, 0, -1, false)
  H.eq(#rendered, 2, "multiline list fields still occupy one row")
  H.check(
    rendered[2] and rendered[2]:find("First line Second line", 1, true),
    "list replaces newlines with spaces"
  )
  H.check(pcall(browser._render_header, browser), "incremental header rendering handles newlines")
  if browser.preview_buf then
    local details = vim.api.nvim_buf_get_lines(browser.preview_buf, 0, -1, false)
    H.check(vim.tbl_contains(details, "Second line"), "station details preserve separate lines")
  end
  local fixture = vim.json.decode(
    table.concat(vim.fn.readfile(H.root .. "/tests/fixtures/radio-cli-recordings.json"), "\n")
  )[1]
  browser.items = { { kind = "recording", record = model.recording(fixture) } }
  H.check(pcall(browser.render, browser), "normal CLI recording renders in details")
  browser.items[1].record.error = "first failure\r\nsecond failure\nthird failure"
  browser.items[1].record.track = "Artist\nTitle"
  H.check(pcall(browser.render, browser), "multiline recording error renders in details")
  if browser.preview_buf then
    local details = vim.api.nvim_buf_get_lines(browser.preview_buf, 0, -1, false)
    H.check(vim.tbl_contains(details, "second failure"), "recording error keeps its second line")
    H.check(vim.tbl_contains(details, "third failure"), "recording error keeps its third line")
  end
  -- Directory mirrors are external data; malformed scalar types cannot crash
  -- rendering and asynchronous preview refresh cannot steal focus.
  browser.preview = true
  browser.preview_geometry = { row = 0, col = 90, width = 20, height = 5 }
  browser.items = {
    {
      kind = "station",
      station = model.station({
        stationuuid = "11111111-1111-4111-8111-111111111111",
        name = "Typed Fixture",
        url = "https://example.test/live",
        active = true,
        countrycode = 42,
        country = true,
        languagecodes = false,
        codec = true,
      }),
    },
  }
  H.check(pcall(browser.render, browser), "non-string fields render in list and details")
  H.check(browser.preview_buf ~= nil, "forced details geometry creates preview")
  local user_window
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    if window ~= browser.win and window ~= browser.preview_win then
      user_window = window
      break
    end
  end
  vim.api.nvim_set_current_win(user_window)
  browser:_render_preview()
  H.eq(vim.api.nvim_get_current_win(), user_window, "preview refresh preserves focus")

  -- The update path above is not the only risk: recreating the float after it
  -- was closed also ran from asynchronous callbacks and moved focus too.
  vim.api.nvim_win_set_cursor(browser.win, { 1, 0 })
  browser:_render_preview()
  H.check(browser.preview_win == nil, "header cursor closes the details pane")
  vim.api.nvim_set_current_win(user_window)
  browser:render()
  H.check(
    browser.preview_win ~= nil and vim.api.nvim_win_is_valid(browser.preview_win),
    "refresh recreates the details pane"
  )
  H.eq(vim.api.nvim_get_current_win(), user_window, "recreating the details pane preserves focus")

  -- Replacing the details buffer must not leave a stale buffer/window pair.
  local stale_preview = browser.preview_buf
  vim.api.nvim_set_current_win(browser.preview_win)
  vim.cmd("enew")
  vim.api.nvim_set_current_win(user_window)
  if vim.api.nvim_buf_is_valid(stale_preview) then
    vim.api.nvim_buf_delete(stale_preview, { force = true })
  end
  H.check(pcall(browser._render_preview, browser), "stale details buffer is recreated")
  H.check(
    browser.preview_buf ~= stale_preview and vim.api.nvim_buf_is_valid(browser.preview_buf),
    "details buffer replacement updates the pair"
  )

  engine.status.station = model.station({ name = "Station\nName" })
  engine.status.title = "Artist\r\nTitle"
  engine.status.message = "first failure\nsecond failure"
  local hud_ok, hud_buf, hud_win = pcall(status.hud, engine)
  H.check(hud_ok, "multiline status opens HUD")
  if hud_ok then
    local hud_lines = vim.api.nvim_buf_get_lines(hud_buf, 0, -1, false)
    H.check(vim.tbl_contains(hud_lines, "second failure"), "HUD preserves multiline errors")
    vim.api.nvim_win_close(hud_win, true)
  end
  engine.status.playback_state = "playing"
  H.eq(status.statusline(engine):find("[\r\n]"), nil, "statusline renders a single line")
  browser:close()
  engine:shutdown()
end
