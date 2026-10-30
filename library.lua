-- ---------------------------------------------------------------------------
-- library.lua -- finding story files and reading them
--
-- Stories are looked for in <KOReader data>/textadventure/ (created on first
-- run) and in the plugin's own stories/ folder. Plain Z-code files (.z3 .z4
-- .z5 .z7 .z8) are loaded as they are; Blorb files (.zblorb .zlb .blb) are
-- opened to take their ZCOD chunk -- pictures and sounds are skipped -- and
-- their iFiction metadata, when present, gives the title.
-- No UI here; lfs is passed in so the parsing is testable without KOReader.
-- ---------------------------------------------------------------------------

local Library = {}

local STORY_EXT = { z3 = true, z4 = true, z5 = true, z7 = true, z8 = true,
                    zblorb = true, zlb = true, blb = true, blorb = true }
local PLAIN_EXT = { z3 = true, z4 = true, z5 = true, z7 = true, z8 = true }
Library.STORY_EXT = STORY_EXT

local function rd32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function unescapeXml(s)
    s = s:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'")
    s = s:gsub("&#(%d+);", function(n)
        n = tonumber(n)
        if n and n < 128 then return string.char(n) end
        return require("zmachine").utf8char(n or 63)
    end)
    return (s:gsub("&amp;", "&"))
end

-- Walk the chunks of a Blorb file. Returns a table: zcode (string or nil),
-- title (string or nil), exec (the executable chunk id: "ZCOD", "GLUL"...).
function Library.parseBlorb(data)
    if #data < 12 or data:sub(1, 4) ~= "FORM" or data:sub(9, 12) ~= "IFRS" then
        return nil, "not a Blorb file"
    end
    local info = {}
    local i, total = 13, math.min(#data, rd32(data, 5) + 8)
    while i + 7 <= total do
        local id, len = data:sub(i, i + 3), rd32(data, i + 4)
        if id == "ZCOD" then
            info.zcode = data:sub(i + 8, i + 7 + len)
            info.exec = id
        elseif id == "GLUL" or id == "TAD2" or id == "TAD3" or id == "HUGO" or id == "ADRI" then
            info.exec = info.exec or id
        elseif id == "IFmd" then
            local xml = data:sub(i + 8, i + 7 + len)
            local t = xml:match("<title>(.-)</title>")
            if t then info.title = unescapeXml(t):gsub("^%s+", ""):gsub("%s+$", "") end
            local a = xml:match("<author>(.-)</author>")
            if a then info.author = unescapeXml(a):gsub("^%s+", ""):gsub("%s+$", "") end
        end
        i = i + 8 + len + (len % 2)
    end
    return info
end

-- Story bytes from a file's contents. Returns story or nil, reason
-- ("glulx" for a Blorb holding another kind of game).
function Library.extractStory(data)
    if data:sub(1, 4) == "FORM" then
        local info, err = Library.parseBlorb(data)
        if not info then return nil, err end
        if not info.zcode then return nil, info.exec and "not-zcode" or "no story in this Blorb file" end
        return info.zcode, nil, info
    end
    local v = data:byte(1)
    if not v or v < 1 or v > 8 or #data < 64 then return nil, "not a Z-code story" end
    return data
end

function Library.readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

function Library.writeFile(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

-- "the_lurking_horror.z3" -> "The lurking horror"; "Advent.z5" -> "Advent".
function Library.titleFromFilename(name)
    local base = name:gsub("%.[^%.]+$", "")
    base = base:gsub("[_]+", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if base == "" then return name end
    return base:sub(1, 1):upper() .. base:sub(2)
end

-- A stable key for a story's saves: the file name without extension, safe
-- for any file system.
function Library.storyKey(path)
    local name = path:match("([^/\\]+)$") or path
    name = name:gsub("%.[^%.]+$", "")
    name = name:gsub("[^%w%-_]", "_")
    if name == "" then name = "story" end
    return name
end

function Library.extension(name)
    local ext = name:match("%.([^%.]+)$")
    return ext and ext:lower() or ""
end

-- List stories in dirs (list of paths). title_cache: { [path..size] = title }
-- filled in for Blorb files, whose title needs reading the file.
function Library.scan(lfs, dirs, title_cache)
    local list, seen = {}, {}
    for _, dir in ipairs(dirs) do
        local ok, iter, state = pcall(lfs.dir, dir)
        if ok and iter then
            for name in iter, state do
                local ext = Library.extension(name)
                if name:sub(1, 1) ~= "." and STORY_EXT[ext] then
                    local path = dir .. "/" .. name
                    local attr = lfs.attributes(path)
                    if attr and attr.mode == "file" and not seen[name:lower()] then
                        seen[name:lower()] = true
                        local title = Library.titleFromFilename(name)
                        if not PLAIN_EXT[ext] then
                            local ck = path .. "#" .. tostring(attr.size)
                            local cached = title_cache and title_cache[ck]
                            if cached == nil then
                                cached = false
                                local data = Library.readFile(path)
                                if data then
                                    local info = Library.parseBlorb(data)
                                    if info and info.title then cached = info.title end
                                end
                                if title_cache then title_cache[ck] = cached end
                            end
                            if cached then title = cached end
                        end
                        list[#list + 1] = { path = path, name = name, title = title,
                                            key = Library.storyKey(path), size = attr.size }
                    end
                end
            end
        end
    end
    -- Two files with the same title (Advent.z5, advent.z3): tell them apart.
    local count = {}
    for _, s in ipairs(list) do count[s.title:lower()] = (count[s.title:lower()] or 0) + 1 end
    for _, s in ipairs(list) do
        if count[s.title:lower()] > 1 then s.title = s.title .. " (" .. Library.extension(s.name) .. ")" end
    end
    table.sort(list, function(a, b) return a.title:lower() < b.title:lower() end)
    return list
end

return Library
