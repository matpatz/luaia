local Utils = {}

local math_huge = math.huge
local math_random = math.random
local string_gsub = string.gsub
local table_clone = table.clone

function Utils.IsKeyword(name: string): boolean
	local keywords = {
		["and"] = true,
		["break"] = true,
		["do"] = true,
		["else"] = true,
		["elseif"] = true,
		["end"] = true,
		["false"] = true,
		["for"] = true,
		["function"] = true,
		["if"] = true,
		["in"] = true,
		["local"] = true,
		["nil"] = true,
		["not"] = true,
		["or"] = true,
		["repeat"] = true,
		["return"] = true,
		["then"] = true,
		["true"] = true,
		["until"] = true,
		["while"] = true,
	}
	return keywords[name] == true
end

function Utils.IsAlpha(char: number): boolean
	return (char >= 65 and char <= 90) or (char >= 97 and char <= 122)
end

function Utils.IsDigit(char: number): boolean
	return char >= 48 and char <= 57
end

function Utils.IsAlphaNum(char: number): boolean
	return Utils.IsAlpha(char) or Utils.IsDigit(char)
end

function Utils.NumberToString(num: number): string
	if num ~= num then
		return "-0/0"
	end
	if num == math_huge then
		return "1/0"
	end
	if num == -math_huge then
		return "-1/0"
	end

	local str = tostring(num)
	str = string_gsub(str, "%.0$", "")
	str = string_gsub(str, "e%+", "e")
	return str
end

local DefaultCharacterPool = {
	"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
	"n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
}

local ReservedNames = {
	["self"] = true,
	["true"] = true,
	["false"] = true,
	["nil"] = true,
	["and"] = true,
	["break"] = true,
	["do"] = true,
	["else"] = true,
	["elseif"] = true,
	["end"] = true,
	["for"] = true,
	["function"] = true,
	["if"] = true,
	["in"] = true,
	["local"] = true,
	["not"] = true,
	["or"] = true,
	["repeat"] = true,
	["return"] = true,
	["then"] = true,
	["until"] = true,
	["while"] = true,
	["continue"] = true,
	["type"] = true,
	["typeof"] = true,
	["declare"] = true,
	["export"] = true,
}

local NameGenerator = {}
NameGenerator.__index = NameGenerator

function NameGenerator.new(Pool: { string }?)
	local self = setmetatable({}, NameGenerator)
	self.Pool = Pool or DefaultCharacterPool
	self.Used = {}
	return self
end

function NameGenerator:Generate(): string
	local name = self.Pool[math_random(1, #self.Pool)]

	while ReservedNames[name] or self.Used[name] do
		name = name .. self.Pool[math_random(1, #self.Pool)]
	end

	self.Used[name] = true
	return name
end

function NameGenerator:Reserve(name: string)
	self.Used[name] = true
end

function NameGenerator:Snapshot(): { [string]: boolean }
	return table_clone(self.Used)
end

function NameGenerator:Restore(snapshot: { [string]: boolean })
	self.Used = snapshot
end

function NameGenerator:Reset()
	self.Used = {}
end

function Utils.CreateNameGenerator(Pool: { string }?)
	return NameGenerator.new(Pool)
end

return Utils
