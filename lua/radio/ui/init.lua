-- UI entry point: engine singleton, browser, status widgets.
local config = require("radio.config")
local log = require("radio.log")

local UI = {}

UI._engine = nil
UI._browser = nil

---Create the engine on first use.
---@param opts table|nil
---@return table|nil engine, string|nil err
function UI.engine(opts)
  if UI._engine then
    return UI._engine
  end
  local Engine = require("radio.engine")
  local engine, err = Engine.new(opts)
  if not engine then
    return nil, err
  end
  UI._engine = engine
  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function()
      if UI._engine then
        UI._engine:shutdown()
        UI._engine = nil
      end
    end,
  })
  return UI._engine
end

---@return table
function UI.browser()
  if not UI._browser then
    UI._browser = require("radio.ui.browser").new(UI.engine())
  end
  return UI._browser
end

function UI.toggle()
  UI.browser():toggle()
end

---@return table
function UI.status()
  return require("radio.ui.status")
end

---@return string
function UI.statusline()
  return UI.status().statusline(UI._engine)
end

function UI.hud()
  UI.status().hud(UI.engine())
end

log.debug("ui module loaded")
return UI
