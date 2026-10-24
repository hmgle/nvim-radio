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
  if UI._engine and not UI._engine.store then
    -- A previous engine in this process was shut down; start a fresh one.
    if UI._browser then
      UI._browser:close()
      UI._browser = nil
    end
    UI._engine = nil
  end
  if UI._engine and UI._engine.stopping then
    return nil, "media_busy: the previous session is still shutting down"
  end
  if UI._engine then
    return UI._engine
  end
  require("radio.config").ensure()
  local Engine = require("radio.engine")
  local engine, err = Engine.new(opts)
  if not engine then
    return nil, err
  end
  UI._engine = engine
  if not UI._leave_hook then
    UI._leave_hook = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        if UI._browser then
          UI._browser:close()
          UI._browser = nil
        end
        if UI._engine then
          UI._engine:shutdown()
        end
      end,
    })
  end
  return UI._engine
end

---@return table
function UI.browser()
  local engine, err = UI.engine()
  if not engine then
    return nil, err
  end
  if not UI._browser then
    UI._browser = require("radio.ui.browser").new(engine)
  end
  return UI._browser
end

function UI.toggle()
  local browser, err = UI.browser()
  if browser then
    browser:toggle()
  else
    log.error(err)
  end
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
