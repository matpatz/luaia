local fs = require("@lune/fs")
local luaia = require("@luaia")

local Input = fs.readFile("test/input.lua")
local FileSize = #Input
local SizeString
if FileSize >= 1024 * 1024 then
	SizeString = string.format("%.1fmb", FileSize / (1024 * 1024))
elseif FileSize >= 1024 then
	SizeString = string.format("%.1fkb", FileSize / 1024)
else
	SizeString = FileSize .. "b"
end

local function Format(Seconds)
	if Seconds < 0.001 then
		return string.format("%.2fms", Seconds * 1000)
	elseif Seconds < 1 then
		return string.format("%.0fms", Seconds * 1000)
	else
		return string.format("%.2fs", Seconds)
	end
end

print("Input: " .. SizeString)
print("")
print("Runs | Total | Avg/Run")
print("-----|-------|--------")

local Counts = { 1, 10, 50, 100 }
for _, RunCount in Counts do
	local Start = os.clock()
	for _ = 1, RunCount do
		luaia.Minify(Input)
	end
	local Elapsed = os.clock() - Start
	local Avg = Elapsed / RunCount
	print(string.format("%4dx | %s | %s", RunCount, Format(Elapsed), Format(Avg)))
end