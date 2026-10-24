-- UI tests: browser float rendering, status widgets, and public API.
local H = require("tests.helpers")

return function()
  local config = require("radio.config")
  local radio = require("radio")
  local ui = require("radio.ui")
  local model = require("radio.model")

  local dir = H.tmpdir("ui")
  radio.setup({ data_dir = dir, auto_sync_days = 0 })

  local engine = assert(ui.engine({ auto_sync = false }))
  engine.store:save_custom(model.station({
    stationuuid = "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
    name = "UI Station",
    url = "https://example.com/ui",
    url_resolved = "https://example.com/ui",
    custom = true,
    active = true,
    bitrate = 192,
  }))
  engine.store:save_custom(model.station({
    stationuuid = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
    name = "第二 台",
    url = "https://example.com/ui2",
    custom = true,
    active = true,
    bitrate = 64,
    tags = "news",
  }))

  -- Public API surface.
  H.eq(radio.stations({ custom = true })[1] ~= nil, true, "stations API")
  H.eq(#radio.recordings(), 0, "recordings API")
  H.eq(radio.statusline():find("radio", 1, true), 1, "statusline prefix")
  H.check(type(radio.doctor()) == "table", "doctor API")

  -- Browser renders in a float.
  local browser = ui.browser()
  browser:open()
  H.wait_for(2000, function()
    return browser.buf ~= nil
      and vim.api.nvim_buf_is_valid(browser.buf)
      and #vim.api.nvim_buf_get_lines(browser.buf, 0, -1, false) > 2
  end, "browser buffer populated")
  local lines = vim.api.nvim_buf_get_lines(browser.buf, 0, -1, false)
  H.check(lines[1]:find("%[stations%]"), "header shows the source")
  H.check(table.concat(lines, "\n"):find("UI Station"), "station listed")
  browser:cycle_source(1)
  H.wait_for(1000, function()
    return browser.source ~= "stations"
  end, "source switches")
  H.eq(browser.source, "favorites", "next source is favorites")
  browser:cycle_source(1)
  browser:cycle_source(1)
  H.eq(browser.source, "custom", "custom source reached")
  H.check(
    table.concat(vim.api.nvim_buf_get_lines(browser.buf, 0, -1, false), "\n"):find("第二"),
    "custom station listed"
  )

  -- Search filters the list.
  browser.source = "stations"
  browser.filter.query = "第二"
  browser:refresh()
  H.eq(#browser.items, 1, "search narrows to one station")
  browser.filter.query = ""
  browser:refresh()

  -- Sort cycling.
  local first_sort = browser.filter.sort
  browser:cycle_sort()
  H.check(browser.filter.sort ~= first_sort, "sort cycles")

  -- Pagination moves through the result set and clamps at the ends.
  for i = 1, 130 do
    engine.store:upsert(model.station({
      stationuuid = string.format("%08d-1111-4111-8111-%012d", i, i),
      name = "台 " .. i,
      url = "https://example.com/" .. i,
      countrycode = "fr",
      language = "french",
      tags = "jazz",
      bitrate = 128,
      clickcount = i,
      active = true,
    }))
  end
  browser.source = "stations"
  browser.filter.query = ""
  browser.filter.offset = 0
  browser:refresh()
  local function header()
    return vim.api.nvim_buf_get_lines(browser.buf, 0, 1, false)[1]
  end
  local total = browser.total
  H.check(total > 100, "more than one page of results")
  local last_start = math.floor((total - 1) / 100) * 100 + 1
  H.check(header():find("1-100/" .. total, 1, true), "first page range")
  browser:page(1)
  H.check(header():find(last_start .. "-" .. total .. "/" .. total, 1, true), "last page range")
  browser:page(1)
  H.check(
    header():find(last_start .. "-" .. total .. "/" .. total, 1, true),
    "paging clamps at the last page"
  )
  browser:page(-1)
  browser:page(-1)
  H.check(header():find("1-100/" .. total, 1, true), "paging returns to the first page")

  -- Engine status updates rewrite the header (fast-event safe).
  engine.status.playback_state = "playing"
  engine.status.station = model.station({ name = "Live 台" })
  engine:emit()
  H.wait_for(2000, function()
    return header():find("playing") ~= nil
  end, "header follows engine status")

  -- Source selection is persisted for resume="selection".
  browser:cycle_source(1)
  H.eq(engine.store:meta("pref_source"), browser.source, "source preference persisted")

  -- Status HUD opens.
  local hud_buf = require("radio.ui.status").hud(engine)
  H.check(hud_buf ~= nil and vim.api.nvim_buf_is_valid(hud_buf), "hud buffer created")

  browser:close()
  H.eq(browser.win, nil, "browser closed")

  engine:shutdown()
end
