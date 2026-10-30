-- ---------------------------------------------------------------------------
-- zmachine.lua -- a Z-machine interpreter (versions 3, 4, 5, 7 and 8)
--
-- Pure Lua, no UI: it runs on LuaJIT 2.1 (KOReader) and on plain Lua 5.1+
-- (busted specs, with a `bit` module). The story lives in one byte array --
-- an FFI uint8_t[] when the FFI is there, a 0-indexed table otherwise -- so a
-- 512 KB story costs 512 KB, plus the original file kept as a string for
-- restart, verify and the Quetzal memory diff.
--
-- The machine runs until it needs something from outside (a line, a key, a
-- file to save to or restore from) and then returns a state:
--   "input"   -- read: call vm:sendLine(text)
--   "char"    -- read_char: call vm:sendChar(zscii)
--   "save"    -- save opcode: write vm:saveQuetzal() somewhere, then vm:finishSave(ok)
--   "restore" -- restore opcode: vm:finishRestore(quetzal_bytes_or_nil)
--   "quit"    -- the story ended
--   "error"   -- vm.error_msg says why
-- Lower-window text is collected and handed over by vm:takeOutput(); the upper
-- window (v4+) is a character grid read with vm:getUpperLines(), the v3 status
-- line comes from vm:getStatusLine().
--
-- Not implemented (ignored, as the standard allows): sound, colours, fonts
-- other than the default, timed input (read/read_char never time out), text
-- styles, version 6 graphics, transcript stream 2 and command stream 4.
-- ---------------------------------------------------------------------------

local bit = require("bit")
local band, bor, bxor, rshift, lshift = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift
local floor = math.floor
local schar, sbyte = string.char, string.byte
local concat = table.concat

local has_ffi, ffi = pcall(require, "ffi")
if has_ffi and not (ffi and ffi.new) then has_ffi = false end

local ZMachine = {}
ZMachine.__index = ZMachine

-- ---------------------------------------------------------------------------
-- Unicode helpers
-- ---------------------------------------------------------------------------

