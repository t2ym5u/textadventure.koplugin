-- Library helpers: Blorb parsing, titles, save keys.
package.path = "./?.lua;" .. package.path
local Library = require("library")

local function be32(v)
    return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256,
                       math.floor(v / 256) % 256, v % 256)
end
local function chunk(id, data)
    return id .. be32(#data) .. data .. ((#data % 2 == 1) and "\0" or "")
end
local function blorb(...)
    local body = "IFRS" .. table.concat({ ... })
    return "FORM" .. be32(#body) .. body
end

local fake_story = string.char(5) .. string.rep("\0", 127)

describe("Blorb files", function()
    it("extracts the ZCOD chunk and the iFiction title", function()
        local md = "<ifindex><story><bibliographic><title>L&apos;&#201;t&#233; &amp; moi</title>"
                 .. "<author>Anne</author></bibliographic></story></ifindex>"
        local data = blorb(chunk("RIdx", be32(0)), chunk("Pict", "xyz"), chunk("ZCOD", fake_story), chunk("IFmd", md))
        local story, err, info = Library.extractStory(data)
        assert.is_nil(err)
        assert.equal(fake_story, story)
        assert.equal("L'Été & moi", info.title)
        assert.equal("Anne", info.author)
    end)

    it("refuses a Blorb holding a Glulx game", function()
        local story, err = Library.extractStory(blorb(chunk("GLUL", "Glul....")))
        assert.is_nil(story)
        assert.equal("not-zcode", err)
    end)

    it("passes plain story files through and rejects junk", function()
        assert.equal(fake_story, (Library.extractStory(fake_story)))
        assert.is_nil((Library.extractStory("hello")))
    end)
end)

describe("names", function()
    it("makes titles from file names", function()
        assert.equal("Advent", Library.titleFromFilename("Advent.z5"))
        assert.equal("The lurking horror", Library.titleFromFilename("the_lurking_horror.z3"))
    end)
    it("makes file-system-safe save keys", function()
        assert.equal("Le_butin_du_Capitaine", Library.storyKey("/x/y/Le butin du Capitaine.zblorb"))
        assert.equal("Advent", Library.storyKey("/data/Advent.z5"))
    end)
end)

describe("scanning", function()
    it("lists stories from several folders, sorted, telling same titles apart", function()
        local files = {
            ["/a"] = { "Advent.z5", "notes.txt", "zork1.z3" },
            ["/b"] = { "advent.z3", ".hidden.z5" },
        }
        local lfs = {
            dir = function(d)
                local i, list = 0, files[d] or {}
                return function() i = i + 1; return list[i] end
            end,
            attributes = function() return { mode = "file", size = 10 } end,
        }
        local list = Library.scan(lfs, { "/a", "/b", "/missing" }, {})
        local titles = {}
        for _, s in ipairs(list) do titles[#titles + 1] = s.title end
        assert.same({ "Advent (z3)", "Advent (z5)", "Zork1" }, titles)
    end)
end)
