-- Floating-window station browser: sources, search, filters, playback,
-- favorites, and recordings. Keyboard driven, zero external dependencies.
local config = require("radio.config")
local log = require("radio.log")
local model = require("radio.model")
local util = require("radio.util")

local Browser = {}
Browser.__index = Browser

local SOURCES = { "stations", "favorites", "history", "custom", "recordings" }

---@param width number
---@param height number
---@return integer buf, integer win
local function create_float(width, height, opts)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = opts.row or 0,
    col = opts.col or 0,
    width = width,
    height = height,
    style = "minimal",
    border = opts.border or "rounded",
    title = opts.title,
    title_pos = "center",
    zindex = 50,
  })
  vim.wo[win].cursorline = true
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "nvim-radio"
  vim.bo[bufnr].swapfile = false
  return bufnr, win
end

---@return table
function Browser.new(engine)
  local ui = config.options.ui
  -- resume="selection" restores the source the user last browsed.
  local source = "stations"
  if engine.resume_source and vim.tbl_contains(SOURCES, engine.resume_source) then
    source = engine.resume_source
  end
  return setmetatable({
    engine = engine,
    source = source,
    filter = model.filter({}),
    items = {},
    total = 0,

    preview = ui.preview,
  }, Browser)
end

---Keep both panes inside the editor, stacking details on narrow screens.
function Browser:_resize()
  local ui = config.options.ui
  local width = math.max(1, math.min(vim.o.columns - 2, math.floor(vim.o.columns * ui.width)))
  local height = math.max(1, math.min(vim.o.lines - 3, math.floor(vim.o.lines * ui.height)))
  local row = math.max(0, math.floor((vim.o.lines - height - 2) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width - 2) / 2))
  self.width, self.height = width, height
  self.preview_geometry = nil
  if self.preview and width >= 90 then
    local details = math.min(60, math.floor(width * 0.4))
    self.width = width - details - 2
    self.preview_geometry =
      { row = row, col = col + self.width + 2, width = details, height = height }
  elseif self.preview and height >= 10 and width >= 12 then
    local details = math.max(3, math.floor(height * 0.45))
    self.height = height - details - 2
    self.preview_geometry =
      { row = row + self.height + 2, col = col, width = width, height = details }
  end
  self.row, self.col = row, col
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_set_config(
      self.win,
      { relative = "editor", row = row, col = col, width = self.width, height = self.height }
    )
    self:_render_preview()
  end
end

function Browser:open()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_set_current_win(self.win)
    self:refresh()
    return
  end
  self:_resize()
  self.buf, self.win = create_float(self.width, self.height, {
    border = config.options.ui.border,
    title = config.options.ui.title,
    row = self.row,
    col = self.col,
  })
  vim.api.nvim_win_set_buf(self.win, self.buf)
  self:_set_keymaps()
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(self.win),
    once = true,
    callback = function()
      self:_unsubscribe()
      if self.resize_autocmd then
        vim.api.nvim_del_autocmd(self.resize_autocmd)
        self.resize_autocmd = nil
      end
      self.win = nil
      self.buf = nil
      if self.preview_win and vim.api.nvim_win_is_valid(self.preview_win) then
        vim.api.nvim_win_close(self.preview_win, true)
        self.preview_win = nil
      end
    end,
  })
  self.resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
    callback = function()
      self:_resize()
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = self.buf,
    callback = function()
      self:_render_preview()
    end,
  })
  self.catalog_revision = self.engine.catalog_revision
  self.recordings_revision = self.engine.recordings_revision
  self.unsubscribe = self.engine:subscribe(function()
    if self.engine.stopping then
      self:close()
    elseif self.buf and vim.api.nvim_buf_is_valid(self.buf) then
      local catalog_changed = self.catalog_revision ~= self.engine.catalog_revision
      local recordings_changed = self.recordings_revision ~= self.engine.recordings_revision
      self.catalog_revision = self.engine.catalog_revision
      self.recordings_revision = self.engine.recordings_revision
      if catalog_changed or (recordings_changed and self.source == "recordings") then
        self:refresh()
      else
        self:_render_header()
      end
    end
  end)
  self:refresh()
end

---Rewrite only the header line (engine status changes arrive frequently).
function Browser:_render_header()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, 1, false, { self:_header() })
  vim.bo[self.buf].modifiable = false
end

function Browser:_unsubscribe()
  if self.unsubscribe then
    self.unsubscribe()
    self.unsubscribe = nil
  end