local function utf8char(cp)
    if cp < 0x80 then return schar(cp) end
    if cp < 0x800 then
        return schar(0xC0 + floor(cp / 64), 0x80 + cp % 64)
    end
    if cp < 0x10000 then
        return schar(0xE0 + floor(cp / 4096), 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return schar(0xF0 + floor(cp / 262144), 0x80 + floor(cp / 4096) % 64,
                 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
end
ZMachine.utf8char = utf8char

-- Decode a UTF-8 string into a list of code points (bad bytes become '?').
local function utf8codes(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = sbyte(s, i)
        local cp, len
        if c < 0x80 then cp, len = c, 1
        elseif c >= 0xF0 then cp, len = c % 8, 4
        elseif c >= 0xE0 then cp, len = c % 16, 3
        elseif c >= 0xC0 then cp, len = c % 32, 2
        else cp, len = 63, 1 end
        for k = 1, len - 1 do
            local cc = sbyte(s, i + k)
            if not cc or cc < 0x80 or cc >= 0xC0 then cp, len = 63, k; break end
            cp = cp * 64 + cc % 64
        end
        out[#out + 1] = cp
        i = i + len
    end
    return out
end
ZMachine.utf8codes = utf8codes

-- Lower case for the Latin letters games actually use.
local function lowerCp(cp)
    if cp >= 65 and cp <= 90 then return cp + 32 end
    if cp >= 0xC0 and cp <= 0xDE and cp ~= 0xD7 then return cp + 32 end
    if cp == 0x152 then return 0x153 end
    return cp
end

-- Standard 1.1, 3.8.7: ZSCII 155..223 by default.
local DEFAULT_UNICODE = {
    0xE4, 0xF6, 0xFC, 0xC4, 0xD6, 0xDC, 0xDF, 0xBB, 0xAB, 0xEB, 0xEF, 0xFF, 0xCB, 0xCF,
    0xE1, 0xE9, 0xED, 0xF3, 0xFA, 0xFD, 0xC1, 0xC9, 0xCD, 0xD3, 0xDA, 0xDD,
    0xE0, 0xE8, 0xEC, 0xF2, 0xF9, 0xC0, 0xC8, 0xCC, 0xD2, 0xD9,
    0xE2, 0xEA, 0xEE, 0xF4, 0xFB, 0xC2, 0xCA, 0xCE, 0xD4, 0xDB,
    0xE5, 0xC5, 0xF8, 0xD8, 0xE3, 0xF1, 0xF5, 0xC3, 0xD1, 0xD5,
    0xE6, 0xC6, 0xE7, 0xC7, 0xFE, 0xF0, 0xDE, 0xD0, 0xA3, 0x153, 0x152, 0xA1, 0xBF,
}

local A0 = "abcdefghijklmnopqrstuvwxyz"
local A1 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local A2 = " \n0123456789.,!?_#'\"/\\-:()"   -- z-chars 6..31 (6 = escape, 7 = newline)

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- story: the story file as a Lua string. opts.cols / opts.rows: screen size in
-- characters reported to the game; opts.seed: random seed.
function ZMachine.new(story, opts)
    opts = opts or {}
    local version = sbyte(story, 1)
    if not version or #story < 64 then
        return nil, "not a story file"
    end
    if version < 3 or version == 6 or version > 8 then
        return nil, "unsupported Z-machine version " .. tostring(version)
    end

    local vm = setmetatable({}, ZMachine)
    vm.version = version
    vm.story = story
    vm.size = #story
    vm.cols = opts.cols or 60
    vm.rows = opts.rows or 255
    vm.interp_number = opts.interp_number or 6
    vm.rng_state = opts.seed or os.time()
    vm:_build()
    vm:_reset()
    return vm
end

-- All the machine's hot state lives in upvalues of the closures made here.
function ZMachine:_build()
    local vm = self
    local version = self.version
    local story = self.story
    local size = self.size

    -- memory -------------------------------------------------------------
    local mem
    if has_ffi then
        mem = ffi.new("uint8_t[?]", size + 8)
        ffi.copy(mem, story, size)
    else
        mem = {}
        for i = 0, size - 1 do mem[i] = sbyte(story, i + 1) end
        for i = size, size + 7 do mem[i] = 0 end
    end
    vm.mem = mem

    local function rw(a) return mem[a] * 256 + mem[a + 1] end
    local function ww(a, v)
        if a < 0 or a + 1 >= size then error({ zerr = string.format("word write out of range: %d", a) }) end
        mem[a] = floor(v / 256) % 256; mem[a + 1] = v % 256
    end
    local function wb(a, v)
        if a < 0 or a >= size then error({ zerr = string.format("byte write out of range: %d", a) }) end
        mem[a] = v % 256
    end
    local function signed(v) if v >= 32768 then return v - 65536 end return v end
    local function fail(msg) error({ zerr = msg }) end
    vm.rw, vm.ww, vm.wb = rw, ww, wb

    -- header values that never change
    local static_base = rw(0x0E)
    local globals = rw(0x0C)
    local obj_table = rw(0x0A)
    local abbrev_table = rw(0x18)
    local dict_main = rw(0x08)
    local packed_mult = (version <= 3) and 2 or ((version <= 7) and 4 or 8)
    local routine_off = (version == 7) and rw(0x28) * 8 or 0
    local string_off = (version == 7) and rw(0x2A) * 8 or 0
    local obj_size = version <= 3 and 9 or 14
    local obj_base = obj_table + (version <= 3 and 62 or 126) - obj_size
    local max_attr = version <= 3 and 31 or 47
    vm.static_base = static_base

    -- alphabets (custom table: v5+, header 0x34) ---------------------------
    local alpha = { [0] = {}, {}, {} }
    do
        local custom = version >= 5 and rw(0x34) or 0
        for z = 6, 31 do
            if custom ~= 0 then
                alpha[0][z] = mem[custom + z - 6]
                alpha[1][z] = mem[custom + 26 + z - 6]
                alpha[2][z] = mem[custom + 52 + z - 6]
            else
                alpha[0][z] = sbyte(A0, z - 5)
                alpha[1][z] = sbyte(A1, z - 5)
                alpha[2][z] = sbyte(A2, z - 5)
            end
        end
        alpha[2][7] = 13
    end
    -- zscii -> { alphabet, zchar } for encoding
    local enc = {}
    for a = 2, 0, -1 do
        for z = 31, 6, -1 do
            if not (a == 2 and z <= 7) then enc[alpha[a][z]] = { a, z } end
        end
    end

    -- unicode table (header extension word 3) ------------------------------
    local zs2uni = {}
    do
        local ext = version >= 5 and rw(0x36) or 0
        local utab = (ext ~= 0 and rw(ext) >= 3) and rw(ext + 6) or 0
        if utab ~= 0 then
            local n = mem[utab]
            for i = 0, n - 1 do zs2uni[155 + i] = rw(utab + 1 + 2 * i) end
        else
            for i, cp in ipairs(DEFAULT_UNICODE) do zs2uni[154 + i] = cp end
        end
    end
    local uni2zs = {}
    for z, cp in pairs(zs2uni) do uni2zs[cp] = z end
    local zs2utf = {}
    for c = 32, 126 do zs2utf[c] = schar(c) end
    zs2utf[13] = "\n"
    for z, cp in pairs(zs2uni) do zs2utf[z] = utf8char(cp) end
    vm.zs2uni, vm.uni2zs = zs2uni, uni2zs

    -- ZSCII code for a unicode code point, or nil.
    local function toZscii(cp)
        if cp >= 32 and cp <= 126 then return cp end
        if cp == 10 or cp == 13 then return 13 end
        return uni2zs[cp]
    end
    vm.toZscii = toZscii

    -- machine state --------------------------------------------------------
    local pc = 0
    local instr_pc = 0
    -- One array holds every frame's locals and evaluation stack: frame d's
    -- local v is stk[F_fp[d] + v], its stack starts above its locals. Frame
    -- data lives in parallel arrays, so a call allocates nothing.
    local stk, sp = {}, 0
    local depth = 1              -- frame 1 is the dummy main frame
    local F_ret, F_store, F_nl, F_argc, F_fp = { 0 }, { false }, { 0 }, { 0 }, { 0 }
    local cur_fp, cur_base = 0, 0  -- top frame: locals base, stack base
    local ops = {}
    local nops = 0
    local state = "running"

    -- output
    local out = {}               -- lower window pieces (UTF-8)
    local stream1 = true
    local stream3 = {}           -- stack of { addr, n }
    local window = 0
    local upper_h = 0
    local grid = {}              -- grid[row][col] = UTF-8 char
    local cur_row, cur_col = 1, 1

    local function getState() return state end
    vm._getState = getState

    -- ---------------------------------------------------------------------
    -- Variables and stack
    -- ---------------------------------------------------------------------
    local function push(v) sp = sp + 1; stk[sp] = v end
    local function pop()
        if sp <= cur_base then fail("stack underflow") end
        local v = stk[sp]; sp = sp - 1
        return v
    end
    local function readVar(v)
        if v == 0 then return pop() end
        if v < 16 then
            if cur_fp + v > cur_base then fail("read of nonexistent local " .. v) end
            return stk[cur_fp + v]
        end
        local a = globals + 2 * (v - 16)
        return mem[a] * 256 + mem[a + 1]
    end
    local function writeVar(v, x)
        if v == 0 then sp = sp + 1; stk[sp] = x; return end
        if v < 16 then
            if cur_fp + v > cur_base then fail("write to nonexistent local " .. v) end
            stk[cur_fp + v] = x; return
        end
        local a = globals + 2 * (v - 16)
        mem[a] = floor(x / 256); mem[a + 1] = x % 256
    end
    -- "indirect" variable references (store, load, inc, dec, pull...): the
    -- stack is read/written in place rather than popped/pushed (Standard 6.3.4).
    local function readVarInd(v)
        if v == 0 then
            if sp <= cur_base then fail("stack underflow") end
            return stk[sp]
        end
        return readVar(v)
    end
    local function writeVarInd(v, x)
        if v == 0 then
            if sp <= cur_base then fail("stack underflow") end
            stk[sp] = x; return
        end
        writeVar(v, x)
    end
    vm.readVar = function(_, v) return readVarInd(v) end

    local function storeResult(x)
        local v = mem[pc]; pc = pc + 1
        writeVar(v, x % 65536)
    end

    -- ---------------------------------------------------------------------
    -- Calls and returns
    -- ---------------------------------------------------------------------
    local function enterFrame(d)
        depth = d
        cur_fp = F_fp[d]
        cur_base = cur_fp + F_nl[d]
    end

    local function doReturn(x)
        if depth <= 1 then fail("return from main routine") end
        local store = F_store[depth]
        sp = cur_fp
        pc = F_ret[depth]
        enterFrame(depth - 1)
        if store then writeVar(store, x % 65536) end
    end

    -- store_var: variable number for the result, or false to discard it.
    local function call(paddr, first, last, store_var)
        if paddr == 0 then
            if store_var then writeVar(store_var, 0) end
            return
        end
        local addr = paddr * packed_mult + routine_off
        if addr >= size then fail(string.format("call to invalid address %d", addr)) end
        local nl = mem[addr]; addr = addr + 1
        if nl > 15 then fail("routine with more than 15 locals") end
        local fp = sp
        for i = 1, nl do
            if version <= 4 then stk[fp + i] = mem[addr] * 256 + mem[addr + 1]; addr = addr + 2
            else stk[fp + i] = 0 end
        end
        local argc = last - first + 1
        for i = 1, (argc < nl) and argc or nl do stk[fp + i] = ops[first + i - 1] end
        local d = depth + 1
        F_ret[d], F_store[d], F_nl[d], F_argc[d], F_fp[d] = pc, store_var, nl, argc, fp
        sp = fp + nl
        enterFrame(d)
        pc = addr
    end

    -- ---------------------------------------------------------------------
    -- Branch
    -- ---------------------------------------------------------------------
    local function branch(cond)
        local b = mem[pc]; pc = pc + 1
        local off
        if b % 128 >= 64 then
            off = b % 64
        else
            off = (b % 64) * 256 + mem[pc]; pc = pc + 1
            if off >= 8192 then off = off - 16384 end
        end
        if (b >= 128) == (cond and true or false) then
            if off == 0 then return doReturn(0) end
            if off == 1 then return doReturn(1) end
            pc = pc + off - 2
        end
    end

    -- ---------------------------------------------------------------------
    -- Output
    -- ---------------------------------------------------------------------
    local function upperPut(ch)
        if ch == "\n" then
            cur_row = cur_row + 1; cur_col = 1
            return
        end
        if cur_row >= 1 and cur_row <= upper_h and cur_col >= 1 and cur_col <= vm.cols then
            local row = grid[cur_row]
            if not row then row = {}; grid[cur_row] = row end
            row[cur_col] = ch
        end
        cur_col = cur_col + 1
    end

    local function screenPut(s)
        if window == 1 and version >= 4 then
            if #s == 1 or s:byte(1) < 0x80 then
                for i = 1, #s do upperPut(s:sub(i, i)) end
            else
                upperPut(s)
            end
        else
            out[#out + 1] = s
        end
    end

    local function printZscii(c)
        if c == 0 then return end
        local t = stream3[#stream3]
        if t then
            wb(t.addr + 2 + t.n, c)
            t.n = t.n + 1
            return
        end
        if not stream1 then return end
        local s = zs2utf[c]
        if not s then
            if c == 9 then s = " " elseif c == 11 then s = "  " else s = "?" end
        end
        screenPut(s)
    end
    vm._printZscii = printZscii

    local function printUnicode(cp)
        if stream3[#stream3] then
            printZscii(toZscii(cp) or 63)
            return
        end
        if not stream1 then return end
        if cp == 10 or cp == 13 then screenPut("\n") return end
        screenPut(utf8char(cp))
    end

    local function printAscii(s)
        for i = 1, #s do printZscii(sbyte(s, i)) end
    end

    -- ---------------------------------------------------------------------
    -- Text decoding
    -- ---------------------------------------------------------------------
    local function decodeZ(addr, emit, in_abbrev)
        local zs, n = {}, 0
        while true do
            if addr + 1 >= size then break end
            local w = mem[addr] * 256 + mem[addr + 1]; addr = addr + 2
            zs[n + 1] = floor(w / 1024) % 32
            zs[n + 2] = floor(w / 32) % 32
            zs[n + 3] = w % 32
            n = n + 3
            if w >= 32768 then break end
        end
        local i, a = 1, 0
        while i <= n do
            local z = zs[i]; i = i + 1
            if z == 0 then
                emit(32); a = 0
            elseif z <= 3 then
                local x = zs[i]; i = i + 1
                if x and not in_abbrev then
                    local idx = 32 * (z - 1) + x
                    decodeZ(rw(abbrev_table + 2 * idx) * 2, emit, true)
                end
                a = 0
            elseif z == 4 then
                a = 1
            elseif z == 5 then
                a = 2
            else
                if a == 2 and z == 6 then
                    local hi, lo = zs[i], zs[i + 1]; i = i + 2
                    if hi and lo then emit(hi * 32 + lo) end
                else
                    emit(alpha[a][z])
                end
                a = 0
            end
        end
        return addr
    end
    vm.decodeZ = function(_, addr)
        local t = {}
        local e = decodeZ(addr, function(c) t[#t + 1] = zs2utf[c] or "?" end)
        return concat(t), e
    end

    local function printAt(addr) return decodeZ(addr, printZscii) end

    -- Encode zscii codes (list, i..j) into dictionary form: a byte string of
    -- 4 bytes (v3) or 6 bytes (v4+).
    local nzc = version <= 3 and 6 or 9
    local function encodeWord(codes, i, j)
        local z = {}
        for k = i, j do
            local c = codes[k]
            local e = enc[c]
            if e then
                if e[1] == 1 then z[#z + 1] = 4 elseif e[1] == 2 then z[#z + 1] = 5 end
                z[#z + 1] = e[2]
            else
                z[#z + 1] = 5; z[#z + 1] = 6
                z[#z + 1] = floor(c / 32) % 32; z[#z + 1] = c % 32
            end
            if #z >= nzc then break end
        end
        while #z < nzc do z[#z + 1] = 5 end
        local bytes = {}
        for w = 0, nzc / 3 - 1 do
            local v = z[3 * w + 1] * 1024 + z[3 * w + 2] * 32 + z[3 * w + 3]
            if w == nzc / 3 - 1 then v = v + 32768 end
            bytes[#bytes + 1] = schar(floor(v / 256), v % 256)
        end
        return concat(bytes)
    end
    vm.encodeWord = encodeWord

    -- ---------------------------------------------------------------------
    -- Objects
    -- ---------------------------------------------------------------------
    local function objAddr(o) return obj_base + o * obj_size end
    local function parentOf(o)
        if o == 0 then return 0 end
        local a = objAddr(o)
        if version <= 3 then return mem[a + 4] end
        return rw(a + 6)
    end
    local function siblingOf(o)
        if o == 0 then return 0 end
        local a = objAddr(o)
        if version <= 3 then return mem[a + 5] end
        return rw(a + 8)
    end
    local function childOf(o)
        if o == 0 then return 0 end
        local a = objAddr(o)
        if version <= 3 then return mem[a + 6] end
        return rw(a + 10)
    end
    local function setParent(o, v)
        local a = objAddr(o)
        if version <= 3 then wb(a + 4, v) else ww(a + 6, v) end
    end
    local function setSibling(o, v)
        local a = objAddr(o)
        if version <= 3 then wb(a + 5, v) else ww(a + 8, v) end
    end
    local function setChild(o, v)
        local a = objAddr(o)
        if version <= 3 then wb(a + 6, v) else ww(a + 10, v) end
    end
    local function propTable(o) return rw(objAddr(o) + (version <= 3 and 7 or 12)) end
    vm.parentOf, vm.siblingOf, vm.childOf = parentOf, siblingOf, childOf

    local function testAttr(o, n)
        if o == 0 or n > max_attr then return false end
        local b = mem[objAddr(o) + floor(n / 8)]
        return floor(b / 2 ^ (7 - n % 8)) % 2 == 1
    end
    local function setAttr(o, n, on)
        if o == 0 or n > max_attr then return end
        local a = objAddr(o) + floor(n / 8)
        local m = 2 ^ (7 - n % 8)
        local b = mem[a]
        local has = floor(b / m) % 2 == 1
        if on and not has then mem[a] = b + m elseif not on and has then mem[a] = b - m end
    end
    vm.testAttr = testAttr

    local function removeObj(o)
        if o == 0 then return end
        local p = parentOf(o)
        if p == 0 then return end
        local c = childOf(p)
        if c == o then
            setChild(p, siblingOf(o))
        else
            local guard = 0
            while c ~= 0 do
                local s = siblingOf(c)
                if s == o then setSibling(c, siblingOf(o)); break end
                c = s
                guard = guard + 1
                if guard > 65535 then fail("object tree loop") end
            end
        end
        setParent(o, 0)
        setSibling(o, 0)
    end
    local function insertObj(o, d)
        if o == 0 or d == 0 then return end
        removeObj(o)
        setParent(o, d)
        setSibling(o, childOf(d))
        setChild(d, o)
    end

    -- First property block of an object: returns its address.
    local function firstProp(o)
        local t = propTable(o)
        return t + 1 + 2 * mem[t]
    end
    -- Decode a property header at a: number, data address, data length.
    local function propHeader(a)
        local b = mem[a]
        if version <= 3 then
            if b == 0 then return 0, a + 1, 0 end
            return b % 32, a + 1, floor(b / 32) + 1
        end
        if b == 0 then return 0, a + 1, 0 end
        if b >= 128 then
            local l = mem[a + 1] % 64
            if l == 0 then l = 64 end
            return b % 64, a + 2, l
        end
        return b % 64, a + 1, (b >= 64) and 2 or 1
    end
    local function findProp(o, p)
        if o == 0 then return nil end
        local a = firstProp(o)
        while true do
            local n, d, l = propHeader(a)
            if n == 0 then return nil end
            if n == p then return d, l end
            if n < p then return nil end
            a = d + l
        end
    end
    local function propLen(d)
        if d == 0 then return 0 end
        local b = mem[d - 1]
        if version <= 3 then return floor(b / 32) + 1 end
        if b >= 128 then
            local l = b % 64
            return l == 0 and 64 or l
        end
        return (b >= 64) and 2 or 1
    end

    local function printObjName(o)
        if o == 0 then return end
        local t = propTable(o)
        if mem[t] > 0 then printAt(t + 1) end
    end
    vm.objName = function(_, o)
        if o == 0 then return "" end
        local t = propTable(o)
        if mem[t] == 0 then return "" end
        return (vm:decodeZ(t + 1))
    end

    -- ---------------------------------------------------------------------
    -- Dictionary and tokenising
    -- ---------------------------------------------------------------------
    local dict_cache = {}
    local function dictInfo(d)
        local info = dict_cache[d]
        if info and d >= static_base then return info end
        local nsep = mem[d]
        local seps = {}
        for i = 1, nsep do seps[mem[d + i]] = true end
        local elen = mem[d + nsep + 1]
        local count = signed(rw(d + nsep + 2))
        if count < 0 then count = -count end
        local first = d + nsep + 4
        local map = {}
        local klen = version <= 3 and 4 or 6
        for i = 0, count - 1 do
            local a = first + i * elen
            local key = {}
            for k = 0, klen - 1 do key[k + 1] = schar(mem[a + k]) end
            key = concat(key)
            if not map[key] then map[key] = a end
        end
        info = { seps = seps, map = map }
        dict_cache[d] = info
        return info
    end
    local function lookup(d, codes, i, j)
        return dictInfo(d).map[encodeWord(codes, i, j)] or 0
    end
    vm.lookup = function(_, word)
        local codes = {}
        for _, cp in ipairs(utf8codes(word)) do codes[#codes + 1] = toZscii(lowerCp(cp)) or 63 end
        return lookup(dict_main, codes, 1, #codes)
    end

    local function tokenise(text, parse, d, flag)
        if d == 0 then d = dict_main end
        local info = dictInfo(d)
        local start, len
        if version <= 4 then
            start = text + 1
            len = 0
            while mem[start + len] ~= 0 and start + len < size do len = len + 1 end
        else
            start = text + 2
            len = mem[text + 1]
        end
        local codes = {}
        for i = 0, len - 1 do codes[i + 1] = mem[start + i] end
        local words = {}
        local i = 1
        while i <= len do
            local c = codes[i]
            if c == 32 then
                i = i + 1
            elseif info.seps[c] then
                words[#words + 1] = { i, i }
                i = i + 1
            else
                local j = i
                while j + 1 <= len and codes[j + 1] ~= 32 and not info.seps[codes[j + 1]] do j = j + 1 end
                words[#words + 1] = { i, j }
                i = j + 1
            end
        end
        local maxw = mem[parse]
        local n = math.min(#words, maxw)
        for k = 1, n do
            local w = words[k]
            local a = info.map[encodeWord(codes, w[1], w[2])] or 0
            local slot = parse + 2 + 4 * (k - 1)
            if not (flag and a == 0) then
                ww(slot, a)
                wb(slot + 2, w[2] - w[1] + 1)
                wb(slot + 3, w[1] - 1 + (start - text))
            end
        end
        wb(parse + 1, n)
    end
    vm._lookup = lookup

    -- ---------------------------------------------------------------------
    -- Random numbers
    -- ---------------------------------------------------------------------
    local rng_mode, rng_seq, rng_seq_n = "random", 0, 0
    local function nextRandom()
        local s = vm.rng_state % 2147483647
        if s <= 0 then s = s + 2147483646 end
        s = (s * 16807) % 2147483647
        vm.rng_state = s
        return s
    end
    local function random(r)
        if r > 0 then
            if rng_mode == "seq" then
                rng_seq = rng_seq % rng_seq_n + 1
                return (rng_seq - 1) % r + 1
            end
            return floor(nextRandom() / 7) % r + 1
        end
        if r == 0 then
            rng_mode = "random"
            vm.rng_state = os.time() + floor(os.clock() * 1000000)
        elseif -r < 1000 then
            rng_mode, rng_seq, rng_seq_n = "seq", 0, -r
        else
            rng_mode = "random"
            vm.rng_state = -r
        end
        return 0
    end

    -- ---------------------------------------------------------------------
    -- Header
    -- ---------------------------------------------------------------------
    local function initHeader(keep_flags2)
        if version <= 3 then
            -- status line available, screen split available, fixed-pitch default off
            mem[1] = band(mem[1], 0x8F) + 0x20
        else
            -- bold, italic, fixed-space available; no colours, pictures, timed input
            mem[1] = 0x1C
        end
        local f2 = rw(0x10)
        if keep_flags2 then f2 = f2 - f2 % 4 + keep_flags2 % 4 end
        -- no pictures, mouse, sound, menus; undo available
        f2 = band(f2, 0xFE57)
        ww(0x10, f2)
        mem[0x1E] = vm.interp_number
        mem[0x1F] = 75   -- 'K'
        mem[0x20] = vm.rows
        mem[0x21] = vm.cols
        if version >= 5 then
            ww(0x22, vm.cols)
            ww(0x24, vm.rows)
            mem[0x26] = 1
            mem[0x27] = 1
            mem[0x2C] = 1   -- default background: current
            mem[0x2D] = 1
        end
        mem[0x32] = 1
        mem[0x33] = 0
    end
    vm._initHeader = initHeader

    -- ---------------------------------------------------------------------
    -- Snapshots (undo / Quetzal)
    -- ---------------------------------------------------------------------
    -- Snapshot as a list of frames { ret_pc, store, nlocals, argc, sp_base,
    -- locals } plus one array of evaluation-stack values (sp_base indexes it):
    -- the shape Quetzal and undo work with.
    local function copyFrames()
        local fs, s = {}, {}
        for d = 1, depth do
            local fp, nl = F_fp[d], F_nl[d]
            local l = {}
            for k = 1, nl do l[k] = stk[fp + k] end
            fs[d] = { ret_pc = F_ret[d], store = F_store[d] or nil, nlocals = nl,
                      argc = F_argc[d], sp_base = #s, locals = l }
            local top = (d < depth) and F_fp[d + 1] or sp
            for k = fp + nl + 1, top do s[#s + 1] = stk[k] end
        end
        return fs, s
    end
    local function dynBytes()
        if has_ffi then return ffi.string(mem, static_base) end
        local t = {}
        for i = 0, static_base - 1 do t[#t + 1] = schar(mem[i]) end
        return concat(t)
    end
    local function setDyn(s)
        if has_ffi then
            ffi.copy(mem, s, static_base)
        else
            for i = 0, static_base - 1 do mem[i] = sbyte(s, i + 1) end
        end
    end
    local function setStacks(fs, s)
        stk, sp = {}, 0
        F_ret, F_store, F_nl, F_argc, F_fp = {}, {}, {}, {}, {}
        for d, f in ipairs(fs) do
            F_ret[d], F_store[d], F_nl[d], F_argc[d], F_fp[d] =
                f.ret_pc, f.store or false, f.nlocals, f.argc, sp
            for k = 1, f.nlocals do stk[sp + k] = f.locals[k] end
            sp = sp + f.nlocals
            local top = fs[d + 1] and fs[d + 1].sp_base or #s
            for k = f.sp_base + 1, top do sp = sp + 1; stk[sp] = s[k] end
        end
        enterFrame(#fs)
    end

    -- A few levels of undo: each snapshot is the dynamic memory plus the
    -- stacks, a few tens of KB for a typical game.
    local MAX_UNDO = 8
    local undo_snaps = {}

    -- ---------------------------------------------------------------------
    -- Opcode tables
    -- ---------------------------------------------------------------------
    local op2, op1, op0, opv, opx = {}, {}, {}, {}, {}

    -- 2OP ----------------------------------------------------------------
    op2[1] = function() -- je
        local a = ops[1]
        local r = false
        for i = 2, nops do if ops[i] == a then r = true; break end end
        branch(r)
    end
    op2[2] = function() branch(signed(ops[1]) < signed(ops[2])) end   -- jl
    op2[3] = function() branch(signed(ops[1]) > signed(ops[2])) end   -- jg
    op2[4] = function() -- dec_chk
        local v = (signed(readVarInd(ops[1])) - 1) % 65536
        writeVarInd(ops[1], v)
        branch(signed(v) < signed(ops[2]))
    end
    op2[5] = function() -- inc_chk
        local v = (signed(readVarInd(ops[1])) + 1) % 65536
        writeVarInd(ops[1], v)
        branch(signed(v) > signed(ops[2]))
    end
    op2[6] = function() branch(parentOf(ops[1]) == ops[2]) end        -- jin
    op2[7] = function() branch(band(ops[1], ops[2]) == ops[2]) end     -- test
    op2[8] = function() storeResult(bor(ops[1], ops[2])) end          -- or
    op2[9] = function() storeResult(band(ops[1], ops[2])) end         -- and
    op2[10] = function() branch(testAttr(ops[1], ops[2])) end         -- test_attr
    op2[11] = function() setAttr(ops[1], ops[2], true) end            -- set_attr
    op2[12] = function() setAttr(ops[1], ops[2], false) end           -- clear_attr
    op2[13] = function() writeVarInd(ops[1], ops[2]) end              -- store
    op2[14] = function() insertObj(ops[1], ops[2]) end                -- insert_obj
    op2[15] = function() storeResult(rw((ops[1] + 2 * signed(ops[2])) % 65536)) end -- loadw
    op2[16] = function() storeResult(mem[(ops[1] + signed(ops[2])) % 65536]) end    -- loadb
    op2[17] = function() -- get_prop
        local d, l = findProp(ops[1], ops[2])
        if not d then
            storeResult(rw(obj_table + 2 * (ops[2] - 1)))
        elseif l == 1 then
            storeResult(mem[d])
        else
            storeResult(rw(d))
        end
    end
    op2[18] = function() storeResult(findProp(ops[1], ops[2]) or 0) end  -- get_prop_addr
    op2[19] = function() -- get_next_prop
        local o, p = ops[1], ops[2]
        if o == 0 then storeResult(0) return end
        local a
        if p == 0 then
            a = firstProp(o)
        else
            local d, l = findProp(o, p)
            if not d then fail("get_next_prop on missing property") end
            a = d + l
        end
        storeResult((propHeader(a)))
    end
    op2[20] = function() storeResult(ops[1] + ops[2]) end            -- add
    op2[21] = function() storeResult(ops[1] - ops[2]) end            -- sub
    op2[22] = function() storeResult(signed(ops[1]) * signed(ops[2])) end -- mul
    op2[23] = function() -- div
        local a, b = signed(ops[1]), signed(ops[2])
        if b == 0 then fail("division by zero") end
        local q = a / b
        q = q >= 0 and floor(q) or -floor(-q)
        storeResult(q)
    end
    op2[24] = function() -- mod
        local a, b = signed(ops[1]), signed(ops[2])
        if b == 0 then fail("division by zero") end
        local q = a / b
        q = q >= 0 and floor(q) or -floor(-q)
        storeResult(a - b * q)
    end
    op2[25] = function() local v = mem[pc]; pc = pc + 1; call(ops[1], 2, nops, v) end -- call_2s
    op2[26] = function() call(ops[1], 2, nops, false) end                -- call_2n
    op2[27] = function() end                                           -- set_colour
    op2[28] = function() -- throw
        local x, f = ops[1], ops[2]
        if f > depth or f < 2 then fail("throw to invalid frame") end
        if f < depth then
            sp = F_fp[f + 1]
            enterFrame(f)
        end
        doReturn(x)
    end

    -- 1OP ----------------------------------------------------------------
    op1[0] = function() branch(ops[1] == 0) end                       -- jz
    op1[1] = function() local s = siblingOf(ops[1]); storeResult(s); branch(s ~= 0) end
    op1[2] = function() local c = childOf(ops[1]); storeResult(c); branch(c ~= 0) end
    op1[3] = function() storeResult(parentOf(ops[1])) end
    op1[4] = function() storeResult(propLen(ops[1])) end              -- get_prop_len
    op1[5] = function() writeVarInd(ops[1], (readVarInd(ops[1]) + 1) % 65536) end -- inc
    op1[6] = function() writeVarInd(ops[1], (readVarInd(ops[1]) - 1) % 65536) end -- dec
    op1[7] = function() printAt(ops[1]) end                           -- print_addr
    op1[8] = function() local v = mem[pc]; pc = pc + 1; call(ops[1], 2, nops, v) end -- call_1s
    op1[9] = function() removeObj(ops[1]) end
    op1[10] = function() printObjName(ops[1]) end
    op1[11] = function() doReturn(ops[1]) end                         -- ret
    op1[12] = function() pc = pc + signed(ops[1]) - 2 end             -- jump
    op1[13] = function() printAt(ops[1] * packed_mult + string_off) end -- print_paddr
    op1[14] = function() storeResult(readVarInd(ops[1])) end          -- load
    op1[15] = function()
        if version <= 4 then storeResult(65535 - ops[1])              -- not
        else call(ops[1], 2, nops, false) end                            -- call_1n
    end

    -- 0OP ----------------------------------------------------------------
    op0[0] = function() doReturn(1) end
    op0[1] = function() doReturn(0) end
    op0[2] = function() pc = printAt(pc) end
    op0[3] = function() pc = printAt(pc); printZscii(13); doReturn(1) end
    op0[4] = function() end
    op0[5] = function() -- save (v3 branch, v4 store)
        state = "save"
    end
    op0[6] = function() state = "restore" end
    op0[7] = function() vm:restart() end
    op0[8] = function() doReturn(pop()) end
    op0[9] = function()
        if version <= 4 then pop()
        else storeResult(depth) end                                    -- catch
    end
    op0[10] = function() state = "quit" end
    op0[11] = function() printZscii(13) end
    op0[12] = function() end                                           -- show_status
    op0[13] = function() -- verify
        local len = rw(0x1A) * (version <= 3 and 2 or (version <= 5 and 4 or 8))
        if len == 0 or len > size then len = size end
        local sum = 0
        for i = 0x40, len - 1 do sum = sum + sbyte(story, i + 1) end
        branch(sum % 65536 == rw(0x1C))
    end
    op0[15] = function() branch(true) end                              -- piracy

    -- VAR ----------------------------------------------------------------
    opv[0] = function() local v = mem[pc]; pc = pc + 1; call(ops[1], 2, nops, v) end -- call_vs
    opv[1] = function() ww((ops[1] + 2 * signed(ops[2])) % 65536, ops[3]) end      -- storew
    opv[2] = function() wb((ops[1] + signed(ops[2])) % 65536, ops[3]) end          -- storeb
    opv[3] = function() -- put_prop
        local d, l = findProp(ops[1], ops[2])
        if not d then fail("put_prop on missing property " .. ops[2]) end
        if l == 1 then wb(d, ops[3] % 256) else ww(d, ops[3]) end
    end
    opv[4] = function() -- sread / aread
        vm.pending = { kind = "line", text = ops[1], parse = ops[2] or 0, instr_pc = instr_pc }
        if version >= 5 then
            vm.pending.store = mem[pc]; pc = pc + 1
        end
        state = "input"
    end
    opv[5] = function() printZscii(ops[1]) end                         -- print_char
    opv[6] = function() printAscii(tostring(signed(ops[1]))) end       -- print_num
    opv[7] = function() storeResult(random(signed(ops[1]))) end
    opv[8] = function() push(ops[1]) end
    opv[9] = function() -- pull
        local v = pop()
        writeVarInd(ops[1], v)
    end
    opv[10] = function() -- split_window
        upper_h = ops[1]
        if version == 3 then grid = {} end
        if cur_row > upper_h then cur_row, cur_col = 1, 1 end
    end
    opv[11] = function() -- set_window
        window = ops[1]
        if window == 1 then cur_row, cur_col = 1, 1 end
    end
    opv[12] = opv[0]                                                   -- call_vs2
    opv[13] = function() -- erase_window
        local w = signed(ops[1])
        if w == -1 then
            upper_h = 0; grid = {}; window = 0; vm.cleared = true; out = {}
            cur_row, cur_col = 1, 1
        elseif w == -2 then
            grid = {}; vm.cleared = true; out = {}
        elseif w == 0 then
            vm.cleared = true; out = {}
        elseif w == 1 then
            grid = {}; cur_row, cur_col = 1, 1
        end
    end
    opv[14] = function() -- erase_line
        if ops[1] == 1 and window == 1 then
            local row = grid[cur_row]
            if row then for c = cur_col, vm.cols do row[c] = nil end end
        end
    end
    opv[15] = function() -- set_cursor
        if window == 1 then
            cur_row, cur_col = signed(ops[1]), ops[2] or 1
            if cur_row > upper_h and version >= 4 and cur_row <= vm.rows then
                -- some games write past the split; grow it, as most terps do
                upper_h = cur_row
            end
        end
    end
    opv[16] = function() -- get_cursor
        ww(ops[1], window == 1 and cur_row or 1)
        ww(ops[1] + 2, window == 1 and cur_col or 1)
    end
    opv[17] = function() end                                           -- set_text_style
    opv[18] = function() end                                           -- buffer_mode
    opv[19] = function() -- output_stream
        local n = signed(ops[1])
        if n == 1 then stream1 = true
        elseif n == -1 then stream1 = false
        elseif n == 2 then ww(0x10, bor(rw(0x10), 1))
        elseif n == -2 then ww(0x10, band(rw(0x10), 0xFFFE))
        elseif n == 3 then
            if #stream3 >= 16 then fail("output stream 3 nested too deep") end
            stream3[#stream3 + 1] = { addr = ops[2], n = 0 }
        elseif n == -3 then
            local t = stream3[#stream3]
            if t then
                ww(t.addr, t.n)
                stream3[#stream3] = nil
            end
        end
    end
    opv[20] = function() end                                           -- input_stream
    opv[21] = function() end                                           -- sound_effect
    opv[22] = function() -- read_char
        vm.pending = { kind = "char", instr_pc = instr_pc, store = mem[pc] }
        pc = pc + 1
        state = "char"
    end
    opv[23] = function() -- scan_table
        local x, t, len = ops[1], ops[2], ops[3]
        local form = nops >= 4 and ops[4] or 0x82
        local words = form >= 128
        local step = form % 128
        local found = 0
        for i = 0, len - 1 do
            local a = t + i * step
            local v = words and rw(a) or mem[a]
            if v == x then found = a; break end
        end
        storeResult(found)
        branch(found ~= 0)
    end
    opv[24] = function() storeResult(65535 - ops[1]) end               -- not
    opv[25] = function() call(ops[1], 2, nops, false) end                -- call_vn
    opv[26] = opv[25]                                                  -- call_vn2
    opv[27] = function() -- tokenise
        tokenise(ops[1], ops[2], nops >= 3 and ops[3] or 0, nops >= 4 and ops[4] ~= 0)
    end
    opv[28] = function() -- encode_text
        local text, len, from, coded = ops[1], ops[2], ops[3], ops[4]
        local codes = {}
        for i = 0, len - 1 do codes[i + 1] = mem[text + from + i] end
        local e = encodeWord(codes, 1, len)
        for i = 1, #e do wb(coded + i - 1, sbyte(e, i)) end
    end
    opv[29] = function() -- copy_table
        local first, second, n = ops[1], ops[2], signed(ops[3])
        if second == 0 then
            for i = 0, math.abs(n) - 1 do wb(first + i, 0) end
        elseif n < 0 or first > second then
            for i = 0, math.abs(n) - 1 do wb(second + i, mem[first + i]) end
        else
            for i = n - 1, 0, -1 do wb(second + i, mem[first + i]) end
        end
    end
    opv[30] = function() -- print_table
        local t, w = ops[1], ops[2]
        local h = nops >= 3 and ops[3] or 1
        local skip = nops >= 4 and ops[4] or 0
        local r0, c0 = cur_row, cur_col
        for r = 0, h - 1 do
            if r > 0 then
                if window == 1 then cur_row, cur_col = r0 + r, c0 else printZscii(13) end
            end
            for c = 0, w - 1 do printZscii(mem[t + r * (w + skip) + c]) end
        end
    end
    opv[31] = function() branch(ops[1] <= F_argc[depth]) end              -- check_arg_count

    -- EXT ----------------------------------------------------------------
    opx[0] = function() state = "save" end
    opx[1] = function() state = "restore" end
    opx[2] = function() -- log_shift
        local n, p = ops[1], signed(ops[2])
        if p >= 0 then storeResult(lshift(n, p) % 65536) else storeResult(rshift(n, -p)) end
    end
    opx[3] = function() -- art_shift
        local n, p = signed(ops[1]), signed(ops[2])
        if p >= 0 then storeResult((n * 2 ^ p) % 65536) else storeResult(floor(n / 2 ^ (-p))) end
    end
    opx[4] = function() -- set_font
        local f = ops[1]
        if f == 0 then storeResult(vm.font or 1)
        elseif f == 1 or f == 4 then storeResult(vm.font or 1); vm.font = f
        else storeResult(0) end
    end
    opx[9] = function() -- save_undo
        local fs, s = copyFrames()
        undo_snaps[#undo_snaps + 1] = { dyn = dynBytes(), frames = fs, stack = s, pc = pc }
        if #undo_snaps > MAX_UNDO then table.remove(undo_snaps, 1) end
        storeResult(1)
    end
    opx[10] = function() -- restore_undo
        local u = undo_snaps[#undo_snaps]
        if not u then storeResult(0) return end
        undo_snaps[#undo_snaps] = nil
        local f2 = rw(0x10)
        setDyn(u.dyn)
        local fs, s = u.frames, u.stack
        setStacks(fs, s)
        ww(0x10, f2)
        pc = u.pc
        storeResult(2)
    end
    opx[11] = function() printUnicode(ops[1]) end                      -- print_unicode
    opx[12] = function() -- check_unicode
        local cp = ops[1]
        local r = 1
        if toZscii(cp) then r = 3 end
        storeResult(r)
    end
    opx[13] = function() end                                           -- set_true_colour

    -- ---------------------------------------------------------------------
    -- Operand decoding and the main loop
    -- ---------------------------------------------------------------------
    local function readOperands(types)
        for shift = 6, 0, -2 do
            local t = band(rshift(types, shift), 3)
            if t == 3 then return false end
            nops = nops + 1
            if t == 0 then
                ops[nops] = mem[pc] * 256 + mem[pc + 1]; pc = pc + 2
            elseif t == 1 then
                ops[nops] = mem[pc]; pc = pc + 1
            else
                ops[nops] = readVar(mem[pc]); pc = pc + 1
            end
        end
        return true
    end

    local function step()
        instr_pc = pc
        local op = mem[pc]; pc = pc + 1
        local h
        if op < 0x80 then
            local a, b = mem[pc], mem[pc + 1]
            pc = pc + 2
            if op >= 0x40 then a = readVar(a) end
            if op % 64 >= 32 then b = readVar(b) end
            ops[1], ops[2] = a, b
            nops = 2
            h = op2[op % 32]
        elseif op < 0xC0 then
            local t = floor(op / 16) % 4
            if t == 3 then
                nops = 0
                h = op0[op % 16]
                if (op == 0xB5 or op == 0xB6) and version >= 5 then
                    fail("illegal 0OP save/restore in v5+")
                end
            else
                nops = 1
                if t == 0 then
                    ops[1] = mem[pc] * 256 + mem[pc + 1]; pc = pc + 2
                elseif t == 1 then
                    ops[1] = mem[pc]; pc = pc + 1
                else
                    ops[1] = readVar(mem[pc]); pc = pc + 1
                end
                h = op1[op % 16]
            end
        else
            local types = mem[pc]; pc = pc + 1
            nops = 0
            if op == 0xEC or op == 0xFA then
                local types2 = mem[pc]; pc = pc + 1
                if readOperands(types) then readOperands(types2) end
            else
                readOperands(types)
            end
            if op < 0xE0 then h = op2[op % 32] else h = opv[op % 32] end
        end
        if not h then
            fail(string.format("unknown opcode 0x%02X at %d", op, instr_pc))
        end
        h()
    end

    -- The extended form (v5+) has its own decode: opcode number, then types.
    local function step2()
        local op = mem[pc]
        if op == 0xBE and version >= 5 then
            instr_pc = pc
            local xop = mem[pc + 1]
            local types = mem[pc + 2]
            pc = pc + 3
            nops = 0
            readOperands(types)
            local h = opx[xop]
            if h then h() end
            return
        end
        return step()
    end

    function vm:_run(budget)
        local n = 0
        while state == "running" do
            step2()
            n = n + 1
            if n >= budget then return false end
        end
        return true
    end

    -- ---------------------------------------------------------------------
    -- Public entry points needing the upvalues
    -- ---------------------------------------------------------------------
    function vm:_resetState()
        stk, sp = {}, 0
        F_ret, F_store, F_nl, F_argc, F_fp = { 0 }, { false }, { 0 }, { 0 }, { 0 }
        enterFrame(1)
        pc = rw(0x06)
        if version == 6 then pc = pc * 4 + routine_off end
        stream3 = {}
        stream1 = true
        window = 0
        upper_h = 0
        grid = {}
        cur_row, cur_col = 1, 1
        undo_snaps = {}
        state = "running"
        vm.pending = nil
    end

    function vm:restart()
        local f2 = rw(0x10)
        if has_ffi then ffi.copy(mem, story, size) else
            for i = 0, size - 1 do mem[i] = sbyte(story, i + 1) end
        end
        initHeader(f2)
        self:_resetState()
        self.cleared = true
        out = {}
    end

    function vm:takeOutput()
        local s = concat(out)
        out = {}
        return s
    end
    function vm:appendOutput(s) out[#out + 1] = s end

    function vm:getUpperLines()
        local lines = {}
        for r = 1, upper_h do
            local row = grid[r] or {}
            local t = {}
            local last = 0
            for c = 1, vm.cols do if row[c] and row[c] ~= " " then last = c end end
            for c = 1, last do t[c] = row[c] or " " end
            lines[r] = concat(t)
        end
        return lines
    end
    function vm:getUpperHeight() return upper_h end
    function vm:setUpper(h, lines)
        upper_h = h
        grid = {}
        for r, line in ipairs(lines or {}) do
            local row = {}
            for c, cp in ipairs(utf8codes(line)) do row[c] = utf8char(cp) end
            grid[r] = row
        end
    end

    -- v3 status line: location name, and "score/moves" or "hh:mm".
    function vm:getStatusLine()
        if version > 3 then return nil end
        local loc = readVar(16)
        local name = loc ~= 0 and self:objName(loc) or ""
        local right
        if band(mem[1], 2) ~= 0 then
            local h, m = readVar(17), readVar(18)
            local ampm = h >= 12 and "PM" or "AM"
            local h12 = h % 12; if h12 == 0 then h12 = 12 end
            right = string.format("%d:%02d %s", h12, m, ampm)
        else
            right = string.format("%d/%d", signed(readVar(17)), signed(readVar(18)))
        end
        return name, right, band(mem[1], 2) ~= 0
    end

    function vm:getPC() return pc end
    function vm:setPC(p) pc = p end
    function vm:getState() return state end
    function vm:setState(s) state = s end
    function vm:storeResult(x) storeResult(x) end
    function vm:branch(c) branch(c) end
    function vm:writeVar(v, x) writeVar(v, x) end

    -- line input
    function vm:_finishLine(codes)
        local p = self.pending
        local text, parse = p.text, p.parse
        local maxc
        if version <= 4 then maxc = mem[text] - 1 else maxc = mem[text] end
        if maxc < 0 then maxc = 0 end
        local n = math.min(#codes, maxc)
        if version <= 4 then
            for i = 1, n do wb(text + i, codes[i]) end
            wb(text + n + 1, 0)
        else
            for i = 1, n do wb(text + 1 + i, codes[i]) end
            wb(text + 1, n)
        end
        if parse ~= 0 then tokenise(text, parse, 0, false) end
        self.pending = nil
        state = "running"
        if version >= 5 then writeVar(p.store, 13) end
    end

    function vm:_finishChar(z)
        local p = self.pending
        self.pending = nil
        state = "running"
        writeVar(p.store, z)
    end

    -- Quetzal pieces
    function vm:_dynBytes() return dynBytes() end
    function vm:_setDyn(s) setDyn(s) end
    function vm:_copyFrames() return copyFrames() end
    function vm:_setStacks(fs, s) setStacks(fs, s) end
    function vm:_window() return window, cur_row, cur_col end
    function vm:_setWindow(w, r, c) window, cur_row, cur_col = w, r, c end
    function vm:_clearStream3() stream3 = {} end
end

-- ---------------------------------------------------------------------------
-- Public API (methods not needing the closures' upvalues directly)
-- ---------------------------------------------------------------------------

function ZMachine:_reset()
    self._initHeader(nil)
    self:_resetState()
end

-- Run until the machine needs something. Returns its state.
function ZMachine:run(budget)
    if self:getState() ~= "running" then return self:getState() end
    local ok, err = pcall(self._run, self, budget or 50000000)
    if not ok then
        self:setState("error")
        self.error_msg = type(err) == "table" and err.zerr or tostring(err)
        return "error"
    end
    if err == false then
        self:setState("error")
        self.error_msg = "the story ran too long without asking for input"
        return "error"
    end
    return self:getState()
end

-- Line input as UTF-8. Echoes it into the transcript, lower-cases it, maps it
-- to ZSCII (accented letters through the unicode table), runs on.
function ZMachine:sendLine(text)
    if self:getState() ~= "input" then return self:getState() end
    text = text:gsub("[\r\n]", " ")
    self:appendOutput(text .. "\n")
    local codes = {}
    for _, cp in ipairs(utf8codes(text)) do
        local z = self.toZscii(lowerCp(cp))
        codes[#codes + 1] = z or 63
    end
    local ok, err = pcall(self._finishLine, self, codes)
    if not ok then
        self:setState("error")
        self.error_msg = type(err) == "table" and err.zerr or tostring(err)
        return "error"
    end
    return self:run()
end

-- One key: a ZSCII code (13 = Enter, 129..132 = cursor keys, 27 = Escape).
function ZMachine:sendChar(z)
    if self:getState() ~= "char" then return self:getState() end
    self:_finishChar(z)
    return self:run()
end

-- ZSCII code for a single UTF-8 character typed by the user.
function ZMachine:keyToZscii(s)
    local cp = utf8codes(s)[1]
    if not cp then return 13 end
    return self.toZscii(cp) or 63
end

-- After a "save" state: report whether the file was written.
function ZMachine:finishSave(ok)
    if self:getState() ~= "save" then return self:getState() end
    self:setState("running")
    if self.version <= 3 then self:branch(ok) else self:storeResult(ok and 1 or 0) end
    return self:run()
end

-- After a "restore" state: data = Quetzal bytes, or nil if cancelled.
function ZMachine:finishRestore(data)
    if self:getState() ~= "restore" then return self:getState() end
    local Quetzal = ZMachine.Quetzal
    local ok = false
    local err
    if data then
        ok, err = Quetzal.load(self, data)
    end
    self:setState("running")
    if ok then
        -- continue at the save instruction's branch/store, "restored" = 2
        if self.version <= 3 then self:branch(true) else self:storeResult(2) end
    else
        if self.version <= 3 then self:branch(false) else self:storeResult(0) end
    end
    return self:run(), err
end

-- Quetzal image of the machine. While waiting on a save opcode the PC is the
-- save's branch/store byte (standard Quetzal). With resume = true (an
-- automatic save while waiting for input) the PC is the start of the read
-- instruction, which re-runs on load; that file carries a private chunk.
function ZMachine:saveQuetzal(resume, extra)
    return ZMachine.Quetzal.save(self, resume, extra)
end

-- Load an automatic (resume) save: returns ok, err, extra.
function ZMachine:resumeFrom(data)
    local ok, err, info = ZMachine.Quetzal.load(self, data)
    if not ok then return false, err end
    if not info.resume then return false, "not a resume file" end
    self:setState("running")
    return true, nil, info.extra
end

-- Does the story's dictionary look French? (for the shortcut buttons)
-- Words are compared truncated to 6 (v3) or 9 letters, so only words with
-- no English look-alike count, and two of them must be there.
function ZMachine:isFrench()
    local n = 0
    for _, w in ipairs({ "ouest", "nord", "prendre", "regarder", "ouvrir", "attendre" }) do
        if self:lookup(w) ~= 0 then n = n + 1 end
    end
    return n >= 2
end

-- ---------------------------------------------------------------------------
-- Quetzal (IFZS) save files -- the standard Z-machine save format, so a save
-- made here loads in Frotz, Gargoyle... and the other way round.
-- Chunks written: IFhd, CMem (XOR-RLE against the original story), Stks.
-- Automatic saves add "KoRs" (window state, upper-window text) and "KoUI"
-- (opaque data for the UI); other interpreters skip unknown chunks.
-- ---------------------------------------------------------------------------

local Quetzal = {}
ZMachine.Quetzal = Quetzal

local function be16(v) return schar(floor(v / 256) % 256, v % 256) end
local function be24(v) return schar(floor(v / 65536) % 256, floor(v / 256) % 256, v % 256) end
local function be32(v)
    return schar(floor(v / 16777216) % 256, floor(v / 65536) % 256, floor(v / 256) % 256, v % 256)
end
local function rd16(s, i) return sbyte(s, i) * 256 + sbyte(s, i + 1) end
local function rd24(s, i) return sbyte(s, i) * 65536 + sbyte(s, i + 1) * 256 + sbyte(s, i + 2) end
local function rd32(s, i)
    return ((sbyte(s, i) * 256 + sbyte(s, i + 1)) * 256 + sbyte(s, i + 2)) * 256 + sbyte(s, i + 3)
end
local function chunk(id, data)
    return id .. be32(#data) .. data .. ((#data % 2 == 1) and "\0" or "")
end

-- Values a VAR-form instruction at addr popped off the stack (operands given
-- as variable 0), in operand order -- a resumed read re-runs and pops again.
local function poppedOperands(vm, addr, ops_values)
    local mem = vm.mem
    local op = mem[addr]
    if op < 0xC0 then return {} end
    local types = mem[addr + 1]
    local a = addr + 2
    local popped = {}
    for k = 0, 3 do
        local t = floor(types / 2 ^ (6 - 2 * k)) % 4
        if t == 3 then break end
        if t == 0 then a = a + 2
        elseif t == 1 then a = a + 1
        else
            if mem[a] == 0 then popped[#popped + 1] = ops_values[k + 1] end
            a = a + 1
        end
    end
    return popped
end

function Quetzal.save(vm, resume, extra)
    local story = vm.story
    local pc = vm:getPC()
    local frames, stack = vm:_copyFrames()
    if resume then
        local p = vm.pending
        if not p then return nil, "not waiting for input" end
        pc = p.instr_pc
        -- operands the read took from the stack go back on it
        local vals = { p.text, p.parse }
        if p.kind == "char" then vals = { 1 } end
        local popped = poppedOperands(vm, pc, vals)
        for k = #popped, 1, -1 do stack[#stack + 1] = popped[k] end
    end
    local hd = story:sub(3, 4) .. story:sub(0x13, 0x18) .. story:sub(0x1D, 0x1E) .. be24(pc)

    -- CMem
    local dyn = vm:_dynBytes()
    local parts, zeros = {}, 0
    local n = #dyn
    for i = 1, n do
        local x = bxor(sbyte(dyn, i), sbyte(story, i))
        if x == 0 then
            zeros = zeros + 1
            if zeros == 256 then parts[#parts + 1] = "\0\255"; zeros = 0 end
        else
            if zeros > 0 then parts[#parts + 1] = "\0" .. schar(zeros - 1); zeros = 0 end
            parts[#parts + 1] = schar(x)
        end
    end
    local cmem = concat(parts)

    -- Stks
    local st = {}
    for i, f in ipairs(frames) do
        local top = frames[i + 1] and frames[i + 1].sp_base or #stack
        local neval = top - f.sp_base
        local flags = f.nlocals + ((f.store == nil and i > 1) and 16 or 0)
        local argmask = 0
        for k = 1, math.min(f.argc, 7) do argmask = argmask + 2 ^ (k - 1) end
        st[#st + 1] = be24(f.ret_pc) .. schar(flags) .. schar(f.store or 0)
                      .. schar(argmask) .. be16(neval)
        for k = 1, f.nlocals do st[#st + 1] = be16(f.locals[k]) end
        for k = f.sp_base + 1, top do st[#st + 1] = be16(stack[k]) end
    end

    local body = chunk("IFhd", hd) .. chunk("CMem", cmem) .. chunk("Stks", concat(st))
    if resume then
        local w, r, c = vm:_window()
        local lines = vm:getUpperLines()
        body = body .. chunk("KoRs", string.format("%d %d %d %d\n", w, r, c, vm:getUpperHeight())
                                      .. concat(lines, "\n"))
        if extra then body = body .. chunk("KoUI", extra) end
    end
    return "FORM" .. be32(4 + #body) .. "IFZS" .. body
end

function Quetzal.load(vm, data)
    if type(data) ~= "string" or #data < 12 or data:sub(1, 4) ~= "FORM" or data:sub(9, 12) ~= "IFZS" then
        return false, "not a Quetzal save file"
    end
    local story = vm.story
    local chunks = {}
    local i, total = 13, math.min(#data, rd32(data, 5) + 8)
    while i + 7 <= total do
        local id, len = data:sub(i, i + 3), rd32(data, i + 4)
        if not chunks[id] then chunks[id] = data:sub(i + 8, i + 7 + len) end
        i = i + 8 + len + (len % 2)
    end
    local hd = chunks.IFhd
    if not hd or #hd < 13 then return false, "missing header chunk" end
    if hd:sub(1, 2) ~= story:sub(3, 4) or hd:sub(3, 8) ~= story:sub(0x13, 0x18)
       or hd:sub(9, 10) ~= story:sub(0x1D, 0x1E) then
        return false, "this save belongs to another story"
    end
    local pc = rd24(hd, 11)
    local static_base = vm.static_base

    -- memory
    local dyn
    if chunks.CMem then
        local c = chunks.CMem
        local out, pos, j = {}, 0, 1
        while j <= #c and pos < static_base do
            local b = sbyte(c, j)
            if b == 0 then
                local run = (sbyte(c, j + 1) or 0) + 1
                for _ = 1, run do
                    if pos >= static_base then break end
                    out[#out + 1] = story:sub(pos + 1, pos + 1)
                    pos = pos + 1
                end
                j = j + 2
            else
                out[#out + 1] = schar(bxor(b, sbyte(story, pos + 1)))
                pos = pos + 1
                j = j + 1
            end
        end
        if pos < static_base then out[#out + 1] = story:sub(pos + 1, static_base) end
        dyn = concat(out)
    elseif chunks.UMem and #chunks.UMem >= static_base then
        dyn = chunks.UMem:sub(1, static_base)
    else
        return false, "missing memory chunk"
    end

    -- stacks
    local s = chunks.Stks
    if not s then return false, "missing stack chunk" end
    local frames, stack = {}, {}
    local j = 1
    while j + 7 <= #s do
        local ret_pc = rd24(s, j)
        local flags = sbyte(s, j + 3)
        local var = sbyte(s, j + 4)
        local argmask = sbyte(s, j + 5)
        local neval = rd16(s, j + 6)
        j = j + 8
        local nl = flags % 16
        local l = {}
        for k = 1, nl do l[k] = rd16(s, j); j = j + 2 end
        local argc = 0
        while argmask % 2 == 1 do argc = argc + 1; argmask = floor(argmask / 2) end
        local f = { ret_pc = ret_pc, store = (floor(flags / 16) % 2 == 1) and nil or var,
                    nlocals = nl, argc = argc, sp_base = #stack, locals = l }
        if #frames == 0 then f.store = nil end
        for _ = 1, neval do stack[#stack + 1] = rd16(s, j); j = j + 2 end
        frames[#frames + 1] = f
    end
    if #frames == 0 then return false, "empty stack chunk" end

    local f2 = vm.rw(0x10)
    vm:_setDyn(dyn)
    vm._initHeader(f2)
    vm:_setStacks(frames, stack)
    vm:setPC(pc)
    vm:_clearStream3()
    vm.pending = nil

    local info = {}
    if chunks.KoRs then
        info.resume = true
        local head, rest = chunks.KoRs:match("^([^\n]*)\n?(.*)$")
        local w, r, c, h = head:match("(%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+)")
        local lines = {}
        if rest and rest ~= "" then
            for line in (rest .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
        end
        vm:setUpper(tonumber(h) or 0, lines)
        vm:_setWindow(tonumber(w) or 0, tonumber(r) or 1, tonumber(c) or 1)
        info.extra = chunks.KoUI
    else
        vm:setUpper(vm:getUpperHeight(), vm:getUpperLines())
    end
    return true, nil, info
end

return ZMachine
