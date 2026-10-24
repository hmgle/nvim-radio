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

  H.eq(vim.tbl_count(engine.listeners), 0, "closing browser unsubscribes")
  local renders = 0
  local original_header = browser._render_header
  browser._render_header = function(self)
    renders = renders + 1
    original_header(self)
  end
  for _ = 1, 3 do
    browser:open()
    H.eq(vim.tbl_count(engine.listeners), 1, "one subscription while browser is open")
    browser:close()
  end
  browser:open()
  engine:emit()
  H.wait_for(1000, function()
    return renders > 0
  end, "open browser receives events")
  H.eq(renders, 1, "reopening does not multiply redraws")
  vim.api.nvim_win_close(browser.win, true)
  H.eq(vim.tbl_count(engine.listeners), 0, "manual window close unsubscribes")
  local received = 0
  local unsubscribe = engine:subscribe(function()
    received = received + 1
  end)
  engine:emit()
  unsubscribe()
  vim.wait(20, function()
    return false
  end)
  H.eq(received, 0, "unsubscribe suppresses queued events")

  engine:shutdown()
  local reopened = assert(ui.engine({ auto_sync = false }))
  local fresh_browser = assert(ui.browser())
  H.check(fresh_browser ~= browser, "engine replacement creates a fresh browser")
  H.eq(fresh_browser.engine, reopened, "fresh browser uses the current engine")
  H.eq(fresh_browser.source, "stations", "resume=false does not restore the previous source")
  fresh_browser:open()
  H.check(#fresh_browser.items > 0, "recreated browser queries the new store")
  fresh_browser:close()
  reopened:shutdown()
  radio.setup({ data_dir = dir, resume = "selection", auto_sync_days = 0 })
  local selected = assert(ui.engine({ auto_sync = false }))
  H.eq(ui.browser().source, "favorites", "selection resume restores the saved source")
  selected:shutdown()

  -- First-run bootstrap must populate an already-open empty browser.
  local Directory = require("radio.directory")
  local original_bootstrap = Directory.bootstrap
  local bootstrap
  Directory.bootstrap = function(self, store, cb)
    bootstrap = function()
      store:bootstrap({
        model.station({
          stationuuid = "ffffffff-ffff-4fff-8fff-ffffffffffff",
          name = "Bootstrap",
          url = "https://example.test/live",
          active = true,
        }),
      })
      cb(nil, 1)
    end
  end
  radio.setup({ data_dir = H.tmpdir("ui-bootstrap"), auto_sync_days = 0 })
  local initial = assert(ui.engine())
  local empty = assert(ui.browser())
  empty:open()
  H.eq(#empty.items, 0, "browser opens before bootstrap response")
  bootstrap()
  H.wait_for(1000, function()
    return #empty.items == 1
  end, "bootstrap updates the open result list")
  empty:close()
  initial:shutdown()
  Directory.bootstrap = original_bootstrap
end
