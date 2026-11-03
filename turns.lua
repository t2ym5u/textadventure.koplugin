-- ---------------------------------------------------------------------------
-- turns.lua — whose turn it is in a "· multiplayer" game (pure Lua, no UI).
--
-- The players sit around one reader; one of them has the turn (reads the
-- section aloud, types the command...). The turn passes to the next seat
-- after every `every` steps (sections read, commands sent), or by hand.
-- A plain table, safe to save.
-- ---------------------------------------------------------------------------

local Turns = {}

Turns.EVERY_CHOICES = { 1, 2, 3, 5 }

-- n players, the turn passing every `every` steps (default 1).
function Turns.new(n, every)
    return { n = n, current = 1, every = every or 1, count = 0 }
end

-- One step done; true when that passed the turn to the next player.
function Turns.step(t)
    t.count = t.count + 1
    if t.count >= t.every then
        Turns.pass(t)
        return true
    end
    return false
end

-- Hands the turn to the next seat now.
function Turns.pass(t)
    t.count = 0
    t.current = t.current % t.n + 1
end

-- Steps left before the turn passes.
function Turns.left(t)
    return t.every - t.count
end

-- The number of players changed: keep the turn when that seat still exists.
function Turns.resize(t, n)
    t.n = n
    if t.current > n then t.current = 1 end
end

function Turns.setEvery(t, every)
    t.every = every
    if t.count >= every then t.count = 0 end
end

-- Validates a saved table for n players; a fresh one when unusable.
function Turns.restore(saved, n, every)
    local t = Turns.new(n, every)
    if type(saved) == "table" then
        local cur, count = tonumber(saved.current), tonumber(saved.count)
        if cur and cur >= 1 and cur <= n then t.current = math.floor(cur) end
        if count and count >= 0 and count < t.every then t.count = math.floor(count) end
    end
    return t
end

function Turns.copy(t)
    return { n = t.n, current = t.current, every = t.every, count = t.count }
end

return Turns
