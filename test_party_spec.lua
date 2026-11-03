local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

local Turns = require("turns")

describe("text adventure multiplayer: the Commander", function()
    it("passes round the table after every command", function()
        local t = Turns.new(3)
        local seen = {}
        for _ = 1, 6 do seen[#seen + 1] = t.current; Turns.step(t) end
        assert.are.same({ 1, 2, 3, 1, 2, 3 }, seen)
    end)

    it("every 3 commands, and by hand", function()
        local t = Turns.new(2, 3)
        Turns.step(t); Turns.step(t)
        assert.are.equal(1, t.current)
        assert.are.equal(1, Turns.left(t))
        Turns.pass(t)                             -- "Next commander"
        assert.are.equal(2, t.current)
        assert.are.equal(3, Turns.left(t))
    end)

    it("survives a save, a change of players and a broken save", function()
        local t = Turns.new(4, 2); Turns.pass(t); Turns.pass(t); Turns.step(t)
        local r = Turns.restore(Turns.copy(t), 4, 2)
        assert.are.equal(3, r.current); assert.are.equal(1, r.count)
        Turns.resize(r, 2)
        assert.are.equal(1, r.current)
        assert.are.equal(0, Turns.restore({ count = 9 }, 2, 2).count)
        assert.are.same(Turns.new(3, 1), Turns.restore(nil, 3, 1))
    end)
end)
