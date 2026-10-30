-- Opcode-level tests on tiny hand-assembled story images.
-- Run: LUA_PATH="<bitshim>/?.lua;;" busted test_zmachine_spec.lua
package.path = "./?.lua;" .. package.path
local ZMachine = require("zmachine")

-- ---------------------------------------------------------------------------
-- A minimal assembler
-- ---------------------------------------------------------------------------

local GLOBALS, OBJECTS, ABBREVS, DICT, STRINGS, CODE = 0x40, 0x300, 0x700, 0x800, 0xA00, 0x1000
local SIZE = 0x2000

local Image = {}
Image.__index = Image

local function newImage(version, size)
    size = size or SIZE
    local img = setmetatable({ v = version, b = {}, pc = CODE, size = size }, Image)
    for i = 0, size - 1 do img.b[i] = 0 end
    img.b[0] = version
    img:w(0x04, CODE)          -- high memory
    img:w(0x06, CODE)          -- initial pc
    img:w(0x08, DICT)
    img:w(0x0A, OBJECTS)
    img:w(0x0C, GLOBALS)
    img:w(0x0E, DICT)          -- static memory starts with the dictionary
    img:w(0x18, ABBREVS)
    img:w(0x1A, size / (version <= 3 and 2 or (version <= 5 and 4 or 8)))
    img:w(0x02, 7)             -- release
    for i = 0, 5 do img.b[0x12 + i] = 48 + i end
    return img
end

function Image:w(a, v) v = v % 65536; self.b[a] = math.floor(v / 256); self.b[a + 1] = v % 256 end
function Image:emit(...) for _, x in ipairs({ ... }) do self.b[self.pc] = x; self.pc = self.pc + 1 end end
-- forward branch (2-byte form) / jump, patched once the target is known
function Image:brFwd(on_true) local p = self.pc; self:br14(on_true, 0); self.b[p] = self.b[p] % 128 + (on_true and 128 or 0); return p end
function Image:patchBr(p, target)
    local flag = self.b[p] >= 128 and 128 or 0
    local off = (target - p) % 16384
    self.b[p] = flag + math.floor(off / 256); self.b[p + 1] = off % 256
end
function Image:jumpFwd() local p = self.pc; self:emit(0x8C, 0, 0); return p end
function Image:patchJump(p, target) self:w(p + 1, target - p - 1) end
function Image:global(n) return 16 + n end      -- variable number of global n

-- operand helpers
local function L(v) return { 0, v % 65536 } end    -- large constant
local function S(v) return { 1, v } end            -- small constant
local function V(v) return { 2, v } end            -- variable

-- VAR-form instruction: opbyte = 0xC0+n for 2OP, 0xE0+n for VAR.
function Image:var(opbyte, ...)
    local operands = { ... }
    local types = 0
    for k = 1, 4 do
        local o = operands[k]
        types = types * 4 + (o and o[1] or 3)
    end
    self:emit(opbyte, types)
    for _, o in ipairs(operands) do
        if o[1] == 0 then self:emit(math.floor(o[2] / 256), o[2] % 256) else self:emit(o[2]) end
    end
end
function Image:op1(n, o)
    self:emit(0x80 + o[1] * 16 + n)
    if o[1] == 0 then self:emit(math.floor(o[2] / 256), o[2] % 256) else self:emit(o[2]) end
end
function Image:op0(n) self:emit(0xB0 + n) end
-- branch byte(s): single-byte form, offset 0 = rfalse, 1 = rtrue
function Image:br(on_true, off) self:emit((on_true and 0x80 or 0) + 0x40 + off) end
function Image:br14(on_true, off)
    off = off % 16384
    self:emit((on_true and 0x80 or 0) + math.floor(off / 256), off % 256)
end

-- A routine header at the current pc (aligned); returns its packed address.
function Image:routine(nlocals, inits)
    local mult = self.v <= 3 and 2 or (self.v <= 5 and 4 or 8)
    while self.pc % mult ~= 0 do self.pc = self.pc + 1 end
    local p = self.pc / mult
    self:emit(nlocals)
    if self.v <= 4 then
        for i = 1, nlocals do
            local v = inits and inits[i] or 0
            self:emit(math.floor(v / 256), v % 256)
        end
    end
    return p
