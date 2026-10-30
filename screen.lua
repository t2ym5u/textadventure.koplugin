local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local Blitbuffer      = require("ffi/blitbuffer")
local ButtonDialog    = require("ui/widget/buttondialog")
local ButtonTable     = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox      = require("ui/widget/confirmbox")
local DataStorage     = require("datastorage")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputDialog     = require("ui/widget/inputdialog")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RenderText      = require("ui/rendertext")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextViewer      = require("ui/widget/textviewer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local lfs             = require("libs/libkoreader-lfs")
local _               = require("i18n")
local T               = require("ffi/util").template

local MenuHelper = require("menu_helper")
local ScreenBase = require("screen_base")

local Guide    = lrequire("stories_guide")
local Library  = lrequire("library")
local ZMachine = lrequire("zmachine")

local DeviceScreen = Device.screen

local FONT_SIZES        = { 16, 18, 20, 22, 24, 26, 28 }
local DEFAULT_FONT_SIZE = 20
local MAX_TRANSCRIPT    = 16000   -- bytes of scrollback kept (and autosaved)
local MAX_HISTORY       = 30

local READ_FACE   = "NotoSerif-Regular.ttf"
local HEADER_FACE = "infont"      -- DroidSansMono: the upper window is a character grid
local STATUS_FACE = "cfont"       -- status bars are drawn as text, not as a grid
local STATUS_SIZE = 18

local RULES_EN = [[
Text Adventures — Help

Interactive fiction: you read a story and decide what the hero does by typing short commands.

Commands
• Move with compass directions: N, S, E, W, NE… and Up, Down, In, Out.
• Look around: LOOK. See what you carry: INVENTORY.
• Act on things: TAKE LAMP, OPEN DOOR, PUT COIN IN SLOT, EXAMINE STATUE, TALK TO GUARD.
• WAIT, AGAIN (repeat the last action), UNDO (take back a turn).
• SAVE and RESTORE: the story asks for a name; saves go to koreader/data/textadventure/saves/.

Screen
• Tap the right side of the text (or swipe up) for the next page, the left side (or swipe down) for the previous one.
• The buttons send the most common commands; "Type a command" opens the keyboard (long-press a letter for accents).
• "Repeat" sends your last typed command again. "History" in the keyboard dialog lists recent ones.
• When the story waits for a single key ("press any key", menus), the buttons become keys.
• The game is saved automatically after every turn: close the reader or let it sleep, you will pick up where you left off.

Getting stories
Put Z-code story files (.z3, .z5, .z8, .zblorb) in koreader/data/textadventure/. Thousands are free:
• IFDB — ifdb.org (search for "zcode")
• IF Archive — ifarchive.org/indexes/if-archive/games/zcode/
• French stories: fiction-interactive.fr and the French section of IFDB.
Most Infocom classics and every Inform 6 game work. Glulx games (.gblorb, .ulx) need another interpreter.
]]

local RULES_FR = [[
Fictions interactives — Aide

Une fiction interactive se lit comme un livre, mais c'est vous qui décidez ce que fait le héros en tapant de courtes commandes.

Commandes
• Se déplacer : N, S, E, O, NE… et Haut, Bas, Entrer, Sortir (dans un jeu anglais : N, S, E, W, U, D).
• Regarder autour de soi : REGARDER. Ce que l'on porte : INVENTAIRE.
• Agir : PRENDRE LAMPE, OUVRIR PORTE, EXAMINER STATUE, PARLER AU GARDE (en anglais : TAKE LAMP, OPEN DOOR…).
• ATTENDRE, ENCORE (refaire la dernière action), ANNULER (revenir d'un tour).
• SAUVER / CHARGER (SAVE / RESTORE) : l'histoire demande un nom ; les sauvegardes vont dans koreader/data/textadventure/saves/.

Écran
• Touchez la droite du texte (ou balayez vers le haut) pour la page suivante, la gauche (ou balayez vers le bas) pour la précédente.
• Les boutons envoient les commandes les plus courantes ; « Taper une commande » ouvre le clavier (appui long sur une lettre pour les accents).
• « Répéter » renvoie votre dernière commande tapée. « Historique », dans la fenêtre du clavier, liste les précédentes.
• Quand l'histoire attend une seule touche (« appuyez sur une touche », menus), les boutons deviennent des touches.
• La partie est sauvegardée automatiquement à chaque tour : fermez ou mettez la liseuse en veille, vous reprendrez où vous en étiez.

Trouver des histoires
Copiez les fichiers d'histoires Z-code (.z3, .z5, .z8, .zblorb) dans koreader/data/textadventure/. Il en existe des milliers, gratuites :
• IFDB — ifdb.org (chercher « zcode »)
• IF Archive — ifarchive.org/indexes/if-archive/games/zcode/
• En français : fiction-interactive.fr et la section française d'IFDB.
Les classiques d'Infocom et tous les jeux Inform 6 fonctionnent. Les jeux Glulx (.gblorb, .ulx) demandent un autre interpréteur.
]]

-- Command words, first one the story's dictionary knows wins. French stories
-- (Inform's French library) get French words.
local COMMANDS = {
    n     = { en = { "n", "north" },     fr = { "n", "nord" } },
    s     = { en = { "s", "south" },     fr = { "s", "sud" } },
    e     = { en = { "e", "east" },      fr = { "e", "est" } },
    w     = { en = { "w", "west" },      fr = { "o", "ouest" } },
    ne    = { en = { "ne", "northeast" }, fr = { "ne", "nordest" } },
    nw    = { en = { "nw", "northwest" }, fr = { "no", "nordouest" } },
    se    = { en = { "se", "southeast" }, fr = { "se", "sudest" } },
    sw    = { en = { "sw", "southwest" }, fr = { "so", "sudouest" } },
    u     = { en = { "u", "up" },        fr = { "haut", "monter", "h" } },
    d     = { en = { "d", "down" },      fr = { "bas", "descendre", "b" } },
    ["in"] = { en = { "in", "enter" },   fr = { "entrer", "dedans" } },
    out   = { en = { "out", "exit" },    fr = { "sortir", "dehors" } },
    look  = { en = { "look", "l" },      fr = { "regarder", "r" } },
    inv   = { en = { "inventory", "i" }, fr = { "inventaire", "i" } },
    wait  = { en = { "wait", "z" },      fr = { "attendre", "z" } },
    again = { en = { "again", "g" },     fr = { "encore", "g" } },
    undo  = { en = { "undo" },           fr = { "annuler", "undo" } },
    save  = { en = { "save" },           fr = { "sauver", "sauvegarder", "save" } },
    restore = { en = { "restore" },      fr = { "charger", "restaurer", "restore" } },
    score = { en = { "score" },          fr = { "score" } },
    help  = { en = { "help", "hint", "about" }, fr = { "aide", "help", "infos" } },
}

local DPI_SCALE = DeviceScreen:scaleBySize(1000) / 1000

local function utf8len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

local function ensureDir(path)
    if lfs.attributes(path, "mode") ~= "directory" then lfs.mkdir(path) end
end

-- A tiny length-prefixed record format for the UI part of an autosave.
local function packFields(t)
    local out = {}
    for k, v in pairs(t) do
        v = tostring(v)
        out[#out + 1] = k .. "\n" .. #v .. "\n" .. v
    end
    return table.concat(out)
end
local function unpackFields(s)
    local t, i = {}, 1
    while s and i <= #s do
        local k, n, j = s:match("^([^\n]*)\n(%d+)\n()", i)
        if not k then break end
        n = tonumber(n)
        t[k] = s:sub(j, j + n - 1)
        i = j + n
    end
    return t
end

-- ---------------------------------------------------------------------------

local TextAdventureScreen = ScreenBase:extend{
    vertical_align = "top",
}

function TextAdventureScreen:init()
    self.font_size = self.plugin:getSetting("font_size", DEFAULT_FONT_SIZE)
    self.lib_page  = 1
    self.mode      = "library"
    self.data_dir  = DataStorage:getDataDir() .. "/textadventure"
    ensureDir(self.data_dir)
    ensureDir(self.data_dir .. "/saves")
    ensureDir(self.data_dir .. "/autosave")
    self:scanLibrary()

    -- Back into the story the reader was in when the game was closed.
    local last = self.plugin:getSetting("last_story")
    if last and self.plugin:getSetting("in_game") and lfs.attributes(last, "mode") == "file" then
        self:openStory(last, true)
    end

    ScreenBase.init(self)

    if Device:hasKeys() then
        self.key_events.PageFwd  = { { Device.input.group.PgFwd } }
        self.key_events.PageBack = { { Device.input.group.PgBack } }
    end
end

-- ---------------------------------------------------------------------------
-- Library
-- ---------------------------------------------------------------------------

function TextAdventureScreen:storyDirs()
    local plugin_dir = (self.plugin and self.plugin.path) or _dir
    plugin_dir = plugin_dir:gsub("/$", "")
    return { self.data_dir, plugin_dir .. "/stories" }
end

function TextAdventureScreen:scanLibrary()
    local cache = self.plugin:getSetting("title_cache", {})
    self.stories = Library.scan(lfs, self:storyDirs(), cache)
    self.plugin:saveSetting("title_cache", cache)
end

function TextAdventureScreen:autosavePath(key)
    return self.data_dir .. "/autosave/" .. key .. ".qzl"
end

function TextAdventureScreen:savesDir(key)
    return self.data_dir .. "/saves/" .. key
end

function TextAdventureScreen:storyInfo(path)
    for _, s in ipairs(self.stories or {}) do
        if s.path == path then return s end
    end
    local name = path:match("([^/]+)$") or path
    return { path = path, name = name, title = Library.titleFromFilename(name), key = Library.storyKey(path) }
end

function TextAdventureScreen:libraryRowsPerPage(avail_h)
    local probe = ButtonTable:new{ width = 100, buttons = { { { text = "Ag" } } } }
    local row_h = probe:getSize().h + Size.padding.small
    return math.max(3, math.floor(avail_h / row_h))
end

function TextAdventureScreen:buildLibrary()
    local sw, sh = self.dimen.w, self.dimen.h
    local g = self:getGutter()
    local title_bar = self:buildTitleBar(_("Text Adventures"), function() return self:libraryMenu() end)
    local w = sw - 2 * g
    local stories = self.stories or {}

    local body
    local over = {}
    if #stories == 0 then
        local face = Font:getFace(READ_FACE, self.font_size)
        local text = _("No stories yet.") .. "\n\n"
            .. T(_("Copy Z-code story files (.z3, .z5, .z8, .zblorb) into:\n%1\nand tap Refresh."), self.data_dir)
            .. "\n\n" .. _("Thousands of free stories are waiting on IFDB (ifdb.org) and the IF Archive (ifarchive.org). French stories too: fiction-interactive.fr.")
            .. "\n\n" .. _("\"Where to find stories\" below lists good ones to start with.")
            .. "\n\n" .. _("Most Infocom classics and every Inform 6 game work. See Help in the menu for how to play.")
        body = CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh - title_bar:getSize().h - 4 * Size.item.height_default },
            TextBoxWidget:new{ text = text, face = face, width = math.floor(w * 0.9), alignment = "center" },
        }
        over = { { text = _("Where to find stories"), callback = function() self:showGuide() end },
                 { text = _("Refresh"), callback = function() self:onRefresh() end } }
    end

    local bar_rows
    local nav_h = 0
    if #stories > 0 then
        bar_rows = { {
            { text = "◀", enabled = self.lib_page > 1, callback = function() self:libraryPage(-1) end },
            { text = _("Refresh"), callback = function() self:onRefresh() end },
            { text = "▶", enabled = false, id = "next", callback = function() self:libraryPage(1) end },
        } }
        local probe = ButtonTable:new{ width = w, buttons = bar_rows }
        nav_h = probe:getSize().h
    end

    if #stories > 0 then
        local avail = sh - title_bar:getSize().h - nav_h - 3 * g - self.status_text:getSize().h
        local per = self:libraryRowsPerPage(avail)
        local pages = math.max(1, math.ceil(#stories / per))
        if self.lib_page > pages then self.lib_page = pages end
        bar_rows[1][3].enabled = self.lib_page < pages
        local rows = {}
        for i = (self.lib_page - 1) * per + 1, math.min(#stories, self.lib_page * per) do
            local s = stories[i]
            local label = s.title
            if lfs.attributes(self:autosavePath(s.key), "mode") == "file" then
                label = self:joinStatus(label, _("in progress"))
            end
            rows[#rows + 1] = { { text = label, align = "left", callback = function() self:openStory(s.path) end } }
        end
        local list = ButtonTable:new{ width = w, buttons = rows, zero_sep = true }
        body = VerticalGroup:new{ align = "center", list }
        self.status_text:setMaxWidth(w)
        self.status_text:setText(T(_("%1 stories"), #stories) .. (pages > 1 and (" · " .. T(_("Page %1/%2"), self.lib_page, pages)) or ""))
    else
        self.status_text:setText("")
    end

    self.action_bar = nil
    local bar
    if bar_rows then
        bar = self:buildActionBar(bar_rows, w)
    else
        bar = ButtonTable:new{ width = w, buttons = { over } }
    end
    local footer = VerticalGroup:new{ align = "center", self.status_text, VerticalSpan:new{ width = Size.padding.default }, bar, VerticalSpan:new{ width = g } }
    local used = title_bar:getSize().h + body:getSize().h + footer:getSize().h + g
    self.layout = VerticalGroup:new{
        align = "center",
        title_bar,
        VerticalSpan:new{ width = g },
        body,
        VerticalSpan:new{ width = math.max(0, sh - used) },
        footer,
    }
    self[1] = self.layout
    self.ges_events = {}
end

function TextAdventureScreen:libraryPage(d)
    self.lib_page = math.max(1, self.lib_page + d)
    self:rebuild()
end

function TextAdventureScreen:onRefresh()
    self:scanLibrary()
    self:rebuild()
end

function TextAdventureScreen:libraryMenu()
    return {
        { text = T(_("Font size: %1"), self.font_size), callback = function() self:pickFontSize() end },
        { text = _("Refresh"), callback = function() self:onRefresh() end },
        { text = _("Where to find stories"), callback = function() self:showGuide() end },
        self:makeRulesButtonConfig(RULES_EN, RULES_FR),
    }
end

-- A text page with our own translated Close button (TextViewer's default
-- buttons rely on KOReader's own catalogue).
function TextAdventureScreen:showText(title, text)
    local viewer
    viewer = TextViewer:new{
        title  = title,
        text   = text,
        width  = math.floor(DeviceScreen:getWidth() * 0.9),
        height = math.floor(DeviceScreen:getHeight() * 0.9),
        buttons_table = { { { text = _("Close"), callback = function() UIManager:close(viewer) end } } },
    }
    UIManager:show(viewer)
end

function TextAdventureScreen:showGuide()
    local lang = _.lang() == "fr" and "fr" or "en"
    self:showText(Guide.title(lang), Guide.text(lang))
end

function TextAdventureScreen:showRules(text)
    self:showText(_("Rules"), text)
end

-- ---------------------------------------------------------------------------
-- Opening a story
-- ---------------------------------------------------------------------------

-- Columns the upper window / status line gets: what fits in the screen's
-- narrower side at a small fixed-pitch font, so rotating never cuts it off.
-- Inform only prints "Score: 36  Moves: 13" (rather than "36/13") from 77
-- columns on, hence the small size; the header font is fitted to it later.
function TextAdventureScreen:headerCols()
    local w = math.min(DeviceScreen:getWidth(), DeviceScreen:getHeight()) - 2 * Size.padding.large
              - 2 * Size.padding.small
    local face = Font:getFace(HEADER_FACE, 11)
    local cw = RenderText:sizeUtf8Text(0, 10000, face, string.rep("0", 20), true, false).x / 20
    return math.max(40, math.min(80, math.floor(w / cw)))
end

function TextAdventureScreen:openStory(path, quiet)
    local info = self:storyInfo(path)
    local data = Library.readFile(path)
    local story, err = nil, "cannot read file"
    if data then story, err = Library.extractStory(data) end
    data = nil -- luacheck: ignore
    if not story then
        if not quiet then
            self:showMessage(err == "not-zcode"
                and T(_("%1 is not a Z-code story (it may be a Glulx game, which needs another interpreter)."), info.name)
                or  T(_("Cannot open %1: %2"), info.name, tostring(err)), 5)
        end
        self.plugin:saveSetting("in_game", false)
        return false
    end
    local vm, verr = ZMachine.new(story, { cols = self:headerCols(), rows = 255 })
    if not vm then
        if not quiet then self:showMessage(T(_("Cannot open %1: %2"), info.name, verr), 5) end
        self.plugin:saveSetting("in_game", false)
        return false
    end
    self.vm = vm
    self.story = info
    self.transcript = ""
    self.turn_start = 0
    self.history = {}
    self.last_cmd = nil
    self.cmd_lang = vm:isFrench() and "fr" or "en"
    self.cmd_cache = {}
    self.mode = "game"
    self.plugin:saveSetting("last_story", path)
    self.plugin:saveSetting("in_game", true)

    local resumed = false
    local auto = Library.readFile(self:autosavePath(info.key))
    if auto then
        local ok, _err, extra = vm:resumeFrom(auto)
        if ok then
            resumed = true
            local f = unpackFields(extra)
            self.transcript = f.transcript or ""
            self.last_cmd = (f.last_cmd ~= "" and f.last_cmd) or nil
            for line in ((f.history or "") .. "\n"):gmatch("(.-)\n") do
                if line ~= "" then self.history[#self.history + 1] = line end
            end
            self.turn_start = #self.transcript
        else
            vm = ZMachine.new(story, { cols = self:headerCols(), rows = 255 })
            self.vm = vm
        end
    end
    self:runVM(function() return vm:run() end, resumed)
    if self.layout then self:rebuild() end
    return true
end

-- ---------------------------------------------------------------------------
-- Running the machine
-- ---------------------------------------------------------------------------

local function tidy(text)
    text = text:gsub("\r", "")
    text = text:gsub("[ \t]+\n", "\n")
    text = text:gsub("\n\n\n+", "\n\n")
    return text
end

-- fn runs the machine (vm:run / sendLine...). Folds its output into the
-- transcript and deals with whatever the machine waits for next.
function TextAdventureScreen:runVM(fn, resumed)
    local vm = self.vm
    local prev = self.transcript or ""
    local cut = prev:match(".*()\n") or 0      -- start of the prompt line
    local state = fn()
    local out = vm:takeOutput()
    if vm.cleared then
        vm.cleared = false
        -- The story cleared the screen: keep the scrollback, but start the
        -- new text on a fresh page.
        if prev ~= "" and not prev:match("\n\n$") then prev = prev .. "\n\n" end
        cut = #prev
    end
    local text = prev .. tidy(out)
    if prev == "" then text = text:gsub("^\n+", "") end
    if state == "error" then
        text = text .. "\n\n" .. T(_("[Story error: %1]"), vm.error_msg or "?") .. "\n"
    end
    if #text > MAX_TRANSCRIPT then
        local drop = #text - MAX_TRANSCRIPT
        local nl = text:find("\n", drop, true) or drop
        cut = math.max(0, cut - nl)
        text = text:sub(nl + 1)
    end
    self.transcript = text
    if not resumed then self.turn_start = cut end

    if state == "save" then
        self:promptSave()
    elseif state == "restore" then
        self:promptRestore()
    elseif state == "input" or state == "char" then
        self:autosave()
    elseif state == "quit" then
        os.remove(self:autosavePath(self.story.key))
        self.plugin:saveSetting("in_game", false)
    end
    return state
end

function TextAdventureScreen:autosave()
    local vm = self.vm
    if not vm or not vm.pending then return end
    local extra = packFields{
        transcript = self.transcript or "",
        last_cmd   = self.last_cmd or "",
        history    = table.concat(self.history or {}, "\n"),
    }
    local data = vm:saveQuetzal(true, extra)
    if data then Library.writeFile(self:autosavePath(self.story.key), data) end
end

function TextAdventureScreen:afterTurn()
    self:rebuild()
end

function TextAdventureScreen:rebuild()
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function TextAdventureScreen:submit(text)
    if not self.vm or self.vm:getState() ~= "input" then return end
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text ~= "" then
        if self.history[#self.history] ~= text then
            self.history[#self.history + 1] = text
            if #self.history > MAX_HISTORY then table.remove(self.history, 1) end
        end
    end
    self:runVM(function() return self.vm:sendLine(text) end)
    self:afterTurn()
end

-- A shortcut button: sends the story-language word for a command.
function TextAdventureScreen:commandWord(id)
    local cached = self.cmd_cache[id]
    if cached then return cached end
    local spec = COMMANDS[id]
    local words = spec[self.cmd_lang] or spec.en
    local pick = words[1]
    for _, w in ipairs(words) do
        if self.vm:lookup(w) ~= 0 then pick = w; break end
    end
    self.cmd_cache[id] = pick
    return pick
end

function TextAdventureScreen:sendCommand(id)
    if not self.vm then return end
    if self.vm:getState() ~= "input" then return end
    self:submit(self:commandWord(id))
end

function TextAdventureScreen:onRepeat()
    if self.last_cmd then
        self:submit(self.last_cmd)
    elseif self.history[#self.history] then
        self:submit(self.history[#self.history])
    end
end

function TextAdventureScreen:sendKey(z)
    if not self.vm or self.vm:getState() ~= "char" then return end
    self:runVM(function() return self.vm:sendChar(z) end)
    self:afterTurn()
end

-- ---------------------------------------------------------------------------
-- Keyboard
-- ---------------------------------------------------------------------------

function TextAdventureScreen:showInput()
    local vm = self.vm
    if not vm then return end
    local st = vm:getState()
    if st ~= "input" and st ~= "char" then return end
    local dlg
    local buttons = {
        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
    }
    if st == "input" then
        buttons[#buttons + 1] = { text = _("History"), enabled = #self.history > 0,
            callback = function() self:showHistory(dlg) end }
    end
    buttons[#buttons + 1] = { text = st == "input" and _("Send") or _("Press key"), is_enter_default = true,
        callback = function()
            local t = dlg:getInputText()
            UIManager:close(dlg)
            if st == "input" then
                self.last_cmd = (t:gsub("^%s+", ""):gsub("%s+$", ""))
                if self.last_cmd == "" then self.last_cmd = nil end
                self:submit(t)
            else
                self:sendKey(t == "" and 13 or vm:keyToZscii(t))
            end
        end }
    dlg = InputDialog:new{
        title      = st == "input" and _("Type a command") or _("Type a key"),
        input      = "",
        input_hint = st == "input" and (self.cmd_lang == "fr" and "prendre la lampe" or "take the lamp") or "",
        buttons    = { buttons },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function TextAdventureScreen:showHistory(input_dlg)
    local dlg
    local rows = {}
    for i = #self.history, math.max(1, #self.history - 14), -1 do
        local cmd = self.history[i]
        rows[#rows + 1] = { { text = cmd, callback = function()
            UIManager:close(dlg)
            input_dlg:setInputText(cmd)
        end } }
    end
    dlg = ButtonDialog:new{ title = _("History"), buttons = rows }
    UIManager:show(dlg)
end

-- ---------------------------------------------------------------------------
-- Save / restore files
-- ---------------------------------------------------------------------------

function TextAdventureScreen:listSaves()
    local dir = self:savesDir(self.story.key)
    local list = {}
    local ok, iter, st = pcall(lfs.dir, dir)
    if ok and iter then
        for name in iter, st do
            if name:match("%.qzl$") then
                local path = dir .. "/" .. name
                list[#list + 1] = { name = name:gsub("%.qzl$", ""), path = path,
                                    time = lfs.attributes(path, "modification") or 0 }
            end
        end
    end
    table.sort(list, function(a, b) return a.time > b.time end)
    return list
end

function TextAdventureScreen:promptSave()
    local vm = self.vm
    local data = vm:saveQuetzal(false)
    local saves = self:listSaves()
    local n = #saves + 1
    local default = T(_("save %1"), n)
    local dlg
    local function finish(ok)
        self:runVM(function() return vm:finishSave(ok) end)
        self:afterTurn()
    end
    dlg = InputDialog:new{
        title   = _("Save the story as"),
        input   = default,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg); finish(false) end },
            { text = _("Save game"), is_enter_default = true, callback = function()
                local name = dlg:getInputText():gsub("[/\\:%*%?\"<>|]", "_"):gsub("^%s+", ""):gsub("%s+$", "")
                if name == "" then name = default end
                UIManager:close(dlg)
                local dir = self:savesDir(self.story.key)
                ensureDir(dir)
                finish(data and Library.writeFile(dir .. "/" .. name .. ".qzl", data) or false)
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function TextAdventureScreen:promptRestore()
    local vm = self.vm
    local function finish(data)
        self:runVM(function()
            local st, err = vm:finishRestore(data)
            if data and err then self:showMessage(T(_("Cannot restore: %1"), err), 4) end
            return st
        end)
        self:afterTurn()
    end
    local saves = self:listSaves()
    if #saves == 0 then
        self:showMessage(_("No saved games for this story yet."), 3)
        finish(nil)
        return
    end
    local dlg
    local rows = {}
    for _, s in ipairs(saves) do
        rows[#rows + 1] = { { text = s.name .. "  ·  " .. os.date("%Y-%m-%d %H:%M", s.time), callback = function()
            UIManager:close(dlg)
            finish(Library.readFile(s.path))
        end } }
    end
    rows[#rows + 1] = { { text = _("Cancel"), callback = function() UIManager:close(dlg); finish(nil) end } }
    dlg = ButtonDialog:new{ title = _("Restore which game?"), buttons = rows }
    UIManager:show(dlg)
end

-- ---------------------------------------------------------------------------
-- Game layout
-- ---------------------------------------------------------------------------

function TextAdventureScreen:isRoundOver()
    if self.mode ~= "game" or not self.vm then return false end
    local st = self.vm:getState()
    return st == "quit" or st == "error"
end

function TextAdventureScreen:getRoundOverButtons()
    return {
        { text = _("New game"), callback = function() self:onNewGame() end },
        { text = _("Library"), callback = function() self:onLibrary() end },
    }
end

-- The upper window (or v3 status line), drawn as a grey band of fixed-pitch
-- text. Returns nil when the story shows none.
function TextAdventureScreen:buildHeader(width)
    local vm = self.vm
    local lines = vm:getUpperLines()
    while #lines > 0 and lines[#lines]:match("^%s*$") do lines[#lines] = nil end
    local status_name, status_right, is_time = vm:getStatusLine()
    if not status_name and #lines == 0 then return nil end

    local pad = Size.padding.small
    local inner = width - 2 * pad
    local group = VerticalGroup:new{ align = "left" }

    -- One status bar: left part, right part. Drawn in a readable font
    -- rather than as the character grid; when both don't fit side by side,
    -- the right part goes on a second line.
    local bar_face = Font:getFace(STATUS_FACE, STATUS_SIZE)
    local function addBar(left, right)
        left, right = left or "", right or ""
        local rw = right ~= "" and TextWidget:new{ text = right, face = bar_face, max_width = inner } or nil
        local gap = Size.padding.large * 2
        local lw_full = TextWidget:new{ text = left ~= "" and left or " ", face = bar_face }
        if not rw or lw_full:getSize().w + gap + rw:getSize().w <= inner then
            lw_full:free()
            local lw = TextWidget:new{ text = left ~= "" and left or " ", face = bar_face,
                                       max_width = rw and (inner - rw:getSize().w - gap) or inner }
            local row = OverlapGroup:new{ dimen = Geom:new{ w = inner, h = lw:getSize().h }, lw }
            if rw then rw.overlap_align = "right"; row[2] = rw end
            group[#group + 1] = row
        else
            lw_full:free()
            group[#group + 1] = TextWidget:new{ text = left, face = bar_face, max_width = inner }
            rw.overlap_align = "right"
            group[#group + 1] = OverlapGroup:new{ dimen = Geom:new{ w = inner, h = rw:getSize().h }, rw }
        end
    end

    if status_name then
        local right
        if is_time then
            right = status_right
        else
            local sc, mv = status_right:match("^(%-?%d+)/(%-?%d+)$")
            right = self:joinStatus(T(_("Score: %1"), sc), T(_("Turns: %1"), mv))
        end
        addBar(status_name, right)
    end

    -- A v5 status line (one or two grid rows) reads as a bar too: its parts
    -- are the runs of text the game spaced apart. Anything taller -- menus,
    -- quote boxes -- is a real layout and keeps the fixed-pitch grid.
    if #lines > 0 and #lines <= 2 then
        for _, line in ipairs(lines) do
            local parts = {}
            for part in (line:gsub("%s%s+", "\1")):gmatch("[^\1]+") do
                part = part:gsub("^%s+", ""):gsub("%s+$", "")
                if part ~= "" then parts[#parts + 1] = part end
            end
            if #parts > 0 then
                addBar(parts[1], table.concat(parts, "   ", 2))
            end
        end
        lines = {}
    end

    if #lines > 0 then
        -- The grid is laid out by column: fit the columns it uses.
        local used = 0
        for _, line in ipairs(lines) do used = math.max(used, utf8len(line)) end
        local size = 16
        local face = Font:getFace(HEADER_FACE, size)
        local function colsFit(f)
            return RenderText:sizeUtf8Text(0, 100000, f, string.rep("0", used), true, false).x <= inner
        end
        while size > 8 and not colsFit(face) do
            size = size - 1
            face = Font:getFace(HEADER_FACE, size)
        end
        local avail = math.floor(self.dimen.h * 0.6)
        local h = 0
        for _, line in ipairs(lines) do
            local tw = TextWidget:new{ text = line == "" and " " or line, face = face, max_width = inner }
            h = h + tw:getSize().h
            if h > avail then break end
            group[#group + 1] = tw
        end
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = pad,
        background = Blitbuffer.COLOR_GRAY_E,
        width = width,
        group,
    }
end

-- Button rows. narrow = the landscape side panel.
function TextAdventureScreen:controlRows(narrow, width)
    local st = self.vm:getState()
    -- page arrows stay narrow so "Type a command" gets the room
    local arrow_w = (not narrow and width) and math.floor(width * 0.13) or nil
    local function cmd(label, id) return { text = label, callback = function() self:sendCommand(id) end } end
    local nav_prev = { text = "◀", width = arrow_w, callback = function() self:onPageBack() end }
    local nav_next = { text = "▶", width = arrow_w, callback = function() self:onPageFwd() end }
    local rows
    if st == "char" then
        local function key(label, z) return { text = label, callback = function() self:sendKey(z) end } end
        local k1 = { key(_("Continue"), 32), key(_("Enter"), 13), { text = _("Key…"), callback = function() self:showInput() end } }
        local k2 = { key("↑", 129), key("↓", 130), key("N", 110), key("P", 112), key("Q", 113) }
        rows = { k1, k2, { nav_prev, { text = _("Escape"), callback = function() self:sendKey(27) end }, nav_next } }
    else
        local dirs = { cmd(_("N"), "n"), cmd(_("S"), "s"), cmd(_("E"), "e"), cmd(_("W"), "w"),
                       cmd(_("Up"), "u"), cmd(_("Down"), "d") }
        local acts = { cmd(_("Look"), "look"), cmd(_("Inventory"), "inv"), cmd(_("Wait"), "wait"),
                       cmd(_("Again"), "again"), { text = _("More…"), callback = function() self:showMore() end } }
        local nav = { nav_prev, { text = _("Type a command"), callback = function() self:showInput() end },
                      { text = _("Repeat"), enabled = (self.last_cmd or self.history[#self.history]) ~= nil,
                        callback = function() self:onRepeat() end },
                      nav_next }
        if narrow then
            rows = { { dirs[1], dirs[2], dirs[3] }, { dirs[4], dirs[5], dirs[6] },
                     { acts[1], acts[2] }, { acts[3], acts[4], acts[5] },
                     { nav[2] }, { nav[1], nav[3], nav[4] } }
        else
            rows = { dirs, acts, nav }
        end
    end
    return rows
end

function TextAdventureScreen:showMore()
    local dlg
    local function cmd(label, id)
        return { text = label, callback = function() UIManager:close(dlg); self:sendCommand(id) end }
    end
    dlg = ButtonDialog:new{
        title = _("More commands"),
        buttons = {
            { cmd(_("NW"), "nw"), cmd(_("N"), "n"), cmd(_("NE"), "ne") },
            { cmd(_("W"), "w"), cmd(_("In"), "in"), cmd(_("E"), "e") },
            { cmd(_("SW"), "sw"), cmd(_("S"), "s"), cmd(_("SE"), "se") },
            { cmd(_("Out"), "out"), cmd(_("Up"), "u"), cmd(_("Down"), "d") },
            { cmd(_("Undo"), "undo"), cmd(_("Score"), "score"), cmd(_("Help"), "help") },
        },
    }
    UIManager:show(dlg)
end

function TextAdventureScreen:buildGame()
    local sw, sh = self.dimen.w, self.dimen.h
    local g = self:getGutter()
    local land = self:isLandscape()
    local title_bar = self:buildTitleBar(self.story.title, function() return self:gameMenu() end)
    local cw = self:getControlsWidth()
    local text_w = land and (sw - cw - 3 * g) or (sw - 2 * g)

    self.status_text:setMaxWidth(cw)
    local bar = self:buildActionBar(self:controlRows(land, cw), cw)
    local controls = VerticalGroup:new{ align = "center",
        self.status_text, VerticalSpan:new{ width = Size.padding.default }, bar }

    local header = self:buildHeader(land and (sw - 2 * g) or text_w)
    local header_h = header and (header:getSize().h + Size.padding.small) or 0
    local tb_h = title_bar:getSize().h
    local text_h
    if land then
        text_h = sh - tb_h - header_h - 2 * g
    else
        -- status line height may change with its text: reserve one line
        text_h = sh - tb_h - header_h - controls:getSize().h - 3 * g - Size.padding.default
    end

    local face = Font:getFace(READ_FACE, self.font_size)
    local tb = TextBoxWidget:new{
        text = self.transcript ~= "" and self.transcript or " ",
        face = face,
        width = text_w,
        height = text_h,
        alignment = "left",
        justified = false,
    }
    self.tb = tb
    self:scrollToTurn()

    local text_col = VerticalGroup:new{ align = "left" }
    if header and not land then
        text_col[#text_col + 1] = header
        text_col[#text_col + 1] = VerticalSpan:new{ width = Size.padding.small }
    end
    text_col[#text_col + 1] = tb

    local x0 = g
    local y0 = tb_h + g + header_h
    if land then
        local panel = CenterContainer:new{ dimen = Geom:new{ w = cw, h = text_h }, controls }
        self.layout = VerticalGroup:new{
            align = "left",
            title_bar,
            VerticalSpan:new{ width = g },
        }
        if header then
            self.layout[#self.layout + 1] = HorizontalGroup:new{ HorizontalSpan:new{ width = g }, header }
            self.layout[#self.layout + 1] = VerticalSpan:new{ width = Size.padding.small }
        end
        self.layout[#self.layout + 1] = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = g },
            text_col, HorizontalSpan:new{ width = g }, panel }
    else
        local used = tb_h + g + header_h + text_h + controls:getSize().h + g
        self.layout = VerticalGroup:new{
            align = "center",
            title_bar,
            VerticalSpan:new{ width = g },
            text_col,
            VerticalSpan:new{ width = math.max(0, sh - used) },
            controls,
            VerticalSpan:new{ width = g },
        }
    end
    self[1] = self.layout
    self.text_rect = Geom:new{ x = x0, y = y0, w = text_w, h = text_h }
    self:updatePageStatus()

    local self_ref = self
    local function range() return self_ref.text_rect end
    self.ges_events = {
        TapText   = { GestureRange:new{ ges = "tap", range = range } },
        SwipeText = { GestureRange:new{ ges = "swipe", range = range } },
    }
end

-- After a turn: show the new text from its start if it is longer than a
-- page (like a "more" prompt), else the end of the transcript.
function TextAdventureScreen:scrollToTurn()
    local tb = self.tb
    local lines = tb.vertical_string_list
    if not lines or #lines == 0 then return end
    local lpp = tb.lines_per_page
    local start_char = utf8len(self.transcript:sub(1, self.turn_start or 0)) + 1
    local ln = 1
    for i = #lines, 1, -1 do
        if lines[i].offset and lines[i].offset <= start_char then ln = i; break end
    end
    if #lines - ln + 1 > lpp then
        tb:scrollLines(ln - tb.virtual_line_num)
    else
        tb:scrollToBottom()
    end
end

function TextAdventureScreen:pageInfo()
    local tb = self.tb
    if not tb or not tb.vertical_string_list then return 1, 1 end
    local n, lpp = #tb.vertical_string_list, math.max(1, tb.lines_per_page)
    local total = math.max(1, math.ceil(n / lpp))
    local cur = math.min(total, math.ceil((tb.virtual_line_num + lpp - 1) / lpp))
    if tb.virtual_line_num + lpp > n then cur = total end
    return cur, total
end

function TextAdventureScreen:updatePageStatus()
    local cur, total = self:pageInfo()
    local st = self.vm:getState()
    local msg
    if st == "char" then msg = _("Press a key")
    elseif st == "quit" then msg = _("The story has ended.")
    elseif st == "error" then msg = _("The story stopped on an error.")
    end
    self:updateStatus(self:joinStatus(msg, T(_("Page %1/%2"), cur, total)))
end

function TextAdventureScreen:scrollPage(dir)
    local tb = self.tb
    if not tb then return end
    local lpp = tb.lines_per_page
    local step = math.max(1, lpp - 1)
    tb:scrollLines(dir * step)
    self:updatePageStatus()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function TextAdventureScreen:onPageFwd() if self.mode == "game" then self:scrollPage(1) end return true end
function TextAdventureScreen:onPageBack() if self.mode == "game" then self:scrollPage(-1) end return true end

function TextAdventureScreen:onTapText(_arg, ges)
    if self.mode ~= "game" then return false end
    local r = self.text_rect
    if ges.pos.x < r.x + r.w / 3 then self:onPageBack() else self:onPageFwd() end
    return true
end

function TextAdventureScreen:onSwipeText(_arg, ges)
    if self.mode ~= "game" then return false end
    local d = ges.direction
    if d == "north" or d == "west" then self:onPageFwd()
    elseif d == "south" or d == "east" then self:onPageBack() end
    return true
end

function TextAdventureScreen:gameMenu()
    local function story(id) return function() self:sendCommand(id) end end
    return {
        { text = _("New game"), callback = function() self:confirmNewGame() end },
        { text = T(_("Font size: %1"), self.font_size), callback = function() self:pickFontSize() end },
        { text = _("Save game"), callback = story("save") },
        { text = _("Restore game"), callback = story("restore") },
        { text = _("Undo"), callback = story("undo") },
        { text = _("Library"), callback = function() self:onLibrary() end },
        self:makeRulesButtonConfig(RULES_EN, RULES_FR),
    }
end

function TextAdventureScreen:confirmNewGame()
    UIManager:show(ConfirmBox:new{
        text = T(_("Start %1 again from the beginning?\nThe automatic save will be lost (your own saves are kept)."), self.story.title),
        ok_text = _("New game"),
        cancel_text = _("Cancel"),
        ok_callback = function() self:onNewGame() end,
    })
end

function TextAdventureScreen:onNewGame()
    if not self.vm then return end
    os.remove(self:autosavePath(self.story.key))
    self.vm:restart()
    self.transcript = ""
    self.turn_start = 0
    self.last_cmd = nil
    self.plugin:saveSetting("in_game", true)
    self:runVM(function() return self.vm:run() end)
    self:rebuild()
end

function TextAdventureScreen:onLibrary()
    self:autosave()
    self.vm = nil
    self.tb = nil
    self.mode = "library"
    self.plugin:saveSetting("in_game", false)
    collectgarbage()
    self:scanLibrary()
    self:rebuild()
end

function TextAdventureScreen:pickFontSize()
    local items = {}
    for _, s in ipairs(FONT_SIZES) do items[#items + 1] = { id = s, text = tostring(s) } end
    MenuHelper.openPickerMenu{
        title = _("Font size"),
        items = items,
        current_id = self.font_size,
        on_select = function(id)
            self.font_size = id
            self.plugin:saveSetting("font_size", id)
            self:rebuild()
        end,
    }
end

function TextAdventureScreen:buildLayout()
    if self.mode == "game" and self.vm then
        self:buildGame()
    else
        self.mode = "library"
        self:buildLibrary()
    end
end

function TextAdventureScreen:onSuspend()
    if self.mode == "game" then self:autosave() end
end

function TextAdventureScreen:closeScreen()
    if self.mode == "game" and self.vm then
        self:autosave()
        local st = self.vm:getState()
        self.plugin:saveSetting("in_game", st == "input" or st == "char")
    else
        self.plugin:saveSetting("in_game", false)
    end
    ScreenBase.closeScreen(self)
end

return TextAdventureScreen
