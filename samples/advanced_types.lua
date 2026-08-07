-- minifier_test.luau
-- Designed to stress-test a Luau minifier

--// Types
export type Vector2 = { x: number, y: number }
export type Vector3 = { x: number, y: number, z: number }
export type Callback<T> = (value: T) -> ()
export type Maybe<T> = T?
export type Result<T, E> = { ok: true, value: T } | { ok: false, err: E }
export type NumberMap = { [string]: number }
export type Predicate<T> = (T) -> boolean

type InternalState = {
    count: number,
    label: string,
    active: boolean,
}

--// Constants
local MAX_ITERATIONS: number = 1000
local DEFAULT_LABEL: string = "default"
local PI: number = 3.14159265358979
local EMPTY: {} = {}

--// @native functions
@native
local function addInts(a: number, b: number): number
    return a + b
end

@native
local function mulVec2(a: Vector2, b: Vector2): Vector2
    return { x = a.x * b.x, y = a.y * b.y }
end

@native
local function clamp(value: number, min: number, max: number): number
    if value < min then
        return min
    elseif value > max then
        return max
    end
    return value
end

@native
local function dotProduct(a: Vector3, b: Vector3): number
    return a.x * b.x + a.y * b.y + a.z * b.z
end

--// Generic functions
local function identity<T>(value: T): T
    return value
end

local function map<T, U>(list: { T }, fn: (T) -> U): { U }
    local result: { U } = {}
    for i, v in ipairs(list) do
        result[i] = fn(v)
    end
    return result
end