end

-- Z-string encoder (default alphabets)
local A2 = "\0\n0123456789.,!?_#'\"/\\-:()"
local function zchars(text)
    local z = {}
    for i = 1, #text do
        local c = text:sub(i, i)
        local b = c:byte()
        if c == " " then z[#z + 1] = 0
        elseif b >= 97 and b <= 122 then z[#z + 1] = b - 97 + 6
        elseif b >= 65 and b <= 90 then z[#z + 1] = 4; z[#z + 1] = b - 65 + 6
        else
            local k = A2:find(c, 3, true)
            if k then z[#z + 1] = 5; z[#z + 1] = k + 5
            else z[#z + 1] = 5; z[#z + 1] = 6; z[#z + 1] = math.floor(b / 32); z[#z + 1] = b % 32 end
        end
    end
    return z
end
local function packZ(z)
    while #z % 3 ~= 0 or #z == 0 do z[#z + 1] = 5 end
    local out = {}
    for i = 1, #z, 3 do
        local w = z[i] * 1024 + z[i + 1] * 32 + z[i + 2]
        if i + 2 == #z then w = w + 32768 end
        out[#out + 1] = math.floor(w / 256); out[#out + 1] = w % 256
    end
    return out
end
local unpack_ = table.unpack or unpack
function Image:zstring(text) self:emit(unpack_(packZ(zchars(text)))) end
function Image:putBytes(a, bytes) for i, x in ipairs(bytes) do self.b[a + i - 1] = x end end

function Image:build()
    local t = {}
    for i = 0, self.size - 1 do t[#t + 1] = string.char(self.b[i]) end
    return table.concat(t)
end

local function boot(img, opts)
    local vm = assert(ZMachine.new(img:build(), opts or { cols = 40, seed = 1 }))
    return vm
end
local function g(vm, n) return vm.rw(GLOBALS + 2 * n) end
local function sg(vm, n) local v = g(vm, n); return v >= 32768 and v - 65536 or v end

-- ---------------------------------------------------------------------------

describe("arithmetic", function()
    it("handles signs in add/sub/mul/div/mod", function()
        local img = newImage(5)
        local G = function(n) return img:global(n) end
        img:var(0xC0 + 20, L(-5), S(3)); img:emit(G(0))          -- add -5 3 -> -2
        img:var(0xC0 + 21, S(3), L(10)); img:emit(G(1))          -- sub 3 10 -> -7
        img:var(0xC0 + 22, L(-7), L(-6)); img:emit(G(2))         -- mul -> 42
        img:var(0xC0 + 23, L(-7), S(2)); img:emit(G(3))          -- div -7 2 -> -3
        img:var(0xC0 + 24, L(-7), S(2)); img:emit(G(4))          -- mod -7 2 -> -1
        img:var(0xC0 + 24, S(7), L(-2)); img:emit(G(5))          -- mod 7 -2 -> 1
        img:var(0xC0 + 23, L(-32768), L(-1)); img:emit(G(6))     -- overflow wraps
        img:var(0xC0 + 20, L(32767), S(1)); img:emit(G(7))       -- 32767+1 -> -32768
        -- extended form: 0xBE, opcode, types (large, large), operands, store
        img:emit(0xBE, 0x02, 0x0F, 0xF0, 0x00, 0xFF, 0xFE, G(8)) -- log_shift 0xF000 -2 -> 0x3C00
        img:emit(0xBE, 0x03, 0x0F, 0xF0, 0x00, 0xFF, 0xFE, G(9)) -- art_shift 0xF000 -2 -> 0xFC00
        img:emit(0xBE, 0x02, 0x1F, 0x00, 0x81, 0x04, G(10))      -- log_shift 0x81 4 -> 0x810
        img:op0(10)                                              -- quit
        local vm = boot(img)
        assert.equal("quit", vm:run())
        assert.equal(-2, sg(vm, 0))
        assert.equal(-7, sg(vm, 1))
        assert.equal(42, sg(vm, 2))
        assert.equal(-3, sg(vm, 3))
        assert.equal(-1, sg(vm, 4))
        assert.equal(1, sg(vm, 5))
        assert.equal(-32768, sg(vm, 6))
        assert.equal(-32768, sg(vm, 7))
        assert.equal(0x3C00, g(vm, 8))
        assert.equal(0xFC00, g(vm, 9))
        assert.equal(0x810, g(vm, 10))
    end)

    it("reports division by zero as an error, not a crash", function()
        local img = newImage(5)
        img:var(0xC0 + 23, S(1), S(0)); img:emit(img:global(0))
        img:op0(10)
        local vm = boot(img)
        assert.equal("error", vm:run())
        assert.truthy(vm.error_msg:find("division"))
    end)

    it("prints signed numbers", function()
        local img = newImage(5)
        img:var(0xE6, L(-32768)); img:var(0xE5, S(32)); img:var(0xE6, L(1234))
        img:op0(10)
        local vm = boot(img)
        vm:run()
        assert.equal("-32768 1234", vm:takeOutput())
    end)
end)

describe("version 8", function()
    -- The headline of "Le butin du Capitaine Verdeterre" printed as garbage;
    -- the story's own banner code does print_paddr on a *routine* (calling
    -- that address prints the real headline), so every interpreter shows the
    -- same thing. This pins the v8 side of it: packed addresses scale by 8
    -- and reach past 64 KB, for strings and routines alike.
    it("unpacks string and routine addresses by 8, beyond 64 KB", function()
        local img = newImage(8, 0x24000)
        local here = img.pc
        img.pc = 0x20000
        img:zstring("Far away")                              -- packed 0x4000
        img.pc = 0x20100
        local r = img:routine(1)                             -- packed 0x4020
        assert.equal(0x4020, r)
        img:var(0xC0 + 20, V(1), S(70)); img:emit(0)         -- push L1 + 70
        img:op0(8)                                           -- ret_popped
        img.pc = here
        img:op1(13, L(0x4000))                               -- print_paddr
        img:var(0xE0, L(r), S(7)); img:emit(img:global(0))   -- call_vs -> 77
        img:op0(10)
        local vm = boot(img)
        assert.equal("quit", vm:run())
        assert.equal("Far away", vm:takeOutput())
        assert.equal(77, g(vm, 0))
    end)
end)

describe("branches", function()
    it("follows je/jl/jg/jz/test with true and false senses", function()
        local img = newImage(5)
        local results = {}
        -- each test: call a routine that branches ?rtrue, else rfalse; store in global n
        local function test(n, emitter)
            local here = img.pc
            img.pc = 0x1400 + n * 0x20
            local r = img:routine(0)
            emitter()
            img:op0(1) -- rfalse
            img.pc = here
            img:var(0xE0, L(r)); img:emit(img:global(n))
            results[#results + 1] = n
        end
        test(0, function() img:var(0xC1, S(3), S(5), S(3)); img:br(true, 1) end)      -- je 3 in {5,3}: true
        test(1, function() img:var(0xC1, S(3), S(5), S(4)); img:br(true, 1) end)      -- false
        test(2, function() img:var(0xC2, L(-1), S(0)); img:br(true, 1) end)           -- jl -1 0: true
        test(3, function() img:var(0xC3, L(-1), S(0)); img:br(true, 1) end)           -- jg -1 0: false
        test(4, function() img:var(0xC2, L(-1), S(0)); img:br(false, 1) end)          -- jl, branch on false: no
        test(5, function() img:op1(0, S(0)); img:br(true, 1) end)                     -- jz 0
        test(6, function() img:var(0xC7, S(0x0F), S(0x05)); img:br(true, 1) end)      -- test 0F 05
        test(7, function() img:var(0xC7, S(0x0A), S(0x05)); img:br(true, 1) end)      -- test 0A 05: false
        img:op0(10)
        local vm = boot(img)
        assert.equal("quit", vm:run())
        local want = { 1, 0, 1, 0, 0, 1, 1, 0 }
        for i, n in ipairs(results) do assert.equal(want[i], g(vm, n), "test " .. n) end
    end)

    it("loops with a negative 14-bit offset (dec_chk) and jumps", function()
        local img = newImage(5)
        local G0, G1 = img:global(0), img:global(1)
        img:var(0xCD, S(G0), S(10))                        -- store g0 10
        local loop = img.pc
        img:op1(5, S(G1))                                  -- inc g1
        img:var(0xC4, S(G0), S(1))                         -- dec_chk g0 1 ?~loop  (branch if not < 1)
        local off = loop - (img.pc + 2) + 2
        img:br14(false, off)
        img:op1(12, L(6))                                  -- jump over the 4-byte store below
        img:var(0xCD, S(G1), S(99))
        img:op0(10)
        local vm = boot(img)
        assert.equal("quit", vm:run())
        assert.equal(0, g(vm, 0))
        assert.equal(10, g(vm, 1))
    end)
end)

describe("calls", function()
    it("passes arguments, initialises v3 locals and returns values", function()
        local img = newImage(3)
        local here = img.pc
        img.pc = 0x1200
        -- routine(a, b, c=7): return a*10 + b + c
        local r = img:routine(3, { 100, 200, 7 })
        img:var(0xC0 + 22, V(1), S(10)); img:emit(1)       -- mul L1 10 -> L1
        img:var(0xC0 + 20, V(1), V(2)); img:emit(1)        -- add L1 L2 -> L1
        img:var(0xC0 + 20, V(1), V(3)); img:emit(0)        -- add L1 L3 -> push
        img:op0(8)                                         -- ret_popped
        img.pc = here
        img:var(0xE0, L(r), S(4), S(2)); img:emit(img:global(0))   -- 4*10+2+7 = 49
        img:var(0xE0, L(r), S(1)); img:emit(img:global(1))         -- 1*10+200+7 = 217
        img:var(0xE0, L(0), S(1)); img:emit(img:global(2))         -- call 0 -> 0
        img:op0(10)
        local vm = boot(img)
        assert.equal("quit", vm:run())
        assert.equal(49, g(vm, 0))
        assert.equal(217, g(vm, 1))
        assert.equal(0, g(vm, 2))
    end)

    it("zeroes v5 locals, counts arguments, and supports catch/throw", function()
        local img = newImage(5)
        local here = img.pc
        img.pc = 0x1200
        local inner = img:routine(1)                       -- inner(frame): throw 55 frame
        img:var(0xC0 + 28, S(55), V(1))
        img.pc = 0x1240
        local outer = img:routine(2)                       -- outer(): catch -> L1; call inner(L1); return 1
        img:op0(9); img:emit(1)                            -- catch -> L1
        img:var(0xE0, L(inner), V(1)); img:emit(2)         -- call inner(L1) -> L2
        img:op0(0)                                         -- rtrue (not reached)
        img.pc = 0x1280
        local argc = img:routine(3)                        -- returns 1 if arg 2 given
        img:var(0xFF, S(2)); img:br(true, 1)               -- check_arg_count 2 ?rtrue
        img:op0(1)
        img.pc = here
        img:var(0xE0, L(outer)); img:emit(img:global(0))   -- 55
        img:var(0xE0, L(argc), S(1)); img:emit(img:global(1))       -- 0
        img:var(0xE0, L(argc), S(1), S(2)); img:emit(img:global(2)) -- 1
        img:op0(10)
        local vm = boot(img)
        assert.equal("quit", vm:run())
        assert.equal(55, g(vm, 0))
        assert.equal(0, g(vm, 1))
        assert.equal(1, g(vm, 2))
    end)

    it("reads and writes the stack in place for indirect variable references", function()
        local img = newImage(5)
        img:var(0xE8, S(5))                                -- push 5
        img:var(0xE8, S(9))                                -- push 9
        img:op1(5, S(0))                                   -- inc [sp] -> 10 (in place)
        img:op1(14, S(0)); img:emit(img:global(0))         -- load [sp] -> g0 = 10, no pop
        img:var(0xE9, S(img:global(1)))                    -- pull -> g1 = 10
        img:var(0xE9, S(img:global(2)))                    -- pull -> g2 = 5
        img:op0(10)
        local vm = boot(img)
        assert.equal("quit", vm:run())
        assert.equal(10, g(vm, 0))
        assert.equal(10, g(vm, 1))
        assert.equal(5, g(vm, 2))
    end)
end)

-- Object table for v3: 31 default words, then 9-byte entries.
local function v3Objects(img)
    -- defaults: property n default = 1000 + n
    for n = 1, 31 do img:w(OBJECTS + 2 * (n - 1), 1000 + n) end
    local base = OBJECTS + 62
    local props = 0x500
    local function obj(i, parent, sibling, child, name, plist)
        local a = base + (i - 1) * 9
        img.b[a + 4], img.b[a + 5], img.b[a + 6] = parent, sibling, child
        img:w(a + 7, props)
        local z = packZ(zchars(name))
        img.b[props] = #z / 2
        img:putBytes(props + 1, z)
        local p = props + 1 + #z
        for _, pr in ipairs(plist) do              -- descending property numbers
            local num, data = pr[1], pr[2]
            img.b[p] = (#data - 1) * 32 + num
            img:putBytes(p + 1, data)
            p = p + 1 + #data
        end
        img.b[p] = 0
        props = p + 1
    end
    -- 1 room { 2 lamp, 3 box }
    obj(1, 0, 0, 2, "Room", { { 5, { 0, 42 } } })
    obj(2, 1, 3, 0, "lamp", { { 7, { 0x12, 0x34 } }, { 4, { 9 } }, { 2, { 1, 2, 3, 4 } } })
    obj(3, 1, 0, 0, "box", {})
    img.b[base + 9 * 1 + 0] = 0x80   -- lamp has attribute 0
end

describe("object tree (v3)", function()
    it("moves objects and reads attributes and properties", function()
        local img = newImage(3)
        v3Objects(img)
        local G = function(n) return img:global(n) end
        img:var(0xC0 + 14, S(2), S(3))                     -- insert_obj lamp box
        img:op1(3, S(2)); img:emit(G(0))                   -- get_parent lamp -> 3
        -- (branch offset 2 lands on the next instruction: the branch is a no-op)
        img:op1(2, S(1)); img:emit(G(1)); img:br(false, 2) -- get_child room -> 3
        img:op1(2, S(3)); img:emit(G(2)); img:br(false, 2) -- get_child box -> 2
        img:op1(1, S(2)); img:emit(G(3)); img:br(false, 2) -- get_sibling lamp -> 0
        img:var(0xC0 + 10, S(2), S(0)); img:br(false, 2)   -- test_attr lamp 0 (skip-only)
        img:var(0xC0 + 11, S(3), S(31))                    -- set_attr box 31
        img:var(0xC0 + 12, S(2), S(0))                     -- clear_attr lamp 0
        img:var(0xC0 + 17, S(2), S(7)); img:emit(G(4))     -- get_prop lamp 7 -> 0x1234
        img:var(0xC0 + 17, S(2), S(4)); img:emit(G(5))     -- get_prop lamp 4 -> 9 (byte)
        img:var(0xC0 + 17, S(2), S(6)); img:emit(G(6))     -- default -> 1006
        img:var(0xC0 + 18, S(2), S(2)); img:emit(G(7))     -- get_prop_addr lamp 2
        img:op1(4, V(G(7))); img:emit(G(8))                -- get_prop_len -> 4
        img:var(0xC0 + 19, S(2), S(0)); img:emit(G(9))     -- get_next_prop lamp 0 -> 7
        img:var(0xC0 + 19, S(2), S(7)); img:emit(G(10))    -- -> 4
        img:var(0xC0 + 19, S(2), S(2)); img:emit(G(11))    -- -> 0
        img:var(0xE3, S(2), S(7), L(0xBEEF))               -- put_prop lamp 7
        img:var(0xC0 + 17, S(2), S(7)); img:emit(G(12))
        img:op1(9, S(3))                                   -- remove_obj box
        img:op1(2, S(1)); img:emit(G(13)); img:br(false, 2) -- room child -> 0
        img:op1(10, S(2))                                  -- print_obj lamp
        img:op0(10)
        local vm = boot(img)
        assert.equal("quit", vm:run())
        assert.equal(3, g(vm, 0))
        assert.equal(3, g(vm, 1))
        assert.equal(2, g(vm, 2))
        assert.equal(0, g(vm, 3))
        assert.is_false(vm.testAttr(2, 0))
        assert.is_true(vm.testAttr(3, 31))
        assert.equal(0x1234, g(vm, 4))
        assert.equal(9, g(vm, 5))
        assert.equal(1006, g(vm, 6))
        assert.equal(4, g(vm, 8))
        assert.equal(7, g(vm, 9))
        assert.equal(4, g(vm, 10))
        assert.equal(0, g(vm, 11))
        assert.equal(0xBEEF, g(vm, 12))
        assert.equal(0, g(vm, 13))
        assert.equal(2, vm.childOf(3))        -- lamp travelled with the box
        assert.equal("lamp", vm:takeOutput())
    end)
end)

describe("text", function()
    it("decodes alphabets, ZSCII escapes and abbreviations", function()
        local img = newImage(3)
        -- abbreviation 0 = "the ", abbreviation 33 (table 2, index 1) = "Cave"
        local a0 = 0x780
        img:putBytes(a0, packZ(zchars("the ")))
        img:w(ABBREVS, a0 / 2)
        local a33 = 0x790
        img:putBytes(a33, packZ(zchars("Cave")))
        img:w(ABBREVS + 2 * 33, a33 / 2)
        -- print: [abbr0] "Big " [abbr 2:1] "! 42" + "@" (escape)
        local z = { 1, 0 }
        for _, c in ipairs(zchars("Big ")) do z[#z + 1] = c end
        z[#z + 1] = 2; z[#z + 1] = 1
        for _, c in ipairs(zchars("! 42@")) do z[#z + 1] = c end
        img:op0(2)
        img:emit(unpack_(packZ(z)))
        img:op0(11)                                         -- new_line
        img:var(0xE5, S(170))                               -- print_char é (default unicode table)
        img:var(0xE5, S(220))                               -- œ
        img:op0(10)
        local vm = boot(img)
        vm:run()
        assert.equal("the Big Cave! 42@\néœ", vm:takeOutput())
    end)

    it("prints unicode and redirects output to a memory table (stream 3)", function()
        local img = newImage(5)
        img:var(0xF3, S(3), L(0x600))                       -- output_stream 3 table
        img:op0(2); img:zstring("ab")
        img:emit(0xBE, 0x0B, 0x3F, 0x00, 0xE9)              -- print_unicode é -> ZSCII 170 in table
        img:var(0xF3, L(-3))                                -- close
        img:emit(0xBE, 0x0B, 0x3F, 0x01, 0x53)              -- print_unicode œ to screen
        img:op0(10)
        local vm = boot(img)
        vm:run()
        assert.equal(3, vm.rw(0x600))
        assert.equal(string.byte("a"), vm.mem[0x602])
        assert.equal(170, vm.mem[0x604])
        assert.equal("œ", vm:takeOutput())
    end)
end)

-- A dictionary with a few words, v5.
local function v5Dict(img, words)
    local d = DICT
    img.b[d] = 2; img.b[d + 1] = string.byte("."); img.b[d + 2] = string.byte(",")
    img.b[d + 3] = 9                                         -- entry length
    table.sort(words)
    img:w(d + 4, #words)
    local addrs = {}
    for i, w in ipairs(words) do
        local a = d + 6 + (i - 1) * 9
        local z = zchars(w)
        while #z < 9 do z[#z + 1] = 5 end
        while #z > 9 do z[#z] = nil end
        img:putBytes(a, packZ(z))
        addrs[w] = a
    end
    return addrs
end

describe("input", function()
    it("tokenises a line against the dictionary (v5 aread)", function()
        local img = newImage(5)
        local addrs = v5Dict(img, { "take", "lamp", "north", "théâtre" })
        local text, parse = 0x0400, 0x0480
        img.b[text] = 60; img.b[parse] = 10
        img:var(0xE4, L(text), L(parse)); img:emit(img:global(0))   -- aread -> g0 terminator
        img:op0(10)
        local vm = boot(img)
        assert.equal("input", vm:run())
        assert.equal("quit", vm:sendLine("Take LAMP, north xyzzy"))
        assert.equal(13, g(vm, 0))
        assert.equal(22, vm.mem[text + 1])                  -- characters typed
        assert.equal(5, vm.mem[parse + 1])                  -- take lamp , north xyzzy
        local function word(k) local a = parse + 2 + 4 * (k - 1); return vm.rw(a), vm.mem[a + 2], vm.mem[a + 3] end
        local a, len, pos = word(1)
        assert.equal(addrs.take, a); assert.equal(4, len); assert.equal(2, pos)
        a, len, pos = word(2)
        assert.equal(addrs.lamp, a); assert.equal(4, len); assert.equal(7, pos)
        a, len = word(3)
        assert.equal(0, a); assert.equal(1, len)            -- "," is a separator word
        assert.equal(addrs.north, (word(4)))
        assert.equal(0, (word(5)))                           -- unknown word
        assert.truthy(vm:takeOutput():find("Take LAMP, north xyzzy\n", 1, true))
    end)

    it("maps accented input to ZSCII and finds accented dictionary words", function()
        local img = newImage(5)
        local text, parse = 0x0400, 0x0480
        img.b[text] = 60; img.b[parse] = 10
        img:var(0xE4, L(text), L(parse)); img:emit(img:global(0))
        img:op0(10)
        -- dictionary word "été" with é = ZSCII 170 (escape-encoded)
        img.b[DICT] = 0; img.b[DICT + 1] = 9; img:w(DICT + 2, 1)
        local z = { 5, 6, 5, 10, 25, 5, 6, 5, 10 }           -- é t é  (170 = 5*32+10)
        img:putBytes(DICT + 4, packZ(z))
        local vm = boot(img)
        vm:run()
        vm:sendLine("ÉTÉ")
        assert.equal(170, vm.mem[text + 2])
        assert.equal(string.byte("t"), vm.mem[text + 3])
        assert.equal(DICT + 4, vm.rw(parse + 2))
    end)

    it("reads and tokenises a line in v3 (sread, zero-terminated)", function()
        local img = newImage(3)
        -- v3 dictionary: no separators, 7-byte entries (4 key bytes + 3 data)
        img.b[DICT] = 1; img.b[DICT + 1] = string.byte(","); img.b[DICT + 2] = 7
        img:w(DICT + 3, 2)
        local function key(w) local z = zchars(w); while #z < 6 do z[#z + 1] = 5 end; while #z > 6 do z[#z] = nil end; return packZ(z) end
        img:putBytes(DICT + 5, key("lamp"))
        img:putBytes(DICT + 12, key("lantern"))     -- stored truncated: "lanter"
        local text, parse = 0x0400, 0x0480
        img.b[text] = 20; img.b[parse] = 4
        img:var(0xE4, L(text), L(parse))
        img:op0(10)
        local vm = boot(img)
        assert.equal("input", vm:run())
        vm:sendLine("Lanterns,lamp")
        assert.equal(string.byte("l"), vm.mem[text + 1])
        assert.equal(0, vm.mem[text + 14])               -- terminator after 13 chars
        assert.equal(3, vm.mem[parse + 1])
        assert.equal(DICT + 12, vm.rw(parse + 2))        -- "lanterns" matches "lanter"
        assert.equal(1, vm.mem[parse + 5])               -- position counts from byte 1
        assert.equal(DICT + 5, vm.rw(parse + 10))
    end)

    it("waits for a key with read_char", function()
        local img = newImage(5)
        img:var(0xF6, S(1)); img:emit(img:global(0))
        img:op0(10)
        local vm = boot(img)
        assert.equal("char", vm:run())
        assert.equal("quit", vm:sendChar(vm:keyToZscii("é")))
        assert.equal(170, g(vm, 0))
    end)
end)

describe("save, restore and undo", function()
    -- loop: inc g0; aread; if g0 == 2 save; if g0 == 4 restore; if g0 == 9 quit
    local function counterImage()
        local img = newImage(5)
        local text, parse = 0x0400, 0x0480
        img.b[text] = 60; img.b[parse] = 10
        local G0, G1 = img:global(0), img:global(1)
        local loop = img.pc
        img:op1(5, S(G0))                                   -- inc g0
        img:var(0xE4, L(text), L(parse)); img:emit(G1)      -- aread
        img:var(0xC1, V(G0), S(2)); local b_not2 = img:brFwd(false)
        img:emit(0xBE, 0x00, 0xFF, img:global(2))           -- save -> g2
        local j_after = img:jumpFwd()
        img:patchBr(b_not2, img.pc)
        img:var(0xC1, V(G0), S(4)); local b_after = img:brFwd(false)
        img:emit(0xBE, 0x01, 0xFF, img:global(3))           -- restore -> g3
        local after = img.pc
        img:patchJump(j_after, after); img:patchBr(b_after, after)
        img:var(0xC1, V(G0), S(9)); img:br(false, 3)        -- skip the quit
        img:op0(10)
        img:op1(12, L(loop - img.pc - 1))                   -- jump loop
        return img
    end

    it("round-trips through Quetzal", function()
        local img = counterImage()
        local vm = boot(img)
        assert.equal("input", vm:run())       -- g0 = 1
        assert.equal("input", vm:sendLine("a")) -- loops round to the next read
        assert.equal(2, g(vm, 0))
        assert.equal("save", vm:sendLine("b"))
        local data = vm:saveQuetzal()
        assert.equal("FORM", data:sub(1, 4))
        assert.equal("IFZS", data:sub(9, 12))
        assert.equal("input", vm:finishSave(true))
        assert.equal(1, g(vm, 2))
        assert.equal(3, g(vm, 0))
        assert.equal("input", vm:sendLine("c"))
        assert.equal(4, g(vm, 0))
        assert.equal("restore", vm:sendLine("d"))
        assert.equal("input", vm:finishRestore(data))
        -- back at the save with g0 = 2, the save returns 2
        assert.equal(2, g(vm, 2))
        assert.equal(3, g(vm, 0))
    end)

    it("rejects a save from another story", function()
        local img = counterImage()
        local vm = boot(img)
        vm:run(); vm:sendLine("a")
        vm:sendLine("b")
        local data = vm:saveQuetzal()
        vm:finishSave(true)
        local other = counterImage()
        other:w(0x02, 99)
        local vm2 = boot(other)
        local ok, err = ZMachine.Quetzal.load(vm2, data)
        assert.is_false(ok)
        assert.truthy(err:find("another story"))
    end)

    it("resumes an automatic save at the pending read", function()
        local img = counterImage()
        local vm = boot(img)
        vm:run(); vm:sendLine("a")
        assert.equal("input", vm:getState())
        local data = vm:saveQuetzal(true, "ui-data")
        local vm2 = boot(img)
        local ok, err, extra = vm2:resumeFrom(data)
        assert.is_true(ok, err)
        assert.equal("ui-data", extra)
        assert.equal("input", vm2:run())
        assert.equal(2, g(vm2, 0))
        assert.equal("save", vm2:sendLine("x"))
    end)

    it("undoes with save_undo / restore_undo", function()
        local img = newImage(5)
        local G0 = img:global(0)
        img:var(0xCD, S(G0), S(5))
        img:emit(0xBE, 0x09, 0xFF, img:global(1))           -- save_undo -> g1
        img:var(0xC1, V(img:global(1)), S(2)); img:br(true, 10) -- je g1 2 ?(skip the next 8 bytes)
        img:var(0xCD, S(G0), S(7))
        img:emit(0xBE, 0x0A, 0xFF, img:global(2))           -- restore_undo
        img:op0(10)
        local vm = boot(img)
        assert.equal("quit", vm:run())
        assert.equal(5, g(vm, 0))                            -- the 7 was undone
        assert.equal(2, g(vm, 1))
    end)
end)

describe("v3 status line", function()
    it("reads location, score and moves from globals 0..2", function()
        local img = newImage(3)
        v3Objects(img)
        img:w(GLOBALS, 1); img:w(GLOBALS + 2, 65535); img:w(GLOBALS + 4, 12)
        img:op0(10)
        local vm = boot(img)
        vm:run()
        local name, right = vm:getStatusLine()
        assert.equal("Room", name)
        assert.equal("-1/12", right)
    end)
end)