end

function Browser:close()
  self:_unsubscribe()
  if self.preview_win and vim.api.nvim_win_is_valid(self.preview_win) then
    vim.api.nvim_win_close(self.preview_win, true)
    self.preview_win = nil
  end
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  self.win = nil
  self.buf = nil
end

function Browser:toggle()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    self:close()
  else
    self:open()
  end
end

function Browser:_set_keymaps()
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, function()
      local ok, err = pcall(rhs)
      if not ok then
        log.error(tostring(err))
      end
    end, { buffer = self.buf, nowait = true, desc = desc })
  end
  map("<CR>", function()
    self:play_current()
  end, "Play selection")
  map("o", function()
    self:play_current()
  end, "Play selection")
  map("<2-LeftMouse>", function()
    local row = vim.fn.line(".")
    self:move_to(row)
    self:play_current()
  end, "Play selection")
  map("i", function()
    self:prompt_search()
  end, "Search")
  map("/", function()
    self:prompt_search()
  end, "Search")
  map("F", function()
    self:prompt_filters()
  end, "Filters")
  map("s", function()
    self:cycle_sort()
  end, "Cycle sort")
  map("n", function()
    self:random()
  end, "Random station")
  map("f", function()
    self:toggle_favorite()
  end, "Toggle favorite")
  map("r", function()
    self.engine:toggle_recording()
    self:refresh()
  end, "Toggle recording")
  map("R", function()
    self:sync()
  end, "Sync catalog")
  map("<F5>", function()
    self:refresh()
  end, "Refresh list")
  map("y", function()
    self:yank("uuid")
  end, "Yank UUID")
  map("Y", function()
    self:yank("url")
  end, "Yank URL")
  map("d", function()
    self:delete_recording()
  end, "Delete recording")
  map("O", function()
    self:open_recordings()
  end, "Open recordings directory")
  map("[", function()
    self:cycle_source(-1)
  end, "Previous source")
  map("]", function()
    self:cycle_source(1)
  end, "Next source")
  map("L", function()
    self:page(1)
  end, "Next page")
  map("H", function()
    self:page(-1)
  end, "Previous page")
  map("<PageDown>", function()
    self:page(1)
  end, "Next page")
  map("<PageUp>", function()
    self:page(-1)
  end, "Previous page")
  map("q", function()
    self:close()
  end, "Close")
  map("<Esc>", function()
    self:close()
  end, "Close")
end

