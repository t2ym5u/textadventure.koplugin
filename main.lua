local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. _dir .. "common/?.lua;" .. package.path

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local PluginBase = require("plugin_base")
local _          = require("i18n")

require("i18n").extend(lrequire("i18n_fr"))

local Screen = lrequire("screen")

local TextAdventure = PluginBase:extend{
    name      = "textadventure",
    menu_text = _("Text Adventures"),
    menu_hint = "tools",
    party_mode = true,
}

function TextAdventure:createScreen()
    return Screen:new{ plugin = self }
end

return TextAdventure
