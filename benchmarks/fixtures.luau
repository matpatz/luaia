local function buildFixture(repetitions: number): string
	local lines = {
		"local function process(values)",
		"	local total = 0",
		"	for index = 1, #values do",
		"		local value = values[index]",
		"		if value then",
		"			total += value * 2 + 1",
		"		else",
		"			total -= 1",
		"		end",
		"	end",
		"	return total",
		"end",
		"",
		"local values = {}",
	}

	for i = 1, repetitions do
		lines[#lines + 1] = string.format("values[%d] = %d", i, i % 7)
	end

	lines[#lines + 1] = "for index = 1, 4 do"
	lines[#lines + 1] = "\tprint(\"status\", process(values), true, false)"
	lines[#lines + 1] = "end"

	for i = 1, repetitions do
		lines[#lines + 1] = string.format("local result%d = process(values)", i)
		lines[#lines + 1] = string.format("if result%d > %d then", i, i)
		lines[#lines + 1] = string.format("\tprint(\"result\", result%d)", i)
		lines[#lines + 1] = "end"
	end

	return table.concat(lines, "\n")
end

return {
	{
		name = "tiny",
		source = [[
local value = 1 + 2 * 3
if value > 0 then
	print("status", true)
end
]],
	},
	{
		name = "medium",
		source = buildFixture(16),
	},
	{
		name = "large",
		source = buildFixture(96),
	},
}