local function filter<T>(list: { T }, pred: Predicate<T>): { T }
    local result: { T } = {}
    for _, v in ipairs(list) do
        if pred(v) then
            result[#result + 1] = v
        end
    end
    return result
end

local function reduce<T, U>(list: { T }, init: U, fn: (U, T) -> U): U
    local acc = init
    for _, v in ipairs(list) do
        acc = fn(acc, v)
    end
    return acc
end

local function find<T>(list: { T }, pred: Predicate<T>): Maybe<T>
    for _, v in ipairs(list) do
        if pred(v) then return v end
    end
    return nil
end

--// String utilities (useless but varied)
local function trim(s: string): string
    return s:match("^%s*(.-)%s*$") or s
end

local function startsWith(s: string, prefix: string): boolean
    return s:sub(1, #prefix) == prefix
end

local function endsWith(s: string, suffix: string): boolean
    return s:sub(-#suffix) == suffix
end

local function split(s: string, sep: string): { string }
    local parts: { string } = {}
    local pattern = "([^" .. sep .. "]+)"
    for part in s:gmatch(pattern) do
        parts[#parts + 1] = part
    end
    return parts
end

local function repeat_str(s: string, n: number): string
    local result = ""
    for _ = 1, n do
        result ..= s
    end
    return result
end

--// Math utilities
@native
local function lerp(a: number, b: number, t: number): number
    return a + (b - a) * t
end

@native
local function sign(n: number): number
    if n > 0 then return 1
    elseif n < 0 then return -1
    else return 0
    end
end

local function isPrime(n: number): boolean
    if n < 2 then return false end
    if n == 2 then return true end
    if n % 2 == 0 then return false end
    local i = 3
    while i * i <= n do
        if n % i == 0 then return false end
        i += 2
    end
    return true
end

local function fibonacci(n: number): number
    if n <= 1 then return n end
    local a, b = 0, 1
    for _ = 2, n do
        a, b = b, a + b
    end
    return b
end

local function factorial(n: number): number
    local result = 1
    for i = 2, n do
        result *= i
    end
    return result
end

--// Table utilities
local function shallowCopy<T>(t: { T }): { T }
    local copy: { T } = {}
    for k, v in pairs(t :: any) do
        (copy :: any)[k] = v
    end
    return copy
end

local function keys(t: { [string]: any }): { string }
    local result: { string } = {}
    for k in pairs(t) do
        result[#result + 1] = k
    end
    return result
end

local function values<T>(t: { [string]: T }): { T }
    local result: { T } = {}
    for _, v in pairs(t) do
        result[#result + 1] = v
    end
    return result
end

local function tableContains<T>(t: { T }, value: T): boolean
    for _, v in ipairs(t) do
        if v == value then return true end
    end
    return false
end

local function mergeInto(target: { [string]: any }, source: { [string]: any }): ()
    for k, v in pairs(source) do
        target[k] = v
    end
end

--// State machine (more complex structure)
type StateId = string
type Transition = { from: StateId, to: StateId, on: string }

export type StateMachine = {
    current: StateId,
    transitions: { Transition },
    send: (self: StateMachine, event: string) -> boolean,
    reset: (self: StateMachine) -> (),
}

local function createStateMachine(initial: StateId, transitions: { Transition }): StateMachine
    local self: StateMachine = {
        current = initial,
        transitions = transitions,
        send = function(sm, event)
            for _, t in ipairs(sm.transitions) do
                if t.from == sm.current and t.on == event then
                    sm.current = t.to
                    return true
                end
            end
            return false
        end,
        reset = function(sm)
            sm.current = initial
        end,
    }
    return self
end

--// Coroutine wrapper
local function async<T>(fn: () -> T): () -> Maybe<T>
    local co = coroutine.create(fn)
    return function(): Maybe<T>
        local ok, val = coroutine.resume(co)
        if ok then
            return val :: Maybe<T>
        end
        return nil
    end
end

local function sleep(seconds: number): ()
    local start = os.clock()
    while os.clock() - start < seconds do
        coroutine.yield()
    end
end

--// Class-like OOP (common Roblox pattern)
export type Counter = {
    value: number,
    increment: (self: Counter, by: number?) -> (),
    decrement: (self: Counter, by: number?) -> (),
    reset: (self: Counter) -> (),
    get: (self: Counter) -> number,
}

local Counter = {}
Counter.__index = Counter

function Counter.new(initial: number?): Counter
    return setmetatable({ value = initial or 0 }, Counter) :: any
end

function Counter:increment(by: number?)
    self.value += by or 1
end

function Counter:decrement(by: number?)
    self.value -= by or 1
end

function Counter:reset()
    self.value = 0
end

function Counter:get(): number
    return self.value
end

--// Bitwise ops (Luau 5.2+ style)
@native
local function packFlags(a: boolean, b: boolean, c: boolean, d: boolean): number
    local result = 0
    if a then result = bit32.bor(result, 0x1) end
    if b then result = bit32.bor(result, 0x2) end
    if c then result = bit32.bor(result, 0x4) end
    if d then result = bit32.bor(result, 0x8) end
    return result
end

@native
local function hasFlag(flags: number, flag: number): boolean
    return bit32.band(flags, flag) ~= 0
end

--// Varargs
local function sum(...: number): number
    local total = 0
    for _, n in ipairs({...}) do
        total += n
    end
    return total
end

local function formatAll(sep: string, ...: any): string
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    return table.concat(parts, sep)
end

--// pcall / error handling
local function safeDiv(a: number, b: number): Result<number, string>
    if b == 0 then
        return { ok = false, err = "division by zero" }
    end
    return { ok = true, value = a / b }
end

local function tryParse(s: string): Result<number, string>
    local n = tonumber(s)
    if n then
        return { ok = true, value = n }
    end
    return { ok = false, err = "not a number: " .. s }
end

--// Metatables with arithmetic
local Vec2 = {}
Vec2.__index = Vec2

function Vec2.new(x: number, y: number)
    return setmetatable({ x = x, y = y }, Vec2)
end

function Vec2.__add(a: any, b: any)
    return Vec2.new(a.x + b.x, a.y + b.y)
end

function Vec2.__sub(a: any, b: any)
    return Vec2.new(a.x - b.x, a.y - b.y)
end

function Vec2.__mul(a: any, b: any)
    if type(b) == "number" then
        return Vec2.new(a.x * b, a.y * b)
    end
    return Vec2.new(a.x * b.x, a.y * b.y)
end

function Vec2.__unm(a: any)
    return Vec2.new(-a.x, -a.y)
end

function Vec2.__eq(a: any, b: any): boolean
    return a.x == b.x and a.y == b.y
end

function Vec2.__tostring(v: any): string
    return string.format("Vec2(%g, %g)", v.x, v.y)
end

function Vec2:length(): number
    return math.sqrt(self.x * self.x + self.y * self.y)
end

function Vec2:normalize()
    local len = self:length()
    if len == 0 then return Vec2.new(0, 0) end
    return Vec2.new(self.x / len, self.y / len)
end

function Vec2:dot(other: any): number
    return self.x * other.x + self.y * other.y
end

--// Useless but syntactically rich code to stress whitespace/comment removal

local _ = (function()
    local x = 0
    repeat
        x += 1
    until x >= 10
    return x
end)()

local _ignored = identity(identity(identity(42)))

do
    local a, b, c = 1, 2, 3
    a, b = b, a
    c = a + b
    _ = c
end

--// Long string / multiline
local longString: string = [[
    This is a
    multiline string
    that the minifier
    should preserve faithfully.
]]

--// Numeric for with step
local evenSum = 0
for i = 0, MAX_ITERATIONS, 2 do
    evenSum += i
end

--// Nested functions and closures
local function makeAdder(n: number): (number) -> number
    return function(x: number): number
        return x + n
    end
end

local add5 = makeAdder(5)
local add10 = makeAdder(10)

--// Table constructors of various forms
local mixed: { [any]: any } = {
    1, 2, 3,
    foo = "bar",
    ["baz-key"] = true,
    nested = { a = 1, b = { c = { d = 4 } } },
    [1 + 1] = "two",
}

--// Chained method calls / long expressions
local result: string = table.concat(
    map(
        filter({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, function(n) return n % 2 == 0 end),
        function(n) return tostring(n * n) end
    ),
    ", "
)

--// Exports (module return)
return {
    -- Types re-exported via values
    createStateMachine = createStateMachine,
    createCounter = Counter.new,
    Vec2 = Vec2,

    -- Utilities
    map = map,
    filter = filter,
    reduce = reduce,
    find = find,
    identity = identity,

    -- Math
    lerp = lerp,
    clamp = clamp,
    sign = sign,
    isPrime = isPrime,
    fibonacci = fibonacci,
    factorial = factorial,

    -- String
    trim = trim,
    split = split,
    startsWith = startsWith,
    endsWith = endsWith,

    -- Table
    shallowCopy = shallowCopy,
    keys = keys,
    values = values,
    tableContains = tableContains,
    mergeInto = mergeInto,

    -- Bit
    packFlags = packFlags,
    hasFlag = hasFlag,

    -- Varargs
    sum = sum,
    formatAll = formatAll,

    -- Error handling
    safeDiv = safeDiv,
    tryParse = tryParse,

    -- Async
    async = async,

    -- Native
    addInts = addInts,
    mulVec2 = mulVec2,
    dotProduct = dotProduct,

    -- Misc
    result = result,
    evenSum = evenSum,
    add5 = add5,
    add10 = add10,
    longString = longString,
    mixed = mixed,
}