---Query the store for the current source and redraw.
function Browser:refresh()
  -- HTTP and libuv callbacks arrive in fast-event contexts where the Neovim
  -- API is unavailable; defer to the main loop.
  if vim.in_fast_event() then
    vim.schedule(function()
      self:refresh()
    end)
    return
  end
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  if self.engine.stopping or not self.engine.store then
    self:close()
    return
  end
  self.catalog_revision = self.engine.catalog_revision
  self.recordings_revision = self.engine.recordings_revision
  local selected = self:current_item()
  local selected_id = selected
    and (selected.kind == "station" and selected.station.stationuuid or selected.record.id)
  local filter = self.filter
  if self.source == "recordings" then
    self.items = {}
    for _, record in ipairs(self.engine.store:recordings_page(filter.limit, filter.offset)) do
      self.items[#self.items + 1] = { kind = "recording", record = record }
    end
    self.total = self.engine.store:recordings_count()
  else
    if self.source == "favorites" then
      filter.favorites = true
      filter.history = false
      filter.custom = false
    elseif self.source == "history" then
      filter.favorites = false
      filter.history = true
      filter.custom = false
    elseif self.source == "custom" then
      filter.favorites = false
      filter.history = false
      filter.custom = true
    else
      filter.favorites = false
      filter.history = false
      filter.custom = false
    end
    local stations, total = self.engine.store:search(filter)
    self.items = {}
    for _, station in ipairs(stations) do
      self.items[#self.items + 1] = { kind = "station", station = station }
    end
    self.total = total
  end
  local last = math.floor(math.max(0, self.total - 1) / filter.limit) * filter.limit
  if filter.offset > last then
    filter.offset = last
    return self:refresh()
  end
  self:render(selected_id)
end

---@return string
function Browser:_header()
  local parts = { "[" .. self.source .. "]" }
  local first = self.filter.offset + 1
  local last = self.filter.offset + #self.items
  if #self.items == 0 then
    parts[#parts + 1] = string.format("0/%d", self.total)
  else
    parts[#parts + 1] = string.format("%d-%d/%d", first, last, self.total)
  end
  if self.filter.query ~= "" then
    parts[#parts + 1] = 'query="' .. self.filter.query .. '"'
  end
  if self.filter.country then
    parts[#parts + 1] = "country=" .. self.filter.country
  end
  if self.filter.language then
    parts[#parts + 1] = "language=" .. self.filter.language
  end
  if self.filter.tag then
    parts[#parts + 1] = "tag=" .. self.filter.tag
  end
  if self.filter.min_bitrate > 0 then
    parts[#parts + 1] = "min=" .. self.filter.min_bitrate .. "k"
  end
  parts[#parts + 1] = "sort=" .. self.filter.sort
  local status = self.engine.status
  local state = status.playback_state
  if status.recording_state == "recording" or status.recording_state == "probing" then
    state = state .. " ●REC " .. util.fmt_duration(status.recording_ms)
  end
  parts[#parts + 1] = state
  return util.display_line(table.concat(parts, "  ·  "))
end

---@return string[]
function Browser:_lines()
  local lines = { self:_header() }
  if #self.items == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  (empty) press i to search, R to sync, ] to switch source"
    return lines
  end
  for index, item in ipairs(self.items) do
    if item.kind == "recording" then
      local r = item.record
      lines[#lines + 1] = string.format(
        "%3d. %-28s %-22s %-11s %8s %s",
        index,
        util.truncate(util.trim(util.display_line(r.station_name)), 28),
        util.truncate(util.trim(util.display_line(r.track)), 22),
        r.status,
        util.fmt_bytes(r.size_bytes),
        (tostring(r.started_at or "")):gsub("T", " "):sub(1, 19)
      )
    else
      local s = item.station
      lines[#lines + 1] = string.format(
        "%3d. %-34s %-5s %6s %-9s %s",
        index,
        util.truncate(util.trim(util.display_line(s.name)), 34),
        (tostring(s.countrycode or "")):upper():sub(1, 5),
        s.bitrate > 0 and (s.bitrate .. "k") or "?",
        (tostring(s.codec or "")):sub(1, 9),
        s.favorite and "★" or ""
      )
    end
    lines[#lines] = util.display_line(lines[#lines])
  end
  return lines
end

function Browser:render(selected_id)
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local row = vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_cursor(self.win)[1] or 2
  if selected_id then
    for i, item in ipairs(self.items) do
      if (item.kind == "station" and item.station.stationuuid or item.record.id) == selected_id then
        row = i + 1
        break
      end
    end
  end
  local lines = self:_lines()
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  if vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_set_cursor(
      self.win,
      { math.max(math.min(2, #lines), math.min(row, #lines)), 0 }
    )
  end
  self:_render_preview()
end

---@param row integer
function Browser:move_to(row)
  if not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local line = util.clamp(row, 2, math.max(2, #self.items + 1))
  vim.api.nvim_win_set_cursor(self.win, { line, 0 })
end

---@return table|nil item
function Browser:current_item()
  if not vim.api.nvim_win_is_valid(self.win) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(self.win)[1]
  return self.items[row - 1]
end

function Browser:play_current()
  local item = self:current_item()
  if not item then
    return
  end
  if item.kind == "recording" then
    self.engine:play_recording(item.record.id)
  else
    self.engine:play(item.station.stationuuid)
  end
  self:render()
end

function Browser:toggle_favorite()
  local item = self:current_item()
  if not item or item.kind ~= "station" then
    return
  end
  local added = self.engine.store:toggle_favorite(item.station.stationuuid)
  vim.notify(
    "[radio] " .. (added and "added to" or "removed from") .. " favorites: " .. item.station.name
  )
  self:refresh()
end

---@param field string "uuid" | "url"
function Browser:yank(field)
  local item = self:current_item()
  if not item then
    return
  end
  local value
  if item.kind == "recording" then
    value = field == "url" and item.record.path or item.record.id
  else
    value = field == "url" and model.Station.primary_url(item.station) or item.station.stationuuid
  end
  vim.fn.setreg(vim.v.register, value)
  vim.notify("[radio] yanked " .. field .. ": " .. value)
end

function Browser:prompt_search()
  vim.ui.input({ prompt = "Search stations: ", default = self.filter.query }, function(query)
    if query == nil then
      return
    end
    self.filter.query = util.trim(query)
    self.filter.offset = 0
    self:refresh()
  end)
end

function Browser:cycle_sort()
  local index = 1
  for i, sort in ipairs(model.SORT) do
    if sort == self.filter.sort then
      index = i
      break
    end
  end
  self.filter.sort = model.SORT[(index % #model.SORT) + 1]
  self.filter.offset = 0
  self:refresh()
end

---@param delta integer
function Browser:cycle_source(delta)
  local index = 1
  for i, source in ipairs(SOURCES) do
    if source == self.source then
      index = i
      break
    end
  end
  self.source = SOURCES[((index + delta - 1) % #SOURCES) + 1]
  self.filter.offset = 0
  self.engine.store:set_meta("pref_source", self.source)
  self:refresh()
end

---Move through the result set one page at a time.
---@param delta integer
function Browser:page(delta)
  local step = self.filter.limit
  local last_page = math.floor(math.max(0, self.total - 1) / step) * step
  local offset = util.clamp(self.filter.offset + delta * step, 0, last_page)
  if offset ~= self.filter.offset then
    self.filter.offset = offset
    self:refresh()
  end
end

function Browser:random()
  self.engine:random(self.filter)
  self:refresh()
end

function Browser:sync()
  self.engine:sync({}, function()
    self:refresh()
  end)
  self:refresh()
end

function Browser:prompt_filters()
  local options = {
    "country: " .. (self.filter.country or "*"),
    "language: " .. (self.filter.language or "*"),
    "tag: " .. (self.filter.tag or "*"),
    "min bitrate: " .. self.filter.min_bitrate .. " kbps",
    "clear filters",
  }
  vim.ui.select(options, { prompt = "Filter by", kind = "filter" }, function(choice)
    if not choice then
      return
    end
    if choice:find("^country") then
      self:_facet_filter(0, function(value)
        self.filter.country = value
      end)
    elseif choice:find("^language") then
      self:_facet_filter(1, function(value)
        self.filter.language = value
      end)
    elseif choice:find("^tag") then
      self:_facet_filter(2, function(value)
        self.filter.tag = value
      end)
    elseif choice:find("^min bitrate") then
      vim.ui.input(
        { prompt = "Minimum bitrate (kbps): ", default = tostring(self.filter.min_bitrate) },
        function(value)
          if value then
            self.filter.min_bitrate = math.max(0, tonumber(value) or 0)
            self.filter.offset = 0
            self:refresh()
          end
        end
      )
    else
      self.filter.country = nil
      self.filter.language = nil
      self.filter.tag = nil
      self.filter.min_bitrate = 0
      self.filter.query = ""
      self.filter.offset = 0
      self:refresh()
    end
  end)
end

---@param kind integer 0=country 1=language 2=tag
---@param apply fun(value: string|nil)
function Browser:_facet_filter(kind, apply, prefix, offset)
  prefix, offset = prefix or "", offset or 0
  local page_size = 200
  local facets = self.engine.store:facets(kind, prefix, page_size + 1, offset)
  local options, values = { "* (any)" }, {}
  for i = 1, math.min(page_size, #facets) do
    local facet = facets[i]
    local label = util.display_line(facet.value) .. "  (" .. facet.count .. ")"
    options[#options + 1] = label
    values[#options] = facet.value
  end
  options[#options + 1] = "Search values..."
  local search_index = #options
  local previous_index, next_index
  if offset > 0 then
    options[#options + 1] = "Previous page"
    previous_index = #options
  end
  if #facets > page_size then
    options[#options + 1] = "Next page"
    next_index = #options
  end
  local prompt = prefix ~= "" and ("Value (prefix: " .. util.display_line(prefix) .. ")") or "Value"
  vim.ui.select(options, { prompt = prompt }, function(choice, index)
    if not choice then
      return
    end
    if index == search_index then
      vim.ui.input({ prompt = "Value prefix (empty for all): ", default = prefix }, function(query)
        if query ~= nil then
          query = util.trim(query)
          query = kind == 0 and query:upper() or util.lower(query)
          self:_facet_filter(kind, apply, query, 0)
        end
      end)
      return
    elseif index == previous_index then
      self:_facet_filter(kind, apply, prefix, math.max(0, offset - page_size))
      return
    elseif index == next_index then
      self:_facet_filter(kind, apply, prefix, offset + page_size)
      return
    end
    apply(values[index])
    self.filter.offset = 0
    self:refresh()
  end)
end

function Browser:delete_recording()
  local item = self:current_item()
  if not item or item.kind ~= "recording" then
    vim.notify("[radio] select a recording first", vim.log.levels.WARN)
    return
  end
  local record = item.record
  vim.ui.select({ "Delete files and index", "Delete index only", "Cancel" }, {
    prompt = "Delete recording " .. record.id .. "?",
  }, function(choice)
    if not choice or choice == "Cancel" then
      return
    end
    local index_only = choice:find("index only") ~= nil
    local ok, err = pcall(self.engine.remove_recording, self.engine, record.id, index_only)
    if not ok then
      log.error(tostring(err))
      return
    end
    vim.notify("[radio] recording removed: " .. record.id)
    self:refresh()
  end)
end

function Browser:open_recordings()
  return require("radio").open_recordings()
end

---Render the details pane for the current selection.
function Browser:_render_preview()
  if not self.preview then
    return
  end
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local item = self:current_item()
  local lines = {}
  if item and item.kind == "station" then
    local s = item.station
    lines = {
      s.name,
      "",
      "country:  " .. (s.country ~= "" and tostring(s.country) or tostring(s.countrycode or "")),
      "language: "
        .. (s.language ~= "" and tostring(s.language) or tostring(s.languagecodes or "")),
      "tags:     " .. tostring(s.tags or ""),
      "bitrate:  " .. (s.bitrate > 0 and (s.bitrate .. " kbps") or "unknown"),
      "codec:    " .. (s.codec ~= "" and tostring(s.codec) or "unknown"),
      "votes:    " .. tostring(s.votes),
      "clicks:   " .. tostring(s.clickcount),
      "",
      "url:      " .. model.Station.primary_url(s),
      "homepage: " .. tostring(s.homepage or ""),
      "",
      "uuid:     " .. s.stationuuid,
      "custom:   " .. tostring(s.custom),
      "favorite: " .. tostring(s.favorite),
    }
  elseif item and item.kind == "recording" then
    local r = item.record
    lines = {
      tostring(r.station_name),
      tostring(r.track or ""),
      "",
      "status:   " .. r.status,
      "codec:    " .. tostring(r.codec) .. " / " .. tostring(r.container),
      "size:     " .. util.fmt_bytes(r.size_bytes),
      "duration: " .. util.fmt_duration(r.media_duration_ms or 0),
      "started:  " .. tostring(r.started_at),
      "stopped:  " .. tostring(r.stopped_at),
      "reconnects: " .. tostring(r.reconnects),
      r.error and ("error: " .. r.error) or "",
      "",
      "path:     " .. r.path,
      "source:   " .. r.source_url_resolved,
    }
  end
  if #lines == 0 then
    if self.preview_win and vim.api.nvim_win_is_valid(self.preview_win) then
      vim.api.nvim_win_close(self.preview_win, true)
      self.preview_win = nil
    end
    return
  end
  lines = util.display_lines(lines)
  local geometry = self.preview_geometry
  if not geometry then
    if self.preview_win and vim.api.nvim_win_is_valid(self.preview_win) then
      vim.api.nvim_win_close(self.preview_win, true)
      self.preview_win = nil
    end
    return
  end
  if self.preview_win and vim.api.nvim_win_is_valid(self.preview_win) then
    if self.preview_buf and vim.api.nvim_buf_is_valid(self.preview_buf) then
      vim.api.nvim_buf_set_lines(self.preview_buf, 0, -1, false, lines)
      vim.api.nvim_win_set_config(
        self.preview_win,
        vim.tbl_extend("force", geometry, { relative = "editor" })
      )
      return
    end
    vim.api.nvim_win_close(self.preview_win, true)
    self.preview_win = nil
    self.preview_buf = nil
  end
  self.preview_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(self.preview_buf, 0, -1, false, lines)
  self.preview_win = vim.api.nvim_open_win(self.preview_buf, false, {
    relative = "editor",
    row = geometry.row,
    col = geometry.col,
    width = geometry.width,
    height = geometry.height,
    style = "minimal",
    border = config.options.ui.border,
    title = " details ",
    title_pos = "center",
    zindex = 51,
  })
  vim.bo[self.preview_buf].bufhidden = "wipe"
  vim.bo[self.preview_buf].filetype = "nvim-radio"
end

log.debug("browser module loaded")
return Browser
