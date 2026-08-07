--!strict
-- metatable_heavy.luau
-- Designed to stress every metatable path a minifier/CST tool might encounter

--------------------------------------------------------------------------------
-- SECTION 1: Proxy / read-write intercept
--------------------------------------------------------------------------------

local function makeProxy(target: { [string]: any }, onChange: (key: string, old: any, new: any) -> ()): { [string]: any }
    local proxy = {}
    local mt = {}

    mt.__index = function(_, key: string): any
        return target[key]
    end

    mt.__newindex = function(_, key: string, value: any): ()
        local old = target[key]
        target[key] = value
        onChange(key, old, value)
    end

    mt.__len = function(_): number
        return #target
    end

    mt.__pairs = function(_)
        return next, target, nil
    end

    mt.__tostring = function(_): string
        local parts = {}
        for k, v in pairs(target) do
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
        return "Proxy{" .. table.concat(parts, ", ") .. "}"
    end

    setmetatable(proxy, mt)
    return proxy
end

local log: { string } = {}
local data: { [string]: any } = { hp = 100, name = "hero" }
local reactive = makeProxy(data, function(key, old, new)
    log[#log + 1] = key .. ": " .. tostring(old) .. " -> " .. tostring(new)
end)

reactive.hp = 80
reactive.name = "villain"
reactive.level = 5

--------------------------------------------------------------------------------
-- SECTION 2: __index chain (deep prototype inheritance)
--------------------------------------------------------------------------------

local Base = {}
Base.__index = Base

function Base.new(name: string)
    return setmetatable({ _name = name, _tag = "base" }, Base)
end

function Base:getName(): string
    return self._name
end

function Base:getTag(): string
    return self._tag
end

function Base:describe(): string
    return string.format("[%s] %s", self:getTag(), self:getName())
end

function Base:__tostring(): string
    return self:describe()
end

-- Level 2
local Entity = setmetatable({}, { __index = Base })
Entity.__index = Entity

function Entity.new(name: string, id: number)
    local self = Base.new(name)
    self._id = id
    self._tag = "entity"
    return setmetatable(self, Entity)
end

function Entity:getId(): number
    return self._id
end

function Entity:describe(): string
    return string.format("[%s#%d] %s", self:getTag(), self:getId(), self:getName())
end

-- Level 3
local Creature = setmetatable({}, { __index = Entity })
Creature.__index = Creature

function Creature.new(name: string, id: number, hp: number, mp: number)
    local self = Entity.new(name, id) :: any
    self._hp = hp
    self._mp = mp
    self._tag = "creature"
    self._buffs = {}
    return setmetatable(self, Creature)
end

function Creature:getHp(): number  return self._hp end
function Creature:getMp(): number  return self._mp end
function Creature:isAlive(): boolean  return self._hp > 0 end

function Creature:applyBuff(name: string, amount: number): ()
    self._buffs[name] = (self._buffs[name] or 0) + amount
    self._hp += amount
end

function Creature:describe(): string
    return string.format("[%s#%d] %s | HP:%d MP:%d", self:getTag(), self:getId(), self:getName(), self._hp, self._mp)
end

-- Level 4
local Hero = setmetatable({}, { __index = Creature })
Hero.__index = Hero

function Hero.new(name: string, id: number, hp: number, mp: number, class: string)
    local self = Creature.new(name, id, hp, mp) :: any
    self._class = class
    self._xp = 0
    self._level = 1
    self._skills = {}
    self._tag = "hero"
    return setmetatable(self, Hero)
end

function Hero:getClass(): string  return self._class end
function Hero:getLevel(): number  return self._level end
function Hero:getXp(): number  return self._xp end

function Hero:gainXp(amount: number): boolean
    self._xp += amount
    if self._xp >= self._level * 100 then
        self._xp -= self._level * 100
        self._level += 1
        self._hp += 10
        self._mp += 5
        return true -- leveled up
    end
    return false
end

function Hero:learnSkill(skill: string): ()
    self._skills[#self._skills + 1] = skill
end

function Hero:describe(): string
    return string.format("[%s Lv%d] %s | HP:%d MP:%d | XP:%d/%d",
        self._class, self._level, self:getName(),
        self._hp, self._mp, self._xp, self._level * 100)
end

function Hero:__tostring(): string
    return self:describe()
end

--------------------------------------------------------------------------------
-- SECTION 3: Operator overloading suite
--------------------------------------------------------------------------------

-- Matrix2x2
local Mat2 = {}
Mat2.__index = Mat2

export type Mat2 = typeof(setmetatable({} :: {
    m00: number, m01: number,
    m10: number, m11: number,
}, Mat2))

function Mat2.new(m00: number, m01: number, m10: number, m11: number): Mat2
    return setmetatable({ m00 = m00, m01 = m01, m10 = m10, m11 = m11 }, Mat2) :: any
end

function Mat2.identity(): Mat2
    return Mat2.new(1, 0, 0, 1)
end

function Mat2.zero(): Mat2
    return Mat2.new(0, 0, 0, 0)
end

function Mat2.__add(a: Mat2, b: Mat2): Mat2
    return Mat2.new(a.m00 + b.m00, a.m01 + b.m01, a.m10 + b.m10, a.m11 + b.m11)
end

function Mat2.__sub(a: Mat2, b: Mat2): Mat2
    return Mat2.new(a.m00 - b.m00, a.m01 - b.m01, a.m10 - b.m10, a.m11 - b.m11)
end

function Mat2.__mul(a: Mat2, b: Mat2 | number): Mat2
    if type(b) == "number" then
        return Mat2.new(a.m00 * b, a.m01 * b, a.m10 * b, a.m11 * b)
    end
    local bm = b :: Mat2
    return Mat2.new(
        a.m00 * bm.m00 + a.m01 * bm.m10,
        a.m00 * bm.m01 + a.m01 * bm.m11,
        a.m10 * bm.m00 + a.m11 * bm.m10,
        a.m10 * bm.m01 + a.m11 * bm.m11
    )
end

function Mat2.__unm(a: Mat2): Mat2
    return Mat2.new(-a.m00, -a.m01, -a.m10, -a.m11)
end

function Mat2.__eq(a: Mat2, b: Mat2): boolean
    return a.m00 == b.m00 and a.m01 == b.m01 and a.m10 == b.m10 and a.m11 == b.m11
end

function Mat2.__concat(a: Mat2, b: Mat2): string
    return tostring(a) .. " | " .. tostring(b)
end

function Mat2.__len(a: Mat2): number
    return 4 -- always 4 elements
end

function Mat2:det(): number
    return self.m00 * self.m11 - self.m01 * self.m10
end

function Mat2:transpose(): Mat2
    return Mat2.new(self.m00, self.m10, self.m01, self.m11)
end

function Mat2:inverse(): Mat2?
    local d = self:det()
    if d == 0 then return nil end
    return Mat2.new(self.m11 / d, -self.m01 / d, -self.m10 / d, self.m00 / d)
end

function Mat2:trace(): number
    return self.m00 + self.m11
end

function Mat2:__tostring(): string
    return string.format("[[%g, %g], [%g, %g]]", self.m00, self.m01, self.m10, self.m11)
end

-- Callable table
function Mat2:__call(x: number, y: number): (number, number)
    return self.m00 * x + self.m01 * y, self.m10 * x + self.m11 * y
end

--------------------------------------------------------------------------------
-- SECTION 4: __index as function (computed properties)
--------------------------------------------------------------------------------

local function makeComputed(base: { [string]: number }): { [string]: any }
    local meta = {}
    local derived: { [string]: (t: { [string]: number }) -> any } = {
        sum    = function(t) local s = 0; for _, v in pairs(t) do s += v end; return s end,
        mean   = function(t)
            local s, n = 0, 0
            for _, v in pairs(t) do s += v; n += 1 end
            return n > 0 and s / n or 0
        end,
        min    = function(t)
            local m = math.huge
            for _, v in pairs(t) do if v < m then m = v end end
            return m
        end,
        max    = function(t)
            local m = -math.huge
            for _, v in pairs(t) do if v > m then m = v end end
            return m
        end,
        count  = function(t)
            local n = 0
            for _ in pairs(t) do n += 1 end
            return n
        end,
    }

    meta.__index = function(self, key: string): any
        if derived[key] then
            return derived[key](base)
        end
        return base[key]
    end

    meta.__newindex = function(_, key: string, value: any): ()
        base[key] = value
    end

    meta.__tostring = function(_): string
        local parts = {}
        for k, v in pairs(base) do
            parts[#parts + 1] = k .. "=" .. v
        end
        return "Computed{" .. table.concat(parts, ",") .. "}"
    end

    return setmetatable({}, meta)
end

local stats = makeComputed({ a = 10, b = 20, c = 30, d = 5, e = 15 })
local _ = stats.sum    -- 80
local _ = stats.mean   -- 16
local _ = stats.min    -- 5
local _ = stats.max    -- 30
stats.f = 100

--------------------------------------------------------------------------------
-- SECTION 5: __newindex write trap + frozen table simulation
--------------------------------------------------------------------------------

local function makeFrozen(t: { [string]: any }): { [string]: any }
    local frozen = {}
    setmetatable(frozen, {
        __index    = t,
        __newindex = function(_, key: string, _value: any)
            error(string.format("attempt to write to frozen key '%s'", tostring(key)), 2)
        end,
        __len      = function() return #t end,
        __tostring = function()
            return "Frozen(" .. tostring(t) .. ")"
        end,
        __pairs    = function()
            return next, t, nil
        end,
    })
    return frozen
end

local config = makeFrozen({ version = "1.0.0", debug = false, maxPlayers = 20 })
local ver = config.version   -- ok
local ok, err = pcall(function()
    config.version = "2.0.0" -- should error
end)

--------------------------------------------------------------------------------
-- SECTION 6: __call — callable objects / functors
--------------------------------------------------------------------------------

local function makeAccumulator(initial: number): any
    local state = { value = initial, history = {} :: { number } }
    return setmetatable(state, {
        __call = function(self, n: number): number
            self.history[#self.history + 1] = self.value
            self.value += n
            return self.value
        end,
        __tostring = function(self): string
            return string.format("Acc(%d, history=%d)", self.value, #self.history)
        end,
        __unm = function(self): any
            return makeAccumulator(-self.value)
        end,
        __len = function(self): number
            return #self.history
        end,
    })
end

local acc = makeAccumulator(0)
acc(10)
acc(20)
acc(-5)
acc(100)
local total = acc.value -- 125

--------------------------------------------------------------------------------
-- SECTION 7: Weak tables (__mode)
--------------------------------------------------------------------------------

local function makeWeakCache<K, V>(): { [K]: V }
    return setmetatable({} :: { [K]: V }, { __mode = "v" }) -- weak values
end

local function makeWeakSet<K>(): { [K]: boolean }
    return setmetatable({} :: { [K]: boolean }, { __mode = "k" }) -- weak keys
end

local cache: { [string]: {} } = makeWeakCache()
local tracked: { [{}]: boolean } = makeWeakSet()

local obj1 = {}
local obj2 = {}
cache["key1"] = obj1
cache["key2"] = obj2
tracked[obj1] = true
tracked[obj2] = true

--------------------------------------------------------------------------------
-- SECTION 8: Chained metamethod dispatch (Vec3 full suite)
--------------------------------------------------------------------------------

local Vec3 = {}
Vec3.__index = Vec3

export type Vec3 = typeof(setmetatable({} :: { x: number, y: number, z: number }, Vec3))

function Vec3.new(x: number, y: number, z: number): Vec3
    return setmetatable({ x = x, y = y, z = z }, Vec3) :: any
end

function Vec3.zero(): Vec3   return Vec3.new(0, 0, 0) end
function Vec3.one(): Vec3    return Vec3.new(1, 1, 1) end
function Vec3.right(): Vec3  return Vec3.new(1, 0, 0) end
function Vec3.up(): Vec3     return Vec3.new(0, 1, 0) end
function Vec3.forward(): Vec3 return Vec3.new(0, 0, 1) end

function Vec3.__add(a: Vec3, b: Vec3): Vec3
    return Vec3.new(a.x + b.x, a.y + b.y, a.z + b.z)
end

function Vec3.__sub(a: Vec3, b: Vec3): Vec3
    return Vec3.new(a.x - b.x, a.y - b.y, a.z - b.z)
end

function Vec3.__mul(a: Vec3 | number, b: Vec3 | number): Vec3
    if type(a) == "number" then
        local bv = b :: Vec3
        return Vec3.new(a * bv.x, a * bv.y, a * bv.z)
    elseif type(b) == "number" then
        local av = a :: Vec3
        return Vec3.new(av.x * b, av.y * b, av.z * b)
    end
    local av, bv = a :: Vec3, b :: Vec3
    return Vec3.new(av.x * bv.x, av.y * bv.y, av.z * bv.z)
end

function Vec3.__div(a: Vec3, b: Vec3 | number): Vec3
    if type(b) == "number" then
        return Vec3.new(a.x / b, a.y / b, a.z / b)
    end
    local bv = b :: Vec3
    return Vec3.new(a.x / bv.x, a.y / bv.y, a.z / bv.z)
end

function Vec3.__mod(a: Vec3, b: number): Vec3
    return Vec3.new(a.x % b, a.y % b, a.z % b)
end

function Vec3.__pow(a: Vec3, b: number): Vec3
    return Vec3.new(a.x ^ b, a.y ^ b, a.z ^ b)
end

function Vec3.__unm(a: Vec3): Vec3
    return Vec3.new(-a.x, -a.y, -a.z)
end

function Vec3.__eq(a: Vec3, b: Vec3): boolean
    return a.x == b.x and a.y == b.y and a.z == b.z
end

function Vec3.__lt(a: Vec3, b: Vec3): boolean
    return a:lengthSq() < b:lengthSq()
end

function Vec3.__le(a: Vec3, b: Vec3): boolean
    return a:lengthSq() <= b:lengthSq()
end

function Vec3.__concat(a: Vec3, b: Vec3): string
    return tostring(a) .. " -> " .. tostring(b)
end

function Vec3.__len(a: Vec3): number
    return math.sqrt(a.x^2 + a.y^2 + a.z^2)
end

function Vec3.__tostring(a: Vec3): string
    return string.format("(%g, %g, %g)", a.x, a.y, a.z)
end

function Vec3:lengthSq(): number
    return self.x^2 + self.y^2 + self.z^2
end

function Vec3:length(): number
    return math.sqrt(self:lengthSq())
end

function Vec3:normalize(): Vec3
    local len = self:length()
    if len == 0 then return Vec3.zero() end
    return self / len
end

function Vec3:dot(other: Vec3): number
    return self.x * other.x + self.y * other.y + self.z * other.z
end

function Vec3:cross(other: Vec3): Vec3
    return Vec3.new(
        self.y * other.z - self.z * other.y,
        self.z * other.x - self.x * other.z,
        self.x * other.y - self.y * other.x
    )
end

function Vec3:lerp(other: Vec3, t: number): Vec3
    return self + (other - self) * t
end

function Vec3:reflect(normal: Vec3): Vec3
    return self - normal * (2 * self:dot(normal))
end

function Vec3:project(onto: Vec3): Vec3
    local d = onto:dot(onto)
    if d == 0 then return Vec3.zero() end
    return onto * (self:dot(onto) / d)
end

function Vec3:angle(other: Vec3): number
    local denom = self:length() * other:length()
    if denom == 0 then return 0 end
    return math.acos(math.clamp(self:dot(other) / denom, -1, 1))
end

function Vec3:abs(): Vec3
    return Vec3.new(math.abs(self.x), math.abs(self.y), math.abs(self.z))
end

function Vec3:floor(): Vec3
    return Vec3.new(math.floor(self.x), math.floor(self.y), math.floor(self.z))
end

function Vec3:ceil(): Vec3
    return Vec3.new(math.ceil(self.x), math.ceil(self.y), math.ceil(self.z))
end

function Vec3:max(other: Vec3): Vec3
    return Vec3.new(math.max(self.x, other.x), math.max(self.y, other.y), math.max(self.z, other.z))
end

function Vec3:min(other: Vec3): Vec3
    return Vec3.new(math.min(self.x, other.x), math.min(self.y, other.y), math.min(self.z, other.z))
end

function Vec3:clamp(minV: Vec3, maxV: Vec3): Vec3
    return Vec3.new(
        math.clamp(self.x, minV.x, maxV.x),
        math.clamp(self.y, minV.y, maxV.y),
        math.clamp(self.z, minV.z, maxV.z)
    )
end

function Vec3:unpack(): (number, number, number)
    return self.x, self.y, self.z
end

--------------------------------------------------------------------------------
-- SECTION 9: Observable / event system using metatables
--------------------------------------------------------------------------------

export type Signal<T> = {
    connect: (self: Signal<T>, fn: (T) -> ()) -> () -> (),
    fire:    (self: Signal<T>, value: T) -> (),
    once:    (self: Signal<T>, fn: (T) -> ()) -> (),
    clear:   (self: Signal<T>) -> (),
    count:   (self: Signal<T>) -> number,
}

local Signal = {}
Signal.__index = Signal

function Signal.new<T>(): Signal<T>
    local self = {
        _listeners = {} :: { (T) -> () },
    }
    return setmetatable(self, Signal) :: any
end

function Signal:connect<T>(fn: (T) -> ()): () -> ()
    local listeners = self._listeners
    listeners[#listeners + 1] = fn
    local alive = true
    return function()
        if not alive then return end
        alive = false
        for i, v in ipairs(listeners) do
            if v == fn then
                table.remove(listeners, i)
                break
            end
        end
    end
end

function Signal:once<T>(fn: (T) -> ()): ()
    local disconnect: (() -> ())?
    disconnect = self:connect(function(value: T)
        if disconnect then disconnect() end
        fn(value)
    end)
end

function Signal:fire<T>(value: T): ()
    for _, fn in ipairs(self._listeners) do
        fn(value)
    end
end

function Signal:clear(): ()
    self._listeners = {}
end

function Signal:count(): number
    return #self._listeners
end

function Signal:__tostring(): string
    return string.format("Signal<%d listeners>", self:count())
end

function Signal:__len(): number
    return self:count()
end

function Signal:__call<T>(value: T): ()
    self:fire(value)
end

--------------------------------------------------------------------------------
-- SECTION 10: __index fallback chain building (mixin system)
--------------------------------------------------------------------------------

local function mixin(target: { [string]: any }, ...: { [string]: any }): { [string]: any }
    local sources = { ... }
    local mt = getmetatable(target) :: { [string]: any }?
    if not mt then
        mt = {}
        setmetatable(target, mt)
    end
    local prev = mt.__index

    mt.__index = function(t: any, k: string): any
        for _, src in ipairs(sources) do
            local v = src[k]
            if v ~= nil then return v end
        end
        if type(prev) == "function" then
            return prev(t, k)
        elseif type(prev) == "table" then
            return prev[k]
        end
        return nil
    end

    return target
end

local Serializable = {
    serialize = function(self: any): string
        local parts = {}
        for k, v in pairs(self) do
            if type(v) ~= "function" then
                parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
            end
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ",") .. "}"
    end,
}

local Printable = {
    print = function(self: any): ()
        print(tostring(self))
    end,
}

local Cloneable = {
    clone = function(self: any): any
        local copy = {}
        for k, v in pairs(self) do
            copy[k] = v
        end
        return setmetatable(copy, getmetatable(self))
    end,
}

local Comparable = {
    equals = function(self: any, other: any): boolean
        for k, v in pairs(self) do
            if type(v) ~= "function" and other[k] ~= v then
                return false
            end
        end
        return true
    end,
}

local thing = mixin({ x = 1, y = 2, z = 3 }, Serializable, Printable, Cloneable, Comparable)
local s = thing:serialize()
local clone = thing:clone()
local eq = thing:equals(clone)

--------------------------------------------------------------------------------
-- SECTION 11: __index with rawget/rawset bypass
--------------------------------------------------------------------------------

local function makeValidated(schema: { [string]: string }): { [string]: any }
    local internal: { [string]: any } = {}
    return setmetatable({}, {
        __index = function(_, key: string): any
            return rawget(internal, key)
        end,
        __newindex = function(_, key: string, value: any): ()
            local expected = schema[key]
            if expected == nil then
                error(string.format("unknown field '%s'", key), 2)
            end
            if type(value) ~= expected then
                error(string.format("field '%s' expects %s, got %s", key, expected, type(value)), 2)
            end
            rawset(internal, key, value)
        end,
        __tostring = function(): string
            local parts = {}
            for k in pairs(schema) do
                parts[#parts + 1] = k .. "=" .. tostring(rawget(internal, k))
            end
            return "Validated{" .. table.concat(parts, ", ") .. "}"
        end,
        __len = function(): number
            local n = 0
            for _ in pairs(internal) do n += 1 end
            return n
        end,
        __pairs = function()
            return next, internal, nil
        end,
    })
end

local player = makeValidated({ name = "string", health = "number", alive = "boolean" })
player.name = "Ada"
player.health = 100
player.alive = true

local badWrite = pcall(function() player.health = "lots" end)  -- type mismatch
local unknownKey = pcall(function() player.mana = 50 end)      -- unknown field

--------------------------------------------------------------------------------
-- SECTION 12: __iter (Luau-specific, 0.6+)
--------------------------------------------------------------------------------

local function makeRange(from: number, to: number, step: number?)
    local s = step or 1
    return setmetatable({}, {
        __iter = function()
            local i = from - s
            return function(): number?
                i += s
                if (s > 0 and i <= to) or (s < 0 and i >= to) then
                    return i
                end
                return nil
            end
        end,
        __len = function(): number
            return math.max(0, math.floor((to - from) / s) + 1)
        end,
        __tostring = function(): string
            return string.format("Range(%d..%d step %d)", from, to, s)
        end,
    })
end

local r = makeRange(1, 10)
local rr = makeRange(10, 1, -1)
local rs = makeRange(0, 100, 5)

local rangeSum = 0
for n in r do
    rangeSum += n
end

--------------------------------------------------------------------------------
-- SECTION 13: Deeply nested metatables (table of proxied tables)
--------------------------------------------------------------------------------

local function makeNamespace(): { [string]: any }
    local modules: { [string]: any } = {}
    return setmetatable({}, {
        __index = function(_, key: string): any
            if not modules[key] then
                -- auto-create sub-namespace on access
                modules[key] = makeNamespace()
            end
            return modules[key]
        end,
        __newindex = function(_, key: string, value: any): ()
            modules[key] = value
        end,
        __tostring = function(): string
            local parts = {}
            for k in pairs(modules) do
                parts[#parts + 1] = k
            end
            table.sort(parts)
            return "NS{" .. table.concat(parts, ", ") .. "}"
        end,
        __len = function(): number
            local n = 0
            for _ in pairs(modules) do n += 1 end
            return n
        end,
        __pairs = function()
            return next, modules, nil
        end,
    })
end

local NS = makeNamespace()
NS.Math = { pi = math.pi, tau = math.pi * 2 }
NS.String.Utils = { upper = string.upper, lower = string.lower }
NS.Game.Players.spawn = function() end
NS.Game.Players.despawn = function() end
NS.Game.World.gravity = -196.2

-- Auto-created sub-namespace
local _ = NS.Game.Physics.enabled   -- creates NS.Game.Physics lazily

--------------------------------------------------------------------------------
-- SECTION 14: Metamethod stress expressions
--------------------------------------------------------------------------------

do
    local a = Vec3.new(1, 2, 3)
    local b = Vec3.new(4, 5, 6)
    local c = Vec3.new(0, 1, 0)

    -- All metamethods exercised in one expression cluster
    local add     = a + b
    local sub     = a - b
    local mul     = a * 2
    local mulL    = 2 * a
    local div     = b / 2
    local mod     = b % 3
    local pow     = a ^ 2
    local neg     = -a
    local eq      = a == Vec3.new(1, 2, 3)
    local lt      = a < b
    local le      = a <= b
    local cat     = a .. b
    local len     = #a      -- calls __len -> actual Lua length op
    local str     = tostring(a)

    -- Method chaining
    local result = a:normalize():cross(b:normalize()):lerp(c, 0.5):reflect(Vec3.up())
    local angle  = a:angle(b)
    local proj   = a:project(b)

    -- Mat2 metamethods
    local m1 = Mat2.new(1, 2, 3, 4)
    local m2 = Mat2.new(5, 6, 7, 8)
    local mAdd  = m1 + m2
    local mSub  = m1 - m2
    local mMul  = m1 * m2
    local mScl  = m1 * 3
    local mNeg  = -m1
    local mEq   = m1 == Mat2.new(1, 2, 3, 4)
    local mCat  = m1 .. m2
    local mLen  = #m1          -- 4
    local mStr  = tostring(m1)
    local ox, oy = m1(1, 0)   -- __call
    local inv   = m1:inverse()
    local tr    = m1:transpose()
    local det   = m1:det()
end

--------------------------------------------------------------------------------
-- Module export
--------------------------------------------------------------------------------

return {
    -- Classes
    Base            = Base,
    Entity          = Entity,
    Creature        = Creature,
    Hero            = Hero,
    Vec3            = Vec3,
    Mat2            = Mat2,
    Signal          = Signal,

    -- Factories
    makeProxy       = makeProxy,
    makeComputed    = makeComputed,
    makeFrozen      = makeFrozen,
    makeAccumulator = makeAccumulator,
    makeValidated   = makeValidated,
    makeNamespace   = makeNamespace,
    makeRange       = makeRange,
    makeWeakCache   = makeWeakCache,
    makeWeakSet     = makeWeakSet,
    mixin           = mixin,

    -- Mixins
    Serializable    = Serializable,
    Printable       = Printable,
    Cloneable       = Cloneable,
    Comparable      = Comparable,
}
