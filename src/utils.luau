local Utils = {}

local math_huge = math.huge
local string_gsub = string.gsub

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

return Utils
